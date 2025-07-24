#!/bin/bash
# Automated Kind multi-node cluster setup, ingress-nginx install, patch, demo-app, Prometheus, Grafana, and Ollama LLM deployment
# Usage: ./deploy_all.sh

set -e

# Color variables
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Variables
CLUSTER_NAME="aire-poc"
LLM_PROVIDER=${LLM_PROVIDER:-ollama}  # Default to Ollama if not set
LLM_MODEL=${LLM_MODEL:-llama3.1}  # Default to llama3.1 if not set
DEMO_APP_NAMESPACE="demo-app"
MONITORING_NAMESPACE="monitoring"
KAGENT_NAMESPACE="kagent"
KIND_CONFIG="01_multi_node_cluster/01_multi_node_cluster.yaml"
INGRESS_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/kind/deploy.yaml"
APP_MANIFEST="02_demo_app/02_deployment_app.yaml"
GRAFANA_VALUES="03_monitoring/grafana_values.yaml"
GRAFANA_INGRESS="03_monitoring/grafana_ingress.yaml"
ARGOCD_NAMESPACE="argocd"
ARGOCD_OBJECTS="06_argocd/argo-cd.yaml"
ARGOCD_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"

# 0. Install and configure LLM provider
if [ "$LLM_PROVIDER" == "ollama" ]; then
  echo -e "${BLUE}Installing Ollama (local LLM provider)...${NC}"
  if ! command -v ollama &> /dev/null; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
      brew install ollama
    else
      echo "Please install Ollama manually for your OS: https://ollama.com/download"
    fi
else
    echo "Ollama is already installed."
  fi

  if lsof -i :11434 | grep LISTEN; then
    echo "Ollama server is already running on port 11434."
  else
    echo -e "${YELLOW}Starting Ollama server on 0.0.0.0...${NC}"
    ollama serve &
    sleep 5
  fi

  echo -e "${GREEN}Pulling the model with Ollama...${NC}"
  ollama pull ${LLM_MODEL}
elif [ "$LLM_PROVIDER" == "anthropic" ] || [ "$LLM_PROVIDER" == "openAI" ] || [ "$LLM_PROVIDER" == "azureOpenAI" ]; then
  echo -e "${YELLOW}Using $LLM_PROVIDER as LLM provider with model $LLM_MODEL${NC}"
  
  # Check if API key is provided via environment variable
  API_KEY_VAR="${LLM_PROVIDER^^}_API_KEY"
  if [ -z "${!API_KEY_VAR}" ]; then
    echo -e "${RED}Error: API key not set for $LLM_PROVIDER provider.${NC}"
    echo -e "Please set the environment variable ${API_KEY_VAR} and try again."
    exit 1
  fi
  echo -e "${GREEN}Found API key for $LLM_PROVIDER provider.${NC}"
else
  echo -e "${RED}Error: Unsupported LLM provider: $LLM_PROVIDER${NC}"
  echo -e "Supported providers: ollama, anthropic, openAI, azureOpenAI"
  exit 1
fi

# 1. Delete existing cluster (if any)
echo -e "${BLUE}Deleting existing Kind cluster (if any)...${NC}"
kind delete cluster --name "$CLUSTER_NAME" || true

# 2. Create Kind cluster with correct port mappings
echo -e "${BLUE}Creating Kind cluster...${NC}"
kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG"

# 3. Install ingress-nginx
echo -e "${BLUE}Installing ingress-nginx...${NC}"
kubectl apply -f "$INGRESS_MANIFEST"

# 4. Wait for ingress-nginx-controller service and pod to be ready
echo -e "${YELLOW}Waiting for ingress-nginx-controller pod to be ready...${NC}"
kubectl wait --namespace ingress-nginx --for=condition=Ready pod -l app.kubernetes.io/component=controller --timeout=180s

# 5. Patch ingress-nginx-controller service to use fixed NodePorts
echo -e "${GREEN}Patching ingress-nginx-controller service NodePorts...${NC}"
kubectl patch svc ingress-nginx-controller -n ingress-nginx \
  -p '{"spec": {"ports": [{"name": "http", "nodePort": 31755, "port": 80, "protocol": "TCP"}, {"name": "https", "nodePort": 30333, "port": 443, "protocol": "TCP"}]}}'

# 6. Wait for service patch to take effect
echo -e "${YELLOW}Waiting for service patch to take effect...${NC}"
sleep 5

# 7. Deploy demo-app (namespace, deployment, service, ingress)
# echo -e "${BLUE}Deploying demo-app...${NC}"
kubectl create namespace "$DEMO_APP_NAMESPACE" || true
# kubectl apply -f "$APP_MANIFEST"

# 8. Create monitoring namespace
echo -e "${BLUE}Creating monitoring namespace...${NC}"
kubectl create namespace "$MONITORING_NAMESPACE" || true

# 9. Add Helm repos and update
echo -e "${BLUE}Adding Helm repos and updating...${NC}"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# 10. Install Prometheus
echo -e "${GREEN}Installing Prometheus...${NC}"
helm upgrade --install prometheus prometheus-community/prometheus \
  --namespace "$MONITORING_NAMESPACE" \
  --set alertmanager.enabled=false \
  --set pushgateway.enabled=false

# 11. Install Grafana with Prometheus data source
echo -e "${GREEN}Installing Grafana...${NC}"
helm upgrade --install grafana grafana/grafana --namespace "$MONITORING_NAMESPACE" -f "$GRAFANA_VALUES"

# 12. Apply Grafana Ingress
if [ -f "$GRAFANA_INGRESS" ]; then
  echo -e "${YELLOW}Applying Grafana Ingress...${NC}"
  kubectl apply -f "$GRAFANA_INGRESS"
fi

# 13. Create kagent namespace
KAGENT_NAMESPACE="kagent"
echo -e "${BLUE}Creating kagent namespace...${NC}"
kubectl create namespace "$KAGENT_NAMESPACE" || true

# 14. Install kagent CRDs
echo -e "${GREEN}Installing kagent CRDs...${NC}"
helm install kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
  --namespace "$KAGENT_NAMESPACE" \
  --create-namespace

# 15. Grant kagent service account cluster-admin permissions
echo -e "${GREEN}Granting kagent service account cluster-admin permissions...${NC}"
cat <<EOF | kubectl apply -f -
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

# # 16. Create OpenAI API key secret with dummy value for the tools-server
# echo -e "${GREEN}Creating OpenAI API key secret with dummy value...${NC}"
# kubectl create secret generic kagent-openai -n "$KAGENT_NAMESPACE" --from-literal=OPENAI_API_KEY=dummy-value-for-tools-server --dry-run=client -o yaml | kubectl apply -f -

# 17. Install kagent with configured provider
# Determine which values file to use
if [ "$LLM_PROVIDER" == "ollama" ]; then
  KAGENT_VALUES="05_kagent/values-ollama.yaml"
else
  # Check if a values file exists for this provider
  if [ -f "05_kagent/values-${LLM_PROVIDER}.yaml" ]; then
    KAGENT_VALUES="05_kagent/values-${LLM_PROVIDER}.yaml"
  else
    # Create a new values file for this provider
    echo -e "${YELLOW}Creating values file for $LLM_PROVIDER provider...${NC}"
    ./switch_provider.sh "$LLM_PROVIDER" "$LLM_MODEL" "${!API_KEY_VAR}"
    KAGENT_VALUES="05_kagent/values-${LLM_PROVIDER}.yaml"
  fi

  # Create provider-specific API key secret
  SECRET_NAME="kagent-$LLM_PROVIDER"
  SECRET_KEY="${LLM_PROVIDER^^}_API_KEY"
  
  # Convert to uppercase for environment variable names
  if [ "$LLM_PROVIDER" == "openAI" ]; then
    SECRET_NAME="kagent-openai"
    SECRET_KEY="OPENAI_API_KEY"
  elif [ "$LLM_PROVIDER" == "azureOpenAI" ]; then
    SECRET_NAME="kagent-azure-openai"
    SECRET_KEY="AZUREOPENAI_API_KEY"
  fi
  
  echo -e "${BLUE}Creating $LLM_PROVIDER API key secret...${NC}"
  kubectl create secret generic "$SECRET_NAME" \
    -n "$KAGENT_NAMESPACE" \
    --from-literal="$SECRET_KEY=${!API_KEY_VAR}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

echo -e "${GREEN}Installing kagent with $LLM_PROVIDER provider...${NC}"
helm upgrade --install kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  --namespace "$KAGENT_NAMESPACE" \
  -f "$KAGENT_VALUES"

echo "Kagent installed in namespace $KAGENT_NAMESPACE with $LLM_PROVIDER provider."

# Create or update ModelConfig object for the provider
echo -e "${BLUE}Creating ModelConfig for $LLM_PROVIDER provider...${NC}"

if [ "$LLM_PROVIDER" == "ollama" ]; then
  cat << EOF | kubectl apply -f -
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
elif [ "$LLM_PROVIDER" == "anthropic" ]; then
  cat << EOF | kubectl apply -f -
apiVersion: kagent.dev/v1alpha1
kind: ModelConfig
metadata:
  name: default-model-config
  namespace: $KAGENT_NAMESPACE
spec:
  model: $LLM_MODEL
  provider: Anthropic
  anthropic:
    apiKeySecretRef: kagent-anthropic
    apiKeySecretKey: ANTHROPIC_API_KEY
EOF
elif [ "$LLM_PROVIDER" == "openAI" ]; then
  cat << EOF | kubectl apply -f -
apiVersion: kagent.dev/v1alpha1
kind: ModelConfig
metadata:
  name: default-model-config
  namespace: $KAGENT_NAMESPACE
spec:
  model: $LLM_MODEL
  provider: OpenAI
  openAI:
    apiKeySecretRef: kagent-openai
    apiKeySecretKey: OPENAI_API_KEY
EOF
elif [ "$LLM_PROVIDER" == "azureOpenAI" ]; then
  cat << EOF | kubectl apply -f -
apiVersion: kagent.dev/v1alpha1
kind: ModelConfig
metadata:
  name: default-model-config
  namespace: $KAGENT_NAMESPACE
spec:
  model: $LLM_MODEL
  provider: AzureOpenAI
  azureOpenAI:
    apiKeySecretRef: kagent-azure-openai
    apiKeySecretKey: AZUREOPENAI_API_KEY
    apiVersion: "2023-05-15"
    azureDeployment: "your-deployment-name"
    azureEndpoint: "https://your-endpoint.openai.azure.com"
EOF
  echo -e "${YELLOW}Note: For Azure OpenAI, you may need to manually update the deployment name and endpoint in the ModelConfig${NC}"
fi

# 18. Deploy test pod for Ollama if using Ollama provider
if [ "$LLM_PROVIDER" == "ollama" ]; then
  OLLAMA_TEST_POD="04_ollama/ollama_test_pod.yaml"
  echo -e "${BLUE}Deploying ollama test pod for connectivity test...${NC}"
  kubectl apply -f "$OLLAMA_TEST_POD"
  echo -e "${YELLOW}Waiting for ollama test pod to be ready...${NC}"
  kubectl wait --namespace demo-app --for=condition=Ready pod/ollama-test --timeout=60s

  echo -e "${GREEN}Running test query to Ollama from inside the Kind cluster...${NC}"
  kubectl exec -n demo-app ollama-test -- curl -s -X POST http://host.docker.internal:11434/api/generate -d "{\"model\": \"$LLM_MODEL\", \"prompt\": \"What is the capital of Sweden?\"}" | jq -r 'select(.done==true) | .response'
else
  echo -e "${YELLOW}Skipping Ollama test pod deployment for $LLM_PROVIDER provider.${NC}"
fi

# 19. Install ArgoCD
echo -e "${BLUE}Creating ArgoCD namespace...${NC}"
kubectl create namespace "$ARGOCD_NAMESPACE" || true

echo -e "${BLUE}Installing ArgoCD...${NC}"
kubectl apply -n "$ARGOCD_NAMESPACE" -f "$ARGOCD_MANIFEST"

echo -e "${YELLOW}Waiting for ArgoCD and Kagent pods to be ready...${NC}"
echo -e "${BLUE}This might take a few minutes...${NC}"

# Add a short delay to allow pods to be created
sleep 20

# Wait for ArgoCD server with more resilient error handling
echo -e "${YELLOW}Waiting for ArgoCD server...${NC}"
kubectl wait --namespace "$ARGOCD_NAMESPACE" --for=condition=Ready pod -l app.kubernetes.io/name=argocd-server --timeout=300s || {
  echo -e "${YELLOW}ArgoCD server pods not ready yet, continuing anyway...${NC}"
  kubectl get pods -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=argocd-server
}

# Wait for Kagent with more resilient error handling
echo -e "${YELLOW}Waiting for Kagent...${NC}"
kubectl wait --namespace "$KAGENT_NAMESPACE" --for=condition=Ready pod -l app.kubernetes.io/name=kagent --timeout=180s || {
  echo -e "${YELLOW}Kagent pods not ready yet, continuing anyway...${NC}" 
  kubectl get pods -n "$KAGENT_NAMESPACE" -l app.kubernetes.io/name=kagent
}

# 20. Apply ArgoCD Application manifest
echo -e "${BLUE}Applying ArgoCD Application manifest...${NC}"
kubectl apply -f "$ARGOCD_OBJECTS"

# Get ArgoCD password with retry logic
echo -e "${YELLOW}Retrieving ArgoCD admin password...${NC}"
MAX_RETRIES=5
RETRY_COUNT=0
ARGOCD_PASS=""

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    ARGOCD_PASS=$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode)
    
    if [ -n "$ARGOCD_PASS" ]; then
        echo -e "${GREEN}Successfully retrieved ArgoCD password.${NC}"
        break
    else
        RETRY_COUNT=$((RETRY_COUNT+1))
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
            echo -e "${YELLOW}Waiting for ArgoCD secret to be created (attempt $RETRY_COUNT of $MAX_RETRIES)...${NC}"
            sleep 10
        else
            echo -e "${YELLOW}Could not retrieve ArgoCD password after $MAX_RETRIES attempts.${NC}"
            echo -e "${YELLOW}You may need to run this command manually:${NC}"
            echo -e "${BLUE}kubectl -n \"$ARGOCD_NAMESPACE\" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 --decode${NC}"
            ARGOCD_PASS="<password not available yet>"
        fi
    fi
done

echo -e "${GREEN}Exposing services...${NC}"

# Setup port forwarding with better error handling
echo -e "${YELLOW}Setting up port forwarding for ArgoCD...${NC}"
kubectl port-forward svc/argocd-server -n "$ARGOCD_NAMESPACE" 8080:443 &>/dev/null &
PORT_FORWARD_ARGOCD_PID=$!

echo -e "${YELLOW}Setting up port forwarding for Kagent...${NC}"
kubectl port-forward svc/kagent -n "$KAGENT_NAMESPACE" 8083:80 &>/dev/null &
PORT_FORWARD_KAGENT_PID=$!

# Give port-forwarding a moment to start
sleep 2

# Check if port forwarding is working
if ps -p $PORT_FORWARD_ARGOCD_PID > /dev/null; then
    echo -e "${GREEN}ArgoCD port forwarding started successfully.${NC}"
else
    echo -e "${YELLOW}ArgoCD port forwarding may not have started. You can manually run:${NC}"
    echo -e "${BLUE}kubectl port-forward svc/argocd-server -n \"$ARGOCD_NAMESPACE\" 8080:443${NC}"
fi

if ps -p $PORT_FORWARD_KAGENT_PID > /dev/null; then
    echo -e "${GREEN}Kagent port forwarding started successfully.${NC}"
else
    echo -e "${YELLOW}Kagent port forwarding may not have started. You can manually run:${NC}"
    echo -e "${BLUE}kubectl port-forward svc/kagent -n \"$KAGENT_NAMESPACE\" 8083:80${NC}"
fi

echo -e "${GREEN}All done!${NC}"
echo -e "You can access your app at: ${YELLOW}http://localhost:31755/ui${NC}"
echo -e "You can access Grafana at: ${YELLOW}http://localhost:31755/grafana (admin/admin)${NC}"
echo -e "You can access kagent at: ${YELLOW}http://localhost:8083/${NC}"
echo -e "You can access ArgoCD at: ${YELLOW}http://localhost:8080/${NC}"
echo -e "ArgoCD admin password is: ${YELLOW}${ARGOCD_PASS}${NC}"
echo -e "\nCurrent LLM provider: ${YELLOW}${LLM_PROVIDER}${NC} with model: ${YELLOW}${LLM_MODEL}${NC}"
echo -e "To switch providers or models, use:"
echo -e "  ${YELLOW}./switch_provider.sh <provider> <model> [api_key]${NC}"
echo -e "Examples:"
echo -e "  ${YELLOW}./switch_provider.sh ollama llama3.1${NC}"
echo -e "  ${YELLOW}./switch_provider.sh anthropic claude-3-sonnet-20240229 <API_KEY>${NC}"
echo -e "For Ollama models only, you can also use the simplified script:"
echo -e "  ${YELLOW}./switch_model.sh llama3.1${NC} (Ollama models only)"
echo -e "Or redeploy with a different provider:"
echo -e "  ${YELLOW}LLM_PROVIDER=anthropic LLM_MODEL=claude-3-sonnet-20240229 ANTHROPIC_API_KEY=<API_KEY> ./deploy_all.sh${NC}"