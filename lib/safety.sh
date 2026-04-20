#!/usr/bin/env bash
# lib/safety.sh — SSH 차단 경고, 60초 확인 타이머, ESTABLISHED,RELATED 감지

FW_SAFETY_TIMEOUT=${FW_SAFETY_TIMEOUT:-60}

# ── SSH 포트 감지 ─────────────────────────────────────────
# $SSH_CONNECTION 형식: "client_ip client_port server_ip server_port"
safety_ssh_port() {
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    awk '{ print $4 }' <<<"$SSH_CONNECTION"
  else
    echo 22
  fi
}

# ── SSH 차단 경고 ─────────────────────────────────────────
# safety_check_ssh_block "description-of-rule"
#   규칙이 SSH 포트를 차단할 가능성이 있으면 경고 후 사용자 확인.
#   설명 문자열에 `-p tcp` 와 `--dport <ssh포트>` 또는 `all`/`-j DROP` 이 들어있으면 의심으로 본다.
#   0 = 진행 OK, 1 = 사용자 취소
safety_check_ssh_block() {
  local desc="$1"
  local port; port=$(safety_ssh_port)

  local suspicious=0
  # "모든 트래픽 차단" 류
  [[ "$desc" == *" -j DROP"* || "$desc" == *" -j REJECT"* ]] || return 0

  # SSH 포트 명시적 포함
  if [[ "$desc" == *"--dport $port"* || "$desc" == *"--dports $port"* ]]; then
    suspicious=1
  fi

  # 프로토콜/포트 미지정 = 전체 차단 → SSH도 잠길 수 있음
  if [[ "$desc" != *"--dport"* && "$desc" != *"-p "* ]]; then
    suspicious=1
  fi

  (( suspicious )) || return 0

  warn "이 규칙은 SSH 포트($port) 접속을 차단할 수 있습니다:"
  warn "  $desc"
  confirm "그래도 진행하시겠습니까?" N
}

# ── 60초 확인 타이머 ──────────────────────────────────────
# safety_arm_confirm_timer BACKUP_PATH
#   $FW_SAFETY_TIMEOUT 초 동안 확인 요청. 미확인 시 BACKUP_PATH 로 자동 롤백.
#   0 = 사용자 확인 완료, 1 = 타임아웃/롤백 수행됨
safety_arm_confirm_timer() {
  local backup="$1"
  local timeout="$FW_SAFETY_TIMEOUT"

  warn "적용 완료. ${timeout}초 내에 확인하지 않으면 자동으로 원복됩니다."
  info "현재 SSH가 살아있고 의도대로 동작하면 Enter를 눌러 확정."

  # read -t timeout 으로 대기
  if read -r -t "$timeout" _; then
    ok "변경 확정."
    return 0
  fi

  warn "확인 타임아웃 — 백업에서 원복 중..."
  persist_rollback_to "$backup"
  return 1
}

# ── ESTABLISHED,RELATED 감지 ──────────────────────────────
# safety_check_established
#   INPUT 체인에 ESTABLISHED,RELATED 허용 규칙이 있는지 확인. 없으면 경고+자동삽입 제안.
safety_check_established() {
  local has=0
  if iptables -S INPUT 2>/dev/null | grep -qE 'state (RELATED,ESTABLISHED|ESTABLISHED,RELATED)|ctstate (RELATED,ESTABLISHED|ESTABLISHED,RELATED)'; then
    has=1
  fi

  (( has )) && return 0

  warn "INPUT 체인에 ESTABLISHED,RELATED 허용 규칙이 없습니다."
  warn "이 상태에서 INPUT policy를 DROP으로 바꾸면 기존 연결이 전부 끊깁니다."
  if confirm "자동으로 '-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT' 을 맨 앞에 삽입할까요?" Y; then
    iptables -I INPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ok "삽입 완료."
  fi
}
