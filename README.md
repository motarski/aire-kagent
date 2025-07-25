# AIRE (PoC): Base Infrastructure for AI Prototyping

This repository provides a fully automated setup of multi node local Kubernetes environment with Kagent framework for rapid AI Prototyping.

#### ⚠️ CAUTION
Running Ollama LLM models larger than **7–8B parameters** is not recommended on MacBooks with less than **32 GB RAM**. On machines with **16 GB RAM**, prefer **quantized models in the 3B–5B range**.

Larger models can cause:
- Excessive memory pressure
- Heavy swap usage
- System slowdowns or instability

If you need more powerful models, consider adding Anthropic as a provider using `switch_provider.sh`.

## Prerequisites
- MacBook
- Docker for desktop installed (might work with podman desktop as well - however it's not been tested)
- kubectl client installed
- Helm installed
- jq installed

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
   - Install and configure Ollama with the llama3.1 model
   - Install kagent CRDs and kagent configured with Ollama
   - Grant kagent cluster-admin RBAC permissions
   - Deploy a test pod to verify Ollama connectivity
   - Install ArgoCD for GitOps management
   - Configure ArgoCD to connect to a public GitHub repository and deploy the demo app automatically

## Accessing Services

- **Demo Application:**
  - URL: [http://localhost:31755/ui](http://localhost:31755/)
  - Deployed and managed by ArgoCD from a public [GitHub repository](https://github.com/motarski/demo-app)

- **Grafana:**
  - URL: [http://localhost:31755/grafana](http://localhost:31755/grafana)
  - Login: `admin` / `admin`
  - Prometheus is pre-configured as the default data source

- **Kagent API:**
  - URL: [http://localhost:8083/](http://localhost:8083/) in your browser.

- **ArgoCD UI:**
  - URL: [http://localhost:8080/](http://localhost:8080/)
  - Login: `admin` / (password is shown at the end of the deployment script)

## Testing LLM Connectivity

You can verify Ollama connectivity from the Kind cluster:

```sh
kubectl exec -n demo-app ollama-test -- curl -s -X POST http://host.docker.internal:11434/api/generate -d '{"model": "llama3.1", "prompt": "What is the capital of Sweden?"}'
```
You should see the final answer (e.g., `Stockholm`).

## Switching between LLM Models and Providers

The framework includes convenient scripts that allow you to quickly change the LLM models and providers used throughout the entire environment after your initial deployment.

### Switching Ollama Models

For quick switching between different Ollama models in an existing deployment:

```sh
# Switch to a different model (e.g., mistral:7b)
./switch_model.sh mistral:7b

# Switch to llama3.1 model (default)
./switch_model.sh llama3.1
```

The script will:
1. Update the Ollama configuration in values-ollama.yaml
2. Pull the model if it's not already available locally
3. Optionally update your running deployment if one exists
4. Update all ModelConfig objects that use Ollama provider
5. Verify the model switch by testing the model

### Adding Different Providers

After your initial deployment with Ollama, you can add Anthropic as a provider using the provider script:

```sh
# First export your Anthropic API key
export ANTHROPIC_API_KEY="your_api_key_here"

# Add Anthropic Claude (requires API key)
./switch_provider.sh anthropic claude-sonnet-4-20250514

# Switch to Ollama with a specific model
./switch_provider.sh ollama llama3.1
```

**The provider switcher script supports:**
1. Ollama (local models)
2. Anthropic (Claude models)

The script adds the specified provider to your cluster, allowing you to use it alongside Ollama. You can select which provider/model to use for each agent via the kagent UI without changing the default configuration or restarting services.

## Cleanup
To delete the environment:
```sh
kind delete cluster --name aire-poc
```

---
