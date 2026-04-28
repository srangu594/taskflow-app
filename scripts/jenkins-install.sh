#!/usr/bin/env bash
set -e

echo "=== Installing Java 21 ==="
apt-get update -y
apt-get install -y openjdk-21-jdk
java -version

echo "=== Installing Jenkins ==="
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 7198F4B714ABFC68
echo "deb https://pkg.jenkins.io/debian-stable binary/" \
  > /etc/apt/sources.list.d/jenkins.list
apt-get update -y
apt-get install -y jenkins

echo "=== Installing Docker ==="
apt-get install -y docker.io
usermod -aG docker jenkins
usermod -aG docker ubuntu
systemctl enable docker
systemctl start docker

echo "=== Installing AWS CLI ==="
apt-get install -y unzip
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/aws.zip
unzip -q /tmp/aws.zip -d /tmp/
/tmp/aws/install
rm -rf /tmp/aws /tmp/aws.zip

echo "=== Installing kubectl ==="
curl -fsSL "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
  -o /usr/local/bin/kubectl
chmod +x /usr/local/bin/kubectl

echo "=== Installing Terraform ==="
wget -O- https://apt.releases.hashicorp.com/gpg \
  | gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  > /etc/apt/sources.list.d/hashicorp.list
apt-get update -y
apt-get install -y terraform

echo "=== Installing ArgoCD CLI ==="
curl -sSL -o /usr/local/bin/argocd \
  https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x /usr/local/bin/argocd

echo "=== Installing Python3 ==="
apt-get install -y python3-pip

echo "=== Starting Jenkins ==="
systemctl enable jenkins
systemctl start jenkins
sleep 20

echo ""
echo "========================================"
echo " Jenkins URL: http://$(curl -sf http://169.254.169.254/latest/meta-data/public-ipv4):8080"
echo ""
echo " Initial admin password:"
cat /var/lib/jenkins/secrets/initialAdminPassword
echo ""
echo "========================================"