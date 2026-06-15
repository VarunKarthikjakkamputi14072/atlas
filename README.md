# ai-ecosystem

Orchestration + docs for the self-healing RAG platform built from three repos:
**Hermes** (async ingestion), **Transit** (AI gateway), **Meridian** (RAG drift
monitor). One `docker compose up` boots the whole loop on one network and serves
**real** NVIDIA NIM chat + embeddings — no fakes.

📐 **Read [`ARCHITECTURE.md`](ARCHITECTURE.md)** for the full picture of what the
ecosystem is and how the pieces interlink.

## Layout (important)

This repo only orchestrates; it builds the three component repos, which must be
checked out as **siblings** of this folder:

```
Documents/
  ai-ecosystem/   <- this repo
  hermes/         (branch: ingestion-bus)
  Transit/        (branch: meridian-telemetry-tap)
  meridian/       (branch: rag-drift-monitor)
```

Confirm the branches:
```bash
for r in hermes Transit meridian; do (cd ../$r && echo "$r: $(git branch --show-current)"); done
```

## Prerequisites

- Docker running (`colima start` if you don't use Docker Desktop).
- `Transit/.env` present with a free-tier `NVIDIA_API_KEY` (already there).

## Run it

```bash
docker compose up -d --build      # first build is slow: Maven + Python images
```

Then either run the one-command check, or drive it by hand.

### One-command smoke test

```bash
./verify.sh
```
Boots nothing extra — assumes the stack is up — and checks: all services healthy,
**real** NVIDIA chat through Transit, a document ingested into **1024-dim** Qdrant
vectors, and the telemetry tap reaching Meridian. Prints PASS/FAIL per check.

### See the self-healing loop (the money shot)

```bash
# 1. mint a key
KEY=$(curl -s -X POST localhost:18080/auth/register -H 'Content-Type: application/json' \
  -d '{"email":"a@x.dev","password":"demo-pass-123"}' | sed -E 's/.*"api_key":"([^"]+)".*/\1/')

# 2. warm up the on-corpus baseline, then snapshot it
for i in $(seq 1 60); do curl -s -o /dev/null -X POST localhost:18080/api/v1/chat/completions \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"What is the patient HbA1c value?"}]}'; done
curl -s -X POST localhost:8002/reference/build

# 3. drift it with off-corpus queries (NEW key — rate limit is 100/hr per key)
KEY2=$(curl -s -X POST localhost:18080/auth/register -H 'Content-Type: application/json' \
  -d '{"email":"b@x.dev","password":"demo-pass-123"}' | sed -E 's/.*"api_key":"([^"]+)".*/\1/')
for i in $(seq 1 60); do curl -s -o /dev/null -X POST localhost:18080/api/v1/chat/completions \
  -H "Authorization: Bearer $KEY2" -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Explain the full genomic variant interpretation pipeline across ancestral populations and multi-omics integration over decades"}]}'; done
sleep 8

# 4. watch it close the loop
curl -s localhost:8002/metrics | grep -E 'rag_drift_share|reembeds_triggered'
curl -s -X POST localhost:6333/collections/hermes-chunks/points/count \
  -H 'Content-Type: application/json' -d '{"exact":true}'
```

Expected: `meridian_rag_dataset_drift 1.0`, `meridian_reembeds_triggered_total`
increments, and `hermes-chunks` fills with points whose payload `docId` is
`rag-corpus` (proof the vectors came from the re-embed, not the warm-up).

Tear down: `docker compose down -v`

## Ports

| Service | URL |
|---|---|
| Transit (gateway) | http://localhost:18080 |
| Hermes order-api | http://localhost:8080 |
| Meridian RAG monitor | http://localhost:8002 |
| Qdrant | http://localhost:6333 |

## Notes

- Real providers mean real latency + free-tier rate limits. Big re-embeds make
  one NVIDIA embedding call per chunk; `MERIDIAN_REEMBED_CHUNK_COUNT` (default 30)
  keeps it modest.
- The component repos still work standalone — this repo just wires them together.
