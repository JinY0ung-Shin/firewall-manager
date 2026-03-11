#!/usr/bin/env bash
# team.sh - ipset 팀 관리 (interactive 흐름)
# common.sh, validators.sh가 이미 source된 상태에서 사용

# ── 자동 가져오기 ────────────────────────────────

# 시작 시 기존 ipset 셋(hash:net)을 conf 파일로 자동 가져오기
auto_import_teams() {
    local teams_dir="${CONFIG_DIR}/teams"
    local imported=0
    local setname=""

    while IFS= read -r line; do
        if [[ "$line" == "Name: "* ]]; then
            setname="${line#Name: }"
        elif [[ "$line" == "Type: "* && -n "$setname" ]]; then
            local settype="${line#Type: }"
            if [[ "$settype" == "hash:net" && ! -f "${teams_dir}/${setname}.conf" ]]; then
                # conf 파일 생성
                local tmpfile
                tmpfile="$(mktemp)"
                echo "# Team: ${setname}" > "$tmpfile"
                echo "# Imported: $(date '+%Y-%m-%d %H:%M:%S')" >> "$tmpfile"

                # live ipset에서 멤버 가져오기
                while IFS= read -r entry; do
                    [[ -z "$entry" ]] && continue
                    local ip comment
                    ip=$(echo "$entry" | awk '{print $1}')
                    comment=""
                    if [[ "$entry" == *"comment \""* ]]; then
                        comment=$(echo "$entry" | sed -n 's/.*comment "\(.*\)"/\1/p')
                    fi
                    comment="${comment//|/\\|}"
                    if [[ -n "$comment" ]]; then
                        echo "${ip}|${comment}" >> "$tmpfile"
                    else
                        echo "${ip}|imported" >> "$tmpfile"
                    fi
                done <<< "$(ipset list "$setname" 2>/dev/null | grep -E '^[0-9]')"

                mv "$tmpfile" "${teams_dir}/${setname}.conf"
                imported=$((imported + 1))
            fi
            setname=""
        fi
    done <<< "$(ipset list -t 2>/dev/null)"

    if [[ $imported -gt 0 ]]; then
        info "기존 ipset ${imported}개를 자동으로 가져왔습니다."
    fi
}

# ── 헬퍼 함수 ────────────────────────────────────

# 팀 목록 배열 반환 (teams/*.conf 기반)
# 사용: local teams=(); _get_team_list teams
_get_team_list() {
    local -n _result=$1
    _result=()

    local teams_dir="${CONFIG_DIR}/teams"
    if [[ ! -d "$teams_dir" ]]; then
        return 0
    fi

    local f
    for f in "${teams_dir}"/*.conf; do
        [[ -e "$f" ]] || continue
        local name
        name="$(basename "$f" .conf)"
        _result+=("$name")
    done
}

# 팀 멤버 배열 반환 (ip|comment 라인만)
# 사용: local members=(); _get_team_members "팀이름" members
_get_team_members() {
    local team="$1"
    local -n _members=$2
    _members=()

    local conf="${CONFIG_DIR}/teams/${team}.conf"
    if [[ ! -f "$conf" ]]; then
        return 1
    fi

    local line
    while IFS= read -r line; do
        # 주석과 빈 줄 건너뛰기
        [[ -z "$line" ]] && continue
        [[ "$line" == \#* ]] && continue
        _members+=("$line")
    done < "$conf"
}

# 인터랙티브 팀 선택 - 화살표 메뉴로 팀을 선택
# 사용: local team; if ! _select_team team; then ... fi
_select_team() {
    local -n _selected_team=$1
    local teams=()
    _get_team_list teams

    if [[ ${#teams[@]} -eq 0 ]]; then
        warn "등록된 팀이 없습니다."
        info "먼저 '팀 만들기'로 팀을 생성하세요."
        return 1
    fi

    # 각 팀의 멤버 수 계산하여 옵션 배열 구성
    local options=()
    local i
    for i in "${!teams[@]}"; do
        local name="${teams[$i]}"
        local members=()
        _get_team_members "$name" members
        options+=("${name} (${#members[@]}명)")
    done

    menu_select "팀 선택" "${options[@]}"
    local choice=$?

    if [[ $choice -eq 0 ]]; then
        return 1
    fi

    _selected_team="${teams[$((choice - 1))]}"
    return 0
}

# ── 메인 함수 ────────────────────────────────────

team_menu() {
    while true; do
        menu_select "팀 관리 (ipset)" \
            "팀 목록 보기" \
            "팀 만들기" \
            "팀에 IP 추가" \
            "팀에서 IP 제거" \
            "팀 삭제"
        local choice=$?

        case $choice in
            1) team_list ;;
            2) team_create ;;
            3) team_add_ip ;;
            4) team_remove_ip ;;
            5) team_delete ;;
            0) return 0 ;;
        esac
    done
}

team_list() {
    clear_screen
    print_header "팀 목록"

    local teams=()
    _get_team_list teams

    if [[ ${#teams[@]} -eq 0 ]]; then
        info "등록된 팀이 없습니다."
        pause
        return 0
    fi

    # 테이블 행 구성
    local rows=()
    local i
    for i in "${!teams[@]}"; do
        local name="${teams[$i]}"
        local members=()
        _get_team_members "$name" members
        rows+=("$((i + 1))|${name}|${#members[@]}")
    done

    print_table "#|이름|멤버 수" "${rows[@]}"

    # 상세 보기 - 화살표 메뉴
    local options=()
    for i in "${!teams[@]}"; do
        local name="${teams[$i]}"
        local members=()
        _get_team_members "$name" members
        options+=("${name} (${#members[@]}명)")
    done

    prompt_choice "상세 보기할 팀 선택" "${options[@]}"
    local choice=$?

    if [[ $choice -eq 0 ]]; then
        return 0
    fi

    local selected="${teams[$((choice - 1))]}"
    local members=()
    _get_team_members "$selected" members

    print_header "${selected} (${#members[@]}명)"

    if [[ ${#members[@]} -eq 0 ]]; then
        info "멤버가 없습니다."
        pause
        return 0
    fi

    local detail_rows=()
    local idx=1
    for entry in "${members[@]}"; do
        # ip|escaped_comment 파싱 — 첫 번째 이스케이프되지 않은 | 기준으로 분리
        local ip comment
        ip="${entry%%|*}"
        comment="${entry#*|}"
        comment="$(unescape_comment "$comment")"
        detail_rows+=("${idx}|${ip}|${comment}")
        idx=$((idx + 1))
    done

    print_table "#|IP / CIDR|설명" "${detail_rows[@]}"

    pause
}

team_create() {
    clear_screen
    print_header "팀 만들기"

    if ! read_valid_team_name "팀 이름 (영문, 숫자, 하이픈, 빈 입력=취소)"; then
        return 0
    fi
    local name="$REPLY"

    # 이미 존재하는 ipset인지 확인
    if ipset list -n 2>/dev/null | grep -q "^${name}$"; then
        error "ipset '${name}'이(가) 이미 존재합니다."
        pause
        return 1
    fi

    # conf 파일도 이미 존재하는지 확인
    if [[ -f "${CONFIG_DIR}/teams/${name}.conf" ]]; then
        error "팀 설정 파일 '${name}.conf'가 이미 존재합니다."
        pause
        return 1
    fi

    local cmd="ipset create ${name} hash:net comment"
    preview_cmd "$cmd"

    if ! prompt_confirm "생성하시겠습니까?"; then
        info "취소되었습니다."
        pause
        return 0
    fi

    # ipset 생성 먼저
    local err
    if err=$(ipset create "$name" hash:net comment 2>&1); then
        # 성공 시 conf 파일 생성
        local created
        created="$(date '+%Y-%m-%d %H:%M:%S')"
        cat > "${CONFIG_DIR}/teams/${name}.conf" <<EOF
# Team: ${name}
# Created: ${created}
EOF
        success "팀 '${name}'이(가) 생성되었습니다."
        info "'팀에 IP 추가'로 멤버를 추가하세요."
    else
        error "ipset create 실패: ${err}"
        pause
    fi
}

team_add_ip() {
    local team
    if ! _select_team team; then
        pause
        return 0
    fi

    clear_screen
    print_header "팀에 IP 추가 (${team})"

    if ! read_valid_ip "IP 주소 (CIDR 가능, 빈 입력=취소)"; then
        return 0
    fi
    local ip="$REPLY"

    # 이미 해당 IP가 팀에 존재하는지 확인
    local conf="${CONFIG_DIR}/teams/${team}.conf"
    if grep -q "^${ip}|" "$conf" 2>/dev/null; then
        warn "'${ip}'는 이미 '${team}' 팀에 등록되어 있습니다."
        return 0
    fi

    if ! read_valid_comment "설명 (누구/무엇인지, 빈 입력=취소)"; then
        return 0
    fi
    local comment="$REPLY"

    # 언이스케이프된 comment로 ipset 명령어 구성 (표시용)
    local display_comment
    display_comment="$(unescape_comment "$comment")"
    local cmd="ipset add ${team} ${ip} comment \"${display_comment}\""
    preview_cmd "$cmd"

    if ! prompt_confirm "추가하시겠습니까?"; then
        info "취소되었습니다."
        pause
        return 0
    fi

    # ipset add 먼저 실행
    local err
    if err=$(ipset add "$team" "$ip" comment "$display_comment" 2>&1); then
        # 성공 시 conf 파일에 추가
        echo "${ip}|${comment}" >> "$conf"
        success "${team} 팀에 ${ip} (${display_comment}) 추가 완료"
    else
        error "ipset add 실패: ${err}"
        pause
    fi
}

team_remove_ip() {
    local team
    if ! _select_team team; then
        pause
        return 0
    fi

    clear_screen
    print_header "팀에서 IP 제거 (${team})"

    local members=()
    _get_team_members "$team" members

    if [[ ${#members[@]} -eq 0 ]]; then
        warn "'${team}' 팀에 멤버가 없습니다."
        pause
        return 0
    fi

    # 멤버 선택 - 화살표 메뉴
    local options=()
    for entry in "${members[@]}"; do
        local ip comment
        ip="${entry%%|*}"
        comment="${entry#*|}"
        comment="$(unescape_comment "$comment")"
        options+=("${ip}  ${comment}")
    done

    menu_select "제거할 IP 선택 (${team})" "${options[@]}"
    local choice=$?

    if [[ $choice -eq 0 ]]; then
        return 0
    fi

    local selected="${members[$((choice - 1))]}"
    local ip="${selected%%|*}"
    local comment="${selected#*|}"
    local display_comment
    display_comment="$(unescape_comment "$comment")"

    local cmd="ipset del ${team} ${ip}"
    preview_cmd "$cmd"

    if ! prompt_confirm "제거하시겠습니까?"; then
        info "취소되었습니다."
        pause
        return 0
    fi

    # ipset del 먼저 실행
    local err
    if err=$(ipset del "$team" "$ip" 2>&1); then
        # 성공 시 conf 파일에서 해당 라인 제거
        local conf="${CONFIG_DIR}/teams/${team}.conf"
        local tmpfile
        tmpfile="$(mktemp)"
        while IFS= read -r line; do
            # 정확히 일치하는 라인만 제거 (ip|comment)
            if [[ "$line" == "${selected}" ]]; then
                continue
            fi
            echo "$line"
        done < "$conf" > "$tmpfile"
        mv "$tmpfile" "$conf"
        success "${ip} (${display_comment})이(가) ${team}에서 제거되었습니다."
    else
        error "ipset del 실패: ${err}"
        pause
    fi
}

team_delete() {
    local team
    if ! _select_team team; then
        pause
        return 0
    fi

    clear_screen
    print_header "팀 삭제 (${team})"

    local members=()
    _get_team_members "$team" members
    local member_count=${#members[@]}

    # iptables 참조 확인
    local refs=""
    local has_refs=false
    if refs=$(check_ipset_refs "$team"); then
        has_refs=true
    fi

    local cmds=()

    if $has_refs; then
        echo ""
        warn "'${team}' 팀을 참조하는 iptables 규칙이 있습니다:"
        echo -e "$refs"

        if ! prompt_confirm "이 규칙들도 함께 삭제하시겠습니까?"; then
            info "취소되었습니다. 참조하는 규칙을 먼저 삭제해야 팀을 삭제할 수 있습니다."
            pause
            return 0
        fi

        # 참조 규칙 수집 (역순 삭제를 위해)
        # check_ipset_refs 출력 형식: "     CHAIN #NUM: RULE_SPEC"
        # 체인별로 규칙 번호를 수집하고 역순으로 삭제 명령어 생성
        local -a delete_rules=()
        local line
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            # 파싱: "     INPUT #2: -m set ..."
            local chain rule_num
            chain=$(echo "$line" | sed -n 's/^[[:space:]]*\([A-Z_-]*\)[[:space:]]*#\([0-9]*\):.*/\1/p')
            rule_num=$(echo "$line" | sed -n 's/^[[:space:]]*\([A-Z_-]*\)[[:space:]]*#\([0-9]*\):.*/\2/p')
            if [[ -n "$chain" && -n "$rule_num" ]]; then
                delete_rules+=("${chain}:${rule_num}")
            fi
        done <<< "$refs"

        # 역순 정렬 (같은 체인 내에서 큰 번호부터 삭제해야 인덱스 밀림 방지)
        # 체인별로 분리하여 번호 역순 정렬
        local -a sorted_rules=()
        local seen_chains=()

        # 고유 체인 목록 수집
        for entry in "${delete_rules[@]}"; do
            local c="${entry%%:*}"
            local already=false
            for sc in "${seen_chains[@]}"; do
                if [[ "$sc" == "$c" ]]; then
                    already=true
                    break
                fi
            done
            if ! $already; then
                seen_chains+=("$c")
            fi
        done

        # 각 체인별로 번호를 역순 정렬하여 sorted_rules에 추가
        for c in "${seen_chains[@]}"; do
            local -a nums=()
            for entry in "${delete_rules[@]}"; do
                local ec="${entry%%:*}"
                local en="${entry#*:}"
                if [[ "$ec" == "$c" ]]; then
                    nums+=("$en")
                fi
            done

            # 숫자 역순 정렬
            IFS=$'\n' read -r -d '' -a nums_sorted < <(printf '%s\n' "${nums[@]}" | sort -rn; printf '\0')

            for n in "${nums_sorted[@]}"; do
                sorted_rules+=("${c}:${n}")
                cmds+=("iptables -D ${c} ${n}")
            done
        done
    fi

    # 위험 확인
    local danger_msg
    if $has_refs; then
        local rule_count=${#cmds[@]}
        danger_msg="이 작업은 되돌릴 수 없습니다! 팀 '${team}'의 모든 멤버(${member_count}명)와 관련 규칙 ${rule_count}개가 삭제됩니다."
    else
        danger_msg="이 작업은 되돌릴 수 없습니다! 팀 '${team}'의 모든 멤버(${member_count}명)가 삭제됩니다."
    fi

    if ! prompt_confirm_dangerous "$team" "$danger_msg"; then
        info "취소되었습니다."
        pause
        return 0
    fi

    cmds+=("ipset destroy ${team}")

    preview_cmd "${cmds[@]}"

    # 참조 iptables 규칙 삭제 (역순으로)
    if $has_refs; then
        local rule_delete_count=0
        local failed=false
        for cmd in "${cmds[@]}"; do
            # ipset destroy는 아래에서 별도 처리
            [[ "$cmd" == "ipset destroy"* ]] && continue

            local err
            # cmd는 "iptables -D CHAIN NUM" 형식 — read로 분리하여 직접 실행
            local -a cmd_parts
            read -ra cmd_parts <<< "$cmd"
            if err=$("${cmd_parts[@]}" 2>&1); then
                rule_delete_count=$((rule_delete_count + 1))
            else
                error "규칙 삭제 실패: ${cmd}"
                error "${err}"
                failed=true
                break
            fi
        done

        if $failed; then
            error "iptables 규칙 삭제 중 오류가 발생하여 중단합니다."
            pause
            return 1
        fi

        if [[ $rule_delete_count -gt 0 ]]; then
            success "관련 iptables 규칙 ${rule_delete_count}개 삭제 완료"
        fi
    fi

    # ipset destroy 실행
    local err
    if err=$(ipset destroy "$team" 2>&1); then
        success "팀 '${team}'이(가) 삭제되었습니다."

        # conf 파일 삭제
        local conf="${CONFIG_DIR}/teams/${team}.conf"
        if [[ -f "$conf" ]]; then
            rm -f "$conf"
            success "${conf} 파일 삭제 완료"
        fi
    else
        error "ipset destroy 실패: ${err}"
        pause
    fi
}
