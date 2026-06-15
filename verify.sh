#!/usr/bin/env bash
# Smoke test for the ecosystem: assumes `docker compose up -d --build` is already
# running. Checks every service is healthy and that the REAL provider paths work.
set -uo pipefail

pass=0; fail=0
ok()   { echo "  PASS  $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail+1)); }

echo "== 1. services healthy =="
for c in "order-api http://localhost:8080/actuator/health 200" \
         "transit   http://localhost:18080/health 200" \
         "meridian  http://localhost:8002/health 200" \
         "qdrant    http://localhost:6333/healthz 200"; do
  set -- $c
  code=$(curl -s -o /dev/null -w '%{http_code}' "$2" 2>/dev/null)
  [ "$code" = "$3" ] && ok "$1 ($code)" || bad "$1 (got $code, want $3)"
done

echo "== 2. real chat through Transit (NVIDIA NIM, not the stub) =="
KEY=$(curl -s -X POST localhost:18080/auth/register -H 'Content-Type: application/json' \
  -d '{"email":"verify@x.dev","password":"verify-pass-1"}' | sed -E 's/.*"api_key":"([^"]+)".*/\1/')
resp=$(curl -s -X POST localhost:18080/api/v1/chat/completions \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"In one sentence, what is an HbA1c test?"}]}')
prov=$(echo "$resp" | sed -E 's/.*"provider":"([^"]+)".*/\1/')
[ "$prov" = "nvidia-nim" ] && ok "chat provider = $prov" || bad "chat provider = $prov (want nvidia-nim — is the key set?)"

echo "== 3. real embeddings: ingest -> 1024-dim vectors in Qdrant =="
JOB=$(curl -s -X POST localhost:8080/api/ingest -H 'Content-Type: application/json' \
  -d '{"docId":"verify-probe","source":"probe.pdf","chunkCount":5}')
ID=$(echo "$JOB" | sed -E 's/.*"jobId":"([^"]+)".*/\1/')
st=""
for i in $(seq 1 30); do
  st=$(curl -s localhost:8080/api/ingest/$ID | sed -E 's/.*"status":"([^"]+)".*/\1/')
  [ "$st" = "COMPLETED" ] || [ "$st" = "FAILED" ] && break
  sleep 1
done
[ "$st" = "COMPLETED" ] && ok "ingestion job COMPLETED" || bad "ingestion job = $st"
dim=$(curl -s -X POST localhost:6333/collections/hermes-chunks/points/scroll \
  -H 'Content-Type: application/json' -d '{"limit":1,"with_vector":true}' \
  | python3 -c "import sys,json; p=json.load(sys.stdin)['result']['points']; print(len(p[0]['vector']) if p else 0)" 2>/dev/null)
[ "$dim" = "1024" ] && ok "vector dim = $dim (real NVIDIA embeddings)" || bad "vector dim = $dim (want 1024)"

echo "== 4. telemetry tap reached Meridian =="
recv=$(curl -s localhost:8002/metrics | grep -E '^meridian_rag_telemetry_received_total' | awk '{print $2}')
awk "BEGIN{exit !(${recv:-0} > 0)}" && ok "Meridian received telemetry (${recv:-0})" || bad "no telemetry at Meridian"

echo
echo "== result: $pass passed, $fail failed =="
[ "$fail" -eq 0 ] && echo "ECOSYSTEM OK" || echo "see failures above"
exit $fail
