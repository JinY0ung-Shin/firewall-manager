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
