# AIRE PoC: Base Infrastructure


This repository provides a fully automated setup of multi node local Kubernetes environment with Kagent framework for rapid AI Prototyping.

## Prerequisites
- 'Jucier' MacBook (M2+ Silicon 32GB Ram)
- Docker for desktop installed
- kubectl
- Helm

## Installation & Setup

1. **Clone the repository**
2. **Run the deployment script:**
   ```sh
   ./deploy_all.sh
   ```

   This will:
   - Create a Kind cluster with required port mappings
   - Install ingress-nginx and patch NodePorts
   - Install Monitoring stack (Prometheus and Grafana)
   - Configure Grafana to use Prometheus as a data source
   - Expose Grafana via Ingress
   - Install Local LLM provider Ollama and pulls the `llama3.1:8b` model
   - Install kagent CRDs and kagent configured to be used with the Local LLM provider
   - Grant kagent cluster-admin RBAC permissions
   - Deploy a test pod to verify Ollama connectivity from inside the cluster
   - Install ArgoCD for GitOps management
   - Configure ArgoCD to connect to a public GitHub repository and deploy the demo app automatically


## Accessing Services

- **Demo Application:**
  - URL: [http://localhost:31755/ui](http://localhost:31755/)
  - Deployed and managed by ArgoCD from your public GitHub repository

- **Grafana:**
  - URL: [http://localhost:31755/grafana](http://localhost:31755/grafana)
  - Login: `admin` / `admin`
  - Prometheus is pre-configured as the default data source

- **Kagent API:**
  - URL: [http://localhost:8083/](http://localhost:8083/) in your browser.

- **ArgoCD UI:**
  - URL: [http://localhost:8080/](http://localhost:8080/)
  - Login: `admin` / (password is shown at the end of the deployment script)
  - ArgoCD automatically syncs and deploys the demo app from a public [GitHub repository](https://github.com/motarski/demo-app)


## ArgoCD & GitHub Integration

This PoC follows the GitOps flow we already have. ArgoCD is configured to connect to a public GitHub repository and automatically deploy the demo app manifests. Any changes pushed to this GitHub repo will be detected and synced by ArgoCD, ensuring the cluster stays up to date with your desired state.

## Testing Ollama Connectivity from Kind Cluster

To manually verify that pods in your Kind cluster can reach the Ollama server running on your Mac:

   ```sh

   kubectl exec -n demo-app ollama-test -- curl -s -X POST http://host.docker.internal:11434/api/generate -d '{"model": "llama3.1:8b", "prompt": "What is the capital of Sweden?"}'
   ```
You should see the final answer (e.g., `Stockholm`).

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

### Contributions and Questions are welcome
