#!/usr/bin/env bash
# ============================================================================
#  tests-run.sh — lance la batterie de tests de server-backup.sh
#
#  Démarre un serveur FTP local jetable, exécute tests.sh, puis nettoie.
#  Aucun serveur distant n'est contacté : tout se passe sur 127.0.0.1.
#
#  Prérequis : python3, et zstd + lftp (ou curl) comme le script principal.
#              pyftpdlib est installé automatiquement dans un venv temporaire.
# ============================================================================

set -Eeuo pipefail

readonly DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly WORK="${TMPDIR:-/tmp}/server-backup-tests"
readonly FTPROOT="${WORK}/ftproot"
readonly VENV="${WORK}/venv"
readonly PORT="2121"

FTPD_PID=""

cleanup() {
  [[ -n "${FTPD_PID}" ]] && kill "${FTPD_PID}" 2>/dev/null || true
  return 0
}
trap cleanup EXIT INT TERM

command -v python3 >/dev/null || { echo "python3 est requis pour lancer le FTP de test." >&2; exit 2; }

mkdir -p "${FTPROOT}"

# --- Serveur FTP jetable ----------------------------------------------------
if ! "${VENV}/bin/python" -c 'import pyftpdlib' 2>/dev/null; then
  echo "Installation de pyftpdlib dans un venv temporaire…"
  python3 -m venv "${VENV}" >/dev/null 2>&1
  "${VENV}/bin/pip" install -q pyftpdlib >/dev/null 2>&1 \
    || { echo "Échec de l'installation de pyftpdlib." >&2; exit 2; }
fi

cat > "${WORK}/ftpd.py" <<'PY'
import sys
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler
from pyftpdlib.servers import FTPServer

auth = DummyAuthorizer()
auth.add_user("testuser", "testpass", sys.argv[1], perm="elradfmwMT")
handler = FTPHandler
handler.authorizer = auth
handler.passive_ports = range(60000, 60020)
FTPServer(("127.0.0.1", int(sys.argv[2])), handler).serve_forever()
PY

"${VENV}/bin/python" "${WORK}/ftpd.py" "${FTPROOT}" "${PORT}" >"${WORK}/ftpd.log" 2>&1 &
FTPD_PID=$!

# Attendre que le serveur réponde plutôt que de dormir arbitrairement.
for _ in $(seq 1 20); do
  if curl -s --connect-timeout 1 --user testuser:testpass \
       "ftp://127.0.0.1:${PORT}/" --list-only >/dev/null 2>&1; then
    break
  fi
done

if ! curl -s --connect-timeout 2 --user testuser:testpass \
     "ftp://127.0.0.1:${PORT}/" --list-only >/dev/null 2>&1; then
  echo "Le serveur FTP de test n'a pas démarré :" >&2
  cat "${WORK}/ftpd.log" >&2
  exit 2
fi

# --- Tests ------------------------------------------------------------------
FTP_TEST_ROOT="${FTPROOT}" bash "${DIR}/tests.sh"
