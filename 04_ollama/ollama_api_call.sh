#!/bin/bash
# Ollama API call from deployed pod in kind cluster to test LLM functionality

# Use specified model or default to the currently configured one
MODEL=${1:-"llama3.1"}
PROMPT=${2:-"What is the capital of Sweden? Just reply with the city name."}

echo "Testing Ollama with model: $MODEL"
echo "Prompt: $PROMPT"
echo

curl -s -X POST http://localhost:11434/api/generate -d "{
  \"model\": \"$MODEL\",
  \"prompt\": \"$PROMPT\",
  \"stream\": false
}" | jq -r '.response'