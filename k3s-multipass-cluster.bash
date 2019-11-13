#!/usr/bin/env bash

dictionary() {
# with 3G and 2 worker nodes no space left during istio installation
# with 5G and 1 worker nodes no enough memory during istio installation
# k3s-worker3 3 3G 5G

# nodename must contains "master" or "worker" word
# master must be just 1 and must be the first
# nodename cpus memory disk
cat << EOF
k3s-master 1 1G 512M
k3s-worker1 3 3G 5G
k3s-worker2 3 3G 5G
EOF
}


k3s_master_cloud_init() {
cat << EOF
#cloud-config
runcmd:
 - '\curl -sfL https://get.k3s.io | K3S_KUBECONFIG_MODE="644" sh -s - --node-taint node-role.kubernetes.io/master=effect:NoSchedule --no-deploy=traefik'
EOF
}

k3s_worker_cloud_init() {
cat << EOF
#cloud-config
runcmd:
 - '\curl -sfL https://get.k3s.io | K3S_TOKEN=${K3S_TOKEN} K3S_URL=${K3S_URL} sh -s -'
EOF
}

KUBECONFIG_PATH="${HOME}/.kube/k3s.yaml"
K3S_NODEIP_MASTER=""
K3S_URL=""
LEADING_NODE=""
K3S_NODEIP_WORKER=""
KUBECTL_INSTALLED=""
HELM_INSTALLED=""
INSTALL_K3S_EXEC_WORKER=""#"--no-deploy=traefik --no-deploy=servicelb"

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

check_root() {
    if [[ $USER == root || $HOME == /root ]] ; then
        fatal "Please don't run as root"
        info "Sudo will be used internally by this script as required."
        exit 1
    fi
}

check_prerequisite()
{
  ### Check osx running
  [[ ! "${OSTYPE}" == "darwin"* ]] && fatal "Prerequisites: Not running OSX"
  ### Check brew installed
  [ ! -f "`command -v brew`" ] && fatal "brew not installed, visit https://brew.sh"
  ### Check kubectl installed
  [ ! -f "`command -v kubectl`" ] && info "kubectl not installed, to install it: brew install kubernetes-cli" && KUBECTL_INSTALLED="false" || KUBECTL_INSTALLED="true"
  ### Check helm installed
  [ ! -f "`command -v helm`" ] && info "helm not installed, to install it: brew install kubernetes-helm" && HELM_INSTALLED="false" || HELM_INSTALLED="true"
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
#  multipass exec ${K3S_NAME} -- /bin/bash -c 'while [ ! -f /etc/rancher/k3s/k3s.yaml ]; do echo -n .; sleep 5; done; sudo chmod 644 /etc/rancher/k3s/k3s.yaml' < /dev/null #https://github.com/rancher/k3s/issues/389
  multipass exec ${K3S_NAME} -- /bin/bash -c 'while [[ $(k3s kubectl get nodes $(hostname) --no-headers 2>/dev/null | grep -c -w "Ready") -ne 1 ]]; do echo -n .; sleep 5; done; echo' < /dev/null
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
  # we need double apex to pass variables to the string
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
      K3S_NODEIP_MASTER=$(multipass info ${LEADING_NODE} | grep "IPv4" | awk -F' ' '{print $2}') && info "K3S_NODEIP_MASTER=${K3S_NODEIP_MASTER}"
      K3S_URL="https://${K3S_NODEIP_MASTER}:6443" && info "K3S_URL=${K3S_URL}"
      K3S_TOKEN="$(multipass exec ${LEADING_NODE} -- /bin/bash -c "sudo cat /var/lib/rancher/k3s/server/node-token" < /dev/null)" && info "K3S_TOKEN=${K3S_TOKEN}"
    fi
    if [[ ${LINE[0]} == *"worker"* ]]; then
      k3s_node ${LINE[@]}
      K3S_NODEIP_WORKER=$(multipass info ${LINE[0]} | grep "IPv4" | awk -F' ' '{print $2}') && info "K3S_NODEIP_WORKER=${K3S_NODEIP_WORKER}"
    fi
  done < <(dictionary)
}

k3s_labels() #OBSOLETE DUE TO: https://github.com/rancher/k3s/issues/379
{
  ### nodes labels and taints
  while read -r -a LINE; do
    if [[ ${LINE[0]} == *"master"* ]]; then
      info "Node ${LINE[0]} labels and taints"
      multipass exec ${LINE[0]} -- /bin/bash -c 'kubectl label node $(hostname) node-role.kubernetes.io/master=""' < /dev/null
      multipass exec ${LINE[0]} -- /bin/bash -c 'kubectl taint node $(hostname) node-role.kubernetes.io/master=effect:NoSchedule' < /dev/null
    fi
    if [[ ${LINE[0]} == *"worker"* ]]; then
      info "Node ${LINE[0]} labels"
      multipass exec ${LEADING_NODE} -- /bin/bash -c "kubectl label node ${LINE[0]} node-role.kubernetes.io/node=\"\"" < /dev/null
    fi
  done < <(dictionary) 
}

kubectl_configuration()
{
  if ${KUBECTL_INSTALLED}; then
      if [ -w ${KUBECONFIG_PATH} ]; then
          multipass copy-files ${LEADING_NODE}:/etc/rancher/k3s/k3s.yaml ${KUBECONFIG_PATH}
          # Managing both localhost and 127.0.0.1 since K3S 0.9.0: https://github.com/rancher/k3s/pull/750
#          sed -ie s,https://localhost:6443,${K3S_URL},g ${KUBECONFIG_PATH}
          sed -i -e "s|    server: https://127.0.0.1:6443|    #EDITED BY SCRIPT\n    server: ${K3S_URL}|" ${KUBECONFIG_PATH}
          kubectl --kubeconfig=${KUBECONFIG_PATH} get nodes
          [ $? -eq 0 ] && success "kubectl configuration: OK" && info "Use i.e.: \"kubectl --kubeconfig=${KUBECONFIG_PATH} get nodes\" or \"export KUBECONFIG="${KUBECONFIG_PATH}"\"" || (fatal "kubectl configuration: KO")
        else
          info "kubectl not configured because not \"${KUBECONFIG_PATH}\" not writable"
          info "Use i.e.: \"multipass exec ${LEADING_NODE} kubectl cluster-info\""
      fi
    else
      info "kubectl not configured because not installed"
      info "Use i.e.: \"multipass exec ${LEADING_NODE} kubectl cluster-info\""
  fi
}

helm_rbac_config() {
cat << EOF | kubectl --kubeconfig=${KUBECONFIG_PATH} apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tiller
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: tiller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: tiller
    namespace: kube-system
EOF
}

helm_install()
{
  ### install helm
  if ${HELM_INSTALLED}; then
      info "[helm] Install"
      helm_rbac_config
      helm --kubeconfig=${KUBECONFIG_PATH} init --service-account tiller
      info "[helm] Please wait for the tiller pod to be ready"
      kubectl --kubeconfig=${KUBECONFIG_PATH} rollout status deployment tiller-deploy --namespace=kube-system -w
      [ $? -eq 0 ] && success "[helm] installation: OK" || fatal "[helm] installation: KO"
    else
      info "[helm] helm not configured because not installed"
  fi
}

# WORK IN PROGRESS - STUCK AFTER 1ST COMMAND, TO BE TESTED AFTER REMOVING </dev/null
# helm_install_2()
# {
#   ### install helm
#   multipass exec ${LEADING_NODE} -- /bin/bash -c "curl -L https://git.io/get_helm.sh | bash"
#   echo "DEBUG1"
#   multipass exec ${LEADING_NODE} -- /bin/bash -c "<(helm_rbac_config)"
#   echo "DEBUG2"
#   multipass exec ${LEADING_NODE} -- /bin/bash -c "helm --kubeconfig=${KUBECONFIG_PATH} init --service-account tiller"
#   helm version
#   [ $? -eq 0 ] && success "Node ${LINE[0]} helm installation: OK" || (info "Node ${LINE[0]} helm installation: KO")
# }

metrics-server_rbac_config() {
cat << EOF | kubectl --kubeconfig=${KUBECONFIG_PATH} apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: metrics-server
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: metrics-server
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: metrics-server
    namespace: kube-system
EOF
}

metrics-server_install()
{
  info "[metrics-server] Configuring ServiceAccount and ClusterRoleBinding"
  metrics-server_rbac_config
  info "[metrics-server] Install"
  TMP_DIR=$(mktemp -d /tmp/k3s-XXXXXX) && cd $TMP_DIR && echo $TMP_DIR
  git clone https://github.com/kubernetes-incubator/metrics-server.git
  kubectl --kubeconfig=${KUBECONFIG_PATH} apply -f metrics-server/deploy/1.8+/
  kubectl --kubeconfig=${KUBECONFIG_PATH} rollout status deployment metrics-server --namespace kube-system -w
  [ $? -eq 0 ] && success "[metrics-server] installation: OK" || fatal "[metrics-server] installation: KO"
  rm -rf $TMP_DIR
  info "[metrics-server] Awaiting for the server to be ready (and avoid \"the server is currently unable to handle the request\" error)"
  until kubectl --kubeconfig=${KUBECONFIG_PATH} top nodes >/dev/null 2>&1; do echo -n .; sleep 5; done; echo; info "[metrics-server] installation: server up & running"
}

weave-scope_install()
{
  [[ -n $WEAVESCOPE ]] || return 0
  info "[weavescope] Install"
  kubectl --kubeconfig=${KUBECONFIG_PATH} apply -f "https://cloud.weave.works/k8s/scope.yaml?k8s-version=$(kubectl --kubeconfig=${KUBECONFIG_PATH} version | base64 | tr -d '\n')&k8s-service-type=NodePort"
  kubectl --kubeconfig=${KUBECONFIG_PATH} rollout status deployment weave-scope-app --namespace weave -w
  [ $? -eq 0 ] && success "[weavescope] installation: OK" || fatal "[weavescope] installation: KO"
  info "[weavescope] URL: http://${K3S_NODEIP_MASTER}:$(kubectl --kubeconfig=${KUBECONFIG_PATH} get services weave-scope-app --namespace weave -o jsonpath="{.spec.ports[0].nodePort}")"
}

prometheus-operator_install() {
  [[ -n $PROMETHEUS ]] || return 0
  info "[prometheus] Install"
  helm --kubeconfig=${KUBECONFIG_PATH} install -n prometheus-operator --namespace monitoring stable/prometheus-operator --set grafana.service.type=NodePort --set grafana.service.nodePort=30808 --set prometheus.service.type=NodePort --set prometheus.service.nodePort=30909 --set kubelet.serviceMonitor.https=true --wait --timeout 300
  [ $? -eq 0 ] && success "[prometheus] installation: OK" || fatal "[prometheus] installation: KO"
  info "[prometheus] URL Grafana: http://${K3S_NODEIP_MASTER}:$(kubectl --kubeconfig=${KUBECONFIG_PATH} get services prometheus-operator-grafana --namespace monitoring -o jsonpath="{.spec.ports[0].nodePort}"), user: \"$(kubectl get secrets prometheus-operator-grafana --namespace monitoring -o jsonpath='{.data.admin-user}' | base64 --decode)\", pwd: \"$(kubectl get secrets prometheus-operator-grafana --namespace monitoring -o jsonpath='{.data.admin-password}' | base64 --decode)\""
  info "[prometheus] URL Prometheus: http://${K3S_NODEIP_MASTER}:$(kubectl --kubeconfig=${KUBECONFIG_PATH} get services prometheus-operator-prometheus --namespace monitoring -o jsonpath="{.spec.ports[0].nodePort}")"
}

istio_grafana_gateway() {
cat << EOF | kubectl --kubeconfig=${KUBECONFIG_PATH} apply -f -
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: grafana-gateway
  namespace: istio-system
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 15031
      name: http-grafana
      protocol: HTTP
    hosts:
    - "*"
EOF
}

istio_grafana_virtualservice() {
cat << EOF | kubectl --kubeconfig=${KUBECONFIG_PATH} apply -f -
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: grafana-vs
  namespace: istio-system
spec:
  hosts:
  - "*"
  gateways:
  - grafana-gateway
  http:
  - match:
    - port: 15031
    route:
    - destination:
        host: grafana
        port:
          number: 3000
EOF
}

nginx() {
cat << EOF | kubectl --kubeconfig=${KUBECONFIG_PATH} apply -f -
apiVersion: v1
kind: Service
metadata:
  name: nginx-svc
  labels:
    app: nginx-svc
spec:
  selector:
    app: nginx
  ports:
  - name: http
    port: 80
    nodePort: 32767
  type: NodePort
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deploy
  labels:
    version: v1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
        version: v1
    spec:
      containers:
      - name: nginx-container
        image: nginx
        ports:
        - containerPort: 80
EOF
}

istio_nginx_gateway() {
cat << EOF | kubectl --kubeconfig=${KUBECONFIG_PATH} apply -f -
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: nginx-gateway
spec:
  selector:
    istio: ingressgateway 
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "*"
EOF
}

istio_nginx_virtualservice() {
cat << EOF | kubectl --kubeconfig=${KUBECONFIG_PATH} apply -f -
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: nginx-vs
spec:
  hosts:
  - "*"
  gateways:
  - nginx-gateway
  http:
  - route:
    - destination:
        host: nginx-svc
EOF
}

istio_install()
{
  [[ -n $ISTIO ]] || return 0
  if ${HELM_INSTALLED}; then
      info "[istio.io] Installation ref: https://istio.io/docs/setup/kubernetes/install/helm/"
      info "[istio.io] Adding helm repo"
      helm repo add istio.io https://storage.googleapis.com/istio-release/releases/1.2.0/charts/
      info "[istio.io] Installing required CRDs"
      helm --kubeconfig=${KUBECONFIG_PATH} install --name istio-init --namespace istio-system istio.io/istio-init --wait --timeout 300
      while [ $(kubectl --kubeconfig=${KUBECONFIG_PATH} get crds | grep 'istio.io\|certmanager.k8s.io' | wc -l | xargs 2>/dev/null) -ne 23 ]; do echo -n .; sleep 5; done; echo; info "[istio.io] Required CRDs have been committed"
      info "[istio.io] Install chart"
      # --set kiali.enabled=true
      # HELM BUG: https://github.com/helm/helm/issues/6894 Helm v2.16.0 --> Error: no kind "Job" is registered for version "batch/v1" in scheme "k8s.io/kubernetes/pkg/api/legacyscheme/scheme.go:30"
      # WAITING TO BE FIXED
      helm --kubeconfig=${KUBECONFIG_PATH} install --name istio --namespace istio-system --set grafana.enabled=true istio.io/istio --wait --timeout 600
      [ $? -eq 0 ] && success "[istio.io] installation: OK" || info "[istio.io] installation: KO *********** CHECK IS NEEDED ***********"
      info "[istio.io] Enabling the creation of Envoy proxies for automatic sidecar injection"
      kubectl --kubeconfig=${KUBECONFIG_PATH} label namespace default istio-injection=enabled
      kubectl --kubeconfig=${KUBECONFIG_PATH} get namespace -L istio-injection
      info "[istio.io] Creating Istio Objects"
      istio_grafana_gateway
      istio_grafana_virtualservice
      while [ $(curl -o /dev/null -w "%{http_code}\n" -sSLIk "http://${K3S_NODEIP_WORKER}:15031" 2>/dev/null) -ne 200 ]; do echo -n .; sleep 5; done; echo; info "[istio.io] Istio graphana: http://${K3S_NODEIP_WORKER}:15031"
      istio_nginx_gateway
      istio_nginx_virtualservice
      nginx
      while [ $(curl -o /dev/null -w "%{http_code}\n" -sSLIk "http://${K3S_NODEIP_WORKER}" 2>/dev/null) -ne 200 ]; do echo -n .; sleep 5; done; echo; info "[istio.io] nginx: http://${K3S_NODEIP_WORKER}"
    else
      info "[istio.io] istio not configured because helm is not installed"
  fi
}

clean()
{
  # Clean everything
  while read -r -a LINE; do
    multipass stop ${LINE[0]}
    [ $? -eq 0 ] && success "Node ${LINE[0]} stop: OK" || (info "Node ${LINE[0]} stop: maybe it does not exist or it is already stopped")
  done < <(dictionary)
  while read -r -a LINE; do
    multipass delete ${LINE[0]}
    [ $? -eq 0 ] && success "Node ${LINE[0]} delete: OK" || (info "Node ${LINE[0]} delete: maybe it does not exist")
  done < <(dictionary)
  multipass purge
  [ $? -eq 0 ] && success "Nodes purge: OK" || (info "Nodes purge: KO")
  exit 1
}


# --- main script ---
check_root
check_prerequisite
installation_multipass
k3s_setup
kubectl_configuration
helm_install
metrics-server_install
WEAVESCOPE="" weave-scope_install
PROMETHEUS="" prometheus-operator_install
ISTIO="y" istio_install
