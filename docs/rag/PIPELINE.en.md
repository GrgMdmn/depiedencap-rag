# RAG pipeline — from Postgres to the bot reply

📘 Cette page est également disponible en [français 🇫🇷](./PIPELINE.md)

Architecture document: the full path of a user question, from raw forum
data to the cited answer. See [`DESIGN.en.md`](DESIGN.en.md) for the
structural choices and [`EVAL.en.md`](EVAL.en.md) for measured metrics.

## Overview

```
POSTGRES (posts, topics)                    ← Discourse replica/prod
   │
   │  [offline, once per piece of content]
   ▼
bge-m3 → 1024-d vector                      ← embedding model (Ollama)
   │    ai_posts_embeddings (pgvector)
   │
USER QUESTION                               ← at query time
   │
   ├─► STAGE 0 — input gate (optional, deterministic)
   │      regex on INTENT (not topics) → immediate decline
   │      if danger/illegal/misuse detected — see SAFETY.en.md
   │
   ├─► STAGE 1 — recall
   │      question → bge-m3 → cosine over 425k post vectors → top-25
   │      (+ BM25 keyword channel / semantic topic in RRF fusion)
   │
   ├─► STAGE 2 — precision (rerank)
   │      mmarco cross-encoder: score (question, candidate) ×25 → re-sort
   │
   ├─► aggregation: dedup by topic → top-5/6 sources
   │      + graduated zone on top-1 CE score:
   │        < −4 → empty-evidence block (abstention)
   │        [−4, 0) → WEAK block (sources + "assume the weakness")
   │        ≥ 0 → normal "STABLE FORUM EVIDENCE" block
   │      (config D: ± neighbouring posts for context)
   │
   ▼
System prompt = persona + refusal clause (SAFETY.en.md)
   │   + evidence block: titles + excerpts + citation rules
   │     strict [[1]]..[[6]] + "evidence does not widen your scope"
   ▼
LLM (mini PC) → drafted answer + [[n]] markers
   │
   ▼
Server sanitizer: [[n]] → /t/slug/id URLs  ← links built server-side,
                                               never by the LLM
```

## Models in play

| Model | Type | Role | Where it runs |
|---|---|---|---|
| **bge-m3** | bi-encoder (embedding) | text → 1024-dim vector. Encodes each post **once** (backfill) and each question **at query time** | Ollama — RTX 2060 laptop in dev; Ollama mini PC `:32134` in prod |
| **cross-encoder mmarco-mMiniLMv2-L12-H384** | cross-encoder | relevance score of a **pair** (question, candidate) — reads both together | dev: `sentence-transformers` laptop CPU; **prod: TEI `/rerank` on the mini PC** (k3s pod `reranker`, NodePort 32136, Tailscale only) |
| **chat LLM `qwen3:30b-a3b-q6k`** | generative (MoE ~3B active) | writes the answer from the 6 provided sources **+** multi-turn query rewrite (`condense_query`, `think:false`) | mini PC (Ollama `:32134`) — **one resident model** for both roles |
| Postgres/pgvector | — | storage + cosine/hamming distance | Discourse container (VPS in prod) |

### Why a 30B MoE on a modest iGPU — the structural choice

The mini PC 780M iGPU has **no dedicated VRAM**: weights live in unified
RAM (GTT, tens of GiB). Two consequences:

- **Capacity**: a quantized 30B (~20+ GiB) fits where a same-form-factor
  dGPU would cap at 8-16 GB VRAM — the limiter is system RAM, of which
  we have 48 GB.
- **Speed**: iGPU inference is **memory-bandwidth bound** (each token
  rereads the active weights). A MoE activates only ~3B parameters per
  token → throughput stays high despite total model size. Measured:
  query rewrite in **~1.0 s** hot vs 1.6 s for a dense llama3.1:8B — the
  "big" model is faster than the small one **because it is MoE**.

That is why query rewriting moved from `llama3.1:8b` to the main LLM
(D10, 17/09): faster, equal or better quality, and one fewer resident
model to keep warm in RAM.

### Bi-encoder vs cross-encoder — why both

They are **not competitors** but two complementary stages:

- **bge-m3 (bi-encoder)**: question and post are encoded **separately**.
  The post vector is precomputed → comparing 425k vectors = a few ms.
  But the model never "sees" the pair together: relevance is indirect
  (geometric proximity).
- **cross-encoder**: takes the concatenated pair `(question, candidate)`
  as input → direct, token-level relevance judgment. More precise, but
  impossible to precompute: using it alone would cost 425k scorings per
  question. So it only **re-sorts the top-25** from pgvector.

Hence: cosine for **recall** (miss nothing), cross-encoder for **fine
ranking** (order well). Cosine is never dropped.

## Measured latency (i5-10300H laptop)

| Step | Cost |
|---|---|
| question embedding (bge-m3) | ~ms (one vector) |
| pgvector cosine top-25 on 425k rows | ~ms (HNSW/scan index) |
| cross-encoder rerank, 25 pairs | **~75-100 ms** (~3-4 ms/pair) |
| model load (once, at boot) | ~5 s |
| LLM generation | **several seconds** (the real bottleneck) |

→ Rerank adds ~100 ms per query: **negligible** next to LLM generation.
In prod it runs on the **mini PC** (k3s pod `rag-depiedencap/reranker`,
TEI `cpu-1.6`, NodePort 32136 — not on the VPS, whose RAM is tight
~300-400 MiB free). Checked: TEI/ONNX logits are **identical** to
`sentence-transformers` PyTorch → thresholds measured in eval (-4 / 0)
stay valid in prod; the plugin converts the TEI sigmoid score back to
a logit.

## Detailed steps

### 1. Indexing (offline)

Each eligible post → `ai_posts_embeddings` (one row per post):

- embedded text = `thread title + category + tags + post body`
  (native `post_truncation` strategy, `strategy_id=1`, truncated at
  `max_sequence_length - 2`)
- **post grain** is the structural decision: a 2 700-post thread has a
  diluted, invisible topic vector, while its individual posts stay sharp
  (measured: Hit@5 0.68 → 0.94, see `EVAL.en.md`)
- rejected after measurement: OP/parent-enriched text (`strategy_id=2`,
  -9 Hit@5 points — dilutes the post, EVAL.en.md §4quater)

### 2. Retrieval (per question)

- **posts**: direct cosine on `ai_posts_embeddings` → top-25 posts
- **keyword**: `Search.execute` (Discourse BM25) on distinctive words
- **semantic**: native `SemanticSearch` on topic embeddings
- **hybrid (prod fallback)**: custom fusion `Retrieval.retrieve` +
  title gate + boosts — prod state before this work, kept as fallback
  (`depiedencap_ai_citations_posts_pipeline=false` or empty posts table
  or error)
- **RRF fusions**: `Σ 1/(60+rank)` over the lists — posts×hybrid is the
  best measured combination (+0.01 MRR vs posts alone)
- rejected: routing by thread size (RRF already routes implicitly)

### 3. Rerank (config E)

Top-25 posts → `cross-encoder/mmarco-mMiniLMv2-L12-H384-v1` score
`(question, title + 300c excerpt)` → re-sort → dedup by topic.
Measured: Hit@5 0.94 → **0.97**, MRR 0.84 → **0.89** (with hybrid fusion).

### 4. Generation (evaluated — `run_full_eval.py`, real mini-PC LLM)

- the 6 best sources → `STABLE FORUM EVIDENCE` prompt with strict rules
  (cite `[[n]]`, never write a URL, abstain if empty)
- **three evidence zones** from top-1 CE score (EVAL.en.md §4.4):
  abstention `< −4`, cautious framing `[−4, 0)`, normal `≥ 0`
- **refusal clause** in the system prompt + role-limit reminder in the
  evidence template (SAFETY.en.md — 20/20 probes)
- the LLM writes; the sanitizer resolves `[[n]]` → `/t/slug/id`
  **server-side** — the LLM cannot invent a link
- measured: valid citations, OOD abstention, refusal/abuse, evidence
  injection, quality regression (A/B n=133 — no degradation outside the
  weak zone)

## File map

| What | Where |
|---|---|
| Prod retrieval (fusion, gate, prompt) | `discourse_plugin/depiedencap-ai-citations/lib/retrieval.rb` |
| Enriched backfill (config C, rejected) | `rag/eval/backfill_enriched.rb` |
| Retrieval eval (inside the container) | `rag/eval/eval_retrieval.rb` |
| Metrics + fusions + rerank harness | `rag/eval/run_eval.py` |
| End-to-end generation eval | `rag/eval/eval_full.rb` + `run_full_eval.py` |
| Question set + goldens | `rag/eval/questions.yml` |
| Safety probes (refusal/injection) | `rag/eval/safety.yml` |
| Input gate (regex rules) | `rag/eval/input_gate.yml` |
| System-prompt variants | `rag/eval/prompt_clauses/` |
| Timestamped results | `rag/eval/results/*.json` |
| Measurements and decisions | `rag/EVAL.md` + `rag/SAFETY.md` (FR) / `EVAL.en.md` + `SAFETY.en.md` |
| Local forum environment | `rag/LOCAL_DEV.md` (French working doc) |
| Pre-deploy prod snapshots | `rag/prod_snapshots/` |

## Production port (15/09/2026)

The v2 channel lives in `Retrieval` behind two site settings
(`depiedencap_ai_citations_posts_pipeline`, `depiedencap_ai_citations_input_gate`,
both **false by default** → deploying the code changes nothing until the
flags are flipped):

- `retrieve_posts_pack`: `vector_from(question)` (bge-m3 mini PC) → cosine
  `ai_posts_embeddings` top-25 → `POST /rerank` (mini PC :32136) → topic
  dedup → 6 sources with post-grain URL `/t/slug/id/post_number`
- **exclusions added vs eval** (prod only): `post_type=regular`,
  non-deleted posts/topics, `archetype='regular'` (no PMs),
  `read_restricted` categories excluded — the legacy channel had
  `Guardian`/`Search`; direct SQL must filter itself
- **input gate**: `Retrieval.gate_match` in `PlaygroundHook`
  (reply_to + schedule_bot_reply) → `publish_canned_reply!` posts the
  fixed reply with no LLM; tagged `depiedencap_ai_citations=t` → the
  sanitizer skips it
- **measured fallbacks**: flag off → legacy; empty `ai_posts_embeddings`
  → legacy (`posts_table_ready?` guard, 60 s cache); embeddings endpoint
  down → legacy; reranker down → cosine order only, zone `:ok` (config B
  measured 0.94)
- deploy: `docker cp` plugin → container + `/shared/…` + `sv restart
  unicorn` (Ruby only, no precompile)

Native posts backfill (`Jobs::EmbeddingsBackfill`, 5 min, `low` queue)
was enabled with `ai_embeddings_per_post_enabled=true` +
`ai_embeddings_backfill_batch_size` raised temporarily — it produces
`(model_id=1, strategy_id=1, strategy_version=1)`, exactly the winning
evaluated strategy. Flags flip only once backfill is done.
