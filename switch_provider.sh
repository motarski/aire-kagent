#!/bin/bash
# Switch between Ollama and Anthropic LLM providers in kagent
# Usage: ./switch_provider.sh <provider> <model>

set -e

# Determine the absolute path to the repository root
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common environment variables
source "$REPO_ROOT/.env"

# Configuration variables
readonly KAGENT_NAMESPACE="kagent"
readonly KAGENT_CONFIG_DIR="05_kagent"
readonly SUPPORTED_PROVIDERS=("ollama" "anthropic")

# Required tools
readonly REQUIRED_TOOLS=("kubectl" "jq")

# Global variables
PROVIDER=""
MODEL=""
MODEL_CONFIG_FILE=""

# Utility functions
log_info() {
    echo -e "${CYAN}$1${NC}"
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

# Show help message
show_help() {
    cat << EOF
Usage: $0 <provider> <model>

This script switches between Ollama and Anthropic LLM providers in kagent.

NOTE: For Anthropic provider, export ANTHROPIC_API_KEY environment variable first.

Examples:
  $0 ollama llama3.1
  export ANTHROPIC_API_KEY="sk-ant-api123..."
  $0 anthropic claude-sonnet-4-20250514

Available providers:
  - ollama      (No API key required, uses local models)
  - anthropic   (Requires ANTHROPIC_API_KEY environment variable)

Instructions:
1. Both Ollama and Anthropic can be used side by side in your cluster
2. Each agent can select which provider/model to use via the kagent UI
3. Access kagent UI: kubectl port-forward svc/kagent -n kagent 8083:80
EOF
}

# Parse command line arguments
parse_arguments() {
    if [[ $# -lt 2 ]]; then
        echo
        log_error "NOTE: Make sure you've exported ANTHROPIC_API_KEY=\"sk-ant-api123...\""
        log_error "...   if you are planning to switch to the Anthropic provider."
        echo
        show_help
        exit 1
    fi
    
    PROVIDER="$1"
    MODEL="$2"
}

# Validate provider
validate_provider() {
    log_info "Validating provider..."
    
    local valid_provider=false
    for supported in "${SUPPORTED_PROVIDERS[@]}"; do
        if [[ "$PROVIDER" == "$supported" ]]; then
            valid_provider=true
            break
        fi
    done
    
    if [[ "$valid_provider" == "false" ]]; then
        log_error "Error: This script only supports Ollama and Anthropic providers."
        log_error "Usage: $0 <ollama|anthropic> <model>"
        exit 1
    fi
    
    log_success "Provider '$PROVIDER' is supported."
}

# Check and install required dependencies
check_dependencies() {
    log_info "Checking required dependencies..."
    
    local missing_tools=()
    
    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! command_exists "$tool"; then
            missing_tools+=("$tool")
        fi
    done
    
    # Add provider-specific dependencies
    if [[ "$PROVIDER" == "ollama" ]] && ! command_exists ollama; then
        missing_tools+=("ollama")
    fi
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_error "Please install these tools and try again."
        exit 1
    fi
}

# Validate API key for Anthropic
validate_anthropic_key() {
    if [[ "$PROVIDER" == "anthropic" ]]; then
        log_info "Validating Anthropic API key..."
        
        if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
            log_error "Error: ANTHROPIC_API_KEY environment variable is not set."
            log_error "Please export your Anthropic API key before running this script:"
            log_error "export ANTHROPIC_API_KEY=\"your-api-key\""
            log_error "$0 anthropic $MODEL"
            exit 1
        fi
        
        log_success "Anthropic API key is set."
    fi
}

# Validate Ollama model
validate_ollama_model() {
    if [[ "$PROVIDER" == "ollama" ]]; then
        log_info "Checking Ollama model availability..."
        
        if ! command_exists ollama; then
            log_warning "Ollama command not found. Skipping model validation."
            return 0
        fi
        
        if ! ollama list 2>/dev/null | grep -q "$MODEL"; then
            log_warning "Model '$MODEL' not found in local Ollama."
            
            read -p "Would you like to pull this model now? (y/n): " pull_model
            if [[ "$pull_model" == "y" ]]; then
                log_info "Pulling model '$MODEL'..."
                if ollama pull "$MODEL"; then
                    log_success "Model '$MODEL' pulled successfully."
                else
                    log_error "Failed to pull model '$MODEL'."
                    exit 1
                fi
            else
                log_warning "Continuing without pulling the model. Make sure it's available before using it."
            fi
        else
            log_success "Model '$MODEL' is available locally."
        fi
    fi
}

# Set model config file path
set_model_config_file() {
    if [[ "$PROVIDER" == "anthropic" ]]; then
        MODEL_CONFIG_FILE="$KAGENT_CONFIG_DIR/${PROVIDER}-model-config.yaml"
    else
        MODEL_CONFIG_FILE="$KAGENT_CONFIG_DIR/default-model-config.yaml"
    fi
}

# Create model config file
create_model_config() {
    log_info "Creating $MODEL_CONFIG_FILE..."
    
    # Ensure directory exists
    mkdir -p "$KAGENT_CONFIG_DIR"
    
    if [[ "$PROVIDER" == "anthropic" ]]; then
        create_anthropic_config
    else
        create_ollama_config
    fi
    
    log_success "ModelConfig file created successfully."
}

# Create Anthropic model config
create_anthropic_config() {
    cat > "$MODEL_CONFIG_FILE" << EOF
apiVersion: kagent.dev/v1alpha1
kind: ModelConfig
metadata:
  name: ${PROVIDER}-model-config
  namespace: ${KAGENT_NAMESPACE}
spec:
  apiKeySecretRef: kagent-${PROVIDER}
  apiKeySecretKey: ANTHROPIC_API_KEY
  model: ${MODEL}
  provider: Anthropic
  anthropic: {}
EOF
}

# Create Ollama model config
create_ollama_config() {
    cat > "$MODEL_CONFIG_FILE" << EOF
apiVersion: kagent.dev/v1alpha1
kind: ModelConfig
metadata:
  name: default-model-config
  namespace: ${KAGENT_NAMESPACE}
spec:
  model: ${MODEL}
  provider: Ollama
  ollama:
    host: host.docker.internal:11434
EOF
}

# Check if Kubernetes cluster is available
check_kubernetes_cluster() {
    if kubectl get namespace "$KAGENT_NAMESPACE" >/dev/null 2>&1; then
        log_success "Kubernetes cluster with kagent detected."
        return 0
    else
        log_warning "No running Kubernetes cluster with kagent detected."
        return 1
    fi
}

# Create Anthropic API secret
create_anthropic_secret() {
    if [[ "$PROVIDER" == "anthropic" ]]; then
        log_info "Creating Anthropic API key secret..."
        
        if kubectl create secret generic "kagent-${PROVIDER}" \
            -n "$KAGENT_NAMESPACE" \
            --from-literal="ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}" \
            --dry-run=client -o yaml | kubectl apply -f -; then
            log_success "Anthropic API key secret created/updated successfully."
        else
            log_error "Failed to create Anthropic API key secret."
            exit 1
        fi
    fi
}

# Apply model config to cluster
apply_model_config() {
    log_info "Applying $PROVIDER ModelConfig..."
    
    if kubectl apply -f "$MODEL_CONFIG_FILE"; then
        log_success "$PROVIDER provider with model $MODEL has been added to the cluster."
        log_warning "You can now select this model in the kagent UI or via API calls."
    else
        log_error "Failed to apply ModelConfig to cluster."
        exit 1
    fi
}

# Setup provider in cluster
setup_provider_in_cluster() {
    create_anthropic_secret
    apply_model_config
    
    echo
    log_info "Access the kagent UI to use this model:"
    log_warning "kubectl port-forward svc/kagent -n $KAGENT_NAMESPACE 8083:80"
    log_warning "Then visit: http://localhost:8083"
}

# Print deployment instructions
print_deployment_instructions() {
    log_success "ModelConfig file created at $MODEL_CONFIG_FILE"
    log_info "To add this provider to your cluster, start your cluster and run:"
    
    if [[ "$PROVIDER" == "anthropic" ]]; then
        log_warning "kubectl create secret generic kagent-${PROVIDER} -n ${KAGENT_NAMESPACE} --from-literal=ANTHROPIC_API_KEY='${ANTHROPIC_API_KEY}'"
    fi
    
    log_warning "kubectl apply -f ${MODEL_CONFIG_FILE}"
    log_info "To deploy your cluster, run:"
    log_warning "./deploy_all.sh"
}

# Print usage instructions
print_usage_instructions() {
    echo
    log_info "Instructions for using multiple providers:"
    echo "1. Both Ollama and Anthropic can be used side by side in your cluster"
    echo "2. Each agent can select which provider/model to use via the kagent UI"
    echo "3. To use the kagent UI to select models:"
    log_warning "   kubectl port-forward svc/kagent -n $KAGENT_NAMESPACE 8083:80"
    log_warning "   Then visit: http://localhost:8083"
}

# Print final information
print_final_info() {
    local cluster_available="$1"
    
    if [[ "$cluster_available" == "true" ]]; then
        echo
        log_success "Services are available at:"
        echo -e "  Demo App:    ${YELLOW}http://localhost:31755/ui${NC}"
        echo -e "  Grafana:     ${YELLOW}http://localhost:31755/grafana${NC} (admin/admin)"
        echo -e "  Kagent:      ${YELLOW}http://localhost:8083/${NC}"
    fi
    
    print_usage_instructions
}

# Main execution flow
main() {
    parse_arguments "$@"
    validate_provider
    check_dependencies
    validate_anthropic_key
    validate_ollama_model
    
    log_info "Setting provider: ${YELLOW}$PROVIDER${NC} with model: ${YELLOW}$MODEL${NC}"
    
    set_model_config_file
    create_model_config
    
    local cluster_available="false"
    
    if check_kubernetes_cluster; then
        cluster_available="true"
        setup_provider_in_cluster
    else
        print_deployment_instructions
    fi
    
    print_final_info "$cluster_available"
}

# Run main function
main "$@"