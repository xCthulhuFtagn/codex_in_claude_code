#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

source ~/.config/claude-code/openai-via-litellm.env
export CHATGPT_TOKEN_DIR="$HOME/.config/litellm/chatgpt"

exec litellm \
  --config "$PWD/litellm.yaml" \
  --host 127.0.0.1 \
  --port 4000
