#!/usr/bin/env bash
# lib/bootstrap.sh — 첫 실행 import

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
  docker_count=$(iptables -S DOCKER-USER 2>/dev/null | grep -c '^-A ' || echo 0)
  output_count=$(iptables -S OUTPUT 2>/dev/null | grep -c '^-A ' || true)

  info "  INPUT 규칙:        ${input_count}개"
  info "  DOCKER-USER 규칙:  ${docker_count}개"
  info "  OUTPUT 규칙:       ${output_count}개"

  # OUTPUT ACCEPT/기타 경고
  local output_accept
  output_accept=$(iptables -S OUTPUT 2>/dev/null | grep -c 'j ACCEPT' || echo 0)
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
