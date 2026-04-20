#!/usr/bin/env bash
# lib/common.sh — 색상/로그/메뉴/flock 래퍼
# 도메인 로직 없음.

set -u

# ── 색상 ───────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_DIM=$'\033[2m';  C_BLD=$'\033[1m'
  C_RST=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_DIM=''; C_BLD=''; C_RST=''
fi

# ── 로그 (stderr) ─────────────────────────────────────────
info()  { printf '%s\n' "$*" >&2; }
warn()  { printf '%s! %s%s\n' "$C_YEL" "$*" "$C_RST" >&2; }
err()   { printf '%s✗ %s%s\n' "$C_RED" "$*" "$C_RST" >&2; }
ok()    { printf '%s✓ %s%s\n' "$C_GRN" "$*" "$C_RST" >&2; }
dim()   { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RST" >&2; }

# ── 확인 프롬프트 ──────────────────────────────────────────
# confirm "질문" [default=N]  → 0=yes, 1=no
confirm() {
  local prompt="$1" default="${2:-N}" reply hint
  case "$default" in Y|y) hint="[Y/n]";; *) hint="[y/N]";; esac
  read -r -p "$(printf '%s %s ' "$prompt" "$hint")" reply || return 1
  [[ -z "$reply" ]] && reply="$default"
  [[ "$reply" =~ ^[Yy]$ ]]
}

# ── 화살표 키 메뉴 ─────────────────────────────────────────
# arrow_menu "프롬프트" item1 item2 ...
# 선택된 index(0-based)를 stdout으로.
arrow_menu() {
  local prompt="$1"; shift
  local -a items=("$@")
  local n=${#items[@]} idx=0 key
  [[ $n -eq 0 ]] && return 1

  tput civis >&2 2>/dev/null || true
  # 초기 렌더
  printf '%s\n' "$prompt" >&2
  local i
  for ((i=0; i<n; i++)); do
    if [[ $i -eq $idx ]]; then
      printf '  %s> %s%s\n' "$C_BLU" "${items[i]}" "$C_RST" >&2
    else
      printf '    %s\n' "${items[i]}" >&2
    fi
  done

  while true; do
    IFS= read -rsn1 key
    if [[ $key == $'\x1b' ]]; then
      IFS= read -rsn2 -t 0.01 key
      case "$key" in
        '[A') idx=$(( (idx - 1 + n) % n )) ;;
        '[B') idx=$(( (idx + 1) % n )) ;;
      esac
    elif [[ -z $key ]]; then
      break  # Enter
    elif [[ $key == q ]]; then
      tput cnorm >&2 2>/dev/null || true
      echo -1; return 2
    fi
    # 다시 그리기: 위로 n줄 이동 후 재렌더
    printf '\033[%dA' "$n" >&2
    for ((i=0; i<n; i++)); do
      printf '\033[2K' >&2
      if [[ $i -eq $idx ]]; then
        printf '  %s> %s%s\n' "$C_BLU" "${items[i]}" "$C_RST" >&2
      else
        printf '    %s\n' "${items[i]}" >&2
      fi
    done
  done
  tput cnorm >&2 2>/dev/null || true
  echo "$idx"
}

# ── 체크박스 멀티선택 ───────────────────────────────────────
# checkbox_menu "프롬프트" item1 item2 ...
# 선택된 index들을 공백 구분으로 stdout. 전체 기본 체크됨.
checkbox_menu() {
  local prompt="$1"; shift
  local -a items=("$@")
  local n=${#items[@]} idx=0 key
  [[ $n -eq 0 ]] && return 1
  local -a checked
  for ((i=0; i<n; i++)); do checked[i]=1; done

  tput civis >&2 2>/dev/null || true
  printf '%s (스페이스=토글, 엔터=확정, q=취소)\n' "$prompt" >&2
  for ((i=0; i<n; i++)); do
    local mark; [[ ${checked[i]} -eq 1 ]] && mark='[x]' || mark='[ ]'
    if [[ $i -eq $idx ]]; then
      printf '  %s> %s %s%s\n' "$C_BLU" "$mark" "${items[i]}" "$C_RST" >&2
    else
      printf '    %s %s\n' "$mark" "${items[i]}" >&2
    fi
  done

  while true; do
    IFS= read -rsn1 key
    if [[ $key == $'\x1b' ]]; then
      IFS= read -rsn2 -t 0.01 key
      case "$key" in
        '[A') idx=$(( (idx - 1 + n) % n )) ;;
        '[B') idx=$(( (idx + 1) % n )) ;;
      esac
    elif [[ $key == ' ' ]]; then
      checked[idx]=$(( 1 - ${checked[idx]} ))
    elif [[ -z $key ]]; then
      break
    elif [[ $key == q ]]; then
      tput cnorm >&2 2>/dev/null || true
      return 2
    fi
    printf '\033[%dA' "$n" >&2
    for ((i=0; i<n; i++)); do
      printf '\033[2K' >&2
      local mark; [[ ${checked[i]} -eq 1 ]] && mark='[x]' || mark='[ ]'
      if [[ $i -eq $idx ]]; then
        printf '  %s> %s %s%s\n' "$C_BLU" "$mark" "${items[i]}" "$C_RST" >&2
      else
        printf '    %s %s\n' "$mark" "${items[i]}" >&2
      fi
    done
  done
  tput cnorm >&2 2>/dev/null || true

  local out=""
  for ((i=0; i<n; i++)); do
    [[ ${checked[i]} -eq 1 ]] && out+="$i "
  done
  printf '%s\n' "${out% }"
}

# ── flock 래퍼 ────────────────────────────────────────────
# with_lock <command...>  — /var/lock/fw-manager.lock 을 non-blocking으로 취득. 실패하면 exit 1.
FW_LOCK=${FW_LOCK:-/var/lock/fw-manager.lock}
with_lock() {
  exec 9>"$FW_LOCK" || { err "락 파일 생성 실패: $FW_LOCK"; exit 1; }
  if ! flock -n 9; then
    err "다른 fw 인스턴스가 실행 중 (lock: $FW_LOCK)"
    exit 1
  fi
  "$@"
  local rc=$?
  flock -u 9
  exec 9>&-
  return $rc
}

# ── 일시정지 ───────────────────────────────────────────────
pause() { read -r -p "엔터를 누르면 계속..." _; }

# ── 루트 확인 ──────────────────────────────────────────────
require_root() {
  [[ $EUID -eq 0 ]] || { err "root 권한 필요 (sudo)"; exit 1; }
}
