#!/usr/bin/env bash
# lib/persist.sh — 백업/덤프/복원 3종 + 트랜잭션 래퍼

FW_CONFIG_DIR=${FW_CONFIG_DIR:-./config}
FW_BACKUP_DIR="$FW_CONFIG_DIR/backups"
FW_IPTABLES_FILE="$FW_CONFIG_DIR/iptables.rules"
FW_IPSETS_FILE="$FW_CONFIG_DIR/ipsets.rules"
FW_BACKUP_KEEP=${FW_BACKUP_KEEP:-20}

# ── 백업 ──────────────────────────────────────────────────
# persist_backup [LABEL]  → 생성된 백업의 전체 경로를 stdout
persist_backup() {
  local label="${1:-auto}"
  mkdir -p "$FW_BACKUP_DIR"
  local ts
  ts=$(date +%Y-%m-%d_%H-%M-%S)
  local path="$FW_BACKUP_DIR/${ts}_${label}.tar.gz"

  # config/ 안에서 backups 제외하고 tar
  tar -czf "$path" -C "$FW_CONFIG_DIR" --exclude='backups' . 2>/dev/null || {
    err "백업 생성 실패: $path"
    return 1
  }

  # rotation
  local count
  count=$(ls -1 "$FW_BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l)
  if (( count > FW_BACKUP_KEEP )); then
    ls -1t "$FW_BACKUP_DIR"/*.tar.gz | tail -n +"$((FW_BACKUP_KEEP + 1))" | xargs -r rm -f
  fi

  echo "$path"
}

# ── live → config 덤프 ────────────────────────────────────
persist_dump_live_to_config() {
  mkdir -p "$FW_CONFIG_DIR"

  # iptables (우리 스코프만) — PIPESTATUS로 iptables-save 실패 감지
  local tmp_ipt; tmp_ipt=$(mktemp)
  iptables-save -t filter 2>/dev/null | scope_filter_iptables > "$tmp_ipt"
  if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
    err "iptables-save 실패"
    rm -f "$tmp_ipt"
    return 1
  fi
  mv "$tmp_ipt" "$FW_IPTABLES_FILE"

  # ipsets (config에 이미 있는 이름들만)
  local tmp_ips; tmp_ips=$(mktemp)
  local -a managed
  mapfile -t managed < <(scope_ipset_names_from_file "$FW_IPSETS_FILE")
  if [[ ${#managed[@]} -eq 0 ]]; then
    : > "$tmp_ips"
  else
    ipset save 2>/dev/null | scope_filter_ipset "${managed[@]}" > "$tmp_ips"
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
      err "ipset save 실패"
      rm -f "$tmp_ips"
      return 1
    fi
  fi
  mv "$tmp_ips" "$FW_IPSETS_FILE"
}

# ── config → live 복원 (순서: ipset 먼저, iptables 나중) ──
persist_restore_from_config() {
  [[ -f "$FW_IPSETS_FILE" ]]    || { err "$FW_IPSETS_FILE 없음"; return 1; }
  [[ -f "$FW_IPTABLES_FILE" ]]  || { err "$FW_IPTABLES_FILE 없음"; return 1; }

  # ipset: `restore -!` 는 이미 존재하는 set을 덮어씀
  if ! ipset restore -! < "$FW_IPSETS_FILE"; then
    err "ipset restore 실패"
    return 1
  fi

  # iptables: --noflush 로 파일에 선언된 체인만 flush
  if ! iptables-restore --noflush < "$FW_IPTABLES_FILE"; then
    err "iptables-restore 실패"
    return 1
  fi
}

# ── 백업에서 롤백 ──────────────────────────────────────────
# persist_rollback_to BACKUP_PATH
persist_rollback_to() {
  local path="$1"
  [[ -f "$path" ]] || { err "백업 없음: $path"; return 1; }

  local tmp; tmp=$(mktemp -d)
  tar -xzf "$path" -C "$tmp" || { err "백업 추출 실패"; rm -rf "$tmp"; return 1; }

  # config 교체
  cp -f "$tmp/iptables.rules" "$FW_IPTABLES_FILE" 2>/dev/null || true
  cp -f "$tmp/ipsets.rules"   "$FW_IPSETS_FILE"   2>/dev/null || true
  rm -rf "$tmp"

  persist_restore_from_config
}

# ── 트랜잭션 래퍼 ──────────────────────────────────────────
# persist_transaction ACTION_FN ARGS...
#   (1) 백업 → (2) ACTION_FN ARGS... → 실패 시 백업에서 롤백, 성공 시 live→config 덤프
persist_transaction() {
  local action="$1"; shift
  local backup
  backup=$(persist_backup "pre-${action}") || return 1

  if ! "$action" "$@"; then
    err "$action 실패, 백업에서 롤백 중..."
    persist_rollback_to "$backup" || err "자동 롤백도 실패! 수동 복구 필요: $backup"
    return 1
  fi

  if ! persist_dump_live_to_config; then
    err "live→config 덤프 실패, 백업에서 롤백 중..."
    persist_rollback_to "$backup"
    return 1
  fi

  return 0
}
