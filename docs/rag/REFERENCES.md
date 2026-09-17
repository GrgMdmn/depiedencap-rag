# Références — techniques RAG éprouvées (notes de lecture)

> Objectif : qu'est-ce que l'industrie fait, et qu'est-ce qui s'applique à
> notre cas (forum francophone, ~425k posts, megathreads, LLM local 30B).

## 1. Contextual Retrieval — Anthropic (sept. 2024)

**Source** : anthropic.com/engineering/contextual-retrieval · cookbook :
`claude-cookbooks/capabilities/contextual-embeddings`

- **Problème** : un chunk sorti de son document perd son contexte →
  le retriever ne peut pas juger sa pertinence.
- **Méthode** : avant d'embedder chaque chunk, un LLM génère 1-2 phrases
  qui le situent (« ce chunk est issu de X et traite de Y »), préfixées
  au texte. Idem pour l'index BM25.
- **Résultats rapportés** : −35 % d'échecs de retrieval top-20 (embeddings
  contextualisés seuls) → **−49 %** avec BM25 contextuel → **−67 %** en
  ajoutant un reranker cross-encoder.
- **Coût** : ~1,02 $ / Mtok de contexte généré (avec prompt caching).

**Chez nous** : la version LLM (C4) coûte 1 appel × ~350k posts = cher pour
un lab. La version **gratuite** (C1-C3 : titre + OP + parent) capture la
même idée — *situuer le chunk*. À mesurer si le blurb LLM ajoute encore
quelque chose au-delà.

## 2. « Retrieve small, synthesize big » — sentence-window / parent-document

**Sources** : LlamaIndex SentenceWindowRetriever · LangChain
ParentDocumentRetriever · survey small-to-big

- **Principe** : *désolidariser l'unité de recherche de l'unité de
  génération*. On embedde du petit (phrase/message → précision) ; quand ça
  matche, on donne au LLM du plus grand (fenêtre de voisinage / parent).
- **Sentence-window** : embedde 1 phrase, lit phrase ± N voisines
  (`window_size=3` par défaut).
- **Parent-document** : embedde les chunks enfants, retourne le parent
  (document/section) via `parent_id` stocké en métadonnée.
- **Auto-merging** : variante hiérarchique — promeut au parent quand un
  ratio de frères est atteint.

**Chez nous** : notre structure naturelle post→topic est exactement
parent/enfant. Retrieval au post (petit), evidence = post + voisinage ±N
+ titre/OP (grand). C'est notre config `D`.

## 3. Hybrid search + Reciprocal Rank Fusion (RRF)

**Sources** : Cormack, Clarke & Buettcher, *SIGIR 2009* (« RRF outperforms
Condorcet and individual rank learning methods ») · guides Elastic/etc.

- **Pourquoi hybride** : BM25 excelle sur l'exact (noms propres, marques,
  termes rares) ; le dense excelle sur la paraphrase/le concept. Aucun ne
  gagne partout — benchmark WANDS : hybride +7,4 % NDCG vs le meilleur seul.
- **RRF** : `score(d) = Σ 1/(k + rank_i(d))` sur chaque liste, `k=60`
  standard. Ignore les scores bruts (BM25 non borné vs cosine [-1,1]
  incommensurables) — fusionne par **rang**, pas par score.
- Pas de tuning nécessaire pour battre la moyenne pondérée.

**Chez nous** : la fusion actuelle est un scoring custom (base rank +
bonus). RRF est le standard — config à comparer en A/B. Notre Search
Discourse joue le rôle de BM25 (Postgres full-text).

## 4. Reranking cross-encoder

- Un bi-encoder (bge-m3) compare q et d **séparément** (rapide, indexable).
- Un cross-encoder prend `(query, doc)` **ensemble** → score de pertinence
  fin, mais coûteux → on ne l'applique qu'au top ~50-150 fusionné.
- Modèles : `bge-reranker-v2-m3` (famille BGE, multilingue, ~2 Go),
  Cohere Rerank (API). Chez Anthropic : le rerank passe de −49 % à −67 %.

**Chez nous** : étape optionnelle `E`. Un bge-reranker-v2-m3 tourne sur
CPU/iGPU mini PC ou laptop. À tester seulement après D — c'est un
multiplicateur, pas le fondement.

## 5. Évaluation — RAGAS et métriques par couche

**Source** : RAGAS (EACL 2024 demo) — ragas.io / explodinggradients

Le principe structurant : **séparer les métriques retrieval des métriques
de génération** — une réponse fidèle sur un mauvais contexte reste un échec.

| Métrique | Couche | Mesure |
|---|---|---|
| Context recall | retrieval | les docs attendus sont-ils dans le top-k ? |
| Context precision | retrieval | les docs remontés sont-ils pertinents ? |
| Faithfulness | génération | les claims de la réponse sont-elles supportées par le contexte ? |
| Answer relevance | génération | la réponse adresse-t-elle la question ? |

- LLM-as-judge = standard pour faithfulness/relevance ; context recall
  peut être non-LLM si on a les golden docs.
- Taille typique d'un eval set : 50-200 Q pour du suivi continu ;
  15-20 questions bien choisies suffisent pour itérer vite.

**Chez nous** : jeu custom `EVAL.md` — golden = fils/messages attendus
connus du forum. Faithfulness partiellement garantie par le sanitizer
(URLs whitelist) ; ce qu'on mesure surtout = **context recall**
(le bon fil/message remonte-t-il ?) et **pertinence des citations**.

## 6. Ce qu'on fait déjà — et que la littérature valide

| Pratique maison | Statut littérature |
|---|---|
| Retrieval serveur, tools LLM `[]` | Équivalent « evidence injection » ; limite les tool-call failures |
| `[[n]]` → URLs whitelist serveur | Anti-hallucination : le LLM ne génère jamais d'identifiant |
| HyDE off | Choix défendable : HyDE coûte 1 appel LLM et peut dériver ; à réévaluer éventuellement |
| Abstention si 0 preuve | Standard — le bot ne doit pas répondre sans contexte |
| temp 0 | Standard pour la fidélité |

## 7. Techniques connues, non retenues d'office

| Technique | Pourquoi pas maintenant |
|---|---|
| HyDE / multi-query expansion | Coût LLM par requête ; réévaluer si recall insuffisant |
| Matryoshka (dims réduites) | bge-m3 n'est pas Matryoshka — dims fixes 1024 |
| Chunking sémantique (split par sens) | Notre « chunk » = le post, frontière naturelle |
| GraphRAG / knowledge graph | Surdimensionné pour un forum |
| Fine-tuning embeddings | Étape possible un jour (MTEB/custom), pas avant la baseline |

## Liens

- Anthropic Contextual Retrieval : https://www.anthropic.com/engineering/contextual-retrieval
- Cormack et al. 2009 (RRF) : SIGIR — « Reciprocal Rank Fusion outperforms Condorcet… »
- RAGAS : https://arxiv.org/abs/2309.15217
- LlamaIndex sentence-window : docs.llamaindex.ai (pack SentenceWindowRetriever)
