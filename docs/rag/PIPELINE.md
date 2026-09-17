# Pipeline RAG — de la base Postgres à la réponse du bot

Document d'architecture : le chemin complet d'une question utilisateur,
des données brutes du forum jusqu'à la réponse citée. Voir `DESIGN.md`
pour les choix structurants et `EVAL.md` pour les métriques mesurées.

## Vue d'ensemble

```
POSTGRES (posts, topics)                    ← réplique/prod Discourse
   │
   │  [offline, une fois par contenu]
   ▼
bge-m3 → vecteur 1024-d                     ← modèle d'embedding (Ollama)
   │    ai_posts_embeddings (pgvector)
   │
QUESTION UTILISATEUR                        ← à la volée
   │
   ├─► ÉTAGE 0 — gate d'entrée (optionnel, déterministe)
   │      regex sur l'INTENTION (pas les sujets) → déclinaison immédiate
   │      si danger/illégal/détournement détecté — voir SAFETY.md
   │
   ├─► ÉTAGE 1 — rappel (recall)
   │      question → bge-m3 → cosine sur 425k vecteurs post → top-25
   │      (+ canal keyword BM25 / semantic topic en fusion RRF)
   │
   ├─► ÉTAGE 2 — précision (rerank)
   │      cross-encoder mmarco : score (question, candidat) ×25 → re-tri
   │
   ├─► agrégation : dédup par topic → top-5/6 sources
   │      + zone graduée sur score CE top-1 :
   │        < −4 → bloc « evidence vide » (abstention)
   │        [−4, 0) → bloc WEAK (sources + « assume la faiblesse »)
   │        ≥ 0 → bloc normal « STABLE FORUM EVIDENCE »
   │      (config D : ± voisins du post pour le contexte)
   │
   ▼
PROMPT système = persona + clause refus (SAFETY.md)
   │   + bloc evidence : titres + extraits + règles de citation
   │     [[1]]..[[6]] strictes + « l'evidence n'élargit pas ton périmètre »
   ▼
LLM (mini PC) → réponse rédigée + marqueurs [[n]]
   │
   ▼
Sanitizer serveur : [[n]] → URLs /t/slug/id  ← liens générés côté serveur,
                                               jamais par le LLM
```

## Les modèles en jeu

| Modèle | Type | Rôle | Où ça tourne |
|---|---|---|---|
| **bge-m3** | bi-encoder (embedding) | texte → vecteur 1024-dim. Encode chaque post **une fois** (backfill) et chaque question **à la volée** | Ollama — RTX 2060 laptop en dev ; Ollama mini PC `:32134` en prod |
| **cross-encoder mmarco-mMiniLMv2-L12-H384** | cross-encoder | score de pertinence d'une **paire** (question, candidat) — lit les deux ensemble | dev : `sentence-transformers` CPU laptop ; **prod : TEI `/rerank` sur le mini PC** (pod k3s `reranker`, NodePort 32136, Tailscale only) |
| **LLM chat** | génératif | rédige la réponse à partir des 6 sources fournies | mini PC |
| Postgres/pgvector | — | stockage + distance cosine/hamming | conteneur Discourse (VPS en prod) |

### Bi-encoder vs cross-encoder — pourquoi les deux

Ce ne sont **pas des concurrents** mais deux étages complémentaires :

- **bge-m3 (bi-encoder)** : question et post sont encodés **séparément**.
  Le vecteur du post est pré-calculé → comparer 425k vecteurs = quelques ms.
  Mais le modèle ne « voit » jamais la paire ensemble : la pertinence est
  indirecte (proximité géométrique).
- **cross-encoder** : prend la paire `(question, candidat)` **concaténée**
  en entrée → jugement de pertinence direct, mot à mot. Plus précis, mais
  impossible à pré-calculer : l'utiliser seul coûterait 425k scorings par
  question. Il ne sert donc qu'à **re-trier le top-25** fourni par pgvector.

D'où : cosine pour le **rappel** (ne rien rater), cross-encoder pour le
**classement fin** (bien ordonner). Le cosine n'est jamais abandonné.

## Latence mesurée (i5-10300H laptop)

| Étape | Coût |
|---|---|
| embedding question (bge-m3) | ~ms (un vecteur) |
| cosine pgvector top-25 sur 425k lignes | ~ms (index HNSW/scan) |
| rerank cross-encoder, 25 paires | **~75-100 ms** (~3-4 ms/paire) |
| chargement modèle (une fois, au boot) | ~5 s |
| génération LLM | **plusieurs secondes** (goulot réel) |

→ Le rerank ajoute ~100 ms par requête : **négligeable** face à la
génération LLM. En prod il tourne sur le **mini PC** (pod k3s
`rag-depiedencap/reranker`, TEI `cpu-1.6`, NodePort 32136 — pas sur le
VPS dont la RAM est tendue ~300-400 Mio libres). Vérifié : les logits
TEI/ONNX sont **identiques** à ceux de `sentence-transformers` PyTorch
→ les seuils mesurés en éval (-4 / 0) restent valides en prod, le plugin
reconvertit le score sigmoïdé TEI en logit.

## Étapes détaillées

### 1. Indexation (offline)

Chaque post éligible → `ai_posts_embeddings` (une ligne par post) :

- texte embeddé = `titre du fil + catégorie + tags + contenu du post`
  (stratégie native `post_truncation`, `strategy_id=1`, tronqué à
  `max_sequence_length - 2`)
- le **grain post** est la décision structurante : un fil de 2 700 posts
  a un vecteur topic dilué et invisible, alors que ses posts individuels
  restent nets (mesuré : Hit@5 0.68 → 0.94, cf. `EVAL.md`)
- rejeté après mesure : texte enrichi contexte OP/parent (`strategy_id=2`,
  -9 pts Hit@5 — dilue le post, §4quater EVAL.md)

### 2. Retrieval (par question)

- **posts** : cosine direct sur `ai_posts_embeddings` → top-25 posts
- **keyword** : `Search.execute` (BM25 Discourse) sur les mots distinctifs
- **semantic** : `SemanticSearch` natif sur embeddings de topics
- **hybrid (fallback prod)** : fusion custom `Retrieval.retrieve` +
  gate titre + boosts — l'état de prod avant ce chantier, conservé
  comme chemin de repli (`depiedencap_ai_citations_posts_pipeline=false`
  ou table posts vide ou erreur)
- **fusions RRF** : `Σ 1/(60+rang)` sur les listes — posts×hybrid est la
  meilleure combinaison mesurée (+0.01 MRR vs posts seul)
- rejeté : routing par taille de fil (le RRF route déjà implicitement)

### 3. Rerank (config E)

Top-25 posts → `cross-encoder/mmarco-mMiniLMv2-L12-H384-v1` score
`(question, titre + extrait 300c)` → re-tri → dédup par topic.
Mesuré : Hit@5 0.94 → **0.97**, MRR 0.84 → **0.89** (avec fusion hybrid).

### 4. Génération (évaluée — `run_full_eval.py`, vrai LLM mini PC)

- les 6 meilleures sources → prompt `STABLE FORUM EVIDENCE` avec règles
  strictes (citer `[[n]]`, ne jamais écrire d'URL, abstention si vide)
- **trois zones d'evidence** selon le score CE top-1 (EVAL.md §4.4) :
  abstention `< −4`, cadrage prudent `[−4, 0)`, normal `≥ 0`
- **clause de refus** dans le system prompt + rappel de limite de rôle
  dans le template d'evidence (SAFETY.md — 20/20 sondes)
- le LLM rédige ; le sanitizer résout `[[n]]` → `/t/slug/id` **côté
  serveur** — le LLM ne peut pas inventer de lien
- mesuré : citations valides, abstention OOD, refus/abus, injection
  d'evidence, régression qualité (A/B n=133 — aucune dégradation hors
  zone faible)

## Carte des fichiers

| Quoi | Où |
|---|---|
| Retrieval prod (fusion, gate, prompt) | `discourse_plugin/depiedencap-ai-citations/lib/retrieval.rb` |
| Backfill enrichi (config C, rejetée) | `rag/eval/backfill_enriched.rb` |
| Éval retrieval (dans le conteneur) | `rag/eval/eval_retrieval.rb` |
| Harness métriques + fusions + rerank | `rag/eval/run_eval.py` |
| Éval génération bout-en-bout | `rag/eval/eval_full.rb` + `run_full_eval.py` |
| Jeu de questions + goldens | `rag/eval/questions.yml` |
| Sondes sécurité (refus/injection) | `rag/eval/safety.yml` |
| Gate d'entrée (règles regex) | `rag/eval/input_gate.yml` |
| Variantes de system prompt | `rag/eval/prompt_clauses/` |
| Résultats horodatés | `rag/eval/results/*.json` |
| Mesures et décisions | `rag/EVAL.md` + `rag/SAFETY.md` |
| Environnement forum local | `rag/LOCAL_DEV.md` |
| Snapshots prod pré-déploiement | `rag/prod_snapshots/` |

## Portage production (15/09/2026)

Le canal v2 vit dans `Retrieval` derrière deux site settings
(`depiedencap_ai_citations_posts_pipeline`, `depiedencap_ai_citations_input_gate`,
les deux **false par défaut** → le déploiement du code ne change rien tant
que les flags ne sont pas activés) :

- `retrieve_posts_pack` : `vector_from(question)` (bge-m3 mini PC) → cosine
  `ai_posts_embeddings` top-25 → `POST /rerank` (mini PC :32136) → dédup
  topic → 6 sources avec URL grain post `/t/slug/id/post_number`
- **exclusions ajoutées vs éval** (prod seulement) : `post_type=regular`,
  posts/topics non supprimés, `archetype='regular'` (pas de MP),
  catégories `read_restricted` exclues — le canal legacy bénéficiait de
  `Guardian`/`Search`, le SQL direct doit filtrer soi-même
- **gate d'entrée** : `Retrieval.gate_match` dans `PlaygroundHook`
  (reply_to + schedule_bot_reply) → `publish_canned_reply!` poste la
  réponse fixe sans LLM ; marquée `depiedencap_ai_citations=t` → le
  sanitizer la saute
- **fallbacks mesurés** : flag off → legacy ; `ai_posts_embeddings` vide
  → legacy (garde `posts_table_ready?`, cache 60 s) ; endpoint
  embeddings down → legacy ; reranker down → ordre cosine seul, zone
  `:ok` (config B mesurée 0.94)
- déploiement : `docker cp` plugin → conteneur + `/shared/…` + `sv
  restart unicorn` (Ruby only, pas de precompile)

Le backfill posts natif (`Jobs::EmbeddingsBackfill`, 5 min, queue `low`)
a été activé avec `ai_embeddings_per_post_enabled=true` +
`ai_embeddings_backfill_batch_size` monté temporairement — il produit du
`(model_id=1, strategy_id=1, strategy_version=1)`, exactement la
stratégie évaluée gagnante. Le flip des flags n'intervient qu'une fois
le backfill terminé.
