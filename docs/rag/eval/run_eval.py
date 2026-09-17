#!/usr/bin/env python3
"""Harness d'éval RAG — côté hôte (laptop/PC), le conteneur `app` doit tourner.

Rejoue les questions de questions.yml contre la réplique locale via
eval_retrieval.rb (rails runner dans le conteneur) et mesure le retrieval :
Hit@k et MRR par canal (semantic / keyword / hybrid).

Usage :
  cd <clone>/scripts
  uv run --with pyyaml python rag/eval/run_eval.py [--label baseline-topic] \
      [--container app] [--questions rag/eval/questions.yml]

Sortie : tableau console + rag/eval/results/<date>-<label>.json
"""

import argparse
import json
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

import yaml

RERANK_MODEL = "cross-encoder/mmarco-mMiniLMv2-L12-H384-v1"

EVAL_DIR = Path(__file__).resolve().parent
RESULTS_DIR = EVAL_DIR / "results"


def hit(rank: int | None, k: int) -> int:
    return int(rank is not None and rank <= k)


def mrr(rank: int | None) -> float:
    return 0.0 if rank is None else 1.0 / rank


def first_hit_rank(ranked_ids: list[int], expected: set[int]) -> int | None:
    for i, tid in enumerate(ranked_ids, 1):
        if tid in expected:
            return i
    return None


def channel_ids(hits: list[dict]) -> list[int]:
    out = []
    for h in hits:
        if "topic_id" in h:
            out.append(h["topic_id"])
    return out


def rrf_fuse(lists: list[list[dict]], k_rrf: int = 60) -> list[dict]:
    """Reciprocal Rank Fusion de plusieurs listes ordonnées de hits.

    Chaque item fusionné garde le post_id de sa meilleure occurrence source
    (sert à évaluer les hits grain post sur les canaux fusionnés).
    """
    scores: dict[int, float] = {}
    best_post: dict[int, int | None] = {}
    for hits in lists:
        for rank, h in enumerate(hits, 1):
            tid = h.get("topic_id")
            if tid is None:
                continue
            scores[tid] = scores.get(tid, 0.0) + 1.0 / (k_rrf + rank)
            if tid not in best_post or rank < best_post[tid][1]:
                best_post[tid] = (h.get("post_id"), rank)
    return [
        {"topic_id": tid, "post_id": best_post[tid][0], "rrf": s}
        for tid, s in sorted(scores.items(), key=lambda kv: -kv[1])
    ]


def posts_topic_ranked(hits: list[dict]) -> list[dict]:
    """Canal posts → liste dédupliquée par topic (1re occurrence = rang)."""
    seen: dict[int, dict] = {}
    for h in hits:
        seen.setdefault(h["topic_id"], h)
    return list(seen.values())


_reranker = None


def get_reranker():
    global _reranker
    if _reranker is None:
        from sentence_transformers import CrossEncoder
        print(f"chargement reranker {RERANK_MODEL}...", file=sys.stderr)
        _reranker = CrossEncoder(RERANK_MODEL)
    return _reranker


def rerank(question: str, hits: list[dict]) -> list[dict]:
    """Re-trie les hits (canal posts, avec `text`) par score cross-encoder."""
    scored = [h for h in hits if h.get("text")]
    if not scored:
        return hits
    ce = get_reranker()
    pairs = [(question, h["text"]) for h in scored]
    scores = ce.predict(pairs)
    order = sorted(zip(scored, scores), key=lambda t: -t[1])
    return [h for h, _ in order]


def pollution_stats(hits: list[dict], k: int) -> tuple[float, float]:
    """Agrégation du canal posts : nb moyen de topics distincts dans le top-k
    et part moyenne du topic dominant (1.0 = un seul topic squatte le top-k)."""
    top = hits[:k]
    if not top:
        return 0.0, 0.0
    counts: dict[int, int] = {}
    for h in top:
        counts[h["topic_id"]] = counts.get(h["topic_id"], 0) + 1
    distinct = len(counts)
    share = max(counts.values()) / len(top)
    return distinct, share


def fetch_posts_count(topic_ids: set[int], container: str) -> dict[int, int]:
    """posts_count des topics, via une requête psql unique dans le conteneur."""
    if not topic_ids:
        return {}
    ids = ",".join(str(i) for i in topic_ids)
    proc = subprocess.run(
        ["docker", "exec", "-u", "postgres", container, "psql", "discourse",
         "-tAc", f"SELECT id, posts_count FROM topics WHERE id IN ({ids})"],
        capture_output=True, text=True, check=True,
    )
    return {int(l.split("|")[0]): int(l.split("|")[1])
            for l in proc.stdout.splitlines() if "|" in l}


def run_ruby(questions: list[dict], container: str) -> list[dict]:
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".json", delete=False, encoding="utf-8"
    ) as f:
        json.dump(questions, f)
        qfile = f.name

    rb_dst = "/tmp/eval_retrieval.rb"
    q_dst = "/tmp/eval_questions.json"
    for src, dst in ((EVAL_DIR / "eval_retrieval.rb", rb_dst), (qfile, q_dst)):
        subprocess.run(
            ["docker", "cp", str(src), f"{container}:{dst}"], check=True
        )

    proc = subprocess.run(
        [
            "docker", "exec", container, "bash", "-lc",
            f"cd /var/www/discourse && su discourse -c "
            f"'bundle exec rails runner {rb_dst} {q_dst}'",
        ],
        capture_output=True, text=True, timeout=3600,
    )
    if proc.returncode != 0:
        print(proc.stderr[-3000:], file=sys.stderr)
        sys.exit("rails runner a échoué — conteneur `app` up ?")

    results = []
    for line in proc.stdout.splitlines():
        line = line.strip()
        if line.startswith("{"):
            results.append(json.loads(line))
    return results


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--questions", default=str(EVAL_DIR / "questions.yml"))
    ap.add_argument("--label", default="run")
    ap.add_argument("--container", default="app")
    ap.add_argument("--k", type=int, default=5)
    ap.add_argument("--rerank", action="store_true",
                     help="ajoute les canaux rerank / rrf_rerank_hyb (cross-encoder, lent)")
    args = ap.parse_args()

    questions = yaml.safe_load(Path(args.questions).read_text(encoding="utf-8"))
    questions = [q for q in questions if q.get("expected_topic_ids")]
    print(f"{len(questions)} questions avec golden topics\n")

    raw = run_ruby(questions, args.container)
    by_id = {r["id"]: r for r in raw}

    # canaux natifs (bruts du ruby) + fusions RRF calculées côté hôte
    # + routing par taille : rrf posts × hybrid filtré aux topics ≤ N posts
    # + config C : posts enrichis (strategy_id=2), seulement si backfill présent
    ROUTED_THRESHOLDS = (25, 50, 100, 250)
    has_enr = any(r.get("posts_enr") for r in raw)
    channels = ["semantic", "keyword", "posts", "hybrid",
                "rrf_post_sem", "rrf_post_kw", "rrf_post_hyb",
                *(f"routed_{n}" for n in ROUTED_THRESHOLDS)]
    if has_enr:
        channels += ["posts_enr", "rrf_enr_hyb"]
    if args.rerank:
        channels += ["rerank", "rrf_rerank_hyb"]
        if has_enr:
            channels += ["rerank_enr"]
        get_reranker()  # charge le modèle une fois avant la boucle

    # posts_count des topics renvoyés (une requête pour tout le run)
    all_tids: set[int] = set()
    for r in raw:
        for ch in ("semantic", "keyword", "posts", "hybrid"):
            for h in r.get(ch) or []:
                if h.get("topic_id"):
                    all_tids.add(h["topic_id"])
    size_of = fetch_posts_count(all_tids, args.container)

    agg = {ch: {"hit": 0, "rr": 0.0, "n": 0} for ch in channels}
    pol = {"distinct": 0.0, "share": 0.0, "n": 0}
    rows = []

    for q in questions:
        expected = set(q["expected_topic_ids"])
        r = by_id.get(q["id"])
        if not r:
            rows.append((q["id"], "ABSENT", None, None, None))
            continue
        expected_posts = set(q.get("expected_post_ids") or [])

        # construit les canaux fusionnés à partir des listes brutes
        post_hits = r.get("posts") or []
        posts_t = posts_topic_ranked(post_hits)
        enr_hits = r.get("posts_enr") or []
        enr_t = posts_topic_ranked(enr_hits)
        hybrid_hits = r.get("hybrid") or []
        fused = {
            "rrf_post_sem": rrf_fuse([posts_t, r.get("semantic") or []]),
            "rrf_post_kw": rrf_fuse([posts_t, r.get("keyword") or []]),
            "rrf_post_hyb": rrf_fuse([posts_t, hybrid_hits]),
            "rrf_enr_hyb": rrf_fuse([enr_t, hybrid_hits]),
        }
        for n in ROUTED_THRESHOLDS:
            short = [h for h in hybrid_hits
                     if size_of.get(h.get("topic_id", 0), 10**9) <= n]
            fused[f"routed_{n}"] = rrf_fuse([posts_t, short])
        if args.rerank:
            reranked = rerank(q["question"], post_hits)
            fused["rerank"] = posts_topic_ranked(reranked)
            fused["rrf_rerank_hyb"] = rrf_fuse([fused["rerank"], hybrid_hits])
            if enr_hits:
                fused["rerank_enr"] = posts_topic_ranked(
                    rerank(q["question"], enr_hits))
        if post_hits and "error" not in (post_hits[0] or {}):
            d, s = pollution_stats(post_hits, args.k)
            pol["distinct"] += d
            pol["share"] += s
            pol["n"] += 1

        row = [q["id"]]
        for ch in channels:
            hits = fused[ch] if ch in fused else (r.get(ch) or [])
            if hits and "error" in hits[0]:
                row.append(f"ERR:{hits[0]['error'][:40]}")
                continue
            rank = first_hit_rank(channel_ids(hits), expected)
            agg[ch]["n"] += 1
            agg[ch]["hit"] += hit(rank, args.k)
            agg[ch]["rr"] += mrr(rank)
            cell = "-" if rank is None else f"#{rank}"
            # hit grain post : un expected_post_id présent dans les k premiers
            if expected_posts:
                pids = [h.get("post_id") for h in hits[: args.k]]
                cell += "·p" + ("✓" if any(p in expected_posts for p in pids) else "✗")
            row.append(cell)
        rows.append(row)

    print(f"{'id':<22} " + " ".join(f"{ch:<10}" for ch in channels))
    for row in rows:
        print(f"{str(row[0]):<22} " + " ".join(f"{str(c):<10}" for c in row[1:]))

    print()
    report = {"label": args.label, "date": datetime.now(timezone.utc).isoformat(),
              "k": args.k, "questions": len(questions), "channels": {}, "raw": raw}
    for ch in channels:
        n = agg[ch]["n"] or 1
        report["channels"][ch] = {
            "hit_at_k": round(agg[ch]["hit"] / n, 3),
            "mrr": round(agg[ch]["rr"] / n, 3),
            "n": agg[ch]["n"],
        }
        print(f"{ch:<12} Hit@{args.k}={agg[ch]['hit'] / n:.2f}  "
              f"MRR={agg[ch]['rr'] / n:.2f}  (n={agg[ch]['n']})")
    if pol["n"]:
        report["posts_pollution"] = {
            "avg_distinct_topics_at_k": round(pol["distinct"] / pol["n"], 2),
            "avg_dominant_topic_share_at_k": round(pol["share"] / pol["n"], 2),
            "n": pol["n"],
        }
        print(f"posts top-{args.k}: {pol['distinct'] / pol['n']:.1f} topics "
              f"distincts, part dominante {pol['share'] / pol['n']:.2f}")

    RESULTS_DIR.mkdir(exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out = RESULTS_DIR / f"{stamp}-{args.label}.json"
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"\n→ {out}")


if __name__ == "__main__":
    main()
