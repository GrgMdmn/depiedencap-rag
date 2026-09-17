# depiedencap-rag — Discourse-embedded RAG agent

📘 Ce projet est également disponible en [français 🇫🇷](./README.fr.md)

> ⚠️ **Work in progress.** The agent is currently being tested on a
> restricted demo group and is **not publicly deployed** on the forum.
> This repository documents the work — no demo URL is published.

A **Discourse plugin** + a self-hosted RAG pipeline, built for a French
community forum (Depiedencap — men's shoes, ~428k posts). Product
principle: **the bot points members to existing threads instead of
answering in their place.**

## What it does

- **Post-grain retrieval** (not topic-grain): `bge-m3` embeddings in
  `ai_posts_embeddings` (pgvector inside the forum's Postgres), top-25 by
  cosine then **cross-encoder rerank** (TEI), per-thread dedup.
- **Multi-turn query rewriting**: the latest message plus earlier turns
  are condensed into a standalone query by a small dedicated model before
  retrieval (*condense question* / history-aware retriever pattern).
- **Server-side verified citations**: the LLM only emits bare `[[n]]`
  markers; the plugin maps them to `/t/slug/id/post_number` links and
  discards any link that does not actually exist in Postgres (URL
  whitelist — the LLM never gets the last word on a link).
- **Graduated evidence zones** (abstain / cautious / normal) driven by
  reranker score + a **deterministic input gate** (intent regexes) for
  dangerous or out-of-role requests — zero LLM calls.
- Graceful degradation: embedding or reranker endpoint down → legacy
  fallback / honest abstention, never invention.

## Architecture

```
Discourse (Ruby plugin, inside the forum process)
   │  question → gate → rewrite (small model) → embed → pgvector → rerank → LLM → sanitizer
   ▼
Self-hosted mini PC (k3s)                      VPS
  Ollama : bge-m3 (embeddings)                   Discourse + Postgres/pgvector
           qwen3 30B MoE (~3B active)           (~428k embedded posts)
             — generation AND query rewriting
             (single resident model)
  TEI    : mmarco-mMiniLMv2 cross-encoder (rerank)
```

Deliberate choice: **no RAG framework** (LangChain & co.) — a linear
pipeline in direct code, instrumented for evaluation. Full reasoning:
[`docs/rag/DESIGN.md`](docs/rag/DESIGN.md) §9.

## Measured results (real corpus, 812-question eval set)

| Metric | Value |
|---|---|
| Hit@5 retrieval | **0.97** |
| MRR | 0.89 |
| Safety (red-team, gate, refusal, evidence injection) | 20/20 |
| Rerank overhead | ~100 ms |

Details: [`docs/rag/EVAL.md`](docs/rag/EVAL.md) ·
[`docs/rag/SAFETY.md`](docs/rag/SAFETY.md) ·
[`docs/rag/PIPELINE.md`](docs/rag/PIPELINE.md) ·
[`docs/rag/REFERENCES.md`](docs/rag/REFERENCES.md)

## Repository layout

| Path | Content |
|---|---|
| root (`plugin.rb`, `lib/`, `app/`, `config/`) | The Discourse plugin — installable via `git clone` into `plugins/` |
| `docs/rag/` | Design, evaluation, safety, references, local dev recipe |
| `prompts/` | Production system prompt (v3.1) |
| `tools/` | Live smoke test (Discourse API) |

## Security & privacy

- No internal endpoint, IP or account is published (sanitised export from
  the private working repo + automated denylist check).
- The agent stays limited to a demo group during the observation phase;
  documented < 5 min rollback.
- The bot refuses dangerous, illegal or generalist requests and ignores
  hostile instructions found inside retrieved forum excerpts.

## License

AGPL-3.0 — see `LICENSE`.
