#!/bin/bash
# switch_provider.sh - A script to switch between Ollama and Anthropic LLM providers in kagent
# Usage: ./switch_provider.sh <provider> <model>
# For Anthropic provider, export ANTHROPIC_API_KEY environment variable first
# Examples: 
#   ./switch_provider.sh ollama llama3.1
#   export ANTHROPIC_API_KEY="sk-ant-api123..."
#   ./switch_provider.sh anthropic claude-sonnet-4-20250514

set -e

# Color variables
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check if provider and model were provided
if [ "$#" -lt 2 ]; then
    echo -e "\n${RED}NOTE:${NC} Make sure you've exported ANTHROPIC_API_KEY=\"sk-ant-api123...\""
    echo -e "...   if you are planning to switch to the Anthropic provider.\n${NC}"
    echo -e "Usage: ${BLUE}./switch_provider.sh <provider> <model>${NC}"
    echo -e "Examples: "
    echo -e "  ${YELLOW}./switch_provider.sh ollama llama3.1${NC}"
    echo -e "  ${YELLOW}./switch_provider.sh anthropic claude-sonnet-4-20250514${NC}"
    echo -e "\nAvailable providers:"
    echo -e "  - ollama (No API key required, uses local models)"
    echo -e "  - anthropic (Requires ANTHROPIC_API_KEY environment variable)"
    exit 1
fi

PROVIDER="$1"
MODEL="$2"
KAGENT_NAMESPACE="kagent"

# Only supports Ollama and Anthropic
if [[ "$PROVIDER" != "ollama" && "$PROVIDER" != "anthropic" ]]; then
    echo -e "${RED}Error: This script only supports Ollama and Anthropic providers.${NC}"
    echo -e "Usage: ${YELLOW}./switch_provider.sh <ollama|anthropic> <model>${NC}"
    exit 1
fi

# Check if API key environment variable is set for Anthropic
if [ "$PROVIDER" == "anthropic" ]; then
    if [ -z "${ANTHROPIC_API_KEY}" ]; then
        echo -e "${RED}Error: ANTHROPIC_API_KEY environment variable is not set.${NC}"
        echo -e "Please export your Anthropic API key before running this script:${NC}"
        echo -e "${YELLOW}export ANTHROPIC_API_KEY=\"your-api-key\"${NC}"
        echo -e "${YELLOW}./switch_provider.sh anthropic $MODEL${NC}"
        exit 1
    fi
fi

echo -e "${BLUE}Setting provider: ${YELLOW}$PROVIDER${NC} with model: ${YELLOW}$MODEL${NC}"

# Create the model config YAML file
if [ "$PROVIDER" == "anthropic" ]; then
    MODEL_CONFIG_FILE="05_kagent/${PROVIDER}-model-config.yaml"
else
    MODEL_CONFIG_FILE="05_kagent/default-model-config.yaml"
fi

echo -e "${BLUE}Creating $MODEL_CONFIG_FILE...${NC}"

# Create provider-specific model config
if [ "$PROVIDER" == "anthropic" ]; then
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
else
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
fi

# Check if a Kubernetes cluster with kagent is running
if kubectl get namespace "$KAGENT_NAMESPACE" &>/dev/null; then
    echo -e "${BLUE}Kubernetes cluster with kagent detected.${NC}"
    
    # Handle provider-specific setup
    if [ "$PROVIDER" == "anthropic" ]; then
        # Create the API key secret for Anthropic
        echo -e "${BLUE}Creating Anthropic API key secret...${NC}"
        kubectl create secret generic "kagent-${PROVIDER}" \
            -n "$KAGENT_NAMESPACE" \
            --from-literal="ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}" \
            --dry-run=client -o yaml | kubectl apply -f -
    else
        # Check if the Ollama model is available
        if ! ollama list | grep -q "$MODEL"; then
            echo -e "${YELLOW}Warning: Model '$MODEL' not found in local Ollama.${NC}"
            read -p "Would you like to pull this model now? (y/n): " PULL_MODEL
            if [[ "$PULL_MODEL" == "y" ]]; then
                echo -e "${BLUE}Pulling model '$MODEL'...${NC}"
                ollama pull "$MODEL"
            else
                echo -e "${YELLOW}Continuing without pulling the model. Make sure it's available before using it.${NC}"
            fi
        fi
    fi
    
    # Apply the ModelConfig
    echo -e "${BLUE}Applying ${PROVIDER} ModelConfig...${NC}"
    kubectl apply -f "$MODEL_CONFIG_FILE"
    
    echo -e "${GREEN}${PROVIDER} provider with model ${MODEL} has been added to the cluster.${NC}"
    echo -e "${YELLOW}You can now select this model in the kagent UI or via API calls.${NC}"
    
    # Provide instructions for accessing the UI
    echo -e "\n${BLUE}Access the kagent UI to use this model:${NC}"
    echo -e "${YELLOW}kubectl port-forward svc/kagent -n $KAGENT_NAMESPACE 8083:80${NC}"
    echo -e "Then visit: ${YELLOW}http://localhost:8083${NC}"
else
    echo -e "${YELLOW}No running Kubernetes cluster with kagent detected.${NC}"
    echo -e "${GREEN}ModelConfig file created at ${MODEL_CONFIG_FILE}${NC}"
    echo -e "${BLUE}To add this provider to your cluster, start your cluster and run:${NC}"
    
    if [ "$PROVIDER" == "anthropic" ]; then
        echo -e "${YELLOW}kubectl create secret generic kagent-${PROVIDER} -n ${KAGENT_NAMESPACE} --from-literal=ANTHROPIC_API_KEY='${ANTHROPIC_API_KEY}'${NC}"
    fi
    
    echo -e "${YELLOW}kubectl apply -f ${MODEL_CONFIG_FILE}${NC}"
    echo -e "${BLUE}To deploy your cluster, run:${NC}"
    echo -e "${YELLOW}./deploy_all.sh${NC}"
fi

echo -e "\n${BLUE}Instructions for using multiple providers:${NC}"
echo -e "1. Both Ollama and Anthropic can be used side by side in your cluster"
echo -e "2. Each agent can select which provider/model to use via the kagent UI"
echo -e "3. To use the kagent UI to select models:"
echo -e "   ${YELLOW}kubectl port-forward svc/kagent -n $KAGENT_NAMESPACE 8083:80${NC} &"
echo -e "   Then visit: ${YELLOW}http://localhost:8083${NC}"

# Display services if in running cluster
if kubectl get namespace "$KAGENT_NAMESPACE" &>/dev/null; then
    echo -e "\n${GREEN}Services are available at:${NC}"
    echo -e "You can access the application UI at: ${YELLOW}http://localhost:31755/ui${NC}"
    echo -e "You can access Grafana at: ${YELLOW}http://localhost:31755/grafana (admin/admin)${NC}"
fi
