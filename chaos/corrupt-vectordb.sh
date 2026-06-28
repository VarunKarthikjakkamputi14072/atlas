#!/usr/bin/env bash
# CHAOS GREMLIN: poison the vector store by deleting most of its points,
# simulating database corruption / data loss.
#
# Then watch the platform heal itself: Meridian's integrity monitor sees the
# point count collapse, flags the store unhealthy, and triggers a Hermes
# re-embed that rebuilds the corpus — no human, no restart.
#
#   ./chaos/corrupt-vectordb.sh           # delete 80% of points
#   FRACTION=1.0 ./chaos/corrupt-vectordb.sh   # wipe everything
set -uo pipefail

QDRANT=${QDRANT_URL:-http://localhost:6333}
COLL=${COLLECTION:-hermes-chunks}
FRACTION=${FRACTION:-0.8}

count() { curl -s -X POST "$QDRANT/collections/$COLL/points/count" \
  -H 'Content-Type: application/json' -d '{"exact":true}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['count'])" 2>/dev/null || echo 0; }

before=$(count)
echo "💀 chaos: corrupting vector store '$COLL' (deleting ${FRACTION} of points)"
echo "   before: $before points"
if [ "$before" = "0" ]; then
  echo "   nothing to corrupt — ingest something first (or run the demo)."; exit 0
fi

ids=$(curl -s -X POST "$QDRANT/collections/$COLL/points/scroll" \
  -H 'Content-Type: application/json' \
  -d '{"limit":100000,"with_payload":false,"with_vector":false}' \
  | python3 -c "
import sys,json
pts=json.load(sys.stdin)['result']['points']
n=int(len(pts)*float('$FRACTION'))
print(json.dumps([p['id'] for p in pts[:n]]))")

curl -s -X POST "$QDRANT/collections/$COLL/points/delete?wait=true" \
  -H 'Content-Type: application/json' -d "{\"points\":$ids}" >/dev/null

after=$(count)
echo "   after:  $after points  (deleted $((before-after)))"
echo
echo "🔎 watch it heal:  watch -n2 ./chaos/status.sh"
echo "   Grafana:        http://localhost:3000  (the 'points' panel drops, then climbs back)"
