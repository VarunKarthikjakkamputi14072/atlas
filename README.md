# atlas

Orchestration + docs for the self-healing RAG platform built from three repos:
**Hermes** (async ingestion), **Transit** (AI gateway), **Meridian** (RAG drift
monitor). One `docker compose up` boots the whole loop on one network and serves
**real** NVIDIA NIM chat + embeddings — no fakes.

📐 **Read [`ARCHITECTURE.md`](ARCHITECTURE.md)** for the full picture of what the
ecosystem is and how the pieces interlink.

## What atlas is — and isn't

atlas is the **conductor**, not the orchestra. It contains **no project code** —
just the compose file, docs, and a verify script.

- ✅ **Is:** a thin orchestration repo that boots Hermes + Transit + Meridian on
  one network so they form the self-healing loop, plus the docs that explain it.
- ❌ **Isn't:** a copy, fork, or merge of the three projects. The actual code —
  and the integration that makes them talk — lives in each component repo on its
  own feature branch (see Layout). Delete those siblings and atlas has nothing to
  build.

So: each project is standalone and runs on its own; the integration code lives in
each project; atlas just wires the running services together.

## Layout (important)

This repo only orchestrates; it builds the three component repos, which must be
checked out as **siblings** of this folder:

```
Documents/
  atlas/   <- this repo
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

### Chaos engineering — break it, watch it heal 💀

The platform's resilience is only convincing if you can watch it recover. The
chaos gremlin poisons the vector store; Meridian's integrity monitor detects the
collapse and triggers a Hermes re-embed to rebuild it — no human, no restart.

```bash
# (first seed the store, e.g. run verify.sh or ingest a doc, so there's data)
./chaos/corrupt-vectordb.sh          # deletes 80% of the Qdrant points
watch -n2 ./chaos/status.sh          # watch points drop, healthy flip to 0, then recover
```
Open **Grafana** at http://localhost:3000 → "Atlas — Resilience": the *vector
store points* panel craters, *healthy* turns red, *self-heals triggered*
increments, then points climb back as the re-embed rebuilds the corpus.

What you'll see in the metrics:
```
before:  points=30  healthy=1  repairs=0
gremlin: 30 -> 6 points
+3s:     points=6   healthy=0  repairs=1     <- corruption detected, re-embed fired
+9s:     points=16  healthy=1  repairs=1     <- rebuilding
...      points climb back above the floor
```

> Note: the re-embed makes one real NVIDIA embedding call per chunk, so on the
> free tier a large rebuild can rate-limit or stall partway. Lower
> `MERIDIAN_REEMBED_CHUNK_COUNT` for a snappier demo. The detection + trigger is
> instant regardless — that's the resilience story.

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
