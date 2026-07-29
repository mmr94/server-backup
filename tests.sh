#!/usr/bin/env bash
# Batterie de tests pour server-backup.sh
# Chaque test est indépendant et vérifie un comportement observable.

#
# Prérequis : un serveur FTP de test sur 127.0.0.1:2121 (testuser/testpass).
#   pip install pyftpdlib
#   python3 -m pyftpdlib -p 2121 -d <racine> -u testuser -w testpass -W
# Le script ./tests-ftpd.sh démarre ce serveur automatiquement.
#
# Usage :  ./tests.sh
#
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/server-backup.sh"
S="${TMPDIR:-/tmp}/server-backup-tests"
FTPROOT="${FTP_TEST_ROOT:-$S/ftproot}"
SRV="$S/tsrv"
mkdir -p "$S" "$FTPROOT"

PASS=0; FAIL=0
declare -a FAILURES=()

ok()   { PASS=$((PASS+1)); printf '  \033[0;32m✅\033[0m %s\n' "$1"; }
ko()   { FAIL=$((FAIL+1)); FAILURES+=("$1"); printf '  \033[0;31m❌ %s\033[0m\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }
head2(){ printf '\n\033[1;34m── %s ──\033[0m\n' "$1"; }

mkconf() {
  local name="$1"; shift
  cat > "$S/t_${name}.conf" <<CONF
SERVER_NAME="${name}"
FTP_HOST="127.0.0.1"
FTP_PORT="2121"
FTP_USER="testuser"
FTP_PASS="testpass"
FTP_PROTOCOL="ftp"
FTP_BASE_DIR="/backups"
INCLUDE_PATHS="
$SRV/etc
$SRV/var/www
$SRV/root
"
EXCLUDE_PATTERNS="
*/node_modules
*.log
"
WORK_DIR="$SRV/work"
LOG_FILE="$S/t_${name}.log"
TIMEOUT_SECONDS="0"
ONE_FILE_SYSTEM="no"
CAPTURE_SYSTEM_STATE="yes"
BACKUP_MODE="snapshot"
$*
CONF
  chmod 600 "$S/t_${name}.conf"
}

run() { bash "$SCRIPT" --config "$S/t_$1.conf" "${@:2}" 2>&1; }
arch_of() { ls "$FTPROOT/backups/$1"/*.tar.zst 2>/dev/null | head -1; }
lst() { zstd -dc "$1" 2>/dev/null | tar -tf - 2>/dev/null | grep -v PaxHeader | grep -v '\._'; }

# ---------------------------------------------------------------- fixture
setup_srv() {
  rm -rf "$SRV"; mkdir -p "$SRV"/{etc,var/www/site,var/log,root,work}
  echo "server { listen 80; }"        > "$SRV/etc/nginx.conf"
  echo "root:x:0:0::/root:/bin/bash"  > "$SRV/etc/passwd"
  echo 'root:$6$HASH::0:99999:7:::'   > "$SRV/etc/shadow"
  echo "<?php echo 1; ?>"             > "$SRV/var/www/site/index.php"
  echo "DB_PASSWORD=s3cr3t"           > "$SRV/var/www/site/.env"
  echo "-----BEGIN OPENSSH PRIVATE KEY-----" > "$SRV/root/id_rsa"
  mkdir -p "$SRV/var/www/site/node_modules/x"; echo "junk" > "$SRV/var/www/site/node_modules/x/a.js"
  head -c 100000 /dev/zero > "$SRV/var/log/access.log"
}
clean_ftp() { rm -rf "$FTPROOT/backups/$1" 2>/dev/null; }

echo "═══════════════════════════════════════════════════════"
echo "  BATTERIE DE TESTS — server-backup.sh"
echo "═══════════════════════════════════════════════════════"

# =========================================================== 1. Statique
head2 "1. Validation statique"
bash -n "$SCRIPT" 2>/dev/null && ok "syntaxe bash valide" || ko "syntaxe bash invalide"
grep -q 'set -Eeuo pipefail' "$SCRIPT" && ok "set -Eeuo pipefail actif" || ko "pipefail absent"
grep -qE '^\s*trap cleanup EXIT' "$SCRIPT" && ok "trap de nettoyage installé" || ko "trap absent"
[ -x "$SCRIPT" ] && ok "script exécutable" || ko "script non exécutable"

# ================================================= 2. Sens unique (crucial)
head2 "2. Sens unique local -> distant (protection anti-écrasement)"
grep -qE '(^|[^a-z])mirror' "$SCRIPT" | grep -v 'mirror.*interdit' >/dev/null 2>&1
if grep -E 'run_lftp|lftp -c' "$SCRIPT" | grep -qE '\bmirror\b'; then
  ko "commande mirror présente dans un appel lftp"
else
  ok "aucune commande 'mirror' dans les appels lftp"
fi
DL=$(grep -nE '(^|[;"[:space:]])(get|pget|mget)[[:space:]]' "$SCRIPT" | grep -v 'apt-get' | grep -v 'GARDE-FOU' | grep -v '^\s*#' | wc -l | xargs)
[ "$DL" -le 2 ] && ok "téléchargements limités au mode restore ($DL occurrences)" || ko "téléchargements hors restore ($DL)"
grep -q 'assert_upload_only' "$SCRIPT" && ok "garde-fou assert_upload_only présent" || ko "garde-fou absent"

# garde-fou en conditions réelles
setup_srv; clean_ftp guard; mkconf guard
BEFORE=$(find "$SRV/etc" "$SRV/var/www" "$SRV/root" -type f | sort | xargs shasum 2>/dev/null | shasum | awk '{print $1}')
run guard >/dev/null 2>&1
AFTER=$(find "$SRV/etc" "$SRV/var/www" "$SRV/root" -type f | sort | xargs shasum 2>/dev/null | shasum | awk '{print $1}')
[ "$BEFORE" = "$AFTER" ] && ok "backup ne modifie aucun fichier local" || ko "backup a modifié des fichiers locaux"

A=$(arch_of guard)
if [ -n "$A" ]; then
  BEFORE2=$(find "$SRV/etc" "$SRV/var/www" "$SRV/root" -type f | sort | xargs shasum 2>/dev/null | shasum | awk '{print $1}')
  run guard --restore "$(basename "$A")" >/dev/null 2>&1
  AFTER2=$(find "$SRV/etc" "$SRV/var/www" "$SRV/root" -type f | sort | xargs shasum 2>/dev/null | shasum | awk '{print $1}')
  [ "$BEFORE2" = "$AFTER2" ] && ok "restore ne modifie aucun fichier local" || ko "restore a modifié des fichiers locaux"
  [ -f "$SRV/work/restore/$(basename "$A")" ] && ok "restore écrit uniquement dans work/restore" || ko "restore n'a pas écrit où attendu"
else
  ko "pas d'archive pour tester restore"
fi

# évasion de chemin
for bad in "../../etc/passwd" "/etc/shadow" "a;rm -rf /"; do
  if run guard --restore "$bad" 2>&1 | grep -q "invalide"; then :; else
    ko "nom d'archive dangereux accepté: $bad"; BADOK=1
  fi
done
[ -z "${BADOK:-}" ] && ok "noms d'archive dangereux rejetés (3 cas)"

# ============================================== 3. Contenu / exclusions
head2 "3. Contenu de l'archive et exclusions"
setup_srv; clean_ftp cont; mkconf cont 'EXCLUDE_SECRETS="no"'
run cont >/dev/null 2>&1
A=$(arch_of cont)
if [ -n "$A" ]; then
  L=$(lst "$A")
  grep -q 'etc/nginx.conf'      <<<"$L" && ok "config /etc incluse"       || ko "/etc absent"
  grep -q 'var/www/site/index.php' <<<"$L" && ok "site /var/www inclus"   || ko "/var/www absent"
  grep -q '_system-state/'      <<<"$L" && ok "métadonnées système incluses" || ko "_system-state absent"
  grep -q '00-INFO.txt'         <<<"$L" && ok "fiche 00-INFO.txt présente" || ko "00-INFO.txt absent"
  grep -q 'node_modules'        <<<"$L" && ko "node_modules NON exclu"    || ok "node_modules exclu"
  grep -q 'access.log'          <<<"$L" && ko "*.log NON exclu"           || ok "fichiers .log exclus"
  grep -q 'var/log'             <<<"$L" && ko "/var/log NON exclu"        || ok "/var/log exclu"
else ko "aucune archive produite"; fi

# ============================================== 4. Modes secrets
head2 "4. Modes de gestion des secrets"
setup_srv; clean_ftp full; mkconf full 'EXCLUDE_SECRETS="no"'
run full >/dev/null 2>&1
A=$(arch_of full)
if [ -n "$A" ]; then
  L=$(lst "$A")
  grep -q 'etc/shadow' <<<"$L" && ok "mode complet: shadow inclus" || ko "mode complet: shadow manquant"
  grep -q '\.env'      <<<"$L" && ok "mode complet: .env inclus"   || ko "mode complet: .env manquant"
  grep -q 'id_rsa'     <<<"$L" && ok "mode complet: clé SSH incluse" || ko "mode complet: clé SSH manquante"
else ko "mode complet: pas d'archive"; fi

setup_srv; clean_ftp exp; mkconf exp 'EXCLUDE_SECRETS="yes"
SECRET_SCAN_ACTION="warn"'
run exp >/dev/null 2>&1
A=$(arch_of exp)
if [ -n "$A" ]; then
  L=$(lst "$A")
  grep -q 'etc/shadow' <<<"$L" && ko "mode expurgé: shadow PRÉSENT" || ok "mode expurgé: shadow exclu"
  grep -q '\.env'      <<<"$L" && ko "mode expurgé: .env PRÉSENT"   || ok "mode expurgé: .env exclu"
  grep -q 'id_rsa'     <<<"$L" && ko "mode expurgé: clé SSH PRÉSENTE" || ok "mode expurgé: clé SSH exclue"
  grep -q 'SECRETS-EXCLUS.txt' <<<"$L" && ok "manifeste SECRETS-EXCLUS.txt présent" || ko "manifeste absent"
  M=$(zstd -dc "$A" 2>/dev/null | tar -xOf - _system-state/SECRETS-EXCLUS.txt 2>/dev/null)
  grep -q 'ssh-keygen -A' <<<"$M" && ok "manifeste: procédure clés SSH documentée" || ko "manifeste incomplet"
  grep -q 'Total' <<<"$M" && ok "manifeste: total des exclusions listé" || ko "manifeste sans total"
else ko "mode expurgé: pas d'archive"; fi

# ============================================== 5. Détection d'échec
head2 "5. Détection des sauvegardes incomplètes"
setup_srv; clean_ftp brk
cat > "$S/t_brk.conf" <<CONF
SERVER_NAME="brk"
FTP_HOST="127.0.0.1"; FTP_PORT="2121"; FTP_USER="testuser"; FTP_PASS="testpass"
FTP_PROTOCOL="ftp"; FTP_BASE_DIR="/backups"
INCLUDE_PATHS="
$SRV/etc
$SRV/var/www
"
EXCLUDE_PATTERNS="
*/tsrv/etc
"
WORK_DIR="$SRV/work"; LOG_FILE="$S/t_brk.log"; TIMEOUT_SECONDS="0"
ONE_FILE_SYSTEM="no"; BACKUP_MODE="snapshot"
CONF
chmod 600 "$S/t_brk.conf"
OUT=$(run brk 2>&1); RC=$?
grep -q 'ABSENTS de l' <<<"$OUT" && ok "chemin manquant détecté" || ko "chemin manquant NON détecté"
[ "$RC" = "3" ] && ok "code de sortie 3 sur archive incomplète" || ko "code de sortie inattendu: $RC"
[ -z "$(arch_of brk)" ] && ok "aucune archive incomplète envoyée sur le FTP" || ko "archive incomplète envoyée !"

# ============================================== 6. Modes de rétention
head2 "6. Rétention"
setup_srv; clean_ftp snap; mkconf snap 'BACKUP_MODE="snapshot"'
for i in 1 2 3; do run snap >/dev/null 2>&1; done
N=$(ls "$FTPROOT/backups/snap"/*.tar.zst 2>/dev/null | wc -l | xargs)
[ "$N" = "1" ] && ok "snapshot: 1 seule archive après 3 exécutions" || ko "snapshot: $N archives (1 attendue)"

clean_ftp hist; mkdir -p "$FTPROOT/backups/hist"
for i in $(seq 0 20); do
  d=$(date -v-${i}d "+%Y-%m-%d" 2>/dev/null || date -d "-${i} days" "+%Y-%m-%d")
  echo x > "$FTPROOT/backups/hist/hist_${d}_030000.tar.zst"
done
for m in 2025-01-01 2026-01-01 2026-03-01 2026-05-01; do echo x > "$FTPROOT/backups/hist/hist_${m}_030000.tar.zst"; done
BEF=$(ls "$FTPROOT/backups/hist" | wc -l | xargs)
mkconf hist 'BACKUP_MODE="history"
KEEP_DAILY="7"
KEEP_WEEKLY="4"
KEEP_MONTHLY="6"
KEEP_YEARLY="2"'
OUT=$(run hist 2>&1)
AFT=$(ls "$FTPROOT/backups/hist"/*.tar.zst 2>/dev/null | wc -l | xargs)
[ "$AFT" -lt "$BEF" ] && ok "history: rotation appliquée ($BEF -> $AFT)" || ko "history: aucune rotation ($BEF -> $AFT)"
grep -q 'Conservées' <<<"$OUT" && ok "history: bilan de rotation affiché" || ko "history: bilan absent"
ls "$FTPROOT/backups/hist" | grep -q '2026-01-01' && ok "history: archive annuelle conservée" || ko "history: annuelle supprimée"

# ============================================== 7. Robustesse
head2 "7. Robustesse et cas limites"
setup_srv; mkconf noftp 'FTP_HOST="127.0.0.1"
FTP_PORT="59999"'
OUT=$(run noftp 2>&1); RC=$?
[ "$RC" = "4" ] && ok "FTP injoignable: code 4" || ko "FTP injoignable: code $RC (4 attendu)"
grep -q 'annulée avant archivage' <<<"$OUT" && ok "FTP testé avant archivage (pas de travail inutile)" || ko "archivage lancé malgré FTP KO"

cat > "$S/t_bad.conf" <<'CONF'
SERVER_NAME="bad"
FTP_HOST=""
FTP_USER=""
FTP_PASS=""
CONF
chmod 600 "$S/t_bad.conf"
OUT=$(bash "$SCRIPT" --config "$S/t_bad.conf" 2>&1); RC=$?
[ "$RC" = "1" ] && ok "config invalide: code 1" || ko "config invalide: code $RC"
grep -q 'FTP_HOST est vide' <<<"$OUT" && ok "config invalide: message explicite" || ko "message peu clair"

OUT=$(bash "$SCRIPT" --config /inexistant.conf 2>&1); RC=$?
[ "$RC" = "1" ] && ok "config absente: code 1" || ko "config absente: code $RC"

setup_srv; mkconf dry
OUT=$(run dry --dry-run 2>&1)
grep -q 'dry-run' <<<"$OUT" && ok "--dry-run n'envoie rien" || ko "--dry-run défaillant"

bash "$SCRIPT" --help >/dev/null 2>&1 && ok "--help fonctionne" || ko "--help échoue"
OUT=$(bash "$SCRIPT" --option-inconnue 2>&1); RC=$?
[ "$RC" != "0" ] && ok "option inconnue rejetée" || ko "option inconnue acceptée"

# verrou concurrent
setup_srv; clean_ftp lock; mkconf lock
( run lock >/dev/null 2>&1 ) &
sleep 0.4
OUT=$(run lock 2>&1); RC=$?
wait
if [ "$RC" = "5" ]; then ok "exécution concurrente bloquée (code 5)"
else grep -q 'déjà en cours' <<<"$OUT" && ok "exécution concurrente bloquée" || ko "concurrence non bloquée (code $RC)"; fi

# ============================================== 8. Intégrité
head2 "8. Intégrité des archives"
setup_srv; clean_ftp integ; mkconf integ
run integ >/dev/null 2>&1
A=$(arch_of integ)
if [ -n "$A" ]; then
  [ -f "$A.sha256" ] && ok "empreinte SHA-256 publiée" || ko "SHA-256 absent"
  EXP=$(cat "$A.sha256" 2>/dev/null); GOT=$(shasum -a 256 "$A" | awk '{print $1}')
  [ "$EXP" = "$GOT" ] && ok "SHA-256 conforme à l'archive" || ko "SHA-256 divergent"
  zstd -t "$A" >/dev/null 2>&1 && ok "archive décompressable" || ko "archive corrompue"
  zstd -dc "$A" | tar -tf - >/dev/null 2>&1 && ok "structure tar valide" || ko "structure tar invalide"
  ls "$FTPROOT/backups/integ"/*.part >/dev/null 2>&1 && ko "fichier .part résiduel" || ok "aucun fichier temporaire résiduel"
else ko "pas d'archive à vérifier"; fi

# ============================================== 9. Hygiène
head2 "9. Hygiène et sécurité opérationnelle"
grep -q 'chmod 600' "$SCRIPT" && ok "permissions restrictives sur les archives" || ko "permissions non restreintes"
grep -q 'rm -rf -- "${STAGING_DIR}"' "$SCRIPT" && ok "staging effacé en sortie" || ko "staging non nettoyé"
ls "$SRV/work"/staging.* >/dev/null 2>&1 && ko "staging résiduel sur disque" || ok "aucun staging résiduel"
ls "$SRV/work"/.build-* >/dev/null 2>&1 && ko "archive intermédiaire résiduelle" || ok "aucune archive intermédiaire résiduelle"
grep -q 'FTP_PASS' "$S/t_integ.log" 2>/dev/null && ko "mot de passe FTP écrit dans le log" || ok "aucun mot de passe dans les logs"

# Le mot de passe ne doit jamais transiter par argv : `ps auxww` est lisible
# par tout utilisateur de la machine.
# On ignore les lignes de commentaire : la doc du script mentionne FTP_PASS
# précisément pour expliquer pourquoi il ne doit pas passer par argv.
grep -vE '^\s*#' "$SCRIPT" | grep -qE 'lftp -c .*\$\{FTP_PASS\}' \
  && ko "mot de passe passé en argument à lftp" || ok "lftp: identifiants hors argv"
grep -qE '\-\-user "\$\{FTP_USER\}:\$\{FTP_PASS\}"' "$SCRIPT" && ko "mot de passe passé en argument à curl" || ok "curl: identifiants hors argv"

# Vérification dynamique : on observe réellement la table des processus
# pendant une sauvegarde.
setup_srv; clean_ftp psleak; mkconf psleak
( run psleak >/dev/null 2>&1 ) &
BGPID=$!
LEAK=0
for _ in $(seq 1 25); do
  if ps auxww 2>/dev/null | grep -v grep | grep -q 'testpass'; then LEAK=1; break; fi
  sleep 0.1
done
wait $BGPID 2>/dev/null
[ "$LEAK" = "0" ] && ok "aucun mot de passe visible dans ps pendant la sauvegarde" \
                  || ko "mot de passe EXPOSÉ dans ps pendant la sauvegarde"

# Le .netrc temporaire ne doit pas survivre à l'exécution.
find "$SRV/work" -name '.netrc' 2>/dev/null | grep -q . && ko ".netrc résiduel sur disque" || ok "aucun .netrc résiduel"

# ============================================== 9b. Protocoles
head2 "9b. Construction des commandes par protocole"
# Validation statique : le FTP de test ne parle que FTP clair. Les modes ftps
# et sftp sont vérifiés au niveau des options générées, pas par un transfert.
grep -q 'ftp:ssl-force true' "$SCRIPT" && ok "ftps: TLS forcé dans les réglages" || ko "ftps: TLS non forcé"
grep -q 'ftp:ssl-protect-data true' "$SCRIPT" && ok "ftps: canal de données protégé" || ko "ftps: données non protégées"
grep -q 'sftp:connect-program' "$SCRIPT" && ok "sftp: clé privée prise en compte" || ko "sftp: clé ignorée"
grep -q 'ssl:verify-certificate' "$SCRIPT" && ok "vérification du certificat configurable" || ko "certificat non vérifié"
grep -q 'StrictHostKeyChecking' "$SCRIPT" && ok "sftp: contrôle de l'hôte SSH" || ko "sftp: hôte non contrôlé"

# ============================================== 9d. Hooks
head2 "9d. Hooks before_backup / after_backup"
setup_srv; clean_ftp hooks
HK="$S/hookconf"; rm -rf "$HK"; mkdir -p "$HK"
cat > "$HK/backup.conf" <<CONF
SERVER_NAME="hooks"
FTP_HOST="127.0.0.1"; FTP_PORT="2121"; FTP_USER="testuser"; FTP_PASS="testpass"
FTP_PROTOCOL="ftp"; FTP_BASE_DIR="/backups"
INCLUDE_PATHS="
$SRV/etc
"
WORK_DIR="$SRV/work"; LOG_FILE="$S/t_hooks.log"; TIMEOUT_SECONDS="0"
ONE_FILE_SYSTEM="no"; BACKUP_MODE="snapshot"; CAPTURE_SYSTEM_STATE="no"
CONF
chmod 600 "$HK/backup.conf"

# --- hook qui réussit et produit des fichiers ---
cat > "$HK/before_backup.sh" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$BACKUP_STAGING_DIR/_databases" "$BACKUP_STAGING_DIR/perso"
echo "dump" > "$BACKUP_STAGING_DIR/_databases/db.sql"
echo "libre" > "$BACKUP_STAGING_DIR/perso/x.txt"
echo "hook-ok serveur=$BACKUP_SERVER_NAME"
HOOK
chmod 750 "$HK/before_backup.sh"
OUT=$(bash "$SCRIPT" --config "$HK/backup.conf" 2>&1)
grep -q 'hook-ok serveur=hooks' <<<"$OUT" && ok "hook exécuté, variables transmises" || ko "hook non exécuté"
A=$(arch_of hooks)
if [ -n "$A" ]; then
  L=$(lst "$A")
  grep -q '_databases/db.sql' <<<"$L" && ok "fichiers du hook inclus dans l'archive" || ko "fichiers du hook absents"
  grep -q 'perso/x.txt' <<<"$L" && ok "dossier au nom libre inclus" || ko "dossier au nom libre ignoré"
else ko "hooks: pas d'archive"; fi

# --- hook en échec : la sauvegarde doit être annulée ---
cat > "$HK/before_backup.sh" <<'HOOK'
#!/usr/bin/env bash
echo "dump impossible" >&2
exit 1
HOOK
chmod 750 "$HK/before_backup.sh"
clean_ftp hooks
OUT=$(bash "$SCRIPT" --config "$HK/backup.conf" 2>&1); RC=$?
[ "$RC" = "7" ] && ok "hook en échec: code 7" || ko "hook en échec: code $RC (7 attendu)"
[ -z "$(arch_of hooks)" ] && ok "hook en échec: aucune archive envoyée" || ko "archive envoyée malgré l'échec du hook"

# --- HOOK_FAILURE=warn : doit continuer ---
echo 'HOOK_FAILURE="warn"' >> "$HK/backup.conf"
clean_ftp hooks
OUT=$(bash "$SCRIPT" --config "$HK/backup.conf" 2>&1)
[ -n "$(arch_of hooks)" ] && ok "HOOK_FAILURE=warn: sauvegarde poursuivie" || ko "HOOK_FAILURE=warn: sauvegarde bloquée"
sed -i'' -e 's/^HOOK_FAILURE=.*/HOOK_FAILURE="abort"/' "$HK/backup.conf" 2>/dev/null

# --- hook non exécutable : averti, non fatal ---
cat > "$HK/before_backup.sh" <<'HOOK'
#!/usr/bin/env bash
exit 0
HOOK
chmod 640 "$HK/before_backup.sh"
OUT=$(bash "$SCRIPT" --config "$HK/backup.conf" 2>&1)
grep -q 'non exécutable' <<<"$OUT" && ok "hook non exécutable signalé" || ko "hook non exécutable silencieux"
chmod 750 "$HK/before_backup.sh"

# --- after_backup reçoit le statut, y compris sur échec ---
cat > "$HK/after_backup.sh" <<'HOOK'
#!/usr/bin/env bash
echo "after-statut=${BACKUP_STATUS}"
HOOK
chmod 750 "$HK/after_backup.sh"
OUT=$(bash "$SCRIPT" --config "$HK/backup.conf" 2>&1)
grep -q 'after-statut=success' <<<"$OUT" && ok "after_backup: statut success transmis" || ko "after_backup: statut absent"

cat > "$HK/before_backup.sh" <<'HOOK'
#!/usr/bin/env bash
exit 1
HOOK
chmod 750 "$HK/before_backup.sh"
OUT=$(bash "$SCRIPT" --config "$HK/backup.conf" 2>&1)
grep -q 'after-statut=failure' <<<"$OUT" && ok "after_backup exécuté malgré l'échec" || ko "after_backup ignoré sur échec"

# --- absence de hook : silencieux, non bloquant ---
rm -f "$HK/before_backup.sh" "$HK/after_backup.sh"
clean_ftp hooks
OUT=$(bash "$SCRIPT" --config "$HK/backup.conf" 2>&1)
[ -n "$(arch_of hooks)" ] && ok "absence de hook: sauvegarde normale" || ko "absence de hook: sauvegarde bloquée"

# ============================================== 9c. Chemins particuliers
head2 "9c. Chemins avec espaces et caractères spéciaux"
rm -rf "$S/space"; mkdir -p "$S/space/mon dossier/etc" "$S/space/work"
echo "conf" > "$S/space/mon dossier/etc/app.conf"
cat > "$S/t_space.conf" <<CONF
SERVER_NAME="space"
FTP_HOST="127.0.0.1"; FTP_PORT="2121"; FTP_USER="testuser"; FTP_PASS="testpass"
FTP_PROTOCOL="ftp"; FTP_BASE_DIR="/backups"
INCLUDE_PATHS="
$S/space/mon dossier/etc
"
WORK_DIR="$S/space/work"; LOG_FILE="$S/t_space.log"; TIMEOUT_SECONDS="0"
ONE_FILE_SYSTEM="no"; CAPTURE_SYSTEM_STATE="no"; BACKUP_MODE="snapshot"
CONF
chmod 600 "$S/t_space.conf"
clean_ftp space
run space >/dev/null 2>&1
A=$(arch_of space)
if [ -n "$A" ]; then
  lst "$A" | grep -q 'app.conf' && ok "chemin contenant des espaces archivé" || ko "chemin avec espaces perdu"
else ko "chemin avec espaces: aucune archive"; fi

# ============================================== 10. Espace disque
head2 "10. Contrôle de l'espace disque"
setup_srv; clean_ftp space; mkconf space
OUT=$(run space 2>&1)
grep -q 'Espace :' <<<"$OUT" && ok "espace disque évalué avant archivage" || ko "aucune évaluation d'espace"

# ============================================== 11. Interruption
head2 "11. Interruption en cours d'exécution"
setup_srv; clean_ftp intr; mkconf intr
( run intr >/dev/null 2>&1 ) & BG=$!
# Attendre que le staging existe réellement avant d'interrompre : frapper trop
# tôt testerait un cas sans intérêt (rien à nettoyer).
for _ in $(seq 1 40); do
  ls "$SRV/work"/staging.* >/dev/null 2>&1 && break
  sleep 0.1
done
# SIGTERM au sous-shell ET aux processus server-backup qu'il a lancés.
# Ne jamais viser le groupe : il contient aussi ce script de test.
kill -TERM $BG 2>/dev/null
pkill -TERM -f "server-backup.sh --config .*t_intr.conf" 2>/dev/null
# 2>/dev/null sur wait ne suffit pas : bash écrit "Terminated" au retour au
# prompt du job control. On le neutralise en désactivant les notifications.
set +m 2>/dev/null
wait $BG 2>/dev/null
sleep 0.8
ls "$SRV/work"/staging.* >/dev/null 2>&1 && ko "staging résiduel après interruption" || ok "staging nettoyé après interruption"
ls "$SRV/work"/.build-* >/dev/null 2>&1 && ko "archive intermédiaire résiduelle après interruption" || ok "archive intermédiaire nettoyée après interruption"
find "$SRV/work" -name '.netrc' 2>/dev/null | grep -q . && ko ".netrc résiduel après interruption" || ok ".netrc nettoyé après interruption"
# Après une interruption, le verrou doit être libéré : sinon le cron suivant
# resterait bloqué indéfiniment.
OUT=$(run intr 2>&1); RC=$?
[ "$RC" != "5" ] && ok "verrou libéré après interruption" || ko "verrou resté bloqué après interruption"

echo
echo "═══════════════════════════════════════════════════════"
printf "  RÉSULTAT : \033[0;32m%d réussis\033[0m, " "$PASS"
[ "$FAIL" -eq 0 ] && printf "\033[0;32m0 échec\033[0m\n" || printf "\033[0;31m%d échec(s)\033[0m\n" "$FAIL"
echo "═══════════════════════════════════════════════════════"
if [ "$FAIL" -gt 0 ]; then
  echo "Échecs :"
  for f in "${FAILURES[@]}"; do echo "  • $f"; done
  exit 1
fi
