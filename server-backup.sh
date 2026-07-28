#!/usr/bin/env bash
# ============================================================================
#  server-backup.sh — sauvegarde complète d'un serveur Linux vers un FTP
# ----------------------------------------------------------------------------
#  Objectif : après un crash total, pouvoir repartir d'un serveur nu et
#  restaurer la configuration, les sites, les crontabs, les unités systemd et
#  les données applicatives — sans avoir à se souvenir de quoi que ce soit.
#
#  Principe : archive tar -> compression -> upload FTP/FTPS/SFTP -> rotation
#  grand-père/père/fils sur le distant.
#
#  Le FTP n'ayant pas de protocole de synchronisation delta, on n'imite pas
#  rsync fichier-par-fichier (lent, fragile, et sans cohérence transactionnelle).
#  On envoie une archive datée par exécution, ce qui donne en prime un
#  historique restaurable à une date précise.
#
#  ⚠️ MODÈLE DE SÉCURITÉ — À COMPRENDRE AVANT D'UTILISER
#  L'archive n'est PAS chiffrée : elle se restaure avec un simple `tar -xf`,
#  sans passphrase à retrouver le jour du crash. Deux modes, via EXCLUDE_SECRETS :
#
#   - "no" (défaut) : archive COMPLÈTE. Contient /etc/shadow, les clés privées
#     SSH/TLS et les .env, donc une restauration intégrale sans rien régénérer.
#     Le périmètre de confiance devient le FTP : quiconque lit une archive
#     obtient un accès root au serveur. À réserver à un espace de sauvegarde
#     maîtrisé, dont les identifiants ne sont connus que de root.
#
#   - "yes" : archive EXPURGÉE. Les secrets sont retirés, un scan de contrôle
#     vérifie qu'il n'en reste pas, et _system-state/SECRETS-EXCLUS.txt liste
#     ce qui manque avec la procédure pour le régénérer. À utiliser si le FTP
#     est mutualisé, partagé, ou hors de ton contrôle.
#
#  Dans les deux cas, FTP_PROTOCOL="ftps" ou "sftp" est recommandé : en FTP
#  clair, l'archive et le mot de passe circulent en clair sur le réseau.
#
#  Usage :
#    ./server-backup.sh                      # sauvegarde complète
#    ./server-backup.sh --config /chemin.conf
#    ./server-backup.sh --dry-run            # simule, n'upload rien
#    ./server-backup.sh --check              # vérifie prérequis + connexion FTP
#    ./server-backup.sh --list               # liste les backups sur le FTP
#    ./server-backup.sh --restore <archive>  # télécharge une archive
#    ./server-backup.sh --install-cron       # installe la tâche cron quotidienne
#
#  Codes de sortie : 0 OK · 1 erreur de config · 2 prérequis manquant
#                    3 échec archivage · 4 échec upload · 5 déjà en cours
#                    6 secret détecté dans l'archive
# ============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_VERSION="1.0.0"
# Non readonly : acquire_lock() se replie sur WORK_DIR si /var/lock est absent.
LOCK_FILE="/var/lock/server-backup.lock"

# Emplacements de configuration, du plus prioritaire au moins prioritaire.
CONFIG_CANDIDATES=(
  "/etc/server-backup/backup.conf"
  "${SCRIPT_DIR}/backup.conf"
)

# ----------------------------------------------------------------------------
# Valeurs par défaut — toute variable non définie dans backup.conf retombe ici.
# ----------------------------------------------------------------------------
SERVER_NAME="$(hostname -s 2>/dev/null || echo server)"
FTP_HOST="" ; FTP_PORT="21" ; FTP_USER="" ; FTP_PASS=""
FTP_BASE_DIR="/backups" ; FTP_PROTOCOL="ftps" ; FTP_VERIFY_CERT="yes" ; SFTP_KEY=""
INCLUDE_PATHS="/etc
/root
/home
/var/www"
EXCLUDE_PATTERNS="/var/log
/var/cache
/proc
/sys
/dev
/run
/tmp"
MAX_FILE_SIZE_MB="512"
ONE_FILE_SYSTEM="yes"
EXCLUDE_SECRETS="no"
EXTRA_SECRET_PATTERNS=""
SECRET_SCAN_ACTION="warn"
CAPTURE_SYSTEM_STATE="yes"
DUMP_MYSQL="no" ; MYSQL_DUMP_OPTS="--all-databases --single-transaction --quick --routines --triggers --events"
MYSQL_USER="" ; MYSQL_PASS=""
DUMP_POSTGRES="no" ; POSTGRES_SUPERUSER="postgres"
DUMP_MONGO="no" ; MONGO_URI="mongodb://127.0.0.1:27017"
DUMP_SKIP_SENSITIVE_TABLES="yes"
BACKUP_MODE="snapshot"
KEEP_DAILY="7" ; KEEP_WEEKLY="4" ; KEEP_MONTHLY="6" ; KEEP_YEARLY="2" ; KEEP_LOCAL="1"
WORK_DIR="/var/backups/server-backup"
LOG_FILE="/var/log/server-backup.log"
COMPRESSION_LEVEL="10"
BANDWIDTH_LIMIT_KB="0"
TIMEOUT_SECONDS="10800"
NOTIFY_WEBHOOK="" ; NOTIFY_ON_SUCCESS="no" ; NOTIFY_EMAIL=""

# ----------------------------------------------------------------------------
# Motifs de secrets exclus par défaut.
# Règle de tri : est un secret ce qui donne un ACCÈS (clé privée, mot de passe,
# token). N'est pas un secret ce qui est public ou régénérable sans risque
# (clés publiques, authorized_keys, certificats).
# ----------------------------------------------------------------------------
readonly -a DEFAULT_SECRET_PATTERNS=(
  # --- Comptes système : hashs de mots de passe ---
  "etc/shadow"
  "etc/shadow-"
  "etc/gshadow"
  "etc/gshadow-"
  "etc/security/opasswd"

  # --- Clés privées SSH (hôte et utilisateurs) ---
  "etc/ssh/ssh_host_*_key"
  "*/.ssh/id_rsa"
  "*/.ssh/id_dsa"
  "*/.ssh/id_ecdsa"
  "*/.ssh/id_ed25519"
  "*/.ssh/identity"
  "*/.ssh/*_key"
  # Une clé privée déposée hors de ~/.ssh (sauvegarde manuelle, script de
  # déploiement, home de service) reste une clé privée.
  "*/id_rsa"
  "*/id_dsa"
  "*/id_ecdsa"
  "*/id_ed25519"

  # --- Clés privées TLS / SSL ---
  "etc/ssl/private"
  "etc/pki/tls/private"
  "etc/letsencrypt/archive"
  "etc/letsencrypt/live"
  "etc/letsencrypt/keys"
  "*.key"
  "*.pem"
  "*.p12"
  "*.pfx"
  "*.jks"
  "*.keystore"

  # --- Variables d'environnement applicatives (tokens, DSN, clés API) ---
  "*/.env"
  "*/.env.*"
  "*.env.local"
  "*.env.production"

  # --- Identifiants stockés par les outils ---
  "*/.my.cnf"
  "*/.pgpass"
  "*/.netrc"
  "*/_netrc"
  "*/.npmrc"
  "*/.pypirc"
  "*/.docker/config.json"
  "*/.aws/credentials"
  "*/.config/gcloud/credentials.db"
  "*/.config/gh/hosts.yml"
  "*/.git-credentials"
  "*/.rclone.conf"
  "*/.s3cfg"

  # --- Trousseaux et coffres ---
  "*/.gnupg"
  "*/.password-store"
  "etc/wireguard/*.conf"
  "etc/openvpn/*.key"

  # --- Configuration de ce script (contient FTP_PASS) ---
  "etc/server-backup/backup.conf"
)

# Motifs recherchés dans le CONTENU des fichiers lors du scan de contrôle.
readonly -a SECRET_CONTENT_PATTERNS=(
  "BEGIN RSA PRIVATE KEY"
  "BEGIN DSA PRIVATE KEY"
  "BEGIN EC PRIVATE KEY"
  "BEGIN OPENSSH PRIVATE KEY"
  "BEGIN PGP PRIVATE KEY"
  "BEGIN PRIVATE KEY"
)

# ----------------------------------------------------------------------------
# État d'exécution
# ----------------------------------------------------------------------------
DRY_RUN="no"
MODE="backup"
RESTORE_TARGET=""
CONFIG_FILE=""
STAGING_DIR=""
ARCHIVE_PATH=""
LOCK_STYLE=""
LOCK_DIR=""
LOG_WRITABLE="unknown"
START_EPOCH="$(date +%s)"
declare -a WARNINGS=()

# ============================================================================
#  Journalisation
# ============================================================================
if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m' ; C_GRN=$'\033[0;32m' ; C_YEL=$'\033[0;33m'
  C_BLU=$'\033[0;34m' ; C_DIM=$'\033[2m'    ; C_OFF=$'\033[0m'
else
  C_RED="" ; C_GRN="" ; C_YEL="" ; C_BLU="" ; C_DIM="" ; C_OFF=""
fi

_log() {
  local level="$1" ; shift
  local color="$1" ; shift
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') [${level}] $*"
  printf '%s%s%s\n' "${color}" "${line}" "${C_OFF}" >&2
  # Le log fichier ne doit jamais faire échouer la sauvegarde, ni polluer la
  # sortie. Le `2>/dev/null` d'une redirection ne suffit pas : le message
  # "Permission denied" est émis par le shell au moment de l'ouverture. On
  # teste donc l'inscriptibilité une seule fois, puis on s'y tient.
  if [[ -n "${LOG_FILE}" && "${LOG_WRITABLE:-unknown}" != "no" ]]; then
    if [[ "${LOG_WRITABLE:-unknown}" == "unknown" ]]; then
      if ( : >>"${LOG_FILE}" ) 2>/dev/null; then LOG_WRITABLE="yes"; else LOG_WRITABLE="no"; fi
    fi
    if [[ "${LOG_WRITABLE}" == "yes" ]]; then
      { printf '%s\n' "${line}" >>"${LOG_FILE}"; } 2>/dev/null
    fi
  fi
  # Toujours réussir : _log est appelé partout, y compris depuis die(), et son
  # code de retour ne doit jamais déclencher le trap ERR ni masquer une erreur.
  return 0
}
log_info()  { _log "INFO " "${C_BLU}" "$@"; }
log_ok()    { _log "OK   " "${C_GRN}" "$@"; }
log_warn()  { _log "WARN " "${C_YEL}" "$@"; WARNINGS+=("$*"); }
log_error() { _log "ERROR" "${C_RED}" "$@"; }
log_step()  { _log "STEP " "${C_DIM}" "── $* ──"; }

die() {
  local code="${2:-1}"
  log_error "$1"
  notify "failure" "$1"
  exit "${code}"
}

# ============================================================================
#  Nettoyage — appelé quoi qu'il arrive (succès, erreur, Ctrl-C)
# ============================================================================
cleanup() {
  local exit_code=$?
  # Le trap ERR ne doit pas se déclencher pendant le nettoyage : sinon une
  # commande de ménage qui échoue ajoute des messages d'erreur trompeurs
  # par-dessus la vraie cause de la sortie.
  set +e
  trap - ERR
  # Le .netrc contient le mot de passe FTP : il doit disparaître même quand il
  # a été créé hors du staging (modes --list, --check, --restore).
  [[ -n "${NETRC_FILE:-}" && -f "${NETRC_FILE}" ]] && rm -f -- "${NETRC_FILE}"
  if [[ -n "${STAGING_DIR}" && -d "${STAGING_DIR}" ]]; then
    rm -rf -- "${STAGING_DIR}"
  fi
  # Libère le verrou selon le mécanisme réellement utilisé. Sans ça, un verrou
  # par répertoire survivrait à la sortie et bloquerait le cron suivant.
  case "${LOCK_STYLE:-}" in
    flock)  flock -u 9 2>/dev/null ; exec 9>&- 2>/dev/null ;;
    mkdir)  [[ -n "${LOCK_DIR:-}" ]] && rm -rf -- "${LOCK_DIR}" 2>/dev/null ;;
  esac
  return "${exit_code}"
}
trap cleanup EXIT
trap 'die "Interrompu par un signal (SIGINT/SIGTERM)." 1' INT TERM
trap 'log_error "Échec ligne ${LINENO} : commande \"${BASH_COMMAND}\""' ERR

# ============================================================================
#  Configuration
# ============================================================================
load_config() {
  if [[ -z "${CONFIG_FILE}" ]]; then
    for candidate in "${CONFIG_CANDIDATES[@]}"; do
      if [[ -r "${candidate}" ]]; then CONFIG_FILE="${candidate}"; break; fi
    done
  fi

  if [[ -z "${CONFIG_FILE}" ]]; then
    log_error "Aucun fichier de configuration trouvé."
    log_error "Cherché dans : ${CONFIG_CANDIDATES[*]}"
    log_error "Copie backup.conf.example vers /etc/server-backup/backup.conf puis édite-le."
    exit 1
  fi
  [[ -r "${CONFIG_FILE}" ]] || die "Configuration illisible : ${CONFIG_FILE}" 1

  # Le fichier contient le mot de passe FTP : il ne doit pas être lisible par tous.
  local perms
  perms="$(stat -c '%a' "${CONFIG_FILE}" 2>/dev/null || stat -f '%Lp' "${CONFIG_FILE}" 2>/dev/null || echo '600')"
  if [[ "${perms}" != "600" && "${perms}" != "400" ]]; then
    log_warn "${CONFIG_FILE} est en mode ${perms} et contient des identifiants. Corrige avec : chmod 600 ${CONFIG_FILE}"
  fi

  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
  # LOG_FILE vient peut-être de changer : le test d'inscriptibilité doit être
  # refait sur le nouveau chemin.
  LOG_WRITABLE="unknown"
  log_info "Configuration chargée depuis ${CONFIG_FILE}"
}

validate_config() {
  local errors=0
  [[ -n "${FTP_HOST}" ]] || { log_error "FTP_HOST est vide."; ((errors++)); }
  [[ -n "${FTP_USER}" ]] || { log_error "FTP_USER est vide."; ((errors++)); }

  if [[ "${FTP_PROTOCOL}" == "sftp" && -n "${SFTP_KEY}" ]]; then
    [[ -r "${SFTP_KEY}" ]] || { log_error "Clé SSH introuvable : ${SFTP_KEY}"; ((errors++)); }
  elif [[ -z "${FTP_PASS}" ]]; then
    log_error "FTP_PASS est vide (et aucune clé SFTP fournie)."; ((errors++))
  fi

  case "${FTP_PROTOCOL}" in
    ftp|ftps|ftps-implicit|sftp) ;;
    *) log_error "FTP_PROTOCOL invalide : '${FTP_PROTOCOL}' (attendu : ftp|ftps|ftps-implicit|sftp)"; ((errors++)) ;;
  esac

  # L'archive n'étant pas chiffrée, le transport en clair est le second maillon
  # faible : n'importe qui sur le réseau peut lire l'archive au passage.
  [[ "${FTP_PROTOCOL}" == "ftp" ]] && \
    log_warn "FTP_PROTOCOL=ftp : l'archive n'est ni chiffrée ni protégée en transit. Préfère ftps ou sftp."

  # Archive non chiffrée : le périmètre de confiance est le FTP lui-même.
  # En mode complet (EXCLUDE_SECRETS=no), l'archive contient /etc/shadow et les
  # clés privées. C'est ce qui permet une restauration intégrale sans rien
  # régénérer — au prix d'une équivalence stricte : accès au FTP = accès root.
  if [[ "${EXCLUDE_SECRETS}" != "yes" ]]; then
    log_info "Mode archive complète : secrets inclus (restauration intégrale possible)."
    log_info "Rappel : l'accès au FTP équivaut à un accès root sur ce serveur."
  else
    log_info "Mode archive expurgée : secrets exclus, voir SECRETS-EXCLUS.txt à la restauration."
  fi

  case "${SECRET_SCAN_ACTION}" in
    abort|warn|off) ;;
    *) log_error "SECRET_SCAN_ACTION invalide : '${SECRET_SCAN_ACTION}' (attendu : abort|warn|off)"; ((errors++)) ;;
  esac

  case "${BACKUP_MODE}" in
    snapshot)
      # Sans historique, une corruption non détectée avant la prochaine
      # exécution écrase la dernière archive saine. L'utilisateur doit le
      # savoir, même si c'est un choix légitime pour de gros volumes.
      log_info "Mode snapshot : une archive unique, écrasée à chaque exécution (pas d'historique)."
      ;;
    history)
      local total=$(( KEEP_DAILY + KEEP_WEEKLY + KEEP_MONTHLY + KEEP_YEARLY ))
      log_info "Mode history : jusqu'à ${total} archives conservées sur le FTP."
      ;;
    *) log_error "BACKUP_MODE invalide : '${BACKUP_MODE}' (attendu : snapshot|history)"; ((errors++)) ;;
  esac

  # Une valeur non numérique ici ferait planter les calculs de rotation.
  local var
  for var in KEEP_DAILY KEEP_WEEKLY KEEP_MONTHLY KEEP_YEARLY KEEP_LOCAL \
             MAX_FILE_SIZE_MB COMPRESSION_LEVEL BANDWIDTH_LIMIT_KB TIMEOUT_SECONDS; do
    if ! [[ "${!var}" =~ ^[0-9]+$ ]]; then
      log_error "${var} doit être un entier (valeur : '${!var}')"; ((errors++))
    fi
  done

  (( errors == 0 )) || die "${errors} erreur(s) de configuration. Corrige ${CONFIG_FILE}." 1
  log_ok "Configuration valide."
}

# ============================================================================
#  Prérequis
# ============================================================================
have() { command -v "$1" >/dev/null 2>&1; }

# mapfile est apparu avec bash 4. La cible normale de ce script (Linux serveur)
# en dispose, mais bash 3.2 est encore livré par défaut sur macOS et sur
# quelques systèmes anciens. Ce repli garde le script utilisable partout, avec
# la même sémantique : une ligne d'entrée = un élément du tableau.
if ! declare -F mapfile >/dev/null 2>&1 && ! type -t mapfile >/dev/null 2>&1; then
  mapfile() {
    local flag_t=0 array_name line
    while (( $# > 0 )); do
      case "$1" in
        -t) flag_t=1 ; shift ;;
        *)  array_name="$1" ; shift ;;
      esac
    done
    eval "${array_name}=()"
    while IFS= read -r line || [[ -n "${line}" ]]; do
      (( flag_t )) && line="${line%$'\n'}"
      eval "${array_name}+=(\"\${line}\")"
    done
  }
fi

check_prerequisites() {
  local missing=0

  have tar || { log_error "'tar' est requis."; ((missing++)); }

  # zstd est bien plus rapide que gzip à taux de compression comparable.
  if have zstd; then
    COMPRESSOR="zstd" ; ARCHIVE_EXT="tar.zst"
  elif have pigz; then
    COMPRESSOR="pigz" ; ARCHIVE_EXT="tar.gz"
    (( COMPRESSION_LEVEL > 9 )) && COMPRESSION_LEVEL=9
  elif have gzip; then
    COMPRESSOR="gzip" ; ARCHIVE_EXT="tar.gz"
    (( COMPRESSION_LEVEL > 9 )) && COMPRESSION_LEVEL=9
  else
    log_error "Aucun compresseur trouvé (zstd, pigz ou gzip)."; ((missing++))
  fi

  # lftp gère nativement FTPS, SFTP, la reprise et la suppression distante.
  if have lftp; then
    TRANSFER_TOOL="lftp"
  elif have curl; then
    TRANSFER_TOOL="curl"
    log_warn "'lftp' absent : bascule sur curl. La rotation des archives distantes sera désactivée."
    [[ "${FTP_PROTOCOL}" == "sftp" ]] && { log_error "Le mode sftp nécessite lftp."; ((missing++)); }
  else
    log_error "Ni 'lftp' ni 'curl' n'est installé — impossible d'uploader."; ((missing++))
  fi

  if (( missing > 0 )); then
    log_error "Installe les paquets manquants :"
    log_error "  Debian/Ubuntu : apt-get install -y tar zstd lftp"
    log_error "  RHEL/Alma     : dnf install -y tar zstd lftp"
    exit 2
  fi

  [[ "${EUID}" -eq 0 ]] || log_warn "Script lancé sans les droits root : /etc, /root et les fichiers protégés seront incomplets."

  log_ok "Prérequis OK (compression: ${COMPRESSOR}, transfert: ${TRANSFER_TOOL})."
}

acquire_lock() {
  # Empêche deux exécutions simultanées : un cron qui se déclenche alors que la
  # sauvegarde précédente tourne encore saturerait le disque et le réseau.
  #
  # /var/lock n'existe pas partout (macOS, conteneurs minimaux, systèmes
  # durcis) : on se replie sur WORK_DIR, toujours disponible puisque le script
  # y écrit ses archives.
  if ! mkdir -p "$(dirname "${LOCK_FILE}")" 2>/dev/null; then
    local fallback="${WORK_DIR}/server-backup.lock"
    log_info "Verrou ${LOCK_FILE} indisponible, repli sur ${fallback}."
    LOCK_FILE="${fallback}"
    mkdir -p "${WORK_DIR}" 2>/dev/null || die "Impossible de créer ${WORK_DIR}" 5
  fi

  if have flock; then
    exec 9>"${LOCK_FILE}" || die "Impossible d'ouvrir le verrou ${LOCK_FILE}" 5
    if ! flock -n 9; then
      die "Une autre sauvegarde est déjà en cours (verrou ${LOCK_FILE}). Abandon." 5
    fi
    echo "$$" >&9
    LOCK_STYLE="flock"
  else
    # Sans flock, mkdir sur un répertoire est l'opération atomique de référence :
    # elle échoue si le répertoire existe déjà, sans condition de concurrence.
    LOCK_DIR="${LOCK_FILE}.d"
    if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
      # Un verrou dont le processus est mort ne doit pas bloquer les
      # sauvegardes suivantes (kill -9, reboot, coupure de courant).
      #
      # `kill -0` ne suffit pas : les PID sont recyclés, surtout après un
      # redémarrage. Un verrou orphelin pointerait alors vers un processus
      # sans rapport, bien vivant, et bloquerait le cron indéfiniment. On
      # vérifie donc aussi l'âge du verrou.
      local old_pid="" lock_age=0 now
      [[ -r "${LOCK_DIR}/pid" ]] && old_pid="$(cat "${LOCK_DIR}/pid" 2>/dev/null)"
      now="$(date +%s)"
      if [[ -r "${LOCK_DIR}/started" ]]; then
        lock_age=$(( now - $(cat "${LOCK_DIR}/started" 2>/dev/null || echo "${now}") ))
      fi

      # Au-delà du timeout configuré (+ marge), la sauvegarde d'origine ne peut
      # plus être en cours : le script s'auto-limite via `timeout`.
      local max_age=$(( TIMEOUT_SECONDS > 0 ? TIMEOUT_SECONDS + 300 : 86400 ))

      if (( lock_age > max_age )); then
        log_warn "Verrou périmé (${lock_age}s > ${max_age}s) : reprise."
      elif [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
        die "Une autre sauvegarde est déjà en cours (PID ${old_pid}, démarrée il y a ${lock_age}s). Abandon." 5
      else
        log_warn "Verrou orphelin détecté (PID ${old_pid:-inconnu} absent) : reprise."
      fi

      rm -rf "${LOCK_DIR}"
      mkdir "${LOCK_DIR}" 2>/dev/null || die "Impossible de créer le verrou ${LOCK_DIR}" 5
    fi
    echo "$$"          >"${LOCK_DIR}/pid"
    date +%s           >"${LOCK_DIR}/started"
    LOCK_STYLE="mkdir"
  fi
}

rotate_own_log() {
  # Sans ça, LOG_FILE grossit indéfiniment sur un serveur qui tourne des années.
  [[ -f "${LOG_FILE}" ]] || return 0
  local size
  size="$(stat -c '%s' "${LOG_FILE}" 2>/dev/null || stat -f '%z' "${LOG_FILE}" 2>/dev/null || echo 0)"
  if (( size > 5 * 1024 * 1024 )); then
    mv -f "${LOG_FILE}" "${LOG_FILE}.1" 2>/dev/null || true
  fi
}

# ============================================================================
#  Gestion des secrets
# ============================================================================
collect_secret_patterns() {
  # Fusionne les motifs par défaut et ceux ajoutés dans la configuration.
  SECRET_PATTERNS=()
  [[ "${EXCLUDE_SECRETS}" == "yes" ]] || return 0

  SECRET_PATTERNS=("${DEFAULT_SECRET_PATTERNS[@]}")
  local p
  while IFS= read -r p; do
    p="$(echo "${p}" | xargs)"
    [[ -z "${p}" || "${p}" == \#* ]] && continue
    SECRET_PATTERNS+=("${p}")
  done <<<"${EXTRA_SECRET_PATTERNS}"
}

write_secrets_manifest() {
  # L'exclusion des secrets crée un trou dans la restauration. Ce manifeste le
  # documente : à la restauration, on sait exactement quoi régénérer et où.
  [[ "${EXCLUDE_SECRETS}" == "yes" ]] || return 0

  local d="${STAGING_DIR}/_system-state"
  mkdir -p "${d}"
  local out="${d}/SECRETS-EXCLUS.txt"

  {
    cat <<'HEADER'
================================================================================
 SECRETS VOLONTAIREMENT EXCLUS DE CETTE SAUVEGARDE
================================================================================

Cette archive n'est PAS chiffrée. Pour qu'elle puisse être stockée sans risque
sur un FTP, tous les éléments donnant un accès (mots de passe, clés privées,
tokens) en ont été retirés.

Ce fichier liste ce qui manque, pour que la restauration soit complète malgré
tout. Les fichiers listés existaient sur le serveur mais ne sont PAS dans
l'archive : il faut les régénérer ou les récupérer depuis ton gestionnaire de
mots de passe.

--------------------------------------------------------------------------------
PROCÉDURE DE RESTAURATION DES SECRETS
--------------------------------------------------------------------------------

1. MOTS DE PASSE DES COMPTES SYSTÈME (/etc/shadow absent)
   Après restauration, aucun compte n'a de mot de passe valide.
   Depuis une console de secours ou en single-user :
       passwd root
       passwd <ton-utilisateur>
   L'accès par clé SSH continue de fonctionner : authorized_keys EST sauvegardé.

2. CLÉS D'HÔTE SSH (/etc/ssh/ssh_host_*_key absentes)
   Régénérer :
       ssh-keygen -A
       systemctl restart sshd
   Les clients verront un avertissement de changement d'empreinte : normal.
   Sur les postes clients : ssh-keygen -R <ip-ou-domaine>

3. CLÉS PRIVÉES SSH UTILISATEUR (~/.ssh/id_* absentes)
   Régénérer et redéployer la clé publique sur les services concernés
   (GitHub, serveurs distants) :
       ssh-keygen -t ed25519 -C "<serveur>"

4. CERTIFICATS TLS (/etc/letsencrypt absent)
   Let's Encrypt se réémet gratuitement, la configuration certbot est
   sauvegardée dans /etc/letsencrypt/renewal :
       certbot certonly --nginx -d <domaine>
   Certificats commerciaux : les reprendre chez le fournisseur.

5. FICHIERS .env ET IDENTIFIANTS APPLICATIFS
   À récupérer depuis ton gestionnaire de mots de passe ou ton coffre CI.
   La liste exacte des chemins attendus est ci-dessous : recréer chaque
   fichier au même emplacement, avec les mêmes droits.

6. MOTS DE PASSE DES BASES DE DONNÉES
   Les identifiants applicatifs sont dans les .env manquants. Réinitialiser
   côté serveur SQL puis remettre la même valeur dans le .env.

--------------------------------------------------------------------------------
LISTE DES FICHIERS EXCLUS (chemins réels au moment de la sauvegarde)
--------------------------------------------------------------------------------

HEADER
  } >"${out}"

  # Recense les fichiers effectivement présents qui ont été écartés. Cette
  # liste est le cœur du manifeste : sans elle, on ignore ce qui manque.
  local -a roots=()
  local p
  while IFS= read -r p; do
    p="$(echo "${p}" | xargs)"
    [[ -z "${p}" || "${p}" == \#* ]] && continue
    [[ -e "${p}" ]] && roots+=("${p}")
  done <<<"${INCLUDE_PATHS}"

  # Sans chemin source existant, il n'y a rien à parcourir : find sans argument
  # lirait le répertoire courant, ce qui produirait un manifeste absurde.
  if (( ${#roots[@]} == 0 )); then
    echo "  (aucun chemin source présent sur ce serveur)" >>"${out}"
    log_warn "Manifeste des secrets : aucun chemin source à analyser."
    return 0
  fi

  local count=0
  local pat
  for pat in "${SECRET_PATTERNS[@]}"; do
    # Le motif tar est relatif à la racine : on le repasse en absolu pour find.
    local abs="/${pat#/}"
    local -a found=()
    # -path gère les jokers ; 2>/dev/null masque les répertoires interdits.
    # "${found[@]+...}" : sous set -u, bash 3.2 traite un tableau vide comme
    # une variable non définie et interromprait le script.
    mapfile -t found < <(find "${roots[@]}" -path "${abs}" \( -type f -o -type d \) 2>/dev/null | sort -u || true)
    local f
    for f in "${found[@]+"${found[@]}"}"; do
      [[ -z "${f}" ]] && continue
      local meta
      meta="$(stat -c '%A %U:%G %s octets' "${f}" 2>/dev/null || echo '')"
      printf '  %-58s %s\n' "${f}" "${meta}" >>"${out}"
      ((count++))
    done
  done

  if (( count == 0 )); then
    echo "  (aucun fichier correspondant trouvé sur ce serveur)" >>"${out}"
  fi

  {
    echo ""
    echo "--------------------------------------------------------------------------------"
    echo "Total : ${count} élément(s) exclu(s)."
    echo "Motifs appliqués : ${#SECRET_PATTERNS[@]}"
    echo "Généré le $(date "+%Y-%m-%d %H:%M:%S %z") par ${SCRIPT_NAME} v${SCRIPT_VERSION}"
    echo "--------------------------------------------------------------------------------"
  } >>"${out}"

  log_ok "Manifeste des secrets écrit : ${count} élément(s) exclu(s) et documenté(s)."
}

scan_archive_for_secrets() {
  # Filet de sécurité : les motifs d'exclusion ne peuvent pas tout prévoir
  # (une clé privée dans un chemin inattendu, un .env nommé autrement). On
  # relit l'archive pour vérifier qu'aucun secret n'a survécu.
  [[ "${SECRET_SCAN_ACTION}" == "off" ]] && { log_info "Scan de secrets désactivé."; return 0; }
  [[ "${DRY_RUN}" == "yes" ]] && return 0
  # En mode archive complète, les secrets sont là par choix : les signaler
  # produirait des milliers de fausses alertes à chaque exécution.
  if [[ "${EXCLUDE_SECRETS}" != "yes" ]]; then
    log_info "Scan de secrets ignoré (EXCLUDE_SECRETS=no : archive complète assumée)."
    return 0
  fi

  log_step "Scan de contrôle : recherche de secrets résiduels"

  local -a decomp
  case "${COMPRESSOR}" in
    zstd) decomp=(zstd -d -c) ;;
    *)    decomp=(gzip -d -c) ;;
  esac

  # 1) Contrôle par nom de fichier.
  local listing="${STAGING_DIR}/_listing.txt"
  "${decomp[@]}" <"${ARCHIVE_PATH}" 2>/dev/null | tar -tf - 2>/dev/null >"${listing}" || true

  local -a hits=()
  local suspicious='(^|/)(shadow|gshadow)$|(^|/)\.env($|\.)|(^|/)\.my\.cnf$|(^|/)\.pgpass$|(^|/)\.netrc$|(^|/)id_(rsa|dsa|ecdsa|ed25519)$|\.(key|pem|p12|pfx|jks)$|(^|/)credentials$|(^|/)\.git-credentials$'
  mapfile -t hits < <(grep -inE "${suspicious}" "${listing}" 2>/dev/null | head -50 || true)

  # 2) Contrôle par contenu : une clé privée reste détectable quel que soit son nom.
  local content_hits=0
  local pattern_alt
  pattern_alt="$(printf '%s|' "${SECRET_CONTENT_PATTERNS[@]}")"
  pattern_alt="${pattern_alt%|}"
  # On limite la lecture aux fichiers texte de taille raisonnable pour ne pas
  # relire des gigaoctets de binaires.
  content_hits="$("${decomp[@]}" <"${ARCHIVE_PATH}" 2>/dev/null \
    | tar -xO -f - 2>/dev/null \
    | grep -caE "${pattern_alt}" 2>/dev/null || echo 0)"
  content_hits="$(echo "${content_hits}" | tr -d ' \n')"
  [[ "${content_hits}" =~ ^[0-9]+$ ]] || content_hits=0

  local total=$(( ${#hits[@]} + content_hits ))

  if (( total == 0 )); then
    log_ok "Aucun secret détecté dans l'archive."
    return 0
  fi

  log_error "═══════════════════════════════════════════════════════════════"
  log_error "SECRETS DÉTECTÉS DANS L'ARCHIVE — elle ne doit pas partir en clair."
  if (( ${#hits[@]} > 0 )); then
    log_error "Fichiers suspects par leur nom (${#hits[@]}) :"
    local h
    for h in "${hits[@]:0:15}"; do
      log_error "    ${h#*:}"
    done
    (( ${#hits[@]} > 15 )) && log_error "    … et $(( ${#hits[@]} - 15 )) autre(s)."
  fi
  (( content_hits > 0 )) && log_error "Blocs de clé privée trouvés dans le contenu : ${content_hits}"
  log_error "Ajoute les motifs correspondants à EXTRA_SECRET_PATTERNS dans ${CONFIG_FILE}."
  log_error "═══════════════════════════════════════════════════════════════"

  if [[ "${SECRET_SCAN_ACTION}" == "abort" ]]; then
    rm -f -- "${ARCHIVE_PATH}" "${ARCHIVE_PATH}.sha256"
    die "Sauvegarde annulée et archive locale supprimée (SECRET_SCAN_ACTION=abort)." 6
  fi
  log_warn "SECRET_SCAN_ACTION=warn : l'upload continue malgré les secrets détectés."
  return 0
}

# ============================================================================
#  Capture de l'état système
#  C'est cette partie qui transforme « j'ai mes fichiers » en « je peux
#  reconstruire le serveur ». Chaque commande est optionnelle : un serveur sans
#  Docker ou sans systemd ne doit pas faire échouer la sauvegarde.
# ============================================================================
capture_system_state() {
  [[ "${CAPTURE_SYSTEM_STATE}" == "yes" ]] || { log_info "Capture de l'état système désactivée."; return 0; }
  log_step "Capture de l'état système"

  local d="${STAGING_DIR}/_system-state"
  mkdir -p "${d}"

  # Chaque capture est isolée : une commande absente écrit un fichier vide
  # plutôt que d'interrompre la sauvegarde.
  _cap() {
    local out="$1" ; shift
    if have "$1"; then
      "$@" >"${d}/${out}" 2>/dev/null || echo "(échec de : $*)" >"${d}/${out}"
    fi
  }

  # --- Identité et matériel ---
  {
    echo "Sauvegarde générée le : $(date "+%Y-%m-%d %H:%M:%S %z")"
    echo "Script                : ${SCRIPT_NAME} v${SCRIPT_VERSION}"
    echo "Hostname              : $(hostname -f 2>/dev/null || hostname)"
    echo "Kernel                : $(uname -a)"
    echo "Uptime                : $(uptime 2>/dev/null)"
    echo "Archive chiffrée      : NON"
    if [[ "${EXCLUDE_SECRETS}" == "yes" ]]; then
      echo "Secrets               : EXCLUS — voir SECRETS-EXCLUS.txt pour la procédure"
    else
      echo "Secrets               : INCLUS — restauration intégrale possible."
      echo "                        Cette archive donne un accès root complet :"
      echo "                        la traiter comme un identifiant serveur."
    fi
  } >"${d}/00-INFO.txt"

  [[ -r /etc/os-release ]] && cp /etc/os-release "${d}/os-release.txt"
  _cap "cpu.txt"     lscpu
  _cap "memory.txt"  free -h
  _cap "block.txt"   lsblk -f
  _cap "disks.txt"   df -hT
  _cap "pci.txt"     lspci
  _cap "mounts.txt"  findmnt -A
  [[ -r /etc/fstab ]] && cp /etc/fstab "${d}/fstab.txt"

  # --- Paquets installés : permet de réinstaller à l'identique ---
  if have dpkg; then
    dpkg --get-selections >"${d}/packages-dpkg.txt" 2>/dev/null || true
    have apt-mark && apt-mark showmanual >"${d}/packages-apt-manual.txt" 2>/dev/null || true
    echo "# Restauration : apt-get install \$(cat packages-apt-manual.txt)" >"${d}/packages-RESTORE.txt"
  elif have rpm; then
    rpm -qa --qf '%{NAME}\n' | sort >"${d}/packages-rpm.txt" 2>/dev/null || true
    echo "# Restauration : dnf install \$(cat packages-rpm.txt)" >"${d}/packages-RESTORE.txt"
  fi
  have snap && snap list >"${d}/packages-snap.txt" 2>/dev/null || true
  have npm  && npm ls -g --depth=0 >"${d}/packages-npm-global.txt" 2>/dev/null || true
  have pip3 && pip3 freeze >"${d}/packages-pip.txt" 2>/dev/null || true

  # --- Dépôts APT / YUM (sinon les paquets tiers sont introuvables) ---
  [[ -d /etc/apt ]]  && tar -cf "${d}/apt-sources.tar"  -C / etc/apt/sources.list etc/apt/sources.list.d etc/apt/trusted.gpg.d 2>/dev/null || true
  [[ -d /etc/yum.repos.d ]] && tar -cf "${d}/yum-repos.tar" -C / etc/yum.repos.d 2>/dev/null || true

  # --- Services et démarrage ---
  if have systemctl; then
    systemctl list-unit-files --state=enabled     >"${d}/systemd-enabled.txt"  2>/dev/null || true
    systemctl list-units --type=service --all     >"${d}/systemd-services.txt" 2>/dev/null || true
    systemctl list-timers --all                   >"${d}/systemd-timers.txt"   2>/dev/null || true
  fi

  # --- Tâches planifiées (crontabs utilisateurs : hors /etc, souvent oubliées) ---
  mkdir -p "${d}/crontabs"
  if have crontab; then
    local u
    while IFS=: read -r u _; do
      crontab -l -u "${u}" >"${d}/crontabs/${u}.cron" 2>/dev/null || rm -f "${d}/crontabs/${u}.cron"
    done </etc/passwd
  fi

  # --- Réseau et pare-feu ---
  _cap "net-interfaces.txt" ip -details a
  _cap "net-routes.txt"     ip route show table all
  have iptables-save  && iptables-save  >"${d}/firewall-iptables.rules"  2>/dev/null || true
  have ip6tables-save && ip6tables-save >"${d}/firewall-ip6tables.rules" 2>/dev/null || true
  have nft && nft list ruleset >"${d}/firewall-nftables.rules" 2>/dev/null || true
  have ufw && ufw status verbose >"${d}/firewall-ufw.txt" 2>/dev/null || true
  have firewall-cmd && firewall-cmd --list-all-zones >"${d}/firewall-firewalld.txt" 2>/dev/null || true
  _cap "net-listening.txt" ss -tulpn

  # --- Comptes ---
  # passwd et group sont conservés : les UID/GID doivent correspondre à la
  # restauration, et ces fichiers ne contiennent pas de mot de passe.
  # shadow n'est JAMAIS copié ici : voir SECRETS-EXCLUS.txt pour la procédure.
  for f in passwd group; do
    [[ -r "/etc/${f}" ]] && cp "/etc/${f}" "${d}/${f}.txt"
  done

  # --- Docker : images et conteneurs à relancer ---
  if have docker && docker info >/dev/null 2>&1; then
    docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' >"${d}/docker-containers.txt" 2>/dev/null || true
    docker images --format '{{.Repository}}:{{.Tag}}'                        >"${d}/docker-images.txt"     2>/dev/null || true
    docker volume ls --format '{{.Name}}'                                    >"${d}/docker-volumes.txt"    2>/dev/null || true
    docker network ls --format '{{.Name}}\t{{.Driver}}'                      >"${d}/docker-networks.txt"   2>/dev/null || true
    # docker inspect expose les variables d'environnement des conteneurs, donc
    # souvent des mots de passe. En archive complète on les garde (ils sont
    # nécessaires pour relancer les conteneurs à l'identique) ; en archive
    # expurgée on les masque.
    docker ps -aq | while read -r cid; do
      if [[ "${EXCLUDE_SECRETS}" == "yes" ]]; then
        docker inspect "${cid}" 2>/dev/null \
          | sed -E 's/("(PASSWORD|PASSWD|SECRET|TOKEN|KEY|API_KEY|DSN)[^"]*=)[^"]*/\1<<REDACTED>>/gI' \
          >>"${d}/docker-inspect.json" || true
      else
        docker inspect "${cid}" 2>/dev/null >>"${d}/docker-inspect.json" || true
      fi
    done
  fi

  # --- Serveurs web ---
  # nginx -T inclut le contenu des fichiers inclus, dont parfois des mots de
  # passe de proxy : on redirige les lignes sensibles.
  if have nginx; then
    if [[ "${EXCLUDE_SECRETS}" == "yes" ]]; then
      nginx -T 2>/dev/null \
        | sed -E 's/(proxy_set_header +Authorization +).*/\1<<REDACTED>>;/I' \
        >"${d}/nginx-full-config.txt" || true
    else
      nginx -T >"${d}/nginx-full-config.txt" 2>/dev/null || true
    fi
  fi
  have apache2ctl && apache2ctl -S  >"${d}/apache-vhosts.txt"      2>/dev/null || true
  have httpd  && httpd -S           >"${d}/httpd-vhosts.txt"       2>/dev/null || true
  have certbot && certbot certificates >"${d}/certbot-certificates.txt" 2>/dev/null || true

  # --- Versions des runtimes : un site PHP 7.4 ne redémarre pas sur PHP 8.3 ---
  {
    for bin in node npm php python3 ruby java go rustc mysql psql mongod redis-server nginx docker; do
      if have "${bin}"; then
        printf '%-14s %s\n' "${bin}" "$("${bin}" --version 2>&1 | head -1)"
      fi
    done
  } >"${d}/runtime-versions.txt" 2>/dev/null || true

  log_ok "État système capturé ($(find "${d}" -type f | wc -l | tr -d ' ') fichiers)."
}

# ============================================================================
#  Dumps bases de données
#  Copier /var/lib/mysql à chaud produit une base corrompue : on exclut ces
#  répertoires et on fait des dumps cohérents à la place.
# ============================================================================
dump_databases() {
  local d="${STAGING_DIR}/_databases"

  # Un dump contient des données clients en clair (emails, téléphones). Sur un
  # FTP non chiffré, la protection repose entièrement sur l'accès au FTP.
  if [[ "${DUMP_MYSQL}" == "yes" || "${DUMP_POSTGRES}" == "yes" || "${DUMP_MONGO}" == "yes" ]]; then
    log_info "Dumps SQL activés : données applicatives incluses en clair dans l'archive."
  fi

  # En archive complète, on garde les tables de comptes SQL : sans elles, les
  # utilisateurs et leurs droits sont à recréer à la main après restauration.
  local skip_sensitive="${DUMP_SKIP_SENSITIVE_TABLES}"
  [[ "${EXCLUDE_SECRETS}" != "yes" ]] && skip_sensitive="no"

  if [[ "${DUMP_MYSQL}" == "yes" ]]; then
    log_step "Dump MySQL / MariaDB"
    if have mysqldump; then
      mkdir -p "${d}"
      local -a auth=()
      [[ -n "${MYSQL_USER}" ]] && auth+=("--user=${MYSQL_USER}")
      [[ -n "${MYSQL_PASS}" ]] && auth+=("--password=${MYSQL_PASS}")
      local -a skip=()
      if [[ "${skip_sensitive}" == "yes" ]]; then
        # La table mysql.user contient les hashs de mots de passe SQL.
        skip+=(--ignore-table=mysql.user --ignore-table=mysql.global_priv)
      fi
      # shellcheck disable=SC2086
      if mysqldump "${auth[@]+"${auth[@]}"}" "${skip[@]+"${skip[@]}"}" ${MYSQL_DUMP_OPTS} >"${d}/mysql-all.sql" 2>"${d}/mysql-error.log"; then
        log_ok "Dump MySQL : $(du -h "${d}/mysql-all.sql" | cut -f1)"
        rm -f "${d}/mysql-error.log"
      else
        log_warn "Dump MySQL échoué — voir _databases/mysql-error.log dans l'archive."
      fi
    else
      log_warn "DUMP_MYSQL=yes mais 'mysqldump' est introuvable."
    fi
  fi

  if [[ "${DUMP_POSTGRES}" == "yes" ]]; then
    log_step "Dump PostgreSQL"
    if have pg_dumpall; then
      mkdir -p "${d}"
      local pg_opts=""
      # --no-role-passwords retire les hashs des rôles du dump.
      [[ "${skip_sensitive}" == "yes" ]] && pg_opts="--no-role-passwords"
      # pg_dumpall doit tourner en tant que superutilisateur postgres.
      if su - "${POSTGRES_SUPERUSER}" -c "pg_dumpall ${pg_opts}" >"${d}/postgres-all.sql" 2>"${d}/postgres-error.log"; then
        log_ok "Dump PostgreSQL : $(du -h "${d}/postgres-all.sql" | cut -f1)"
        rm -f "${d}/postgres-error.log"
      else
        log_warn "Dump PostgreSQL échoué — voir _databases/postgres-error.log."
      fi
    else
      log_warn "DUMP_POSTGRES=yes mais 'pg_dumpall' est introuvable."
    fi
  fi

  if [[ "${DUMP_MONGO}" == "yes" ]]; then
    log_step "Dump MongoDB"
    if have mongodump; then
      mkdir -p "${d}/mongo"
      if mongodump --uri="${MONGO_URI}" --out="${d}/mongo" >"${d}/mongo-dump.log" 2>&1; then
        log_ok "Dump MongoDB : $(du -sh "${d}/mongo" | cut -f1)"
      else
        log_warn "Dump MongoDB échoué — voir _databases/mongo-dump.log."
      fi
      # L'URI peut contenir des identifiants : elle ne doit pas rester en clair.
      sed -i -E 's#(mongodb(\+srv)?://)[^@ ]*@#\1<<REDACTED>>@#g' "${d}/mongo-dump.log" 2>/dev/null || true
    else
      log_warn "DUMP_MONGO=yes mais 'mongodump' est introuvable."
    fi
  fi

  return 0
}

# ============================================================================
#  Construction de l'archive
# ============================================================================
build_archive() {
  log_step "Construction de l'archive"

  # En mode snapshot, le nom est fixe : la nouvelle archive remplace la
  # précédente sur le FTP. En mode history, il est daté pour permettre la
  # rotation grand-père/père/fils.
  local base
  if [[ "${BACKUP_MODE}" == "snapshot" ]]; then
    base="${SERVER_NAME}_latest"
  else
    base="${SERVER_NAME}_$(date '+%Y-%m-%d_%H%M%S')"
  fi
  local tarball="${WORK_DIR}/${base}.${ARCHIVE_EXT}"

  # --- Liste des chemins réellement présents ---
  local -a includes=()
  local p
  while IFS= read -r p; do
    p="$(echo "${p}" | xargs)"          # trim
    [[ -z "${p}" || "${p}" == \#* ]] && continue
    if [[ -e "${p}" ]]; then
      includes+=("${p#/}")               # tar -C / veut des chemins relatifs
    else
      log_warn "Chemin absent, ignoré : ${p}"
    fi
  done <<<"${INCLUDE_PATHS}"

  # Les données générées (état système, dumps) sont ajoutées depuis le staging.
  local -a staging_includes=()
  [[ -d "${STAGING_DIR}/_system-state" ]] && staging_includes+=("_system-state")
  [[ -d "${STAGING_DIR}/_databases"    ]] && staging_includes+=("_databases")

  if (( ${#includes[@]} == 0 && ${#staging_includes[@]} == 0 )); then
    die "Aucun chemin à sauvegarder : vérifie INCLUDE_PATHS dans ${CONFIG_FILE}." 3
  fi
  log_info "${#includes[@]} chemin(s) source(s) retenu(s)."

  # --- Options tar ---
  # Toutes les options ne sont pas portables : GNU tar (Linux) et bsdtar
  # (macOS, BSD) ne partagent pas le même jeu. Passer une option non supportée
  # fait échouer tar au lieu de produire une archive : on teste avant d'ajouter.
  local -a tar_opts=(--create --file=-)
  _tar_supports() { tar "$1" --version >/dev/null 2>&1 || tar --help 2>&1 | grep -q -- "$1"; }

  _tar_supports --ignore-failed-read   && tar_opts+=(--ignore-failed-read)
  _tar_supports --warning              && tar_opts+=(--warning=no-file-changed)

  # --one-file-system empêche de partir dans un montage réseau ou un disque de
  # données, mais il exclut SILENCIEUSEMENT tout chemin situé sur un autre
  # système de fichiers. Un /var/www monté sur un disque dédié disparaîtrait
  # ainsi de la sauvegarde sans le moindre message. On prévient explicitement.
  if [[ "${ONE_FILE_SYSTEM}" == "yes" ]] && _tar_supports --one-file-system; then
    tar_opts+=(--one-file-system)
    local root_dev inc_dev inc
    root_dev="$(stat -c '%d' / 2>/dev/null || stat -f '%d' / 2>/dev/null || echo '')"
    if [[ -n "${root_dev}" ]]; then
      for inc in "${includes[@]}"; do
        inc_dev="$(stat -c '%d' "/${inc}" 2>/dev/null || stat -f '%d' "/${inc}" 2>/dev/null || echo '')"
        if [[ -n "${inc_dev}" && "${inc_dev}" != "${root_dev}" ]]; then
          log_warn "/${inc} est sur un autre système de fichiers : ONE_FILE_SYSTEM=yes va l'EXCLURE. Passe ONE_FILE_SYSTEM à \"no\" pour l'inclure."
        fi
      done
    fi
  fi

  # Préserve users, groupes, permissions et ACL — indispensable pour restaurer
  # /etc et /var/www dans un état fonctionnel.
  _tar_supports --numeric-owner && tar_opts+=(--numeric-owner)
  _tar_supports --acls          && tar_opts+=(--acls)
  _tar_supports --xattrs        && tar_opts+=(--xattrs)

  local pat
  while IFS= read -r pat; do
    pat="$(echo "${pat}" | xargs)"
    [[ -z "${pat}" || "${pat}" == \#* ]] && continue
    tar_opts+=(--exclude="${pat}")
  done <<<"${EXCLUDE_PATTERNS}"

  # --- Exclusion des secrets ---
  # C'est la protection principale de l'archive : appliquée APRÈS les
  # exclusions normales pour qu'aucune règle utilisateur ne puisse les annuler.
  if [[ "${EXCLUDE_SECRETS}" == "yes" ]]; then
    for pat in "${SECRET_PATTERNS[@]}"; do
      tar_opts+=(--exclude="${pat}")
      # Un motif relatif doit aussi matcher en absolu et inversement.
      [[ "${pat}" == /* ]] && tar_opts+=(--exclude="${pat#/}") || tar_opts+=(--exclude="/${pat}")
    done
    log_info "${#SECRET_PATTERNS[@]} motif(s) de secrets exclu(s) de l'archive."
  fi

  # Toujours exclure notre propre répertoire de travail : sans ça l'archive
  # tenterait de s'inclure elle-même en cours d'écriture.
  tar_opts+=(--exclude="${WORK_DIR#/}" --exclude="${WORK_DIR}")
  tar_opts+=(--exclude="${LOG_FILE#/}")

  # Écarte les fichiers énormes (dumps oubliés, ISO, images disque).
  if (( MAX_FILE_SIZE_MB > 0 )); then
    local biglist="${STAGING_DIR}/_toobig.txt"
    : >"${biglist}"
    local inc
    for inc in "${includes[@]}"; do
      find "/${inc}" -type f -size +"${MAX_FILE_SIZE_MB}"M -printf '%P\n' 2>/dev/null \
        | sed "s|^|${inc}/|" >>"${biglist}" || true
    done
    if [[ -s "${biglist}" ]]; then
      local n ; n="$(wc -l <"${biglist}" | tr -d ' ')"
      log_warn "${n} fichier(s) > ${MAX_FILE_SIZE_MB} Mo exclus (liste dans _system-state/excluded-large-files.txt)."
      mkdir -p "${STAGING_DIR}/_system-state"
      cp "${biglist}" "${STAGING_DIR}/_system-state/excluded-large-files.txt"
      tar_opts+=(--exclude-from="${biglist}")
    fi
  fi

  # --- Compression ---
  local -a comp_cmd
  case "${COMPRESSOR}" in
    zstd) comp_cmd=(zstd "-${COMPRESSION_LEVEL}" -T0 -q -c) ;;
    pigz) comp_cmd=(pigz "-${COMPRESSION_LEVEL}" -c) ;;
    gzip) comp_cmd=(gzip "-${COMPRESSION_LEVEL}" -c) ;;
  esac

  if [[ "${DRY_RUN}" == "yes" ]]; then
    log_info "[dry-run] Archive qui serait créée : ${tarball}"
    log_info "[dry-run] tar ${tar_opts[*]}"
    ARCHIVE_PATH="${tarball}"
    return 0
  fi

  mkdir -p "${WORK_DIR}"
  chmod 700 "${WORK_DIR}"

  # Contrôle d'espace AVANT d'écrire : sur un gros serveur, découvrir un disque
  # plein après une heure de compression coûte une nuit de sauvegarde, et
  # laisse une archive tronquée à nettoyer. L'archive intermédiaire est écrite
  # non compressée, il faut donc prévoir la taille brute des sources.
  local need_kb=0 avail_kb=0 inc
  for inc in "${includes[@]}"; do
    need_kb=$(( need_kb + $(du -sk "/${inc}" 2>/dev/null | awk '{print $1}' || echo 0) ))
  done
  avail_kb="$(df -Pk "${WORK_DIR}" 2>/dev/null | awk 'NR==2{print $4}' || echo 0)"

  if (( need_kb > 0 && avail_kb > 0 )); then
    # ~1,15× la taille brute : l'archive intermédiaire, plus une marge pour le
    # fichier compressé qui coexiste avec elle le temps de la compression.
    local need_total_kb=$(( need_kb * 115 / 100 ))
    log_info "Espace : $(( need_kb / 1024 )) Mo de sources, $(( avail_kb / 1024 )) Mo disponibles sur ${WORK_DIR}."
    if (( avail_kb < need_total_kb )); then
      die "Espace insuffisant sur ${WORK_DIR} : ~$(( need_total_kb / 1024 )) Mo requis, $(( avail_kb / 1024 )) Mo libres. Libère de la place ou déplace WORK_DIR." 3
    fi
  fi

  log_info "Écriture de ${tarball} (compression ${COMPRESSOR} niveau ${COMPRESSION_LEVEL})…"

  # ATTENTION — deux flux `tar -cf -` ne se concatènent PAS : chaque archive se
  # termine par un marqueur de fin, et tout lecteur s'arrête au premier. Une
  # concaténation ferait donc disparaître silencieusement _system-state/ et
  # _databases/, c'est-à-dire exactement les métadonnées de reconstruction.
  # On construit donc une archive intermédiaire sur disque, à laquelle on
  # ajoute le staging avec --append, avant de compresser en une seule passe.
  local raw="${WORK_DIR}/.build-${base}.tar"
  rm -f -- "${raw}"

  # L'archive est écrite directement dans un fichier : on remplace --file=-
  # par la cible réelle. Le stderr est capturé dans un fichier plutôt que via
  # une substitution de processus, qui rendrait le code retour de tar
  # imprévisible selon les shells.
  local -a tar_run=()
  local o
  for o in "${tar_opts[@]}"; do
    [[ "${o}" == "--file=-" ]] && tar_run+=("--file=${raw}") || tar_run+=("${o}")
  done

  local tar_err="${STAGING_DIR}/_tar-stderr.txt"
  local rc=0
  if (( ${#includes[@]} > 0 )); then
    tar "${tar_run[@]}" -C / -- "${includes[@]}" 2>"${tar_err}" || rc=$?
    # « file changed as we read it » est attendu sur un serveur en production :
    # on ne remonte que le reste, pour ne pas noyer les vraies erreurs.
    if [[ -s "${tar_err}" ]]; then
      grep -v 'file changed as we read it' "${tar_err}" | head -20 >&2 || true
    fi
    # Code 1 = avertissements non fatals (typiquement « file changed as we
    # read it », courant sur un serveur en production). On poursuit, mais
    # sans conclure que tout va bien : verify_archive() contrôle ensuite que
    # les chemins sources sont réellement présents. Un tar qui échoue tôt
    # (option non supportée, permissions) sort aussi en 1 sans rien archiver.
    if (( rc == 1 )); then
      log_warn "tar a signalé des avertissements (code 1) — vérification du contenu en aval."
      rc=0
    fi
    (( rc > 1 )) && { rm -f -- "${raw}"; die "Échec de tar (code ${rc})." 3; }
  fi

  if (( ${#staging_includes[@]} > 0 )); then
    if [[ -f "${raw}" ]]; then
      tar --append --file="${raw}" -C "${STAGING_DIR}" -- "${staging_includes[@]}" \
        || { rm -f -- "${raw}"; die "Échec de l'ajout des métadonnées à l'archive." 3; }
    else
      tar --create --file="${raw}" -C "${STAGING_DIR}" -- "${staging_includes[@]}" \
        || { rm -f -- "${raw}"; die "Échec de la création de l'archive des métadonnées." 3; }
    fi
  fi

  [[ -s "${raw}" ]] || { rm -f -- "${raw}"; die "Archive intermédiaire vide : rien n'a été archivé." 3; }

  "${comp_cmd[@]}" <"${raw}" >"${tarball}" \
    || { rm -f -- "${raw}" "${tarball}"; die "Échec de la compression de l'archive." 3; }
  rm -f -- "${raw}"

  [[ -s "${tarball}" ]] || die "Archive vide ou absente : ${tarball}" 3

  chmod 600 "${tarball}"
  ARCHIVE_PATH="${tarball}"

  # Somme de contrôle : permet de vérifier l'intégrité après téléchargement.
  if have sha256sum; then
    sha256sum "${tarball}" | awk '{print $1}' >"${tarball}.sha256"
  elif have shasum; then
    shasum -a 256 "${tarball}" | awk '{print $1}' >"${tarball}.sha256"
  fi

  log_ok "Archive créée : $(basename "${tarball}") ($(du -h "${tarball}" | cut -f1))"
}

verify_archive() {
  [[ "${DRY_RUN}" == "yes" ]] && return 0
  log_step "Vérification de l'archive"

  # On relit l'archive de bout en bout : mieux vaut découvrir une archive
  # corrompue maintenant que le jour du crash.
  local -a decomp
  case "${COMPRESSOR}" in
    zstd) decomp=(zstd -d -c) ;;
    *)    decomp=(gzip -d -c) ;;
  esac

  local listing="${STAGING_DIR}/_verify-listing.txt"
  if ! "${decomp[@]}" <"${ARCHIVE_PATH}" 2>/dev/null | tar -tf - >"${listing}" 2>/dev/null; then
    die "Archive illisible : la décompression ou la lecture tar a échoué." 3
  fi

  local count
  count="$(wc -l <"${listing}" | tr -d ' ')"
  (( count > 0 )) || die "Archive vide : aucune entrée lisible." 3

  # Contrôle ESSENTIEL : vérifier que chaque chemin source figure réellement
  # dans l'archive. Un simple comptage ne suffit pas — les métadonnées de
  # _system-state/ peuvent à elles seules dépasser n'importe quel seuil et
  # masquer un tar qui a échoué sans rien archiver. C'est précisément le cas
  # qui produirait une sauvegarde "réussie" mais vide, découverte le jour du
  # crash.
  # L'entrée d'un chemin source doit apparaître en DÉBUT de ligne du listing
  # tar. Une recherche non ancrée trouverait le chemin mentionné n'importe où
  # (y compris dans un fichier de _system-state/) et validerait à tort une
  # archive vide — le pire scénario possible pour une sauvegarde.
  local -a missing=()
  local p rel
  while IFS= read -r p; do
    p="$(echo "${p}" | xargs)"
    [[ -z "${p}" || "${p}" == \#* ]] && continue
    [[ -e "${p}" ]] || continue          # chemin absent du serveur : déjà signalé
    rel="${p#/}"
    # tar liste les répertoires avec un / final et leur contenu en dessous :
    # on accepte la ligne exacte, avec ou sans / final, ou tout descendant.
    if ! grep -qE "^${rel//./\\.}(/|\$)" "${listing}"; then
      missing+=("${p}")
    fi
  done <<<"${INCLUDE_PATHS}"

  if (( ${#missing[@]} > 0 )); then
    log_error "Ces chemins existent sur le serveur mais SONT ABSENTS de l'archive :"
    local m
    for m in "${missing[@]}"; do log_error "    ${m}"; done
    die "Archive incomplète — sauvegarde annulée pour ne pas remplacer une archive valide par une archive vide." 3
  fi

  log_ok "Archive vérifiée : ${count} entrées, tous les chemins sources présents."
}

# ============================================================================
#  Transfert
# ============================================================================
ftp_url_scheme() {
  case "${FTP_PROTOCOL}" in
    ftp)           echo "ftp" ;;
    ftps)          echo "ftp" ;;   # lftp active TLS via ftp:ssl-force
    ftps-implicit) echo "ftps" ;;
    sftp)          echo "sftp" ;;
  esac
}

lftp_settings() {
  # Réglages communs à toutes les commandes lftp.
  local s=""
  s+="set cmd:fail-exit yes;"
  s+="set net:max-retries 3;"
  s+="set net:reconnect-interval-base 5;"
  s+="set net:timeout 30;"
  s+="set xfer:clobber yes;"
  case "${FTP_PROTOCOL}" in
    ftps)          s+="set ftp:ssl-force true; set ftp:ssl-protect-data true;" ;;
    ftps-implicit) s+="set ftp:ssl-force true; set ftp:ssl-protect-data true;" ;;
    ftp)           s+="set ftp:ssl-allow false;" ;;
  esac
  [[ "${FTP_VERIFY_CERT}" == "yes" ]] \
    && s+="set ssl:verify-certificate true;" \
    || s+="set ssl:verify-certificate false;"
  [[ "${FTP_PROTOCOL}" == "sftp" && -n "${SFTP_KEY}" ]] \
    && s+="set sftp:connect-program \"ssh -a -x -i ${SFTP_KEY} -o StrictHostKeyChecking=accept-new\";"
  (( BANDWIDTH_LIMIT_KB > 0 )) && s+="set net:limit-total-rate 0:$(( BANDWIDTH_LIMIT_KB * 1024 ));"
  echo "${s}"
}

# ----------------------------------------------------------------------------
#  GARDE-FOU : sens unique local -> distant
#
#  Ce script est une sauvegarde, pas une synchronisation. Le flux normal est
#  STRICTEMENT montant : rien de ce qui se trouve sur le FTP ne doit jamais
#  écraser un fichier du serveur. Un FTP compromis, un fichier modifié à
#  distance ou une archive corrompue ne doivent avoir aucun effet local.
#
#  Trois protections superposées :
#    1. Aucune commande de synchronisation (mirror) n'est utilisée nulle part.
#    2. assert_upload_only() inspecte chaque commande lftp AVANT exécution et
#       refuse toute opération descendante hors du mode --restore explicite.
#    3. En mode --restore, l'écriture est confinée à ${WORK_DIR}/restore et
#       l'extraction n'est JAMAIS automatique : le script affiche les commandes
#       tar à lancer manuellement, il ne les exécute pas.
# ----------------------------------------------------------------------------
assert_upload_only() {
  local commands="$1"

  # Le mode restore est la seule exception, et il est toujours déclenché
  # manuellement par l'utilisateur — jamais par le cron.
  [[ "${MODE}" == "restore" ]] && return 0

  # `mirror` sans -R synchronise le distant VERS le local : c'est exactement
  # l'opération qui pourrait écraser les fichiers du serveur. Refus catégorique,
  # y compris dans le sens montant, que ce script n'utilise pas.
  if grep -qiE '(^|[;[:space:]])mirror([[:space:]]|$)' <<<"${commands}"; then
    die "GARDE-FOU : commande 'mirror' interdite (risque de synchronisation distant -> local)." 1
  fi

  # `get`/`pget` téléchargent. Aucune raison d'en émettre hors mode restore.
  if grep -qiE '(^|[;[:space:]])(get|pget|mget)([[:space:]]|$)' <<<"${commands}"; then
    die "GARDE-FOU : téléchargement ('get') interdit en mode '${MODE}' — ce script n'écrit jamais sur le serveur." 1
  fi

  return 0
}

run_lftp() {
  # Les identifiants sont envoyés sur l'ENTRÉE STANDARD de lftp, jamais en
  # argument : `lftp -c "...FTP_PASS..."` rendrait le mot de passe lisible par
  # tout utilisateur du serveur via `ps auxww`, ce qui reviendrait à publier
  # l'accès au dépôt de sauvegardes.
  local commands="$1"
  assert_upload_only "${commands}"
  local scheme ; scheme="$(ftp_url_scheme)"

  # `set` puis `open` sont interprétés ligne par ligne, comme en session
  # interactive : rien ne transite par argv.
  printf '%s\nopen -u %s,%s -p %s %s://%s\n%s\n' \
    "$(lftp_settings)" "${FTP_USER}" "${FTP_PASS}" "${FTP_PORT}" \
    "${scheme}" "${FTP_HOST}" "${commands}" \
    | lftp
}

remote_dir() { echo "${FTP_BASE_DIR%/}/${SERVER_NAME}"; }

# curl --user place les identifiants dans argv, donc dans `ps auxww`, lisible
# par tout utilisateur du serveur. On passe par un .netrc temporaire en 600,
# créé dans le staging (effacé automatiquement en sortie).
NETRC_FILE=""
curl_auth_args() {
  if [[ -z "${NETRC_FILE}" ]]; then
    local dir="${STAGING_DIR:-${WORK_DIR}}"
    mkdir -p "${dir}" 2>/dev/null || true
    NETRC_FILE="${dir}/.netrc"
    # umask avant création : le fichier ne doit jamais être lisible, même
    # brièvement, entre sa création et le chmod.
    ( umask 077 ; printf 'machine %s login %s password %s\n' \
        "${FTP_HOST}" "${FTP_USER}" "${FTP_PASS}" >"${NETRC_FILE}" )
    chmod 600 "${NETRC_FILE}" 2>/dev/null || true
  fi
  printf '%s\n%s\n' "--netrc-file" "${NETRC_FILE}"
}

test_connection() {
  log_step "Test de la connexion ${FTP_PROTOCOL}://${FTP_HOST}:${FTP_PORT}"
  if [[ "${TRANSFER_TOOL}" == "lftp" ]]; then
    if run_lftp "cls -1 / >/dev/null; exit" 2>/dev/null; then
      log_ok "Connexion établie."
      return 0
    fi
    log_error "Connexion impossible. Vérifie FTP_HOST/PORT/USER/PASS et FTP_PROTOCOL."
    [[ "${FTP_VERIFY_CERT}" == "yes" ]] && log_error "Si le certificat est auto-signé, essaie FTP_VERIFY_CERT=\"no\"."
    return 1
  else
    local -a auth=() ; mapfile -t auth < <(curl_auth_args)
    if curl -sS --connect-timeout 20 --list-only "ftp://${FTP_HOST}:${FTP_PORT}/" \
         "${auth[@]}" >/dev/null 2>&1; then
      log_ok "Connexion établie."
      return 0
    fi
    log_error "Connexion impossible via curl."
    return 1
  fi
}

upload_archive() {
  log_step "Envoi vers le FTP"
  local rdir ; rdir="$(remote_dir)"
  local name ; name="$(basename "${ARCHIVE_PATH}")"

  if [[ "${DRY_RUN}" == "yes" ]]; then
    log_info "[dry-run] Upload de ${name} vers ${rdir}/ — non effectué."
    return 0
  fi

  if [[ "${TRANSFER_TOOL}" == "lftp" ]]; then
    # Upload sous un nom temporaire puis renommage : une archive visible sur le
    # FTP est donc toujours une archive complète, jamais un transfert coupé.
    local cmds=""
    # Contrairement au mkdir du shell, `mkdir -p` de lftp renvoie une erreur
    # 550 si le répertoire existe déjà. Avec cmd:fail-exit, toutes les
    # sauvegardes suivant la première échoueraient. On neutralise donc l'échec
    # de cette commande précise, sans désactiver fail-exit pour le reste.
    cmds+="mkdir -p -f ${rdir};"
    cmds+="cd ${rdir};"
    cmds+="put -c \"${ARCHIVE_PATH}\" -o \"${name}.part\";"
    cmds+="mv \"${name}.part\" \"${name}\";"
    [[ -f "${ARCHIVE_PATH}.sha256" ]] && cmds+="put \"${ARCHIVE_PATH}.sha256\" -o \"${name}.sha256\";"
    cmds+="exit"
    run_lftp "${cmds}" || die "Échec de l'envoi vers le FTP." 4
  else
    local base_url="ftp://${FTP_HOST}:${FTP_PORT}${rdir}/"
    local -a auth=() ; mapfile -t auth < <(curl_auth_args)
    local -a opts=("${auth[@]}" --ftp-create-dirs --silent --show-error --fail)
    [[ "${FTP_PROTOCOL}" == "ftps" ]] && opts+=(--ssl-reqd)
    [[ "${FTP_VERIFY_CERT}" == "no" ]] && opts+=(--insecure)
    (( BANDWIDTH_LIMIT_KB > 0 )) && opts+=(--limit-rate "${BANDWIDTH_LIMIT_KB}K")

    curl "${opts[@]}" -T "${ARCHIVE_PATH}" "${base_url}${name}" \
      || die "Échec de l'envoi vers le FTP." 4
    [[ -f "${ARCHIVE_PATH}.sha256" ]] && curl "${opts[@]}" -T "${ARCHIVE_PATH}.sha256" "${base_url}${name}.sha256" || true
  fi

  log_ok "Envoyé : ${rdir}/${name}"
}

# ============================================================================
#  Rotation grand-père / père / fils
#  Une archive est « annuelle » si elle date du 1er janvier, « mensuelle » le
#  1er du mois, « hebdomadaire » le dimanche, « quotidienne » sinon. Chaque
#  catégorie a son propre quota, ce qui donne une profondeur d'historique
#  élevée pour un coût de stockage faible.
# ============================================================================
list_remote_archives() {
  local rdir ; rdir="$(remote_dir)"
  # Le motif doit accepter les deux conventions de nommage : "_latest" en mode
  # snapshot, "_AAAA-MM-JJ_HHMMSS" en mode history. Un motif uniquement daté
  # ferait apparaître --list comme vide sur une installation en snapshot.
  local pattern="^${SERVER_NAME}_([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}|latest)\."
  if [[ "${TRANSFER_TOOL}" == "lftp" ]]; then
    run_lftp "cd ${rdir}; cls -1; exit" 2>/dev/null \
      | grep -E "${pattern}" \
      | grep -v '\.sha256$' | grep -v '\.part$' | sort || true
  else
    local -a auth=() ; mapfile -t auth < <(curl_auth_args)
    curl -sS "${auth[@]}" --list-only \
      "ftp://${FTP_HOST}:${FTP_PORT}${rdir}/" 2>/dev/null \
      | grep -E "${pattern}" \
      | grep -v '\.sha256$' | grep -v '\.part$' | sort || true
  fi
}

archive_tier() {
  # Détermine la catégorie de rétention depuis la date encodée dans le nom.
  local name="$1"

  # L'archive "_latest" du mode snapshot n'a pas de date : elle est protégée
  # et ne doit jamais être considérée comme candidate à la suppression.
  if [[ "${name}" == "${SERVER_NAME}_latest."* ]]; then
    echo "snapshot"
    return 0
  fi

  local date_part
  date_part="$(sed -E "s/^${SERVER_NAME}_([0-9]{4}-[0-9]{2}-[0-9]{2})_.*/\1/" <<<"${name}")"
  local yy mm dd dow
  yy="${date_part:0:4}" ; mm="${date_part:5:2}" ; dd="${date_part:8:2}"

  # Jour de la semaine : `date -d` est une extension GNU, absente sur BSD/macOS,
  # et `date -j` est propre à BSD. Un échec silencieux classerait toutes les
  # archives en "daily" et ferait disparaître la rétention long terme. On
  # essaie les deux, puis on retombe sur le calcul de Sakamoto — sans
  # dépendance, valable pour toute date grégorienne.
  dow="$(date -d "${date_part}" +%u 2>/dev/null \
      || date -j -f '%Y-%m-%d' "${date_part}" +%u 2>/dev/null \
      || echo '')"

  if ! [[ "${dow}" =~ ^[1-7]$ ]]; then
    local y="${yy#0}" m="${mm#0}" d="${dd#0}"
    local -a t=(0 3 2 5 0 3 5 1 4 6 2 4)
    (( m < 3 )) && y=$(( y - 1 ))
    local w=$(( ( y + y/4 - y/100 + y/400 + t[m-1] + d ) % 7 ))
    # Sakamoto renvoie 0 pour dimanche ; on convertit au format ISO (1=lundi..7=dimanche).
    dow=$(( w == 0 ? 7 : w ))
  fi

  if [[ "${mm}" == "01" && "${dd}" == "01" ]]; then echo "yearly"
  elif [[ "${dd}" == "01" ]];                  then echo "monthly"
  elif [[ "${dow}" == "7" ]];                  then echo "weekly"
  else                                              echo "daily"
  fi
}

rotate_remote() {
  # En mode snapshot il n'y a qu'une archive, écrasée à chaque exécution :
  # rien à faire tourner.
  if [[ "${BACKUP_MODE}" == "snapshot" ]]; then
    log_info "Mode snapshot : une seule archive conservée, pas de rotation."
    return 0
  fi

  log_step "Rotation des archives distantes"

  if [[ "${TRANSFER_TOOL}" != "lftp" ]]; then
    log_warn "Rotation impossible sans lftp — pense à purger le FTP manuellement."
    return 0
  fi
  if [[ "${DRY_RUN}" == "yes" ]]; then
    log_info "[dry-run] Rotation non effectuée."
    return 0
  fi

  local -a all=()
  mapfile -t all < <(list_remote_archives)
  if (( ${#all[@]} == 0 )); then
    log_info "Aucune archive distante à faire tourner."
    return 0
  fi

  # Les plus récentes d'abord, pour garder les N premières de chaque catégorie.
  local -a sorted=()
  mapfile -t sorted < <(printf '%s\n' "${all[@]}" | sort -r)

  # Compteurs en variables simples plutôt qu'en tableau associatif : declare -A
  # exige bash 4, absent de bash 3.2 (macOS, vieux systèmes). Une rotation qui
  # plante laisse les archives s'accumuler indéfiniment sur le FTP.
  local kept_daily=0 kept_weekly=0 kept_monthly=0 kept_yearly=0
  local -a to_delete=()
  local a tier keep

  for a in "${sorted[@]}"; do
    tier="$(archive_tier "${a}")"
    keep="no"
    case "${tier}" in
      # Une archive "_latest" laissée par un passage en mode snapshot ne doit
      # jamais être supprimée par la rotation : c'est peut-être la seule
      # sauvegarde complète présente sur le FTP.
      snapshot) keep="yes" ;;
      daily)   (( kept_daily   < KEEP_DAILY   )) && { kept_daily=$((   kept_daily   + 1 )); keep="yes"; } ;;
      weekly)  (( kept_weekly  < KEEP_WEEKLY  )) && { kept_weekly=$((  kept_weekly  + 1 )); keep="yes"; } ;;
      monthly) (( kept_monthly < KEEP_MONTHLY )) && { kept_monthly=$(( kept_monthly + 1 )); keep="yes"; } ;;
      yearly)  (( kept_yearly  < KEEP_YEARLY  )) && { kept_yearly=$((  kept_yearly  + 1 )); keep="yes"; } ;;
    esac
    [[ "${keep}" == "no" ]] && to_delete+=("${a}")
  done

  log_info "Conservées — quotidiennes:${kept_daily} hebdo:${kept_weekly} mensuelles:${kept_monthly} annuelles:${kept_yearly}"

  if (( ${#to_delete[@]} == 0 )); then
    log_ok "Aucune archive à supprimer."
    return 0
  fi

  local rdir ; rdir="$(remote_dir)"
  local cmds="cd ${rdir};"
  for a in "${to_delete[@]}"; do
    # fail-exit désactivé : un fichier .sha256 absent ne doit pas tout stopper.
    cmds+="rm -f \"${a}\"; rm -f \"${a}.sha256\";"
  done
  cmds+="exit"

  # Comme run_lftp : identifiants par stdin pour ne pas les exposer dans `ps`.
  # fail-exit est retiré ici — un .sha256 déjà absent ne doit pas interrompre
  # la purge des archives suivantes.
  if printf '%s\nopen -u %s,%s -p %s %s://%s\n%s\n' \
       "$(lftp_settings | sed 's/set cmd:fail-exit yes;//')" \
       "${FTP_USER}" "${FTP_PASS}" "${FTP_PORT}" \
       "$(ftp_url_scheme)" "${FTP_HOST}" "${cmds}" \
     | lftp 2>/dev/null; then
    log_ok "${#to_delete[@]} archive(s) obsolète(s) supprimée(s) du FTP."
  else
    log_warn "La rotation distante a partiellement échoué — sans conséquence sur la sauvegarde du jour."
  fi
}

rotate_local() {
  [[ "${DRY_RUN}" == "yes" ]] && return 0
  local -a locals=()
  mapfile -t locals < <(find "${WORK_DIR}" -maxdepth 1 -name "${SERVER_NAME}_*" ! -name '*.sha256' -type f 2>/dev/null | sort -r)
  local i
  for (( i = KEEP_LOCAL; i < ${#locals[@]}; i++ )); do
    rm -f -- "${locals[i]}" "${locals[i]}.sha256"
  done
  (( ${#locals[@]} > KEEP_LOCAL )) && \
    log_info "$(( ${#locals[@]} - KEEP_LOCAL )) copie(s) locale(s) supprimée(s) (KEEP_LOCAL=${KEEP_LOCAL})."
  return 0
}

# ============================================================================
#  Notifications
# ============================================================================
notify() {
  local status="$1" ; shift
  local message="$1"

  [[ "${status}" == "success" && "${NOTIFY_ON_SUCCESS}" != "yes" ]] && return 0

  local emoji="✅" ; [[ "${status}" == "failure" ]] && emoji="🚨"
  local text="${emoji} Sauvegarde *${SERVER_NAME}* — ${message}"

  if [[ -n "${NOTIFY_WEBHOOK}" ]] && have curl; then
    curl -sS -m 15 -X POST -H 'Content-Type: application/json' \
      -d "$(printf '{"text":%s}' "$(printf '%s' "${text}" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/')")" \
      "${NOTIFY_WEBHOOK}" >/dev/null 2>&1 || true
  fi

  if [[ -n "${NOTIFY_EMAIL}" ]] && have mail; then
    printf '%s\n' "${text}" | mail -s "[Backup ${status}] ${SERVER_NAME}" "${NOTIFY_EMAIL}" 2>/dev/null || true
  fi
  return 0
}

# ============================================================================
#  Modes secondaires
# ============================================================================
do_check() {
  check_prerequisites
  validate_config
  collect_secret_patterns
  test_connection || exit 2

  log_step "Chemins configurés"
  local p total=0
  while IFS= read -r p; do
    p="$(echo "${p}" | xargs)"
    [[ -z "${p}" || "${p}" == \#* ]] && continue
    if [[ -e "${p}" ]]; then
      local size ; size="$(du -sh "${p}" 2>/dev/null | cut -f1 || echo '?')"
      printf '  %s %-32s %s\n' "${C_GRN}✓${C_OFF}" "${p}" "${size}" >&2
      ((total++))
    else
      printf '  %s %-32s %s\n' "${C_YEL}✗${C_OFF}" "${p}" "absent" >&2
    fi
  done <<<"${INCLUDE_PATHS}"

  if [[ "${EXCLUDE_SECRETS}" == "yes" ]]; then
    log_info "Protection des secrets : ${#SECRET_PATTERNS[@]} motif(s) actifs, scan de contrôle = ${SECRET_SCAN_ACTION}."
  else
    log_warn "Protection des secrets DÉSACTIVÉE sur une archive non chiffrée."
  fi

  local avail
  avail="$(df -h "${WORK_DIR%/*}" 2>/dev/null | awk 'NR==2{print $4}' || echo '?')"
  log_info "Espace libre sur ${WORK_DIR} : ${avail}"
  log_ok "Vérification terminée : ${total} chemin(s) prêt(s) à être sauvegardé(s)."
}

do_list() {
  check_prerequisites
  log_step "Archives présentes sur ${FTP_HOST}$(remote_dir)"
  local -a arr=()
  mapfile -t arr < <(list_remote_archives)
  if (( ${#arr[@]} == 0 )); then
    log_warn "Aucune archive trouvée."
    return 0
  fi
  local a
  for a in "${arr[@]}"; do
    printf '  %-52s [%s]\n' "${a}" "$(archive_tier "${a}")" >&2
  done
  log_ok "${#arr[@]} archive(s)."
}

do_restore() {
  check_prerequisites
  local name="${RESTORE_TARGET}"
  local dest="${WORK_DIR}/restore"

  # Le nom d'archive vient de la ligne de commande : il ne doit pas pouvoir
  # faire écrire hors du dossier de restauration. Un nom du type
  # "../../etc/passwd" détournerait sinon la destination de téléchargement.
  if [[ "${name}" != "$(basename "${name}")" ]] || [[ "${name}" == .* ]]; then
    die "Nom d'archive invalide : '${name}'. Attendu : un nom de fichier simple, sans chemin." 1
  fi
  if ! [[ "${name}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    die "Nom d'archive invalide : '${name}'. Caractères autorisés : lettres, chiffres, . _ -" 1
  fi

  mkdir -p "${dest}"

  # Rappel du sens unique : on télécharge dans un dossier de travail isolé.
  # Rien n'est écrit dans /etc, /var/www ou ailleurs sur le système.
  log_info "Destination de téléchargement : ${dest} (aucun fichier système ne sera modifié)."
  log_step "Téléchargement de ${name}"
  if [[ "${TRANSFER_TOOL}" == "lftp" ]]; then
    run_lftp "cd $(remote_dir); get -c \"${name}\" -o \"${dest}/${name}\"; exit" \
      || die "Téléchargement impossible : ${name}" 4
  else
    local -a auth=() ; mapfile -t auth < <(curl_auth_args)
    curl -sS --fail "${auth[@]}" \
      -o "${dest}/${name}" "ftp://${FTP_HOST}:${FTP_PORT}$(remote_dir)/${name}" \
      || die "Téléchargement impossible : ${name}" 4
  fi
  log_ok "Téléchargé : ${dest}/${name}"

  # Vérification d'intégrité si la somme de contrôle est disponible.
  if run_lftp "cd $(remote_dir); get \"${name}.sha256\" -o \"${dest}/${name}.sha256\"; exit" 2>/dev/null; then
    local expected actual
    expected="$(cat "${dest}/${name}.sha256")"
    actual="$(sha256sum "${dest}/${name}" 2>/dev/null | awk '{print $1}')"
    if [[ "${expected}" == "${actual}" ]]; then
      log_ok "Intégrité vérifiée (SHA-256 conforme)."
    else
      log_warn "SHA-256 différent — l'archive est peut-être corrompue ou incomplète."
    fi
  fi

  # On n'extrait pas : écraser /etc sur un système en marche le casserait.
  # printf plutôt qu'un heredoc : les apostrophes du texte français ne doivent
  # pas être interprétées par bash.
  local f="${dest}/${name}"
  printf '\n%sArchive telechargee. Aucun fichier du serveur na ete modifie.%s\n' \
    "${C_GRN}" "${C_OFF}"
  printf 'Elle nest volontairement PAS extraite : ecraser /etc sur un systeme en\n'
  printf 'marche le casserait. Lextraction reste une decision manuelle.\n\n'
  printf 'Etapes recommandees :\n\n'
  printf '  # 1. Inspecter le contenu\n  tar -tvf "%s" | less\n\n' "${f}"
  printf '  # 2. Lire etat systeme : paquets, services, pare-feu, versions\n'
  printf '  tar -xOf "%s" _system-state/00-INFO.txt\n\n' "${f}"
  if [[ "${EXCLUDE_SECRETS}" == "yes" ]]; then
    printf '  # 3. IMPORTANT : liste des secrets exclus, a regenerer\n'
    printf '  tar -xOf "%s" _system-state/SECRETS-EXCLUS.txt | less\n\n' "${f}"
  fi
  printf '  # 4. Extraire dans un dossier neutre pour comparer avant application\n'
  printf '  mkdir -p /tmp/restore && tar -xf "%s" -C /tmp/restore\n\n' "${f}"
  printf '  # 5. Restaurer un chemin precis, droits et proprietaires conserves\n'
  printf '  tar -xf "%s" -C / --numeric-owner var/www\n\n' "${f}"
}

do_install_cron() {
  local target="/etc/cron.d/server-backup"
  local script_path="${SCRIPT_DIR}/${SCRIPT_NAME}"

  [[ "${EUID}" -eq 0 ]] || die "L'installation du cron nécessite root." 1

  cat >"${target}" <<EOF
# Sauvegarde serveur -> FTP — installé par ${SCRIPT_NAME} v${SCRIPT_VERSION}
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""

# Tous les jours a 03h17. Un horaire decale evite le pic de charge de 3h00,
# quand la plupart des serveurs lancent leurs taches en meme temps.
#
# La sortie va dans le log du script plutot que dans /dev/null : sans cela,
# un echec ne laisserait aucune trace exploitable si NOTIFY_WEBHOOK n'est pas
# configure. Le script fait tourner ce fichier au-dela de 5 Mo.
17 3 * * * root ${script_path} >>${LOG_FILE} 2>&1
EOF
  chmod 644 "${target}"
  log_ok "Cron installé : ${target}"
  log_info "Sauvegarde quotidienne à 03h17. Édite ${target} pour changer l'horaire."
}

# ============================================================================
#  Sauvegarde complète
# ============================================================================
do_backup() {
  check_prerequisites
  validate_config
  collect_secret_patterns
  acquire_lock

  log_info "═══ Sauvegarde de ${SERVER_NAME} — ${SCRIPT_NAME} v${SCRIPT_VERSION} ═══"
  [[ "${DRY_RUN}" == "yes" ]] && log_warn "MODE DRY-RUN : aucune archive ne sera envoyée."

  # Vérifier le FTP AVANT de passer une heure à construire une archive qui ne
  # pourrait pas partir.
  if [[ "${DRY_RUN}" != "yes" ]]; then
    test_connection || die "FTP injoignable — sauvegarde annulée avant archivage." 4
  fi

  mkdir -p "${WORK_DIR}" && chmod 700 "${WORK_DIR}"

  # Un SIGKILL, une coupure de courant ou un OOM-killer ne déclenchent aucun
  # trap : des staging et des archives intermédiaires peuvent survivre et
  # remplir le disque au fil des exécutions. On balaie ce qui est assez vieux
  # pour ne plus appartenir à une exécution en cours (le verrou garantit
  # l'unicité, donc tout résidu ici est forcément orphelin).
  local leftovers
  leftovers="$(find "${WORK_DIR}" -maxdepth 1 \( -name 'staging.*' -o -name '.build-*' \) -mmin +60 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${leftovers}" =~ ^[0-9]+$ ]] && (( leftovers > 0 )); then
    log_warn "${leftovers} résidu(s) d'une exécution interrompue : nettoyage."
    find "${WORK_DIR}" -maxdepth 1 \( -name 'staging.*' -o -name '.build-*' \) -mmin +60 \
      -exec rm -rf {} + 2>/dev/null || true
  fi

  STAGING_DIR="$(mktemp -d "${WORK_DIR}/staging.XXXXXX")"
  chmod 700 "${STAGING_DIR}"

  capture_system_state
  write_secrets_manifest
  dump_databases
  build_archive
  verify_archive
  scan_archive_for_secrets
  upload_archive
  rotate_remote
  rotate_local

  local elapsed=$(( $(date +%s) - START_EPOCH ))
  local size="n/a"
  [[ -f "${ARCHIVE_PATH}" ]] && size="$(du -h "${ARCHIVE_PATH}" | cut -f1)"

  local summary="terminée en $(( elapsed / 60 ))m$(( elapsed % 60 ))s — ${size} — $(basename "${ARCHIVE_PATH}")"
  if (( ${#WARNINGS[@]} > 0 )); then
    summary+=" — ${#WARNINGS[@]} avertissement(s)"
  fi

  log_ok "═══ Sauvegarde ${summary} ═══"
  notify "success" "${summary}"
}

# ============================================================================
#  Aide et arguments
# ============================================================================
usage() {
  # Heredoc quoté : les apostrophes du texte français ne sont pas interprétées
  # par bash. Les variables sont donc injectées via printf plutôt qu'en ligne.
  printf '%s v%s — sauvegarde serveur vers FTP/FTPS/SFTP\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}"
  printf '\nUSAGE\n  %s [options]\n' "${SCRIPT_NAME}"
  cat <<'EOF'

OPTIONS
  --config <fichier>     Chemin du fichier de configuration
  --dry-run              Simule sans créer ni envoyer d'archive
  --check                Vérifie prérequis, configuration et connexion FTP
  --list                 Liste les archives présentes sur le FTP
  --restore <archive>    Télécharge une archive (sans extraction)
  --install-cron         Installe la tâche cron quotidienne
  -h, --help             Affiche cette aide

MODÈLE DE SÉCURITÉ
  Archive NON chiffrée : restauration par un simple tar -xf, sans passphrase
  à retrouver le jour du crash.

  EXCLUDE_SECRETS="no"  (defaut) : archive complète, secrets inclus. Permet
      une restauration intégrale sans rien régénérer. Suppose que le FTP est
      un espace de confiance : quiconque lit une archive obtient /etc/shadow
      et les clés privées SSH/TLS, donc le contrôle du serveur.
  EXCLUDE_SECRETS="yes" : les secrets sont retirés et listés dans
      _system-state/SECRETS-EXCLUS.txt, avec la procédure pour les régénérer.
      À utiliser si le FTP est mutualisé ou hors de ton contrôle.

  Dans les deux cas, préfère FTP_PROTOCOL="ftps" ou "sftp" : en FTP clair,
  archive et mot de passe circulent en clair sur le réseau.

CONFIGURATION
  Recherchée dans l'ordre :
EOF
  printf '    %s\n' "${CONFIG_CANDIDATES[@]}"
  cat <<'EOF'

PREMIÈRE INSTALLATION
  install -d -m 700 /etc/server-backup
  cp backup.conf.example /etc/server-backup/backup.conf
  chmod 600 /etc/server-backup/backup.conf
  $EDITOR /etc/server-backup/backup.conf
EOF
  printf '  ./%s --check\n  ./%s --dry-run\n  ./%s\n  sudo ./%s --install-cron\n' \
    "${SCRIPT_NAME}" "${SCRIPT_NAME}" "${SCRIPT_NAME}" "${SCRIPT_NAME}"
  cat <<'EOF'

CODES DE SORTIE
  0 succès · 1 config · 2 prérequis · 3 archivage · 4 upload
  5 déjà en cours · 6 secret détecté dans une archive
EOF
}

main() {
  while (( $# > 0 )); do
    case "$1" in
      --config)        CONFIG_FILE="${2:?--config attend un chemin}" ; shift 2 ;;
      --dry-run)       DRY_RUN="yes" ; shift ;;
      --check)         MODE="check" ; shift ;;
      --list)          MODE="list" ; shift ;;
      --restore)       MODE="restore" ; RESTORE_TARGET="${2:?--restore attend un nom darchive}" ; shift 2 ;;
      --install-cron)  MODE="install-cron" ; shift ;;
      -h|--help)       usage ; exit 0 ;;
      *)               log_error "Option inconnue : $1" ; usage ; exit 1 ;;
    esac
  done

  if [[ "${MODE}" != "install-cron" ]]; then
    load_config
    rotate_own_log
  else
    # install-cron n'exige pas une configuration valide, mais le fichier cron
    # généré référence LOG_FILE : sans ce chargement, il pointerait vers le
    # chemin par défaut au lieu de celui réellement configuré.
    local candidate
    for candidate in "${CONFIG_FILE:-}" "${CONFIG_CANDIDATES[@]}"; do
      if [[ -n "${candidate}" && -r "${candidate}" ]]; then
        # shellcheck disable=SC1090
        source "${candidate}" 2>/dev/null || true
        break
      fi
    done
  fi

  # Filet de sécurité : un serveur injoignable ou un tar bloqué ne doit pas
  # laisser un processus tourner jusqu'au cron suivant.
  if (( TIMEOUT_SECONDS > 0 )) && [[ "${MODE}" == "backup" ]] && [[ -z "${_BACKUP_TIMEBOXED:-}" ]] && have timeout; then
    export _BACKUP_TIMEBOXED=1
    # --foreground : sans lui, `timeout` place l'enfant dans son propre groupe
    # de processus et un SIGTERM reçu de l'extérieur (kill, arrêt système) ne
    # lui parvient jamais. Le trap de nettoyage ne s'exécuterait pas et le
    # verrou survivrait, bloquant toutes les sauvegardes suivantes.
    exec timeout --foreground --signal=TERM --kill-after=60 "${TIMEOUT_SECONDS}" \
      "${BASH_SOURCE[0]}" ${CONFIG_FILE:+--config "${CONFIG_FILE}"} \
      $([[ "${DRY_RUN}" == "yes" ]] && echo --dry-run)
  fi

  case "${MODE}" in
    backup)       do_backup ;;
    check)        do_check ;;
    list)         do_list ;;
    restore)      do_restore ;;
    install-cron) do_install_cron ;;
  esac
}

main "$@"
