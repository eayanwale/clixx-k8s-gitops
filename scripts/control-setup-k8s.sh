#!/bin/bash

sudo swapoff -a

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# sysctl params required by setup, params persist across reboots
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

# Apply sysctl params without reboot
sudo sysctl --system

# Install packages needed to use the Kubernetes apt repository
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl

# Download the Google Cloud public signing key
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Add the Kubernetes apt repository
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update

# Install Kubernetes process
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# Install containerd
sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

sudo kubeadm init

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

kubectl apply -f https://reweave.azurewebsites.net/k8s/v1.36/net.yaml

sudo apt install -y docker.io
sudo usermod -a -G docker ubuntu
sudo apt install -y awscli mysql-server
aws ecr get-login-password --region us-east-1 \
    | docker login --username AWS --password-stdin \
    111111111111.dkr.ecr.us-east-1.amazonaws.com/clixx-repository

kubectl create secret generic ecr-registry-key \
    --from-file=.dockerconfigjson=$HOME/.docker/config.json \
    --type=kubernetes.io/dockerconfigjson \
    -n=clixx-prod

echo
echo
echo "======= TOKEN ======="
kubeadm token create --print-join-command



# pods="clixx-web-deployment-5bd6f5dffc-cpmzg clixx-web-deployment-5bd6f5dffc-drpkx"
# for pod in $pods; do
#     echo "=== Fixing $pod ==="
#     kubectl exec -it "$pod" -- env \
#       DB_NAME="wordpressdb" \
#       DB_USER="wordpressuser" \
#       DB_PASS="W3lcome123" \
#       DB_HOST="test-k8s-clixx.cwtkykmw0yzx.us-east-1.rds.amazonaws.com" \
#       bash -c '
#         CONFIG="/var/www/html/wp-config.php"
#         cd /var/www/html
#         cp wp-config-sample.php "$CONFIG"

#         sed -i "s|define( *.DB_NAME.*|define( '"'"'DB_NAME'"'"', '"'"'${DB_NAME}'"'"' );|" "$CONFIG"
#         sed -i "s|define( *.DB_USER.*|define( '"'"'DB_USER'"'"', '"'"'${DB_USER}'"'"' );|" "$CONFIG"
#         sed -i "s|define( *.DB_PASSWORD.*|define( '"'"'DB_PASSWORD'"'"', '"'"'${DB_PASS}'"'"' );|" "$CONFIG"
#         sed -i "s|define( *.DB_HOST.*|define( '"'"'DB_HOST'"'"', '"'"'${DB_HOST}'"'"' );|" "$CONFIG"
#       '
# done

# for pod in clixx-web-deployment-5bd6f5dffc-cpmzg clixx-web-deployment-5bd6f5dffc-drpkx; do
#   kubectl exec -it $pod -- bash -c '
# cat > /etc/apache2/sites-enabled/000-default.conf << "EOF"
# <VirtualHost *:80>
#         ServerAdmin webmaster@localhost
#         DocumentRoot /var/www/html

#         Alias /clixx /var/www/html
#         <Directory /var/www/html>
#             AllowOverride All
#             Require all granted
#         </Directory>

#         ErrorLog ${APACHE_LOG_DIR}/error.log
#         CustomLog ${APACHE_LOG_DIR}/access.log combined
# </VirtualHost>
# EOF
# apache2ctl configtest
# apache2ctl graceful
# '
# done