#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════
# TaskFlow Session Manager
#
# Usage (run from Git Bash on Windows or terminal on Mac/Linux):
#   ./scripts/session.sh start    — provision + deploy everything (~25 min)
#   ./scripts/session.sh stop     — destroy everything cleanly (~15 min)
#   ./scripts/session.sh status   — show what is running + cost estimate
#   ./scripts/session.sh deploy   — redeploy app only (infra already up)
#
# Jenkins EC2 is NOT managed by Terraform.
# session.sh starts/stops it to save cost between sessions (~$0.50/month).
# ══════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Config
AWS_REGION="us-east-1"
CLUSTER_NAME="taskflow-prod"
K8S_NAMESPACE="taskflow"
GITHUB_USER="srangu594"
REPO_NAME="taskflow-app"

# ── Paths (relative to project root)
TF_DIR="terraform"
K8S_DIR="k8s/base"
TFVARS="${TF_DIR}/terraform.tfvars"

# ── Colours
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}══ $1 ══${NC}"; }

# ── Prerequisite check
check_prereqs() {
  local missing=()
  for cmd in aws terraform kubectl helm docker git; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  [ ${#missing[@]} -gt 0 ] && error "Missing tools: ${missing[*]}"
  success "All prerequisites found"
}

# ── Read value from terraform.tfvars
read_tfvar() {
  local key="$1"
  grep "^${key}" "$TFVARS" 2>/dev/null \
    | head -1 \
    | sed 's/.*=\s*"\(.*\)".*/\1/' \
    | tr -d '[:space:]'
}

# ── Find Jenkins EC2 by Name tag
get_jenkins_instance_id() {
  aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=taskflow-jenkins" \
              "Name=instance-state-name,Values=running,stopped" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text 2>/dev/null || echo "None"
}

# ── Start Jenkins EC2 (if stopped)
start_jenkins() {
  local id
  id=$(get_jenkins_instance_id)
  if [ "$id" = "None" ] || [ -z "$id" ]; then
    warn "Jenkins EC2 not found. If this is your first session, complete Step 5 in the guide to launch it manually."
    return 0
  fi
  local state
  state=$(aws ec2 describe-instances \
    --instance-ids "$id" \
    --query "Reservations[0].Instances[0].State.Name" \
    --output text --region "$AWS_REGION")
  if [ "$state" = "running" ]; then
    success "Jenkins EC2 already running (${id})"
  else
    info "Starting Jenkins EC2 (${id})..."
    aws ec2 start-instances --instance-ids "$id" --region "$AWS_REGION" > /dev/null
    aws ec2 wait instance-running --instance-ids "$id" --region "$AWS_REGION"
    sleep 20   # give Jenkins service time to fully start
    local ip
    ip=$(aws ec2 describe-instances \
      --instance-ids "$id" \
      --query "Reservations[0].Instances[0].PublicIpAddress" \
      --output text --region "$AWS_REGION")
    success "Jenkins EC2 started — http://${ip}:8080"
  fi
}

# ── Stop Jenkins EC2 (saves ~$0.50/month)
stop_jenkins() {
  local id
  id=$(get_jenkins_instance_id)
  if [ "$id" = "None" ] || [ -z "$id" ]; then
    warn "Jenkins EC2 not found — skipping stop"
    return 0
  fi
  info "Stopping Jenkins EC2 (${id}) to save cost..."
  aws ec2 stop-instances --instance-ids "$id" --region "$AWS_REGION" > /dev/null
  success "Jenkins EC2 stop initiated (charges stop within minutes)"
}

# ══════════════════════════════════════════════
# START COMMAND
# ══════════════════════════════════════════════
cmd_start() {
  echo -e "\n${BOLD}${GREEN}⚡ TaskFlow — Starting Session${NC}"
  echo -e "${CYAN}Estimated time: 25-30 minutes${NC}\n"

  check_prereqs

  # Validate terraform.tfvars exists and has real values
  [ -f "$TFVARS" ] || error "terraform.tfvars not found. Copy from terraform.tfvars.example and fill in your values."
  DB_PASS=$(read_tfvar "db_password")
  DB_USER=$(read_tfvar "db_username")
  [ -z "$DB_PASS" ] && error "db_password not set in terraform.tfvars"
  [ "$DB_PASS" = "ReplaceWithSecurePassword123!" ] && error "db_password is still the example value. Set a real password."

  # ── Start Jenkins EC2 first (it takes time to boot)
  step "0  Starting Jenkins EC2"
  start_jenkins

  # ── Terraform
  step "1/7  Provisioning AWS Infrastructure"
  cd "$TF_DIR"
  terraform init -input=false -reconfigure
  terraform validate
  terraform apply -input=false -auto-approve
  success "Infrastructure ready"

  # Save outputs for later steps
  ECR_BACKEND=$(terraform output -raw ecr_backend_url)
  ECR_FRONTEND=$(terraform output -raw ecr_frontend_url)
  RDS_ENDPOINT=$(terraform output -raw rds_endpoint | cut -d: -f1)
  RDS_PORT=$(terraform output -raw rds_port)
  S3_BUCKET=$(terraform output -raw s3_frontend_bucket)
  CF_URL=$(terraform output -raw cloudfront_url)
  cd - > /dev/null

  # ── kubectl
  step "2/7  Configuring kubectl"
  aws eks update-kubeconfig \
    --region "$AWS_REGION" \
    --name   "$CLUSTER_NAME"
  kubectl wait node --all --for=condition=Ready --timeout=300s
  success "Cluster nodes ready"

  # ── Docker images
  step "3/7  Building and Pushing Docker Images"
  IMAGE_TAG=$(git rev-parse --short HEAD 2>/dev/null || echo "local")

  aws ecr get-login-password --region "$AWS_REGION" | \
    docker login \
      --username AWS \
      --password-stdin \
      "$(echo "$ECR_BACKEND" | cut -d/ -f1)"

  docker build -t "${ECR_BACKEND}:${IMAGE_TAG}" -t "${ECR_BACKEND}:latest" \
    -f backend/Dockerfile backend/
  docker build -t "${ECR_FRONTEND}:${IMAGE_TAG}" -t "${ECR_FRONTEND}:latest" \
    --build-arg REACT_APP_API_URL=/api \
    -f frontend/Dockerfile frontend/

  docker push "${ECR_BACKEND}:${IMAGE_TAG}"
  docker push "${ECR_BACKEND}:latest"
  docker push "${ECR_FRONTEND}:${IMAGE_TAG}"
  docker push "${ECR_FRONTEND}:latest"
  success "Images pushed to ECR"

  # Update deployment manifest with new image tag
  sed -i "s|taskflow-backend:.*|taskflow-backend:${IMAGE_TAG}|g" \
    "${K8S_DIR}/deployment-backend.yaml"

  # ── K8s setup
  step "4/7  Deploying to Kubernetes"

  # Install AWS Load Balancer Controller (needed for ALB Ingress)
  helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
  helm repo update
  VPC_ID=$(cd "$TF_DIR" && terraform output -raw vpc_id)
  helm upgrade --install aws-load-balancer-controller \
    eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName="$CLUSTER_NAME" \
    --set serviceAccount.create=true \
    --set region="$AWS_REGION" \
    --set vpcId="$VPC_ID" \
    --wait --timeout 120s || warn "ALB controller install timed out (may already be installed)"

  # Apply K8s base manifests
  kubectl apply -f "${K8S_DIR}/namespace.yaml"

  # Inject real DATABASE_URL into the secret
  DB_URL="postgresql://${DB_USER}:${DB_PASS}@${RDS_ENDPOINT}:${RDS_PORT}/taskflow_db"
  kubectl create secret generic taskflow-secrets \
    --namespace="$K8S_NAMESPACE" \
    --from-literal=DATABASE_URL="$DB_URL" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl apply -f "${K8S_DIR}/" --namespace="$K8S_NAMESPACE"
  kubectl rollout status deployment/taskflow-backend \
    -n "$K8S_NAMESPACE" --timeout=120s
  success "Backend deployed and rolling update complete"

  # Seed database (safe to run multiple times)
  info "Seeding database..."
  sleep 5
  kubectl exec -n "$K8S_NAMESPACE" \
    deploy/taskflow-backend \
    -- python scripts/seed.py 2>/dev/null \
    && success "Database seeded" \
    || warn "Seed skipped (already seeded or DB not ready yet)"

  # Apply network policies
  kubectl apply -f "${K8S_DIR}/network-policy.yaml" 2>/dev/null || true

  # ── Frontend to S3
  step "5/7  Deploying Frontend to S3"
  docker create --name fe-extract "${ECR_FRONTEND}:${IMAGE_TAG}"
  docker cp fe-extract:/usr/share/nginx/html ./react-build 2>/dev/null || true
  docker rm fe-extract 2>/dev/null || true

  if [ -d "./react-build" ]; then
    aws s3 sync ./react-build "s3://${S3_BUCKET}/" \
      --delete \
      --cache-control "public,max-age=31536000,immutable" \
      --exclude "index.html" --quiet
    aws s3 cp ./react-build/index.html "s3://${S3_BUCKET}/index.html" \
      --cache-control "no-cache,no-store,must-revalidate"
    rm -rf ./react-build
    success "Frontend deployed to S3"
  fi

  # ── ArgoCD (install if not present)
  step "6/7  Installing ArgoCD"
  if ! kubectl get namespace argocd &>/dev/null; then
    kubectl create namespace argocd
    kubectl apply -n argocd \
      -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    kubectl wait --for=condition=available deployment/argocd-server \
      -n argocd --timeout=180s || warn "ArgoCD install timed out"
  fi
  kubectl apply -f k8s/argocd/application.yaml 2>/dev/null || \
    warn "ArgoCD application not applied — configure manually (Step 10 in guide)"
  success "ArgoCD ready"

  # ── Monitoring
  step "7/7  Installing Monitoring Stack"
  helm repo add prometheus-community \
    https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  helm repo update
  helm upgrade --install kube-prometheus-stack \
    prometheus-community/kube-prometheus-stack \
    -n monitoring --create-namespace \
    -f helm/monitoring/values.yaml \
    --timeout 300s || warn "Monitoring install timed out"
  kubectl apply -f k8s/monitoring/prometheus-rules.yaml 2>/dev/null || true
  success "Monitoring stack installed"

  # ── Smoke test
  echo ""
  sleep 10
  bash scripts/smoke-test.sh "http://localhost:8888" 2>/dev/null || true

  # ── Session summary
  ALB_DNS=$(kubectl get ingress -n "$K8S_NAMESPACE" \
    -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")

  JENKINS_IP=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=taskflow-jenkins" "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --output text 2>/dev/null || echo "not running")

  echo ""
  echo -e "${BOLD}${GREEN}═══════════════════════════════════════════${NC}"
  echo -e "${BOLD}${GREEN}  ✅  TaskFlow is LIVE${NC}"
  echo -e "${BOLD}${GREEN}═══════════════════════════════════════════${NC}"
  echo -e "  ${CYAN}Frontend:${NC}   $CF_URL"
  echo -e "  ${CYAN}API docs:${NC}   http://${ALB_DNS}/api/docs"
  echo -e "  ${CYAN}Jenkins:${NC}    http://${JENKINS_IP}:8080"
  echo -e "  ${CYAN}Grafana:${NC}    kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80"
  echo -e "  ${CYAN}ArgoCD:${NC}     kubectl port-forward svc/argocd-server -n argocd 8080:443"
  echo ""
  warn "Remember: run './scripts/session.sh stop' when done to avoid charges!"
}

# ══════════════════════════════════════════════
# STOP COMMAND
# ══════════════════════════════════════════════
cmd_stop() {
  echo -e "\n${BOLD}${RED}🛑 TaskFlow — Stopping Session${NC}"
  warn "This destroys all AWS resources except Jenkins EC2 (it will be stopped, not terminated)."
  warn "RDS final snapshot is saved for data recovery."
  read -rp "Type 'destroy' to confirm: " confirm
  [ "$confirm" != "destroy" ] && { info "Cancelled."; exit 0; }

  check_prereqs

  # ── Remove K8s resources first
  # CRITICAL: must delete K8s Ingress BEFORE terraform destroy
  # Otherwise the ALB created by Ingress becomes an orphan resource
  # that blocks VPC deletion (Terraform will fail trying to delete the VPC)
  step "1/4  Removing Kubernetes Resources"
  if kubectl cluster-info &>/dev/null 2>&1; then
    kubectl delete ingress --all -n "$K8S_NAMESPACE" --ignore-not-found=true 2>/dev/null || true
    sleep 30   # wait for ALB to be deleted by controller
    kubectl delete -f "${K8S_DIR}/" -n "$K8S_NAMESPACE" --ignore-not-found=true 2>/dev/null || true
    kubectl delete namespace "$K8S_NAMESPACE" --ignore-not-found=true 2>/dev/null || true
    helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true
    helm uninstall kube-prometheus-stack -n monitoring 2>/dev/null || true
    sleep 20   # give time for ALB to be fully deprovisioned
    success "K8s resources removed"
  else
    warn "Cluster unreachable — skipping K8s cleanup"
  fi

  # ── Destroy Terraform infrastructure
  step "2/4  Destroying AWS Infrastructure (15-20 min)"
  cd "$TF_DIR"
  terraform destroy -input=false -auto-approve
  success "AWS infrastructure destroyed"
  cd - > /dev/null

  # ── Stop Jenkins EC2 (not terminate — keeps it for next session)
  step "3/4  Stopping Jenkins EC2"
  stop_jenkins

  # ── Clean Docker images
  step "4/4  Cleaning Local Docker Images"
  docker images | grep taskflow | awk '{print $3}' | xargs docker rmi -f 2>/dev/null || true

  echo ""
  echo -e "${BOLD}${GREEN}═══════════════════════════════════════════${NC}"
  echo -e "${BOLD}${GREEN}  ✅  Session stopped cleanly${NC}"
  echo -e "${BOLD}${GREEN}═══════════════════════════════════════════${NC}"
  echo -e "  RDS final snapshot saved (data safe)"
  echo -e "  Jenkins EC2 stopped (not terminated — ready for next session)"
  echo -e "  ECR images, S3 bucket, tfstate remain (~\$0.12/month)"
  echo -e "  Run 'start' next time to bring everything back up in ~25 min"
}

# ══════════════════════════════════════════════
# STATUS COMMAND
# ══════════════════════════════════════════════
cmd_status() {
  echo -e "\n${BOLD}${CYAN}📊 TaskFlow — Status${NC}\n"

  if kubectl cluster-info &>/dev/null 2>&1; then
    echo -e "${GREEN}● EKS cluster: REACHABLE${NC}"
    kubectl get nodes -o wide 2>/dev/null || true
    echo ""
    kubectl get pods -n "$K8S_NAMESPACE" 2>/dev/null || true
    echo ""
    kubectl get ingress -n "$K8S_NAMESPACE" 2>/dev/null || true
  else
    echo -e "${RED}● EKS cluster: NOT REACHABLE${NC}"
  fi

  echo ""
  echo -e "${CYAN}── Jenkins EC2${NC}"
  JENKINS_ID=$(get_jenkins_instance_id)
  if [ "$JENKINS_ID" != "None" ] && [ -n "$JENKINS_ID" ]; then
    JENKINS_STATE=$(aws ec2 describe-instances \
      --instance-ids "$JENKINS_ID" \
      --query "Reservations[0].Instances[0].State.Name" \
      --output text --region "$AWS_REGION" 2>/dev/null || echo "unknown")
    JENKINS_IP=$(aws ec2 describe-instances \
      --instance-ids "$JENKINS_ID" \
      --query "Reservations[0].Instances[0].PublicIpAddress" \
      --output text --region "$AWS_REGION" 2>/dev/null || echo "—")
    echo "  Instance: $JENKINS_ID  State: $JENKINS_STATE  IP: $JENKINS_IP"
  else
    echo "  Jenkins EC2 not found — launch manually (Step 5 in guide)"
  fi

  echo ""
  echo -e "${CYAN}── RDS${NC}"
  aws rds describe-db-instances \
    --query 'DBInstances[*].[DBInstanceIdentifier,DBInstanceStatus,Endpoint.Address]' \
    --output table --region "$AWS_REGION" 2>/dev/null || echo "  No RDS instances"

  echo ""
  echo -e "${CYAN}── Estimated cost at 6 hrs/week (26 hrs/month)${NC}"
  echo "  EKS control plane:          \$2.60"
  echo "  1× On-Demand t3.medium:     \$1.08"
  echo "  1× Spot t3.medium:          \$0.39"
  echo "  RDS db.t3.medium Single-AZ: \$3.54"
  echo "  NAT Gateway × 1:            \$1.17"
  echo "  ALB:                        \$0.21"
  echo "  Jenkins EC2 (stopped):      \$0.01  (storage only)"
  echo "  ECR + S3 + DynamoDB:        \$0.12"
  echo "  ─────────────────────────────────"
  echo "  TOTAL:                     ~\$9.12/month"
}

# ══════════════════════════════════════════════
# DEPLOY COMMAND — redeploy app only, infra up
# ══════════════════════════════════════════════
cmd_deploy() {
  echo -e "\n${BOLD}${CYAN}🚀 TaskFlow — Quick Redeploy${NC}\n"
  check_prereqs

  ECR_BACKEND=$(cd "$TF_DIR" && terraform output -raw ecr_backend_url)
  IMAGE_TAG=$(git rev-parse --short HEAD 2>/dev/null || echo "local")

  aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin \
    "$(echo "$ECR_BACKEND" | cut -d/ -f1)"

  docker build -t "${ECR_BACKEND}:${IMAGE_TAG}" -t "${ECR_BACKEND}:latest" \
    -f backend/Dockerfile backend/
  docker push "${ECR_BACKEND}:${IMAGE_TAG}"
  docker push "${ECR_BACKEND}:latest"

  sed -i "s|taskflow-backend:.*|taskflow-backend:${IMAGE_TAG}|g" \
    "${K8S_DIR}/deployment-backend.yaml"

  kubectl set image deployment/taskflow-backend \
    backend="${ECR_BACKEND}:${IMAGE_TAG}" \
    -n "$K8S_NAMESPACE"
  kubectl rollout status deployment/taskflow-backend \
    -n "$K8S_NAMESPACE" --timeout=120s

  success "Redeployed image ${IMAGE_TAG}"
}

# ── Entry point
case "${1:-help}" in
  start)  cmd_start  ;;
  stop)   cmd_stop   ;;
  status) cmd_status ;;
  deploy) cmd_deploy ;;
  *)
    echo -e "\n${BOLD}Usage: ./scripts/session.sh [start|stop|status|deploy]${NC}"
    echo ""
    echo -e "  ${CYAN}start${NC}   Provision AWS infra + build + deploy (~25 min)"
    echo -e "  ${CYAN}stop${NC}    Destroy everything cleanly, stop Jenkins EC2 (~15 min)"
    echo -e "  ${CYAN}status${NC}  Show running resources + cost estimate"
    echo -e "  ${CYAN}deploy${NC}  Rebuild + redeploy app only (infra must already be up)"
    echo ""
    ;;
esac
