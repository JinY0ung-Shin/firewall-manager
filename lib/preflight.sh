#!/usr/bin/env bash
# preflight.sh - restore/migration readiness checks

_preflight_require_command() {
    local cmd="$1"

    if command -v "$cmd" >/dev/null 2>&1; then
        success "${cmd} 사용 가능"
        return 0
    fi

    error "${cmd} 이(가) 설치되어 있지 않습니다."
    return 1
}

preflight_report() {
    print_header "사전 점검 (복원/이전 전)"

    local failures=0
    local warnings=0
    local rules_file="${CONFIG_DIR}/iptables.rules"
    local full_rules_file="${CONFIG_DIR}/iptables-full.rules"
    local teams_dir="${CONFIG_DIR}/teams"

    info "설정 경로: ${CONFIG_DIR}"
    info "iptables backend: ${IPTABLES_BACKEND:-unknown}"

    echo ""
    info "필수 명령 확인:"
    for cmd in iptables iptables-save iptables-restore ipset tar; do
        if ! _preflight_require_command "$cmd"; then
            failures=$((failures + 1))
        fi
    done

    echo ""
    info "저장된 설정 확인:"
    if [[ -f "${rules_file}" ]]; then
        local rules_date
        local input_count
        local docker_count
        rules_date=$(stat -c '%y' "${rules_file}" 2>/dev/null | cut -d'.' -f1)
        input_count=$(grep -c '^-A INPUT' "${rules_file}" 2>/dev/null || echo "0")
        docker_count=$(grep -c '^-A DOCKER-USER' "${rules_file}" 2>/dev/null || echo "0")
        success "저장된 규칙 파일 확인 (${rules_date})"
        info "INPUT 규칙: ${input_count}개"
        info "DOCKER-USER 규칙: ${docker_count}개"
    else
        error "저장된 규칙 파일이 없습니다: ${rules_file}"
        failures=$((failures + 1))
    fi

    if [[ -f "${full_rules_file}" ]]; then
        success "전체 스냅샷 파일이 있습니다."
    else
        warn "iptables-full.rules 가 없습니다. 비상 복구용 스냅샷이 없을 수 있습니다."
        warnings=$((warnings + 1))
    fi

    local team_count=0
    if [[ -d "${teams_dir}" ]]; then
        team_count=$(find "${teams_dir}" -maxdepth 1 -type f -name '*.conf' | wc -l)
    fi
    info "팀 설정 파일: ${team_count}개"

    echo ""
    info "복원 대상 서버 확인:"
    if [[ -f "${rules_file}" ]] && grep -q '^-A DOCKER-USER' "${rules_file}" 2>/dev/null; then
        if iptables -L DOCKER-USER -n &>/dev/null; then
            success "대상 서버에 DOCKER-USER 체인이 있습니다."
        else
            warn "저장 파일에는 DOCKER-USER 규칙이 있지만 대상 서버에는 체인이 없습니다."
            warn "Docker가 실행 중인지 먼저 확인하세요."
            warnings=$((warnings + 1))
        fi
    else
        info "저장 파일에 DOCKER-USER 규칙이 없습니다."
    fi

    if [[ -f "${rules_file}" ]]; then
        if grep -q 'ESTABLISHED,RELATED\|ESTABLISHED.*RELATED' "${rules_file}" 2>/dev/null; then
            success "저장 파일에 ESTABLISHED,RELATED 보호 규칙이 있습니다."
        else
            warn "저장 파일에 ESTABLISHED,RELATED 보호 규칙이 없습니다."
            warnings=$((warnings + 1))
        fi
    fi

    if [[ -n "${SSH_CLIENT_PORT:-}" ]]; then
        info "감지된 SSH 포트: ${SSH_CLIENT_PORT}"
    fi
    if [[ -n "${SSH_CLIENT_IP:-}" ]]; then
        info "감지된 접속 IP: ${SSH_CLIENT_IP}"
    fi

    echo ""
    if (( failures > 0 )); then
        error "사전 점검 실패: ${failures}개 문제, ${warnings}개 경고"
        return 1
    fi

    if (( warnings > 0 )); then
        warn "사전 점검 완료: 치명적 문제는 없지만 ${warnings}개 경고가 있습니다."
        return 0
    fi

    success "사전 점검 통과: 복원/이전을 진행할 준비가 되었습니다."
    return 0
}
