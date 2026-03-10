#!/usr/bin/env bash
# rule.sh - iptables 규칙 관리 (interactive 흐름)

# ── 규칙 관리 서브메뉴 ─────────────────────────────
rule_menu() {
    while true; do
        menu_select "규칙 관리" \
            "규칙 목록 보기" \
            "규칙 추가" \
            "규칙 삭제"
        local choice=$?

        case $choice in
            1) rule_list; pause ;;
            2) rule_add; pause ;;
            3) rule_remove; pause ;;
            0) return ;;
        esac
    done
}

# ── 규칙 파싱 (공통) ───────────────────────────────
# iptables -S 출력을 파싱하여 테이블 행 배열에 채운다.
# 인자: chain
# 출력: _parsed_rows 배열 (전역), _parsed_raw 배열 (전역, 원본 줄)
_parse_rules() {
    local chain="$1"
    _parsed_rows=()
    _parsed_raw=()

    local line_num=0
    while IFS= read -r line; do
        # -P (정책) 및 -N (체인 정의) 라인 스킵
        [[ "$line" == -P* ]] && continue
        [[ "$line" == -N* ]] && continue
        line_num=$((line_num + 1))

        local action="" proto="all" source="0.0.0.0/0" port="all" comment=""

        # 액션 추출
        if [[ "$line" =~ -j\ ([A-Z]+) ]]; then
            action="${BASH_REMATCH[1]}"
        fi

        # 프로토콜 추출
        if [[ "$line" =~ -p\ ([a-z]+) ]]; then
            proto="${BASH_REMATCH[1]}"
        fi

        # 소스 추출
        if [[ "$line" =~ -s\ ([0-9./]+) ]]; then
            source="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ --match-set\ ([^ ]+)\ src ]]; then
            source="team:${BASH_REMATCH[1]}"
        fi

        # 포트 추출
        if [[ "$line" =~ --dport\ ([0-9]+) ]]; then
            port="${BASH_REMATCH[1]}"
        fi

        # comment 추출
        if [[ "$line" =~ --comment\ \"([^\"]+)\" ]]; then
            comment="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ --comment\ ([^ ]+) ]]; then
            comment="${BASH_REMATCH[1]}"
        fi

        _parsed_rows+=("${line_num}|${action}|${proto}|${source}|${port}|${comment}")
        _parsed_raw+=("$line")
    done <<< "$(iptables -S "$chain" 2>/dev/null)"
}

# ── 규칙 목록 보기 ─────────────────────────────────
rule_list() {
    print_header "규칙 목록 보기"

    # 체인 선택
    prompt_choice "체인 선택" "INPUT" "DOCKER-USER"
    local chain_choice=$?
    if [[ $chain_choice -eq 0 ]]; then return; fi
    local chain
    case $chain_choice in
        1) chain="INPUT" ;;
        2) chain="DOCKER-USER" ;;
    esac

    # DOCKER-USER 체인 존재 확인
    if [[ "$chain" == "DOCKER-USER" ]]; then
        if ! iptables -nL DOCKER-USER &>/dev/null; then
            warn "DOCKER-USER 체인이 존재하지 않습니다."
            info "Docker가 설치되어 실행 중이어야 DOCKER-USER 체인이 생성됩니다."
            return
        fi
    fi

    # 규칙 파싱
    _parse_rules "$chain"

    if [[ ${#_parsed_rows[@]} -eq 0 ]]; then
        info "${chain} 체인에 규칙이 없습니다."
        return
    fi

    # 테이블 출력
    print_table "#|Action|Proto|Source|Port|Comment" "${_parsed_rows[@]}"
}

# ── 규칙 추가 (Step-by-step Wizard) ───────────────
rule_add() {
    print_header "규칙 추가"

    # Step 1: 체인 선택
    prompt_choice "체인 선택" "INPUT" "DOCKER-USER"
    local chain_choice=$?
    if [[ $chain_choice -eq 0 ]]; then return; fi
    local chain
    case $chain_choice in
        1) chain="INPUT" ;;
        2) chain="DOCKER-USER" ;;
    esac

    # DOCKER-USER 체인 존재 확인
    if [[ "$chain" == "DOCKER-USER" ]]; then
        if ! iptables -nL DOCKER-USER &>/dev/null; then
            warn "DOCKER-USER 체인이 존재하지 않습니다."
            info "Docker가 설치되어 실행 중이어야 DOCKER-USER 체인이 생성됩니다."
            return
        fi
    fi

    echo ""

    # Step 2: 액션 선택
    prompt_choice "액션 선택" "ACCEPT (허용)" "DROP (차단)" "REJECT (거부)"
    local action_choice=$?
    if [[ $action_choice -eq 0 ]]; then return; fi
    local action
    case $action_choice in
        1) action="ACCEPT" ;;
        2) action="DROP" ;;
        3) action="REJECT" ;;
    esac

    echo ""

    # Step 3: 소스 지정
    local source=""
    local source_type=""
    local source_display=""
    local team_name=""

    prompt_choice "소스 지정" "IP 주소 직접 입력" "팀(ipset)에서 선택" "모든 소스 (0.0.0.0/0)"
    local src_choice=$?
    if [[ $src_choice -eq 0 ]]; then return 0; fi

    case $src_choice in
        1)
            source_type="ip"
            if ! read_valid_ip "IP 주소 (CIDR 가능, 빈 입력=취소)"; then
                return 0
            fi
            source="$REPLY"
            source_display="$source"
            ;;
        2)
            source_type="team"
            # ipset 목록 가져오기
            local ipsets=()
            while IFS= read -r setname; do
                [[ -n "$setname" ]] && ipsets+=("$setname")
            done <<< "$(ipset list -n 2>/dev/null)"

            if [[ ${#ipsets[@]} -eq 0 ]]; then
                warn "등록된 팀(ipset)이 없습니다."
                info "IP 주소를 직접 입력합니다."
                source_type="ip"
                if ! read_valid_ip "IP 주소 (CIDR 가능, 빈 입력=취소)"; then
                    return 0
                fi
                source="$REPLY"
                source_display="$source"
            else
                echo ""
                prompt_choice "팀 선택" "${ipsets[@]}"
                local team_choice=$?
                if [[ $team_choice -eq 0 ]]; then return 0; fi
                team_name="${ipsets[$((team_choice - 1))]}"
                source="$team_name"
                source_display="team:${team_name}"
            fi
            ;;
        3)
            source_type="all"
            source="0.0.0.0/0"
            source_display="0.0.0.0/0 (모든 소스)"
            ;;
    esac

    echo ""

    # Step 4: 포트 번호
    if ! read_valid_port "포트 번호 (전체는 'all', 빈 입력=취소)"; then
        return 0
    fi
    local port="$REPLY"

    # Step 5: 프로토콜 (포트가 all이 아닐 때만)
    local proto="all"
    if [[ "$port" != "all" ]]; then
        echo ""
        prompt_choice "프로토콜" "tcp" "udp" "all"
        local proto_choice=$?
        if [[ $proto_choice -eq 0 ]]; then return 0; fi
        case $proto_choice in
            1) proto="tcp" ;;
            2) proto="udp" ;;
            3) proto="all" ;;
        esac

        # 포트가 지정되었는데 프로토콜이 all이면 tcp로 자동 설정
        if [[ "$proto" == "all" ]]; then
            proto="tcp"
            echo ""
            info "포트가 지정된 경우 프로토콜이 필요합니다. tcp로 자동 설정합니다."
        fi
    fi

    echo ""

    # Step 6: 설명 (선택사항)
    prompt_input_optional "설명 (선택사항)"
    local comment="$REPLY"
    # comment 내의 위험 문자 제거 (셸 인젝션 방지)
    comment="${comment//\"/}"
    comment="${comment//\$/}"
    comment="${comment//\`/}"
    comment="${comment//\\/}"

    # ── iptables 명령어 구성 (배열 기반, eval 사용하지 않음) ──
    local -a cmd_args=(iptables -A "$chain")

    # 소스
    if [[ "$source_type" == "ip" ]]; then
        cmd_args+=(-s "$source")
    elif [[ "$source_type" == "team" ]]; then
        cmd_args+=(-m set --match-set "$source" src)
    fi
    # source_type == "all"이면 -s 생략 (모든 소스)

    # 프로토콜
    if [[ "$proto" != "all" ]]; then
        cmd_args+=(-p "$proto")
    fi

    # 포트
    if [[ "$port" != "all" ]]; then
        cmd_args+=(--dport "$port")
    fi

    # comment
    if [[ -n "$comment" ]]; then
        cmd_args+=(-m comment --comment "$comment")
    fi

    # 액션
    cmd_args+=(-j "$action")

    # 미리보기용 문자열 (표시용)
    local cmd_display="iptables -A ${chain}"
    [[ "$source_type" == "ip" ]] && cmd_display+=" -s ${source}"
    [[ "$source_type" == "team" ]] && cmd_display+=" -m set --match-set ${source} src"
    [[ "$proto" != "all" ]] && cmd_display+=" -p ${proto}"
    [[ "$port" != "all" ]] && cmd_display+=" --dport ${port}"
    [[ -n "$comment" ]] && cmd_display+=" -m comment --comment \"${comment}\""
    cmd_display+=" -j ${action}"

    # ── 요약 표시 ────────────────────────────────
    print_header "확인"
    echo -e "  체인:     ${BOLD}${chain}${RESET}"
    echo -e "  액션:     ${BOLD}${action}${RESET}"
    echo -e "  소스:     ${BOLD}${source_display}${RESET}"
    echo -e "  포트:     ${BOLD}${port}${RESET}"
    echo -e "  프로토콜: ${BOLD}${proto}${RESET}"
    if [[ -n "$comment" ]]; then
        echo -e "  설명:     ${BOLD}${comment}${RESET}"
    fi

    preview_cmd "$cmd_display"

    # ── 중복 규칙 검사 ───────────────────────────
    local dup_src="$source"
    [[ "$source_type" == "team" ]] && dup_src="team:${source}"
    [[ "$source_type" == "all" ]] && dup_src="0.0.0.0/0"
    local dup_num
    if dup_num=$(check_duplicate_rule "$chain" "$dup_src" "$port" "$proto" "$action"); then
        warn "동일한 규칙이 이미 존재합니다 (#${dup_num}번)"
        if ! prompt_confirm "그래도 추가하시겠습니까?"; then
            info "취소되었습니다."
            return
        fi
    fi

    # ── SSH 충돌 검사 ────────────────────────────
    if [[ "$action" == "DROP" || "$action" == "REJECT" ]]; then
        local ssh_src="$source"
        [[ "$source_type" == "all" ]] && ssh_src="0.0.0.0/0"
        [[ "$source_type" == "team" ]] && ssh_src="team:${source}"

        if detect_ssh_conflict_add "$chain" "$action" "$ssh_src" "$port" "$proto"; then
            echo ""
            echo -e "  ${RED}${BOLD}경고: 이 규칙은 SSH 접속(포트 ${SSH_CLIENT_PORT})을 차단할 수 있습니다!${RESET}"
            if [[ -n "$SSH_CLIENT_IP" ]]; then
                echo -e "  현재 접속 중인 IP: ${BOLD}${SSH_CLIENT_IP}${RESET}"
            fi
            echo -e "  이 규칙을 적용하면 서버에 접속할 수 없게 될 수 있습니다."

            if ! prompt_confirm_critical "SSH 접속이 차단될 수 있는 규칙입니다."; then
                info "취소되었습니다."
                return
            fi
        fi
    fi

    # ── ESTABLISHED,RELATED 규칙 존재 확인 ───────
    if [[ "$chain" == "INPUT" ]]; then
        if ! check_established_exists; then
            echo ""
            warn "INPUT 체인에 ESTABLISHED,RELATED 허용 규칙이 없습니다!"
            info "기존 연결이 끊어질 수 있습니다."

            if prompt_confirm "기본 보호 규칙을 먼저 추가하시겠습니까?"; then
                local est_cmd="iptables -I INPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
                preview_cmd "$est_cmd"
                if iptables -I INPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT; then
                    success "기본 보호 규칙(ESTABLISHED,RELATED)이 추가되었습니다."
                else
                    error "기본 보호 규칙 추가에 실패했습니다."
                fi
            fi
        fi
    fi

    # ── 최종 확인 및 실행 ────────────────────────
    if ! prompt_confirm "이 규칙을 추가하시겠습니까?"; then
        info "취소되었습니다."
        return
    fi

    if "${cmd_args[@]}"; then
        success "규칙이 추가되었습니다."

        # DROP/REJECT 규칙: 60초 안전 타이머 롤백
        if [[ "$action" == "DROP" || "$action" == "REJECT" ]]; then
            _safety_timer_rollback "$chain" "$cmd_display"
        else
            echo ""
            info "저장하려면 메인 메뉴 → '저장 / 불러오기'를 이용하세요."
        fi
    else
        error "규칙 추가에 실패했습니다."
    fi
}

# ── 안전 타이머 롤백 ───────────────────────────────
# DROP/REJECT 규칙 추가 후 60초 이내에 확인하지 않으면 자동 제거
_safety_timer_rollback() {
    local chain="$1"
    local add_cmd="$2"

    # -A 를 -D 로 바꿔서 삭제 명령어 생성
    local del_cmd="${add_cmd/-A /-D }"
    # "iptables " 접두어 제거 (xargs에서 iptables를 직접 호출하므로)
    local del_args="${del_cmd#iptables }"

    echo ""
    warn "안전 확인: 60초 이내에 Enter를 누르면 규칙이 유지됩니다."
    info "시간 내에 응답하지 않으면 자동으로 규칙이 제거됩니다..."
    echo ""

    # 백그라운드 롤백 프로세스 시작 (xargs로 안전하게 실행, eval 사용 안 함)
    (
        sleep 60
        echo "$del_args" | xargs iptables 2>/dev/null
    ) &
    local rollback_pid=$!

    # 사용자 입력 대기 (60초 타임아웃)
    local confirmed=false
    if read -rt 60 -p "  [확인하려면 Enter] " _; then
        confirmed=true
    fi

    if $confirmed; then
        # 사용자가 확인함 -> 롤백 프로세스 종료
        kill "$rollback_pid" 2>/dev/null
        wait "$rollback_pid" 2>/dev/null
        echo ""
        success "규칙이 확정되었습니다."
        info "저장하려면 메인 메뉴 → '저장 / 불러오기'를 이용하세요."
    else
        # 타임아웃 -> 롤백 프로세스가 자동 제거 처리
        echo ""
        warn "60초 초과 - 규칙이 자동으로 제거됩니다."
        # 롤백 프로세스가 이미 실행 중이므로 완료 대기
        wait "$rollback_pid" 2>/dev/null
        info "규칙이 제거되었습니다. (안전 롤백)"
    fi
}

# ── 규칙 삭제 ──────────────────────────────────────
rule_remove() {
    print_header "규칙 삭제"

    # 체인 선택
    prompt_choice "체인 선택" "INPUT" "DOCKER-USER"
    local chain_choice=$?
    if [[ $chain_choice -eq 0 ]]; then return; fi
    local chain
    case $chain_choice in
        1) chain="INPUT" ;;
        2) chain="DOCKER-USER" ;;
    esac

    # DOCKER-USER 체인 존재 확인
    if [[ "$chain" == "DOCKER-USER" ]]; then
        if ! iptables -nL DOCKER-USER &>/dev/null; then
            warn "DOCKER-USER 체인이 존재하지 않습니다."
            info "Docker가 설치되어 실행 중이어야 DOCKER-USER 체인이 생성됩니다."
            return
        fi
    fi

    # 현재 규칙 표시
    _parse_rules "$chain"

    if [[ ${#_parsed_rows[@]} -eq 0 ]]; then
        info "${chain} 체인에 삭제할 규칙이 없습니다."
        return
    fi

    echo -e "  ${BOLD}현재 규칙:${RESET}"
    print_table "#|Action|Proto|Source|Port|Comment" "${_parsed_rows[@]}"

    # 삭제할 규칙 번호 입력
    local rule_num
    while true; do
        read -rp "  삭제할 규칙 번호 (빈 입력=취소): " rule_num
        if [[ -z "$rule_num" ]]; then
            return
        fi
        if [[ "$rule_num" =~ ^[0-9]+$ ]] && (( rule_num >= 1 && rule_num <= ${#_parsed_rows[@]} )); then
            break
        fi
        error "1~${#_parsed_rows[@]} 사이의 숫자를 입력하세요."
    done

    # 선택된 규칙의 원본 줄 가져오기
    local raw_rule="${_parsed_raw[$((rule_num - 1))]}"

    # SSH 허용 규칙 삭제 감지
    if detect_ssh_rule "$raw_rule"; then
        echo ""
        echo -e "  ${RED}${BOLD}경고: 이 규칙은 현재 SSH 접속을 허용하고 있습니다!${RESET}"
        echo -e "  삭제하면 서버에 접속할 수 없게 될 수 있습니다."

        if ! prompt_confirm_critical "SSH 허용 규칙을 삭제하려 합니다."; then
            info "취소되었습니다."
            return
        fi
    fi

    # ESTABLISHED,RELATED 규칙 삭제 감지
    if detect_established_rule "$raw_rule"; then
        echo ""
        echo -e "  ${RED}${BOLD}경고: 이 규칙은 기존 연결 유지에 필수적입니다!${RESET}"
        echo -e "  삭제하면 현재 SSH를 포함한 모든 기존 연결이 끊어질 수 있습니다."

        if ! prompt_confirm_critical "ESTABLISHED,RELATED 규칙을 삭제하려 합니다."; then
            info "취소되었습니다."
            return
        fi
    fi

    # 미리보기 및 확인
    local del_cmd="iptables -D ${chain} ${rule_num}"
    preview_cmd "$del_cmd"

    if ! prompt_confirm "이 규칙을 삭제하시겠습니까?"; then
        info "취소되었습니다."
        return
    fi

    # 실행 (eval 사용하지 않음 — 인자가 단순하므로 직접 호출)
    if iptables -D "$chain" "$rule_num"; then
        success "규칙이 삭제되었습니다."
        info "저장하려면 메인 메뉴 → '저장 / 불러오기'를 이용하세요."
    else
        error "규칙 삭제에 실패했습니다."
    fi
}
