# AIRE PoC Environment

This repository provides a fully automated setup for a local Kubernetes environment using Kind, with:
- Multi-node cluster
- Ingress NGINX
- Demo application
- Monitoring stack (Prometheus & Grafana)
- Local LLM Provider (Ollama)
- Kagent installed & Configured with Ollama

## Prerequisites
- 'Stronger' MacBook (M2+ Silicon 32GB Ram)
- Docker for desktop installed
- kubectl
- Helm
- jq (for Ollama test output)

## Installation & Setup

1. **Clone the repository**
2. **Run the deployment script:**
   ```sh
   chmod +x deploy_all.sh
   ./deploy_all.sh
   ```
   This will:
   - Create a Kind cluster with required port mappings
   - Install ingress-nginx and patch NodePorts
   - Deploy the demo app
   - Install Prometheus and Grafana via Helm
   - Configure Grafana to use Prometheus as a data source
   - Expose Grafana via Ingress
   - Install Ollama and pull the `mistral:7b` model
   - Install kagent CRDs and kagent with Ollama provider
   - Grant kagent cluster-admin RBAC permissions
   - Deploy a test pod to verify Ollama connectivity from inside the cluster

## Accessing Services

- **Demo Application:**
  - URL: [http://localhost:31755/](http://localhost:31755/)

- **Grafana:**
  - URL: [http://localhost:31755/grafana](http://localhost:31755/grafana)
  - Login: `admin` / `admin`
  - Prometheus is pre-configured as the default data source

- **Kagent API:**
  - To access from your host, run:
    ```sh
    kubectl port-forward -n kagent svc/kagent 8083:80
    ```
  - Then open: [http://localhost:8083/](http://localhost:8083/) in your browser or API client.

## Testing Ollama Connectivity from Kind Cluster

To verify that pods in your Kind cluster can reach the Ollama server running on your Mac:

1. Deploy the test pod (automated in the script):
   ```sh
   kubectl apply -f 02_demo_app/ollama-test-pod.yaml
   kubectl wait --namespace demo-app --for=condition=Ready pod/ollama-test --timeout=60s
   kubectl exec -n demo-app ollama-test -- curl -s -X POST http://host.docker.internal:11434/api/generate -d '{"model": "mistral:7b", "prompt": "What is the capital of Sweden?"}' | jq -r 'select(.done==true) | .response'
   ```
2. You should see the final answer (e.g., `Stockholm`).

## Troubleshooting
- If you see 404 errors for Grafana, ensure the Ingress and Helm values are set as described.
- If ports do not match, check your Kind config and NodePort patching in `deploy_all.sh`.
- For custom dashboards, import them via the Grafana UI.
- If kagent cannot access the cluster, ensure RBAC permissions are set (see script for ClusterRoleBinding).

## Cleanup
To delete the environment:
```sh
kind delete cluster --name aire-poc
```

## Customization
- Edit `deploy_all.sh` to add more services, agents, or dashboards
- Update Helm values in `03_monitoring/grafana-values.yaml` and `05_kagent/values-ollama.yaml` for advanced configuration

---
Questions and / or improvements are welcome.
