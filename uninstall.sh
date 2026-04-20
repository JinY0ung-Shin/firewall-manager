#!/usr/bin/env bash
# uninstall.sh — firewall-manager 시스템 제거

set -u

INSTALL_PREFIX="/opt/firewall-manager"
DATA_DIR="/var/lib/fw-manager"
WRAPPER="/usr/local/bin/fw"

die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
info() { printf '  %s\n' "$*" >&2; }
ok()   { printf '\033[32m✓ %s\033[0m\n' "$*" >&2; }

[[ $EUID -eq 0 ]] || die "root 권한 필요"

printf '\n==== firewall-manager 제거 ====\n\n' >&2

# 1. 래퍼
if [[ -e "$WRAPPER" ]]; then
  rm -f "$WRAPPER"
  ok "$WRAPPER 제거"
else
  info "$WRAPPER 없음 — 건너뜀"
fi

# 2. /opt 레포
printf '\n' >&2
if [[ -d "$INSTALL_PREFIX" ]]; then
  read -r -p "$INSTALL_PREFIX 도 삭제할까요? [y/N] " r || r=""
  if [[ "$r" =~ ^[Yy]$ ]]; then
    rm -rf "$INSTALL_PREFIX"
    ok "$INSTALL_PREFIX 삭제"
  else
    info "$INSTALL_PREFIX 유지"
  fi
fi

# 3. 데이터/백업
printf '\n' >&2
if [[ -d "$DATA_DIR" ]]; then
  printf '주의: $DATA_DIR 안에는 방화벽 설정과 백업이 들어있습니다. 삭제하면 복원 불가.\n' >&2
  read -r -p "$DATA_DIR 를 삭제할까요? [y/N] " r || r=""
  if [[ "$r" =~ ^[Yy]$ ]]; then
    rm -rf "$DATA_DIR"
    ok "$DATA_DIR 삭제"
  else
    info "$DATA_DIR 유지"
  fi
fi

printf '\n' >&2
ok "제거 완료"
