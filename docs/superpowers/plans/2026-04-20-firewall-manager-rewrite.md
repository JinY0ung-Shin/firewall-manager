# firewall-manager 재작성 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 기존 4,315줄 bash firewall-manager를 자동-저장 모델·네이티브 포맷 기반으로 ~1,300줄 규모로 재작성.

**Architecture:** 모든 변경은 `persist_transaction`으로 감싸 `(1) 백업 → (2) live 적용 → (3) live를 config로 덤프`. 복원은 `ipset restore` → `iptables-restore --noflush` 순서로 우리 체인(`INPUT`/`DOCKER-USER`/`OUTPUT`)만 건드림. 커스텀 파싱 없음, iptables/ipset 네이티브 포맷 그대로.

**Tech Stack:** Bash 4+, iptables, ipset, flock, tar.

**Spec:** [docs/superpowers/specs/2026-04-20-firewall-manager-rewrite-design.md](../specs/2026-04-20-firewall-manager-rewrite-design.md)

**Testing note:** 스펙 §12에 따라 자동화 테스트 프레임워크는 도입하지 않음. 각 Task에 **수동 smoke verification 스텝**이 포함되어 있고, 최종 Task로 종합 체크리스트(SMOKE_TEST.md)를 작성함.

---

## Task 0: 작업 브랜치 + 기존 파일 정리

**Files:**
- Delete: `lib/bundle.sh`, `lib/sync.sh`, `lib/preflight.sh`, `lib/validators.sh`
- Delete: `MIGRATION.md`, `examples/SCENARIOS.md`
- Keep (will rewrite later): `lib/common.sh`, `lib/persist.sh`, `lib/rule.sh`, `lib/team.sh`, `lib/status.sh`, `fw`

- [ ] **Step 1: 작업 브랜치 생성**

```bash
git checkout -b rewrite/native-format
```

- [ ] **Step 2: 스펙 §14에 따라 out-of-scope 파일 삭제**

```bash
git rm lib/bundle.sh lib/sync.sh lib/preflight.sh lib/validators.sh
git rm MIGRATION.md examples/SCENARIOS.md
```

- [ ] **Step 3: config/teams/ 디렉토리 자체는 bootstrap 재실행으로 재구성 예정 — 지금 단계에서는 건드리지 않음**

수동 확인: 현재 삭제 대상만 제거되고 나머지 파일은 유지 상태인지.

```bash
git status
```
Expected: deleted 5 files (4 lib + MIGRATION.md + SCENARIOS.md). `lib/common.sh` 등은 그대로.

- [ ] **Step 4: 커밋**

```bash
git commit -m "Remove out-of-scope files for rewrite

Migration bundle, bidirectional sync, verbose preflight, and input
validators are all dropped per the rewrite spec (§14). The remaining
lib/ files will be rewritten in subsequent commits."
```

---

## Task 1: `lib/common.sh` — 기반 유틸리티

**Files:**
- Replace: `lib/common.sh` (현재 422줄 → ~180줄)

Responsibility: 색상, 로깅, 확인 프롬프트, 화살표 메뉴, flock 래퍼. 도메인 로직 없음.

- [ ] **Step 1: `lib/common.sh` 전체 교체**

```bash
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

  tput civis 2>/dev/null || true
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
      tput cnorm 2>/dev/null || true
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
  tput cnorm 2>/dev/null || true
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

  tput civis 2>/dev/null || true
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
      tput cnorm 2>/dev/null || true
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
  tput cnorm 2>/dev/null || true

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
```

- [ ] **Step 2: 문법 체크**

Run: `bash -n lib/common.sh`
Expected: (no output)

- [ ] **Step 3: 기본 동작 smoke**

```bash
# source 후 색상 함수 하나씩
bash -c 'source lib/common.sh; ok "OK 메시지"; warn "경고"; err "에러"'
```
Expected: 각 메시지가 해당 색상으로 stderr에 출력.

- [ ] **Step 4: 커밋**

```bash
git add lib/common.sh
git commit -m "Rewrite lib/common.sh with color, menu, flock primitives

422 lines → ~180 lines. Domain logic stripped; only UI and concurrency
primitives remain. Interactive menus use arrow keys with checkbox
variant for multi-select."
```

---

## Task 2: `lib/scope.sh` — 스코프 필터

**Files:**
- Create: `lib/scope.sh` (~80줄)

Responsibility: `iptables-save` / `ipset save` 출력에서 **우리가 관리하는 부분만** 골라냄. 파일 I/O 없음, stdin→stdout 변환만.

- [ ] **Step 1: `lib/scope.sh` 작성**

```bash
#!/usr/bin/env bash
# lib/scope.sh — iptables-save / ipset save 출력 필터링
# 입력은 stdin, 결과는 stdout. 파일 I/O 없음.

# scope_filter_iptables
#   `iptables-save -t filter` 출력에서 INPUT/OUTPUT/DOCKER-USER 체인 선언+규칙만 추출.
#   다른 체인(FORWARD, DOCKER, DOCKER-INGRESS, DOCKER-ISOLATION-*)은 제외.
scope_filter_iptables() {
  awk '
    BEGIN { in_filter = 0 }
    /^\*filter/  { print; in_filter = 1; next }
    /^COMMIT/    { if (in_filter) { print; in_filter = 0 }; next }
    !in_filter   { next }

    # 체인 정의
    /^:INPUT/       { print; next }
    /^:OUTPUT/      { print; next }
    /^:DOCKER-USER/ { print; next }
    /^:/            { next }   # 다른 체인 정의는 모두 버림

    # 규칙
    /^-A INPUT /       { print; next }
    /^-A OUTPUT /      { print; next }
    /^-A DOCKER-USER / { print; next }

    # 그 외 라인 (주석 등) 버림
  '
}

# scope_filter_ipset NAME1 NAME2 ...
#   `ipset save` 출력에서 주어진 set 이름만 추출.
#   `create NAME ...` 과 `add NAME ...` 라인 모두 포함.
scope_filter_ipset() {
  local names_pattern
  names_pattern=$(printf '%s|' "$@")
  names_pattern="^(create|add) (${names_pattern%|}) "
  grep -E "$names_pattern" || true  # 매치 없어도 exit 0
}

# scope_ipset_names_from_file FILE
#   기존 config/ipsets.rules 에서 관리 중인 set 이름 목록 추출.
scope_ipset_names_from_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  awk '/^create / { print $2 }' "$file"
}
```

- [ ] **Step 2: 필터링 smoke**

```bash
# iptables 필터 동작 확인
cat <<'EOF' | bash -c 'source lib/scope.sh; scope_filter_iptables'
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:DOCKER - [0:0]
:DOCKER-USER - [0:0]
-A INPUT -p tcp --dport 22 -j ACCEPT
-A FORWARD -j DOCKER-USER
-A DOCKER-USER -j RETURN
-A DOCKER -j ACCEPT
COMMIT
EOF
```
Expected:
```
*filter
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:DOCKER-USER - [0:0]
-A INPUT -p tcp --dport 22 -j ACCEPT
-A DOCKER-USER -j RETURN
COMMIT
```
(FORWARD, DOCKER 체인 선언과 해당 규칙들은 모두 제거됨)

- [ ] **Step 3: ipset 필터 동작 확인**

```bash
cat <<'EOF' | bash -c 'source lib/scope.sh; scope_filter_ipset team_office team_ci'
create team_office hash:net family inet hashsize 1024 maxelem 65536 comment
create team_ci hash:net family inet hashsize 1024 maxelem 65536 comment
create docker_blocked hash:net family inet hashsize 1024 maxelem 65536
add team_office 10.0.0.1 comment "alice laptop"
add docker_blocked 192.0.2.0/24
add team_ci 203.0.113.5
EOF
```
Expected: `docker_blocked` 관련 2줄만 빠지고 나머지 4줄 출력.

- [ ] **Step 4: 커밋**

```bash
git add lib/scope.sh
git commit -m "Add lib/scope.sh — filter iptables-save/ipset save output

Pure stdin→stdout filters. No file I/O, no parsing beyond awk/grep.
scope_filter_iptables keeps INPUT/OUTPUT/DOCKER-USER only.
scope_filter_ipset keeps listed set names only."
```

---

## Task 3: `lib/persist.sh` — 트랜잭션 기반 저장/복원

**Files:**
- Replace: `lib/persist.sh` (현재 945줄 → ~180줄)

Responsibility: backup, dump-live-to-config, restore, rollback, transaction wrapper. **도메인 로직 없음** — 아는 것은 "config/ 디렉토리에 뭐가 있고 live에 무엇을 반영하는가".

- [ ] **Step 1: `lib/persist.sh` 전체 교체**

```bash
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

  # iptables (우리 스코프만)
  local tmp_ipt; tmp_ipt=$(mktemp)
  if ! iptables-save -t filter 2>/dev/null | scope_filter_iptables > "$tmp_ipt"; then
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
```

- [ ] **Step 2: 문법 체크**

Run: `bash -n lib/persist.sh`
Expected: (no output)

- [ ] **Step 3: 백업/덤프 smoke (live iptables 건드리지 않고)**

```bash
# 임시 config 디렉토리에서
TMPDIR=$(mktemp -d)
FW_CONFIG_DIR=$TMPDIR bash -c '
  source lib/scope.sh
  source lib/common.sh
  source lib/persist.sh
  echo "dummy" > $FW_CONFIG_DIR/iptables.rules
  backup=$(persist_backup "smoke")
  echo "created: $backup"
  ls -la $FW_BACKUP_DIR/
'
rm -rf "$TMPDIR"
```
Expected: `created: ...tar.gz` 출력, 해당 파일 실제로 존재.

- [ ] **Step 4: 커밋**

```bash
git add lib/persist.sh
git commit -m "Rewrite lib/persist.sh around transaction wrapper

945 lines → ~180 lines. Five functions:
- persist_backup: tarball snapshot of config/, rotate to 20
- persist_dump_live_to_config: iptables-save|filter > config
- persist_restore_from_config: ipset restore THEN iptables-restore --noflush
- persist_rollback_to: restore from a specific backup
- persist_transaction: backup → action → dump (rollback on failure)

All persistent-state changes in the tool must go through persist_transaction."
```

---

## Task 4: `lib/safety.sh` — SSH 경고, 60초 타이머, ESTABLISHED 감지

**Files:**
- Create: `lib/safety.sh` (~140줄)

Responsibility: 자기-차단 위험이 있는 변경 앞/뒤에 쓸 수 있는 프리미티브 3종.

- [ ] **Step 1: `lib/safety.sh` 작성**

```bash
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
```

- [ ] **Step 2: 문법 체크 + SSH 포트 감지**

```bash
bash -n lib/safety.sh
SSH_CONNECTION="1.2.3.4 55555 10.0.0.1 22" bash -c 'source lib/safety.sh; safety_ssh_port'
# Expected: 22
SSH_CONNECTION="1.2.3.4 55555 10.0.0.1 2222" bash -c 'source lib/safety.sh; safety_ssh_port'
# Expected: 2222
unset SSH_CONNECTION; bash -c 'source lib/safety.sh; safety_ssh_port'
# Expected: 22
```

- [ ] **Step 3: 커밋**

```bash
git add lib/safety.sh
git commit -m "Add lib/safety.sh — SSH warning, 60s timer, ESTABLISHED detection

Three primitives used around any destructive change:
- safety_check_ssh_block: warn if rule might block SSH
- safety_arm_confirm_timer: 60s timeout with auto-rollback
- safety_check_established: offer to add conntrack RELATED,ESTABLISHED"
```

---

## Task 5: `lib/bootstrap.sh` — 첫 실행 import

**Files:**
- Create: `lib/bootstrap.sh` (~100줄)

Responsibility: `config/` 가 없을 때만 호출. live 상태를 읽어서 초기 config 파일 생성. live는 변경하지 않음.

- [ ] **Step 1: `lib/bootstrap.sh` 작성**

```bash
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
```

- [ ] **Step 2: 문법 체크**

Run: `bash -n lib/bootstrap.sh`
Expected: (no output)

- [ ] **Step 3: 커밋**

```bash
git add lib/bootstrap.sh
git commit -m "Add lib/bootstrap.sh — first-run config import

Triggered only when config/ files are missing. Imports current live
iptables and user-selected ipsets into config/, creates initial
backup. Does NOT modify live state."
```

---

## Task 6: `lib/team.sh` — ipset 팀 관리

**Files:**
- Replace: `lib/team.sh` (현재 603줄 → ~220줄)

Responsibility: ipset 기반 팀 CRUD. 신규 set 생성 시 항상 `hash:net comment` 옵션.

- [ ] **Step 1: `lib/team.sh` 전체 교체**

```bash
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
```

- [ ] **Step 2: 문법 체크**

Run: `bash -n lib/team.sh`
Expected: (no output)

- [ ] **Step 3: 커밋**

```bash
git add lib/team.sh
git commit -m "Rewrite lib/team.sh around ipset native comment

603 lines → ~220 lines. All new sets created with hash:net + comment
option. Member comments are required. All state changes go through
persist_transaction."
```

---

## Task 7: `lib/rule.sh` — INPUT/DOCKER-USER/OUTPUT 규칙 편집

**Files:**
- Replace: `lib/rule.sh` (현재 545줄 → ~280줄)

Responsibility: iptables 규칙 CRUD. INPUT/DOCKER-USER는 source 기반 allow+deny, OUTPUT은 destination 기반 deny만 추가 가능.

- [ ] **Step 1: `lib/rule.sh` 전체 교체**

```bash
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
  persist_dump_live_to_config

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
  persist_dump_live_to_config
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
  persist_dump_live_to_config
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
```

- [ ] **Step 2: 문법 체크**

Run: `bash -n lib/rule.sh`
Expected: (no output)

- [ ] **Step 3: 커밋**

```bash
git add lib/rule.sh
git commit -m "Rewrite lib/rule.sh with scoped chain menus

545 lines → ~280 lines. INPUT/DOCKER-USER are source-based
allow+deny. OUTPUT is destination-based deny only. Rule deletion
works across all three chains by picking from live listing.

DROP/REJECT rules trigger SSH-block check and 60s confirm timer."
```

---

## Task 8: `lib/rollback.sh` — 백업 목록 & 복원 UI

**Files:**
- Create: `lib/rollback.sh` (~80줄)

- [ ] **Step 1: `lib/rollback.sh` 작성**

```bash
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
```

- [ ] **Step 2: 문법 체크 + 커밋**

```bash
bash -n lib/rollback.sh
git add lib/rollback.sh
git commit -m "Add lib/rollback.sh — backup list UI and restore"
```

---

## Task 9: `lib/status.sh` — 현재 상태 요약

**Files:**
- Replace: `lib/status.sh` (현재 120줄 → ~70줄)

- [ ] **Step 1: `lib/status.sh` 전체 교체**

```bash
#!/usr/bin/env bash
# lib/status.sh — 현재 상태 요약 출력

status_show() {
  info "${C_BLD}=== 현재 방화벽 상태 ===${C_RST}"
  info ""
  local chain
  for chain in INPUT DOCKER-USER OUTPUT; do
    if iptables -S "$chain" >/dev/null 2>&1; then
      local policy
      policy=$(iptables -S "$chain" 2>/dev/null | awk 'NR==1 {print $3}')
      local n
      n=$(iptables -S "$chain" 2>/dev/null | grep -c '^-A ')
      printf '%s[%s]%s policy=%s, rules=%d\n' "$C_BLD" "$chain" "$C_RST" "$policy" "$n" >&2
      iptables -S "$chain" 2>/dev/null | grep '^-A ' | sed 's/^/    /' >&2
      info ""
    else
      dim "[$chain] (체인 없음)"
    fi
  done

  info "${C_BLD}=== 관리 중인 팀(ipset) ===${C_RST}"
  team_show_summary
  info ""

  info "${C_BLD}=== 최근 백업 ===${C_RST}"
  local -a paths
  mapfile -t paths < <(ls -1t "$FW_BACKUP_DIR"/*.tar.gz 2>/dev/null | head -5)
  if [[ ${#paths[@]} -eq 0 ]]; then
    dim "  (없음)"
  else
    local p
    for p in "${paths[@]}"; do
      printf '  %s\n' "$(basename "$p" .tar.gz)" >&2
    done
  fi
}
```

- [ ] **Step 2: 문법 체크 + 커밋**

```bash
bash -n lib/status.sh
git add lib/status.sh
git commit -m "Rewrite lib/status.sh — concise state summary"
```

---

## Task 10: `fw` — 엔트리포인트

**Files:**
- Replace: `fw` (현재 172줄 → ~100줄)

Responsibility: 모든 lib/ 로드, 루트/flock 체크, 메인 메뉴/비대화형 서브커맨드 디스패치.

- [ ] **Step 1: `fw` 전체 교체**

```bash
#!/usr/bin/env bash
# fw — Firewall Manager entrypoint

set -u

FW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FW_CONFIG_DIR="${FW_CONFIG_DIR:-$FW_ROOT/config}"

# lib 로드 (순서 중요: common → scope → persist → safety → bootstrap → team → rule → rollback → status)
# shellcheck source=lib/common.sh
source "$FW_ROOT/lib/common.sh"
# shellcheck source=lib/scope.sh
source "$FW_ROOT/lib/scope.sh"
# shellcheck source=lib/persist.sh
source "$FW_ROOT/lib/persist.sh"
# shellcheck source=lib/safety.sh
source "$FW_ROOT/lib/safety.sh"
# shellcheck source=lib/bootstrap.sh
source "$FW_ROOT/lib/bootstrap.sh"
# shellcheck source=lib/team.sh
source "$FW_ROOT/lib/team.sh"
# shellcheck source=lib/rule.sh
source "$FW_ROOT/lib/rule.sh"
# shellcheck source=lib/rollback.sh
source "$FW_ROOT/lib/rollback.sh"
# shellcheck source=lib/status.sh
source "$FW_ROOT/lib/status.sh"

# ── CLI ───────────────────────────────────────────────────
print_help() {
  cat <<'EOF' >&2
fw — Interactive Firewall Manager

사용법:
  sudo ./fw                 대화형 메뉴
  sudo ./fw status          현재 상태 표시
  sudo ./fw rollback [N]    백업 목록 or 인덱스 복원
  sudo ./fw --help          이 도움말

관리 범위: INPUT, DOCKER-USER, OUTPUT(차단만), ipset(hash:net).
FORWARD/nat/mangle/다른 ipset 타입은 건드리지 않음.
EOF
}

main_menu() {
  while true; do
    clear
    info "  ${C_BLD}+======================================+${C_RST}"
    info "  ${C_BLD}|       Firewall Manager v2.0.0        |${C_RST}"
    info "  ${C_BLD}+======================================+${C_RST}"
    info ""
    local idx
    idx=$(arrow_menu "메뉴 (q=종료):" \
      "규칙 관리" \
      "팀 관리 (ipset)" \
      "롤백 (백업에서 복원)" \
      "현재 상태 보기" \
      "종료") || return 0
    (( idx < 0 )) && return 0
    case "$idx" in
      0) rule_menu ;;
      1) team_menu ;;
      2) rollback_menu; pause ;;
      3) status_show; pause ;;
      4) return 0 ;;
    esac
  done
}

main() {
  # --help 는 루트 없이도 볼 수 있어야 자연스럽다
  case "${1:-}" in
    --help|-h) print_help; exit 0 ;;
  esac

  require_root

  # 비대화형 분기
  case "${1:-}" in
    status)    with_lock bash -c 'bootstrap_run; safety_check_established >/dev/null 2>&1 || true; status_show'; exit 0 ;;
    rollback)
      shift
      if [[ -n "${1:-}" ]]; then
        with_lock rollback_by_index "$1"
      else
        with_lock bash -c 'rollback_list'
      fi
      exit $?
      ;;
    '') : ;;
    *) err "알 수 없는 명령: $1"; print_help; exit 1 ;;
  esac

  # 대화형
  with_lock bash -c 'bootstrap_run; safety_check_established'
  with_lock main_menu
}

main "$@"
```

- [ ] **Step 2: 문법 체크 + 실행 권한**

```bash
bash -n fw
chmod +x fw
```

- [ ] **Step 3: `--help` 동작 (sudo 없이)**

```bash
./fw --help
```
Expected: help 텍스트 출력, exit 0.

- [ ] **Step 4: source 무결성 smoke — 실제 iptables 변경 없이 메뉴 화면만 뜨는지**

```bash
sudo ./fw status
```
Expected: 첫 실행이면 bootstrap이 먼저 돌고, 이후 상태 요약이 출력됨. iptables 자체는 변경되지 않음.

- [ ] **Step 5: 커밋**

```bash
git add fw
git commit -m "Rewrite fw entrypoint

172 lines → ~100 lines. Single main() dispatches to interactive
menu or three non-interactive subcommands (status/rollback/--help).
All state-changing code is wrapped in with_lock."
```

---

## Task 11: `SMOKE_TEST.md` — 수동 검증 체크리스트

**Files:**
- Create: `SMOKE_TEST.md`

Responsibility: 스펙 §12의 smoke 체크리스트를 실제 시나리오로 풀어 놓아, 재작성 후 실환경에서 밟을 수 있게 함.

- [ ] **Step 1: `SMOKE_TEST.md` 작성**

```markdown
# Smoke Test — firewall-manager v2.0

재작성 후 실환경(격리된 VM이나 컨테이너 권장)에서 한 번씩 밟는 수동 체크리스트입니다. 각 항목이 모두 기대대로 동작하면 PR/릴리스 OK로 봅니다.

## 준비

- 리눅스 VM 또는 `--privileged` 컨테이너 (iptables/ipset 실행 가능 환경)
- root 접근
- `iptables`, `ipset`, `flock`, `tar` 설치

## 체크리스트

### 1. 첫 실행 bootstrap

- [ ] `config/` 를 삭제한 상태에서 `sudo ./fw status` 실행
- [ ] bootstrap 메시지가 뜨고 ipset 선택 체크리스트가 나타남
- [ ] 선택 후 `config/iptables.rules`, `config/ipsets.rules`, `config/backups/*_initial.tar.gz` 생성됨
- [ ] live iptables 규칙은 **변경 없음** (bootstrap 전후 `iptables -S` 비교)

### 2. 팀 생성 / IP 추가 / IP 삭제

- [ ] 메뉴 → 팀 관리 → 팀 생성 → 이름 `team_smoke` → 완료
- [ ] `ipset list team_smoke` 로 `comment` 옵션이 포함되어 생성됐는지 확인
- [ ] 멤버 추가: `10.0.0.1`, 설명 `"smoke-a"` → 성공
- [ ] 설명을 빈 문자열로 추가 시도 → 거부됨
- [ ] 멤버 삭제 → `10.0.0.1` 사라짐
- [ ] `config/ipsets.rules` 에 변경이 즉시 반영되어 있음

### 3. INPUT 허용 추가

- [ ] 메뉴 → 규칙 관리 → INPUT 허용 추가 → 팀 `team_smoke` → 모든 포트
- [ ] `iptables -S INPUT` 에 `-m set --match-set team_smoke src -j ACCEPT` 존재
- [ ] `config/iptables.rules` 에 해당 라인 존재

### 4. INPUT 차단 추가 (SSH 경고 & 60초 타이머)

- [ ] 단일 IP `203.0.113.99`, 포트 제한 없음, 차단 → SSH 경고 뜸
- [ ] 확인 후 적용 → 60초 타이머 시작
- [ ] 60초 안에 엔터 → 확정 메시지
- [ ] 다시 다른 DROP 규칙 추가 후 60초 대기 → 자동 롤백 확인

### 5. OUTPUT 차단 추가

- [ ] OUTPUT 차단 추가 → destination `10.50.0.0/16`, TCP 8080, DROP
- [ ] `iptables -S OUTPUT` 에 해당 라인 존재
- [ ] `iptables -S OUTPUT` 의 기존 ACCEPT 규칙이 **그대로 보존**되어 있음

### 6. DOCKER-USER (Docker 있는 환경)

- [ ] Docker 실행 중인 환경에서 DOCKER-USER 허용 규칙 추가 → 성공
- [ ] Docker 없는 환경에서 동일 시도 → iptables 에러가 사용자에게 그대로 노출됨

### 7. 변경 후 롤백

- [ ] 몇 개 규칙 추가한 상태에서 `sudo ./fw rollback` → 백업 목록 표시
- [ ] `*_initial.tar.gz` 선택 → 복원 → `iptables -S` 가 처음과 동일
- [ ] 롤백 전 현재 상태는 `pre-rollback` 백업으로 저장되었는지 확인

### 8. 비대화형 커맨드

- [ ] `sudo ./fw status` → 상태 요약 출력
- [ ] `sudo ./fw rollback 2` → 2번째 최신 백업으로 복원

### 9. 동시 실행 flock

- [ ] 터미널 A에서 `sudo ./fw` 실행 (메뉴 대기 상태)
- [ ] 터미널 B에서 `sudo ./fw` 시도 → "다른 fw 인스턴스 실행 중" 에러로 즉시 종료

### 10. 복원 순서 (ipset → iptables)

- [ ] `team_smoke` 를 참조하는 INPUT 규칙이 있는 상태에서
- [ ] `ipset destroy team_smoke` 를 수동으로 실행 (도구 밖)
- [ ] `sudo ./fw rollback` → 최신 `pre-*` 백업으로 복원
- [ ] **복원 성공** (ipset이 먼저 복구되므로 iptables 규칙이 유효해짐)
```

- [ ] **Step 2: 커밋**

```bash
git add SMOKE_TEST.md
git commit -m "Add SMOKE_TEST.md — manual verification checklist"
```

---

## Task 12: `README.md` 갱신

**Files:**
- Modify: `README.md`

Responsibility: 삭제된 기능(migration, save/load/sync/export/import), 새 메뉴 구조, 자동 저장 모델을 반영. MIGRATION.md 참조도 제거.

- [ ] **Step 1: `README.md` 를 스펙 내용에 맞춰 갱신**

주요 변경:
- 상단 "핵심 목표" 에서 "다른 서버로 옮기기" 삭제
- "비대화형 모드" 섹션을 `status` / `rollback [N]` 두 개만 남김
- "서버 이전 흐름" 섹션 삭제
- "주요 기능" 에서 export/import/sync 언급 삭제
- "디렉토리 구조" 를 Task 0 삭제 반영 + `SMOKE_TEST.md` 추가
- v2.0 이라고 표시

전체를 다시 쓸 필요는 없고, 해당 섹션만 수정하면 됨.

- [ ] **Step 2: 커밋**

```bash
git add README.md
git commit -m "Update README for v2.0 rewrite

Drop migration/export/import/sync; add rollback; document the
automatic-save model. Points to SMOKE_TEST.md for verification."
```

---

## Task 13: 최종 점검 + 머지

- [ ] **Step 1: 문법 일괄 체크**

```bash
for f in fw lib/*.sh; do
  bash -n "$f" || echo "FAIL: $f"
done
```
Expected: (아무 FAIL 없음)

- [ ] **Step 2: 스펙 §13 "목표 ~1,300줄" 달성 여부 확인**

```bash
wc -l fw lib/*.sh | tail -1
```
Expected: 2,000줄 이하 (목표는 1,300이지만 주석/헤더 포함 2,000선이면 허용).

- [ ] **Step 3: `SMOKE_TEST.md` 를 격리 환경에서 1회 완주**

실패 항목 있으면 해당 Task 로 되돌아가 수정.

- [ ] **Step 4: 메인 브랜치 머지 전 확인**

```bash
git log --oneline main..rewrite/native-format
# 13개 내외의 커밋이 보여야 함
```

- [ ] **Step 5: 머지**

```bash
git checkout main
git merge --no-ff rewrite/native-format -m "Rewrite firewall-manager v2.0

See docs/superpowers/specs/2026-04-20-firewall-manager-rewrite-design.md
and docs/superpowers/plans/2026-04-20-firewall-manager-rewrite.md for
the design and task breakdown."
```

---

## 완료 조건

- [ ] 위 13개 Task 모두 체크됨
- [ ] `SMOKE_TEST.md` 10개 항목 모두 통과
- [ ] `wc -l fw lib/*.sh` 가 2,000 이하
- [ ] 삭제된 파일들(`lib/bundle.sh` 외 4개, `MIGRATION.md`, `examples/SCENARIOS.md`)이 `git log` 에 정상 삭제 커밋으로 기록됨
