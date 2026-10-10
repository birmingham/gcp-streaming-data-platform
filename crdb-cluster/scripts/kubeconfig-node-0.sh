bash
#!/bin/bash
set -euo pipefail

mkdir -p ~/.kube
sudo cp /etc/rancher/rke2/rke2.yaml ~/.kube/config
sudo chown "$(id -u):$(id -g)" ~/.kube/config
chmod 600 ~/.kube/config

# Remove the global KUBECONFIG override so it stops shadowing ~/.kube/config
sudo sed -i '/^export KUBECONFIG=/d' /etc/profile.d/rke2.sh

unset KUBECONFIG
echo "Kubeconfig installed at ~/.kube/config. Verifying:"
kubectl get nodes