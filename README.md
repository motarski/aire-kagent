# AIRE (PoC): Base Infrastructure for AI Prototyping

This repository provides a fully automated setup of multi node local Kubernetes environment with Kagent framework for rapid AI Prototyping.

#### ⚠️ CAUTION
Running Ollama LLM models larger than **7–8B parameters** is not recommended on MacBooks with less than **32 GB RAM**. On machines with **16 GB RAM**, prefer **quantized models in the 3B–5B range**.

Larger models can cause:
- Excessive memory pressure
- Heavy swap usage
- System slowdowns or instability

If you need more powerful models, consider switching to a remote provider using `switch_provider.sh`.

## Prerequisites
- MacBook
- Docker for desktop installed (could with podman desktop as well - however it's not tested)
- kubectl client installed
- Helm installed
- jq installed

## Installation & Setup

1. **Clone the repository**
2. **Run the deployment script:**

   Basic deployment with default **Ollama** provider and **llama3.1:8b** model:
   ```sh
   ./deploy_all.sh
   ```
This will:
   - Create a Kind cluster with required port mappings
   - Install ingress-nginx and patch NodePorts
   - Install Monitoring stack (Prometheus and Grafana)
   - Configure Grafana to use Prometheus as a data source
   - Expose Grafana via Ingress
   - Install and configure the specified LLM provider (Ollama, Anthropic, OpenAI, or Azure OpenAI)
   - Install kagent CRDs and kagent configured with the selected LLM provider
   - Grant kagent cluster-admin RBAC permissions
   - Deploy a test pod to verify Ollama connectivity if using Ollama provider
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

## Testing LLM Provider Connectivity

### Ollama Provider
When using the Ollama provider, you can verify connectivity from the Kind cluster:

```sh
# The current model will be automatically used in the test
kubectl exec -n demo-app ollama-test -- curl -s -X POST http://host.docker.internal:11434/api/generate -d '{"model": "YOUR_MODEL", "prompt": "What is the capital of Sweden?"}'
```
You should see the final answer (e.g., `Stockholm`).

### API-Based Providers (Anthropic, OpenAI, Azure)
When using API-based providers, you can verify functionality through the kagent UI

## Switching between LLM Models and Providers

The framework includes convenient scripts that allow you to quickly change the LLM models and providers used throughout the entire environment. You can deploy the entire environment with a specific provider by setting environment variables:

```sh
# For Ollama provider (default)
LLM_PROVIDER=ollama LLM_MODEL=qwen3:8b ./deploy_all.sh

# For Anthropic provider
LLM_PROVIDER=anthropic LLM_MODEL=claude-3-sonnet-20240229 ANTHROPIC_API_KEY=your_api_key_here ./deploy_all.sh

# For OpenAI provider
LLM_PROVIDER=openAI LLM_MODEL=gpt-4.1-mini OPENAI_API_KEY=your_api_key_here ./deploy_all.sh
```

### Switching Ollama Models

For quick switching between different Ollama models in an existing deployment:

```sh
# Switch to a different model (e.g., mistral:7b)
./switch_model.sh mistral:7b

# Switch to llama3.1 model (default)
./switch_model.sh llama3.1
```

The script will:
1. Update all configuration files with the new model
2. Pull the model if it's not already available locally
3. Optionally update your running deployment if one exists
4. Update all ModelConfig objects that use Ollama provider
5. Verify the model switch by testing the model

### Switching Between Different Providers

For switching between different providers in an existing deployment:

```sh
# Switch to Ollama with a specific model
./switch_provider.sh ollama llama3.1

# Switch to Anthropic Claude (requires API key)
./switch_provider.sh anthropic claude-3-sonnet-20240229 your_api_key_here

# Switch to OpenAI (requires API key)
./switch_provider.sh openAI gpt-4.1-mini your_api_key_here

# Switch to Azure OpenAI (requires API key and additional configuration)
./switch_provider.sh azureOpenAI deployment-model-name your_api_key_here
```

**The provider switcher script supports:**
1. Ollama (local models)
2. Anthropic (Claude models)
3. OpenAI (GPT models)
4. Azure OpenAI (requires additional configuration)

This comprehensive approach makes it easy to experiment with different models and providers without manually editing multiple files.

## Cleanup
To delete the environment:
```sh
kind delete cluster --name aire-poc
```

---
