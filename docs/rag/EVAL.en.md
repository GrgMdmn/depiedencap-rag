# RAG evaluation — protocol and question set

📘 Cette page est également disponible en [français 🇫🇷](./EVAL.md)

> **Status**: active (13/09/2026). Set expanded to **101 questions** sourced
> from the local DB (goldens verified as existing in the DB; relevance of
> canonical threads still to be validated by a forum human).
> Principle: **measure by layer** (retrieval ≠ generation), see
> [`REFERENCES.en.md`](REFERENCES.en.md) §5.
>
> **Public-facing intent**: this `rag/` folder (protocol, timestamped
> results, comparison table) is a deliverable meant to be **shown publicly
> later** (Forgejo). Consequences for how we work:
> - each run produces a timestamped JSON committed in `results/`;
> - the §4 table is filled for every tested config, with qualitative notes;
> - commits tell the reasoning (why a config, what the measurement showed)
>   — not just the mechanics;
> - one factor at a time (§3), so the table reads as a demonstration.

## 1. Eval-set structure

101 questions (initial 15–20 target exceeded — a larger corpus gives less
noisy signals), each with **golden documents** (threads/messages that
*should* come back). Format:

```yaml
- id: calceophilie
  question: "C'est quoi la calcéophilie ?"
  expected_topic_ids: [34091]       # /t/du-terme-calceophile/34091
  expected_post_ids: []             # empty = topic grain is enough
  difficulty: facile
  tags: [définition]

- id: <ex-megathread>
  question: "<question whose answer is a precise message in a long thread>"
  expected_topics: [<topic_id>]
  expected_posts: [<post_id>]       # the precise message — the real post-grain test
  difficulty: megathread
  tags: [contexte, anaphore]
```

Actual coverage (101 questions, `questions.yml` sections A–J):

| Question type | n | What it tests |
|---|---|---|
| Definition / manufacturing technique | 7 | semantic retrieval on concepts (constructions, gemming…) |
| Brand opinions | 24 | brand→canonical thread, megathreads up to 2.7k posts |
| Care / repair | 21 | fine grain (wax, glazing, fading…) |
| Buying / second-hand / budget | 8 | transactional intents |
| Sizing / width | 7 | sizing — answers scattered across posts |
| Shoe types | 12 | product taxonomy + colour megathreads |
| Forum life / rules | 10 | non-"shoes" categories, sensitive topics |
| Answer inside a megathread (post grain) | 2 | **the core of the workstream** — `expected_post_ids` |
| Off-topic | 6 | correct abstention |
| Anaphora / conversational context | — | out of scope of the single-turn harness — manual bot test |
| LLM unavailable | — | manual test (humorous message) |

## 2. Metrics

The two README numbers (**Hit@5 = 0.97**, **MRR = 0.89**) measure
**retrieval only** (does the right thread/post come back?), not the quality
of the generated sentence. They are computed on the golden set
(`questions.yml`): each question has one or more `expected_topic_ids`
(and sometimes `expected_post_ids`).

### Hit@5 (recall in the top-5)

For one question, retrieval **succeeds** if **at least one** golden
document appears in the first 5 results. Hit@5 = that success averaged
over the set (0 or 1 per question).

- **0.97** (config E, n=796): 97 questions out of 100 see the right
  thread in the top-5.
- A Hit@5 of 1.0 with the right thread always in 5th place would still
  be "perfect" as recall, and bad as ranking → hence MRR beside it.
- Variants in the tables: **Hit@k topic** (the golden thread is in the
  top-k); **Hit@k post** (the golden *message* is in the top-k, post grain
  only). The headline figure is scale Hit@5 **topic** (batch K). Early
  passes also used k ∈ {3, 6} on curated batch A–J.

### MRR — Mean Reciprocal Rank (ranking of the first hit)

For each question: `1 / rank` of the **first** relevant result
(1st → 1, 2nd → 0.5, 3rd → ≈ 0.33, 5th → 0.2). If the golden is missing
from the returned list: **0**. MRR = mean of those scores.

- **0.89** (config E): the first relevant hit is in practice 1st or 2nd,
  rarely 4th/5th.
- Unlike Hit@5, a golden moving from #1 to #5 **lowers** MRR (1 → 0.2)
  even if it stays "in the top-5".

In one line: **Hit@5 = did we miss it?** · **MRR = did we put it first?**
The topic → post jump (0.68 → 0.94 Hit@5) is the main gain; rerank
(0.94 → 0.97 Hit@5, 0.84 → 0.89 MRR) mainly improves order.

### Retrieval (automatic) — recap

| Metric | Definition |
|---|---|
| **Hit@5 topic** | at least one `expected_topic` in the top-5 (README figure) |
| **Hit@k topic** | same for a given k (batches A–J: also k ∈ {3, 6}) |
| **Hit@k post** | the `expected_post` in the top-k posts (post grain only) |
| **MRR** | mean of `1/rank` of the first relevant hit (0 if missing) |
| Pollution | evidence slots occupied by the same topic (measures aggregation) |

### Generation (semi-auto)

| Metric | How |
|---|---|
| Real cited links | % `[[n]]` → `Post.exists?` — should be 100 % (sanitizer) |
| Relevant citation | does the cited message carry the answer? (human, 0/1) |
| Faithfulness | claims supported by the evidence (LLM-judge or review) |
| Correct abstention | off-topic → abstain, no invention |
| CTA present | "To go further" footer with an invitation to post |

## 3. Protocol

1. **Baseline `A`** (live config, topic grain): run the set on the local
   forum → fill the table. That is the bar to beat.
2. Each config (`B`, `C`, `D`, `E`…): **one factor changed** vs the
   previous config, same set, same metrics.
3. Results → table below + qualitative notes (striking examples).
4. A question that regresses = we understand it before concluding.

## 4. Results table (to fill)

| Config | Hit@5 topic | Hit@k post | Real links | Abstention OK | Notes |
|---|---|---|---|---|---|
| A (live, topics) | **39/95** (kw 17/95, sem 32/95) | n/a | | | 13/09 v2, goldens corrected — hybrid=41% |
| B (native posts) | **88/95** | exact post `#1` ×2 (carmina-sizing, glaçage-sèche-cheveux) | | | 13/09 v2 — 425k posts embedded |
| C (enriched posts) | **0.85** (n=796) | — | | | 14/09 — **measured, rejected**: enriching the embedded text (OP + parent excerpt) degrades vs B (0.94) — dilution of post content, §4quater |
| D (+ neighbourhood) | | | | | generation side (LLM context), not Hit@k |
| E (+ rerank) | **97%** (n=796) | `p✓` kept | | | 13/09 — CPU cross-encoder, Hit@5=0.97/MRR=0.89 (rrf rerank×hybrid) — detail §4ter |
| F (RRF fusions) | **87-88/95** | `p✓` ×2 kept at #1 | | | 13/09 v2 — posts×hybrid MRR **0.80** |
| G (size routing) | 84-88/95 | `p✓` ×2 | | | 13/09 — **rejected**: degrades vs F, RRF already routes implicitly |

Size-routing findings (13/09, thresholds 25/50/100/250 posts): filtering
topics > N posts out of the topic channel before fusion **degrades
monotonically** (MRR 0.68@25 → 0.76@250 < 0.80 with no filter). Long
threads almost never get a "topic" vote anyway (diluted embedding =
invisible), so there is no noise to remove; cutting medium threads removes
useful votes. **RRF already implements the spirit of routing**: a
megathread only comes back via its posts, a short thread benefits from
both channels. Variant documented then dropped — negative result, kept
for the demonstration.

Baseline A→B findings (13/09, n=95, goldens v2): the native posts channel
alone does **Hit@5 0.93 / MRR 0.77** vs topic hybrid 0.41. Golden
correction by pooling (13/09): the initial "failures" were bringing back
**valid** threads missing from the expected list — widened for
`corthay-avis`, `noeuds-lacets`, `presentation-nouveau-membre`,
`bienvenue-nouveau`; `richelieu-bout-rapporte` rephrased (a member names
the brand). **Method lesson: the initial 0.87→0.93 gap comes from golden
completeness, not retrieval** — keeping goldens current is the most
fragile part of the benchmark.

Fusion findings (13/09): RRF posts×{semantic, hybrid} **does not gain
recall** (posts is enough) but **improves MRR** (0.77→0.80) and rescues
posts failures (`loding-pointure` #23→**#1**, `grande-pointure` #11→#1 —
sizing diluted in posts benefits from the semantic topic signal). RRF
posts×keyword **degrades** (BM25 noise: MRR 0.74). Posts-channel
pollution: top-5 = 2.8 distinct topics on average, dominant topic 63 % of
slots.

Baseline A findings (12/09): the Carmina megathread (2690 posts) absent
from semantic top-20 **and** keyword top-25 → topic-embedding dilution is
real and measured. The title gate (`relevance_score` requires a
distinctive word in the title) also rejects relevant threads whose title
does not contain the keyword — keep that in mind when reading post-grain
metrics.

## 4bis. Scale confirmation (812 questions, 13/09)

Batch A-J (101 curated questions, goldens verified by pooling) was
completed by a **scale-generated batch** (section K of `questions.yml`,
+701 questions + 10 off-topic, sourced by mining all categories/tags in
the DB — different methodology, documented at the top of the section,
golden = single source topic without multi-thread union). Goal: check
that curated-batch results are not a small-sample artefact.

| Channel | Hit@5 (n=796) | MRR |
|---|---|---|
| semantic (topic) | 0.55 | 0.43 |
| keyword (topic) | 0.41 | 0.38 |
| native posts | **0.94** | **0.84** |
| hybrid (then-current prod) | 0.68 | 0.63 |
| rrf posts×hybrid | **0.95** | **0.88** |
| routed_250 | 0.95 | 0.86 |
| enriched posts (C) | 0.85 | 0.80 |
| rrf enriched×hybrid | 0.92 | 0.85 |
| rerank enriched | 0.91 | 0.86 |

**Confirmed**: the native-posts / RRF-fusion advantage holds at scale,
slightly improving (less statistical noise). **Notable gap vs the curated
batch**: prod `hybrid` scores 0.68 here vs 0.41 on A-J — the generated
batch contains many highly distinctive titles (named brands/products)
that BM25 matches easily, while A-J deliberately tests rephrasings and
harder megathreads. The two measurements are complementary: A-J documents
fine cases, K measures general robustness. Size routing (rejected on A-J)
is confirmed rejected here too (routed_250 < rrf_post_hyb with no filter).

## 4ter. Config E — cross-encoder rerank (13/09, n=796)

Model: `cross-encoder/mmarco-mMiniLMv2-L12-H384-v1` (multilingual, light,
CPU — loaded once via `sentence-transformers`, `--rerank` in
`run_eval.py`). Re-sorts the posts-channel top-25 (`{title}. {first 300
characters of the post}` vs question) before topic dedup.

| Channel | Hit@5 | MRR |
|---|---|---|
| native posts | 0.94 | 0.84 |
| rrf posts×hybrid | 0.95 | 0.88 |
| **rerank** | **0.97** | 0.88 |
| **rrf rerank×hybrid** | **0.97** | **0.89** |

Rerank mainly gains **recall** (0.94→0.97 Hit@5): it promotes relevant
posts poorly ranked by cosine distance alone, already in the top-25 but
not in the top-5. Net but incremental gain versus the initial topic→post
jump (still the dominant factor of the workstream). `eval_retrieval.rb`
now exposes `text` (title + 300c excerpt) per post so the host can rerank
without an extra step inside the container.

## 4quater. Config C (enriched posts) — measured, rejected (14/09, n=796)

Implemented for the vitrine (comparable metrics on the whole dataset):
full `strategy_id=2` backfill on 425 505 posts (`backfill_enriched.rb`,
~3h GPU). Embedded text = native context (title+cat+tags) **+ 500c
excerpt of the thread's first message + 400c excerpt of the parent post**
(`reply_to_post_number`), truncated at max_seq−2 like the native strategy.
Hypothesis: disambiguate short replies ("same in 8.5") that the bare post
does not contextualise.

| Channel | Hit@5 | MRR |
|---|---|---|
| native posts (s1) | **0.94** | **0.84** |
| **enriched posts (s2)** | 0.85 | 0.80 |
| rrf posts×hybrid | **0.95** | **0.88** |
| rrf enriched×hybrid | 0.92 | 0.85 |
| rerank (s1) | **0.97** | 0.88 |
| rerank enriched (s2) | 0.91 | 0.86 |

**Negative result, uniform across all variants**: enrichment costs ~9
Hit@5 points and ~4 MRR points on the channel alone, and the degradation
propagates to fusions and rerank. Interpretation: the OP/parent excerpt
consumes token budget and **dilutes the post's own content** in the
vector — contextual noise hurts more than disambiguation helps. Typical
case: `scaled-faq-les-diff-rents-montages` — the golden (36778) is #1 in
s1 but **drops out of the top-25 in s2**: the shared OP context
homogenises vectors of posts in the same thread and flips toward a
neighbouring thread (36856) that occupies the first 5 slots at ~equal
distance.

**Decision: rejected on measurement.** The bare post (title+cat+tags+body)
is the right granularity. Context belongs **at generation time**
(config D — neighbourhood injected into the LLM prompt, without touching
embeddings), not in the indexed vector.

Dataset note: residual failures (~3 % after rerank) remain dominated by
generic titles in batch K ("Présentation": 1671 close threads in the DB,
"Question": 211, "ceinture": 123) whose single-topic golden is
structurally ambiguous — a measurement limit, not a retrieval one.

## 4quinquies. FULL eval — real generation (14/09, n=17→20)

First end-to-end test with the **real prod LLM** (`qwen3:30b-a3b-q6k`,
vLLM mini PC `:32134`). `eval_full.rb` emits per question the prod
evidence (`instructions_block`/`for_question` as-is) + the native-posts
top-25; `run_full_eval.py` rebuilds the "new" block (posts+rerank, same
template), calls the LLM with `system = persona + block`, and collects
the answer + `[[n]]` markers for validation. Readable digest in
`results/*-full-*.yml`.

### Lessons (17 questions: 14 in-domain, 3 off-topic)

| | prod (topic grain) | new (posts+rerank) |
|---|---|---|
| in-domain | answers 12/14; **wrong abstention ×2** (`montage-norvegien-def`, `carmina-sizing-megathread` — empty evidence) | answers 14/14 |
| off-topic | abstains ×3 cleanly | **hallucinates ×3** with citations (invented recipe, "42 °C in Paris", "DPEC investment committee") |
| invalid citations | 2 (`scaled-aston-martin` cites [[2]][[3]] with only 1 source) | 0 |
| LLM latency | ~3-10 s/answer (mini PC) | same |

**Central finding**: the prod title gate was serving as abstention *by
accident* — off-topic → no distinctive word in titles → empty evidence →
abstention. Removing it gains in-domain recall (the 2 wrong abstentions
are fixed) but **loses out-of-domain protection**: the posts channel
always returns 25 candidates and the LLM uses them, even off-brief.

**CE score alone does not split cleanly** (calibration 14/09):
top-1 CE on 796 in-domain questions: min −4.74, p25 +0.42, 4/796 < −4;
on 16 off-topic: −5.9 → **+2.77**. The overlap comes from Le Comptoir —
the forum talks food, wine, cinema: "bœuf bourguignon" has legitimate
tangential threads (off-topic cinema = +2.77). A −4 threshold cuts
extreme cases with no measured in-domain false negative, but lets the
grey zone through; that is as much a **product** decision (should the
bot answer Comptoir questions?) as a technical knob.

**To decide for the final abstention design** (options, not yet settled):
calibrated CE threshold, minimum number of sources above a score, second
lexical signal, or categories to exclude from retrieval. The full eval
did its job: reveal the gap Hit@k does not measure — 0.97 recall ≠ safe
answers.

### 4.4 Measured solution: graduated zone (weak evidence) — 14/09 run `weak-zone`

The binary gate (full evidence / empty) is replaced by **three zones**
on top-1 CE score: `< −4` → empty evidence (abstention);
`[−4, +1[` → `WEAK_EVIDENCE` block: sources are provided but with the
instruction to own the weak relevance ("honestly say no excerpt really
answers, point to the closest thread with caution, invite to post");
`≥ +1` → normal evidence.

Result on the 17 representative cases (`--variants new`,
`--weak-threshold 1.0`):

- **the 3 off-topic hallucinations disappear**: cooking → "no excerpt
  provides a recipe"; weather → "no precise information"; finance → "no
  recommendation available". No more asserted "42 °C" or "DPEC
  investment committee".
- **no in-domain regression**: `calceophilie` (CE −2.32, weak zone!),
  `bannissement` (−1.87), `carmina-megathread` (−0.91),
  `presentation` (−0.21) all answer correctly — graduated framing does
  not turn legitimate low-CE questions into abstentions.
- confident cases (CE ≥ +1, including Comptoir: aston-martin +3.8,
  finsbury +3.4) answer normally.

Key lesson: overlapping CE distributions (in-domain min −4.7 vs
off-topic max +2.8) make any hard threshold imperfect — **but the
graduated zone does not need a clean split**: ambiguous cases are
handled honestly rather than cut. That is the measured answer to the
"post grain without OOD protection" problem in §4.3.

**Watch the quality/safety trade-off** — top-1 CE distribution recomputed
on the 796 in-domain questions (offline, no LLM):

| Weak threshold | % legitimate questions in the "cautious" zone |
|---|---|
| +2.0 | 33 % |
| +1.0 | **25 %** (first-test value — too high) |
| **0.0** | **17 %** |
| −1.0 | 10 % |
| −4.0 (abstention) | 0 % |

The 3 measured off-topic cases (−0.74, −0.46, −3.60) all fall in
`[−4, 0)` → threshold **0.0** captures the same cases while almost
halving exposure of legitimate questions (25 % → 17 %). The cost of the
WEAK block is stylistic (more cautious answer), not an abstention —
legitimate low-CE questions still answer correctly (calceophilie −2.3).
Trade-off to confirm with a scale A/B run.

File: `results/20260914-115544-weak-zone.*`. See also
[`SAFETY.en.md`](SAFETY.en.md) (refusal/abuse axis — complementary: the
weak block handles weak relevance, the refusal clause handles out-of-role
requests).

## 5. Harness

`rag/eval/`:

- `questions.yml` — question set + `expected_topic_ids` (golden). The
  initial seed is **to validate/enrich** (some expected items are
  guesses — check that the listed thread is the canonical one).
- `safety.yml` — refusal/injection probes (safety axis, see
  [`SAFETY.en.md`](SAFETY.en.md)).
- `input_gate.yml` — input-gate regex rules (intent, not topic).
- `prompt_clauses/` — system-prompt variants testable without touching
  the DB (`--system-append`).
- `eval_retrieval.rb` — run **inside the container** (`rails runner`):
  replays `Retrieval` without cache, splits semantic / keyword / hybrid.
- `run_eval.py` — host side: copies the ruby, runs, computes Hit@k/MRR
  per channel, saves `results/<date>-<label>.json`.
- `eval_full.rb` + `run_full_eval.py` — **end-to-end** eval: prod
  retrieval vs posts+rerank, real LLM (mini PC), citation validation,
  gate, weak zone, evidence injection.

```bash
python3 -m venv rag/eval/.venv && rag/eval/.venv/bin/pip install pyyaml
rag/eval/.venv/bin/python rag/eval/run_eval.py --label baseline-topic
# options : --k 6  --container app  --questions rag/eval/questions.yml

# for --rerank (config E, CPU cross-encoder, ~1.5 GB RAM at load):
rag/eval/.venv/bin/pip install sentence-transformers
rag/eval/.venv/bin/python rag/eval/run_eval.py --label with-rerank --rerank

# end-to-end generation eval (real mini-PC LLM, ~10 s/question):
rag/eval/.venv/bin/python rag/eval/run_full_eval.py \
    --questions rag/eval/safety.yml --label safety-v3 \
    --input-gate rag/eval/input_gate.yml \
    --system-append rag/eval/prompt_clauses/refusal.txt \
    --weak-threshold 0.0
# options : --n 20  --ids a,b,c  --variants prod,new  --abstain-threshold -4
```

> Retrieval metrics run **without an LLM** → fast iteration loop.
> Generation eval calls the real mini-PC `qwen3:30b` via Tailscale —
> budget ~10 s per question and per variant.
