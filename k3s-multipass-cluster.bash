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
LEADING_NODE=""
KUBECTL_INSTALLED=""

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
}

# --- prerequisite functions ---
check_prerequisite()
{
  ### Check osx running
  [[ ! "${OSTYPE}" == "darwin"* ]] && fatal "Prerequisites: Not running OSX"
  ### Check brew installed
  [ ! -f "`command -v brew`" ] && fatal "brew not installed, visit https://brew.sh"
  ### Check kubectl installed
  [ ! -f "`command -v kubectl`" ] && info "kubectl not installed, to install it: brew install kubernetes-cli" && KUBECTL_INSTALLED="0" || KUBECTL_INSTALLED="1"
  success "Prerequisites: OK"
}

installation_multipass()
{
  ### Install multipass
  if command -v multipass > /dev/null 2>&1; then
    success "Multipass installation: Already installed"
  else
    brew cask install multipass 2>/dev/null
    [ $? -eq 0 ] && success "Multipass installation: OK" || (fatal "Multipass installation: KO")
  fi
}

# --- k3s functions ---
k3s_master_node()
{
  K3S_NAME=$1
  K3S_CPUS=$2
  K3S_MEM=$3
  K3S_DISK=$4

  multipass launch --name ${K3S_NAME} --cpus ${K3S_CPUS} --mem ${K3S_MEM} --disk ${K3S_DISK} --cloud-init <(k3s_master_cloud_init)
  [ $? -eq 0 ] && success "Node ${K3S_NAME} k3s creation: OK" || fatal "Node ${K3S_NAME} creation: KO"
  info "Node ${K3S_NAME} k3s: Waiting to be ready"
  multipass exec ${K3S_NAME} -- /bin/bash -c 'while [[ $(kubectl get nodes $(hostname) --no-headers 2>/dev/null | grep -c -w "Ready") -ne 1 ]]; do echo -n .; sleep 5; done; echo' < /dev/null
  [ $? -eq 0 ] && success "Node ${K3S_NAME} k3s: Ready" || fatal "Node ${K3S_NAME} k3s: KO"
}

k3s_node()
{
  K3S_NAME=$1
  K3S_CPUS=$2
  K3S_MEM=$3
  K3S_DISK=$4

  multipass launch --name ${K3S_NAME} --cpus ${K3S_CPUS} --mem ${K3S_MEM} --disk ${K3S_DISK} --cloud-init <(k3s_worker_cloud_init)
  [ $? -eq 0 ] && success "Node ${K3S_NAME} k3s creation: OK" || fatal "Node ${K3S_NAME} creation: KO"
  info "Node ${K3S_NAME} k3s: Waiting to be ready"
  # kubectl is configured only on master node
  # we need double axes to pass variables to the string
  # we need backslash on kubectl otherwise executed on host machine
  multipass exec ${LEADING_NODE} -- /bin/bash -c "while [[ \$(kubectl get nodes ${K3S_NAME} --no-headers 2>/dev/null | grep -c -w \"Ready\") -ne 1 ]]; do echo -n .; sleep 5; done; echo" < /dev/null
  [ $? -eq 0 ] && success "Node ${K3S_NAME} k3s: Ready" || fatal "Node ${K3S_NAME} k3s: KO"
}

k3s_setup()
{
  while read -r -a LINE; do
    info "Setup node: ${LINE[@]}"
    if [[ ${LINE[0]} == *"master"* ]]; then
      k3s_master_node ${LINE[@]}
      LEADING_NODE=${LINE[0]} && info "LEADING_NODE=${LEADING_NODE}"
      K3S_NODEIP_MASTER="https://$(multipass info ${LEADING_NODE} | grep "IPv4" | awk -F' ' '{print $2}'):6443" && info "K3S_NODEIP_MASTER=${K3S_NODEIP_MASTER}"
      K3S_TOKEN="$(multipass exec ${LEADING_NODE} -- /bin/bash -c "sudo cat /var/lib/rancher/k3s/server/node-token" < /dev/null)" && info "K3S_TOKEN=${K3S_TOKEN}"
    fi
    if [[ ${LINE[0]} == *"worker"* ]]; then
      k3s_node ${LINE[@]}
    fi
  done < <(dictionary)
}

kubectl_configuration()
{
  if [ ${KUBECTL_INSTALLED} -eq 1 ]; then
    multipass copy-files k3s-master:/etc/rancher/k3s/k3s.yaml ${HOME}/.kube/k3s.yaml
    sed -ie s,https://localhost:6443,${K3S_NODEIP_MASTER},g ${HOME}/.kube/k3s.yaml
    kubectl --kubeconfig=${HOME}/.kube/k3s.yaml get nodes
    [ $? -eq 0 ] && success "kubectl configuration: OK" && info "Use i.e.: \"kubectl --kubeconfig=${HOME}/.kube/k3s.yaml get nodes\" or \"export KUBECONFIG="${HOME}/.kube/k3s.yaml"\"" || (fatal "kubectl configuration: KO")
  else
    info "kubectl not configured because not installed"
  fi
}

k3s_labels()
{
  ### nodes labels and taints
  while read -r -a LINE; do
    if [[ ${LINE[0]} == *"master"* ]]; then
      info "=== DEBUG nodes labels and taints: ${LINE[0]}"
      multipass exec ${LINE[0]} -- /bin/bash -c 'kubectl label node $(hostname) node-role.kubernetes.io/master=""' < /dev/null
      multipass exec ${LINE[0]} -- /bin/bash -c 'kubectl taint node $(hostname) node-role.kubernetes.io/master=effect:NoSchedule' < /dev/null
    fi
    if [[ ${LINE[0]} == *"worker"* ]]; then
      info "=== DEBUG nodes labels and taints: ${LINE[0]}"
      multipass exec ${LEADING_NODE} -- /bin/bash -c "kubectl label node ${LINE[0]} node-role.kubernetes.io/node=\"\"" < /dev/null
    fi
  done < <(dictionary) 
}

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
  exit 1
}


# --- main script ---
check_prerequisite
installation_multipass
k3s_setup
kubectl_configuration
k3s_labels
