# Design — RAG grain post (Depiedencap)

> **Dernière màj** : 14/09/2026 · **Statut** : toutes les configs A-G
> mesurées, config gagnante identifiée (E : posts natifs + rerank),
> sécurité testée à l'échelle. **Rien déployé en prod.**
> Résultats : [`EVAL.md`](EVAL.md) · Sécurité : [`SAFETY.md`](SAFETY.md) ·
> Architecture : [`PIPELINE.md`](PIPELINE.md)
> Références techniques : [`REFERENCES.md`](REFERENCES.md)

## 0. État actuel (rappel)

- **Index** : `ai_topics_embeddings` — 1 vecteur/topic (bge-m3, 1024 dims,
  entrée 4096 tokens), 22 340 lignes. Stockage pgvector dans la DB du forum.
- **Retrieval** (`retrieval.rb`) : `Search.execute` (keyword) +
  `SemanticSearch` (pgvector, HyDE off), fusion custom (base rank + bonus
  titre + bonus hybride +12), filtre titre obligatoire (mot distinctif ≥ 6
  chars / stem), stopwords FR, `INTENT_QUERIES` codées en dur, cache 2 h,
  max 6 sources.
- **Evidence** : titres + extraits 320 chars injectés serveur, le LLM émet
  des `[[n]]` nus, sanitizer → URLs whitelist (`Topic.exists?`), footer
  Sources + CTA.

### Faiblesses identifiées

| Faiblesse | Cause |
|---|---|
| Megathreads invisibles au détail | 1 vecteur / 300 posts = dilution + troncature 4096 |
| Citation au fil entier | `[[n]]` → `/t/slug/id`, pas au message précis |
| Evidence sans contexte | Extrait 320 chars isolé, anaphores non résolues |
| Fusion ad hoc | Score custom, pas de méthode standard (RRF) |

## 1. Schéma de stockage (décidé)

**Vecteurs dans la Postgres du forum** (pgvector), pas de store externe.
Justification : atomicité avec `posts`, backup gratuit dans le `.tar.gz`,
le forum local de dev a sa copie automatiquement.

| Table | Contenu | Statut |
|---|---|---|
| `ai_topics_embeddings` | 1 vecteur/topic (natif discourse-ai) | existant, **conservé** (related topics + fallback) |
| `ai_posts_embeddings` | 1 vecteur/post, `strategy_id=1` natif + `strategy_id=2` enrichi (test) | **implémenté** — voir note ci-dessous, remplace `dpec_post_embeddings` |

> **Révision D2 (14/09)** : la table custom `dpec_post_embeddings` n'a
> **pas** été créée — décision changée en cours de route. La table native
> `ai_posts_embeddings` avec sa clé `(model_id, strategy_id, post_id)`
> permet exactement la même chose (plusieurs représentations du même post
> qui cohabitent) sans dupliquer l'infra (index, purge, backfill job).
> `strategy_id=1` = natif discourse-ai (titre+cat+tags+contenu, gratuit,
> **c'est celui qui gagne**), `strategy_id=2` = enrichi OP/parent (mesuré,
> rejeté — voir EVAL.md §4.2). Le custom serait resté nécessaire seulement
> pour C4 (blurb LLM), jamais implémenté (voir §8).

> Pourquoi une table **custom** et pas `ai_posts_embeddings` natif :
> le backfill natif embedde `post.raw` nu — impossible d'y injecter le
> contexte (titre/OP/parent). Table custom = contrôle total du texte
> embarqué + métadonnées (post_number, topic_id, hash du texte, modèle).
> `ai_posts_embeddings` reste désactivé (`ai_embeddings_per_post_enabled=false`).
>
> Constats du restore local (12/09) : la table native existe déjà avec
> `embeddings halfvec` + index **HNSW binary-quantized** par
> `(model_id, strategy_id)` — et la clé unique est
> `(model_id, strategy_id, post_id)`. **Et** la stratégie native
> `Truncation#post_truncation` embedde déjà « titre + catégorie + tags +
> contenu du post » — l'enrichissement partiel est **gratuit** en activant
> `ai_embeddings_per_post_enabled`. Ce qui reste custom : parent/OP excerpt
> et nos métadonnées. Un `strategy_id` custom dans la table native
> permettrait nos vecteurs enrichis complets en réutilisant index + purge —
> option sérieuse avant de créer `dpec_post_embeddings` — cf. D2.

Schéma proposé :

```sql
post_id      bigint PK FK → posts.id
topic_id     bigint  (dénormalisé, filtre/agrégation rapide)
post_number  int     (ancre de citation)
embedding    vector(1024)
source_hash  char(40) -- sha1 du texte enrichi embarqué (détecte l'édit)
model        text    -- 'bge-m3' (un changement de modèle = vecteurs incompatibles)
embedded_at  timestamptz
```

Index : **à mesurer** — brute force `ORDER BY embedding <=> $q` (cosine)
sur ~300-400k lignes ≈ 200-500 ms, peut suffire dans un chemin où le LLM
prend des secondes. Sinon HNSW (`vector_cosine_ops`, `m`/`ef` à régler) —
rappel ~95-99 %, build coûteux en RAM sur le VPS 8 Go.

## 2. Le texte embarqué (enrichissement) — l'axe décisif

Le post nu échoue sur les anaphores (« c'était pourri » → pourrie **quoi** ?).
Le contexte résout la majorité des références. Texte candidat à embedder :

```
[titre du topic] › [extrait OP si post_number > 1] › [extrait post parent
si réponse formelle] › [post.raw nettoyé]
```

Variantes à tester (matrice §4) :

| Code | Texte embeddé | Coût index |
|---|---|---|
| `B` | `post.raw` nu | minimal |
| `C1` | `title + post.raw` | minimal |
| `C2` | `title + OP excerpt + post.raw` | minimal |
| `C3` | `C2 + parent excerpt` (reply_to_post_number / quote) | minimal |
| `C4` | `C3 + blurb LLM` (« dans ce fil sur X, ce message dit… ») | 1 appel LLM/post — cher, borne à un sous-ensemble |

> C4 = le « Contextual Retrieval » d'Anthropic littéral (−35 % d'échecs
> top-20 à lui seul). C1-C3 = version gratuite. La littérature suggère que
> le gain majeur vient de *situer* le chunk, pas forcément du LLM.

Note : le post orphelin (réponse sans citation à un post voisin) n'a **pas**
besoin d'être retrouvé lui-même — il sera lu via l'expansion de voisinage
du post voisin qui, lui, porte le contexte (§3).

## 3. Retrieval en deux temps (small-to-big)

```
question
  → embed requête (bge-m3, même instance)
  → top-K posts (pgvector) + top-M topics (keyword Search existant)
  → fusion RRF (k=60)                       ← remplace le scoring custom ?
  → agrégation par topic : 1 entrée/fil, score = max(posts du fil)
  → evidence block : par entrée,
       titre + extrait post ciblé + voisinage ±N posts
  → LLM : citations [[n]] → sanitizer → /t/slug/id/post_number
```

- **Agrégation par topic** : évite qu'un megathread monopolise les 6 slots
  d'evidence. Score du topic = meilleur post (ou moyenne top-2, à tester).
- **Voisinage** (`window` ±2 ou ±3 posts, paramètre) : porte le contexte,
  résout les anaphores à la **lecture** — pas à l'indexation. C'est le
  « sentence-window retrieval » appliqué aux posts.
- **Citation post-level** : `[[n]]` → `/t/slug/topic_id/post_number`.
  Whitelist sanitizer : `Post.exists?` (pas seulement `Topic.exists?`).

## 4. Matrice de configs — résultats (14/09/2026)

| Config | Description | Hit@5 | MRR | Verdict |
|---|---|---|---|---|
| `A` | topics (prod actuelle) | 0.68 | 0.63 | baseline live |
| `B` | posts natifs (strategy_id=1) | **0.94** | 0.84 | **retenu** — le gain principal |
| `C` | posts enrichis OP/parent (strategy_id=2) | 0.85 | 0.80 | **mesuré, rejeté** — dilue le vecteur |
| `D` | voisinage ±N au moment de la génération | — | — | non testé isolément (le rerank + evidence 320c couvre le besoin en pratique) |
| `E` | B + rerank cross-encoder mmarco | **0.97** | **0.89** | **retenu — config gagnante** |
| `F` | fusion RRF posts×hybrid | 0.95 | 0.88 | mesuré, marginal sur E (+0.01 MRR), optionnel |
| `G` | routing par taille de topic | 0.93-0.95 | 0.77-0.86 | **mesuré, rejeté** — dégrade MRR vs fusion libre |

Détail complet, méthodologie et n mesurés : `EVAL.md` §1-4.
Chaque config comparée en ne changeant **qu'un** facteur à la fois.
Sécurité de la config E (refus, gate, injection) : `SAFETY.md`.

Variables secondaires à explorer ensuite : top-K (10/20/50), longueur
d'entrée embed (1024 vs 4096), seuil de filtre titre, taille fenêtre.

## 5. Corpus à indexer

| Choix | Position |
|---|---|
| Catégories | **Toutes les publiques** (les questions « vie du forum » sont légitimes) |
| MP | **Jamais** (décision produit existante) |
| Longueur min. | À calibrer — posts < ~30-40 chars probablement exclus (« +1 », « merci ! ») |
| Posts supprimés / staff | exclus (`deleted_at`, catégories non publiques) |
| Volume estimé | ~300-350k posts indexables sur ~425k |

## 6. Coûts / charge

- **Backfill** : ~300k embeddings bge-m3. Sur laptop CPU ~10-20/s → 4-8 h
  (plusieurs nuits OK). Prod : même modèle côté mini PC iGPU, plus rapide.
- **Requête** : 1 embed (~50-200 ms) + 1 similarité SQL + expansion =
  négligeable devant la génération LLM.
- **Stockage VPS** : ~300-400k × (1024 dims × 4 o + overhead ligne)
  ≈ **2-3 Go** — tenable vs ~13 Go libres, à surveiller.
- **Incrémental** : 1 embed par nouveau post (job Sidekiq async), + re-embed
  si `source_hash` change après édit.

## 7. Décisions

| # | Date | Décision | Motif |
|---|---|---|---|
| D1 | 12/09/2026 | Vecteurs dans la Postgres du forum, pas de store externe | Atomicité, backup dans le `.tar.gz`, réplique locale gratuite |
| D2 | 12/09/2026, **révisée 14/09** | `ai_posts_embeddings` natif (`strategy_id`), pas de table custom | Même besoin (cohabitation multi-représentation) sans dupliquer index/purge/backfill |
| D3 | 12/09/2026 | Dev : bge-m3 **local CPU/GPU laptop**, LLM mini PC | Isolation dev/prod ; NUM_PARALLEL=2 risqué pour le 30B |
| D4 | 13/09/2026 | RRF mesuré vs fusion custom — retenu comme option (F), pas obligatoire | Gain marginal (+0.01 MRR) sur la config gagnante E |
| D5 | 13/09/2026 | Config B (posts nus) retenue comme socle, C (enrichi) rejeté | Mesuré : 0.94 vs 0.85 Hit@5 — le contexte OP/parent dilue le vecteur |
| D6 | 14/09/2026 | Config E (B + rerank cross-encoder) = solution finale retrieval | Mesuré : 0.97 Hit@5 / 0.89 MRR, coût ~100ms négligeable |
| D7 | 14/09/2026 | G (routing par taille) rejeté | Mesuré à l'échelle (796) : dégrade MRR vs fusion libre |
| D8 | 14/09/2026 | Abstention/scope : zone graduée sur score CE (pas de seuil dur) + gate d'entrée déterministe + clause de refus dans le prompt | Aucun seuil ne sépare proprement in-domain/hors-sujet (distributions qui se chevauchent) — voir SAFETY.md |
| D9 | 17/09/2026 | **Pas de LangChain** — patterns repris sans la dépendance | Voir §9 |
| D10 | 17/09/2026 | Réécriture de requête multi-tour via modèle dédié léger (`condense_query`, llama3.1:8b) — repli sur le message brut si indispo | Retrieval ne voyait que le dernier message ; bug réel observé en usage (17/09). Modèle non-thinking choisi exprès (qwen3:4b engloutit son budget dans le champ `reasoning`) |

## 9. Stack : pourquoi pas LangChain (et ce qu'on en retient)

LangChain est une **bibliothèque** (Python/JS — pas un LLM, pas un service à
déployer) qui fournit des briques d'orchestration LLM : retrieval, mémoire,
réécriture de requête, outils. C'est le framework le plus répandu pour
*prototyper* un RAG — d'où sa présence dans les offres d'emploi.

**Pourquoi on ne l'utilise pas ici** — choix d'architecture, pas de rejet du
concept :

- Notre pipeline vit dans un **plugin Discourse Ruby**, dans le process du
  forum. LangChain impliquerait un service Python séparé à déployer,
  maintenir et sécuriser — un nouveau point de défaillance entre le forum
  et le mini PC, pour ré-implémenter une logique déjà linéaire.
- On fait déjà les mêmes étapes en code direct (~600 lignes) :
  embed → pgvector → rerank cross-encoder → LLM → sanitizer. Pas besoin
  d'abstraction pour un pipeline linéaire et instrumenté (l'éval
  `eval_full.rb` appelle directement les fonctions).
- Si un jour on visait des capacités **agentiques** (le bot choisit ses
  outils, enchaîne des recherches), un service dédié deviendrait défendable
  — LangChain/LangGraph seraient alors candidats. Pas la roadmap actuelle.

**Ce qu'on a quand même repris de ce monde** : la **réécriture de requête
conversationnelle** (pattern *condense question* / *history-aware retriever*
de LangChain, et littérature QReCC/CANARD) — implémentée dans
`Retrieval.condense_query` avec un petit modèle dédié : le dernier message +
les 3 tours précédents → une requête autonome avant embedding.

## 8. Questions ouvertes — état

- ~~`OP excerpt` dans l'enrichi~~ → **tranché** : mesuré et rejeté (D5/D2).
- Fenêtre voisinage (config D) : **non mesurée isolément** — le rerank +
  extrait 320c suffit en pratique sur l'éval bout-en-bout (`SAFETY.md`
  run 812) ; à revisiter seulement si des cas d'anaphore non résolue
  sont observés en usage réel.
- Reranker : **tranché** — oui, +0.03 Hit@5 / +0.05 MRR pour ~100ms.
  Tourne sur CPU, mini PC ou VPS EPYC Rome tous deux suffisants
  (mesuré : `PIPELINE.md`).
- Abstention : **tranché** — pas un seuil unique, zone graduée
  (`< -4` abstention, `[-4,0)` prudence, `≥0` normal) + gate d'entrée
  pour l'axe sécurité (indépendant de la pertinence). Voir SAFETY.md.
- `INTENT_QUERIES` codées main (prod actuelle) : **non repris** dans le
  nouveau pipeline — le rerank cross-encoder couvre ce besoin sans règles
  ad hoc à maintenir ; à confirmer si un cas de régression apparaît.
- Config D (voisinage génération), config F (RRF) : optionnelles,
  gain marginal mesuré — pas nécessaires pour le MVP.
