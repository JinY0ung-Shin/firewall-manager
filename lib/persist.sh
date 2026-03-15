#!/usr/bin/env bash
# persist.sh - 저장/불러오기/백업/복원 (트랜잭셔널 load + 롤백)

# ── 롤백 ────────────────────────────────────────────
_rollback() {
    local snap_dir="/tmp/fw-rollback-$$"

    if [[ ! -d "$snap_dir" ]]; then
        error "롤백 스냅샷을 찾을 수 없습니다: $snap_dir"
        return 1
    fi

    warn "이전 상태로 롤백합니다..."

    if [[ -f "$snap_dir/iptables.snap" ]]; then
        if iptables-restore < "$snap_dir/iptables.snap" 2>/dev/null; then
            info "iptables 롤백 완료"
        else
            error "iptables 롤백 실패!"
        fi
    fi

    if [[ -f "$snap_dir/ipset.snap" ]]; then
        if ipset restore -exist < "$snap_dir/ipset.snap" 2>/dev/null; then
            info "ipset 롤백 완료"
        else
            error "ipset 롤백 실패!"
        fi
    fi

    error "복원 실패, 이전 상태로 롤백했습니다"
    return 0
}

# ── 저장 / 불러오기 메뉴 ────────────────────────────
persist_menu() {
    while true; do
        menu_select "저장 / 불러오기" \
            "현재 규칙 저장" \
            "저장된 규칙 불러오기" \
            "백업 만들기" \
            "백업에서 복원" \
            "이전 번들 내보내기" \
            "이전 번들 가져오기"
        local choice=$?

        case $choice in
            0) return 0 ;;
            1) persist_save ;;
            2) persist_load ;;
            3) persist_backup ;;
            4) persist_restore ;;
            5) bundle_export_interactive ;;
            6) bundle_import_interactive ;;
        esac
    done
}

# ── 현재 규칙 저장 ──────────────────────────────────
persist_save() {
    print_header "현재 규칙 저장"

    # DOCKER-USER 체인 존재 여부 확인
    local has_docker_user=false
    if iptables -L DOCKER-USER -n &>/dev/null; then
        has_docker_user=true
    fi

    # 실행될 명령어 미리보기
    local cmds=()
    cmds+=("iptables -S INPUT > ${CONFIG_DIR}/iptables.rules")
    if $has_docker_user; then
        cmds+=("iptables -S DOCKER-USER >> ${CONFIG_DIR}/iptables.rules")
    fi
    cmds+=("iptables-save > ${CONFIG_DIR}/iptables-full.rules")

    preview_cmd "${cmds[@]}"

    info "팀 메타데이터(teams/*.conf)는 이미 최신 상태입니다."
    echo ""

    if ! prompt_confirm "현재 규칙을 저장하시겠습니까?"; then
        info "취소되었습니다."
        pause
        return 0
    fi

    echo ""

    # INPUT 규칙 저장
    if iptables -S INPUT > "${CONFIG_DIR}/iptables.rules" 2>/dev/null; then
        local input_count
        input_count=$(grep -c '^-A INPUT' "${CONFIG_DIR}/iptables.rules" 2>/dev/null || echo "0")
        success "INPUT 규칙 저장 완료 (${input_count}개)"
    else
        error "INPUT 규칙 저장 실패"
        pause
        return 1
    fi

    # DOCKER-USER 규칙 저장
    if $has_docker_user; then
        if iptables -S DOCKER-USER >> "${CONFIG_DIR}/iptables.rules" 2>/dev/null; then
            local docker_count
            docker_count=$(grep -c '^-A DOCKER-USER' "${CONFIG_DIR}/iptables.rules" 2>/dev/null || echo "0")
            success "DOCKER-USER 규칙 저장 완료 (${docker_count}개)"
        else
            error "DOCKER-USER 규칙 저장 실패"
            pause
            return 1
        fi
    else
        warn "DOCKER-USER 체인이 없습니다. (Docker가 실행 중이 아닐 수 있습니다)"
    fi

    # 전체 스냅샷 저장
    if iptables-save > "${CONFIG_DIR}/iptables-full.rules" 2>/dev/null; then
        success "전체 스냅샷 저장 완료 (iptables-full.rules, 비상 복구용)"
    else
        error "전체 스냅샷 저장 실패"
        pause
        return 1
    fi

    info "저장 위치: ${CONFIG_DIR}/"

    pause
    return 0
}

# ── 저장된 규칙 불러오기 ────────────────────────────
persist_load() {
    local target_chain=""
    local quiet=false
    local skip_verify=false

    # 인자 파싱
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --chain)
                target_chain="$2"
                shift 2
                ;;
            --quiet)
                quiet=true
                shift
                ;;
            --skip-verify)
                skip_verify=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    local rules_file="${CONFIG_DIR}/iptables.rules"
    local snap_dir="/tmp/fw-rollback-$$"

    # ── 저장 파일 존재 확인 ──────────────────────────
    if [[ ! -f "$rules_file" ]]; then
        error "저장된 규칙 파일이 없습니다: $rules_file"
        if ! $quiet; then
            info "'현재 규칙 저장'을 먼저 실행하세요."
            pause
        fi
        return 1
    fi

    # ── 저장 파일 정보 표시 (interactive 모드) ───────
    if ! $quiet; then
        print_header "저장된 규칙 불러오기"

        local rules_date
        rules_date=$(stat -c '%y' "$rules_file" 2>/dev/null | cut -d'.' -f1)
        local input_count
        input_count=$(grep -c '^-A INPUT' "$rules_file" 2>/dev/null || echo "0")
        local docker_count
        docker_count=$(grep -c '^-A DOCKER-USER' "$rules_file" 2>/dev/null || echo "0")

        info "저장된 규칙 정보:"
        echo -e "    iptables: ${rules_file} (${rules_date})"
        echo -e "    INPUT 규칙: ${input_count}개"
        echo -e "    DOCKER-USER 규칙: ${docker_count}개"

        # 팀 정보
        local team_names=""
        if [[ -d "${CONFIG_DIR}/teams" ]]; then
            local conf_files
            conf_files=$(ls "${CONFIG_DIR}/teams/"*.conf 2>/dev/null)
            if [[ -n "$conf_files" ]]; then
                for f in ${conf_files}; do
                    local tname
                    tname=$(basename "$f" .conf)
                    if [[ -n "$team_names" ]]; then
                        team_names+=", "
                    fi
                    team_names+="$tname"
                done
                echo -e "    팀: ${CONFIG_DIR}/teams/ (${team_names})"
            fi
        fi

        echo ""
        warn "현재 INPUT/DOCKER-USER 규칙을 덮어씁니다!"
        echo -e "  ${DIM}(다른 체인은 영향 없음)${RESET}"
        echo ""

        if ! prompt_confirm "불러오시겠습니까?"; then
            info "취소되었습니다."
            pause
            return 0
        fi

        echo ""
    fi

    # ═════════════════════════════════════════════════
    # Step 1: [Snapshot] 현재 상태 스냅샷 (롤백용)
    # ═════════════════════════════════════════════════
    if ! $quiet; then
        info "현재 상태 스냅샷 저장 중... (롤백용)"
    fi

    mkdir -p "$snap_dir"

    if ! iptables-save > "$snap_dir/iptables.snap" 2>/dev/null; then
        error "iptables 스냅샷 저장 실패"
        rm -rf "$snap_dir"
        if ! $quiet; then pause; fi
        return 1
    fi

    if ! ipset save > "$snap_dir/ipset.snap" 2>/dev/null; then
        error "ipset 스냅샷 저장 실패"
        rm -rf "$snap_dir"
        if ! $quiet; then pause; fi
        return 1
    fi

    # ═════════════════════════════════════════════════
    # Step 2: [ipset restore] teams/*.conf 기반 재구성
    # ═════════════════════════════════════════════════
    if [[ "$target_chain" != "DOCKER-USER" ]]; then
        if [[ -d "${CONFIG_DIR}/teams" ]]; then
            local conf_files
            conf_files=$(ls "${CONFIG_DIR}/teams/"*.conf 2>/dev/null)
            if [[ -n "$conf_files" ]]; then
                if ! $quiet; then
                    info "ipset 팀 재구성 중 (teams/*.conf 기반)..."
                fi

                for conf in ${conf_files}; do
                    local team_name
                    team_name=$(basename "$conf" .conf)

                    # ipset 생성 (이미 존재하면 무시)
                    if ! ipset create "$team_name" hash:net comment -exist 2>/dev/null; then
                        error "ipset create 실패: $team_name"
                        _rollback
                        rm -rf "$snap_dir"
                        if ! $quiet; then pause; fi
                        return 1
                    fi

                    # 기존 엔트리 제거
                    if ! ipset flush "$team_name" 2>/dev/null; then
                        error "ipset flush 실패: $team_name"
                        _rollback
                        rm -rf "$snap_dir"
                        if ! $quiet; then pause; fi
                        return 1
                    fi

                    # conf 파일에서 IP|comment 읽어서 추가
                    while IFS= read -r line; do
                        # 주석 및 빈 줄 스킵
                        [[ -z "$line" ]] && continue
                        [[ "$line" == \#* ]] && continue

                        local ip comment
                        ip="${line%%|*}"
                        comment="${line#*|}"

                        # 파이프 이스케이프 복원
                        comment="${comment//\\|/|}"

                        if ! ipset add "$team_name" "$ip" comment "$comment" 2>/dev/null; then
                            error "ipset add 실패: $team_name <- $ip"
                            _rollback
                            rm -rf "$snap_dir"
                            if ! $quiet; then pause; fi
                            return 1
                        fi
                    done < "$conf"
                done

                if ! $quiet; then
                    success "ipset 팀 복원 완료 (teams/*.conf 기반)"
                fi
            fi
        fi
    fi

    # ═════════════════════════════════════════════════
    # Step 3: [iptables restore] 체인 규칙 복원
    # ═════════════════════════════════════════════════

    # INPUT 체인 복원
    if [[ -z "$target_chain" || "$target_chain" == "INPUT" ]]; then
        if ! $quiet; then
            info "INPUT 체인 복원 중..."
        fi

        # INPUT flush
        if ! iptables -F INPUT 2>/dev/null; then
            error "INPUT 체인 flush 실패"
            _rollback
            rm -rf "$snap_dir"
            if ! $quiet; then pause; fi
            return 1
        fi

        # INPUT 규칙 재적용
        local input_failed=false
        while IFS= read -r line; do
            # -A INPUT 으로 시작하는 줄만 처리
            [[ "$line" != -A\ INPUT* ]] && continue

            # -A INPUT 부분을 iptables -A INPUT 으로 변환하여 실행
            # xargs 사용: 따옴표(comment 등)를 올바르게 처리하면서 셸 인젝션 방지
            if ! echo "$line" | xargs iptables 2>/dev/null; then
                error "INPUT 규칙 적용 실패: $line"
                input_failed=true
                break
            fi
        done < "$rules_file"

        if $input_failed; then
            _rollback
            rm -rf "$snap_dir"
            if ! $quiet; then pause; fi
            return 1
        fi

        if ! $quiet; then
            success "INPUT 규칙 복원 완료"
        fi
    fi

    # DOCKER-USER 체인 복원
    if [[ -z "$target_chain" || "$target_chain" == "DOCKER-USER" ]]; then
        if iptables -L DOCKER-USER -n &>/dev/null; then
            if ! $quiet; then
                info "DOCKER-USER 체인 복원 중..."
            fi

            # DOCKER-USER flush
            if ! iptables -F DOCKER-USER 2>/dev/null; then
                error "DOCKER-USER 체인 flush 실패"
                _rollback
                rm -rf "$snap_dir"
                if ! $quiet; then pause; fi
                return 1
            fi

            # DOCKER-USER 규칙 재적용
            local docker_failed=false
            while IFS= read -r line; do
                [[ "$line" != -A\ DOCKER-USER* ]] && continue

                if ! echo "$line" | xargs iptables 2>/dev/null; then
                    error "DOCKER-USER 규칙 적용 실패: $line"
                    docker_failed=true
                    break
                fi
            done < "$rules_file"

            if $docker_failed; then
                _rollback
                rm -rf "$snap_dir"
                if ! $quiet; then pause; fi
                return 1
            fi

            if ! $quiet; then
                success "DOCKER-USER 규칙 복원 완료"
            fi
        else
            if ! $quiet; then
                warn "DOCKER-USER 체인이 없습니다. (Docker가 실행 중이 아닐 수 있습니다)"
            fi
        fi
    fi

    # ═════════════════════════════════════════════════
    # Step 4: [Verify] 안전 검증
    # ═════════════════════════════════════════════════
    if [[ -z "$target_chain" || "$target_chain" == "INPUT" ]]; then
        local verify_failed=false

        # ESTABLISHED,RELATED 규칙 확인
        if ! check_established_exists; then
            if $skip_verify; then
                warn "ESTABLISHED,RELATED 규칙이 INPUT 체인에 없습니다!"
            else
                error "ESTABLISHED,RELATED 규칙이 INPUT 체인에 없습니다!"
                verify_failed=true
            fi
        fi

        # SSH 포트 허용 규칙 확인
        # SSH는 TCP이므로, 다음 중 하나라도 있으면 SSH가 안전하다고 판단:
        # 1) 명시적 SSH 포트 허용: -p tcp --dport <ssh_port> -j ACCEPT
        # 2) TCP 또는 프로토콜 무관 + 포트 무관 ACCEPT (광범위 허용)
        #    예: -s <ip> -j ACCEPT, -m set --match-set <team> src -j ACCEPT
        # 비-TCP 전용 규칙 (예: -p udp -j ACCEPT)은 SSH에 무관하므로 제외
        local ssh_rule_found=false
        local ssh_port="${SSH_CLIENT_PORT:-22}"
        while IFS= read -r rule; do
            [[ "$rule" != *"-j ACCEPT"* ]] && continue

            # 명시적 SSH 포트 허용 (TCP) — 소스 확인 필요
            if [[ "$rule" == *"-p tcp"* && "$rule" == *"--dport ${ssh_port}"* ]]; then
                if [[ "$rule" =~ -s\ ([0-9./]+) && -n "$SSH_CLIENT_IP" ]]; then
                    # 소스 제한 있음: SSH 클라이언트가 범위 내인지 확인
                    if ip_in_cidr "$SSH_CLIENT_IP" "${BASH_REMATCH[1]}"; then
                        ssh_rule_found=true; break
                    fi
                    continue  # 범위 밖이면 이 규칙은 무관
                fi
                if [[ "$rule" =~ --match-set\ ([^ ]+)\ src && -n "$SSH_CLIENT_IP" ]]; then
                    if ipset test "${BASH_REMATCH[1]}" "$SSH_CLIENT_IP" 2>/dev/null; then
                        ssh_rule_found=true; break
                    fi
                    continue
                fi
                # 소스 제한 없음 = SSH-safe
                ssh_rule_found=true; break
            fi

            # 포트 제한 없는 ACCEPT — TCP 또는 프로토콜 무관이어야 함
            if [[ "$rule" != *"--dport "* ]]; then
                # UDP/ICMP 전용이면 SSH에 무관
                if [[ "$rule" == *"-p udp"* || "$rule" == *"-p icmp"* ]]; then
                    continue
                fi

                # 소스 제한이 있는 경우: SSH 클라이언트 IP가 해당 소스에 포함되는지 확인
                if [[ "$rule" =~ -s\ ([0-9./]+) ]]; then
                    local rule_src="${BASH_REMATCH[1]}"
                    if [[ -n "$SSH_CLIENT_IP" ]]; then
                        # SSH 클라이언트가 이 소스 범위에 포함되면 SSH-safe
                        if ip_in_cidr "$SSH_CLIENT_IP" "$rule_src"; then
                            ssh_rule_found=true; break
                        fi
                        # 포함되지 않으면 이 규칙은 SSH와 무관, 다음 규칙 확인
                        continue
                    fi
                fi

                # 소스 제한 없는 전체 ACCEPT = 확실히 SSH-safe
                ssh_rule_found=true; break
            fi
        done <<< "$(iptables -S INPUT 2>/dev/null)"

        if ! $ssh_rule_found; then
            if $skip_verify; then
                warn "SSH 포트(${ssh_port}) 허용 규칙이 INPUT 체인에 없습니다!"
            else
                error "SSH 포트(${ssh_port}) 허용 규칙이 INPUT 체인에 없습니다!"
                verify_failed=true
            fi
        fi

        if $verify_failed; then
            _rollback
            rm -rf "$snap_dir"
            if ! $quiet; then pause; fi
            return 1
        fi

        if ! $quiet; then
            success "검증 통과 (ESTABLISHED,RELATED ✓, SSH 허용 ✓)"
        fi
    fi

    # ═════════════════════════════════════════════════
    # Step 5: [Cleanup] 스냅샷 정리
    # ═════════════════════════════════════════════════
    rm -rf "$snap_dir"

    if ! $quiet; then
        pause
    fi

    return 0
}

# ── 백업 만들기 ─────────────────────────────────────
persist_backup() {
    print_header "백업 만들기"

    local timestamp
    timestamp=$(date +%Y-%m-%d_%H%M%S)
    local backup_dir="${CONFIG_DIR}/backups/${timestamp}"

    info "백업 대상:"
    if [[ -f "${CONFIG_DIR}/iptables.rules" ]]; then
        echo -e "    ${CONFIG_DIR}/iptables.rules"
    else
        warn "iptables.rules 파일이 없습니다. 먼저 '현재 규칙 저장'을 실행하세요."
        pause
        return 1
    fi

    if [[ -f "${CONFIG_DIR}/iptables-full.rules" ]]; then
        echo -e "    ${CONFIG_DIR}/iptables-full.rules"
    fi

    if [[ -d "${CONFIG_DIR}/teams" ]]; then
        local team_count
        team_count=$(ls "${CONFIG_DIR}/teams/"*.conf 2>/dev/null | wc -l)
        echo -e "    ${CONFIG_DIR}/teams/ (${team_count}개 팀)"
    fi

    echo ""
    info "백업 위치: ${backup_dir}/"
    echo ""

    if ! prompt_confirm "백업하시겠습니까?"; then
        info "취소되었습니다."
        pause
        return 0
    fi

    echo ""

    # 백업 디렉토리 생성
    if ! mkdir -p "$backup_dir"; then
        error "백업 디렉토리 생성 실패: $backup_dir"
        pause
        return 1
    fi

    # 파일 복사
    if [[ -f "${CONFIG_DIR}/iptables.rules" ]]; then
        if ! cp "${CONFIG_DIR}/iptables.rules" "$backup_dir/"; then
            error "iptables.rules 복사 실패"
            pause
            return 1
        fi
    fi

    if [[ -f "${CONFIG_DIR}/iptables-full.rules" ]]; then
        if ! cp "${CONFIG_DIR}/iptables-full.rules" "$backup_dir/"; then
            error "iptables-full.rules 복사 실패"
            pause
            return 1
        fi
    fi

    if [[ -d "${CONFIG_DIR}/teams" ]]; then
        if ! cp -r "${CONFIG_DIR}/teams" "$backup_dir/"; then
            error "teams/ 디렉토리 복사 실패"
            pause
            return 1
        fi
    fi

    success "백업 완료: ${backup_dir}/"

    # ── 자동 정리: 최근 10개만 유지 ─────────────────
    local backup_base="${CONFIG_DIR}/backups"
    local backup_list
    backup_list=$(ls -1d "$backup_base"/*/ 2>/dev/null | sort)
    local backup_count
    backup_count=$(echo "$backup_list" | grep -c . 2>/dev/null || echo "0")

    if (( backup_count > 10 )); then
        local delete_count=$(( backup_count - 10 ))
        local old_backups
        old_backups=$(echo "$backup_list" | head -n "$delete_count")

        while IFS= read -r old_dir; do
            [[ -z "$old_dir" ]] && continue
            rm -rf "$old_dir"
        done <<< "$old_backups"

        info "오래된 백업 ${delete_count}개 삭제 (최근 10개만 유지)"
    fi

    pause
    return 0
}

# ── 백업에서 복원 ───────────────────────────────────
persist_restore() {
    print_header "백업에서 복원"

    local backup_base="${CONFIG_DIR}/backups"

    # 백업 목록 확인
    if [[ ! -d "$backup_base" ]]; then
        warn "백업 디렉토리가 없습니다: $backup_base"
        pause
        return 0
    fi

    local -a backup_dirs=()
    local -a backup_names=()
    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        backup_dirs+=("$dir")
        backup_names+=("$(basename "$dir")")
    done <<< "$(ls -1d "$backup_base"/*/ 2>/dev/null | sort -r)"

    if [[ ${#backup_dirs[@]} -eq 0 ]]; then
        warn "사용 가능한 백업이 없습니다."
        pause
        return 0
    fi

    # 백업 목록 표시 및 선택
    prompt_choice "복원할 백업 선택" "${backup_names[@]}"
    local choice=$?

    if [[ $choice -eq 0 ]]; then
        return 0
    fi

    local selected_dir="${backup_dirs[$((choice - 1))]}"
    local selected_name="${backup_names[$((choice - 1))]}"

    echo ""
    info "선택된 백업: ${selected_name}"

    # 백업 내용 확인
    if [[ ! -f "$selected_dir/iptables.rules" ]]; then
        error "백업에 iptables.rules 파일이 없습니다."
        pause
        return 1
    fi

    local bk_input_count
    bk_input_count=$(grep -c '^-A INPUT' "$selected_dir/iptables.rules" 2>/dev/null || echo "0")
    local bk_docker_count
    bk_docker_count=$(grep -c '^-A DOCKER-USER' "$selected_dir/iptables.rules" 2>/dev/null || echo "0")
    echo -e "    INPUT 규칙: ${bk_input_count}개"
    echo -e "    DOCKER-USER 규칙: ${bk_docker_count}개"

    if [[ -d "$selected_dir/teams" ]]; then
        local bk_team_count
        bk_team_count=$(ls "$selected_dir/teams/"*.conf 2>/dev/null | wc -l)
        echo -e "    팀: ${bk_team_count}개"
    fi

    echo ""
    warn "현재 규칙을 덮어씁니다!"
    echo ""

    if ! prompt_confirm "복원하시겠습니까?"; then
        info "취소되었습니다."
        pause
        return 0
    fi

    echo ""

    # 현재 on-disk config를 임시로 백업 (load 실패 시 복구용)
    # 원래 없었던 파일은 롤백 시 삭제해야 하므로 존재 여부 기록
    local config_snap="/tmp/fw-config-snap-$$"
    mkdir -p "$config_snap/teams"
    local had_iptables=false had_iptables_full=false
    if [[ -f "${CONFIG_DIR}/iptables.rules" ]]; then
        cp "${CONFIG_DIR}/iptables.rules" "$config_snap/"
        had_iptables=true
    fi
    if [[ -f "${CONFIG_DIR}/iptables-full.rules" ]]; then
        cp "${CONFIG_DIR}/iptables-full.rules" "$config_snap/"
        had_iptables_full=true
    fi
    # 기존 팀 conf 파일 목록 기록
    ls "${CONFIG_DIR}/teams/"*.conf > "$config_snap/teams/.filelist" 2>/dev/null || true
    cp "${CONFIG_DIR}/teams/"*.conf "$config_snap/teams/" 2>/dev/null || true

    # 백업 파일을 설정 디렉토리로 복사
    if [[ -f "$selected_dir/iptables.rules" ]]; then
        if ! cp "$selected_dir/iptables.rules" "${CONFIG_DIR}/iptables.rules"; then
            error "iptables.rules 복사 실패"
            rm -rf "$config_snap"
            pause
            return 1
        fi
    fi

    if [[ -f "$selected_dir/iptables-full.rules" ]]; then
        if ! cp "$selected_dir/iptables-full.rules" "${CONFIG_DIR}/iptables-full.rules"; then
            error "iptables-full.rules 복사 실패"
            rm -rf "$config_snap"
            pause
            return 1
        fi
    fi

    if [[ -d "$selected_dir/teams" ]]; then
        rm -f "${CONFIG_DIR}/teams/"*.conf 2>/dev/null
        if ! cp "$selected_dir/teams/"*.conf "${CONFIG_DIR}/teams/" 2>/dev/null; then
            :
        fi
    fi

    success "백업 파일 복원 완료"
    info "규칙을 적용합니다..."
    echo ""

    # persist_load를 --quiet로 호출 (이미 confirm을 받았으므로 중복 confirm 방지)
    if persist_load --quiet; then
        rm -rf "$config_snap"
        return 0
    else
        # load 실패: on-disk config도 이전 상태로 복구
        warn "규칙 적용 실패. on-disk 설정을 이전 상태로 복구합니다..."

        # 원래 없었던 파일은 삭제, 있었던 파일은 복구
        if $had_iptables; then
            cp "$config_snap/iptables.rules" "${CONFIG_DIR}/iptables.rules"
        else
            rm -f "${CONFIG_DIR}/iptables.rules"
        fi

        if $had_iptables_full; then
            cp "$config_snap/iptables-full.rules" "${CONFIG_DIR}/iptables-full.rules"
        else
            rm -f "${CONFIG_DIR}/iptables-full.rules"
        fi

        # teams: 원래 있던 파일만 복구, 새로 생긴 파일은 삭제
        rm -f "${CONFIG_DIR}/teams/"*.conf 2>/dev/null
        if [[ -s "$config_snap/teams/.filelist" ]]; then
            cp "$config_snap/teams/"*.conf "${CONFIG_DIR}/teams/" 2>/dev/null || true
        fi
        rm -rf "$config_snap"
        success "on-disk 설정이 이전 상태로 복구되었습니다."
        pause
        return 1
    fi
}
