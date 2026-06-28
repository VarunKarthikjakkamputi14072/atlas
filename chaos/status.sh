#!/usr/bin/env bash
# Print the live resilience metrics — handy with `watch -n2 ./chaos/status.sh`.
set -uo pipefail
M=$(curl -s http://localhost:8002/metrics 2>/dev/null)
g() { echo "$M" | grep -E "^$1 " | awk '{print $2}'; }
echo "vector store points : $(g meridian_vectorstore_points)   (peak $(g meridian_vectorstore_peak_points))"
echo "store healthy        : $(g meridian_vectorstore_healthy)   (1=intact, 0=corrupted)"
echo "repairs triggered    : $(g meridian_vectorstore_repairs_total)"
echo "rag drift share      : $(g meridian_rag_drift_share)"
echo "re-embeds (drift)    : $(g meridian_reembeds_triggered_total)"
qc=$(curl -s -X POST http://localhost:6333/collections/hermes-chunks/points/count -H 'Content-Type: application/json' -d '{"exact":true}' 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['count'])" 2>/dev/null || echo "?")
echo "qdrant actual count  : $qc"
