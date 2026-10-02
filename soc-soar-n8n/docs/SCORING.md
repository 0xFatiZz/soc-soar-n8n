# Calcul du score et décision

Le score est calculé **par le code** (nœud `Build Prompt`), pas par le LLM. Le LLM rédige le résumé et propose un ajustement borné (nœud `Parse & Guardrails`).

## 1. Score de base

| Signal | Condition | Points |
|---|---|---|
| Niveau de règle Wazuh | 15 et plus | +60 |
| | 12 à 14 | +50 |
| | 10 à 11 | +35 |
| | 7 à 9 | +20 |
| | 0 à 6 | 0 |
| Détections malveillantes VirusTotal | 10 et plus | +30 |
| | 5 à 9 | +25 |
| | 1 à 4 | +10 |
| Tag `tor` sur l'IP | présent | +20 |
| Source interne non protégée | règle de niveau 12 ou plus | +20 |

Le total est plafonné à **100**. VirusTotal n'est pas interrogé pour une IP privée (inutile, et cela évite de divulguer l'adressage interne).

## 2. Zone grise et ajustement de l'IA

| Score de base | Ajustement de l'IA (de -10 à +10) | Score final |
|---|---|---|
| Moins de 30 | Ignoré | Score de base |
| De 30 à 79 | Appliqué | Score de base + ajustement, plafonné à 79 |
| 80 et plus | Ignoré | Score de base |

L'IA ne peut donc jamais faire passer une alerte au seuil de blocage (80), et elle ne peut pas faire baisser une menace confirmée.

## 3. Sévérité et action

| Score final | Sévérité | Action |
|---|---|---|
| Moins de 20 | `low` | Enregistrement seul (`false_positive`) |
| 20 à 49 | `medium` | Enregistrement et message Telegram sans sonnerie (`low_risk`) |
| 50 à 79 | `high` | `investigate` : message Telegram détaillé |
| 80 et plus | `critical` | `block` si l'IP n'est pas un actif protégé, sinon `investigate` |

## 4. Exemples

| Alerte | Calcul | Score | Résultat |
|---|---|---|---|
| Connexion réussie depuis `8.8.8.8`, règle de niveau 3 | 0 | 0 | `false_positive` |
| Échecs de connexion depuis `8.8.8.8`, règle de niveau 8 | +20 | 20 | `low_risk` |
| Scan Modbus depuis `192.168.10.50` (interne), règle de niveau 12 | +50, +20 | 70 | Zone grise, `investigate` (60 à 79 selon l'IA) |
| Écriture Modbus depuis un relais Tor (10 détections), règle de niveau 15 | +60, +30, +20 | 100 | `block` |

## 5. Pourquoi ne pas laisser le LLM noter

Observations pendant les essais, avec des modèles locaux sur CPU :

| Modèle | Alerte | Score obtenu | Score attendu |
|---|---|---|---|
| Mistral 7B | Relais Tor, règle de niveau 15 | 32 | 70 ou plus |
| Qwen 2.5 3B | Connexion depuis `8.8.8.8`, règle de niveau 3 | 53 | Moins de 20 |
| Qwen 2.5 7B | Connexion depuis `8.8.8.8`, règle de niveau 3 | Même erreur | Moins de 20 |

Un modèle plus grand ne corrige pas le problème : un LLM est adapté pour **résumer et expliquer**, pas pour calculer un score de risque reproductible.
