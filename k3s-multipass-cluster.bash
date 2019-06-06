#!/usr/bin/env bash

dictionary() {
# nodename must contains "master" or "worker" word
# master must be just 1 and must be the first 
# nodename cpus memory disk
cat << EOF
k3s-master 1 1024M 3G
k3s-worker1 1 1024M 3G
k3s-worker2 1 1024M 3G
EOF
}

k3s_master_cloud_init() {
cat << EOF
runcmd:
 - '\curl -sfL https://get.k3s.io | sh -'
EOF
}

k3s_worker_cloud_init() {
cat << EOF
runcmd:
 - '\curl -sfL https://get.k3s.io | K3S_TOKEN=${K3S_TOKEN} K3S_URL=${K3S_NODEIP_MASTER} sh -'
EOF
}

K3S_NODEIP_MASTER=""
K3S_TOKEN=""

### Functions

# --- set colors and formats for logs ---
if [ "x$TERM" != "x" ] && [ "$TERM" != "dumb" ]; then

    export fmt_red=$(tput setaf 1)
    export fmt_green=$(tput setaf 2)
    export fmt_yellow=$(tput setaf 3)
    export fmt_purple=$(tput setaf 5)
    export fmt_cyan=$(tput setaf 6)
    export fmt_bold=$(tput bold)
    export fmt_underline=$(tput sgr 0 1)
    export fmt_end=$(tput sgr0)

fi

# --- helper functions for logs ---
success()
{
    echo -e "${fmt_green}[SUCCESS]${fmt_end}" "$@"
}

info()
{
    echo -e "${fmt_yellow}[INFO]${fmt_end}" "$@"
}

fatal()
{
    echo -e "${fmt_red}[ERROR]${fmt_end}" "$@"
    echo -e "${fmt_red}[ERROR]${fmt_end} Exiting with errors. Cleaning..."
    clean
    exit 1
}

check_prerequisite()
{
  ### Check osx running
  [[ ! "${OSTYPE}" == "darwin"* ]] && fatal "Prerequisites: Not running OSX"
  ### Check brew installed
  [ ! -f "`which brew`" ] && fatal "Brew not installed"
  success "Prerequisites: OK"
}

installation_multipass()
{
  ### Install multipass
  brew cask install multipass 2>/dev/null 
  [ $? -eq 0 ] && success "Multipass installation: OK"
}

k3s()
{
  ### node creation and k3s configuration
  while read -r -a LINE; do
    if [[ ${LINE[0]} == *"master"* ]]; then
      multipass launch --name ${LINE[0]} --cpus ${LINE[1]} --mem ${LINE[2]} --disk ${LINE[3]} --cloud-init <(k3s_master_cloud_init)
      [ $? -eq 0 ] && success "Node ${LINE[0]} k3s creation: OK" || fatal "Node ${LINE[0]} creation: KO"
      info "Node ${LINE[0]} k3s: Waiting to be ready"
      multipass exec ${LINE[0]} -- /bin/bash -c 'while [[ $(k3s kubectl get nodes --no-headers 2>/dev/null | grep -c -v "NotReady") -eq 0 ]]; do echo -n .; sleep 2; done; echo'
      success "Node ${LINE[0]} k3s: Ready"
      K3S_NODEIP_MASTER="https://$(multipass info ${LINE[0]} | grep "IPv4" | awk -F' ' '{print $2}'):6443" && info "Cluster URL: ${K3S_NODEIP_MASTER}"
      K3S_TOKEN="$(multipass exec ${LINE[0]} -- /bin/bash -c "sudo cat /var/lib/rancher/k3s/server/node-token")" && info "K3S_TOKEN: ${K3S_TOKEN}"
    fi
  done < <(dictionary) 
  while read -r -a LINE; do
    if [[ ${LINE[0]} == *"worker"* ]]; then
      multipass launch --name ${LINE[0]} --cpus ${LINE[1]} --mem ${LINE[2]} --disk ${LINE[3]} --cloud-init <(k3s_worker_cloud_init)
      [ $? -eq 0 ] && success "Node ${LINE[0]} k3s creation: OK" || fatal "Node ${LINE[0]} creation: KO"
      # info "Node ${LINE[0]} k3s: Waiting to be ready"
      # multipass exec ${LINE[0]} -- /bin/bash -c 'while [[ $(k3s kubectl get nodes --no-headers 2>/dev/null | grep -c -v "NotReady") -eq 0 ]]; do echo -n .; sleep 2; done; echo'
      # success "Node ${LINE[0]} k3s: Ready"
    fi
  done < <(dictionary) 
}

kubectl_configuration()
{
  multipass copy-files k3s-master:/etc/rancher/k3s/k3s.yaml ${HOME}/.kube/k3s.yaml
  sed -i s,https://localhost:6443,${K3S_NODEIP_MASTER},g ${HOME}/.kube/k3s.yaml
  kubectl --kubeconfig=${HOME}/.kube/k3s.yaml get nodes
  [ $? -eq 0 ] && success "kubectl configuration: OK" && info "Use i.e.: \"kubectl --kubeconfig=${HOME}/.kube/k3s.yaml get nodes\"" || (fatal "kubectl configuration: KO")
}

# k3s_labels()
# {

# }

clean()
{
  # Clean everything
  while read -r -a LINE; do
    multipass stop ${LINE[0]}
    [ $? -eq 0 ] && success "Node stop ${LINE[0]}: OK" || (info "Node stop ${LINE[0]}: maybe it does not exist or it is already stopped")
  done < <(dictionary)
  while read -r -a LINE; do
    multipass delete ${LINE[0]}
    [ $? -eq 0 ] && success "Node delete ${LINE[0]}: OK" || (info "Node delete ${LINE[0]}: maybe it does not exist")
  done < <(dictionary)
  multipass purge
  [ $? -eq 0 ] && success "Nodes purge: OK" || (info "Nodes purge: KO")
}

### main

check_prerequisite
installation_multipass
k3s
kubectl_configuration
#clean

