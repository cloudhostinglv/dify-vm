#!/usr/bin/env bash
# avots-smoke.sh — verify avots.ai OpenAI-compat endpoint is agent-ready (tool-calling).
# Usage: AVOTS_API_KEY=av_mcp_... bash 00-avots-smoke.sh
# Note: each run spends a little of the avots balance.
set -uo pipefail

BASE="${AVOTS_BASE:-https://api.avots.ai/openai/v1}"
KEY="${AVOTS_API_KEY:?export AVOTS_API_KEY=av_mcp_...}"
AUTH="Authorization: Bearer $KEY"; CT="Content-Type: application/json"
command -v jq >/dev/null || { echo "need jq"; exit 1; }

MODELS=("anthropic/claude-opus-4.8" "openai/gpt-5.5-pro" "google/gemini-2.5-pro" "claude" "gpt")

read -r -d '' TOOLS <<'JSON'
[{"type":"function","function":{
  "name":"get_weather","description":"Get current weather for a city",
  "parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}]
JSON

echo "== 1) GET /models =="
code=$(curl -sS -o /tmp/av_models.json -w '%{http_code}' -H "$AUTH" "$BASE/models")
echo "HTTP $code"
[ "$code" = "200" ] && echo "models: $(jq '.data|length' /tmp/av_models.json 2>/dev/null)" \
  || { echo "WARN /models unavailable"; head -c 400 /tmp/av_models.json; echo; }

echo; echo "== 2) plain chat =="
curl -sS -H "$AUTH" -H "$CT" "$BASE/chat/completions" -d '{
  "model":"'"${MODELS[0]}"'","messages":[{"role":"user","content":"Reply with exactly: OK"}]}' \
  | jq -r '.choices[0].message.content // (.error|tostring)'

echo; echo "== 3) tool-calling per model (non-stream) =="
for m in "${MODELS[@]}"; do
  body=$(jq -n --arg m "$m" --argjson tools "$TOOLS" '{model:$m,
    messages:[{role:"user",content:"What is the weather in Riga right now? Call the tool."}],
    tools:$tools, tool_choice:"auto"}')
  resp=$(curl -sS -H "$AUTH" -H "$CT" "$BASE/chat/completions" -d "$body")
  tc=$(echo "$resp" | jq -r '.choices[0].message.tool_calls // empty')
  if [ -n "$tc" ]; then
    n=$(echo "$resp" | jq -r '.choices[0].message.tool_calls[0].function.name')
    a=$(echo "$resp" | jq -rc '.choices[0].message.tool_calls[0].function.arguments')
    echo "  [$m] PASS -> $n($a)"
  else
    err=$(echo "$resp" | jq -r '.error.message // empty')
    [ -n "$err" ] && echo "  [$m] FAIL error: $err" \
      || echo "  [$m] FAIL no tool_calls (answered as text)"
  fi
done

echo; echo "== 4) tool-calling in stream =="
# Write to a file first: avoids the grep -m1 + pipefail SIGPIPE false-negative.
curl -sS -N -H "$AUTH" -H "$CT" "$BASE/chat/completions" -d '{
  "model":"'"${MODELS[0]}"'","messages":[{"role":"user","content":"Weather in Riga? Call the tool."}],
  "tools":'"$TOOLS"',"tool_choice":"auto","stream":true}' > /tmp/av_stream.txt
n=$(grep -c tool_calls /tmp/av_stream.txt || true)
[ "${n:-0}" -gt 0 ] && echo "  PASS: $n stream chunks with tool_calls" || echo "  FAIL: no tool_calls in stream"
