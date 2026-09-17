# RAG workstream — post grain, advanced retrieval, evaluation

📘 Cette page est également disponible en [français 🇫🇷](./README.md)

> **Status (17/09/2026)**: plugin + pipeline in prod on the **VPS**
> (Discourse + Postgres/pgvector, 424 835 posts). Inference on the **mini
> PC** (Ollama `bge-m3` + `qwen3:30b-a3b-q6k`, TEI mmarco) via Tailscale.
> Member flags still **OFF**; agent limited to a demo group. Public diagram:
> [`README.en.md`](../../README.en.md). Session resume (French working doc):
> [`PLAN_RAG_PROD_VPS.md`](../PLAN_RAG_PROD_VPS.md).
> Eval: posts+rerank, Hit@5 0.97 — [`EVAL.en.md`](EVAL.en.md) /
> [`SAFETY.en.md`](SAFETY.en.md).

## Languages in this folder

This repo (unlike the others): **unprefixed `.md` = French**, **`.en.md` =
English**. That includes the root README. GitHub only renders `README.md`,
so the landing page is French; the banner links to `README.en.md`.

| Files | Language |
|---|---|
| `DESIGN.md`, `EVAL.md`, `SAFETY.md`, `PIPELINE.md`, `REFERENCES.md`, this folder's `README.md` | French |
| `DESIGN.en.md`, `EVAL.en.md`, `SAFETY.en.md`, `PIPELINE.en.md`, `REFERENCES.en.md`, `README.en.md` | English (linked from root `README.en.md`) |
| `LOCAL_DEV.md`, `prod_snapshots/`, `../PLAN_RAG_PROD_VPS.md` | French only (operator runbooks) |

## Why this workstream

The RAG then in prod indexed **one vector per topic** (~22 340). On
megathreads (300+ messages), a single vector = a diluted semantic
centroid **plus** 4096-token input truncation → precise passages on page
12 are invisible. Goal: **post-grain** retrieval with citations
`/t/slug/id/post_number`, keeping the product principle — **the bot
points to existing threads, it does not answer in members' place**.

It is also a learning workstream: we test industry-standard techniques
(see [`REFERENCES.en.md`](REFERENCES.en.md)), we measure on **our**
corpus, we document.

## Documents

| File | Content |
|---|---|
| [`DESIGN.en.md`](DESIGN.en.md) | Architecture, configs to test, decisions |
| [`REFERENCES.en.md`](REFERENCES.en.md) | RAG literature notes — proven techniques + sources |
| [`EVAL.en.md`](EVAL.en.md) | Eval set, metrics, protocol, retrieval + generation results |
| [`SAFETY.en.md`](SAFETY.en.md) | Red-team, input gate, refusal clause, evidence injection |
| [`PIPELINE.en.md`](PIPELINE.en.md) | End-to-end question→answer architecture + measured latencies |
| `LOCAL_DEV.md` | Recipe: redeploy the forum locally (French) |
| `prod_snapshots/` | Prod state saved before deploy (prompt, settings, rollback) |
| `../PLAN_RAG_PROD_VPS.md` | **Deploy plan + session resume** (French) — read first to continue |

## Dev workflow

```
Dev machine (laptop / desktop)             AI mini PC (prod)
┌────────────────────────────┐             ┌──────────────────────┐
│ Local Discourse = exact    │             │ k3s rag-depiedencap  │
│ VPS replica (.tar.gz)      │             │ Ollama :32134        │
│ + local pgvector           │──Tailscale──►│  qwen3:30b (chat)   │
│ + LOCAL bge-m3 (CPU)       │             │  bge-m3 (prod        │
│   for tests                │             │   embeddings)        │
└────────────────────────────┘             └──────────────────────┘
```

- Dev vectors → **local** pgvector (zero prod risk).
- Dev chat LLM → mini PC (the laptop does not carry a 30B).
- Dev embeddings → **local CPU** bge-m3 (do not clog the prod queue).
- Once the solution is validated: the mini-PC **bge-m3** produces prod
  vectors (same model = compatible vectors).

## Rules

- Never run retrieval/embedding tests against the prod database.
- The local forum **sends no email** (`disable_emails`, see `LOCAL_DEV.md`).
- Every design decision → ADR in [`DESIGN.en.md`](DESIGN.en.md) § Decisions.
- Bench results → [`EVAL.en.md`](EVAL.en.md) (numbers, not feeling).
