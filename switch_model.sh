#!/bin/bash
# switch_model.sh - A script to easily switch Ollama LLM models across the framework
# Usage: ./switch_model.sh <model_name>
# Example: ./switch_model.sh llama3.1

set -e

# Color variables
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check if a model name was provided
if [ "$#" -ne 1 ]; then
    echo -e "${RED}Error: Please provide a model name.${NC}"
    echo -e "Usage: ${YELLOW}./switch_model.sh <model_name>${NC}"
    echo -e "Example: ${YELLOW}./switch_model.sh llama3.1${NC}"
    echo -e "\nAvailable models:"
    ollama list | grep -v "NAME" | awk '{print "  - " $1}'
    exit 1
fi

NEW_MODEL="$1"
KAGENT_NAMESPACE="kagent"

# Check if the model is available in Ollama
if ! ollama list | grep -q "$NEW_MODEL"; then
    echo -e "${YELLOW}Warning: Model '$NEW_MODEL' not found in local Ollama.${NC}"
    read -p "Would you like to pull this model now? (y/n): " PULL_MODEL
    if [[ "$PULL_MODEL" == "y" ]]; then
        echo -e "${BLUE}Pulling model '$NEW_MODEL'...${NC}"
        ollama pull "$NEW_MODEL"
    else
        echo -e "${YELLOW}Continuing without pulling the model. Make sure it's available before using it.${NC}"
    fi
fi

echo -e "${BLUE}Switching to model: ${YELLOW}$NEW_MODEL${NC}"

# Check if required files exist
if [ ! -f "05_kagent/values-ollama.yaml" ]; then
    echo -e "${RED}Error: values-ollama.yaml file not found!${NC}"
    exit 1
fi

if [ ! -f "deploy_all.sh" ]; then
    echo -e "${RED}Error: deploy_all.sh file not found!${NC}"
    exit 1
fi

if [ ! -f "04_ollama/ollama_api_call.sh" ]; then
    echo -e "${YELLOW}Warning: ollama_api_call.sh file not found. Skipping update.${NC}"
else
    # Check if ollama_api_call.sh has been updated to use parameters
    if grep -q "MODEL=" 04_ollama/ollama_api_call.sh; then
        echo -e "${BLUE}ollama_api_call.sh already uses parameters, no update needed.${NC}"
    else
        # Update ollama_api_call.sh - old format
        echo -e "${BLUE}Updating ollama_api_call.sh...${NC}"
        sed -i '' "s/\"model\": \".*\"/\"model\": \"$NEW_MODEL\"/" 04_ollama/ollama_api_call.sh
    fi
fi

# Update values-ollama.yaml file
echo -e "${BLUE}Updating values-ollama.yaml...${NC}"
sed -i '' "s/model: \".*\"/model: \"$NEW_MODEL\"/" 05_kagent/values-ollama.yaml

# Update deploy_all.sh
echo -e "${BLUE}Updating deploy_all.sh...${NC}"
sed -i '' "s/OLLAMA_MODEL=\".*\"/OLLAMA_MODEL=\"$NEW_MODEL\"  # Updated model/" deploy_all.sh
# Check if the API call line exists in deploy_all.sh
if grep -q "{\"model\":" deploy_all.sh; then
    sed -i '' "s/{\"model\": \".*\", \"prompt\"/{\"model\": \"$NEW_MODEL\", \"prompt\"/" deploy_all.sh
else
    echo -e "${YELLOW}Warning: Could not find API call line in deploy_all.sh. Manual update may be required.${NC}"
fi

# Check if we should update the running deployment
if kubectl get namespace "$KAGENT_NAMESPACE" &>/dev/null; then
    echo -e "${BLUE}Kubernetes cluster with kagent detected.${NC}"
    read -p "Do you want to update the running deployment with the new model? (y/n): " UPDATE_DEPLOYMENT
    
    if [[ "$UPDATE_DEPLOYMENT" == "y" ]]; then
        # Apply changes to the running deployment
        echo -e "${YELLOW}Updating kagent deployment...${NC}"
        kubectl -n "$KAGENT_NAMESPACE" delete configmap kagent-config || true
        kubectl -n "$KAGENT_NAMESPACE" create configmap kagent-config --from-file=values.yaml=05_kagent/values-ollama.yaml
        
        # Update all ModelConfig objects that use Ollama provider
        echo -e "${YELLOW}Updating ModelConfig objects with new model...${NC}"
        
        # First, check and update the default ModelConfig
        if kubectl get modelconfig -n "$KAGENT_NAMESPACE" default-model-config &>/dev/null; then
            kubectl patch modelconfig -n "$KAGENT_NAMESPACE" default-model-config --type=merge -p "{\"spec\":{\"model\":\"$NEW_MODEL\"}}"
            echo -e "${GREEN}Default ModelConfig updated successfully.${NC}"
        else
            echo -e "${YELLOW}ModelConfig 'default-model-config' not found. Skipping update.${NC}"
        fi
        
        # Find all other ModelConfig objects that use Ollama
        echo -e "${BLUE}Checking for additional Ollama-based ModelConfig objects...${NC}"
        OLLAMA_CONFIGS=$(kubectl get modelconfig -n "$KAGENT_NAMESPACE" -o json | jq -r '.items[] | select(.spec.provider == "Ollama" and .metadata.name != "default-model-config") | .metadata.name')
        
        if [ -n "$OLLAMA_CONFIGS" ]; then
            echo -e "${BLUE}Found additional ModelConfig objects using Ollama provider:${NC}"
            echo "$OLLAMA_CONFIGS"
            for CONFIG in $OLLAMA_CONFIGS; do
                echo -e "${YELLOW}Updating ModelConfig '$CONFIG'...${NC}"
                kubectl patch modelconfig -n "$KAGENT_NAMESPACE" "$CONFIG" --type=merge -p "{\"spec\":{\"model\":\"$NEW_MODEL\"}}"
                echo -e "${GREEN}ModelConfig '$CONFIG' updated successfully.${NC}"
            done
        else
            echo -e "${BLUE}No additional Ollama-based ModelConfig objects found.${NC}"
        fi
        
        # Find and restart kagent pods to pick up the new config
        echo -e "${YELLOW}Restarting kagent pods to apply new model...${NC}"
        kubectl -n "$KAGENT_NAMESPACE" rollout restart deployment kagent
        
        echo -e "${GREEN}Waiting for kagent to restart...${NC}"
        kubectl -n "$KAGENT_NAMESPACE" rollout status deployment kagent --timeout=60s
        
        # Restart port-forwarding for services
        echo -e "${BLUE}Restarting port-forwarding for services...${NC}"
        
        # Check if port-forwarding processes are running and kill them if they are
        echo -e "${YELLOW}Stopping existing port-forwards if any...${NC}"
        pkill -f "kubectl port-forward svc/argocd-server" || true
        pkill -f "kubectl port-forward svc/kagent" || true
        sleep 2
        
        # Start new port-forwarding
        echo -e "${GREEN}Starting new port-forwards...${NC}"
        
        # Check if ArgoCD is installed before port-forwarding
        if kubectl get namespace argocd &>/dev/null; then
            kubectl port-forward svc/argocd-server -n argocd 8080:443 &
        else
            echo -e "${YELLOW}ArgoCD not found, skipping port-forward.${NC}"
        fi
        
        kubectl port-forward svc/kagent -n "$KAGENT_NAMESPACE" 8083:80 &
        
        echo -e "${GREEN}Model updated successfully in running deployment.${NC}"
        echo -e "\n${BLUE}=== Testing the new model with a quick question ===${NC}"
        ./04_ollama/ollama_api_call.sh "$NEW_MODEL" "What is the capital of Sweden?"
    else
        echo -e "${YELLOW}Changes applied to configuration files only.${NC}"
        echo -e "${BLUE}To deploy these changes, run:${NC}"
        echo -e "${YELLOW}helm upgrade kagent 05_kagent/kagent -n $KAGENT_NAMESPACE --values 05_kagent/values-ollama.yaml${NC}"
    fi
else
    echo -e "${YELLOW}No running Kubernetes cluster with kagent detected.${NC}"
    echo -e "${GREEN}Configuration files updated successfully.${NC}"
    echo -e "${BLUE}To deploy with the new model, run:${NC}"
    echo -e "${YELLOW}./deploy_all.sh${NC}"
fi

# Verify model switch with a direct test if Ollama server is running
if curl -s http://localhost:11434/api/tags &>/dev/null; then
    # Only run local test if we haven't already done so as part of deployment update
    if [[ "${UPDATE_DEPLOYMENT:-}" != "y" ]]; then
        echo -e "\n${BLUE}=== Testing model switch with the new model ===${NC}"
        ./04_ollama/ollama_api_call.sh "$NEW_MODEL" "Say hello!"
    fi
    
    # Check if pods can access the model (if cluster exists)
    if kubectl get namespace demo-app &>/dev/null && kubectl get pod -n demo-app ollama-test &>/dev/null; then
        echo -e "\n${BLUE}=== Testing model accessibility from the cluster ===${NC}"
        echo -e "${YELLOW}Response from cluster test:${NC}"
        CLUSTER_RESPONSE=$(kubectl exec -n demo-app ollama-test -- curl -s -X POST http://host.docker.internal:11434/api/generate -d "{\"model\": \"$NEW_MODEL\", \"prompt\": \"Say hello!\", \"stream\": false}" | jq -r '.response')
        echo "$CLUSTER_RESPONSE"
    fi
else
    echo -e "${YELLOW}Ollama server not running or not accessible. Can't verify model switch.${NC}"
    echo -e "${BLUE}Start Ollama server with 'ollama serve' to use the model.${NC}"
fi

echo -e "\n${GREEN}=== Model switch completed! ===${NC}"

# Display access information if we updated the running deployment
if [[ "${UPDATE_DEPLOYMENT:-}" == "y" ]]; then
    echo -e "${GREEN}Services are available at:${NC}"
    echo -e "You can access your app at: ${YELLOW}http://localhost:31755/ui${NC}"
    echo -e "You can access Grafana at: ${YELLOW}http://localhost:31755/grafana (admin/admin)${NC}"
    echo -e "You can access kagent at: ${YELLOW}http://localhost:8083/${NC}"
    echo -e "You can access ArgoCD at: ${YELLOW}http://localhost:8080/${NC}"
fi
