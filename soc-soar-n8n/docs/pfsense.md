# Configuration de pfSense

Le blocage repose sur un **alias** (liste d'IP) déjà interdit par **une règle fixe**. n8n n'a qu'à ajouter l'IP à la liste par SSH.

## 1. Interface de gestion

L'hôte du SOAR n'a pas de route vers le réseau WAN de pfSense (NAT). On ajoute une carte réseau dédiée :

1. Ajouter une carte Host-Only à la VM pfSense (commande `VBoxManage modifyvm`, VM éteinte).
2. Assigner la carte (par exemple `em6`) à une interface `OPT5`.
3. Lui donner une IP statique sur le réseau Host-Only (par exemple `192.168.154.254/24`), **sans passerelle**.
4. Activer le SSH (console, option 14).

## 2. Règles sur l'interface de gestion

| Action | Protocole | Source | Destination | Port |
|---|---|---|---|---|
| Pass | TCP | Hôte du SOAR (`192.168.154.1`) | `192.168.154.254` | 22 |
| Pass | ICMP (echo) | Hôte du SOAR | `192.168.154.254` | (test) |

Seul l'hôte du SOAR peut joindre pfSense par cette interface.

## 3. Alias et règle de blocage

**Alias** : `Firewall > Aliases > IP`

| Champ | Valeur |
|---|---|
| Name | `n8n_blocklist` |
| Type | Host(s) |
| Entrée initiale | `192.0.2.1` (adresse réservée à la documentation, valeur de départ inoffensive) |

**Règle floating** : `Firewall > Rules > Floating`

| Champ | Valeur |
|---|---|
| Action | Block |
| Quick | Oui |
| Interfaces | Zones internes (SOC, DMZ, OPS, SCADA, CONTROL) et WAN |
| Direction | in |
| Protocole | Any |
| Source | Alias `n8n_blocklist` |
| Destination | any |

**Ne pas inclure l'interface de gestion** : une erreur ajoutant l'hôte du SOAR à la liste couperait l'accès à pfSense.

## 4. Accès SSH par clé

Générer une paire de clés sur l'hôte du SOAR :

```bash
ssh-keygen -t ed25519 -f ~/.ssh/n8n_pfsense -N ""
```

Coller la **clé publique** (`n8n_pfsense.pub`) dans `System > User Manager`, champ *Authorized SSH Keys*. La **clé privée** va uniquement dans le credential SSH de n8n. Ne jamais la publier.

Test :

```bash
ssh -i ~/.ssh/n8n_pfsense root@192.168.154.254 "pfctl -t n8n_blocklist -T show"
```

## 5. Commandes utiles

```bash
# Voir la liste de blocage
pfctl -t n8n_blocklist -T show

# Bloquer une IP à la main
pfctl -t n8n_blocklist -T add 203.0.113.50

# Débloquer une IP
pfctl -t n8n_blocklist -T delete 203.0.113.50
```

## 6. Note sur le compte utilisé

Le compte `admin` de pfSense a pour shell le menu de la console et n'exécute pas les commandes passées par SSH. Le compte `root` (mêmes droits) les exécute. C'est une limite connue : l'amélioration prévue est un compte dédié avec `sudo` restreint à `pfctl -t n8n_blocklist -T add`.
