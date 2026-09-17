# Évaluation RAG — protocole et jeu de questions

📘 This page is also available in [English 🇬🇧](./EVAL.en.md)

> **Statut** : actif (13/09/2026). Jeu étendu à **101 questions** sourcées
> depuis la base locale (goldens vérifiés existants en base ; pertinence des
> fils canoniques à valider par un humain du forum).
> Principe : **on mesure par couche** (retrieval ≠ génération), cf. `REFERENCES.md` §5.
>
> **Intention d'exposition** : ce dossier `rag/` (protocole, résultats
> horodatés, tableau comparatif) est un livrable destiné à être **présenté
> publiquement à terme** (Forgejo). Conséquence sur la façon de travailler :
> - chaque run produit un JSON horodaté commité dans `results/` ;
> - le tableau §4 est rempli à chaque config testée, avec notes qualitatives ;
> - les commits racontent le raisonnement (pourquoi une config, ce que la
>   mesure a montré) — pas juste la mécanique ;
> - un facteur à la fois (§3), pour que le tableau soit lisible comme une
>   démonstration.

## 1. Structure du jeu d'éval

101 questions (visé initial 15–20 dépassé — un corpus plus large donne des
signaux moins bruités), chacune avec ses **golden documents** (fils/messages
qui *devraient* remonter). Format :

```yaml
- id: calceophilie
  question: "C'est quoi la calcéophilie ?"
  expected_topic_ids: [34091]       # /t/du-terme-calceophile/34091
  expected_post_ids: []             # vide = grain topic suffit
  difficulty: facile
  tags: [définition]

- id: <ex-megathread>
  question: "<question dont la réponse est un message précis dans un long fil>"
  expected_topics: [<topic_id>]
  expected_posts: [<post_id>]       # le message précis — vrai test grain post
  difficulty: megathread
  tags: [contexte, anaphore]
```

Couverture réelle (101 questions, `questions.yml` sections A–J) :

| Type de question | n | Ce que ça teste |
|---|---|---|
| Définition / technique fabrication | 7 | retrieval sémantique sur concepts (montages, trépointe…) |
| Avis marques | 24 | naviguer marque→fil canonique, megathreads jusqu'à 2.7k posts |
| Entretien / réparation | 21 | grain fin (cirage, glaçage, décoloration…) |
| Achat / occasion / budget | 8 | intentions transactionnelles |
| Pointure / largeur | 7 | sizing — réponses dispersées en posts |
| Types de chaussures | 12 | taxonomie produit + megathreads couleur |
| Vie du forum / règles | 10 | catégories non « souliers », sujets sensibles |
| Réponse dans un megathread (grain post) | 2 | **le cœur du chantier** — `expected_post_ids` |
| Hors-sujet | 6 | abstention correcte |
| Anaphore / contexte conversationnel | — | hors scope du harness single-turn — test manuel du bot |
| LLM indisponible | — | test manuel (message humoristique) |

## 2. Métriques

Les deux chiffres du README (**Hit@5 = 0.97**, **MRR = 0.89**) mesurent
**uniquement le retrieval** (le bon fil/post remonte-t-il ?), pas la
qualité de la phrase générée. Ils sont calculés sur le jeu golden
(`questions.yml`) : chaque question a un ou plusieurs `expected_topic_ids`
(et parfois `expected_post_ids`).

### Hit@5 (rappel dans le top-5)

Pour une question, le retrieval **réussit** si **au moins un** document
golden apparaît dans les 5 premiers résultats. Hit@5 = cette réussite
moyennée sur le jeu (0 ou 1 par question).

- **0.97** (config E, n=796) : 97 questions sur 100 voient le bon fil dans
  le top-5.
- Un Hit@5 à 1.0 avec le bon fil toujours en 5e place resterait « parfait »
  au sens du rappel, et mauvais au classement → d'où le MRR à côté.
- Variantes dans les tableaux : **Hit@k topic** (le fil golden est dans le
  top-k) ; **Hit@k post** (le *message* golden est dans le top-k, grain
  post uniquement). Le chiffre vitrine est le Hit@5 **topic** à l'échelle
  (lot K). Les premières passes utilisaient aussi k ∈ {3, 6} sur le lot
  curé A–J.

### MRR — Mean Reciprocal Rank (classement du premier hit)

Pour chaque question : `1 / rang` du **premier** résultat pertinent
(1er → 1, 2e → 0.5, 3e → ≈ 0.33, 5e → 0.2). Si le golden est hors de la
liste renvoyée : **0**. MRR = moyenne de ces scores.

- **0.89** (config E) : le premier hit pertinent est en pratique 1er ou
  2e, rarement 4e/5e.
- Contrairement au Hit@5, un golden passé de #1 à #5 **fait baisser** le
  MRR (1 → 0.2) même s'il reste « dans le top-5 ».

En une ligne : **Hit@5 = est-ce qu'on a raté ?** · **MRR = est-ce qu'on
l'a mis en haut ?** Le saut topic → post (0.68 → 0.94 Hit@5) est le gain
principal ; le rerank (0.94 → 0.97 Hit@5, 0.84 → 0.89 MRR) améliore
surtout l'ordre.

### Retrieval (automatique) — récap

| Métrique | Définition |
|---|---|
| **Hit@5 topic** | au moins un `expected_topic` dans le top-5 (chiffre README) |
| **Hit@k topic** | idem pour un k donné (lots A–J : aussi k ∈ {3, 6}) |
| **Hit@k post** | le `expected_post` dans le top-k posts (grain post uniquement) |
| **MRR** | moyenne de `1/rang` du premier hit pertinent (0 si absent) |
| Pollution | slots evidence occupés par un même topic (mesure l'agrégation) |

### Génération (semi-auto)

| Métrique | Comment |
|---|---|
| Liens cités réels | % `[[n]]` → `Post.exists?` — devrait être 100 % (sanitizer) |
| Citation pertinente | le message cité porte-t-il la réponse ? (humain, 0/1) |
| Fidélité | claims supportées par l'evidence (LLM-juge ou relecture) |
| Abstention correcte | hors-sujet → abstention, pas d'invention |
| CTA présent | footer « Pour aller plus loin » avec invitation à poster |

## 3. Protocole

1. **Baseline `A`** (config live, grain topic) : faire tourner le jeu sur le
   forum local → remplir le tableau. C'est la référence à battre.
2. Chaque config (`B`, `C`, `D`, `E`…) : **un seul facteur changé** vs la
   config précédente, même jeu, mêmes métriques.
3. Résultats → tableau ci-dessous + notes qualitatives (exemples marquants).
4. Une question qui régresse = on la comprend avant de conclure.

## 4. Tableau de résultats (à remplir)

| Config | Hit@5 topic | Hit@k post | Liens réels | Abstention OK | Notes |
|---|---|---|---|---|---|
| A (live, topics) | **39/95** (kw 17/95, sem 32/95) | n/a | | | 13/09 v2, goldens corrigés — hybrid=41% |
| B (posts natifs) | **88/95** | post exact `#1` ×2 (carmina-sizing, glaçage-sèche-cheveux) | | | 13/09 v2 — 425k posts embeddés |
| C (posts enrichis) | **0.85** (n=796) | — | | | 14/09 — **mesuré, rejeté** : enrichir le texte embeddé (extrait OP + parent) dégrade vs B (0.94) — dilution du contenu du post, §4quater |
| D (+ voisinage) | | | | | côté génération (contexte LLM), pas Hit@k |
| E (+ rerank) | **97%** (n=796) | `p✓` conservés | | | 13/09 — cross-encoder CPU, Hit@5=0.97/MRR=0.89 (rrf rerank×hybrid) — détail §4ter |
| F (fusions RRF) | **87-88/95** | `p✓` ×2 conservés en #1 | | | 13/09 v2 — posts×hybrid MRR **0.80** |
| G (routing taille) | 84-88/95 | `p✓` ×2 | | | 13/09 — **rejeté** : dégrade vs F, le RRF route déjà implicitement |

Constats routing par taille (13/09, seuils 25/50/100/250 posts) : filtrer les
topics > N posts du canal topic avant fusion **dégrade monotonement** (MRR
0.68@25 → 0.76@250 < 0.80 sans filtre). Les longs fils n'obtiennent de toute
façon quasiment jamais de vote « topic » (embedding dilué = invisible), donc
il n'y a pas de bruit à retirer ; couper les fils moyens retire des votes
utiles. **Le RRF implémente déjà l'esprit du routing** : un megathread ne
remonte que via ses posts, un fil court profite des deux canaux. Variante
documentée puis abandonnée — résultat négatif, gardé pour la démonstration.

Constats baseline A→B (13/09, n=95, goldens v2) : le canal posts natif seul
fait **Hit@5 0.93 / MRR 0.77** vs hybrid topic 0.41. Correction de goldens
par pooling (13/09) : les « échecs » initiaux remontaient des fils **valides**
absents de la liste attendue — élargis pour `corthay-avis`, `noeuds-lacets`,
`presentation-nouveau-membre`, `bienvenue-nouveau` ; `richelieu-bout-rapporte`
reformulé (un membre nomme la marque). **Leçon méthodo : l'écart initial
0.87→0.93 vient de la complétude des goldens, pas du retrieval** — tenir les
goldens à jour est la partie la plus fragile du benchmark.

Constats fusions (13/09) : RRF posts×{semantic, hybrid} **ne gagne pas de
rappel** (posts suffit) mais **améliore le MRR** (0.77→0.80) et rescute des
échecs posts (`loding-pointure` #23→**#1**, `grande-pointure` #11→#1 — le
sizing dilué en posts profite du signal topic sémantique). RRF posts×keyword
**dégrade** (bruit BM25 : MRR 0.74). Pollution canal posts : top-5 = 2.8
topics distincts en moyenne, topic dominant 63 % des slots.

Constats baseline A (12/09) : le megathread Carmina (2690 posts) absent des
top-20 sémantiques **et** top-25 keyword → la dilution topic-embedding est
réelle et mesurée. La gate titre (`relevance_score` exige un mot distinctif
dans le titre) rejette aussi des fils pertinents dont le titre ne contient
pas le mot-clé — à garder en tête quand on lira les métriques post-grain.

## 4bis. Confirmation à grande échelle (812 questions, 13/09)

Le lot A-J (101 questions curées, goldens vérifiés par pooling) a été
complété par un **lot généré à l'échelle** (section K de `questions.yml`,
+701 questions + 10 hors-sujet, sourcées par mining large de toutes les
catégories/tags de la base — méthodologie différente, documentée en tête
de section, golden = topic source unique sans union multi-fils). Objectif :
vérifier que les résultats du lot curé ne sont pas un artefact de petit
échantillon.

| Canal | Hit@5 (n=796) | MRR |
|---|---|---|
| semantic (topic) | 0.55 | 0.43 |
| keyword (topic) | 0.41 | 0.38 |
| posts natifs | **0.94** | **0.84** |
| hybrid (prod actuelle) | 0.68 | 0.63 |
| rrf posts×hybrid | **0.95** | **0.88** |
| routed_250 | 0.95 | 0.86 |
| posts enrichis (C) | 0.85 | 0.80 |
| rrf enriched×hybrid | 0.92 | 0.85 |
| rerank enriched | 0.91 | 0.86 |

**Confirmé** : l'avantage posts natifs / fusion RRF tient à l'échelle, en
s'améliorant légèrement (bruit statistique réduit). **Écart notable vs le
lot curé** : `hybrid` prod fait 0.68 ici contre 0.41 sur A-J — le lot généré
contient beaucoup de titres très distinctifs (marques/produits nommés) que
le BM25 matche facilement, alors que A-J teste délibérément des
reformulations et megathreads plus durs. Les deux mesures sont
complémentaires : A-J documente les cas fins, K mesure la robustesse
générale. Le résultat du routing par taille (rejeté sur A-J) est confirmé
rejeté ici aussi (routed_250 < rrf_post_hyb sans filtre).

## 4ter. Config E — rerank cross-encoder (13/09, n=796)

Modèle : `cross-encoder/mmarco-mMiniLMv2-L12-H384-v1` (multilingue, léger,
CPU — chargé une fois via `sentence-transformers`, `--rerank` dans
`run_eval.py`). Re-trie le top-25 du canal posts (`{titre}. {300 premiers
caractères du post}` vs question) avant dédup par topic.

| Canal | Hit@5 | MRR |
|---|---|---|
| posts natifs | 0.94 | 0.84 |
| rrf posts×hybrid | 0.95 | 0.88 |
| **rerank** | **0.97** | 0.88 |
| **rrf rerank×hybrid** | **0.97** | **0.89** |

Le rerank gagne surtout en **rappel** (0.94→0.97 Hit@5) : il remonte des
posts pertinents mal classés par la seule distance cosine, déjà présents
dans le top-25 mais pas dans le top-5. Gain net mais incrémental par
rapport au saut initial topic→post (qui reste le facteur dominant du
chantier). `eval_retrieval.rb` expose désormais `text` (titre + extrait
300c) par post pour permettre le rerank côté hôte sans étape supplémentaire
côté conteneur.

## 4quater. Config C (posts enrichis) — mesuré, rejeté (14/09, n=796)

Implémentée pour la vitrine (métriques comparables sur tout le dataset) :
backfill complet `strategy_id=2` sur les 425 505 posts
(`backfill_enriched.rb`, ~3h GPU). Texte embeddé = contexte natif
(titre+cat+tags) **+ extrait 500c du message initial du fil + extrait 400c
du post parent** (`reply_to_post_number`), tronqué à max_seq−2 comme le
natif. Hypothèse : désambiguïser les réponses courtes (« pareil en 8.5 »)
que le post nu ne contextualise pas.

| Canal | Hit@5 | MRR |
|---|---|---|
| posts natifs (s1) | **0.94** | **0.84** |
| **posts enrichis (s2)** | 0.85 | 0.80 |
| rrf posts×hybrid | **0.95** | **0.88** |
| rrf enriched×hybrid | 0.92 | 0.85 |
| rerank (s1) | **0.97** | 0.88 |
| rerank enriched (s2) | 0.91 | 0.86 |

**Résultat négatif, uniforme sur toutes les variantes** : l'enrichissement
coûte ~9 pts de Hit@5 et ~4 pts de MRR au canal seul, et la dégradation se
propage aux fusions et au rerank. Interprétation : l'extrait OP/parent
consomme du budget de tokens et **dilue le contenu propre du post** dans
le vecteur — le bruit contextuel nuit plus que la désambiguïsation n'aide.
Cas typique : `scaled-faq-les-diff-rents-montages` — le golden (36778)
est #1 en s1 mais **sort du top-25 en s2** : le contexte OP mutualisé
uniformise les vecteurs des posts d'un même fil et fait basculer vers un
fil voisin (36856) qui squatte les 5 premiers slots à distance ~égale.

**Décision : rejetée sur mesure.** Le post nu (titre+cat+tags+contenu) est
la bonne granularité. Le contexte a sa place **au moment de la génération**
(config D — voisinage injecté dans le prompt LLM, sans toucher aux
embeddings), pas dans le vecteur indexé.

Note dataset : les échecs résiduels (~3 % après rerank) restent dominés par
les titres génériques du lot K (« Présentation » : 1671 fils proches en
base, « Question » : 211, « ceinture » : 123) dont le golden single-topic
est structurellement ambigu — limite de mesure, pas du retrieval.

## 4quinquies. Éval FULL — génération réelle (14/09, n=17→20)

Premier test bout-en-bout avec le **vrai LLM de prod** (`qwen3:30b-a3b-q6k`,
vLLM mini PC `:32134`). `eval_full.rb` émet par question l'evidence prod
(`instructions_block`/`for_question` tels quels) + le top-25 posts natifs ;
`run_full_eval.py` reconstruit le bloc « new » (posts+rerank, même gabarit),
appelle le LLM avec `system = persona + block`, et recueille la réponse +
les marqueurs `[[n]]` pour validation. Digest lisible dans
`results/*-full-*.yml`.

### Enseignements (17 questions : 14 in-domain, 3 hors-sujet)

| | prod (grain topic) | new (posts+rerank) |
|---|---|---|
| in-domain | répond sur 12/14 ; **abstention à tort ×2** (`montage-norvegien-def`, `carmina-sizing-megathread` — evidence vide) | répond sur 14/14 |
| hors-sujet | s'abstient ×3 proprement | **hallucine ×3** avec citations (recette inventée, « 42 °C à Paris », « comité d'investissement DPEC ») |
| citations invalides | 2 (`scaled-aston-martin` cite [[2]][[3]] avec 1 seule source) | 0 |
| latence LLM | ~3-10 s/réponse (mini PC) | idem |

**Constat central** : la gate titre de prod servait d'abstention *par
accident* — hors-sujet → aucun mot distinctif dans les titres → evidence
vide → abstention. En la supprimant, on gagne le rappel in-domain (les 2
abstentions à tort sont corrigées) mais on **perd la protection
out-of-domain** : le canal posts retourne toujours 25 candidats et le LLM
les exploite, même hors propos.

**Le score CE seul ne tranche pas proprement** (calibration 14/09) :
top-1 CE sur 796 questions in-domain : min −4.74, p25 +0.42, 4/796 < −4 ;
sur 16 hors-sujet : −5.9 → **+2.77**. L'overlap vient du Comptoir —
le forum parle cuisine, vin, cinéma : « bœuf bourguignon » a des fils
tangentiels légitimes (cinema hors-sujet = +2.77). Un seuil −4 coupe les
cas extrêmes sans faux négatif mesuré in-domain, mais laisse passer la
zone grise ; c'est autant une décision **produit** (le bot doit-il répondre
aux questions Comptoir ?) qu'un réglage technique.

**À décider pour le design final de l'abstention** (options, pas encore
tranché) : seuil CE calibré, nombre minimal de sources au-dessus d'un
score, deuxième signal lexical, ou catégories à exclure du retrieval.
L'éval full a rempli son rôle : révéler ce déficit que Hit@k ne mesure
pas — 0.97 de rappel ≠ réponses sûres.

### 4.4 Solution mesurée : zone graduée (weak evidence) — 14/09 run `weak-zone`

Le gate binaire (evidence pleine / vide) est remplacé par **trois zones**
sur le score CE top-1 : `< −4` → evidence vide (abstention) ;
`[−4, +1[` → bloc `WEAK_EVIDENCE` : les sources sont fournies mais avec
l'instruction d'assumer la pertinence faible (« dis honnêtement qu'aucun
extrait ne répond vraiment, pointe le fil le plus proche avec prudence,
invite à poster ») ; `≥ +1` → evidence normale.

Résultat sur les 17 cas représentatifs (`--variants new`,
`--weak-threshold 1.0`) :

- **les 3 hallucinations hors-sujet disparaissent** : cuisine → « aucun
  extrait ne fournit une recette » ; meteo → « aucune information
  précise » ; finance → « aucune recommandation disponible ». Plus de
  « 42 °C » ni de « comité d'investissement DPEC » affirmés.
- **aucune régression in-domain** : `calceophilie` (CE −2.32, zone
  faible !), `bannissement` (−1.87), `carmina-megathread` (−0.91),
  `presentation` (−0.21) répondent tous correctement — le cadrage gradué
  ne transforme pas les questions légitimes à CE bas en abstentions.
- les cas confiants (CE ≥ +1, incluant Comptoir : aston-martin +3.8,
  finsbury +3.4) répondent normalement.

Enseignement clé : l'overlap des distributions CE (in-domain min −4.7 vs
hors-sujet max +2.8) rend tout seuil dur imparfait — **mais la zone
graduée n'a pas besoin de séparer proprement** : les cas ambigus sont
traités avec honnêteté plutôt que tranchés. C'est la réponse mesurée au
problème « grain post sans protection OOD » relevé en §4.3.

**Attention à l'arbitrage qualité/sécurité** — distribution CE top-1
recomputée sur les 796 questions in-domain (offline, sans LLM) :

| Seuil weak | % questions légitimes en zone « prudente » |
|---|---|
| +2.0 | 33 % |
| +1.0 | **25 %** (valeur du premier test — trop haut) |
| **0.0** | **17 %** |
| −1.0 | 10 % |
| −4.0 (abstention) | 0 % |

Les 3 hors-sujet mesurés (−0.74, −0.46, −3.60) tombent tous dans
`[−4, 0)` → seuil **0.0** capture les mêmes cas en divisant presque par
deux l'exposition des questions légitimes (25 % → 17 %). Le coût du
bloc WEAK est stylistique (réponse plus prudente), pas une abstention —
les questions légitimes à CE bas y répondent correctement (calceophilie
−2.3). Arbitrage à confirmer par run A/B à l'échelle.

Fichier : `results/20260914-115544-weak-zone.*`. Voir aussi `SAFETY.md`
(axe refus/abus — complémentaire : le weak-block gère la pertinence
faible, la clause de refus gère les demandes hors-rôle).

## 5. Harness

`rag/eval/` :

- `questions.yml` — jeu de questions + `expected_topic_ids` (golden). Le
  seed initial est **à valider/enrichir** (certaines attendues sont des
  suppositions — vérifier que le fil listé est bien le canonique).
- `safety.yml` — sondes de refus/injection (axe sécurité, cf. `SAFETY.md`).
- `input_gate.yml` — règles regex du gate d'entrée (intention, pas sujet).
- `prompt_clauses/` — variantes de system prompt testables sans toucher
  la DB (`--system-append`).
- `eval_retrieval.rb` — tourné **dans le conteneur** (`rails runner`) :
  rejoue `Retrieval` sans cache, décompose semantic / keyword / hybrid.
- `run_eval.py` — côté hôte : copie le ruby, exécute, calcule Hit@k/MRR
  par canal, sauvegarde `results/<date>-<label>.json`.
- `eval_full.rb` + `run_full_eval.py` — éval **bout-en-bout** : retrieval
  prod vs posts+rerank, vrai LLM (mini PC), validation des citations,
  gate, zone faible, injection d'evidence.

```bash
python3 -m venv rag/eval/.venv && rag/eval/.venv/bin/pip install pyyaml
rag/eval/.venv/bin/python rag/eval/run_eval.py --label baseline-topic
# options : --k 6  --container app  --questions rag/eval/questions.yml

# pour --rerank (config E, cross-encoder CPU, ~1.5 Go RAM au chargement) :
rag/eval/.venv/bin/pip install sentence-transformers
rag/eval/.venv/bin/python rag/eval/run_eval.py --label with-rerank --rerank

# éval génération bout-en-bout (vrai LLM mini PC, ~10 s/question) :
rag/eval/.venv/bin/python rag/eval/run_full_eval.py \
    --questions rag/eval/safety.yml --label safety-v3 \
    --input-gate rag/eval/input_gate.yml \
    --system-append rag/eval/prompt_clauses/refusal.txt \
    --weak-threshold 0.0
# options : --n 20  --ids a,b,c  --variants prod,new  --abstain-threshold -4
```

> Les métriques retrieval tournent **sans LLM** → boucle d'itération rapide.
> L'éval génération appelle le vrai `qwen3:30b` du mini PC via Tailscale —
> compter ~10 s par question et par variante.
