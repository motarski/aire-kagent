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
DEMO_APP_NAMESPACE="demo-app"
MONITORING_NAMESPACE="monitoring"
KIND_CONFIG="01_multi_node_cluster/01_multi_node_cluster.yaml"
INGRESS_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/kind/deploy.yaml"
APP_MANIFEST="02_demo_app/02_deployment_app.yaml"
GRAFANA_VALUES="03_monitoring/grafana_values.yaml"
GRAFANA_INGRESS="03_monitoring/grafana_ingress.yaml"
ARGOCD_NAMESPACE="argocd"
ARGOCD_OBJECTS="06_argocd/argo-cd.yaml"
ARGOCD_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"

# 0. Install Ollama (local LLM provider)
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
  ollama serve --host 0.0.0.0 &
  sleep 5
fi

echo -e "${GREEN}Pulling mistral:7b model with Ollama...${NC}"
ollama pull mistral:7b

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
echo -e "${BLUE}Deploying demo-app...${NC}"
kubectl create namespace "$DEMO_APP_NAMESPACE" || true
kubectl apply -f "$APP_MANIFEST"

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
KAGENT_VALUES="05_kagent/values-ollama.yaml"
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

# 16. Install kagent with Ollama provider
echo -e "${GREEN}Installing kagent with Ollama provider...${NC}"
helm upgrade --install kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  --namespace "$KAGENT_NAMESPACE" \
  -f "$KAGENT_VALUES"

echo "Kagent installed in namespace $KAGENT_NAMESPACE with Ollama provider."

# 17. Deploy ollama-test-pod to demo-app namespace
OLLAMA_TEST_POD="04_ollama/ollama_test_pod.yaml"
echo -e "${BLUE}Deploying ollama test pod for connectivity test...${NC}"
kubectl apply -f "$OLLAMA_TEST_POD"
echo -e "${YELLOW}Waiting for ollama test pod to be ready...${NC}"
kubectl wait --namespace demo-app --for=condition=Ready pod/ollama-test --timeout=60s

echo -e "${GREEN}Running test query to Ollama from inside the Kind cluster...${NC}"
kubectl exec -n demo-app ollama-test -- curl -s -X POST http://host.docker.internal:11434/api/generate -d '{"model": "mistral:7b", "prompt": "What is the capital of Sweden?"}' | jq -r 'select(.done==true) | .response'

# 18. Install ArgoCD
echo -e "${BLUE}Creating ArgoCD namespace...${NC}"
kubectl create namespace "$ARGOCD_NAMESPACE" || true

echo -e "${BLUE}Installing ArgoCD...${NC}"
kubectl apply -n "$ARGOCD_NAMESPACE" -f "$ARGOCD_MANIFEST"

echo -e "${YELLOW}Waiting for ArgoCD server to be ready...${NC}"
kubectl wait --namespace "$ARGOCD_NAMESPACE" --for=condition=Ready pod -l app.kubernetes.io/name=argocd-server --timeout=180s

echo -e "${BLUE}Applying ArgoCD Application manifest...${NC}"
kubectl apply -f "$ARGOCD_OBJECTS"

echo -e "${GREEN}Exposing ArgoCD server on localhost:8080...${NC}"
kubectl port-forward svc/argocd-server -n "$ARGOCD_NAMESPACE" 8080:443 &

echo -e "${GREEN}All done!${NC}"
echo -e "${YELLOW}You can access your app at: http://localhost:31755/${NC}"
echo -e "${YELLOW}You can access Grafana at: http://localhost:31755/grafana (admin/admin)${NC}"
echo -e "To access kagent's API from your host, run: ${BLUE}kubectl port-forward -n kagent svc/kagent 8083:80${NC}"
echo -e "${YELLOW}Then open: http://localhost:8083/ in your browser${NC}"
echo -e "To access ArgoCD, open: http://localhost:8080/ in your browser"

