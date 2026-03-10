#!/usr/bin/env bash
# status.sh - 상태 대시보드 모듈
# 의존: common.sh (로깅, 색상, CONFIG_DIR, VERSION, IPTABLES_BACKEND)
#       validators.sh (check_established_exists)

# ── 상태 대시보드 ───────────────────────────────────

show_status() {
    local line_top="═══════════════════════════════════════════"
    local line_mid="───────────────────────────────────────────"

    # ── 배너 ──
    echo ""
    echo -e "${BOLD}${line_top}${RESET}"
    echo -e "${BOLD}  Firewall Manager 상태${RESET}"
    echo -e "${BOLD}${line_top}${RESET}"

    # ── iptables ──
    local ipt_version
    ipt_version=$(iptables --version 2>/dev/null | grep -oP 'v[\d.]+' || true)
    if [[ -n "$ipt_version" ]]; then
        local backend_label
        if [[ "$IPTABLES_BACKEND" == "nft" ]]; then
            backend_label="nft 백엔드"
        else
            backend_label="legacy 백엔드"
        fi
        echo -e "  iptables:        ${GREEN}✓${RESET} 활성 (${ipt_version}, ${backend_label})"
    else
        echo -e "  iptables:        ${RED}✗${RESET} 미설치"
    fi

    # ── ipset ──
    local ipset_version
    ipset_version=$(ipset version 2>/dev/null | grep -oP 'v[\d.]+' || true)
    if [[ -n "$ipset_version" ]]; then
        echo -e "  ipset:           ${GREEN}✓${RESET} 설치됨 (${ipset_version})"
    else
        echo -e "  ipset:           ${RED}✗${RESET} 미설치"
    fi

    # ── 저장된 규칙 ──
    local rules_file="${CONFIG_DIR}/iptables.rules"
    if [[ -f "$rules_file" ]]; then
        local rules_date
        rules_date=$(date -r "$rules_file" "+%Y-%m-%d %H:%M" 2>/dev/null || stat -c '%y' "$rules_file" 2>/dev/null | cut -d. -f1)
        echo -e "  저장된 규칙:      ${GREEN}✓${RESET} ${CONFIG_DIR}/ (${rules_date})"
    else
        echo -e "  저장된 규칙:      ${YELLOW}!${RESET} 저장된 규칙 없음"
    fi

    # ── 부팅 시 복원 ──
    local fw_restore_status fw_docker_status

    if systemctl is-enabled fw-restore.service &>/dev/null; then
        fw_restore_status=$(systemctl is-enabled fw-restore.service 2>/dev/null)
    else
        fw_restore_status="not-found"
    fi

    if [[ "$fw_restore_status" == "enabled" ]]; then
        echo -e "  부팅 시 복원:     ${GREEN}✓${RESET} fw-restore.service (INPUT)"
    elif [[ "$fw_restore_status" == "not-found" ]]; then
        echo -e "  부팅 시 복원:     ${DIM}-${RESET} fw-restore.service 미설치"
    else
        echo -e "  부팅 시 복원:     ${YELLOW}!${RESET} fw-restore.service 비활성"
    fi

    if systemctl is-enabled fw-docker-rules.service &>/dev/null; then
        fw_docker_status=$(systemctl is-enabled fw-docker-rules.service 2>/dev/null)
    else
        fw_docker_status="not-found"
    fi

    if [[ "$fw_docker_status" == "enabled" ]]; then
        echo -e "                   ${GREEN}✓${RESET} fw-docker-rules.service (DOCKER-USER)"
    elif [[ "$fw_docker_status" == "not-found" ]]; then
        echo -e "                   ${DIM}-${RESET} fw-docker-rules.service 미설치"
    else
        echo -e "                   ${YELLOW}!${RESET} fw-docker-rules.service 비활성"
    fi

    # ── 충돌 도구 ──
    local conflict_parts=()

    if systemctl is-active --quiet ufw 2>/dev/null; then
        conflict_parts+=("${RED}ufw 활성 ✗${RESET}")
    elif systemctl list-unit-files ufw.service &>/dev/null 2>&1 && systemctl list-unit-files ufw.service 2>/dev/null | grep -q ufw; then
        conflict_parts+=("ufw 비활성 ${GREEN}✓${RESET}")
    else
        conflict_parts+=("ufw 미설치 ${GREEN}✓${RESET}")
    fi

    if systemctl is-active --quiet firewalld 2>/dev/null; then
        conflict_parts+=("${RED}firewalld 활성 ✗${RESET}")
    elif systemctl list-unit-files firewalld.service &>/dev/null 2>&1 && systemctl list-unit-files firewalld.service 2>/dev/null | grep -q firewalld; then
        conflict_parts+=("firewalld 비활성 ${GREEN}✓${RESET}")
    else
        conflict_parts+=("firewalld 미설치 ${GREEN}✓${RESET}")
    fi

    local IFS=', '
    echo -e "  충돌 도구:       ${conflict_parts[*]}"
    unset IFS

    # ── 체인 요약 ──
    echo -e "${DIM}${line_mid}${RESET}"
    echo -e "  ${BOLD}체인:${RESET}"

    # INPUT 체인
    local input_count
    input_count=$(iptables -S INPUT 2>/dev/null | grep -cv '^-P' || echo 0)
    local estab_mark
    if check_established_exists; then
        estab_mark="${GREEN}✓${RESET}"
    else
        estab_mark="${YELLOW}⚠${RESET}"
    fi
    printf "    %-16s %s개 규칙  (ESTABLISHED,RELATED %b)\n" "INPUT" "${input_count}" "${estab_mark}"

    # DOCKER-USER 체인
    if iptables -S DOCKER-USER &>/dev/null; then
        local docker_count
        docker_count=$(iptables -S DOCKER-USER 2>/dev/null | grep -cv '^-P\|^-N' || echo 0)
        printf "    %-16s %s개 규칙\n" "DOCKER-USER" "${docker_count}"
    else
        echo -e "    DOCKER-USER      ${DIM}Docker 미설치/미실행${RESET}"
    fi

    # ── 팀 요약 ──
    local team_dir="${CONFIG_DIR}/teams"
    local team_files=()

    if [[ -d "$team_dir" ]]; then
        while IFS= read -r -d '' f; do
            team_files+=("$f")
        done < <(find "$team_dir" -maxdepth 1 -name '*.conf' -print0 2>/dev/null | sort -z)
    fi

    if [[ ${#team_files[@]} -gt 0 ]]; then
        echo -e "${DIM}${line_mid}${RESET}"
        printf "  ${BOLD}%-21s %s${RESET}\n" "팀:" "ipset 동기화"

        for conf_file in "${team_files[@]}"; do
            local team_name
            team_name=$(basename "$conf_file" .conf)

            # conf 파일에서 IP 목록 추출 (주석/빈줄 제외, 파이프 앞부분만)
            local conf_ips conf_count
            conf_ips=$(grep -E '^[0-9]' "$conf_file" 2>/dev/null | cut -d'|' -f1 | sort)
            conf_count=$(echo "$conf_ips" | grep -c . 2>/dev/null || echo 0)

            # ipset 라이브 IP 목록 추출
            local live_ips live_count
            live_ips=$(ipset list "$team_name" 2>/dev/null | grep -E '^[0-9]' | awk '{print $1}' | sort)
            live_count=$(echo "$live_ips" | grep -c . 2>/dev/null || echo 0)

            # 내용 비교 (count가 아닌 실제 IP 목록)
            local sync_mark
            if [[ "$conf_ips" == "$live_ips" ]]; then
                sync_mark="${GREEN}✓ 일치${RESET}"
            else
                sync_mark="${YELLOW}⚠ 불일치${RESET}"
            fi

            printf "    %-17s %3s명       %b\n" "$team_name" "$conf_count" "$sync_mark"
        done
    fi

    # ── 범위 안내 ──
    echo -e "${BOLD}${line_top}${RESET}"
    echo -e "  ${BLUE}i${RESET}  이 도구는 INPUT/DOCKER-USER 체인만 관리합니다."
    echo ""
}
