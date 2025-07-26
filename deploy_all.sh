#!/bin/bash
# Automated Kind multi-node cluster setup with monitoring, ArgoCD, and Kagent
# Usage: ./deploy_all.sh

set -e

# Determine the absolute path to the repository root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common environment variables
source "$REPO_ROOT/.env"

# Configuration variables
readonly CLUSTER_NAME="aire-poc"
readonly LLM_PROVIDER="ollama"
readonly LLM_MODEL="llama3.1"
readonly DEMO_APP_NAMESPACE="demo-app"
readonly MONITORING_NAMESPACE="monitoring"
readonly KAGENT_NAMESPACE="kagent"
readonly ARGOCD_NAMESPACE="argocd"

# File paths
readonly KIND_CONFIG="01_multi_node_cluster/01_multi_node_cluster.yaml"
readonly APP_MANIFEST="02_demo_app/02_deployment_app.yaml"
readonly GRAFANA_VALUES="03_monitoring/grafana_values.yaml"
readonly GRAFANA_INGRESS="03_monitoring/grafana_ingress.yaml"
readonly OLLAMA_TEST_POD="04_ollama/ollama_test_pod.yaml"
readonly KAGENT_VALUES="05_kagent/values-ollama.yaml"
readonly ARGOCD_OBJECTS="06_argocd/argo-cd.yaml"

# URLs
readonly INGRESS_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/kind/deploy.yaml"
readonly ARGOCD_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"

# Required tools
readonly REQUIRED_TOOLS=("kind" "helm" "kubectl" "jq" "ollama" "docker")

# Utility functions
log_info() {
    echo -e "${BLUE}$1${NC}"
}

log_success() {
    echo -e "${GREEN}$1${NC}"
}

log_warning() {
    echo -e "${YELLOW}$1${NC}"
}

log_error() {
    echo -e "${RED}$1${NC}"
}

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if Docker Desktop is running
check_docker_running() {
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker is not running. Please start Docker Desktop and try again."
        exit 1
    fi
    log_success "Docker is running."
}

# Install a tool using brew
install_tool() {
    local tool=$1
    log_info "Installing $tool..."
    if brew install "$tool"; then
        log_success "$tool installed successfully."
    else
        log_error "Failed to install $tool. Please install it manually."
        exit 1
    fi
}

# Check and install required dependencies
check_dependencies() {
    log_info "Checking required dependencies..."
    
    # Check if brew is installed
    if ! command_exists brew; then
        log_error "Homebrew is not installed. Please install it first: https://brew.sh/"
        exit 1
    fi
    
    local missing_tools=()
    
    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! command_exists "$tool"; then
            missing_tools+=("$tool")
        else
            log_success "$tool is already installed."
        fi
    done
    
    # Install missing tools
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_info "Installing missing tools: ${missing_tools[*]}"
        for tool in "${missing_tools[@]}"; do
            install_tool "$tool"
        done
    fi
    
    # Special check for Docker Desktop
    check_docker_running
}

# Setup Ollama server
setup_ollama() {
    log_info "Setting up Ollama..."
    
    if lsof -i :11434 | grep -q LISTEN; then
        log_success "Ollama server is already running on port 11434."
    else
        log_warning "Starting Ollama server..."
        ollama serve &
        sleep 5
    fi
    
    log_success "Pulling the model: $LLM_MODEL"
    ollama pull "$LLM_MODEL"
}

# Create Kind cluster
create_cluster() {
    log_info "Managing Kind cluster..."
    
    # Delete existing cluster if it exists
    if kind get clusters | grep -q "$CLUSTER_NAME"; then
        log_warning "Deleting existing Kind cluster: $CLUSTER_NAME"
        kind delete cluster --name "$CLUSTER_NAME"
    fi
    
    log_info "Creating Kind cluster: $CLUSTER_NAME"
    kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG"
}

# Setup ingress-nginx
setup_ingress() {
    log_info "Setting up ingress-nginx..."
    
    kubectl apply -f "$INGRESS_MANIFEST"
    
    log_warning "Waiting for ingress-nginx-controller pod to be ready..."
    kubectl wait --namespace ingress-nginx \
        --for=condition=Ready pod \
        -l app.kubernetes.io/component=controller \
        --timeout=180s
    
    log_success "Patching ingress-nginx-controller service NodePorts..."
    kubectl patch svc ingress-nginx-controller -n ingress-nginx \
        -p '{"spec": {"ports": [{"name": "http", "nodePort": 31755, "port": 80, "protocol": "TCP"}, {"name": "https", "nodePort": 30333, "port": 443, "protocol": "TCP"}]}}'
    
    sleep 5
}

# Setup monitoring stack
setup_monitoring() {
    log_info "Setting up monitoring stack..."
    
    kubectl create namespace "$MONITORING_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    
    # Add Helm repos
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo add grafana https://grafana.github.io/helm-charts
    helm repo update
    
    # Install Prometheus
    log_success "Installing Prometheus..."
    helm upgrade --install prometheus prometheus-community/prometheus \
        --namespace "$MONITORING_NAMESPACE" \
        --set alertmanager.enabled=false \
        --set pushgateway.enabled=false \
        --hide-notes
    
    # Install Grafana
    log_success "Installing Grafana..."
    helm upgrade --install grafana grafana/grafana \
        --namespace "$MONITORING_NAMESPACE" \
        -f "$GRAFANA_VALUES" \
        --hide-notes
    
    # Apply Grafana Ingress if it exists
    if [[ -f "$GRAFANA_INGRESS" ]]; then
        log_warning "Applying Grafana Ingress..."
        kubectl apply -f "$GRAFANA_INGRESS"
    fi
}

# Setup Kagent
setup_kagent() {
    log_info "Setting up Kagent..."
    
    kubectl create namespace "$KAGENT_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    
    # Install CRDs
    log_success "Installing Kagent CRDs..."
    helm install kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
        --namespace "$KAGENT_NAMESPACE" \
        --create-namespace \
        --hide-notes
    
    # Grant cluster-admin permissions
    log_success "Granting Kagent cluster-admin permissions..."
    kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kagent-cluster-admin
subjects:
- kind: ServiceAccount
  name: kagent
  namespace: $KAGENT_NAMESPACE
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
EOF
    
    # Install Kagent
    log_success "Installing Kagent with $LLM_PROVIDER provider..."
    helm upgrade --install kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent \
        --namespace "$KAGENT_NAMESPACE" \
        -f "$KAGENT_VALUES" \
        --hide-notes
    
    # Create ModelConfig
    log_info "Creating ModelConfig for Ollama provider..."
    kubectl apply -f - <<EOF
apiVersion: kagent.dev/v1alpha1
kind: ModelConfig
metadata:
  name: default-model-config
  namespace: $KAGENT_NAMESPACE
spec:
  model: $LLM_MODEL
  ollama:
    host: host.docker.internal:11434
  provider: Ollama
EOF
}

# Test Ollama connectivity
test_ollama() {
    log_info "Testing Ollama connectivity..."
    
    kubectl create namespace "$DEMO_APP_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f "$OLLAMA_TEST_POD"
    
    log_warning "Waiting for Ollama test pod to be ready..."
    kubectl wait --namespace "$DEMO_APP_NAMESPACE" \
        --for=condition=Ready pod/ollama-test \
        --timeout=60s
    
    log_success "Running test query to Ollama..."
    kubectl exec -n "$DEMO_APP_NAMESPACE" ollama-test -- \
        curl -s -X POST http://host.docker.internal:11434/api/generate \
        -d "{\"model\": \"$LLM_MODEL\", \"prompt\": \"What is the capital of Sweden?\"}" \
        | jq -r 'select(.done==true) | .response'
}

# Setup ArgoCD
setup_argocd() {
    log_info "Setting up ArgoCD..."
    
    kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -n "$ARGOCD_NAMESPACE" -f "$ARGOCD_MANIFEST"
    
    log_warning "Waiting for ArgoCD pods to be ready..."
    sleep 20
    
    kubectl wait --namespace "$ARGOCD_NAMESPACE" \
        --for=condition=Ready pod \
        -l app.kubernetes.io/name=argocd-server \
        --timeout=300s || {
        log_warning "ArgoCD server pods not ready yet, continuing anyway..."
    }
    
    # Apply ArgoCD Application manifest
    log_info "Applying ArgoCD Application manifest..."
    kubectl apply -f "$ARGOCD_OBJECTS"
}

# Get ArgoCD password with retry logic
get_argocd_password() {
    log_warning "Retrieving ArgoCD admin password..."
    
    local max_retries=5
    local retry_count=0
    local argocd_pass=""
    
    while [[ $retry_count -lt $max_retries ]]; do
        argocd_pass=$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
            -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode || echo "")
        
        if [[ -n "$argocd_pass" ]]; then
            log_success "Successfully retrieved ArgoCD password."
            echo "$argocd_pass"
            return 0
        else
            ((retry_count++))
            if [[ $retry_count -lt $max_retries ]]; then
                log_warning "Waiting for ArgoCD secret (attempt $retry_count of $max_retries)..."
                sleep 10
            fi
        fi
    done
    
    log_warning "Could not retrieve ArgoCD password after $max_retries attempts."
    echo "<password not available yet>"
}

# Setup port forwarding
setup_port_forwarding() {
    log_success "Setting up port forwarding..."
    
    # ArgoCD port forwarding
    kubectl port-forward svc/argocd-server -n "$ARGOCD_NAMESPACE" 8080:443 &>/dev/null &
    local argocd_pid=$!
    
    # Kagent port forwarding
    kubectl port-forward svc/kagent -n "$KAGENT_NAMESPACE" 8083:80 &>/dev/null &
    local kagent_pid=$!
    
    sleep 2
    
    # Check if port forwarding is working
    if ps -p $argocd_pid > /dev/null; then
        log_success "ArgoCD port forwarding started successfully."
    else
        log_warning "ArgoCD port forwarding failed. Run manually:"
        log_info "kubectl port-forward svc/argocd-server -n \"$ARGOCD_NAMESPACE\" 8080:443"
    fi
    
    if ps -p $kagent_pid > /dev/null; then
        log_success "Kagent port forwarding started successfully."
    else
        log_warning "Kagent port forwarding failed. Run manually:"
        log_info "kubectl port-forward svc/kagent -n \"$KAGENT_NAMESPACE\" 8083:80"
    fi
}

# Print final information
print_final_info() {
    local argocd_pass
    argocd_pass=$(get_argocd_password)
    
    log_success "All done!"
    echo
    echo -e "Access URLs:"
    echo -e "  Demo App:    ${YELLOW}http://localhost:31755/ui${NC}"
    echo -e "  Grafana:     ${YELLOW}http://localhost:31755/grafana${NC} (admin/admin)"
    echo -e "  Kagent:      ${YELLOW}http://localhost:8083/${NC}"
    echo -e "  ArgoCD:      ${YELLOW}http://localhost:8080/${NC}"
    echo -e "  ArgoCD Pass: ${YELLOW}${argocd_pass}${NC}"
    echo
    echo -e "Current LLM: ${YELLOW}$LLM_PROVIDER${NC} with model: ${YELLOW}$LLM_MODEL${NC}"
    echo
    echo -e "To switch models:"
    echo -e "  ${YELLOW}./switch_model.sh <model_name>${NC}"
    echo -e "  ${YELLOW}./switch_model.sh mistral:7b${NC}"
    echo
    echo -e "To switch providers:"
    echo -e "  ${YELLOW}./switch_provider.sh <provider> <model> [api_key]${NC}"
    echo -e "  ${YELLOW}./switch_provider.sh anthropic claude-3-sonnet-20240229 <API_KEY>${NC}"
}

# Main execution flow
main() {
    log_info "Starting automated deployment..."
    
    check_dependencies
    setup_ollama
    create_cluster
    setup_ingress
    setup_monitoring
    setup_kagent
    test_ollama
    setup_argocd
    setup_port_forwarding
    print_final_info
}

# Run main function
main "$@"