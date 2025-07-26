#!/bin/bash
# Switch Ollama LLM models across the framework
# Usage: ./switch_model.sh <model_name>

set -e

# Determine the absolute path to the repository root
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common environment variables
source "$REPO_ROOT/.env"

# Configuration variables
readonly KAGENT_NAMESPACE="kagent"
readonly OLLAMA_TEST_SCRIPT="04_ollama/ollama_api_call.sh"
readonly VALUES_FILE="05_kagent/values-ollama.yaml"

# Required tools
readonly REQUIRED_TOOLS=("kubectl" "jq" "ollama")

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
Usage: $0 <model_name>

This script switches the Ollama LLM model across the framework.

Examples:
  $0 llama3.1
  $0 mistral:7b
  $0 codellama

Available models:
EOF
    if command_exists ollama; then
        ollama list 2>/dev/null | grep -v "NAME" | awk '{print "  - " $1}' || echo "  No models found or Ollama not accessible"
    else
        echo "  Ollama not installed"
    fi
}

# Parse command line arguments
parse_arguments() {
    if [[ $# -ne 1 ]]; then
        log_error "Please provide a model"
        echo
        show_help
        exit 1
    fi
    
    NEW_MODEL="$1"
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
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_error "Please install these tools and try again."
        exit 1
    fi
}

# Check if Ollama model is available
check_model_availability() {
    log_info "Checking model availability..."
    
    if ! ollama list 2>/dev/null | grep -q "$NEW_MODEL"; then
        log_warning "Model '$NEW_MODEL' not found in local Ollama."
        
        read -p "Would you like to pull this model now? (y/n): " pull_model
        if [[ "$pull_model" == "y" ]]; then
            log_info "Pulling model '$NEW_MODEL'..."
            if ollama pull "$NEW_MODEL"; then
                log_success "Model '$NEW_MODEL' pulled successfully."
            else
                log_error "Failed to pull model '$NEW_MODEL'."
                exit 1
            fi
        else
            log_warning "Continuing without pulling the model. Make sure it's available before using it."
        fi
    else
        log_success "Model '$NEW_MODEL' is available locally."
    fi
}

# Validate required files
validate_files() {
    log_info "Validating required files..."
    
    if [[ ! -f "$VALUES_FILE" ]]; then
        log_error "Error: $VALUES_FILE file not found!"
        log_error "Please ensure you're running this script from the correct directory."
        exit 1
    fi
    
    log_success "Required files validated."
}

# Update configuration files
update_config_files() {
    log_info "Updating configuration files..."
    
    # Update values-ollama.yaml file
    log_info "Updating $VALUES_FILE..."
    if sed -i.bak "s/model: \".*\"/model: \"$NEW_MODEL\"/" "$VALUES_FILE"; then
        rm -f "${VALUES_FILE}.bak"
        log_success "Configuration file updated successfully."
    else
        log_error "Failed to update configuration file."
        exit 1
    fi
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

# Update ModelConfig objects
update_model_configs() {
    log_info "Updating ModelConfig objects with new model..."
    
    # Update the default ModelConfig
    if kubectl get modelconfig -n "$KAGENT_NAMESPACE" default-model-config >/dev/null 2>&1; then
        kubectl patch modelconfig -n "$KAGENT_NAMESPACE" default-model-config \
            --type=merge -p "{\"spec\":{\"model\":\"$NEW_MODEL\"}}"
        log_success "Default ModelConfig updated successfully."
    else
        log_warning "ModelConfig 'default-model-config' not found. Skipping update."
    fi
    
    # Find and update other Ollama-based ModelConfig objects
    log_info "Checking for additional Ollama-based ModelConfig objects..."
    local ollama_configs
    ollama_configs=$(kubectl get modelconfig -n "$KAGENT_NAMESPACE" -o json 2>/dev/null | \
        jq -r '.items[] | select(.spec.provider == "Ollama" and .metadata.name != "default-model-config") | .metadata.name' || echo "")
    
    if [[ -n "$ollama_configs" ]]; then
        log_info "Found additional ModelConfig objects using Ollama provider:"
        echo "$ollama_configs" | sed 's/^/  - /'
        
        while IFS= read -r config; do
            if [[ -n "$config" ]]; then
                log_info "Updating ModelConfig '$config'..."
                kubectl patch modelconfig -n "$KAGENT_NAMESPACE" "$config" \
                    --type=merge -p "{\"spec\":{\"model\":\"$NEW_MODEL\"}}"
                log_success "ModelConfig '$config' updated successfully."
            fi
        done <<< "$ollama_configs"
    else
        log_info "No additional Ollama-based ModelConfig objects found."
    fi
}

# Restart kagent deployment
restart_kagent() {
    log_info "Restarting kagent pods to apply new model..."
    
    if kubectl rollout restart deployment kagent -n "$KAGENT_NAMESPACE"; then
        log_success "Kagent deployment restart initiated."
        
        log_info "Waiting for kagent to restart..."
        if kubectl rollout status deployment kagent -n "$KAGENT_NAMESPACE" --timeout=60s; then
            log_success "Kagent deployment restarted successfully."
        else
            log_warning "Kagent deployment restart timed out, but may still be in progress."
        fi
    else
        log_error "Failed to restart kagent deployment."
        exit 1
    fi
}

# Restart port forwarding
restart_port_forwarding() {
    log_info "Restarting port-forwarding for services..."
    
    # Stop existing port-forwards
    log_info "Stopping existing port-forwards if any..."
    pkill -f "kubectl port-forward svc/argocd-server" 2>/dev/null || true
    pkill -f "kubectl port-forward svc/kagent" 2>/dev/null || true
    sleep 2
    
    # Start new port-forwarding
    log_success "Starting new port-forwards..."
    
    # Check if ArgoCD is installed before port-forwarding
    if kubectl get namespace argocd >/dev/null 2>&1; then
        kubectl port-forward svc/argocd-server -n argocd 8080:443 >/dev/null 2>&1 &
        log_success "ArgoCD port-forward started on port 8080."
    else
        log_warning "ArgoCD not found, skipping port-forward."
    fi
    
    kubectl port-forward svc/kagent -n "$KAGENT_NAMESPACE" 8083:80 >/dev/null 2>&1 &
    log_success "Kagent port-forward started on port 8083."
}

# Update running deployment
update_running_deployment() {
    read -p "Do you want to update the running deployment with the new model? (y/n): " update_deployment
    
    if [[ "$update_deployment" == "y" ]]; then
        update_model_configs
        restart_kagent
        restart_port_forwarding
        
        log_success "Model updated successfully in running deployment."
        return 0
    else
        log_warning "Changes applied to configuration files only."
        log_info "To deploy these changes, run:"
        log_info "helm upgrade kagent 05_kagent/kagent -n $KAGENT_NAMESPACE --values $VALUES_FILE"
        return 1
    fi
}

# Test model locally
test_model_locally() {
    if [[ ! -f "$OLLAMA_TEST_SCRIPT" ]]; then
        log_warning "Test script not found at $OLLAMA_TEST_SCRIPT"
        return 1
    fi
    
    log_info "Testing the new model with a quick question"
    if "$OLLAMA_TEST_SCRIPT" "$NEW_MODEL" "What is the capital of Sweden?"; then
        log_success "Local model test completed."
    else
        log_warning "Local model test failed or incomplete."
    fi
}

# Test model from cluster
test_model_cluster() {
    if ! kubectl get namespace demo-app >/dev/null 2>&1 || ! kubectl get pod -n demo-app ollama-test >/dev/null 2>&1; then
        log_warning "Demo app test pod not available for cluster testing."
        return 1
    fi
    
    log_info "Testing model accessibility from the cluster"
    local cluster_response
    cluster_response=$(kubectl exec -n demo-app ollama-test -- \
        curl -s -X POST http://host.docker.internal:11434/api/generate \
        -d "{\"model\": \"$NEW_MODEL\", \"prompt\": \"Say hello!\", \"stream\": false}" 2>/dev/null | \
        jq -r '.response' 2>/dev/null || echo "Test failed")
    
    if [[ "$cluster_response" != "Test failed" && -n "$cluster_response" ]]; then
        log_success "Cluster test response:"
        echo "  $cluster_response"
    else
        log_warning "Cluster model test failed or returned empty response."
    fi
}

# Check Ollama server accessibility
check_ollama_server() {
    if curl -s http://localhost:11434/api/tags >/dev/null 2>&1; then
        return 0
    else
        log_warning "Ollama server not running or not accessible."
        log_info "Start Ollama server with 'ollama serve' to use the model."
        return 1
    fi
}

# Print final information
print_final_info() {
    local deployment_updated="$1"
    
    echo
    log_success "Model switch completed!"
    
    if [[ "$deployment_updated" == "true" ]]; then
        echo
        log_success "Services are available at:"
        echo -e "  Demo App:    ${YELLOW}http://localhost:31755/ui${NC}"
        echo -e "  Grafana:     ${YELLOW}http://localhost:31755/grafana${NC} (admin/admin)"
        echo -e "  Kagent:      ${YELLOW}http://localhost:8083/${NC}"
        echo -e "  ArgoCD:      ${YELLOW}http://localhost:8080/${NC}"
    else
        log_info "Configuration files updated for model: $NEW_MODEL"
        log_info "Deploy with: ./deploy_all.sh"
    fi
}

# Main execution flow
main() {
    parse_arguments "$@"
    check_dependencies
    
    log_info "Switching to model: ${YELLOW}$NEW_MODEL${NC}"
    
    check_model_availability
    validate_files
    update_config_files
    
    local deployment_updated="false"
    
    if check_kubernetes_cluster; then
        if update_running_deployment; then
            deployment_updated="true"
        fi
    else
        log_success "Configuration files updated successfully."
        log_info "To deploy a cluster with this model, run ./deploy_all.sh"
    fi
    
    # Test the model if Ollama server is accessible
    if check_ollama_server; then
        # Only test locally if we haven't already tested as part of deployment update
        if [[ "$deployment_updated" != "true" ]]; then
            test_model_locally
        fi
        
        # Test cluster access if available
        if [[ "$deployment_updated" == "true" ]]; then
            test_model_cluster
        fi
    fi
    
    print_final_info "$deployment_updated"
}

# Run main function
main "$@"