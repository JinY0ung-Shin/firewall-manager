#!/usr/bin/env bash
# lib/rule.sh — iptables 규칙 편집 (INPUT, DOCKER-USER, OUTPUT)

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

# 설명(comment) 입력 프롬프트. Enter만 치면 빈값.
_rule_prompt_comment() {
  local comment
  read -r -p "설명 (선택, Enter로 건너뛰기): " comment
  printf '%s' "$comment"
}

# 문자열 spec + 선택적 comment → iptables argv 배열.
# 사용: _rule_build_args ARRNAME "<chain>" "$spec" "$comment"
_rule_build_args() {
  local -n _out="$1"
  local chain="$2" spec="$3" comment="$4"
  _out=()
  # spec은 공백 포함 토큰이 없으므로 word-split 안전.
  local tok
  for tok in $spec; do _out+=("$tok"); done
  if [[ -n "$comment" ]]; then
    _out+=(-m comment --comment "$comment")
  fi
}

# ── INPUT/DOCKER-USER 허용 or 차단 추가 ────────────────────
_rule_add_source_based() {
  local chain="$1" jump="$2"  # jump: ACCEPT | DROP | REJECT
  local src port comment
  src=$(_rule_prompt_source) || { warn "취소됨"; return 0; }
  port=$(_rule_prompt_port) || { warn "취소됨"; return 0; }
  comment=$(_rule_prompt_comment)

  local spec="$src $port -j $jump"
  spec="${spec//  / }"; spec="${spec# }"

  local -a args
  _rule_build_args args "$chain" "$spec" "$comment"

  info "추가할 규칙: iptables -A $chain $spec${comment:+ -m comment --comment \"$comment\"}"
  confirm "진행?" Y || return 0

  if [[ "$jump" == "DROP" || "$jump" == "REJECT" ]]; then
    safety_check_ssh_block "$chain $spec" || return 0
  fi

  local backup; backup=$(persist_backup "pre-rule-add") || return 1
  if ! iptables -A "$chain" "${args[@]}"; then
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
  local dst port comment
  dst=$(_rule_prompt_destination) || { warn "취소됨"; return 0; }
  port=$(_rule_prompt_port) || { warn "취소됨"; return 0; }

  local jidx
  jidx=$(arrow_menu "동작:" "DROP (조용히 버림)" "REJECT (거절 응답)") || return 0
  (( jidx < 0 )) && return 0
  local jump; case "$jidx" in 0) jump=DROP ;; 1) jump=REJECT ;; esac

  comment=$(_rule_prompt_comment)

  local spec="$dst $port -j $jump"
  spec="${spec//  / }"; spec="${spec# }"

  local -a args
  _rule_build_args args OUTPUT "$spec" "$comment"

  info "추가할 규칙: iptables -A OUTPUT $spec${comment:+ -m comment --comment \"$comment\"}"
  confirm "진행?" Y || return 0

  local backup; backup=$(persist_backup "pre-output-block") || return 1
  if ! iptables -A OUTPUT "${args[@]}"; then
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

# ── INPUT 기본 정책 변경 (ACCEPT ↔ DROP) ──────────────────
# 위험도가 높은 작업이라 3단 안전장치: ESTABLISHED 체크 → SSH 허용 체크 → 60초 타이머
_rule_toggle_input_policy() {
  local current
  current=$(iptables -S INPUT 2>/dev/null | awk 'NR==1 {print $3}')
  [[ -z "$current" ]] && { err "INPUT 체인 조회 실패"; return 1; }

  local target
  if [[ "$current" == "DROP" ]]; then
    target="ACCEPT"
    info "현재: ${C_BLD}DROP${C_RST} (명시적 허용만 통과) → 변경 시: ACCEPT (모든 트래픽 허용, 차단 규칙만 적용)"
  else
    target="DROP"
    info "현재: ${C_BLD}$current${C_RST} (기본 통과) → 변경 시: DROP (명시적으로 허용하지 않은 트래픽 전부 차단)"
    warn "DROP 전환은 허용 규칙이 충분치 않으면 SSH 접속이 끊기는 등 자기-차단 위험이 있습니다."
  fi
  info ""

  confirm "INPUT 기본 정책을 $target 로 바꾸시겠습니까?" N || return 0

  if [[ "$target" == "DROP" ]]; then
    # (1) ESTABLISHED,RELATED 체크 + 자동 삽입 제안
    safety_check_established

    # (2) SSH 허용 규칙 체크
    local port; port=$(safety_ssh_port)
    if ! iptables -S INPUT 2>/dev/null | grep -qE "dport $port\\b.*-j ACCEPT"; then
      warn "INPUT에 SSH 포트($port) 허용 규칙이 안 보입니다."
      warn "이 상태로 DROP 전환하면 현재 SSH 세션은 유지되어도, 다음 새 접속은 차단됩니다."
      confirm "그래도 진행?" N || return 0
    fi
  fi

  local backup; backup=$(persist_backup "pre-policy-change") || return 1
  if ! iptables -P INPUT "$target"; then
    err "정책 변경 실패"
    persist_rollback_to "$backup"
    return 1
  fi
  if ! persist_dump_live_to_config; then
    err "config 덤프 실패, 백업에서 롤백 중..."
    persist_rollback_to "$backup"
    return 1
  fi

  # (3) DROP 전환인 경우에만 60초 확인 타이머
  if [[ "$target" == "DROP" ]]; then
    safety_arm_confirm_timer "$backup" || return 1
  fi

  ok "INPUT 기본 정책: $target"
}

# ── 규칙 삭제 (목록에서 선택) ──────────────────────────────
# 구현 노트: 규칙에 --comment "..." 가 있으면 spec 문자열을 word-split 해서 넘기면
# 따옴표가 깨진다. 대신 "체인 내 규칙 번호(1-based)" 로 삭제해서 우회한다.
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

  local rule_num=$((idx + 1))
  info "삭제: iptables -D $chain $rule_num  (${rules[$idx]})"
  confirm "진행?" Y || return 0

  local backup; backup=$(persist_backup "pre-rule-delete") || return 1
  if ! iptables -D "$chain" "$rule_num"; then
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
      "INPUT 기본 정책 변경 (ACCEPT ↔ DROP)" \
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
      8) _rule_toggle_input_policy ;;
      9) return 0 ;;
    esac
    pause
  done
}
