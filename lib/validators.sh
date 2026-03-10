#!/usr/bin/env bash
# validators.sh - 입력 검증 함수

# IPv4 주소 검증 (CIDR 포함)
validate_ip() {
    local ip="$1"

    # CIDR 형식 (예: 10.0.0.0/24)
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]]; then
        local base="${ip%/*}"
        local mask="${ip#*/}"
        if (( mask < 0 || mask > 32 )); then
            return 1
        fi
        ip="$base"
    # 단일 IP (예: 10.0.0.5)
    elif [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi

    # 각 옥텟 범위 확인
    IFS='.' read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        if (( octet < 0 || octet > 255 )); then
            return 1
        fi
    done

    return 0
}

# 포트 검증 (1-65535 또는 "all")
validate_port() {
    local port="$1"

    if [[ "$port" == "all" ]]; then
        return 0
    fi

    if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
        return 0
    fi

    return 1
}

# 체인명 검증 (허용: INPUT, DOCKER-USER)
validate_chain() {
    local chain="$1"
    case "$chain" in
        INPUT|DOCKER-USER) return 0 ;;
        *) return 1 ;;
    esac
}

# 팀 이름 검증 (영문, 숫자, 하이픈, 1-32자)
validate_team_name() {
    local name="$1"

    if [[ -z "$name" ]]; then
        return 1
    fi

    if [[ ${#name} -gt 32 ]]; then
        return 1
    fi

    if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
        return 1
    fi

    return 0
}

# comment 검증 (비어있지 않음, 64자 이하)
validate_comment() {
    local comment="$1"

    if [[ -z "$comment" ]]; then
        return 1
    fi

    if [[ ${#comment} -gt 64 ]]; then
        return 1
    fi

    return 0
}

# comment 이스케이핑 (큰따옴표 제거, 파이프 이스케이프)
escape_comment() {
    local comment="$1"
    # 큰따옴표 제거
    comment="${comment//\"/}"
    # 메타데이터 파일에서 파이프는 구분자이므로 이스케이프
    comment="${comment//|/\\|}"
    echo "$comment"
}

# comment 언이스케이핑 (메타데이터 파일에서 읽을 때)
unescape_comment() {
    local comment="$1"
    comment="${comment//\\|/|}"
    echo "$comment"
}

# ── IP/CIDR 매칭 ─────────────────────────────────

# IP를 32비트 정수로 변환
_ip_to_int() {
    local ip="$1"
    local a b c d
    IFS='.' read -r a b c d <<< "$ip"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

# IP가 CIDR 범위에 속하는지 확인
# ip_in_cidr "10.0.0.5" "10.0.0.0/24" → 0(yes) / 1(no)
# ip_in_cidr "10.0.0.5" "10.0.0.5" → 0(yes) / 1(no)
ip_in_cidr() {
    local ip="$1"
    local cidr="$2"

    # 단일 IP인 경우 직접 비교
    if [[ "$cidr" != *"/"* ]]; then
        [[ "$ip" == "$cidr" ]] && return 0
        return 1
    fi

    local net="${cidr%/*}"
    local mask="${cidr#*/}"

    local ip_int net_int
    ip_int=$(_ip_to_int "$ip")
    net_int=$(_ip_to_int "$net")

    # 마스크 비트 계산
    local mask_int=$(( 0xFFFFFFFF << (32 - mask) & 0xFFFFFFFF ))

    if (( (ip_int & mask_int) == (net_int & mask_int) )); then
        return 0
    fi
    return 1
}

# ── 안전 검증 함수 ───────────────────────────────

# SSH 충돌 감지: 추가하려는 규칙이 SSH를 차단하는지 확인
# 반환: 0=충돌, 1=안전
detect_ssh_conflict_add() {
    local chain="$1"
    local action="$2"
    local src="$3"
    local port="$4"
    local proto="$5"

    # ACCEPT 규칙은 안전
    [[ "$action" == "ACCEPT" ]] && return 1

    # INPUT 체인이 아니면 SSH에 영향 없음
    [[ "$chain" != "INPUT" ]] && return 1

    # SSH 포트와 관련 있는지 확인
    if [[ "$port" == "all" || "$port" == "$SSH_CLIENT_PORT" ]]; then
        # 프로토콜이 all이거나 tcp면 SSH에 영향
        if [[ "$proto" == "all" || "$proto" == "tcp" ]]; then
            # 소스가 all이면 확실히 충돌
            if [[ "$src" == "0.0.0.0/0" || -z "$src" ]]; then
                return 0  # 충돌!
            fi

            # 소스가 현재 SSH 클라이언트 IP와 매칭 (단일 IP 또는 CIDR)
            if [[ -n "$SSH_CLIENT_IP" ]]; then
                if ip_in_cidr "$SSH_CLIENT_IP" "$src"; then
                    return 0  # 충돌!
                fi
            fi

            # 소스가 team(ipset)인 경우: ipset에 현재 SSH IP가 포함되어 있는지 확인
            if [[ "$src" == team:* && -n "$SSH_CLIENT_IP" ]]; then
                local team_name="${src#team:}"
                if ipset test "$team_name" "$SSH_CLIENT_IP" 2>/dev/null; then
                    return 0  # 충돌! SSH IP가 이 팀에 속해 있음
                fi
            fi
        fi
    fi

    return 1  # 안전
}

# SSH 허용 규칙 삭제 감지
# 반환: 0=SSH 관련 규칙 (삭제하면 SSH가 끊길 수 있음), 1=아님
detect_ssh_rule() {
    local rule_spec="$1"

    # ACCEPT 규칙이 아니면 SSH와 무관
    [[ "$rule_spec" != *"-j ACCEPT"* ]] && return 1

    # 명시적 SSH 포트 허용 — 소스 확인 필요
    if [[ "$rule_spec" == *"--dport ${SSH_CLIENT_PORT}"* || "$rule_spec" == *"dpt:${SSH_CLIENT_PORT}"* ]]; then
        # 소스 제한이 있으면 SSH 클라이언트가 해당 범위에 있는지 확인
        if [[ "$rule_spec" =~ -s\ ([0-9./]+) && -n "$SSH_CLIENT_IP" ]]; then
            ip_in_cidr "$SSH_CLIENT_IP" "${BASH_REMATCH[1]}" && return 0
            return 1  # SSH 클라이언트가 소스 범위 밖 — 무관
        fi
        if [[ "$rule_spec" =~ --match-set\ ([^ ]+)\ src && -n "$SSH_CLIENT_IP" ]]; then
            ipset test "${BASH_REMATCH[1]}" "$SSH_CLIENT_IP" 2>/dev/null && return 0
            return 1
        fi
        # 소스 제한 없으면 전체 허용 — SSH 관련
        return 0
    fi

    # 포트 제한 없는 광범위 ACCEPT (소스 IP/team 기반 전체 허용)
    # 이 규칙을 삭제하면 SSH도 차단될 수 있음
    # 단, UDP/ICMP 전용 규칙은 SSH(TCP)와 무관하므로 제외
    if [[ "$rule_spec" != *"--dport "* && "$rule_spec" != *"dpt:"* ]]; then
        if [[ "$rule_spec" == *"-p udp"* || "$rule_spec" == *"-p icmp"* ]]; then
            return 1  # 비-TCP 전용, SSH와 무관
        fi
        # ESTABLISHED,RELATED 규칙은 별도로 감지하므로 여기서 제외
        if [[ "$rule_spec" == *"ESTABLISHED"* ]]; then
            return 1
        fi
        # 소스 제한이 있는 경우: SSH 클라이언트 IP가 범위 내인지 확인
        if [[ "$rule_spec" =~ -s\ ([0-9./]+) && -n "$SSH_CLIENT_IP" ]]; then
            local rule_src="${BASH_REMATCH[1]}"
            if ip_in_cidr "$SSH_CLIENT_IP" "$rule_src"; then
                return 0  # SSH 클라이언트가 이 소스에 포함됨 — 삭제하면 위험
            fi
            return 1  # SSH 클라이언트가 이 소스에 포함되지 않음 — 무관
        fi
        # team 소스: ipset에 SSH IP가 있는지 확인
        if [[ "$rule_spec" =~ --match-set\ ([^ ]+)\ src && -n "$SSH_CLIENT_IP" ]]; then
            local team="${BASH_REMATCH[1]}"
            if ipset test "$team" "$SSH_CLIENT_IP" 2>/dev/null; then
                return 0  # SSH IP가 팀에 포함됨
            fi
            return 1  # 무관
        fi
        # 소스 제한 없는 전체 ACCEPT — 삭제하면 SSH 위험
        return 0
    fi

    return 1
}

# ESTABLISHED,RELATED 규칙 삭제 감지
detect_established_rule() {
    local rule_spec="$1"

    if [[ "$rule_spec" == *"ESTABLISHED"* && "$rule_spec" == *"RELATED"* ]]; then
        return 0
    fi

    return 1
}

# INPUT 체인에 ESTABLISHED,RELATED 규칙이 있는지 확인
check_established_exists() {
    if iptables -S INPUT 2>/dev/null | grep -q "ESTABLISHED,RELATED\|ESTABLISHED.*RELATED"; then
        return 0
    fi
    return 1
}

# 중복 규칙 감지
# 반환: 0=중복 존재 (중복 규칙 번호를 stdout으로 출력), 1=중복 없음
check_duplicate_rule() {
    local chain="$1"
    local src="$2"
    local port="$3"
    local proto="$4"
    local action="$5"

    local line_num=0
    while IFS= read -r line; do
        # -P (정책) 및 -N (체인 정의) 라인 스킵
        [[ "$line" == -P* ]] && continue
        [[ "$line" == -N* ]] && continue
        line_num=$((line_num + 1))

        local match=true

        # 액션 매칭
        [[ "$line" != *"-j $action"* ]] && match=false

        # 소스 매칭
        if [[ "$src" == "0.0.0.0/0" || -z "$src" ]]; then
            # all 소스: 기존 규칙에도 -s가 없어야 매칭
            [[ "$line" == *"-s "* ]] && match=false
            [[ "$line" == *"--match-set "* ]] && match=false
        elif [[ "$src" == team:* ]]; then
            # team 소스: --match-set 매칭
            local team="${src#team:}"
            [[ "$line" != *"--match-set ${team} src"* ]] && match=false
        else
            # IP 소스: -s 매칭
            [[ "$line" != *"-s $src"* ]] && match=false
        fi

        # 포트 매칭
        if [[ "$port" != "all" ]]; then
            [[ "$line" != *"--dport $port"* ]] && match=false
        fi

        # 프로토콜 매칭
        if [[ "$proto" != "all" ]]; then
            [[ "$line" != *"-p $proto"* ]] && match=false
        fi

        if $match; then
            echo "$line_num"
            return 0
        fi
    done <<< "$(iptables -S "$chain" 2>/dev/null)"

    return 1
}

# ipset이 iptables에서 참조되는지 확인
# 반환: 0=참조됨 (참조 규칙을 stdout으로 출력), 1=참조 없음
check_ipset_refs() {
    local setname="$1"
    local refs=""
    local found=false

    for chain in INPUT DOCKER-USER; do
        if ! iptables -nL "$chain" &>/dev/null; then
            continue
        fi

        local line_num=0
        while IFS= read -r line; do
            [[ "$line" == -P* ]] && continue
            [[ "$line" == -N* ]] && continue
            line_num=$((line_num + 1))
            if [[ "$line" == *"--match-set ${setname}"* ]]; then
                refs+="     ${chain} #${line_num}: ${line}\n"
                found=true
            fi
        done <<< "$(iptables -S "$chain" 2>/dev/null)"
    done

    if $found; then
        echo -e "$refs"
        return 0
    fi

    return 1
}

# ── 입력 루프 (검증 포함) ────────────────────────

# 유효한 IP를 받을 때까지 반복
read_valid_ip() {
    local prompt="${1:-? IP 주소 (CIDR 가능)}"
    while true; do
        prompt_input "$prompt"
        if validate_ip "$REPLY"; then
            return 0
        fi
        error "올바른 IPv4 주소를 입력하세요. (예: 10.0.0.5 또는 10.0.0.0/24)"
    done
}

# 유효한 포트를 받을 때까지 반복
read_valid_port() {
    local prompt="${1:-? 포트 번호 (전체는 'all')}"
    while true; do
        prompt_input "$prompt"
        if validate_port "$REPLY"; then
            return 0
        fi
        error "1~65535 사이의 숫자 또는 'all'을 입력하세요."
    done
}

# 유효한 팀 이름을 받을 때까지 반복
read_valid_team_name() {
    local prompt="${1:-? 팀 이름 (영문, 숫자, 하이픈)}"
    while true; do
        prompt_input "$prompt"
        if validate_team_name "$REPLY"; then
            return 0
        fi
        error "영문, 숫자, 하이픈만 사용 가능합니다. (1~32자)"
    done
}

# 유효한 comment를 받을 때까지 반복
read_valid_comment() {
    local prompt="${1:-? 설명 (누구/무엇인지, 필수)}"
    while true; do
        prompt_input "$prompt"
        if validate_comment "$REPLY"; then
            REPLY=$(escape_comment "$REPLY")
            return 0
        fi
        error "설명을 입력해 주세요. (1~64자)"
    done
}
