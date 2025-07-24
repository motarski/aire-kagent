#!/bin/bash
# switch_provider.sh - A script to easily switch between LLM providers across the framework
# Usage: ./switch_provider.sh <provider> <model> [api_key]
# Examples: 
#   ./switch_provider.sh ollama llama3.1
#   ./switch_provider.sh anthropic claude-3-sonnet-20240229 sk-ant-api123...

set -e

# Color variables
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check if provider and model were provided
if [ "$#" -lt 2 ]; then
    echo -e "${RED}Error: Please provide a provider and model name.${NC}"
    echo -e "Usage: ${YELLOW}./switch_provider.sh <provider> <model> [api_key]${NC}"
    echo -e "Examples: "
    echo -e "  ${YELLOW}./switch_provider.sh ollama llama3.1${NC}"
    echo -e "  ${YELLOW}./switch_provider.sh anthropic claude-3-sonnet-20240229 sk-ant-api123...${NC}"
    echo -e "\nAvailable Ollama models:"
    ollama list | grep -v "NAME" | awk '{print "  - " $1}'
    echo -e "\nAvailable providers:"
    echo -e "  - ollama (No API key required, uses local models)"
    echo -e "  - anthropic (Requires API key)"
    echo -e "  - openAI (Requires API key)"
    echo -e "  - azureOpenAI (Requires API key and configuration)"
    exit 1
fi

PROVIDER="$1"
MODEL="$2"
API_KEY="$3"
KAGENT_NAMESPACE="kagent"

# Validate provider
case "$PROVIDER" in
    "ollama")
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
        ;;
    "anthropic"|"openAI"|"azureOpenAI")
        # Check if API key is provided for API-based providers
        if [ -z "$API_KEY" ]; then
            echo -e "${RED}Error: API key is required for $PROVIDER.${NC}"
            echo -e "Usage: ${YELLOW}./switch_provider.sh $PROVIDER $MODEL <api_key>${NC}"
            exit 1
        fi
        ;;
    *)
        echo -e "${RED}Error: Invalid provider '$PROVIDER'.${NC}"
        echo -e "Available providers: ollama, anthropic, openAI, azureOpenAI"
        exit 1
        ;;
esac

echo -e "${BLUE}Switching to provider: ${YELLOW}$PROVIDER${NC} with model: ${YELLOW}$MODEL${NC}"

# Create values file for the provider
VALUES_FILE="05_kagent/values-${PROVIDER}.yaml"

echo -e "${BLUE}Creating/updating $VALUES_FILE...${NC}"

# Create values file based on provider
case "$PROVIDER" in
    "ollama")
        cat > "$VALUES_FILE" << EOF
providers:
  default: ollama
  ollama:
    provider: Ollama
    model: "$MODEL"
    config:
      host: host.docker.internal:11434

# Add a dummy OpenAI API key for the tools-server
# openAI:
#   apiKey: "dummy-value-for-tools-server"

k8s-agent:
  enabled: true

kgateway-agent:
  enabled: true

istio-agent:
  enabled: false

promql-agent:
  enabled: true

observability-agent:
  enabled: true

argo-rollouts-agent:
  enabled: false

helm-agent:
  enabled: false

cilium-policy-agent:
  enabled: false

cilium-manager-agent:
  enabled: false

cilium-debug-agent:
  enabled: false
EOF
        ;;
    "anthropic")
        cat > "$VALUES_FILE" << EOF
providers:
  default: anthropic
  anthropic:
    provider: Anthropic
    model: "$MODEL"
    apiKey: "$API_KEY"

k8s-agent:
  enabled: true

kgateway-agent:
  enabled: true

istio-agent:
  enabled: false

promql-agent:
  enabled: true

observability-agent:
  enabled: true

argo-rollouts-agent:
  enabled: false

helm-agent:
  enabled: false

cilium-policy-agent:
  enabled: false

cilium-manager-agent:
  enabled: false

cilium-debug-agent:
  enabled: false
EOF
        ;;
    "openAI")
        cat > "$VALUES_FILE" << EOF
providers:
  default: openAI
  openAI:
    provider: OpenAI
    model: "$MODEL"
    apiKey: "$API_KEY"

k8s-agent:
  enabled: true

kgateway-agent:
  enabled: true

istio-agent:
  enabled: false

promql-agent:
  enabled: true

observability-agent:
  enabled: true

argo-rollouts-agent:
  enabled: false

helm-agent:
  enabled: false

cilium-policy-agent:
  enabled: false

cilium-manager-agent:
  enabled: false

cilium-debug-agent:
  enabled: false
EOF
        ;;
    "azureOpenAI")
        cat > "$VALUES_FILE" << EOF
providers:
  default: azureOpenAI
  azureOpenAI:
    provider: AzureOpenAI
    model: "$MODEL"
    apiKey: "$API_KEY"
    config:
      apiVersion: "2023-05-15"
      azureDeployment: "your-deployment-name"
      azureEndpoint: "https://your-endpoint.openai.azure.com"

k8s-agent:
  enabled: true

kgateway-agent:
  enabled: true

istio-agent:
  enabled: false

promql-agent:
  enabled: true

observability-agent:
  enabled: true

argo-rollouts-agent:
  enabled: false

helm-agent:
  enabled: false

cilium-policy-agent:
  enabled: false

cilium-manager-agent:
  enabled: false

cilium-debug-agent:
  enabled: false
EOF
        echo -e "${YELLOW}Note: For Azure OpenAI, you need to manually update the deployment name and endpoint in $VALUES_FILE${NC}"
        ;;
esac

# Update deploy_all.sh for Ollama
if [ "$PROVIDER" == "ollama" ]; then
    echo -e "${BLUE}Updating deploy_all.sh for Ollama model...${NC}"
    if [ -f "deploy_all.sh" ]; then
        # Update the OLLAMA_MODEL variable
        sed -i '' "s/OLLAMA_MODEL=\".*\"/OLLAMA_MODEL=\"$MODEL\"  # Updated model/" deploy_all.sh
        
        # Update the API call if it exists
        if grep -q "{\"model\":" deploy_all.sh; then
            sed -i '' "s/{\"model\": \".*\", \"prompt\"/{\"model\": \"$MODEL\", \"prompt\"/" deploy_all.sh
        else
            echo -e "${YELLOW}Warning: Could not find API call line in deploy_all.sh. Manual update may be required.${NC}"
        fi
    else
        echo -e "${YELLOW}Warning: deploy_all.sh not found. Skipping update.${NC}"
    fi
    
    # Update ollama_api_call.sh
    if [ -f "04_ollama/ollama_api_call.sh" ]; then
        echo -e "${BLUE}Updating ollama_api_call.sh...${NC}"
        sed -i '' "s/\"model\": \".*\"/\"model\": \"$MODEL\"/" 04_ollama/ollama_api_call.sh
    else
        echo -e "${YELLOW}Warning: ollama_api_call.sh not found. Skipping update.${NC}"
    fi
else
    echo -e "${YELLOW}Note: Using $PROVIDER provider. Some Ollama-specific files were not updated.${NC}"
fi

# Check if we should update the running deployment
if kubectl get namespace "$KAGENT_NAMESPACE" &>/dev/null; then
    echo -e "${BLUE}Kubernetes cluster with kagent detected.${NC}"
    read -p "Do you want to update the running deployment with the new provider/model? (y/n): " UPDATE_DEPLOYMENT
    
    if [[ "$UPDATE_DEPLOYMENT" == "y" ]]; then
        # Apply changes to the running deployment
        echo -e "${YELLOW}Updating kagent deployment...${NC}"
        
        # Create or update provider-specific secret if needed
        if [ "$PROVIDER" != "ollama" ] && [ -n "$API_KEY" ]; then
            echo -e "${BLUE}Creating/updating $PROVIDER API key secret...${NC}"
            
            SECRET_NAME="kagent-$PROVIDER"
            SECRET_KEY="${PROVIDER^^}_API_KEY"
            
            # Convert to uppercase for environment variable names
            if [ "$PROVIDER" == "openAI" ]; then
                SECRET_NAME="kagent-openai"
                SECRET_KEY="OPENAI_API_KEY"
            elif [ "$PROVIDER" == "azureOpenAI" ]; then
                SECRET_NAME="kagent-azure-openai"
                SECRET_KEY="AZUREOPENAI_API_KEY"
            fi
            
            # Create or update the secret
            kubectl create secret generic "$SECRET_NAME" \
                -n "$KAGENT_NAMESPACE" \
                --from-literal="$SECRET_KEY=$API_KEY" \
                --dry-run=client -o yaml | kubectl apply -f -
                
            echo -e "${GREEN}Secret $SECRET_NAME created/updated.${NC}"
        fi
        
        # Create/update the configmap
        kubectl -n "$KAGENT_NAMESPACE" delete configmap kagent-config || true
        kubectl -n "$KAGENT_NAMESPACE" create configmap kagent-config --from-file=values.yaml="$VALUES_FILE"
        
        # Update ModelConfig or create a new one for the provider
        if [ "$PROVIDER" == "ollama" ]; then
            # Update existing Ollama ModelConfig
            echo -e "${YELLOW}Updating Ollama ModelConfig objects...${NC}"
            if kubectl get modelconfig -n "$KAGENT_NAMESPACE" default-model-config &>/dev/null; then
                kubectl patch modelconfig -n "$KAGENT_NAMESPACE" default-model-config --type=merge -p "{\"spec\":{\"model\":\"$MODEL\"}}"
                echo -e "${GREEN}Default ModelConfig updated successfully.${NC}"
            else
                echo -e "${YELLOW}Creating new default-model-config for Ollama...${NC}"
                cat << EOF | kubectl apply -f -
apiVersion: kagent.dev/v1alpha1
kind: ModelConfig
metadata:
  name: default-model-config
  namespace: $KAGENT_NAMESPACE
spec:
  model: $MODEL
  ollama:
    host: host.docker.internal:11434
  provider: Ollama
EOF
            fi
        else
            # Create a new ModelConfig for the provider if it doesn't exist
            echo -e "${YELLOW}Updating ModelConfig for $PROVIDER...${NC}"
            
            # Check if provider-specific ModelConfig exists
            if kubectl get modelconfig -n "$KAGENT_NAMESPACE" "$PROVIDER-model-config" &>/dev/null; then
                echo -e "${BLUE}Updating existing $PROVIDER-model-config...${NC}"
                kubectl patch modelconfig -n "$KAGENT_NAMESPACE" "$PROVIDER-model-config" --type=merge -p "{\"spec\":{\"model\":\"$MODEL\"}}"
            else
                echo -e "${BLUE}Creating new ModelConfig for $PROVIDER...${NC}"
                
                # Create provider-specific ModelConfig
                case "$PROVIDER" in
                    "anthropic")
                        cat << EOF | kubectl apply -f -
apiVersion: kagent.dev/v1alpha1
kind: ModelConfig
metadata:
  name: anthropic-model-config
  namespace: $KAGENT_NAMESPACE
spec:
  model: $MODEL
  provider: Anthropic
  anthropic:
    apiKeySecretRef: kagent-anthropic
    apiKeySecretKey: ANTHROPIC_API_KEY
EOF
                        ;;
                    "openAI")
                        cat << EOF | kubectl apply -f -
apiVersion: kagent.dev/v1alpha1
kind: ModelConfig
metadata:
  name: openai-model-config
  namespace: $KAGENT_NAMESPACE
spec:
  model: $MODEL
  provider: OpenAI
  openAI:
    apiKeySecretRef: kagent-openai
    apiKeySecretKey: OPENAI_API_KEY
EOF
                        ;;
                    "azureOpenAI")
                        cat << EOF | kubectl apply -f -
apiVersion: kagent.dev/v1alpha1
kind: ModelConfig
metadata:
  name: azure-openai-model-config
  namespace: $KAGENT_NAMESPACE
spec:
  model: $MODEL
  provider: AzureOpenAI
  azureOpenAI:
    apiKeySecretRef: kagent-azure-openai
    apiKeySecretKey: AZUREOPENAI_API_KEY
    apiVersion: "2023-05-15"
    azureDeployment: "your-deployment-name"
    azureEndpoint: "https://your-endpoint.openai.azure.com"
EOF
                        echo -e "${YELLOW}Note: For Azure OpenAI, you need to manually update the deployment name and endpoint in the ModelConfig${NC}"
                        ;;
                esac
            fi
            
            # Update the default ModelConfig to point to the new provider
            if kubectl get modelconfig -n "$KAGENT_NAMESPACE" default-model-config &>/dev/null; then
                echo -e "${YELLOW}Updating default-model-config to use $PROVIDER...${NC}"
                kubectl delete modelconfig -n "$KAGENT_NAMESPACE" default-model-config
            fi
            
            # Create a new default-model-config that points to the provider
            cat << EOF | kubectl apply -f -
apiVersion: kagent.dev/v1alpha1
kind: ModelConfig
metadata:
  name: default-model-config
  namespace: $KAGENT_NAMESPACE
spec:
  model: $MODEL
  provider: $PROVIDER
EOF
            if [ "$PROVIDER" == "anthropic" ]; then
                kubectl patch modelconfig -n "$KAGENT_NAMESPACE" default-model-config --type=merge -p "{\"spec\":{\"anthropic\":{\"apiKeySecretRef\":\"kagent-anthropic\",\"apiKeySecretKey\":\"ANTHROPIC_API_KEY\"}}}"
            elif [ "$PROVIDER" == "openAI" ]; then
                kubectl patch modelconfig -n "$KAGENT_NAMESPACE" default-model-config --type=merge -p "{\"spec\":{\"openAI\":{\"apiKeySecretRef\":\"kagent-openai\",\"apiKeySecretKey\":\"OPENAI_API_KEY\"}}}"
            elif [ "$PROVIDER" == "azureOpenAI" ]; then
                kubectl patch modelconfig -n "$KAGENT_NAMESPACE" default-model-config --type=merge -p "{\"spec\":{\"azureOpenAI\":{\"apiKeySecretRef\":\"kagent-azure-openai\",\"apiKeySecretKey\":\"AZUREOPENAI_API_KEY\",\"apiVersion\":\"2023-05-15\"}}}"
            fi
        fi
        
        # Restart kagent pods
        echo -e "${YELLOW}Restarting kagent pods to apply new configuration...${NC}"
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
        
        echo -e "${GREEN}Provider/model updated successfully in running deployment.${NC}"
        
        if [ "$PROVIDER" == "ollama" ]; then
            echo -e "${BLUE}You can test the new model with:${NC}"
            echo -e "${YELLOW}kubectl exec -n demo-app ollama-test -- curl -s -X POST http://host.docker.internal:11434/api/generate -d '{\"model\": \"$MODEL\", \"prompt\": \"What is the capital of Sweden?\"}' | jq -r 'select(.done==true) | .response'${NC}"
        else
            echo -e "${BLUE}You can verify the provider switch using the kagent UI:${NC}"
            echo -e "${YELLOW}kubectl port-forward svc/kagent-controller -n $KAGENT_NAMESPACE 8080:http${NC}"
            echo -e "${BLUE}Then access http://localhost:8080 in your browser${NC}"
        fi
    else
        echo -e "${YELLOW}Changes applied to configuration files only.${NC}"
        echo -e "${BLUE}To deploy these changes, run:${NC}"
        echo -e "${YELLOW}helm upgrade kagent 05_kagent/kagent -n $KAGENT_NAMESPACE --values $VALUES_FILE${NC}"
    fi
else
    echo -e "${YELLOW}No running Kubernetes cluster with kagent detected.${NC}"
    echo -e "${GREEN}Configuration files updated successfully.${NC}"
    echo -e "${BLUE}To deploy with the new provider/model, run:${NC}"
    echo -e "${YELLOW}./deploy_all.sh${NC}"
    
    # Update deploy_all.sh to use the new values file if it's not Ollama
    if [ "$PROVIDER" != "ollama" ] && [ -f "deploy_all.sh" ]; then
        echo -e "${YELLOW}Note: You should update deploy_all.sh to use the new values file:${NC}"
        echo -e "${YELLOW}  1. Find the helm install command for kagent${NC}"
        echo -e "${YELLOW}  2. Change --values 05_kagent/values-ollama.yaml to --values $VALUES_FILE${NC}"
    fi
fi

# Verify model/provider switch with a test if possible
if [ "$PROVIDER" == "ollama" ] && curl -s http://localhost:11434/api/tags &>/dev/null; then
    echo -e "${BLUE}Testing Ollama model switch with API...${NC}"
    TEST_RESULT=$(curl -s -X POST http://localhost:11434/api/generate -d "{\"model\": \"$MODEL\", \"prompt\": \"Say hello!\", \"stream\": false}")
    
    if echo "$TEST_RESULT" | grep -q "error"; then
        echo -e "${RED}Error during model test:${NC}"
        echo "$TEST_RESULT" | grep error
        echo -e "${YELLOW}Please check that the model '$MODEL' is correctly installed in Ollama.${NC}"
    else
        RESPONSE=$(echo "$TEST_RESULT" | grep -o '"response":"[^"]*"' | sed 's/"response":"//;s/"//')
        echo -e "${GREEN}Model switch verified! Response from $MODEL:${NC} $RESPONSE"
    fi
elif [ "$PROVIDER" == "ollama" ]; then
    echo -e "${YELLOW}Ollama server not running or not accessible. Can't verify model switch.${NC}"
    echo -e "${BLUE}Start Ollama server with 'ollama serve' to use the model.${NC}"
else
    echo -e "${BLUE}For API-based providers like $PROVIDER, use the kagent UI to test the model.${NC}"
fi

# Create a symlink to the current values file for easy reference
echo -e "${BLUE}Creating symlink to current values file...${NC}"
ln -sf "$VALUES_FILE" 05_kagent/values-current.yaml

echo -e "${GREEN}Provider/model switch completed!${NC}"
echo -e "${BLUE}Current provider:${NC} $PROVIDER"
echo -e "${BLUE}Current model:${NC} $MODEL"
echo -e "${BLUE}Values file:${NC} $VALUES_FILE"

# Display access information if we updated the running deployment
if [[ "${UPDATE_DEPLOYMENT:-}" == "y" ]]; then
    echo -e "\n${GREEN}Services are available at:${NC}"
    echo -e "You can access your app at: ${YELLOW}http://localhost:31755/ui${NC}"
    echo -e "You can access Grafana at: ${YELLOW}http://localhost:31755/grafana (admin/admin)${NC}"
    echo -e "You can access kagent at: ${YELLOW}http://localhost:8083/${NC}"
    echo -e "You can access ArgoCD at: ${YELLOW}http://localhost:8080/${NC}"
fi
