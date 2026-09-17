# References — proven RAG techniques (reading notes)

📘 Cette page est également disponible en [français 🇫🇷](./REFERENCES.md)

> Goal: what industry does, and what applies to our case (French-language
> forum, ~425k posts, megathreads, local 30B LLM).

## 1. Contextual Retrieval — Anthropic (Sept. 2024)

**Source**: anthropic.com/engineering/contextual-retrieval · cookbook:
`claude-cookbooks/capabilities/contextual-embeddings`

- **Problem**: a chunk taken out of its document loses context → the
  retriever cannot judge relevance.
- **Method**: before embedding each chunk, an LLM generates 1-2 sentences
  that situate it ("this chunk comes from X and discusses Y"), prefixed
  to the text. Same for the BM25 index.
- **Reported results**: −35 % top-20 retrieval failures (contextualised
  embeddings alone) → **−49 %** with contextual BM25 → **−67 %** adding a
  cross-encoder reranker.
- **Cost**: ~$1.02 / Mtok of generated context (with prompt caching).

**Here**: the LLM version (C4) costs 1 call × ~350k posts = expensive for
a lab. The **free** version (C1-C3: title + OP + parent) captures the same
idea — *situate the chunk*. Still to measure whether the LLM blurb adds
anything beyond that.

## 2. "Retrieve small, synthesize big" — sentence-window / parent-document

**Sources**: LlamaIndex SentenceWindowRetriever · LangChain
ParentDocumentRetriever · small-to-big survey

- **Principle**: *decouple the retrieval unit from the generation unit*.
  Embed small (sentence/message → precision); on a match, give the LLM
  something larger (neighbourhood window / parent).
- **Sentence-window**: embed 1 sentence, read sentence ± N neighbours
  (`window_size=3` by default).
- **Parent-document**: embed child chunks, return the parent
  (document/section) via a `parent_id` stored as metadata.
- **Auto-merging**: hierarchical variant — promote to the parent when a
  ratio of siblings is reached.

**Here**: our natural post→topic structure is exactly parent/child.
Retrieve at post (small), evidence = post + ±N neighbourhood + title/OP
(large). That is our config `D`.

## 3. Hybrid search + Reciprocal Rank Fusion (RRF)

**Sources**: Cormack, Clarke & Buettcher, *SIGIR 2009* ("RRF outperforms
Condorcet and individual rank learning methods") · Elastic/etc. guides.

- **Why hybrid**: BM25 excels on exact match (proper names, brands, rare
  terms); dense excels on paraphrase/concept. Neither wins everywhere —
  WANDS benchmark: hybrid +7.4 % NDCG vs the best alone.
- **RRF**: `score(d) = Σ 1/(k + rank_i(d))` over each list, `k=60`
  standard. Ignores raw scores (unbounded BM25 vs incommensurable cosine
  [-1,1]) — fuses by **rank**, not by score.
- No tuning needed to beat a weighted average.

**Here**: current fusion is a custom score (base rank + bonuses). RRF is
the standard — a config to A/B. Discourse Search plays the BM25 role
(Postgres full-text).

## 4. Cross-encoder reranking

- A bi-encoder (bge-m3) compares q and d **separately** (fast, indexable).
- A cross-encoder takes `(query, doc)` **together** → fine relevance
  score, but expensive → apply it only to the fused top ~50-150.
- Models: `bge-reranker-v2-m3` (BGE family, multilingual, ~2 GB),
  Cohere Rerank (API). At Anthropic: rerank moves from −49 % to −67 %.

**Here**: optional step `E`. A bge-reranker-v2-m3 runs on mini-PC or
laptop CPU/iGPU. Test only after D — it is a multiplier, not the
foundation.

## 5. Evaluation — RAGAS and per-layer metrics

**Source**: RAGAS (EACL 2024 demo) — ragas.io / explodinggradients

The structuring principle: **separate retrieval metrics from generation
metrics** — a faithful answer on the wrong context is still a failure.

| Metric | Layer | Measures |
|---|---|---|
| Context recall | retrieval | are the expected docs in the top-k? |
| Context precision | retrieval | are the retrieved docs relevant? |
| Faithfulness | generation | are the answer's claims supported by the context? |
| Answer relevance | generation | does the answer address the question? |

- LLM-as-judge is standard for faithfulness/relevance; context recall can
  be non-LLM if we have golden docs.
- Typical eval-set size: 50-200 Q for ongoing tracking; 15-20 well-chosen
  questions are enough to iterate fast.

**Here**: custom set in [`EVAL.en.md`](EVAL.en.md) — goldens = known
forum threads/messages. Faithfulness is partly guaranteed by the sanitizer
(URL whitelist); what we mainly measure is **context recall** (does the
right thread/message come back?) and **citation relevance**. Hit@5 / MRR
are defined in EVAL.en.md §2.

## 6. What we already do — and the literature backs

| Homegrown practice | Literature status |
|---|---|
| Server-side retrieval, LLM tools `[]` | Equivalent to "evidence injection"; limits tool-call failures |
| `[[n]]` → server URL whitelist | Anti-hallucination: the LLM never generates an identifier |
| HyDE off | Defensible: HyDE costs 1 LLM call and can drift; re-evaluate later if needed |
| Abstain if 0 evidence | Standard — the bot must not answer without context |
| temp 0 | Standard for fidelity |

## 7. Known techniques, not taken as default

| Technique | Why not now |
|---|---|
| HyDE / multi-query expansion | LLM cost per query; re-evaluate if recall is insufficient |
| Matryoshka (reduced dims) | bge-m3 is not Matryoshka — fixed 1024 dims |
| Semantic chunking (split by meaning) | Our "chunk" = the post, a natural boundary |
| GraphRAG / knowledge graph | Oversized for a forum |
| Embedding fine-tuning | Possible someday (MTEB/custom), not before the baseline |

## Links

- Anthropic Contextual Retrieval: https://www.anthropic.com/engineering/contextual-retrieval
- Cormack et al. 2009 (RRF): SIGIR — "Reciprocal Rank Fusion outperforms Condorcet…"
- RAGAS: https://arxiv.org/abs/2309.15217
- LlamaIndex sentence-window: docs.llamaindex.ai (SentenceWindowRetriever pack)
