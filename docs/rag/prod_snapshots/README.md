# Snapshots état production — avant déploiement pipeline posts

Pris le **14 septembre 2026**, avant l'activation de `ai_embeddings_per_post_enabled`
et le portage du pipeline évalué dans le plugin. Objectif : rollback < 5 min.

## Contenu

| Fichier | Contenu | Restauration |
| --- | --- | --- |
| `system_prompt_live_2026-09-14.txt` | `AiAgent#1.system_prompt` (742 car.) copié tel quel depuis la prod | `agent.system_prompt = File.read(...)` via `rails runner` |
| `persona_and_ai_settings_2026-09-14.json` | Attributs persona + tous les `SiteSetting ai_*` | Réappliquer via `SiteSetting.<name> = <value>` / admin |

Le `system_prompt` live est **identique** à `scripts/templates/guide_depiedencap_system_prompt.txt`
(seul le `\n` final diffère) — le fichier template fait donc aussi foi de backup.

## État non fichier

- **Plugin `depiedencap-ai-citations` déployé** : identique (md5) au commit
  `b4ada69eb00fe61267d0b3a6d717223d7cd514f2` de ce dépôt. Rollback = redeployer
  ce commit via `scripts/deploy_depiedencap_ai_citations_plugin.py` (sur le VPS :
  `docker cp` vers `/var/www/discourse/plugins/` + `/shared/depiedencap-plugins/`,
  puis `sv restart unicorn`).
- **Persona** : `id=1`, `allowed_group_ids=[42]` (ia_demo), `tools=[]`,
  `temperature=0`, `default_llm_id=1` (Qwen 30B mini PC, `:32134`).
- **Embeddings prod** : `EmbeddingDefinition#1` = bge-m3 →
  `http://<MINI_PC>:32134/v1/embeddings` (Ollama mini PC, 1024 dims,
  `max_sequence_length=4096`). `ai_topics_embeddings` remplie (22 340) ;
  `ai_posts_embeddings` vide à cet instant.
- **Backfill natif** : `Jobs::EmbeddingsBackfill` (toutes les 5 min, queue `low`,
  `cluster_concurrency 1`), `ai_embeddings_backfill_batch_size=10`.
  Stratégie native = `Truncation` → `(model_id=1, strategy_id=1,
  strategy_version=1)` — identique à la stratégie évaluée gagnante (config B).
- **VPS** : ~315 Mio libres / 2,9 Gio disponibles, 12 Gio disque libres —
  surveiller pendant le backfill.

## Rollback rapide

```bash
# Désactiver le backfill posts
ssh <vps> "docker exec app bash -lc \"cd /var/www/discourse && \
  su discourse -c 'bundle exec rails runner \\\"SiteSetting.ai_embeddings_per_post_enabled=false; \
  SiteSetting.ai_embeddings_backfill_batch_size=10\\\"'\""

# Restaurer le prompt
ssh <vps> "docker exec app bash -lc \"cd /var/www/discourse && \
  su discourse -c 'bundle exec rails runner \\\"a=AiAgent.find(1); \
  a.system_prompt=File.read(\\\"/tmp/prompt_backup.txt\\\"); a.save!\\\"'\""
# (uploader au préalable system_prompt_live_2026-09-14.txt vers /tmp/prompt_backup.txt du conteneur)

# Revenir au plugin précédent : redeployer le commit b4ada69 + sv restart unicorn
```
