#!/bin/sh
# SPDX-License-Identifier: MIT
# launchd creates the session socket at load and
# starts `newtd serve` on first connect.
set -eu

LABEL="org.newt.manager"
PLIST_DEST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
DOMAIN="gui/$(id -u)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/launchd/org.newt.manager.plist.in"
DAEMON="${HOME}/.local/bin/newtd"
UNINSTALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --daemon) DAEMON="$2"; shift 2 ;;
        --uninstall) UNINSTALL=1; shift ;;
        *) echo "usage: $0 [--daemon /path/to/newtd] [--uninstall]" >&2; exit 2 ;;
    esac
done

if [ "${UNINSTALL}" = "1" ]; then
    launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
    rm -f "${PLIST_DEST}"
    echo "Removed ${LABEL}. A running manager (if any) keeps its own socket until stopped."
    exit 0
fi

if [ ! -x "${DAEMON}" ]; then
    echo "error: daemon not executable: ${DAEMON} (build/install Newt first, or pass --daemon)" >&2
    exit 1
fi

IPC_DIR="${NEWT_IPC_DIR:-/tmp/newt-session-$(id -u)}"
STATE_DIR="${NEWT_STATE_DIR:-${HOME}/Library/Application Support/Newt}"
mkdir -p "${IPC_DIR}" "${STATE_DIR}" "${HOME}/Library/LaunchAgents"
chmod 700 "${IPC_DIR}" "${STATE_DIR}"

# Replace separators for sed: paths may contain '/', so use '|' delimiters.
sed -e "s|__NEWT_DAEMON_PATH__|${DAEMON}|g" \
    -e "s|__NEWT_SESSION_SOCK__|${IPC_DIR}/session.sock|g" \
    -e "s|__NEWT_MANAGER_LOG__|${STATE_DIR}/manager.log|g" \
    "${TEMPLATE}" > "${PLIST_DEST}"
plutil -lint "${PLIST_DEST}" >/dev/null

launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
launchctl bootstrap "${DOMAIN}" "${PLIST_DEST}"
echo "Registered ${LABEL}: daemon=${DAEMON} socket=${IPC_DIR}/session.sock"
echo "Verify with: launchctl print ${DOMAIN}/${LABEL}  and  \"${DAEMON}\" status"
echo "Remove with: $0 --uninstall"
