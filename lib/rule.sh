#!/usr/bin/env bash
# lib/rule.sh — iptables 규칙 편집 (INPUT, DOCKER-USER, OUTPUT)

# ── 내부 헬퍼 ──────────────────────────────────────────────
_rule_apply_live() {
  # args: CHAIN ACTION(-A|-D) SPEC...
  local chain="$1" op="$2"; shift 2
  iptables "$op" "$chain" "$@"
}

# ── 대상 입력 헬퍼 ─────────────────────────────────────────
# 결과: stdout에 iptables 매치 옵션 (e.g. "-s 10.0.0.1" 또는 "-m set --match-set team_x src")
_rule_prompt_source() {
  local idx
  idx=$(arrow_menu "소스 종류 선택:" "단일 IP" "CIDR" "팀(ipset)" "전체") || return 1
  (( idx < 0 )) && return 1
  case "$idx" in
    0|1)
      local ip; read -r -p "IP${idx:+/CIDR}: " ip
      [[ -z "$ip" ]] && return 1
      printf -- '-s %s' "$ip"
      ;;
    2)
      local -a teams
      mapfile -t teams < <(team_list_names)
      [[ ${#teams[@]} -eq 0 ]] && { err "팀 없음"; return 1; }
      local tidx; tidx=$(arrow_menu "팀 선택:" "${teams[@]}") || return 1
      (( tidx < 0 )) && return 1
      printf -- '-m set --match-set %s src' "${teams[$tidx]}"
      ;;
    3) printf -- '' ;;
  esac
}

_rule_prompt_destination() {
  local idx
  idx=$(arrow_menu "대상 종류 선택:" "단일 IP" "CIDR" "팀(ipset)") || return 1
  (( idx < 0 )) && return 1
  case "$idx" in
    0|1)
      local ip; read -r -p "IP${idx:+/CIDR}: " ip
      [[ -z "$ip" ]] && return 1
      printf -- '-d %s' "$ip"
      ;;
    2)
      local -a teams
      mapfile -t teams < <(team_list_names)
      [[ ${#teams[@]} -eq 0 ]] && { err "팀 없음"; return 1; }
      local tidx; tidx=$(arrow_menu "팀 선택:" "${teams[@]}") || return 1
      (( tidx < 0 )) && return 1
      printf -- '-m set --match-set %s dst' "${teams[$tidx]}"
      ;;
  esac
}

_rule_prompt_port() {
  local idx
  idx=$(arrow_menu "포트 제한:" "모든 포트" "특정 TCP 포트" "특정 UDP 포트") || return 1
  (( idx < 0 )) && return 1
  case "$idx" in
    0) printf -- '' ;;
    1) local p; read -r -p "TCP 포트: " p; [[ -n "$p" ]] && printf -- '-p tcp --dport %s' "$p" ;;
    2) local p; read -r -p "UDP 포트: " p; [[ -n "$p" ]] && printf -- '-p udp --dport %s' "$p" ;;
  esac
}

# ── INPUT/DOCKER-USER 허용 or 차단 추가 ────────────────────
_rule_add_source_based() {
  local chain="$1" jump="$2"  # jump: ACCEPT | DROP | REJECT
  local src port
  src=$(_rule_prompt_source) || { warn "취소됨"; return 0; }
  port=$(_rule_prompt_port) || { warn "취소됨"; return 0; }

  local spec="$src $port -j $jump"
  spec="${spec//  / }"; spec="${spec# }"
  info "추가할 규칙: iptables -A $chain $spec"
  confirm "진행?" Y || return 0

  if [[ "$jump" == "DROP" || "$jump" == "REJECT" ]]; then
    safety_check_ssh_block "$chain $spec" || return 0
  fi

  local backup; backup=$(persist_backup "pre-rule-add") || return 1
  # shellcheck disable=SC2086
  if ! _rule_apply_live "$chain" -A $spec; then
    err "적용 실패"
    persist_rollback_to "$backup"
    return 1
  fi
  if ! persist_dump_live_to_config; then
    err "config 덤프 실패, 백업에서 롤백 중..."
    persist_rollback_to "$backup"
    return 1
  fi

  if [[ "$jump" == "DROP" || "$jump" == "REJECT" ]]; then
    safety_arm_confirm_timer "$backup" || return 1
  fi
  ok "규칙 추가 완료"
}

# ── OUTPUT 차단 전용 ───────────────────────────────────────
_rule_add_output_block() {
  local dst port
  dst=$(_rule_prompt_destination) || { warn "취소됨"; return 0; }
  port=$(_rule_prompt_port) || { warn "취소됨"; return 0; }

  local jidx
  jidx=$(arrow_menu "동작:" "DROP (조용히 버림)" "REJECT (거절 응답)") || return 0
  (( jidx < 0 )) && return 0
  local jump; case "$jidx" in 0) jump=DROP ;; 1) jump=REJECT ;; esac

  local spec="$dst $port -j $jump"
  spec="${spec//  / }"; spec="${spec# }"
  info "추가할 규칙: iptables -A OUTPUT $spec"
  confirm "진행?" Y || return 0

  local backup; backup=$(persist_backup "pre-output-block") || return 1
  # shellcheck disable=SC2086
  if ! _rule_apply_live OUTPUT -A $spec; then
    err "적용 실패"
    persist_rollback_to "$backup"
    return 1
  fi
  if ! persist_dump_live_to_config; then
    err "config 덤프 실패, 백업에서 롤백 중..."
    persist_rollback_to "$backup"
    return 1
  fi
  ok "OUTPUT 차단 규칙 추가 완료"
}

# ── 규칙 삭제 (목록에서 선택) ──────────────────────────────
_rule_delete_from_chain() {
  local chain="$1"
  local -a rules
  mapfile -t rules < <(iptables -S "$chain" 2>/dev/null | grep '^-A ' | sed "s/^-A $chain //")
  if [[ ${#rules[@]} -eq 0 ]]; then
    warn "$chain 에 삭제할 규칙 없음"
    return 0
  fi

  local idx
  idx=$(arrow_menu "$chain — 삭제할 규칙 선택 (q=취소):" "${rules[@]}") || return 0
  (( idx < 0 )) && return 0
  local spec="${rules[$idx]}"

  info "삭제: iptables -D $chain $spec"
  confirm "진행?" Y || return 0

  local backup; backup=$(persist_backup "pre-rule-delete") || return 1
  # shellcheck disable=SC2086
  if ! iptables -D "$chain" $spec; then
    err "삭제 실패"
    persist_rollback_to "$backup"
    return 1
  fi
  if ! persist_dump_live_to_config; then
    err "config 덤프 실패, 백업에서 롤백 중..."
    persist_rollback_to "$backup"
    return 1
  fi
  ok "규칙 삭제 완료"
}

# ── 메뉴 ───────────────────────────────────────────────────
rule_menu() {
  while true; do
    clear
    info "${C_BLD}=== 규칙 관리 ===${C_RST}"
    info ""
    local idx
    idx=$(arrow_menu "작업 선택 (q=뒤로):" \
      "INPUT 허용 추가" \
      "INPUT 차단 추가" \
      "DOCKER-USER 허용 추가" \
      "DOCKER-USER 차단 추가" \
      "OUTPUT 차단 추가" \
      "INPUT 규칙 삭제" \
      "DOCKER-USER 규칙 삭제" \
      "OUTPUT 규칙 삭제" \
      "뒤로") || return 0
    (( idx < 0 )) && return 0
    case "$idx" in
      0) _rule_add_source_based INPUT       ACCEPT ;;
      1) _rule_add_source_based INPUT       DROP   ;;
      2) _rule_add_source_based DOCKER-USER ACCEPT ;;
      3) _rule_add_source_based DOCKER-USER DROP   ;;
      4) _rule_add_output_block ;;
      5) _rule_delete_from_chain INPUT ;;
      6) _rule_delete_from_chain DOCKER-USER ;;
      7) _rule_delete_from_chain OUTPUT ;;
      8) return 0 ;;
    esac
    pause
  done
}
