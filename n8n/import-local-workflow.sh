#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="$repo_root/n8n/.env"
workflow_file="$repo_root/n8n/neuroreview.workflow.json"
local_workflow="/tmp/speedsters-neuroreview.local.json"

if [[ ! -f "$env_file" ]]; then
  echo "Missing $env_file. Copy n8n/.env.example to n8n/.env and fill OPENROUTER_API_KEY." >&2
  exit 1
fi

if [[ ! -f "$workflow_file" ]]; then
  echo "Missing workflow file: $workflow_file" >&2
  exit 1
fi

node - "$env_file" "$workflow_file" "$local_workflow" <<'NODE'
const fs = require('fs');
const [envFile, workflowFile, outputFile] = process.argv.slice(2);

const envText = fs.readFileSync(envFile, 'utf8');
const env = Object.fromEntries(envText
  .split(/\r?\n/)
  .filter((line) => line && !line.startsWith('#'))
  .map((line) => {
    const index = line.indexOf('=');
    return [line.slice(0, index), line.slice(index + 1)];
  }));

const workflow = JSON.parse(fs.readFileSync(workflowFile, 'utf8'));
const codeNode = workflow.nodes.find((node) => node.name === 'Run Neuroreview');
if (!codeNode?.parameters || typeof codeNode.parameters.jsCode !== 'string') {
  throw new Error('Workflow must contain a Code node named "Run Neuroreview" with parameters.jsCode');
}
let code = codeNode.parameters.jsCode;

const provider = env.LLM_PROVIDER || 'openrouter';
const openRouterModel = env.OPENROUTER_MODEL || 'openai/gpt-oss-20b:free';
const openAiModel = env.OPENAI_MODEL || 'gpt-5.4-nano';

code = code.replace(
  /^const provider = .*?;$/m,
  `const provider = body.provider ?? ${JSON.stringify(provider)};`,
);
code = code.replace(
  /^const model = .*?;$/m,
  `const model = body.model ?? (provider === 'openrouter' ? ${JSON.stringify(openRouterModel)} : ${JSON.stringify(openAiModel)});`,
);
code = code.replace(
  /^const apiKey = .*?;$/m,
  `const apiKey = provider === 'openrouter' ? ${JSON.stringify(env.OPENROUTER_API_KEY || '')} : ${JSON.stringify(env.OPENAI_API_KEY || '')};`,
);
code = code.replace(/^const gitToken = .*?;$/m, `const gitToken = ${JSON.stringify(env.GIT_TOKEN || '')};`);
code = code.replace(/^const webhookToken = .*?;$/m, `const webhookToken = ${JSON.stringify(env.WEBHOOK_TOKEN || '')};`);

codeNode.parameters.jsCode = code;
fs.writeFileSync(outputFile, JSON.stringify(workflow, null, 2));
NODE

public_n8n_url="$(grep -E '^PUBLIC_N8N_URL=' "$env_file" | cut -d= -f2- || true)"
public_n8n_url="${public_n8n_url:-http://localhost:5678/}"
if ! node -e "const u = new URL(process.argv[1]); if (!['http:', 'https:'].includes(u.protocol)) process.exit(1)" "$public_n8n_url"; then
  echo "Invalid PUBLIC_N8N_URL: must be an http(s) URL" >&2
  exit 1
fi
network_args=()
if docker network inspect vpn_default >/dev/null 2>&1; then
  network_args=(--network vpn_default)
fi

docker rm -f speedsters-n8n >/dev/null 2>&1 || true
rm -rf "$repo_root/n8n/n8n_data"
mkdir -p "$repo_root/n8n/n8n_data"
chown -R "${N8N_DATA_UID:-1000}:${N8N_DATA_GID:-1000}" "$repo_root/n8n/n8n_data"

if ! docker run --rm \
  -e N8N_SECURE_COOKIE=false \
  -e N8N_RUNNERS_ENABLED=false \
  -e N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true \
  -e N8N_BLOCK_ENV_ACCESS_IN_NODE=true \
  -v "$repo_root/n8n/n8n_data:/home/node/.n8n" \
  -v "$local_workflow:/workflows/neuroreview.workflow.json:ro" \
  n8nio/n8n:1.91.3 import:workflow --input=/workflows/neuroreview.workflow.json >/tmp/n8n_import.log; then
  cat /tmp/n8n_import.log >&2
  exit 1
fi

if ! docker run --rm \
  -e N8N_SECURE_COOKIE=false \
  -e N8N_RUNNERS_ENABLED=false \
  -e N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true \
  -e N8N_BLOCK_ENV_ACCESS_IN_NODE=true \
  -v "$repo_root/n8n/n8n_data:/home/node/.n8n" \
  n8nio/n8n:1.91.3 update:workflow --all --active=true >/tmp/n8n_update.log; then
  cat /tmp/n8n_update.log >&2
  exit 1
fi

docker run -d \
  --name speedsters-n8n \
  --restart unless-stopped \
  -p 127.0.0.1:5678:5678 \
  "${network_args[@]}" \
  -e N8N_HOST=0.0.0.0 \
  -e N8N_PORT=5678 \
  -e N8N_PROTOCOL=http \
  -e WEBHOOK_URL="$public_n8n_url" \
  -e N8N_SECURE_COOKIE=false \
  -e N8N_RUNNERS_ENABLED=false \
  -e N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true \
  -e N8N_BLOCK_ENV_ACCESS_IN_NODE=true \
  -e GENERIC_TIMEZONE=Etc/UTC \
  -v "$repo_root/n8n/n8n_data:/home/node/.n8n" \
  n8nio/n8n:1.91.3 >/dev/null

echo "n8n is starting at http://localhost:5678"
echo "Webhook: POST http://localhost:5678/webhook/speedsters-neuroreview"
