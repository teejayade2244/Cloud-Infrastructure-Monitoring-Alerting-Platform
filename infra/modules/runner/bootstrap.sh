#!/bin/bash
set -e

# Install Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | bash

# Install Terraform
wget -O- https://apt.releases.hashicorp.com/gpg | \
  gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  tee /etc/apt/sources.list.d/hashicorp.list
apt-get update && apt-get install -y terraform

# Create runner user
useradd -m -s /bin/bash runner || true

# Download and configure GitHub Actions runner
mkdir -p /home/runner/actions-runner
cd /home/runner/actions-runner
curl -o actions-runner-linux-x64.tar.gz -L \
  https://github.com/actions/runner/releases/download/v2.319.1/actions-runner-linux-x64-2.319.1.tar.gz
tar xzf ./actions-runner-linux-x64.tar.gz
chown -R runner:runner /home/runner/actions-runner

# Runner registration happens via separate step using
# GitHub registration token - see outputs for next steps

echo "Bootstrap complete - runner tools installed"
echo "Next: SSH in and run ./config.sh with GitHub token"
