# Chantier RAG — granularité post, retrieval avancé, évaluation

> **Statut (17/09/2026)** : plugin + pipeline en prod sur le **VPS**
> (Discourse + Postgres/pgvector, 424 835 posts). Inférence sur le **mini
> PC** (Ollama `bge-m3` + `qwen3:30b-a3b-q6k`, TEI mmarco) via Tailscale.
> Flags membre encore **OFF** ; agent limité à un groupe démo. Schéma
> public : [`README.md`](../../README.md). Reprise :
> [`PLAN_RAG_PROD_VPS.md`](../PLAN_RAG_PROD_VPS.md) § « Reprise session ».
> Éval : posts+rerank, Hit@5 0.97 — `EVAL.md` / `SAFETY.md`.

## Pourquoi ce chantier

Le RAG actuel indexe **un vecteur par topic** (~22 340). Sur les megathreads
(300+ messages), un seul vecteur = centroïde sémantique dilué **+** troncature
à 4096 tokens d'entrée → les passages précis en page 12 sont invisibles.
Objectif : retrieval au **grain post** avec citations `/t/slug/id/post_number`,
en gardant le principe produit — **le bot oriente vers les fils, il ne répond
pas à la place des membres**.

C'est aussi un chantier d'apprentissage : on teste les techniques standard de
l'industrie (voir `REFERENCES.md`), on mesure sur **notre** corpus, on documente.

## Documents

| Fichier | Contenu |
|---|---|
| `DESIGN.md` | Architecture, options à tester (matrice de configs), décisions |
| `REFERENCES.md` | Notes de littérature RAG — techniques éprouvées + sources |
| `EVAL.md` | Jeu d'éval, métriques, protocole, résultats retrieval + génération |
| `SAFETY.md` | Red-team, gate d'entrée, clause de refus, injection-evidence |
| `PIPELINE.md` | Architecture bout-en-bout question→réponse + latences mesurées |
| `LOCAL_DEV.md` | Recette : redéployer le forum en local sur n'importe quelle machine |
| `prod_snapshots/` | État prod sauvegardé avant déploiement (prompt, settings, rollback) |
| `../PLAN_RAG_PROD_VPS.md` | **Plan de déploiement + reprise de session** — à lire en premier pour continuer |

## Workflow dev (nouveau)

```
Machine de dev (laptop / PC fixe)          Mini PC IA (prod)
┌────────────────────────────┐             ┌──────────────────────┐
│ Discourse local = réplique │             │ k3s rag-depiedencap  │
│ exacte du VPS (.tar.gz)    │             │ Ollama :32134        │
│ + pgvector locale          │──Tailscale──►│  qwen3:30b (chat)   │
│ + bge-m3 LOCAL (CPU)       │             │  bge-m3 (embeddings  │
│   pour les tests           │             │   prod)              │
└────────────────────────────┘             └──────────────────────┘
```

- Vecteurs dev → pgvector **locale** (zéro risque prod).
- LLM chat dev → mini PC (le laptop ne porte pas un 30B).
- Embeddings dev → bge-m3 **local CPU** (ne pas encombrer la file prod).
- Une fois la solution validée : le bge-m3 **du mini PC** génère les vecteurs
  prod (même modèle = vecteurs compatibles).

## Règles

- Jamais de test de retrieval/embedding contre la base prod.
- Le forum local **n'envoie aucun e-mail** (`disable_emails`, voir `LOCAL_DEV.md`).
- Toute décision de design → ADR dans `DESIGN.md` § Décisions.
- Résultats de benchs → `EVAL.md` (pas de feeling, des chiffres).
