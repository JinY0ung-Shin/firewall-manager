#!/usr/bin/env bash
# install.sh - install fw system-wide

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BIN_DIR="${BIN_DIR:-/usr/local/bin}"
LIB_DIR="${LIB_DIR:-/usr/local/lib/fw}"
CONFIG_DIR="${CONFIG_DIR:-/etc/fw}"
COPY_CONFIG=false

usage() {
    cat <<EOF
Usage: sudo ./install.sh [--copy-config] [--help]

Options:
  --copy-config   Copy current config/ contents into ${CONFIG_DIR}
  --help          Show this help

Environment overrides:
  BIN_DIR         Install directory for the fw executable
  LIB_DIR         Install directory for lib/*.sh
  CONFIG_DIR      Installed config directory
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --copy-config)
            COPY_CONFIG=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "This installer must be run as root." >&2
    exit 1
fi

if [[ ! -f "${SCRIPT_DIR}/fw" || ! -d "${SCRIPT_DIR}/lib" ]]; then
    echo "Could not find fw or lib/ in ${SCRIPT_DIR}" >&2
    exit 1
fi

install -d "${BIN_DIR}" "${LIB_DIR}" "${CONFIG_DIR}" "${CONFIG_DIR}/teams" "${CONFIG_DIR}/backups"

install -m 0755 "${SCRIPT_DIR}/fw" "${BIN_DIR}/fw"

for file in "${SCRIPT_DIR}"/lib/*.sh; do
    install -m 0644 "${file}" "${LIB_DIR}/$(basename "${file}")"
done

if ${COPY_CONFIG}; then
    if [[ -f "${SCRIPT_DIR}/config/iptables.rules" ]]; then
        install -m 0644 "${SCRIPT_DIR}/config/iptables.rules" "${CONFIG_DIR}/iptables.rules"
    fi

    if [[ -f "${SCRIPT_DIR}/config/iptables-full.rules" ]]; then
        install -m 0644 "${SCRIPT_DIR}/config/iptables-full.rules" "${CONFIG_DIR}/iptables-full.rules"
    fi

    shopt -s nullglob
    team_files=("${SCRIPT_DIR}/config/teams/"*.conf)
    if (( ${#team_files[@]} > 0 )); then
        cp -a "${team_files[@]}" "${CONFIG_DIR}/teams/"
    fi

    backup_dirs=("${SCRIPT_DIR}/config/backups/"*)
    if (( ${#backup_dirs[@]} > 0 )); then
        cp -a "${backup_dirs[@]}" "${CONFIG_DIR}/backups/"
    fi
    shopt -u nullglob
fi

cat <<EOF

fw installed successfully.

  executable: ${BIN_DIR}/fw
  libraries : ${LIB_DIR}
  config    : ${CONFIG_DIR}

Next steps:
  1) Run 'sudo fw --help'
  2) If migrating an existing server, copy or export the saved config
  3) Run 'sudo fw preflight' before 'sudo fw load'

EOF
