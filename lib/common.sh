#!/usr/bin/env bash
# common.sh - 색상, 로깅, 메뉴, 프롬프트, 테이블 유틸리티

# ── 색상 ──────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' RESET=''
fi

# ── 로깅 ──────────────────────────────────────────
info()    { echo -e "  ${BLUE}i${RESET}  $*"; }
success() { echo -e "  ${GREEN}✓${RESET}  $*"; }
warn()    { echo -e "  ${YELLOW}!${RESET}  $*"; }
error()   { echo -e "  ${RED}✗${RESET}  $*" >&2; }
fatal()   { error "$*"; exit 1; }

# ── 화면 ──────────────────────────────────────────
clear_screen() {
    printf '\033[2J\033[H'
}

print_header() {
    local title="$1"
    local pad_len=$(( 40 - ${#title} ))
    (( pad_len < 1 )) && pad_len=1
    echo ""
    echo -e "  ${DIM}--${RESET} ${BOLD}${title}${RESET} ${DIM}$(printf -- '-%.0s' $(seq 1 "$pad_len"))${RESET}"
    echo ""
}

print_banner() {
    clear_screen
    echo ""
    echo -e "  ${BOLD}+==========================================+${RESET}"
    echo -e "  ${BOLD}|       Firewall Manager v${VERSION}          |${RESET}"
    echo -e "  ${BOLD}+==========================================+${RESET}"
    echo ""
    echo -e "  ${DIM}INPUT/DOCKER-USER 체인만 관리합니다.${RESET}"
    echo ""
}

print_separator() {
    echo -e "  ${DIM}------------------------------------------${RESET}"
}

# ── 명령어 미리보기 ──────────────────────────────
preview_cmd() {
    echo ""
    echo -e "  ${DIM}-> 실행될 명령어:${RESET}"
    for cmd in "$@"; do
        echo -e "    ${CYAN}${cmd}${RESET}"
    done
    echo ""
}

# ── 방향키 메뉴 (공통 엔진) ───────────────────────
# _arrow_menu selected_index "옵션1" "옵션2" ... "마지막옵션(돌아가기/종료)"
# 커서를 숨기고, 방향키로 이동, Enter로 선택
# 반환: 선택된 인덱스 (0부터)
_arrow_menu() {
    local cur=$1; shift
    local items=("$@")
    local total=${#items[@]}

    # 커서 숨기기
    printf '\033[?25l'
    # 종료 시 커서 복원
    trap 'printf "\033[?25h"' RETURN

    # 초기 렌더링
    _arrow_menu_render "$cur" "${items[@]}"

    while true; do
        # 키 입력 읽기
        local key
        IFS= read -rsn1 key

        if [[ "$key" == $'\x1b' ]]; then
            read -rsn2 -t 0.01 key
            case "$key" in
                '[A') (( cur > 0 )) && cur=$((cur - 1)) ;;           # Up
                '[B') (( cur < total - 1 )) && cur=$((cur + 1)) ;;   # Down
            esac
        elif [[ "$key" == "" ]]; then
            # Enter
            # 렌더링 영역 지우기
            printf '\033[%dA' "$total"
            for (( i=0; i<total; i++ )); do
                printf '\033[2K\n'
            done
            printf '\033[%dA' "$total"
            printf '\033[?25h'
            return "$cur"
        fi

        # 다시 그리기: 위로 올라가서 덮어쓰기
        printf '\033[%dA' "$total"
        _arrow_menu_render "$cur" "${items[@]}"
    done
}

_arrow_menu_render() {
    local cur=$1; shift
    local items=("$@")

    for i in "${!items[@]}"; do
        printf '\033[2K'  # 줄 지우기
        if [[ $i -eq $cur ]]; then
            echo -e "  ${CYAN}▸${RESET} ${BOLD}${items[$i]}${RESET}"
        else
            echo -e "    ${items[$i]}"
        fi
    done
}

# ── 메뉴 선택 ────────────────────────────────────
# menu_select "제목" "옵션1" "옵션2" ...
# 반환: 선택된 번호 (1부터), 0 = 돌아가기
menu_select() {
    local title="$1"; shift
    local options=("$@")

    clear_screen
    print_header "$title"

    # 옵션 + 돌아가기를 합쳐서 배열 구성
    local items=()
    for opt in "${options[@]}"; do
        items+=("$opt")
    done
    items+=("${DIM}<- 돌아가기${RESET}")

    _arrow_menu 0 "${items[@]}"
    local idx=$?

    # 마지막 항목 = 돌아가기 = 0
    if (( idx == ${#options[@]} )); then
        return 0
    fi
    return $((idx + 1))
}

# 메인 메뉴 전용 (종료 표시)
menu_select_main() {
    local options=("$@")

    local items=()
    for opt in "${options[@]}"; do
        items+=("$opt")
    done
    items+=("${DIM}종료${RESET}")

    _arrow_menu 0 "${items[@]}"
    local idx=$?

    if (( idx == ${#options[@]} )); then
        return 0
    fi
    return $((idx + 1))
}

# ── 입력 프롬프트 ────────────────────────────────
# prompt_input "질문" [기본값]
# 결과: $REPLY
prompt_input() {
    local question="$1"
    local default="${2:-}"

    if [[ -n "$default" ]]; then
        read -rp "  ${question} [${default}]: " REPLY
        REPLY="${REPLY:-$default}"
    else
        while true; do
            read -rp "  ${question}: " REPLY
            if [[ -n "$REPLY" ]]; then
                return 0
            fi
            error "값을 입력해 주세요."
        done
    fi
}

# prompt_input_optional "질문"
prompt_input_optional() {
    local question="$1"
    read -rp "  ${question}: " REPLY
}

# ── 확인 프롬프트 ────────────────────────────────
# prompt_confirm "질문" -> 0(yes) / 1(no)
prompt_confirm() {
    local question="$1"
    local answer

    while true; do
        read -rp "  ${question} (y/n): " answer
        case "$answer" in
            [yY]|[yY][eE][sS]) return 0 ;;
            [nN]|[nN][oO])     return 1 ;;
            *) error "y 또는 n을 입력하세요." ;;
        esac
    done
}

# 위험한 작업 확인 (이름 입력 필요)
prompt_confirm_dangerous() {
    local resource_name="$1"
    local message="$2"
    local answer

    echo ""
    warn "$message"
    echo ""
    read -rp "  확인하려면 '${resource_name}'을(를) 입력하세요: " answer

    [[ "$answer" == "$resource_name" ]]
}

# 매우 위험한 작업 확인 (yes 정확히 입력)
prompt_confirm_critical() {
    local message="$1"
    local answer

    echo ""
    warn "$message"
    echo ""
    read -rp "  정말 진행하시겠습니까? (yes를 정확히 입력): " answer

    [[ "$answer" == "yes" ]]
}

# ── 선택 프롬프트 ────────────────────────────────
# prompt_choice "질문" "옵션1" "옵션2" ...
# 반환: 선택된 번호 (1부터)
prompt_choice() {
    local question="$1"; shift
    local options=("$@")

    echo -e "  ${BOLD}?${RESET} ${question}"
    echo ""

    local items=("${options[@]}")
    items+=("${DIM}<- 돌아가기${RESET}")

    _arrow_menu 0 "${items[@]}"
    local idx=$?

    if (( idx == ${#options[@]} )); then
        return 0
    fi
    return $((idx + 1))
}

# ── 테이블 출력 ──────────────────────────────────
# print_table "헤더1|헤더2|헤더3" "값1|값2|값3" ...
print_table() {
    local header="$1"; shift
    local rows=("$@")

    # 헤더 파싱
    IFS='|' read -ra headers <<< "$header"
    local num_cols=${#headers[@]}

    # 각 컬럼 최대 너비 계산
    local -a widths
    for i in "${!headers[@]}"; do
        widths[$i]=${#headers[$i]}
    done

    for row in "${rows[@]}"; do
        IFS='|' read -ra cols <<< "$row"
        for i in "${!cols[@]}"; do
            local len=${#cols[$i]}
            if (( len > ${widths[$i]:-0} )); then
                widths[$i]=$len
            fi
        done
    done

    # 헤더 출력
    echo ""
    local header_line="  "
    for i in "${!headers[@]}"; do
        header_line+="$(printf "${BOLD}%-$((widths[$i] + 3))s${RESET}" "${headers[$i]}")"
    done
    echo -e "$header_line"

    # 구분선
    local sep_line="  "
    for i in "${!headers[@]}"; do
        sep_line+="$(printf '%-s' "$(printf -- '-%.0s' $(seq 1 $((widths[$i] + 3))))")"
    done
    echo -e "  ${DIM}${sep_line}${RESET}"

    # 행 출력
    if [[ ${#rows[@]} -eq 0 ]]; then
        echo -e "  ${DIM}  (비어 있음)${RESET}"
    else
        for row in "${rows[@]}"; do
            IFS='|' read -ra cols <<< "$row"
            local line="  "
            for i in "${!headers[@]}"; do
                local val="${cols[$i]:-}"
                if [[ "$val" == "ACCEPT" ]]; then
                    line+="$(printf "${GREEN}%-$((widths[$i] + 3))s${RESET}" "$val")"
                elif [[ "$val" == "DROP" || "$val" == "REJECT" ]]; then
                    line+="$(printf "${RED}%-$((widths[$i] + 3))s${RESET}" "$val")"
                else
                    line+="$(printf "%-$((widths[$i] + 3))s" "$val")"
                fi
            done
            echo -e "$line"
        done
    fi
    echo ""
}

# ── 전제조건 확인 ────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        fatal "root 권한이 필요합니다. 레포 디렉터리에서 'sudo ./fw' 로 실행하세요."
    fi
}

check_dependencies() {
    local missing=()
    for cmd in iptables iptables-save iptables-restore ipset; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "필요한 도구가 설치되어 있지 않습니다:"
        for cmd in "${missing[@]}"; do
            echo "    - $cmd"
        done
        echo ""
        info "설치: sudo apt install iptables ipset"
        exit 1
    fi
}

detect_iptables_backend() {
    # iptables-nft vs iptables-legacy 감지
    local version
    version=$(iptables --version 2>/dev/null || true)
    if [[ "$version" == *"nf_tables"* ]]; then
        IPTABLES_BACKEND="nft"
    else
        IPTABLES_BACKEND="legacy"
    fi
}

# ── 설정 디렉토리 초기화 ─────────────────────────
init_config_dir() {
    mkdir -p "${CONFIG_DIR}"
    mkdir -p "${CONFIG_DIR}/teams"
    mkdir -p "${CONFIG_DIR}/backups"
}

# ── SSH 정보 ─────────────────────────────────────
get_ssh_info() {
    SSH_CLIENT_IP=""
    SSH_CLIENT_PORT="${SSH_PORT:-22}"

    if [[ -n "${SSH_CLIENT:-}" ]]; then
        SSH_CLIENT_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
    fi

    # sshd 포트 확인
    if command -v ss &>/dev/null; then
        local sshd_port
        sshd_port=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | grep -oP ':\K[0-9]+' | head -1)
        if [[ -n "$sshd_port" ]]; then
            SSH_CLIENT_PORT="$sshd_port"
        fi
    fi
}

# ── 일시 정지 ────────────────────────────────────
pause() {
    echo ""
    read -rp "  계속하려면 Enter를 누르세요..." _
}
