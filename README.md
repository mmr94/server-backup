# server-backup

Sauvegarde système d'un serveur Linux vers un espace FTP / FTPS / SFTP, en une seule commande, pensée pour tourner en cron.

L'objectif : après un crash total, repartir d'une machine nue et retrouver la configuration, les sites, les services, les crontabs et l'état complet du système — sans avoir à se souvenir de quoi que ce soit.

```bash
./server-backup.sh
```

---

## Ce que ça fait

Le script produit **une archive compressée** contenant :

- les chemins que tu listes (`/etc`, `/var/www`, `/root`, `/opt`, …) ;
- un dossier `_system-state/` qui capture ce qu'un `tar` ne voit pas : paquets installés, services activés, règles de pare-feu, unités systemd, crontabs de tous les utilisateurs, conteneurs et volumes Docker, configuration nginx/Apache complète, versions des runtimes, table de montage, disposition des disques.

C'est ce second point qui fait la différence entre « j'ai récupéré mes fichiers » et « je peux reconstruire le serveur ».

L'archive part ensuite sur le FTP, sous un nom temporaire renommé une fois le transfert terminé : une archive visible sur le serveur distant est donc toujours une archive complète.

### Ce que ça ne fait pas

Ce script sauvegarde **le système**, pas les données applicatives volumineuses. Les bases de données et les fichiers utilisateurs relèvent d'une sauvegarde dédiée, plus fréquente.

Pour tout ce qui doit être préparé avant l'archivage — dumps SQL, exports, arrêt d'un service le temps d'une copie cohérente — voir les hooks ci-dessous.

---

## Hooks

Le script ne connaît aucun moteur de base de données, et c'est délibéré : il exécute un script à toi et archive ce qu'il produit.

Dépose un `before_backup.sh` à côté de `backup.conf` :

```bash
cp before_backup.sh.example /etc/server-backup/before_backup.sh
chmod 750 /etc/server-backup/before_backup.sh
```

Tout ce qu'il écrit dans `$BACKUP_STAGING_DIR` entre dans l'archive — sous n'importe quel nom de dossier, sans rien déclarer dans la configuration.

```bash
#!/usr/bin/env bash
set -euo pipefail
[ "$BACKUP_DRY_RUN" = "yes" ] && exit 0

mkdir -p "$BACKUP_STAGING_DIR/_databases"
mysqldump --all-databases --single-transaction --quick \
  > "$BACKUP_STAGING_DIR/_databases/mysql.sql"
mongodump --uri="mongodb://127.0.0.1:27017" \
  --archive="$BACKUP_STAGING_DIR/_databases/mongo.archive"
```

| Variable | Contenu |
|---|---|
| `BACKUP_STAGING_DIR` | Dossier inclus dans l'archive — écrire ici |
| `BACKUP_SERVER_NAME` | Nom du serveur |
| `BACKUP_WORK_DIR` | Répertoire de travail |
| `BACKUP_MODE_NAME` | `snapshot` ou `history` |
| `BACKUP_DRY_RUN` | `yes` / `no` — un hook correct ne dumpe rien en simulation |
| `BACKUP_ARCHIVE_PATH` | *(after seulement)* chemin de l'archive produite |
| `BACKUP_STATUS` | *(after seulement)* `success` / `failure` |

Un `after_backup.sh` est exécuté à la fin, **y compris quand la sauvegarde échoue** — utile pour purger des dumps ou alerter.

Si `before_backup.sh` échoue, la sauvegarde est annulée (`HOOK_FAILURE="abort"`, code `7`) et l'archive précédente reste intacte sur le FTP. Une archive amputée d'un dump raté est pire qu'une absence de sauvegarde : on la croit valide jusqu'au jour de la restauration. Passer à `warn` pour continuer malgré tout.

Lancé en root, le script refuse d'exécuter un hook modifiable par tous — ce serait une porte d'entrée directe vers un accès root.

---

## Installation

```bash
git clone https://github.com/<ton-compte>/server-backup.git /opt/server-backup
cd /opt/server-backup
cp backup.conf.example backup.conf
chmod 600 backup.conf
$EDITOR backup.conf
```

Dépendances (`lftp` est fortement recommandé : il gère FTPS, SFTP, la reprise de transfert et la rotation distante) :

```bash
apt-get install -y tar zstd lftp
```

Puis, dans l'ordre :

```bash
./server-backup.sh --check
```

```bash
./server-backup.sh --dry-run
```

```bash
./server-backup.sh
```

```bash
sudo ./server-backup.sh --install-cron
```

Le cron s'exécute chaque jour à 03h17 — un horaire volontairement décalé de l'heure ronde.

---

## Configuration

Le script cherche sa configuration dans cet ordre :

1. le chemin passé à `--config`
2. `/etc/server-backup/backup.conf`
3. `backup.conf`, à côté du script

`backup.conf` n'est **jamais** versionné (voir `.gitignore`) : il contient le mot de passe FTP. Seul `backup.conf.example` est commité.

### Les réglages qui comptent

| Variable | Rôle |
|---|---|
| `FTP_HOST` `FTP_USER` `FTP_PASS` | Connexion au serveur de sauvegarde |
| `FTP_PROTOCOL` | `ftps` ou `sftp` recommandés — `ftp` fait circuler l'archive en clair |
| `INCLUDE_PATHS` | Ce qui est sauvegardé (les chemins absents sont ignorés proprement) |
| `EXCLUDE_PATTERNS` | Ce qui est écarté : logs, caches, `node_modules`, données SQL brutes |
| `EXCLUDE_SECRETS` | Voir « Modèle de sécurité » ci-dessous |
| `BACKUP_MODE` | `snapshot` (une archive) ou `history` (rotation) |
| `HOOK_FAILURE` | `abort` (défaut) ou `warn` si `before_backup.sh` échoue |
| `MAX_FILE_SIZE_MB` | Filet contre un dump de 40 Go oublié dans `/var/www` |

Un même fichier de configuration convient à plusieurs serveurs : les chemins inexistants sont signalés puis ignorés, jamais fatals.

---

## Modèle de sécurité

L'archive **n'est pas chiffrée** : elle se restaure avec un simple `tar -xf`, sans passphrase à retrouver le jour du crash. Le choix porte donc sur ce qu'on accepte d'y mettre.

### `EXCLUDE_SECRETS="no"` — archive complète (par défaut)

L'archive contient tout, y compris `/etc/shadow`, les clés privées SSH et TLS, et les fichiers `.env`. La restauration est intégrale, sans rien à régénérer.

En contrepartie, **l'archive vaut un accès root**. Ce mode suppose un espace FTP privé et maîtrisé, dont le mot de passe n'est connu que de root, et un transport en `ftps` ou `sftp`.

### `EXCLUDE_SECRETS="yes"` — archive expurgée

Les hashs de mots de passe, clés privées, `.env` et tokens sont retirés. Un scan de contrôle relit ensuite l'archive pour vérifier qu'aucun secret n'a échappé aux motifs — et peut annuler la sauvegarde le cas échéant (`SECRET_SCAN_ACTION="abort"`).

Rien n'est perdu en silence : `_system-state/SECRETS-EXCLUS.txt` liste chaque élément retiré, avec la procédure pour le régénérer (`ssh-keygen -A`, `certbot certonly`, `passwd`, …).

À choisir si le FTP est mutualisé, partagé, ou hors de ton contrôle.

---

### Protection des identifiants

Le mot de passe FTP ne transite jamais par la ligne de commande : `lftp` le reçoit sur son entrée standard, `curl` via un `.netrc` temporaire en mode 600, effacé en sortie. Sans cette précaution, un simple `ps auxww` révélerait l'accès au dépôt de sauvegardes à n'importe quel utilisateur de la machine.

`backup.conf` doit rester en `chmod 600` — le script le signale sinon.

---

## Sens unique : le script n'écrit jamais sur le serveur

C'est une sauvegarde, pas une synchronisation. Rien de ce qui se trouve sur le FTP ne peut écraser un fichier local. Trois protections se superposent :

1. **Aucune commande `mirror`** n'est utilisée nulle part — la synchronisation distant → local n'existe pas dans ce script.
2. **`assert_upload_only()`** inspecte chaque commande `lftp` avant exécution et refuse tout `get`, `pget`, `mget` ou `mirror` en dehors du mode `--restore`, déclenché manuellement.
3. **`--restore` est confiné** : il télécharge dans `WORK_DIR/restore/`, valide le nom d'archive contre toute évasion de chemin, et **n'extrait jamais automatiquement**. Le script affiche les commandes `tar` à lancer — écraser `/etc` sur un système en marche reste une décision humaine.

---

## Rétention

**`BACKUP_MODE="snapshot"`** — une seule archive, écrasée à chaque exécution. Espace utilisé = taille d'une archive. Adapté aux gros volumes et à une configuration système qui évolue lentement.

**`BACKUP_MODE="history"`** — archives datées avec rotation grand-père / père / fils : les N derniers jours, les dimanches, les 1ers du mois, les 1ers janvier. Avec les valeurs par défaut, ~19 archives couvrent près de deux ans d'historique.

Le mode `history` protège d'un scénario que `snapshot` ne couvre pas : une corruption non détectée pendant plusieurs jours reste récupérable via une archive antérieure.

---

## Utilisation

```bash
./server-backup.sh --check
```
Vérifie les prérequis, la configuration, la connexion FTP, et affiche la taille de chaque chemin à sauvegarder.

```bash
./server-backup.sh --list
```
Liste les archives présentes sur le FTP avec leur catégorie de rétention.

```bash
./server-backup.sh --restore nom-archive.tar.zst
```
Télécharge une archive, vérifie son empreinte SHA-256, et affiche la marche à suivre. N'extrait rien.

---

## Restaurer un serveur

```bash
./server-backup.sh --restore monserveur_latest.tar.zst
```

Puis, dans l'ordre :

```bash
tar -xOf archive.tar.zst _system-state/00-INFO.txt
```

```bash
mkdir -p /tmp/restore && tar -xf archive.tar.zst -C /tmp/restore
```

`_system-state/` contient alors la liste des paquets à réinstaller, les services à réactiver, les règles de pare-feu et les versions de runtime à respecter — un site PHP 7.4 ne redémarre pas sur PHP 8.3.

Pour remettre un chemin en place en conservant droits et propriétaires :

```bash
tar -xf archive.tar.zst -C / --numeric-owner var/www
```

En mode expurgé, lire d'abord `_system-state/SECRETS-EXCLUS.txt`.

---

## Garanties vérifiées

Le script contrôle son propre travail avant de considérer une sauvegarde réussie :

- **Le FTP est testé avant l'archivage** — inutile de passer une heure à compresser si le transfert ne peut pas aboutir.
- **L'archive est relue de bout en bout**, et chaque chemin source doit y figurer. Une archive incomplète est refusée et **n'écrase pas** la précédente (code de sortie `3`).
- **Une empreinte SHA-256** accompagne chaque archive.
- **Un verrou** empêche deux exécutions simultanées (code `5`).
- **Un timeout global** évite qu'une sauvegarde bloquée tourne jusqu'au cron suivant.
- Les fichiers temporaires sont effacés en sortie, y compris après une erreur ou une interruption.

### Tests

```bash
./tests-run.sh
```

68 tests couvrant le sens unique du transfert, le contenu des archives, les deux modes de gestion des secrets, la détection des sauvegardes incomplètes, les deux stratégies de rétention, la robustesse (FTP injoignable, config invalide, exécution concurrente, interruption en plein travail), l'intégrité SHA-256 et la non-exposition des identifiants.

Le lanceur démarre un serveur FTP jetable sur `127.0.0.1:2121`, exécute la suite, puis nettoie. Aucun serveur distant n'est contacté.

### Codes de sortie

| Code | Signification |
|---|---|
| `0` | Succès |
| `1` | Erreur de configuration |
| `2` | Prérequis manquant |
| `3` | Échec ou incomplétude de l'archivage |
| `4` | Échec du transfert |
| `5` | Une sauvegarde est déjà en cours |
| `6` | Secret détecté dans une archive censée être expurgée |
| `7` | Échec de `before_backup.sh` |

---

## Notifications

```bash
NOTIFY_WEBHOOK="https://hooks.slack.com/services/..."
NOTIFY_ON_SUCCESS="no"
```

Compatible Slack, Mattermost et Discord (ajouter `/slack` à l'URL Discord). Par défaut, seuls les échecs sont notifiés — une sauvegarde silencieuse est une sauvegarde qui fonctionne.

---

## Portabilité

Testé sur GNU/Linux (cible principale) et macOS. Le script s'adapte à l'environnement : détection des options `tar` réellement supportées, repli `zstd` → `pigz` → `gzip`, repli `lftp` → `curl`, repli du verrou si `/var/lock` est absent, et compatibilité bash 3.2 comme bash 5.

## Licence

MIT.
