# depiedencap-rag — Agent RAG ancré dans Discourse

📘 This project is also available in [English 🇬🇧](./README.md)

> ⚠️ **Work in progress.** L'agent est en cours de test sur un groupe
> restreint de démonstration et **n'est pas encore déployé publiquement**
> sur le forum. Ce dépôt documente le chantier — aucune URL de démo n'est
> publiée.

Un plugin **Discourse** + un pipeline RAG auto-hébergé, conçu pour un forum
associatif francophone (Depiedencap — souliers pour homme, ~428k messages).
Principe produit : **le bot oriente vers les fils existants, il ne répond
pas à la place des membres.**

## Ce que fait le plugin

- Retrieval au **grain post** (et non au grain topic) : embeddings `bge-m3`
  dans `ai_posts_embeddings` (pgvector dans la Postgres du forum), top-25
  par cosine puis **rerank cross-encoder** (TEI), déduplication par fil.
- **Réécriture de requête multi-tour** : le dernier message + les tours
  précédents sont condensés en une requête autonome par un petit modèle
  dédié avant retrieval (pattern *condense question* / history-aware
  retriever).
- **Citations vérifiées côté serveur** : le LLM n'écrit que des marqueurs
  `[[n]]` ; le plugin les transforme en liens `/t/slug/id/post_number` et
  jette tout lien qui n'existe pas réellement en base (whitelist Postgres,
  le LLM n'a jamais le dernier mot sur une URL).
- **Zones d'evidence graduées** (abstention / prudent / normal) pilotées
  par le score du reranker + **gate d'entrée déterministe** (regex
  d'intention) pour les demandes dangereuses ou hors-rôle — zéro appel LLM.
- Dégradation gracieuse : endpoint embedding ou reranker indisponible →
  repli legacy/abstention honnête, jamais d'invention.

## Architecture

```
Discourse (plugin Ruby, dans le process du forum)
   │  question → gate → réécriture (modèle léger) → embed → pgvector → rerank → LLM → sanitizer
   ▼
Mini PC auto-hébergé (k3s)                     VPS
  Ollama : bge-m3 (embeddings)                   Discourse + Postgres/pgvector
           qwen3 30B (génération)               (~428k posts embeddés)
           llama3.1 8B (réécriture requête)
  TEI    : cross-encoder mmarco-mMiniLMv2 (rerank)
```

Le choix délibéré : **pas de framework RAG** (LangChain & co.) — pipeline
linéaire en code direct, instrumenté pour l'évaluation. Le raisonnement
complet : [`docs/rag/DESIGN.md`](docs/rag/DESIGN.md) §9.

## Résultats mesurés (corpus réel, 812 questions d'éval)

| Métrique | Valeur |
|---|---|
| Hit@5 retrieval | **0.97** |
| MRR | 0.89 |
| Sécurité (red-team, gate, refus, injection-evidence) | 20/20 |
| Surcoût rerank | ~100 ms |

Détail : [`docs/rag/EVAL.md`](docs/rag/EVAL.md) ·
[`docs/rag/SAFETY.md`](docs/rag/SAFETY.md) ·
[`docs/rag/PIPELINE.md`](docs/rag/PIPELINE.md) ·
[`docs/rag/REFERENCES.md`](docs/rag/REFERENCES.md)

## Contenu du dépôt

| Chemin | Contenu |
|---|---|
| racine (`plugin.rb`, `lib/`, `app/`, `config/`) | Le plugin Discourse, installable par `git clone` dans `plugins/` |
| `docs/rag/` | Design, éval, sécurité, références, recette dev local |
| `prompts/` | System prompt de production (v3.1) |
| `tools/` | Smoke test live (API Discourse) |

## Sécurité & confidentialité

- Aucun endpoint interne, IP ou compte n'est publié (export sanitisé
  depuis le dépôt privé de travail + denylist-check automatique).
- L'agent reste limité à un groupe de démonstration pendant la phase
  d'observation ; rollback < 5 min documenté.
- Le bot refuse les demandes dangereuses, illégales ou généralistes et
  ignore les instructions hostiles trouvées dans les extraits du forum.

## Licence

AGPL-3.0 — voir `LICENSE`.
