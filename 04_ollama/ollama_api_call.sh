#!/bin/bash
# Ollama API call from deployed pod in kind cluster to test LLM functionality

curl http://host.docker.internal:11434/api/generate -d '{
  "model": "llama3.1:8b",
  "prompt": "What is the capital of Sweden? Just reply with the city name."
}'