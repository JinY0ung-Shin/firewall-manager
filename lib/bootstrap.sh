#!/usr/bin/env bash
# lib/bootstrap.sh — 첫 실행 import + 사후 재스캔

# rescan_run
#   live에 있지만 config에 등록 안 된 ipset 을 찾아, 관리 대상 추가 제안.
#   "다른 서버에서 ipset save → scp → ipset restore" 후 이 도구가 해당 set을
#   관리 대상으로 인식하게 만드는 경로.
rescan_run() {
  local -a live_sets
  mapfile -t live_sets < <(ipset list -n 2>/dev/null || true)

  local -a managed_sets
  mapfile -t managed_sets < <(scope_ipset_names_from_file "$FW_IPSETS_FILE")

  local -a unmanaged=()
  local s m found
  for s in "${live_sets[@]}"; do
    [[ -z "$s" ]] && continue
    found=0
    for m in "${managed_sets[@]}"; do
      [[ "$s" == "$m" ]] && { found=1; break; }
    done
    (( found )) || unmanaged+=("$s")
  done

  if [[ ${#unmanaged[@]} -eq 0 ]]; then
    info "live 의 모든 ipset 이 이미 관리 중입니다. 추가할 set 없음."
    return 0
  fi

  info ""
  info "${C_BLD}=== 미관리 ipset 감지 ===${C_RST}"
  info "  live 에 관리되지 않는 set ${#unmanaged[@]}개 발견:"
  info ""

  local selected
  selected=$(checkbox_menu "관리 대상에 추가할 ipset 선택:" "${unmanaged[@]}")
  local -a picked
  for idx in $selected; do
    picked+=("${unmanaged[$idx]}")
  done

  if [[ ${#picked[@]} -eq 0 ]]; then
    info "선택 없음, 중단."
    return 0
  fi

  persist_backup "pre-rescan" >/dev/null || return 1

  # 기존 + 신규 set 이름을 합쳐서 ipset save 필터링 → 전체 재작성
  local -a combined=()
  local name
  for name in "${managed_sets[@]}"; do [[ -n "$name" ]] && combined+=("$name"); done
  for name in "${picked[@]}"; do combined+=("$name"); done

  local tmp; tmp=$(mktemp)
  ipset save 2>/dev/null | scope_filter_ipset "${combined[@]}" > "$tmp"
  if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
    err "ipset save 실패"
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$FW_IPSETS_FILE"

  ok "관리 대상에 추가: ${picked[*]}"
}


# bootstrap_run
#   config/ 가 이미 있으면 아무것도 안 함.
#   없으면 live 스캔 → 체크리스트로 관리할 ipset 선택 → config 생성 + initial backup
bootstrap_run() {
  if [[ -f "$FW_IPTABLES_FILE" && -f "$FW_IPSETS_FILE" ]]; then
    return 0
  fi

  info ""
  info "${C_BLD}=== 첫 실행: 현재 방화벽 상태를 가져옵니다 ===${C_RST}"
  info ""

  mkdir -p "$FW_CONFIG_DIR"

  # iptables 상태 요약
  local input_count docker_count output_count
  input_count=$(iptables -S INPUT 2>/dev/null | grep -c '^-A ' || true)
  docker_count=$(iptables -S DOCKER-USER 2>/dev/null | grep -c '^-A ' || true)
  output_count=$(iptables -S OUTPUT 2>/dev/null | grep -c '^-A ' || true)

  info "  INPUT 규칙:        ${input_count}개"
  info "  DOCKER-USER 규칙:  ${docker_count}개"
  info "  OUTPUT 규칙:       ${output_count}개"

  # OUTPUT ACCEPT/기타 경고
  local output_accept
  output_accept=$(iptables -S OUTPUT 2>/dev/null | grep -c 'j ACCEPT' || true)
  if (( output_accept > 0 )); then
    warn "  OUTPUT에 ACCEPT 규칙 ${output_accept}개가 있습니다."
    warn "  이 규칙들은 도구가 '읽기 전용'으로 보존합니다 (메뉴에서 삭제만 가능)."
  fi

  # 기존 ipset 목록
  local -a all_sets
  mapfile -t all_sets < <(ipset list -n 2>/dev/null || true)

  if [[ ${#all_sets[@]} -eq 0 ]]; then
    info "  ipset: 없음"
    : > "$FW_IPSETS_FILE"
  else
    info "  발견된 ipset: ${#all_sets[@]}개"
    info ""
    local selected
    selected=$(checkbox_menu "관리 대상으로 삼을 ipset을 선택하세요:" "${all_sets[@]}")
    local -a picked
    for idx in $selected; do
      picked+=("${all_sets[$idx]}")
    done

    if [[ ${#picked[@]} -eq 0 ]]; then
      : > "$FW_IPSETS_FILE"
    else
      ipset save 2>/dev/null | scope_filter_ipset "${picked[@]}" > "$FW_IPSETS_FILE"
    fi
  fi

  # iptables 덤프
  iptables-save -t filter 2>/dev/null | scope_filter_iptables > "$FW_IPTABLES_FILE"

  # initial backup
  persist_backup "initial" >/dev/null

  ok "초기 설정 완료."
  info "  config/iptables.rules (${input_count} INPUT, ${docker_count} DOCKER-USER, ${output_count} OUTPUT)"
  info "  config/ipsets.rules"
  info "  config/backups/*_initial.tar.gz"
  info ""
}
