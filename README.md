# depiedencap-rag — Discourse-embedded RAG agent

📘 Ce projet est également disponible en [français 🇫🇷](./README.fr.md)

> ⚠️ **Work in progress.** The agent is currently being tested on a
> restricted demo group and is **not publicly deployed** on the forum.
> This repository documents the work — no demo URL is published.

A **Discourse plugin** + a self-hosted RAG pipeline, built for a French
community forum (Depiedencap — men's shoes, 424 835 posts / 22 230
topics). Product principle: **the bot points members to existing threads
instead of answering in their place.**

## What it does

- **Post-grain retrieval** (not topic-grain): `bge-m3` embeddings in
  `ai_posts_embeddings` (pgvector inside the forum's Postgres on the VPS),
  top-25 by cosine then **cross-encoder rerank** (TEI on the mini PC),
  per-thread dedup.
- **Multi-turn query rewriting**: the latest message plus earlier turns
  are condensed into a standalone query (*condense question* /
  history-aware retriever). Same resident model as generation:
  `qwen3:30b-a3b-q6k` (MoE, ~3B active, `think:false`) — not a separate
  small rewriter.
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

The plugin runs **inside Discourse on the VPS**. The mini PC is only the
inference backend (Ollama + TEI), reached over Tailscale. Gate, pgvector
and the citation sanitizer never leave the VPS.

```
Member question
        │
        ▼
[VPS]  Discourse + this Ruby plugin
        │
        ├─ 1. gate        regex, local, 0 LLM
        │
        ├─ 2. rewrite     ──Tailscale──►  [mini PC] Ollama  qwen3:30b-a3b-q6k
        │
        ├─ 3. embed       ──Tailscale──►  [mini PC] Ollama  bge-m3
        │
        ├─ 4. pgvector    Postgres local, 424 835 posts, cosine top-25
        │
        ├─ 5. rerank      ──Tailscale──►  [mini PC] TEI     mmarco-mMiniLMv2
        │
        ├─ 6. generate    ──Tailscale──►  [mini PC] Ollama  qwen3:30b-a3b-q6k
        │
        └─ 7. sanitizer   URL whitelist, local Postgres
                │
                ▼
          answer + /t/slug/id/post_number links
```

| Lives on the VPS | Lives on the mini PC (k3s, iGPU) |
|---|---|
| Discourse, this plugin, Postgres/pgvector | Ollama (`bge-m3` + `qwen3:30b-a3b-q6k`) and TEI (`mmarco`) |

`qwen3:30b-a3b-q6k` is a single resident MoE (~3B active) used for both
rewrite (`think:false`) and generation.

Deliberate choice: **no RAG framework** (LangChain & co.) — a linear
pipeline in direct code, instrumented for evaluation. Full reasoning:
[`docs/rag/DESIGN.md` §9](docs/rag/DESIGN.md#user-content-9-pourquoi-pas-langchain).

## Measured results (real corpus, 812-question eval set)

| Metric | Value |
|---|---|
| Hit@5 retrieval | **0.97** |
| MRR | 0.89 |
| Safety (red-team, gate, refusal, evidence injection) | 20/20 |
| Rerank overhead | ~100 ms |

**Hit@5** : share of eval questions whose expected thread (or post) appears
in the **top 5** retrieved results. 0.97 means the right source is in that
shortlist 97 times out of 100. It does not say *where* in the five.

**MRR** (Mean Reciprocal Rank) : scores the **rank of the first** relevant
hit, then averages. Rank 1 → 1, rank 2 → 0.5, rank 5 → 0.2, not in the
list → 0. 0.89 means the first good hit is usually 1st or 2nd, not merely
"somewhere in the top 5".

Hit@5 = recall ("did we miss it?"). MRR = ranking ("did we put it first?").
Protocol and formulas :
[`docs/rag/EVAL.md` §2](docs/rag/EVAL.md#user-content-2-métriques).

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
