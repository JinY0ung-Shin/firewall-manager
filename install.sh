#!/usr/bin/env bash
# install.sh — firewall-manager 시스템 설치
#
# 수행 내용:
#   1. 이 레포를 /opt/firewall-manager/ 로 복사 (이미 있으면 생략)
#   2. 데이터/백업 디렉토리 /var/lib/fw-manager/ 생성 (0700 root:root)
#   3. 기존 ./config/ 가 있으면 /var/lib/fw-manager/ 로 마이그레이션
#   4. /usr/local/bin/fw 래퍼 스크립트 작성
#
# 이후: 어디에서든 'sudo fw' 로 실행 가능.
# 업데이트: 'sudo git -C /opt/firewall-manager pull'

set -eu

INSTALL_PREFIX="/opt/firewall-manager"
DATA_DIR="/var/lib/fw-manager"
WRAPPER="/usr/local/bin/fw"

die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
info() { printf '  %s\n' "$*" >&2; }
ok()   { printf '\033[32m✓ %s\033[0m\n' "$*" >&2; }

[[ $EUID -eq 0 ]] || die "root 권한 필요 (sudo ./install.sh)"

SRC_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SRC_REPO/fw" && -d "$SRC_REPO/lib" ]] \
  || die "$SRC_REPO 이 firewall-manager 레포로 보이지 않음"

printf '\n==== firewall-manager 시스템 설치 ====\n\n' >&2
info "레포 원본:    $SRC_REPO"
info "설치 대상:    $INSTALL_PREFIX"
info "데이터 디렉:  $DATA_DIR"
info "실행 파일:    $WRAPPER"
printf '\n' >&2

# 1. 레포를 /opt/ 로 복사
if [[ "$SRC_REPO" == "$INSTALL_PREFIX" ]]; then
  info "이미 $INSTALL_PREFIX 에서 실행 중 — 복사 생략"
elif [[ -e "$INSTALL_PREFIX" ]]; then
  info "$INSTALL_PREFIX 이미 존재 — 업데이트는 'sudo git -C $INSTALL_PREFIX pull' 사용"
  info "(이번 설치는 기존 파일을 덮어쓰지 않습니다)"
else
  info "$SRC_REPO → $INSTALL_PREFIX 복사 중..."
  cp -a "$SRC_REPO" "$INSTALL_PREFIX"
  # /opt/ 아래 소유권을 root 로 정리 (cp -a 가 원 소유자 유지하기 때문)
  chown -R root:root "$INSTALL_PREFIX"
  ok "복사 완료"
fi

# 2. 데이터 디렉토리
if [[ ! -d "$DATA_DIR" ]]; then
  mkdir -p "$DATA_DIR/backups"
  chown -R root:root "$DATA_DIR"
  chmod 0700 "$DATA_DIR"
  chmod 0700 "$DATA_DIR/backups"
  ok "$DATA_DIR 생성됨 (0700 root:root)"
else
  info "$DATA_DIR 이미 존재 — 유지"
fi

# 3. 기존 config/ 마이그레이션 (원본 레포 또는 /opt 내부 config)
MIGRATED=0
for src_cfg in "$SRC_REPO/config" "$INSTALL_PREFIX/config"; do
  [[ -d "$src_cfg" ]] || continue
  if [[ -f "$DATA_DIR/iptables.rules" || -f "$DATA_DIR/ipsets.rules" ]]; then
    info "$DATA_DIR 에 이미 데이터 있음 — $src_cfg 유지 (마이그레이션 생략)"
    continue
  fi
  info "$src_cfg → $DATA_DIR 로 마이그레이션 중..."
  # 내용만 복사 (backups/ 포함)
  cp -a "$src_cfg/." "$DATA_DIR/"
  chown -R root:root "$DATA_DIR"
  chmod -R go-rwx "$DATA_DIR"
  # 마이그레이션 원본 제거 (중복 방지) — /opt 아래만 안전하게 제거
  if [[ "$src_cfg" == "$INSTALL_PREFIX/config" ]]; then
    rm -rf "$src_cfg"
  fi
  ok "마이그레이션 완료 ($src_cfg)"
  MIGRATED=1
  break
done

# 4. 래퍼 스크립트
cat > "$WRAPPER" <<EOF
#!/bin/sh
# /usr/local/bin/fw — wrapper installed by install.sh
# 시스템 설치된 firewall-manager 진입점.
export FW_CONFIG_DIR="$DATA_DIR"
exec "$INSTALL_PREFIX/fw" "\$@"
EOF
chmod 0755 "$WRAPPER"
ok "$WRAPPER 작성됨"

printf '\n==== 설치 완료 ====\n\n' >&2
info "사용:       sudo fw          (어디에서든)"
info "상태:       sudo fw status"
info "업데이트:   sudo git -C $INSTALL_PREFIX pull"
info "제거:       sudo $INSTALL_PREFIX/uninstall.sh"

if [[ "$SRC_REPO" != "$INSTALL_PREFIX" ]]; then
  printf '\n' >&2
  info "원본 레포($SRC_REPO) 는 더 이상 필요 없으면 삭제해도 됩니다:"
  info "  rm -rf $SRC_REPO"
fi
printf '\n' >&2
