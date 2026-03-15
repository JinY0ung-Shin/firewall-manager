#!/usr/bin/env bash
# bundle.sh - export/import config bundles for migration

_bundle_snapshot_config() {
    local snap_dir="$1"

    mkdir -p "${snap_dir}/teams"

    [[ -f "${CONFIG_DIR}/iptables.rules" ]] && cp "${CONFIG_DIR}/iptables.rules" "${snap_dir}/"
    [[ -f "${CONFIG_DIR}/iptables-full.rules" ]] && cp "${CONFIG_DIR}/iptables-full.rules" "${snap_dir}/"

    shopt -s nullglob
    local team_files=("${CONFIG_DIR}/teams/"*.conf)
    if (( ${#team_files[@]} > 0 )); then
        cp "${team_files[@]}" "${snap_dir}/teams/"
    fi
    shopt -u nullglob
}

_bundle_restore_config_snapshot() {
    local snap_dir="$1"

    rm -f "${CONFIG_DIR}/iptables.rules" "${CONFIG_DIR}/iptables-full.rules"
    rm -f "${CONFIG_DIR}/teams/"*.conf 2>/dev/null || true

    [[ -f "${snap_dir}/iptables.rules" ]] && cp "${snap_dir}/iptables.rules" "${CONFIG_DIR}/"
    [[ -f "${snap_dir}/iptables-full.rules" ]] && cp "${snap_dir}/iptables-full.rules" "${CONFIG_DIR}/"

    shopt -s nullglob
    local team_files=("${snap_dir}/teams/"*.conf)
    if (( ${#team_files[@]} > 0 )); then
        cp "${team_files[@]}" "${CONFIG_DIR}/teams/"
    fi
    shopt -u nullglob
}

_bundle_write_metadata() {
    local metadata_file="$1"
    local input_count=0
    local docker_count=0
    local team_count=0

    [[ -f "${CONFIG_DIR}/iptables.rules" ]] && input_count=$(grep -c '^-A INPUT' "${CONFIG_DIR}/iptables.rules" 2>/dev/null || echo "0")
    [[ -f "${CONFIG_DIR}/iptables.rules" ]] && docker_count=$(grep -c '^-A DOCKER-USER' "${CONFIG_DIR}/iptables.rules" 2>/dev/null || echo "0")
    [[ -d "${CONFIG_DIR}/teams" ]] && team_count=$(find "${CONFIG_DIR}/teams" -maxdepth 1 -type f -name '*.conf' | wc -l)

    cat > "${metadata_file}" <<EOF
created_at=$(date '+%Y-%m-%d %H:%M:%S')
hostname=$(hostname 2>/dev/null || echo unknown)
config_dir=${CONFIG_DIR}
iptables_backend=${IPTABLES_BACKEND:-unknown}
input_rules=${input_count}
docker_user_rules=${docker_count}
team_files=${team_count}
EOF
}

bundle_export() {
    local archive_path="${1:-${CONFIG_DIR}/backups/fw-bundle-$(date +%Y-%m-%d_%H%M%S).tar.gz}"
    local rules_file="${CONFIG_DIR}/iptables.rules"

    if ! command -v tar >/dev/null 2>&1; then
        error "tar 명령이 필요합니다."
        return 1
    fi

    if [[ ! -f "${rules_file}" ]]; then
        error "저장된 규칙 파일이 없습니다: ${rules_file}"
        info "먼저 '현재 규칙 저장' 또는 'sudo ./fw save'를 실행하세요."
        return 1
    fi

    mkdir -p "$(dirname "${archive_path}")"

    local tmpdir
    tmpdir="$(mktemp -d)"
    mkdir -p "${tmpdir}/config/teams"

    cp "${rules_file}" "${tmpdir}/config/"
    [[ -f "${CONFIG_DIR}/iptables-full.rules" ]] && cp "${CONFIG_DIR}/iptables-full.rules" "${tmpdir}/config/"

    shopt -s nullglob
    local team_files=("${CONFIG_DIR}/teams/"*.conf)
    if (( ${#team_files[@]} > 0 )); then
        cp "${team_files[@]}" "${tmpdir}/config/teams/"
    fi
    shopt -u nullglob

    _bundle_write_metadata "${tmpdir}/bundle-metadata.txt"

    if tar -czf "${archive_path}" -C "${tmpdir}" config bundle-metadata.txt; then
        success "이전 번들 생성 완료: ${archive_path}"
        rm -rf "${tmpdir}"
        return 0
    fi

    rm -rf "${tmpdir}"
    error "이전 번들 생성 실패"
    return 1
}

bundle_import() {
    local archive_path="$1"
    shift || true

    local apply_after=false
    local quiet=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --apply)
                apply_after=true
                shift
                ;;
            --quiet)
                quiet=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    if [[ -z "${archive_path}" ]]; then
        error "가져올 번들 파일 경로가 필요합니다."
        return 1
    fi

    if [[ ! -f "${archive_path}" ]]; then
        error "번들 파일을 찾을 수 없습니다: ${archive_path}"
        return 1
    fi

    if ! command -v tar >/dev/null 2>&1; then
        error "tar 명령이 필요합니다."
        return 1
    fi

    local extract_dir
    local config_snap
    local stage_dir
    extract_dir="$(mktemp -d)"
    config_snap="$(mktemp -d)"
    stage_dir="$(mktemp -d)"

    if ! tar -xzf "${archive_path}" -C "${extract_dir}"; then
        rm -rf "${extract_dir}" "${config_snap}" "${stage_dir}"
        error "번들 압축 해제 실패"
        return 1
    fi

    local payload_dir="${extract_dir}"
    [[ -d "${extract_dir}/config" ]] && payload_dir="${extract_dir}/config"

    # fw export로 생성된 번들은 항상 iptables.rules를 포함해야 함
    if [[ ! -f "${payload_dir}/iptables.rules" ]]; then
        rm -rf "${extract_dir}" "${config_snap}" "${stage_dir}"
        error "올바른 fw 번들 형식이 아닙니다."
        return 1
    fi

    mkdir -p "${stage_dir}/teams"

    # 먼저 staging 디렉터리로 복사하여 payload 자체가 온전한지 검증
    if ! cp "${payload_dir}/iptables.rules" "${stage_dir}/"; then
        rm -rf "${extract_dir}" "${config_snap}" "${stage_dir}"
        error "번들에서 iptables.rules 복사 실패"
        return 1
    fi

    if [[ -f "${payload_dir}/iptables-full.rules" ]]; then
        if ! cp "${payload_dir}/iptables-full.rules" "${stage_dir}/"; then
            rm -rf "${extract_dir}" "${config_snap}" "${stage_dir}"
            error "번들에서 iptables-full.rules 복사 실패"
            return 1
        fi
    fi

    if [[ -d "${payload_dir}/teams" ]]; then
        shopt -s nullglob
        local team_files=("${payload_dir}/teams/"*.conf)
        if (( ${#team_files[@]} > 0 )); then
            if ! cp "${team_files[@]}" "${stage_dir}/teams/"; then
                shopt -u nullglob
                rm -rf "${extract_dir}" "${config_snap}" "${stage_dir}"
                error "번들에서 팀 설정 파일 복사 실패"
                return 1
            fi
        fi
        shopt -u nullglob
    fi

    init_config_dir
    _bundle_snapshot_config "${config_snap}"

    rm -f "${CONFIG_DIR}/iptables.rules" "${CONFIG_DIR}/iptables-full.rules"
    rm -f "${CONFIG_DIR}/teams/"*.conf 2>/dev/null || true

    if ! cp "${stage_dir}/iptables.rules" "${CONFIG_DIR}/"; then
        error "iptables.rules 적용 실패"
        _bundle_restore_config_snapshot "${config_snap}"
        rm -rf "${extract_dir}" "${config_snap}" "${stage_dir}"
        return 1
    fi

    if [[ -f "${stage_dir}/iptables-full.rules" ]]; then
        if ! cp "${stage_dir}/iptables-full.rules" "${CONFIG_DIR}/"; then
            error "iptables-full.rules 적용 실패"
            _bundle_restore_config_snapshot "${config_snap}"
            rm -rf "${extract_dir}" "${config_snap}" "${stage_dir}"
            return 1
        fi
    fi

    if [[ -d "${stage_dir}/teams" ]]; then
        shopt -s nullglob
        local team_files=("${stage_dir}/teams/"*.conf)
        if (( ${#team_files[@]} > 0 )); then
            if ! cp "${team_files[@]}" "${CONFIG_DIR}/teams/"; then
                shopt -u nullglob
                error "팀 설정 파일 적용 실패"
                _bundle_restore_config_snapshot "${config_snap}"
                rm -rf "${extract_dir}" "${config_snap}" "${stage_dir}"
                return 1
            fi
        fi
        shopt -u nullglob
    fi

    if ! ${quiet}; then
        success "번들 가져오기 완료: ${archive_path}"
    fi

    if ${apply_after}; then
        if ! ${quiet}; then
            info "가져온 설정을 바로 적용합니다..."
        fi

        if persist_load --quiet; then
            rm -rf "${extract_dir}" "${config_snap}" "${stage_dir}"
            if ! ${quiet}; then
                success "번들 적용까지 완료되었습니다."
            fi
            return 0
        fi

        warn "번들 적용 실패. on-disk 설정을 이전 상태로 복구합니다..."
        _bundle_restore_config_snapshot "${config_snap}"
        rm -rf "${extract_dir}" "${config_snap}" "${stage_dir}"
        return 1
    fi

    rm -rf "${extract_dir}" "${config_snap}" "${stage_dir}"
    return 0
}

bundle_export_interactive() {
    print_header "이전 번들 내보내기"
    info "현재 저장된 config 상태를 tar.gz 번들로 만듭니다."
    info "live 상태를 옮기려면 먼저 '현재 규칙 저장'을 실행하세요."
    echo ""

    local default_path="${CONFIG_DIR}/backups/fw-bundle-$(date +%Y-%m-%d_%H%M%S).tar.gz"
    prompt_input "번들 파일 경로" "${default_path}"
    local archive_path="${REPLY}"

    preview_cmd "tar -czf ${archive_path} ..."

    if ! prompt_confirm "내보내시겠습니까?"; then
        info "취소되었습니다."
        pause
        return 0
    fi

    bundle_export "${archive_path}"
    pause
}

bundle_import_interactive() {
    print_header "이전 번들 가져오기"

    if ! prompt_confirm "가져온 번들을 현재 config에 덮어쓸 수 있습니다. 계속하시겠습니까?"; then
        info "취소되었습니다."
        pause
        return 0
    fi

    echo ""
    prompt_input "번들 파일 경로"
    local archive_path="${REPLY}"

    local apply_now=false
    if prompt_confirm "가져온 뒤 바로 방화벽에 적용하시겠습니까?"; then
        apply_now=true
    fi

    if ${apply_now}; then
        bundle_import "${archive_path}" --apply
    else
        bundle_import "${archive_path}"
    fi

    pause
}
