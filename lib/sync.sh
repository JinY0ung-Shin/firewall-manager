#!/usr/bin/env bash
# sync.sh - live 상태와 config 파일 간 동기화
# 의존: common.sh, validators.sh

# ── 동기화 메뉴 ────────────────────────────────────
sync_menu() {
    while true; do
        menu_select "동기화 (live ↔ config)" \
            "팀 동기화 (ipset ↔ conf)" \
            "규칙 동기화 (iptables ↔ rules)"
        local choice=$?

        case $choice in
            0) return 0 ;;
            1) sync_teams ;;
            2) sync_rules ;;
        esac
    done
}

_team_affects_ssh() {
    local team="$1"
    local rule
    local matched_team

    while IFS= read -r rule; do
        if [[ "$rule" =~ --match-set[[:space:]]+([^[:space:]]+)[[:space:]]+src ]]; then
            matched_team="${BASH_REMATCH[1]}"
        else
            continue
        fi
        [[ "$matched_team" == "$team" ]] || continue
        [[ "$rule" == *"-j ACCEPT"* ]] || continue

        if detect_ssh_rule "$rule"; then
            return 0
        fi

        if [[ -z "$SSH_CLIENT_IP" ]]; then
            if [[ "$rule" == *"--dport ${SSH_CLIENT_PORT}"* ]]; then
                return 0
            fi

            if [[ "$rule" != *"--dport "* &&
                  "$rule" != *"-p udp"* &&
                  "$rule" != *"-p icmp"* &&
                  "$rule" != *"ESTABLISHED"* ]]; then
                return 0
            fi
        fi
    done <<< "$(iptables -S INPUT 2>/dev/null)"

    return 1
}

_conf_team_has_ip() {
    local conf="$1"
    local ip="$2"
    local line

    [[ -n "$ip" ]] || return 1

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue

        local entry_ip="${line%%|*}"
        if ip_in_cidr "$ip" "$entry_ip"; then
            return 0
        fi
    done < "$conf"

    return 1
}

# ── 팀 동기화 ──────────────────────────────────────
sync_teams() {
    print_header "팀 동기화 (ipset ↔ conf)"

    # conf 파일 기반 팀 목록
    local -a conf_teams=()
    if [[ -d "${CONFIG_DIR}/teams" ]]; then
        local f
        for f in "${CONFIG_DIR}/teams/"*.conf; do
            [[ -e "$f" ]] || continue
            conf_teams+=("$(basename "$f" .conf)")
        done
    fi

    # live ipset 기반 팀 목록 (hash:net 타입만)
    local -a live_teams=()
    local _setname=""
    while IFS= read -r _line; do
        if [[ "$_line" == "Name: "* ]]; then
            _setname="${_line#Name: }"
        elif [[ "$_line" == "Type: "* && -n "$_setname" ]]; then
            if [[ "${_line#Type: }" == "hash:net" ]]; then
                live_teams+=("$_setname")
            fi
            _setname=""
        fi
    done <<< "$(ipset list -t 2>/dev/null)"

    # 모든 팀 이름 합집합
    local -a all_teams=()
    local t
    for t in "${conf_teams[@]}"; do
        all_teams+=("$t")
    done
    for t in "${live_teams[@]}"; do
        local found=false
        for c in "${conf_teams[@]}"; do
            [[ "$c" == "$t" ]] && found=true && break
        done
        $found || all_teams+=("$t")
    done

    if [[ ${#all_teams[@]} -eq 0 ]]; then
        info "등록된 팀이 없습니다."
        pause
        return 0
    fi

    # 각 팀별 비교
    local has_diff=false
    local -a diff_teams=()

    for team in "${all_teams[@]}"; do
        local in_conf=false in_live=false
        for c in "${conf_teams[@]}"; do
            [[ "$c" == "$team" ]] && in_conf=true && break
        done
        for l in "${live_teams[@]}"; do
            [[ "$l" == "$team" ]] && in_live=true && break
        done

        if $in_conf && ! $in_live; then
            echo -e "  ${YELLOW}!${RESET} ${BOLD}${team}${RESET}: conf에만 존재 (live에 없음)"
            has_diff=true
            diff_teams+=("$team")
            continue
        fi

        if ! $in_conf && $in_live; then
            echo -e "  ${YELLOW}!${RESET} ${BOLD}${team}${RESET}: live에만 존재 (conf에 없음)"
            has_diff=true
            diff_teams+=("$team")
            continue
        fi

        # 양쪽 모두 존재 — IP 내용 비교
        local conf_ips live_ips
        conf_ips=$(grep -E '^[0-9]' "${CONFIG_DIR}/teams/${team}.conf" 2>/dev/null | cut -d'|' -f1 | sort)
        live_ips=$(ipset list "$team" 2>/dev/null | grep -E '^[0-9]' | awk '{print $1}' | sort)

        if [[ "$conf_ips" == "$live_ips" ]]; then
            echo -e "  ${GREEN}✓${RESET} ${team}: 일치"
        else
            echo -e "  ${YELLOW}!${RESET} ${BOLD}${team}${RESET}: 불일치"

            # conf에만 있는 IP
            local only_conf
            only_conf=$(comm -23 <(echo "$conf_ips") <(echo "$live_ips") 2>/dev/null)
            if [[ -n "$only_conf" ]]; then
                while IFS= read -r ip; do
                    echo -e "      ${DIM}conf에만:${RESET} ${ip}"
                done <<< "$only_conf"
            fi

            # live에만 있는 IP
            local only_live
            only_live=$(comm -13 <(echo "$conf_ips") <(echo "$live_ips") 2>/dev/null)
            if [[ -n "$only_live" ]]; then
                while IFS= read -r ip; do
                    echo -e "      ${DIM}live에만:${RESET} ${ip}"
                done <<< "$only_live"
            fi

            has_diff=true
            diff_teams+=("$team")
        fi
    done

    echo ""

    if ! $has_diff; then
        success "모든 팀이 동기화 상태입니다."
        pause
        return 0
    fi

    # 동기화 방향 선택
    echo ""
    prompt_choice "동기화 방향" \
        "live → conf (현재 ipset 상태를 conf에 저장)" \
        "conf → live (conf 기준으로 ipset 복원)"
    local direction=$?

    if [[ $direction -eq 0 ]]; then pause; return 0; fi

    echo ""

    if [[ $direction -eq 1 ]]; then
        _sync_teams_live_to_conf "${diff_teams[@]}"
    else
        _sync_teams_conf_to_live "${diff_teams[@]}"
    fi

    pause
}

# live ipset → conf 파일로 동기화
_sync_teams_live_to_conf() {
    local teams=("$@")

    for team in "${teams[@]}"; do
        # live에 존재하는지 확인
        if ! ipset list "$team" &>/dev/null; then
            # live에 없음 → conf 삭제
            if [[ -f "${CONFIG_DIR}/teams/${team}.conf" ]]; then
                if prompt_confirm "'${team}' conf 파일을 삭제하시겠습니까? (live에 없음)"; then
                    rm -f "${CONFIG_DIR}/teams/${team}.conf"
                    success "${team}.conf 삭제됨"
                fi
            fi
            continue
        fi

        # live에서 IP+comment 추출
        local conf="${CONFIG_DIR}/teams/${team}.conf"
        local tmpfile
        tmpfile="$(mktemp)"

        # 헤더 유지 또는 새로 생성
        if [[ -f "$conf" ]]; then
            grep '^#' "$conf" > "$tmpfile" 2>/dev/null || true
        else
            echo "# Team: ${team}" > "$tmpfile"
            echo "# Synced: $(date '+%Y-%m-%d %H:%M:%S')" >> "$tmpfile"
        fi

        # ipset list에서 IP와 comment 파싱
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            # 형식: "10.0.0.5/32 comment "홍길동""  또는 "10.0.0.0/24 comment "서버팀""
            local ip comment
            ip=$(echo "$line" | awk '{print $1}')
            comment=""
            if [[ "$line" == *"comment \""* ]]; then
                comment=$(echo "$line" | sed -n 's/.*comment "\(.*\)"/\1/p')
            fi

            # comment 이스케이프
            comment="${comment//|/\\|}"

            if [[ -n "$comment" ]]; then
                echo "${ip}|${comment}" >> "$tmpfile"
            else
                echo "${ip}|imported" >> "$tmpfile"
            fi
        done <<< "$(ipset list "$team" 2>/dev/null | grep -E '^[0-9]')"

        mv "$tmpfile" "$conf"
        success "${team}: live → conf 동기화 완료"
    done
}

# conf 파일 → live ipset으로 동기화
_sync_teams_conf_to_live() {
    local teams=("$@")

    for team in "${teams[@]}"; do
        local conf="${CONFIG_DIR}/teams/${team}.conf"

        if [[ ! -f "$conf" ]]; then
            # conf에 없음 → live에서 삭제
            if ipset list "$team" &>/dev/null; then
                # iptables 참조 확인
                local refs=""
                if refs=$(check_ipset_refs "$team"); then
                    warn "'${team}'을 참조하는 iptables 규칙이 있어 삭제할 수 없습니다."
                    echo -e "$refs"
                    continue
                fi

                if _team_affects_ssh "$team"; then
                    warn "'${team}'은(는) 현재 SSH 허용에 사용 중일 수 있습니다."
                    if ! prompt_confirm_critical "SSH 허용에 쓰일 수 있는 팀을 삭제하려 합니다."; then
                        info "취소되었습니다."
                        continue
                    fi
                fi

                if prompt_confirm "'${team}' ipset을 삭제하시겠습니까? (conf에 없음)"; then
                    if ipset destroy "$team" 2>/dev/null; then
                        success "${team} ipset 삭제됨"
                    else
                        error "${team} ipset 삭제 실패"
                    fi
                fi
            fi
            continue
        fi

        if _team_affects_ssh "$team"; then
            if [[ -n "$SSH_CLIENT_IP" ]]; then
                if ! _conf_team_has_ip "$conf" "$SSH_CLIENT_IP"; then
                    warn "'${team}'은(는) 현재 SSH 허용에 사용 중인데, 새 conf에 현재 접속 IP(${SSH_CLIENT_IP})가 없습니다."
                    if ! prompt_confirm_critical "현재 SSH 접속이 끊길 수 있는 팀 동기화입니다."; then
                        info "취소되었습니다."
                        continue
                    fi
                fi
            else
                warn "'${team}'은(는) SSH 허용에 사용 중일 수 있지만 현재 접속 IP를 검증할 수 없습니다."
                if ! prompt_confirm_critical "SSH 안전성을 검증하지 못한 채 팀을 동기화하려 합니다."; then
                    info "취소되었습니다."
                    continue
                fi
            fi
        fi

        local tmp_set="fw-sync-${RANDOM}-$$"
        if ! ipset create "$tmp_set" hash:net comment 2>/dev/null; then
            error "${team}: 임시 ipset 생성 실패"
            continue
        fi

        local staged_failed=false
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            [[ "$line" == \#* ]] && continue

            local ip comment
            ip="${line%%|*}"
            comment="${line#*|}"
            comment="${comment//\\|/|}"

            if ! ipset add "$tmp_set" "$ip" comment "$comment" 2>/dev/null; then
                error "${team}: ${ip} 추가 실패"
                staged_failed=true
                break
            fi
        done < "$conf"

        if $staged_failed; then
            ipset destroy "$tmp_set" 2>/dev/null || true
            continue
        fi

        local created_live=false
        if ! ipset list "$team" &>/dev/null; then
            created_live=true
        fi

        if ! ipset create "$team" hash:net comment -exist 2>/dev/null; then
            error "${team}: 대상 ipset 생성 실패"
            ipset destroy "$tmp_set" 2>/dev/null || true
            continue
        fi

        if ! ipset swap "$team" "$tmp_set" 2>/dev/null; then
            error "${team}: ipset 교체 실패"
            if $created_live; then
                ipset destroy "$team" 2>/dev/null || true
            fi
            ipset destroy "$tmp_set" 2>/dev/null || true
            continue
        fi

        if ! ipset destroy "$tmp_set" 2>/dev/null; then
            warn "${team}: 이전 ipset 정리 실패"
        fi

        success "${team}: conf → live 동기화 완료"
    done
}

# ── 규칙 동기화 ────────────────────────────────────
sync_rules() {
    print_header "규칙 동기화 (iptables ↔ rules)"

    local rules_file="${CONFIG_DIR}/iptables.rules"
    local has_saved=false

    if [[ -f "$rules_file" ]]; then
        has_saved=true
    fi

    # 현재 live 규칙 가져오기
    local live_input live_docker=""
    live_input=$(iptables -S INPUT 2>/dev/null | grep '^-A INPUT')

    if iptables -L DOCKER-USER -n &>/dev/null; then
        live_docker=$(iptables -S DOCKER-USER 2>/dev/null | grep '^-A DOCKER-USER')
    fi

    local live_all="${live_input}"
    if [[ -n "$live_docker" ]]; then
        live_all+=$'\n'"${live_docker}"
    fi

    if ! $has_saved; then
        warn "저장된 규칙 파일이 없습니다."
        echo ""

        if [[ -z "$live_all" ]]; then
            info "live 규칙도 비어 있습니다."
            pause
            return 0
        fi

        local live_count
        live_count=$(echo "$live_all" | grep -c . 2>/dev/null || echo 0)
        info "live에 ${live_count}개 규칙이 있습니다."
        echo ""

        if prompt_confirm "현재 live 규칙을 conf에 저장하시겠습니까?"; then
            _sync_rules_live_to_conf
        fi

        pause
        return 0
    fi

    # 저장 파일과 live 비교
    local saved_rules
    saved_rules=$(grep '^-A' "$rules_file" 2>/dev/null)
    local live_rules="${live_all}"

    if [[ "$saved_rules" == "$live_rules" ]]; then
        success "live 규칙과 저장된 규칙이 일치합니다."
        pause
        return 0
    fi

    # 차이점 표시
    warn "live 규칙과 저장된 규칙이 다릅니다."
    echo ""

    local saved_sorted
    local live_sorted
    saved_sorted=$(echo "$saved_rules" | sort)
    live_sorted=$(echo "$live_rules" | sort)

    if [[ "$saved_sorted" == "$live_sorted" ]]; then
        warn "규칙 내용은 같지만 순서가 다릅니다. iptables는 규칙 순서에 따라 동작이 달라집니다."
        echo ""
    fi

    local only_live only_saved
    only_live=$(comm -23 <(echo "$live_sorted") <(echo "$saved_sorted") 2>/dev/null)
    only_saved=$(comm -13 <(echo "$live_sorted") <(echo "$saved_sorted") 2>/dev/null)

    if [[ -n "$only_live" ]]; then
        echo -e "  ${BOLD}live에만 있는 규칙:${RESET}"
        while IFS= read -r line; do
            echo -e "    ${GREEN}+ ${line}${RESET}"
        done <<< "$only_live"
        echo ""
    fi

    if [[ -n "$only_saved" ]]; then
        echo -e "  ${BOLD}저장 파일에만 있는 규칙:${RESET}"
        while IFS= read -r line; do
            echo -e "    ${RED}- ${line}${RESET}"
        done <<< "$only_saved"
        echo ""
    fi

    # 동기화 방향 선택
    prompt_choice "동기화 방향" \
        "live → conf (현재 iptables 상태를 파일에 저장)" \
        "conf → live (저장된 규칙을 iptables에 적용)"
    local direction=$?

    if [[ $direction -eq 0 ]]; then pause; return 0; fi

    echo ""

    if [[ $direction -eq 1 ]]; then
        _sync_rules_live_to_conf
    else
        info "저장된 규칙을 적용합니다..."
        persist_load
        return $?
    fi

    pause
}

# live iptables → conf 파일로 저장
_sync_rules_live_to_conf() {
    local rules_file="${CONFIG_DIR}/iptables.rules"

    # INPUT 저장
    if iptables -S INPUT > "${rules_file}" 2>/dev/null; then
        local input_count
        input_count=$(grep -c '^-A INPUT' "${rules_file}" 2>/dev/null || echo "0")
        success "INPUT 규칙 저장 (${input_count}개)"
    else
        error "INPUT 규칙 저장 실패"
        return 1
    fi

    # DOCKER-USER 저장
    if iptables -L DOCKER-USER -n &>/dev/null; then
        if iptables -S DOCKER-USER >> "${rules_file}" 2>/dev/null; then
            local docker_count
            docker_count=$(grep -c '^-A DOCKER-USER' "${rules_file}" 2>/dev/null || echo "0")
            success "DOCKER-USER 규칙 저장 (${docker_count}개)"
        fi
    fi

    # 전체 스냅샷
    if iptables-save > "${CONFIG_DIR}/iptables-full.rules" 2>/dev/null; then
        success "전체 스냅샷 저장 (iptables-full.rules)"
    fi

    success "동기화 완료: live → conf"
}
