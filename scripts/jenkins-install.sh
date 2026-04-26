#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════
# TaskFlow — Jenkins EC2 Install Script
#
# Run this on the Jenkins EC2 after launching it manually:
#   chmod +x scripts/jenkins-install.sh
#   scp -i ~/.ssh/taskflow-key.pem scripts/jenkins-install.sh ubuntu@<EC2_IP>:~/
#   ssh -i ~/.ssh/taskflow-key.pem ubuntu@<EC2_IP>
#   sudo bash jenkins-install.sh
#
# What this installs:
#   Java 17, Jenkins, Docker, AWS CLI v2, kubectl, Terraform, ArgoCD CLI, Python3
# ══════════════════════════════════════════════════════════════════
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

info "Starting Jenkins EC2 setup..."
apt-get update -y

# ── Java 17 (required by Jenkins)
info "Installing Java 17..."
apt-get install -y openjdk-17-jdk
java -version
success "Java 17 installed"

# ── Jenkins
info "Installing Jenkins..."
curl -fsSL https://pkg.jenkins.io/debian/jenkins.io-2023.key \
    | tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] \
    https://pkg.jenkins.io/debian binary/" \
    | tee /etc/apt/sources.list.d/jenkins.list > /dev/null
apt-get update -y
apt-get install -y jenkins
success "Jenkins installed"

# ── Docker
info "Installing Docker..."
apt-get install -y docker.io
usermod -aG docker jenkins
usermod -aG docker ubuntu
systemctl enable docker
systemctl start docker
success "Docker installed"

# ── AWS CLI v2
info "Installing AWS CLI v2..."
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
apt-get install -y unzip
unzip -q /tmp/awscliv2.zip -d /tmp/aws-install
/tmp/aws-install/aws/install
rm -rf /tmp/awscliv2.zip /tmp/aws-install
aws --version
success "AWS CLI v2 installed"

# ── kubectl
info "Installing kubectl..."
KUBECTL_VER=$(curl -sL https://dl.k8s.io/release/stable.txt)
curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VER}/bin/linux/amd64/kubectl" \
    -o /usr/local/bin/kubectl
chmod +x /usr/local/bin/kubectl
kubectl version --client
success "kubectl installed"

# ── Terraform
info "Installing Terraform..."
wget -O- https://apt.releases.hashicorp.com/gpg \
    | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
    https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    | tee /etc/apt/sources.list.d/hashicorp.list > /dev/null
apt-get update -y
apt-get install -y terraform
terraform version
success "Terraform installed"

# ── ArgoCD CLI
info "Installing ArgoCD CLI..."
curl -sSL -o /usr/local/bin/argocd \
    https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x /usr/local/bin/argocd
argocd version --client
success "ArgoCD CLI installed"

# ── Python3 + pip (for tests in pipeline)
info "Installing Python3..."
apt-get install -y python3-pip
python3 --version
success "Python3 installed"

# ── git (usually pre-installed, ensure latest)
apt-get install -y git
git --version

# ── Start Jenkins
info "Starting Jenkins..."
systemctl enable jenkins
systemctl start jenkins
sleep 5

# ── Print initial admin password
echo ""
echo "════════════════════════════════════════════════════"
echo "  Jenkins is running at http://$(curl -sf http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo '<EC2_PUBLIC_IP>'):8080"
echo "  Initial admin password:"
echo ""
cat /var/lib/jenkins/secrets/initialAdminPassword
echo ""
echo "  Copy this password to complete setup in the browser."
echo "════════════════════════════════════════════════════"
