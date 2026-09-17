# Forum local — recette de redéploiement (réplique du VPS)

> **But** : un Discourse local = copie exacte de `depiedencap.org`
> (données + config IA + vecteurs), pour développer/tester le RAG sans
> toucher la prod. IA : embeddings en **local** (bge-m3 CPU), chat LLM sur
> le **mini PC** via Tailscale (config déjà dans le dump).
> Marche sur laptop **et** PC fixe (Tailscale requis dans les deux cas).

## 0. Prérequis machine

| Besoin | Minimum | Vérifier |
|---|---|---|
| Docker Engine | installé + daemon | `docker info` |
| RAM dispo | ~6 Go | Discourse ~3-4 Go + Ollama ~2 Go |
| Disque | **~60 Go libres** | tar 10 Go + uploads ~19 Go + DB ~5 Go + image ~6 Go + marge |
| Tailscale | connecté | `tailscale status` → mini PC `<MINI_PC>` |
| Ollama (local, embeddings dev) | CPU suffit | `ollama --version` |
| Ce repo | cloné (`scripts/` du chantier) | `git status` propre |

Install (Ubuntu/Tuxedo — sudo, par l'utilisateur) :

```bash
# ⚠️ Tuxedo OS : get.docker.com détecte mal la distrib (écrit un dépôt
# Debian trixie → paquets cassés). Utiliser les dépôts Ubuntu :
sudo apt install -y docker.io
sudo usermod -aG docker "$USER"   # re-login ensuite (ou `newgrp docker`)
docker info

# Ollama (bge-m3 local ; RTX 2060 détectée auto si driver NVIDIA présent,
# sinon CPU — suffisant dans les deux cas)
curl -fsSL https://ollama.com/install.sh | sh
ollama pull bge-m3

# Ollama doit écouter au-delà de 127.0.0.1 (le conteneur passe par
# host.docker.internal → gateway docker0) :
sudo mkdir -p /etc/systemd/system/ollama.service.d   # ← dossier à créer d'abord
printf '[Service]\nEnvironment="OLLAMA_HOST=0.0.0.0"\n' | sudo tee /etc/systemd/system/ollama.service.d/override.conf
sudo systemctl daemon-reload && sudo systemctl restart ollama
curl -s http://localhost:11434/api/tags   # doit lister bge-m3
```

## 1. Récupérer le dernier backup prod

```bash
# Liste des archives sur le NAS (chaîne hebdo, rétention glissante)
ssh <nas> 'ls -lht <NAS_BACKUP_DIR>/ | head'

# Copier le plus récent (~10 Go, patience). Référence 07/09/2026 :
#   depiedencap-2026-09-07-010010-v20260817054353.tar.gz
scp <nas>:<NAS_BACKUP_DIR>/depiedencap-AAAA-MM-JJ-*.tar.gz ~/dpec-restore/
```

> La version Discourse exacte est dans le `meta.json` du tar :
> `tar -xzf depiedencap-*.tar.gz -O meta.json | head` → si le restore se
> plaint de version, pinner `version:` dans `app.yml` en conséquence.

## 2. Installer discourse_docker en local

```bash
sudo git clone https://github.com/discourse/discourse_docker.git /var/discourse
cd /var/discourse
sudo cp <clone>/rag/local/app.yml containers/app.yml   # template prêt, sans secrets
```

`rag/local/app.yml` — diff vs prod : hostname `localhost`, **pas de SMTP**
(aucun `DISCOURSE_SMTP_*`), port 80 seul, `--add-host
host.docker.internal:host-gateway` (pour joindre l'Ollama local depuis le
conteneur), hook `after_code` qui recopie les 3 plugins depuis `/shared`.

```bash
sudo ./launcher bootstrap app
sudo ./launcher start app
```

## 3. Restaurer le dump

```bash
sudo cp ~/dpec-restore/depiedencap-*.tar.gz /var/discourse/shared/standalone/backups/default/
sudo chown 1000:www-data /var/discourse/shared/standalone/backups/default/*.tar.gz

docker exec app bash -lc 'cd /var/www/discourse && su discourse -c "bundle exec script/discourse enable_restore"'
docker exec app bash -lc 'cd /var/www/discourse && su discourse -c "bundle exec script/discourse restore depiedencap-AAAA-MM-JJ-....tar.gz"'
```

Le restore fait **déjà** deux choses tout seul : `Remapping
'https://depiedencap.org' to 'http://localhost'` (cooked réécrits) et
« Disabling outgoing emails for non-staff users ». Reste à durcir :

```bash
# ⚠️ E-mails : passer à "yes" (couvre aussi staff/digests). En pratique
# aucun mail ne peut partir : le SMTP prod était en env vars, absent ici.
docker exec -u postgres app psql discourse -c \
  "UPDATE site_settings SET value='yes' WHERE name='disable_emails';"
```

Puis les 3 plugins custom (le .tar.gz ne contient pas le code). Le hook
`after_code` de `app.yml` les attend dans `/shared/depiedencap-plugins/` :

```bash
sudo mkdir -p /var/discourse/shared/standalone/depiedencap-plugins
cd <clone>/scripts
sudo cp -r discourse_plugin/depiedencap-ai-citations \
          discourse_plugin/depiedencap-onboarding \
          plugins/discourse-depiedencap-locale \
          /var/discourse/shared/standalone/depiedencap-plugins/
cd /var/discourse && sudo ./launcher rebuild app   # ~10-15 min
```

> Thèmes/picker/PWA : dans le dump. `discourse-ai` est **inclus dans
> l'image** officielle — avec `ai_posts_embeddings` (grain post) et son
> index HNSW+binary-quantization natifs : le chantier post-centric peut
> s'appuyer dessus au lieu d'une table custom.

## 4. Recâbler l'IA

La config IA est **dans le dump** : `llm_models` → `http://<MINI_PC>:32134`
(mini PC, joignable via Tailscale — laissé tel quel pour le chat),
`embedding_definitions` id=1 → **à repointer** vers l'Ollama local
(ci-dessous), `allowed_internal_hosts` → ajouter le gateway docker0.

| Composant | Local dev | Comment |
|---|---|---|
| Chat LLM | mini PC `:32134` | inchangé — marche dès le restore |
| Embeddings | **bge-m3 local** `host.docker.internal:11434` | repointer `EmbeddingDefinition` (ci-dessous) |
| pgvector / vecteurs | locale (restaurés) | backfill posts → ici, jamais en prod |

Repointer les embeddings vers l'Ollama local — `embedding_definitions`
est une **table** (id=1 = bge-m3 prod) — SQL direct ou rails runner :

```bash
docker exec -u postgres app psql discourse -c \
  "UPDATE embedding_definitions SET url='http://host.docker.internal:11434/v1/embeddings' WHERE id=1;"
docker exec -u postgres app psql discourse -c \
  "UPDATE site_settings SET value='<MINI_PC>|172.17.0.1|host.docker.internal' WHERE name='allowed_internal_hosts';"
# ⚠️ allowed_internal_hosts matche le NOM D'HÔTE (pas l'IP résolue) —
# sans « host.docker.internal », les appels embeddings échouent avec
# « FinalDestination: all resolved IPs were disallowed » (canal sem vide).

# Vérif depuis l'intérieur du conteneur :
docker exec app curl -s -m 5 -X POST http://host.docker.internal:11434/v1/embeddings \
  -H 'Content-Type: application/json' -d '{"model":"bge-m3","input":"test"}' | head -c 120
# → doit renvoyer du JSON {"object":"list","data":[{"embedding":[...
# (ou garder le mini PC :32134 — marche aussi, juste partagé avec la prod)
```

## 5. Vérifs post-restore

```bash
curl -s http://localhost | head -3                      # forum up
docker exec app rails runner 'puts Post.count'          # ~425k attendus
docker exec app rails runner 'puts AiAgent.find_by(name: "Guide Depiedencap").present?'
docker exec app rails runner 'puts ActiveRecord::Base.connection.execute("SELECT count(*) FROM ai_topics_embeddings").first'  # 22 340
curl -s http://<MINI_PC>:32134/api/tags | head      # mini PC joignable
curl -s http://localhost:11434/api/tags | head          # bge-m3 local
```

Login local : ton compte admin de prod fonctionne tel quel (même hash en
base) — **mot de passe**, pas de lien magique (emails coupés).

Checklist « ne pas casser la prod par procuration » :

- [ ] `disable_emails = yes` (aucun mail réel ne part — digests, D9…)
- [ ] Pas de domaine public pointant sur l'instance locale (localhost only)
- [ ] Backups locaux : `enable_backups` peut être laissé — écrira en local
- [ ] Le compte `demo` existe dans le dump — comportement identique, OK
- [ ] **Redémarrer sidekiq après un restore** : `docker exec app kill -TERM $(docker exec app pgrep -f 'sidekiq.*discourse')`
  (respawn auto via `unicorn_launcher`, ~40 s). Sinon le process garde
  `@readonly_mode = true` en mémoire → tous les `Jobs::Scheduled` no-opent
  silencieusement (`success` dans `scheduler_stats`, ~100 ms, rien fait) :
  pas de rebakes, pas de backfill embeddings, pas de cleanups. Symptôme
  observé : `ai_posts_embeddings` figé malgré job actif toutes les 5 min.

## 6. Différences assumées vs prod

| Écart | Impact |
|---|---|
| Pas de Cloudflare/TLS | Tester les liens en HTTP `localhost` |
| Uploads `optimized/` régénérés à la demande | Premières images lentes, normal |
| SMTP coupé | Onboarding email non testable en local (le MP d'accueil, si) |
| UX bot (suggestions, overlay cold-start, endpoint `/depiedencap-ai/llm-warmup`) | Restreint au compte **`demo`** (`shouldRender` + 403 API) — se connecter en `demo` pour les voir. Identique à la prod, pas un bug. |
| bge-m3 CPU local | Vecteurs identiques (même modèle), juste plus lents |
| `demo-<token>.html` statique | Fichier public, présent dans uploads — marche |

## 7. Dépannage rapide

| Symptôme | Piste |
|---|---|
| Restore échoue « version » | Pinner `version:` app.yml = version du dump |
| `Permission denied` sur le tar | `chown 1000:www-data` (§3) |
| Bot muet / erreur TCP | Mini PC éteint ? `curl :32134/api/tags` ; plugin → message humoristique attendu |
| Embeddings vides | `OLLAMA_HOST=0.0.0.0` + URL `host.docker.internal` (§4) |
| `//localhost/` cassés dans les posts | remap §3 pas (encore) joué |
| Jobs planifiés « success » mais rien ne se passe | readonly résiduel côté sidekiq → restart sidekiq (§5) |
| Bandeaux « thème comporte des erreurs » après restore | bundles JS au vieux format → `Theme.find_each(&:update_javascript_cache!)` + vider `js_asset_info` du cache |
| Job/backfill embeddings figé | verifier `scheduler_stats` (`duration_ms` ~100 ms = no-op) ; verrou `cluster_concurrency:Jobs::EmbeddingsBackfill` (redis **sans** namespace, ttl 120 s) |
