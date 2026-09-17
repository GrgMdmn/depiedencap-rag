# Design — post-grain RAG (Depiedencap)

📘 Cette page est également disponible en [français 🇫🇷](./DESIGN.md)

> **Last update**: 17/09/2026 · **Status**: winning config (E: native posts
> + rerank) measured; code in prod on the VPS, member flags still **OFF**,
> agent limited to a demo group. §0 below is a **historical snapshot**
> (topic grain) — current architecture:
> [`README.en.md`](../../README.en.md) · [`PIPELINE.en.md`](PIPELINE.en.md).
> Results: [`EVAL.en.md`](EVAL.en.md) · Safety: [`SAFETY.en.md`](SAFETY.en.md) ·
> References: [`REFERENCES.en.md`](REFERENCES.en.md)

## 0. Current state (snapshot)

- **Index**: `ai_topics_embeddings` — 1 vector/topic (bge-m3, 1024 dims,
  4096-token input), 22 340 rows. pgvector storage in the forum DB.
- **Retrieval** (`retrieval.rb`): `Search.execute` (keyword) +
  `SemanticSearch` (pgvector, HyDE off), custom fusion (base rank + title
  bonus + hybrid bonus +12), mandatory title filter (distinctive word ≥ 6
  chars / stem), FR stopwords, hard-coded `INTENT_QUERIES`, 2 h cache,
  max 6 sources.
- **Evidence**: titles + 320-char excerpts injected server-side; the LLM
  emits bare `[[n]]`; sanitizer → URL whitelist (`Topic.exists?`), Sources
  footer + CTA.

### Known weaknesses

| Weakness | Cause |
|---|---|
| Megathreads invisible in detail | 1 vector / 300 posts = dilution + 4096 truncation |
| Citation to the whole thread | `[[n]]` → `/t/slug/id`, not the precise message |
| Evidence without context | Isolated 320-char excerpt, unresolved anaphora |
| Ad-hoc fusion | Custom score, not a standard method (RRF) |

## 1. Storage schema (decided)

**Vectors in the forum Postgres** (pgvector), no external store.
Rationale: atomicity with `posts`, free backup inside the `.tar.gz`, the
local dev forum gets its copy automatically.

| Table | Content | Status |
|---|---|---|
| `ai_topics_embeddings` | 1 vector/topic (native discourse-ai) | existing, **kept** (related topics + fallback) |
| `ai_posts_embeddings` | 1 vector/post, native `strategy_id=1` + enriched `strategy_id=2` (test) | **implemented** — see note below, replaces `dpec_post_embeddings` |

> **Revision D2 (14/09)**: the custom table `dpec_post_embeddings` was
> **not** created — decision changed mid-course. Native
> `ai_posts_embeddings` with key `(model_id, strategy_id, post_id)` does
> the same job (several representations of the same post coexist) without
> duplicating infra (index, purge, backfill job). `strategy_id=1` = native
> discourse-ai (title+cat+tags+body, free, **this is the winner**),
> `strategy_id=2` = OP/parent enriched (measured, rejected — see
> EVAL.en.md §4.2). Custom would have remained necessary only for C4
> (LLM blurb), never implemented (see §8).

> Why a **custom** table rather than native `ai_posts_embeddings`:
> native backfill embeds bare `post.raw` — no way to inject context
> (title/OP/parent). Custom table = full control of the embedded text +
> metadata (post_number, topic_id, text hash, model).
> `ai_posts_embeddings` stays disabled (`ai_embeddings_per_post_enabled=false`).
>
> Findings from the local restore (12/09): the native table already exists
> with `embeddings halfvec` + **HNSW binary-quantized** index per
> `(model_id, strategy_id)` — unique key `(model_id, strategy_id, post_id)`.
> **And** native strategy `Truncation#post_truncation` already embeds
> "title + category + tags + post body" — partial enrichment is **free**
> by turning on `ai_embeddings_per_post_enabled`. What remains custom:
> parent/OP excerpt and our metadata. A custom `strategy_id` in the native
> table would give fully enriched vectors while reusing index + purge —
> a serious option before creating `dpec_post_embeddings` — see D2.

Proposed schema:

```sql
post_id      bigint PK FK → posts.id
topic_id     bigint  (denormalised, fast filter/aggregation)
post_number  int     (citation anchor)
embedding    vector(1024)
source_hash  char(40) -- sha1 of the embedded enriched text (detects edits)
model        text    -- 'bge-m3' (a model change = incompatible vectors)
embedded_at  timestamptz
```

Index: **to be measured** — brute force `ORDER BY embedding <=> $q`
(cosine) on ~300-400k rows ≈ 200-500 ms, may be enough on a path where
the LLM takes seconds. Otherwise HNSW (`vector_cosine_ops`, tune `m`/`ef`)
— recall ~95-99 %, RAM-heavy build on the 8 GB VPS.

## 2. Embedded text (enrichment)

A bare post fails on anaphora ("it was rubbish" → rubbish **what**?).
Context resolves most references. Candidate text to embed:

```
[topic title] › [OP excerpt if post_number > 1] › [parent-post excerpt
if a formal reply] › [cleaned post.raw]
```

Variants to test (matrix §4):

| Code | Embedded text | Index cost |
|---|---|---|
| `B` | bare `post.raw` | minimal |
| `C1` | `title + post.raw` | minimal |
| `C2` | `title + OP excerpt + post.raw` | minimal |
| `C3` | `C2 + parent excerpt` (reply_to_post_number / quote) | minimal |
| `C4` | `C3 + LLM blurb` ("in this thread about X, this message says…") | 1 LLM call/post — expensive, bound to a subset |

> C4 = Anthropic "Contextual Retrieval" literally (−35 % top-20 failures
> on its own). C1-C3 = the free version. The literature suggests the main
> gain is *situating* the chunk, not necessarily the LLM.

Note: an orphan post (a reply that does not quote a neighbour) does
**not** need to be retrieved itself — it will be read via neighbourhood
expansion of the neighbouring post that *does* carry the context (§3).

## 3. Two-stage retrieval (small-to-big)

```
question
  → embed query (bge-m3, same instance)
  → top-K posts (pgvector) + top-M topics (existing keyword Search)
  → RRF fusion (k=60)                       ← replace custom scoring?
  → aggregate by topic: 1 entry/thread, score = max(posts in thread)
  → evidence block: per entry,
       title + targeted post excerpt + ±N neighbouring posts
  → LLM: citations [[n]] → sanitizer → /t/slug/id/post_number
```

- **Aggregate by topic**: stops a megathread monopolising the 6 evidence
  slots. Topic score = best post (or mean of top-2, to test).
- **Neighbourhood** (`window` ±2 or ±3 posts, parameter): carries context,
  resolves anaphora at **read** time — not at index time. Sentence-window
  retrieval applied to posts.
- **Post-level citation**: `[[n]]` → `/t/slug/topic_id/post_number`.
  Sanitizer whitelist: `Post.exists?` (not only `Topic.exists?`).

## 4. Config matrix — results (14/09/2026)

| Config | Description | Hit@5 | MRR | Verdict |
|---|---|---|---|---|
| `A` | topics (then-current prod) | 0.68 | 0.63 | live baseline |
| `B` | native posts (strategy_id=1) | **0.94** | 0.84 | **kept** — the main gain |
| `C` | OP/parent-enriched posts (strategy_id=2) | 0.85 | 0.80 | **measured, rejected** — dilutes the vector |
| `D` | ±N neighbourhood at generation time | — | — | not tested in isolation (rerank + 320c evidence covers the need in practice) |
| `E` | B + mmarco cross-encoder rerank | **0.97** | **0.89** | **kept — winning config** |
| `F` | RRF posts×hybrid fusion | 0.95 | 0.88 | measured, marginal on E (+0.01 MRR), optional |
| `G` | routing by topic size | 0.93-0.95 | 0.77-0.86 | **measured, rejected** — degrades MRR vs free fusion |

Full detail, methodology and measured n: `EVAL.en.md` §1-4.
Each config compared by changing **one** factor at a time.
Safety of config E (refusal, gate, injection): `SAFETY.en.md`.

Secondary variables to explore later: top-K (10/20/50), embed input
length (1024 vs 4096), title-filter threshold, window size.

## 5. Corpus to index

| Choice | Position |
|---|---|
| Categories | **All public ones** ("forum life" questions are legitimate) |
| PMs | **Never** (existing product decision) |
| Min length | To calibrate — posts < ~30-40 chars likely excluded ("+1", "thanks!") |
| Deleted / staff posts | excluded (`deleted_at`, non-public categories) |
| Estimated volume | ~300-350k indexable posts out of ~425k |

## 6. Cost and load

- **Backfill**: ~300k bge-m3 embeddings. Laptop CPU ~10-20/s → 4-8 h
  (several nights OK). Prod: same model on the mini-PC iGPU, faster.
- **Query**: 1 embed (~50-200 ms) + 1 SQL similarity + expansion =
  negligible next to LLM generation.
- **VPS storage**: ~300-400k × (1024 dims × 4 B + row overhead)
  ≈ **2-3 GB** — tenable vs ~13 GB free, to watch.
- **Incremental**: 1 embed per new post (async Sidekiq job), + re-embed
  if `source_hash` changes after an edit.

## 7. Decisions

| # | Date | Decision | Why |
|---|---|---|---|
| D1 | 12/09/2026 | Vectors in the forum Postgres, no external store | Atomicity, backup in the `.tar.gz`, free local replica |
| D2 | 12/09/2026, **revised 14/09** | Native `ai_posts_embeddings` (`strategy_id`), no custom table | Same need (multi-representation coexistence) without duplicating index/purge/backfill |
| D3 | 12/09/2026 | Dev: bge-m3 **local laptop CPU/GPU**, LLM on mini PC | Dev/prod isolation; NUM_PARALLEL=2 is risky for the 30B |
| D4 | 13/09/2026 | RRF measured vs custom fusion — kept as option (F), not mandatory | Marginal gain (+0.01 MRR) on winning config E |
| D5 | 13/09/2026 | Config B (bare posts) kept as base, C (enriched) rejected | Measured: 0.94 vs 0.85 Hit@5 — OP/parent context dilutes the vector |
| D6 | 14/09/2026 | Config E (B + cross-encoder rerank) = final retrieval | Measured: 0.97 Hit@5 / 0.89 MRR, ~100 ms cost negligible |
| D7 | 14/09/2026 | G (routing by size) rejected | Measured at scale (796): degrades MRR vs free fusion |
| D8 | 14/09/2026 | Abstention/scope: graduated zone on CE score (no hard threshold) + deterministic input gate + refusal clause in the prompt | No threshold cleanly separates in-domain/off-topic (overlapping distributions) — see SAFETY.en.md |
| D9 | 17/09/2026 | **No LangChain** — patterns reused without the dependency | See [§9](#user-content-9-why-not-langchain) |
| D10 | 17/09/2026, **revised same day** | Multi-turn query rewrite (`condense_query`) via **`qwen3:30b-a3b-q6k`** — the main LLM, not a dedicated model | Retrieval only saw the last message; real bug in usage. First cut `llama3.1:8b` (qwen3:4b swallowed its budget in `reasoning`); comparative test → the MoE (~3B active) condenses in ~1.0s vs 1.6s, equal quality, **one fewer resident model** in RAM. `think:false` forced in the request (thinking guardrail, ignored without error by non-thinking models) |

## 8. Open questions — status

- ~~`OP excerpt` in the enriched text~~ → **settled**: measured and rejected (D5/D2).
- Neighbourhood window (config D): **not measured in isolation** — rerank +
  320c excerpt is enough in practice on the end-to-end eval (`SAFETY.en.md`
  run 812); revisit only if unresolved anaphora shows up in real use.
- Reranker: **settled** — yes, +0.03 Hit@5 / +0.05 MRR for ~100 ms.
  Runs on CPU; mini PC or VPS EPYC Rome both sufficient
  (measured: `PIPELINE.en.md`).
- Abstention: **settled** — not a single threshold, graduated zone
  (`< -4` abstain, `[-4,0)` cautious, `≥0` normal) + input gate
  for the safety axis (independent of relevance). See SAFETY.en.md.
- Hand-coded `INTENT_QUERIES` (then-current prod): **not carried** into the
  new pipeline — the cross-encoder rerank covers that need without ad-hoc
  rules to maintain; confirm if a regression case appears.
- Config D (generation neighbourhood), config F (RRF): optional,
  measured marginal gain — not needed for the MVP.

## 9. Why not LangChain

LangChain is a **library** (Python/JS — not an LLM, not a service to
deploy) that provides LLM orchestration bricks: retrieval, memory, query
rewriting, tools. It is the most common framework for *prototyping* a RAG
— hence its presence in job ads.

**Why we do not use it here** — an architecture choice, not a rejection of
the idea:

- Our pipeline lives in a **Discourse Ruby plugin**, inside the forum
  process. LangChain would mean a separate Python service to deploy,
  maintain and secure — a new failure point between the forum and the
  mini PC, to re-implement logic that is already linear.
- We already do the same steps in direct code (~600 lines):
  embed → pgvector → cross-encoder rerank → LLM → sanitizer. No need
  for an abstraction on a linear, instrumented pipeline (the
  `eval_full.rb` eval calls the functions directly).
- If we one day wanted **agentic** capabilities (the bot picks its tools,
  chains searches), a dedicated service would become defensible —
  LangChain/LangGraph would then be candidates. Not the current roadmap.

**What we still took from that world**: **conversational query rewriting**
(*condense question* / *history-aware retriever* pattern from LangChain,
and QReCC/CANARD literature) — implemented in `Retrieval.condense_query`:
latest message + the previous 3 turns → a standalone query before
embedding. The rewriting model is **the same Qwen3-30B as generation**
(D10) — see PIPELINE.en.md "why a MoE".
