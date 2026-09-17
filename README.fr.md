# depiedencap-rag — Agent RAG ancré dans Discourse

📘 This project is also available in [English 🇬🇧](./README.md)

> ⚠️ **Work in progress.** L'agent est en cours de test sur un groupe
> restreint de démonstration et **n'est pas encore déployé publiquement**
> sur le forum. Ce dépôt documente le chantier — aucune URL de démo n'est
> publiée.

Un plugin **Discourse** + un pipeline RAG auto-hébergé, conçu pour un forum
associatif francophone (Depiedencap — souliers pour homme, 424 835 messages
/ 22 230 sujets). Principe produit : **le bot oriente vers les fils
existants, il ne répond pas à la place des membres.**

## Ce que fait le plugin

- Retrieval au **grain post** (et non au grain topic) : embeddings `bge-m3`
  dans `ai_posts_embeddings` (pgvector dans la Postgres du forum, **sur le
  VPS**), top-25 par cosine puis **rerank cross-encoder** (TEI **sur le mini
  PC**), déduplication par fil.
- **Réécriture de requête multi-tour** : le dernier message + les tours
  précédents sont condensés en une requête autonome (pattern *condense
  question* / history-aware retriever). Même modèle résident que la
  génération : `qwen3:30b-a3b-q6k` (MoE, ~3B actifs, `think:false`) — plus
  de petit modèle dédié à la réécriture.
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

Le plugin tourne **dans Discourse, sur le VPS**. Le mini PC n'est que le
backend d'inférence (Ollama + TEI), joignable via Tailscale. Le gate,
pgvector et le sanitizer de citations ne quittent jamais le VPS.

```
Question membre
        │
        ▼
[VPS]  Discourse + ce plugin Ruby
        │
        ├─ 1. gate          regex locale, 0 LLM
        │
        ├─ 2. réécriture    ──Tailscale──►  [mini PC] Ollama  qwen3:30b-a3b-q6k
        │
        ├─ 3. embed         ──Tailscale──►  [mini PC] Ollama  bge-m3
        │
        ├─ 4. pgvector      Postgres locale, 424 835 posts, cosine top-25
        │
        ├─ 5. rerank        ──Tailscale──►  [mini PC] TEI     mmarco-mMiniLMv2
        │
        ├─ 6. génération    ──Tailscale──►  [mini PC] Ollama  qwen3:30b-a3b-q6k
        │
        └─ 7. sanitizer     whitelist URL, Postgres locale
                │
                ▼
          réponse + liens /t/slug/id/post_number
```

| Sur le VPS | Sur le mini PC (k3s, iGPU) |
|---|---|
| Discourse, ce plugin, Postgres/pgvector | Ollama (`bge-m3` + `qwen3:30b-a3b-q6k`) et TEI (`mmarco`) |

`qwen3:30b-a3b-q6k` est un seul MoE résident (~3B actifs) pour la
réécriture (`think:false`) **et** la génération.

Le choix délibéré : **pas de framework RAG** (LangChain & co.) — pipeline
linéaire en code direct, instrumenté pour l'évaluation. Le raisonnement
complet : [`docs/rag/DESIGN.md` §9](docs/rag/DESIGN.md#user-content-9-pourquoi-pas-langchain).

## Résultats mesurés (corpus réel, 812 questions d'éval)

| Métrique | Valeur |
|---|---|
| Hit@5 retrieval | **0.97** |
| MRR | 0.89 |
| Sécurité (red-team, gate, refus, injection-evidence) | 20/20 |
| Surcoût rerank | ~100 ms |

**Hit@5** : part des questions d'éval dont le fil (ou le post) attendu
apparaît dans les **5 premiers** résultats. 0.97 = la bonne source est
dans ce top-5 97 fois sur 100. Ça ne dit pas *où* dans les cinq.

**MRR** (*Mean Reciprocal Rank*, rang réciproque moyen) : on note le
**rang du premier** hit pertinent, puis on moyenne. Rang 1 → 1, rang 2 →
0.5, rang 5 → 0.2, absent → 0. 0.89 = le premier bon hit est le plus
souvent 1er ou 2e, pas seulement « quelque part dans le top-5 ».

Hit@5 = rappel (« est-ce qu'on a raté ? »). MRR = classement (« est-ce
qu'on l'a mis en haut ? »). Protocole et formules :
[`docs/rag/EVAL.md` §2](docs/rag/EVAL.md#user-content-2-métriques).

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
