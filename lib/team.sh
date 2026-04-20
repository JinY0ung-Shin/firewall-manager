#!/usr/bin/env bash
# lib/team.sh — ipset 팀 관리
# 모든 live 변경은 persist_transaction 래퍼를 통해.

# ── 내부 헬퍼: live에 set 생성 ────────────────────────────
_team_create_live() {
  local name="$1" desc="$2"
  local args=(hash:net family inet hashsize 1024 maxelem 65536 comment)
  ipset create "$name" "${args[@]}" || return 1
  if [[ -n "$desc" ]]; then
    # ipset 자체 comment: 현재 ipset은 set-level comment가 `--comment` 옵션으로 안 붙음.
    # set-level 설명은 지원 안 되는 버전이 많음 → 포기, member comment 만 사용.
    : # no-op
  fi
}

_team_delete_live() {
  local name="$1"
  # 참조 중인 iptables 규칙이 있으면 먼저 삭제하라는 에러 나옴 — 그대로 사용자에게 노출
  ipset destroy "$name"
}

_team_add_member_live() {
  local name="$1" ip="$2" comment="$3"
  ipset add "$name" "$ip" comment "$comment"
}

_team_remove_member_live() {
  local name="$1" ip="$2"
  ipset del "$name" "$ip"
}

# ── 팀 목록 ───────────────────────────────────────────────
team_list_names() {
  scope_ipset_names_from_file "$FW_IPSETS_FILE"
}

team_show_summary() {
  local -a names
  mapfile -t names < <(team_list_names)
  if [[ ${#names[@]} -eq 0 ]]; then
    info "(팀 없음)"
    return
  fi
  local n
  for n in "${names[@]}"; do
    local count
    count=$(ipset list "$n" 2>/dev/null | grep -c '^[0-9]' || echo 0)
    printf '  %s%-24s%s  %s개 멤버\n' "$C_BLD" "$n" "$C_RST" "$count" >&2
  done
}

# ── 팀 생성 (대화형) ───────────────────────────────────────
team_create_interactive() {
  local name
  read -r -p "새 팀 이름 (영문/숫자/_, 31자 이내): " name
  [[ -z "$name" ]] && { warn "취소됨"; return 1; }
  if [[ ! "$name" =~ ^[A-Za-z0-9_]+$ ]]; then
    err "이름은 영문/숫자/_만 가능"; return 1
  fi
  if ipset list -n 2>/dev/null | grep -qx "$name"; then
    err "이미 존재하는 set: $name"; return 1
  fi

  persist_transaction _team_create_live "$name" "" || return 1
  ok "팀 생성: $name"
}

# ── 팀 삭제 (대화형) ───────────────────────────────────────
team_delete_interactive() {
  local -a names
  mapfile -t names < <(team_list_names)
  [[ ${#names[@]} -eq 0 ]] && { warn "삭제할 팀 없음"; return 0; }

  local idx
  idx=$(arrow_menu "삭제할 팀 선택 (q=취소):" "${names[@]}") || return 0
  (( idx < 0 )) && return 0
  local name="${names[$idx]}"

  confirm "팀 '$name' 을 삭제합니다. 이 팀을 참조하는 iptables 규칙이 있으면 먼저 ipset destroy가 실패합니다. 계속?" N || return 0
  persist_transaction _team_delete_live "$name" || return 1
  ok "팀 삭제: $name"
}

# ── 멤버 추가 (대화형) ─────────────────────────────────────
team_add_member_interactive() {
  local -a names
  mapfile -t names < <(team_list_names)
  [[ ${#names[@]} -eq 0 ]] && { warn "팀이 없음 — 먼저 생성"; return 0; }

  local idx
  idx=$(arrow_menu "멤버를 추가할 팀 선택 (q=취소):" "${names[@]}") || return 0
  (( idx < 0 )) && return 0
  local name="${names[$idx]}"

  local ip comment
  read -r -p "IP 또는 CIDR: " ip
  [[ -z "$ip" ]] && { warn "취소됨"; return 0; }
  read -r -p "설명 (누구의 IP인지, 필수): " comment
  if [[ -z "$comment" ]]; then
    err "설명은 필수입니다."
    return 1
  fi

  persist_transaction _team_add_member_live "$name" "$ip" "$comment" || return 1
  ok "추가됨: $name ← $ip ($comment)"
}

# ── 멤버 삭제 (대화형) ─────────────────────────────────────
team_remove_member_interactive() {
  local -a names
  mapfile -t names < <(team_list_names)
  [[ ${#names[@]} -eq 0 ]] && { warn "팀 없음"; return 0; }

  local idx
  idx=$(arrow_menu "팀 선택 (q=취소):" "${names[@]}") || return 0
  (( idx < 0 )) && return 0
  local name="${names[$idx]}"

  # 멤버 목록 뽑기: `ipset save NAME` 에서 `add` 라인
  local -a members
  mapfile -t members < <(
    ipset save "$name" 2>/dev/null |
      awk -v n="$name" '$1=="add" && $2==n {
        ip=$3; sub(/^[^ ]+ [^ ]+ [^ ]+ /, "")
        printf "%s\t%s\n", ip, $0
      }'
  )
  [[ ${#members[@]} -eq 0 ]] && { warn "멤버 없음"; return 0; }

  # 화살표 메뉴 표시는 IP + comment
  local -a labels
  local m
  for m in "${members[@]}"; do
    labels+=("$(tr '\t' ' ' <<<"$m")")
  done
  local midx
  midx=$(arrow_menu "삭제할 멤버 선택 (q=취소):" "${labels[@]}") || return 0
  (( midx < 0 )) && return 0
  local member_ip="${members[$midx]%%$'\t'*}"

  persist_transaction _team_remove_member_live "$name" "$member_ip" || return 1
  ok "삭제됨: $name ← $member_ip"
}

# ── 메뉴 진입점 ────────────────────────────────────────────
team_menu() {
  while true; do
    clear
    info "${C_BLD}=== 팀 관리 (ipset) ===${C_RST}"
    info ""
    team_show_summary
    info ""
    local idx
    idx=$(arrow_menu "작업 선택 (q=뒤로):" \
      "팀 생성" \
      "팀 삭제" \
      "멤버 추가" \
      "멤버 삭제" \
      "뒤로") || return 0
    (( idx < 0 )) && return 0
    case "$idx" in
      0) team_create_interactive ;;
      1) team_delete_interactive ;;
      2) team_add_member_interactive ;;
      3) team_remove_member_interactive ;;
      4) return 0 ;;
    esac
    pause
  done
}
