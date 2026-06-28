# The AI ecosystem — architecture

Six projects that started as separate products and grew into one platform: three
user-facing RAG/Web3 apps, and three infrastructure services that solve the
problems those apps hit at scale. The three infra services are now wired into a
single **self-healing RAG loop**.

This repo is the orchestration layer — it boots Hermes + Transit + Meridian
together so the whole loop runs in one `docker compose up`. The component code
lives in the sibling repos.

---

## 1. Application layer — the products

| Project | Domain | Stack | What it does |
|---|---|---|---|
| **MedQuery** | Healthcare | Next.js · FastAPI · Pinecone · hybrid retrieval | Clinical-document RAG; hybrid BM25+vector retrieval (recall@5 0.75→0.92). Deployed live. |
| **ChatDoc** | Legal / FinTech | React · FastAPI · LlamaIndex · Qdrant · RAGAS | Exact-clause RAG over contracts/filings; BM25+dense RRF, SSE streaming. |
| **VaultMind** | Web3 / DeFi | Next.js · Wagmi · Prisma | Translates raw on-chain transactions into plain-English risk before signing. Live. |

## 2. Infrastructure layer — the platform

| Project | Origin | Stack | Role in the platform |
|---|---|---|---|
| **Transit** | AI cost-control gateway | FastAPI · Redis · NVIDIA NIM | Sits in front of the LLM providers for the RAG apps: caches identical queries, meters tokens, fails over across providers, and **taps query telemetry** to Meridian. |
| **Hermes** | Java order-fulfillment engine | Spring Boot · Kafka · JPA · Postgres | Its durable async pipeline (idempotent consumers, dead-letter queue, SSE progress) was generalized into an **async document-ingestion bus**: chunk + embed in the background, write to the vector store. |
| **Meridian** | MLOps drift pipeline (taxi regressor) | PyTorch · MLflow · Evidently · Prometheus | Its serve→observe→drift→retrain loop was pointed at a live RAG app: detects when production **queries drift** from the corpus and **triggers a re-embed**. |

> Honest note: Hermes and Meridian were *not* born as RAG infrastructure —
> Hermes is an order engine, Meridian an ML-model monitor. What transfers is each
> one's **reusable primitive** (durable async pipeline; observe→act lifecycle
> loop), which was generalized to serve the RAG apps. The order engine and the
> taxi regressor still exist and still work in their own repos.

---

## 3. The self-healing loop

```
                      writes 1024-dim vectors
   Hermes ingestion ───────────────────────────▶  Qdrant (vector store)
   (Kafka workers,                                     │
    embeds via                                         │ apps read chunks
    NVIDIA NIM)                                         ▼
        ▲                                        MedQuery / ChatDoc
        │ re-embed job                                  │
        │ (POST /api/ingest)                            │ query
        │                                               ▼
   Meridian  ◀──────── taps every query ──────────  Transit (gateway)
   (RAG drift:                                       cache · meter · failover
    Evidently on                                          │
    query telemetry)                                      ▼
                                                   NVIDIA NIM (real Llama-3.3)
```

**Observe on the read path, act on the write path:**

1. A query goes to a RAG app → **Transit** (real NVIDIA NIM answer, cached + metered).
2. Transit **taps** the query's telemetry (length, tokens, latency) to **Meridian** — non-blocking, never affects the user.
3. **Meridian** runs Evidently drift on that telemetry vs the on-corpus baseline. When production queries drift away from what the index covers, it fires a re-embed.
4. The re-embed is a **Hermes** ingestion job: workers embed chunks via **NVIDIA NIM** (`nv-embedqa-e5-v5`, 1024-dim) and upsert to **Qdrant**.
5. The RAG apps read the refreshed vectors from the same Qdrant. The loop closes — serving never stopped.

The apps and the ingestion engine never call each other directly: they meet only
through Kafka (the job) and the shared vector store (Hermes writes, apps read).

---

## 4. The four integration seams

| # | Seam | Where it lives | Mechanism |
|---|---|---|---|
| 1 | Hermes → vector store | hermes `ingestion-bus` | worker embeds via NVIDIA, upserts to Qdrant (idempotent, keyed by `docId:idx`) |
| 2 | vector store → apps | Qdrant collection `hermes-chunks` | apps read; Hermes is the writer |
| 3 | Transit → Meridian | Transit `meridian-telemetry-tap` | fire-and-forget telemetry POST, failure-isolated |
| 4 | Meridian → Hermes | meridian `rag-drift-monitor` | drift breach → POST `/api/ingest` (re-embed) |

All four were verified live end-to-end (2026-06-14): a flood of off-corpus
queries drove drift share to 1.0, fired exactly one re-embed, and Hermes wrote
fresh `rag-corpus` vectors into Qdrant.

### A fifth seam: vector-store integrity (chaos engineering)

Drift isn't the only failure mode — the vector store itself can lose data. A
**vector-store integrity monitor** in Meridian polls Qdrant's point count against
an auto-calibrated high-water mark; when the count collapses (corruption / data
loss) it flags the store unhealthy and triggers the same Hermes re-embed to
rebuild it. Same act-on-the-write-path healing, triggered by data loss instead of
query drift.

This makes resilience demonstrable, not theoretical. `chaos/corrupt-vectordb.sh`
deletes most of the vectors; within one monitor cycle `meridian_vectorstore_healthy`
flips to 0, `meridian_vectorstore_repairs_total` increments, and the corpus
rebuilds — visible live on the Grafana "Resilience" dashboard. Verified
2026-06-14: 30 → 6 points → detected → re-embed → climbing back.

---

## 5. Branches

This is unmerged feature work, one branch per repo:

- **hermes** → `ingestion-bus`
- **Transit** → `meridian-telemetry-tap`
- **meridian** → `rag-drift-monitor`

## 6. Real vs fake

Everything in the running demo is **real**: real NVIDIA NIM chat and embeddings
(free-tier key from `Transit/.env`), real Kafka, Postgres, Qdrant. Offline fakes
(`EMBED_PROVIDER=fake`, `USE_FAKE_PROVIDER`, in-memory store) exist only for unit
tests / CI where no external call should happen — never as a demo default.

See `README.md` to run it.
