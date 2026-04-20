#!/usr/bin/env bash
# lib/rollback.sh — 백업 목록 표시 + 선택 복원

rollback_list() {
  local -a paths
  mapfile -t paths < <(ls -1t "$FW_BACKUP_DIR"/*.tar.gz 2>/dev/null)
  [[ ${#paths[@]} -eq 0 ]] && { info "(백업 없음)"; return 0; }
  local i p
  for i in "${!paths[@]}"; do
    p="${paths[$i]}"
    local base; base=$(basename "$p" .tar.gz)
    printf '  %2d) %s\n' "$((i+1))" "$base" >&2
  done
}

rollback_menu() {
  local -a paths
  mapfile -t paths < <(ls -1t "$FW_BACKUP_DIR"/*.tar.gz 2>/dev/null)
  if [[ ${#paths[@]} -eq 0 ]]; then
    info "백업 없음"
    return 0
  fi

  local -a labels
  local p
  for p in "${paths[@]}"; do
    labels+=("$(basename "$p" .tar.gz)")
  done

  local idx
  idx=$(arrow_menu "복원할 백업 선택 (q=취소):" "${labels[@]}") || return 0
  (( idx < 0 )) && return 0

  confirm "'${labels[$idx]}' 으로 복원합니다. 현재 상태는 별도로 백업됩니다. 진행?" N || return 0

  persist_backup "pre-rollback" >/dev/null
  persist_rollback_to "${paths[$idx]}" || return 1
  ok "복원 완료"
}

# 비대화형: rollback_by_index N (1-based)
rollback_by_index() {
  local n="$1"
  local -a paths
  mapfile -t paths < <(ls -1t "$FW_BACKUP_DIR"/*.tar.gz 2>/dev/null)
  if [[ ${#paths[@]} -eq 0 ]]; then
    err "백업 없음"; return 1
  fi
  if [[ -z "$n" || "$n" -lt 1 || "$n" -gt ${#paths[@]} ]]; then
    err "유효하지 않은 인덱스: $n (1-${#paths[@]})"
    return 1
  fi
  local target="${paths[$((n-1))]}"
  persist_backup "pre-rollback" >/dev/null
  persist_rollback_to "$target"
}
