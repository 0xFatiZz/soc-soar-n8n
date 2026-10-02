# Scénarios de test

Quatre scénarios couvrent toutes les branches du workflow : faible risque, investigation, blocage réussi, blocage en échec. Les alertes sont **simulées** en envoyant un JSON au webhook, au format d'une alerte Wazuh.

## Préparation

1. Services démarrés (`docker compose ps`), modèle présent (`ollama list`).
2. Credentials n8n configurés et pfSense accessible en SSH.
3. Deux modes d'exécution :
   - **Test** : cliquer sur **Execute workflow** dans n8n, puis envoyer la requête sur `/webhook-test/wazuh-alert`.
   - **Production** : workflow **Active**, requête sur `/webhook/wazuh-alert`.
4. Compter environ **une minute** par alerte (le modèle tourne sur CPU).

Les requêtes ci-dessous sont données pour PowerShell. Depuis Linux, utiliser `curl` :

```bash
curl -X POST http://192.168.154.1:5678/webhook-test/wazuh-alert \
  -H "Content-Type: application/json" \
  -d '<JSON de l alerte>'
```

## Commandes de vérification

```bash
# Dernières lignes d'audit
docker exec -it postgres-soc psql -U analyst -d soc -c "SELECT id, source_ip, score, severity, action, status FROM audit_log ORDER BY id DESC LIMIT 5;"

# Liste de blocage de pfSense
ssh -i ~/.ssh/n8n_pfsense root@192.168.154.254 "pfctl -t n8n_blocklist -T show"
```

---

## Scénario 1 : faible risque

**Objectif** : vérifier que les alertes bénignes sont enregistrées sans déranger l'analyste, et que les alertes à faible risque envoient un message discret.

### 1A. Faux positif (score sous 20)

**Alerte** : connexion réussie depuis une IP saine, règle de niveau 3.

```powershell
$body = '{"timestamp":"2026-10-02T10:00:00Z","rule":{"id":"5501","level":3,"description":"User login success"},"agent":{"name":"ews-01"},"data":{"srcip":"8.8.8.8"},"full_log":"user login ok"}'
Invoke-RestMethod -Uri http://192.168.154.1:5678/webhook-test/wazuh-alert -Method Post -ContentType "application/json" -Body $body
```

**Chemin attendu** : ... `Score >= 50` (faux) puis `Log Low Score`. `Notify Low Risk` (faux) : aucun message.

| Vérification | Résultat attendu |
|---|---|
| `base_score` / `score` | 0 / 0 |
| `in_gray_zone` | `false` |
| `severity` / `recommended_action` | `low` / `ignore` |
| Telegram | Aucun message |
| `audit_log` | Une ligne `status = false_positive` |
| pfSense | Liste inchangée |

<!-- TODO : captures -->
![Exécution n8n, scénario 1A](images/test1a-n8n.png)
![Ligne d'audit, scénario 1A](images/test1a-audit.png)

### 1B. Faible risque (score de 20 à 49)

**Alerte** : plusieurs échecs de connexion, règle de niveau 8, IP saine.

```powershell
$body = '{"timestamp":"2026-10-02T10:30:00Z","rule":{"id":"5710","level":8,"description":"Multiple failed logins"},"agent":{"name":"ews-01"},"data":{"srcip":"8.8.8.8"},"full_log":"failed login x3"}'
Invoke-RestMethod -Uri http://192.168.154.1:5678/webhook-test/wazuh-alert -Method Post -ContentType "application/json" -Body $body
```

**Chemin attendu** : ... `Score >= 50` (faux), puis en parallèle `Log Low Score` et `Notify Low Risk` (vrai) vers `Telegram Routine`.

| Vérification | Résultat attendu |
|---|---|
| `base_score` / `score` | 20 / 20 (hors zone grise, l'IA n'intervient pas) |
| `severity` | `medium` |
| Telegram | Message court **sans sonnerie** (« Alerte à faible risque (enregistrée) ») |
| `audit_log` | Une ligne `status = low_risk` |
| pfSense | Liste inchangée |

<!-- TODO : captures -->
![Message Telegram de routine](images/test1b-telegram.png)
![Ligne d'audit, scénario 1B](images/test1b-audit.png)

---

## Scénario 2 : investigation

**Objectif** : vérifier qu'une alerte sérieuse venant d'une machine **interne** déclenche une investigation humaine, **sans blocage automatique**, et que l'IA n'influence la décision que dans la zone grise.

**Alerte** : scan Modbus depuis une machine interne non protégée, règle de niveau 12.

```powershell
$body = '{"timestamp":"2026-10-02T11:00:00Z","rule":{"id":"100201","level":12,"description":"Modbus scan from internal host"},"agent":{"name":"ot-gateway"},"data":{"srcip":"192.168.10.50"},"full_log":"modbus scan"}'
Invoke-RestMethod -Uri http://192.168.154.1:5678/webhook-test/wazuh-alert -Method Post -ContentType "application/json" -Body $body
```

**Chemin attendu** : ... `Score >= 50` (vrai), `Action Router` (sortie **Investigate**), `Telegram Investigate`.

| Vérification | Résultat attendu |
|---|---|
| `vt_summary` | `Internal/private IP, no external reputation available.` (VirusTotal est sauté) |
| `base_score` | 70 (règle +50, source interne +20) |
| `in_gray_zone` | `true` |
| `score` | Entre 60 et 79 (ajustement de l'IA appliqué, plafond à 79) |
| `recommended_action` | `investigate` (jamais `block`) |
| `guardrail_notes` | Détaille les facteurs et l'ajustement |
| Telegram | Message « ALERTE À VÉRIFIER » avec règle, IP, score et résumé de l'IA |
| pfSense | Liste inchangée |

> Limite connue : la branche `investigate` n'écrit pas dans `audit_log`.

<!-- TODO : captures -->
![Exécution n8n, scénario 2](images/test2-n8n.png)
![Message Telegram d'investigation](images/test2-telegram.png)

---

## Scénario 3 : blocage automatique réussi

**Objectif** : vérifier le blocage de bout en bout : enrichissement, score, validation de la cible, commande SSH, audit et notification.

**Alerte** : écriture Modbus non autorisée depuis un relais Tor connu, règle de niveau 15.

```powershell
$body = '{"timestamp":"2026-10-02T12:00:00Z","rule":{"id":"100200","level":15,"description":"Modbus write from unauthorized host"},"agent":{"name":"ot-gateway"},"data":{"srcip":"185.220.101.5"},"full_log":"test log"}'
Invoke-RestMethod -Uri http://192.168.154.1:5678/webhook-test/wazuh-alert -Method Post -ContentType "application/json" -Body $body
```

**Chemin attendu** : ... `Score >= 50` (vrai), `Action Router` (**Block**), `Validate Block Target`, `Valid Target?` (vrai), `pfSense Block IP`, `Block OK?` (vrai), `Log Block`, `Telegram Auto-Block`.

| Vérification | Résultat attendu |
|---|---|
| `vt_summary` | Une dizaine de détections malveillantes, tag `tor` (les chiffres varient dans le temps) |
| `base_score` / `score` | 100 / 100 (règle +60, détections +30, Tor +20) |
| `in_gray_zone` | `false` : ajustement de l'IA ignoré |
| `severity` / `recommended_action` | `critical` / `block` |
| `block_valid` | `true` |
| `block_command` | `pfctl -t n8n_blocklist -T add 185.220.101.5` |
| Nœud SSH | `code: 0`, `stderr: 1/1 addresses added.` (ou `0/1` si l'IP y est déjà) |
| pfSense | La liste contient `185.220.101.5` |
| Telegram | Message « BLOCAGE AUTOMATIQUE » **avec sonnerie** et la commande de déblocage |
| `audit_log` | Une ligne `status = blocked` |

**Nettoyage** (IP de test) :

```bash
ssh -i ~/.ssh/n8n_pfsense root@192.168.154.254 "pfctl -t n8n_blocklist -T delete 185.220.101.5"
```

<!-- TODO : captures -->
![Exécution n8n, scénario 3](images/test3-n8n.png)
![Liste de blocage pfSense](images/test3-pfsense.png)
![Message Telegram de blocage](images/test3-telegram.png)
![Ligne d'audit, scénario 3](images/test3-audit.png)

---

## Scénario 4 : échec du blocage

**Objectif** : vérifier que le pipeline **n'annonce jamais** un blocage qui n'a pas eu lieu, et qu'il demande une action manuelle.

**Méthode (injection de panne)** : utiliser l'alerte du scénario 3, après avoir remplacé **temporairement** la commande du nœud `pfSense Block IP` par :

```text
exit 3
```

Aucune commande `pfctl` n'est lancée, le nœud renvoie simplement le code 3. Cela simule une panne réelle : pfSense injoignable, clé refusée, `pfctl` en erreur.

**Chemin attendu** : ... `Valid Target?` (vrai), `pfSense Block IP` (code 3), `Block OK?` (**faux**), `Log Block Failed`, `Telegram Block Failed`.

| Vérification | Résultat attendu |
|---|---|
| Nœud SSH | `code: 3` |
| `Block OK?` | Sortie **False** |
| Telegram | Message « BLOCAGE NON EFFECTUÉ » avec la raison et la commande manuelle |
| Telegram | **Aucun** message « BLOCAGE AUTOMATIQUE » |
| `audit_log` | Une ligne `status = block_failed`, aucune ligne `blocked` |

**Après le test**, remettre dans le champ **Command** : `{{ $json.block_command }}`.

<!-- TODO : captures -->
![Exécution n8n, scénario 4](images/test4-n8n.png)
![Message Telegram d'échec](images/test4-telegram.png)
![Ligne d'audit, scénario 4](images/test4-audit.png)

---

## Synthèse

| Scénario | Alerte | Score | Action | Notification | Audit |
|---|---|---|---|---|---|
| 1A | Connexion, niveau 3, `8.8.8.8` | 0 | `ignore` | Aucune | `false_positive` |
| 1B | Échecs de connexion, niveau 8, `8.8.8.8` | 20 | `ignore` | Telegram discret | `low_risk` |
| 2 | Scan Modbus interne, niveau 12 | 60 à 79 | `investigate` | Telegram avec détails | Aucun (limite connue) |
| 3 | Écriture Modbus, relais Tor, niveau 15 | 100 | `block` | Telegram avec sonnerie | `blocked` |
| 4 | Idem, commande en échec | 100 | `block` (échec) | Telegram d'action manuelle | `block_failed` |
