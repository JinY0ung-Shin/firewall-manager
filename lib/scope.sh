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
