#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_EXAMPLE="${ROOT_DIR}/.env.example"
COMPOSE_EXAMPLE="${ROOT_DIR}/docker-compose.example.yml"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"
ENV_FILE="${ROOT_DIR}/.env"
APP_UID="10001"
YES=0
MANUAL=0
CHECK_ONLY=0

for arg in "$@"; do
    case "$arg" in
        -y|--yes) YES=1 ;;
        --manual) MANUAL=1 ;;
        --check) CHECK_ONLY=1 ;;
        *) printf 'Unknown option: %s\n' "$arg" >&2; exit 1 ;;
    esac
done

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
    fi
}

confirm() {
    local prompt="$1"
    local answer
    read -r -p "${prompt} [y/N]: " answer
    [[ "${answer}" =~ ^[Yy]([Ee][Ss])?$ ]]
}

have_command() {
    command -v "$1" >/dev/null 2>&1
}

prompt_with_default() {
    local prompt="$1"
    local default_value="$2"
    local value
    read -r -p "${prompt} [${default_value}]: " value
    if [[ -z "${value}" ]]; then
        value="${default_value}"
    fi
    printf '%s' "${value}"
}

get_env_value() {
    local key="$1"
    local file="$2"
    if [[ ! -f "${file}" ]]; then
        return 1
    fi
    awk -F= -v key="${key}" '$1 == key { sub(/^[^=]*=/, "", $0); print $0; exit }' "${file}"
}

gen_secret() {
    if have_command openssl; then
        openssl rand -hex 32
        return
    fi
    python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
}

detect_socket_gid() {
    stat -c '%g' /var/run/docker.sock
}

detect_port_in_use() {
    local port="$1"
    ss -ltn "( sport = :${port} )" 2>/dev/null | tail -n +2 | grep -q .
}

detect_caddy_candidates() {
    docker ps --format '{{.Names}}|{{.Image}}|{{.Status}}' | while IFS='|' read -r name image status; do
        [[ "${status}" == *"Up"* ]] || continue
        if [[ "${name}" == "caddy" ]]; then
            printf 'caddy\n'
        elif [[ "${name}" == *caddy* || "${image}" == *caddy* ]]; then
            printf '%s\n' "${name}"
        fi
    done | awk '!seen[$0]++'
}

detect_caddy_mount() {
    local container_name="$1"
    docker inspect "${container_name}" --format '{{range .Mounts}}{{println .Source "|" .Destination}}{{end}}'
}

set_env_value() {
    local key="$1"
    local value="$2"
    local target_file="$3"
    local temp_file
    temp_file="$(mktemp)"
    awk -v key="${key}" -v value="${value}" '
        BEGIN { updated = 0 }
        $0 ~ ("^" key "=") {
            print key "=" value
            updated = 1
            next
        }
        { print }
        END {
            if (!updated) {
                print key "=" value
            }
        }
    ' "${target_file}" > "${temp_file}"
    mv "${temp_file}" "${target_file}"
}

check_prerequisites() {
    require_command docker
    if ! docker compose version >/dev/null 2>&1; then
        printf 'Docker Compose plugin is required. `docker compose version` failed.\n' >&2
        exit 1
    fi
    if [[ ! -S /var/run/docker.sock ]]; then
        printf 'Docker socket not found at /var/run/docker.sock\n' >&2
        exit 1
    fi
}

show_running_containers() {
    printf 'Running containers:\n'
    docker ps --format '  - {{.Names}} ({{.Image}})'
    printf '\n'
}

apply_acl_setup() {
    local caddy_host_dir="$1"
    local caddyfile_path="$2"
    printf '\nOptional ACL step:\n'
    printf '  This can grant container UID %s write access to:\n' "${APP_UID}"
    printf '  - %s\n' "${caddy_host_dir}"
    printf '  - %s\n' "${caddyfile_path}"
    printf '  It will not use chmod 777.\n'
    if [[ -w "${caddyfile_path}" ]]; then
        printf '  UID %s can already write the Caddyfile path.\n' "${APP_UID}"
        return
    fi
    if confirm "Apply ACLs for UID ${APP_UID} now?"; then
        if have_command sudo && sudo -n true >/dev/null 2>&1; then
            sudo setfacl -m "u:${APP_UID}:rwx" "${caddy_host_dir}"
            sudo setfacl -m "u:${APP_UID}:rw" "${caddyfile_path}"
            sudo setfacl -d -m "u:${APP_UID}:rwx" "${caddy_host_dir}"
            printf 'Applied ACLs for UID %s\n' "${APP_UID}"
            return
        fi
        if have_command sudo && confirm "Run the exact sudo setfacl commands yourself?"; then
            printf 'sudo setfacl -m "u:%s:rwx" "%s"\n' "${APP_UID}" "${caddy_host_dir}"
            printf 'sudo setfacl -m "u:%s:rw" "%s"\n' "${APP_UID}" "${caddyfile_path}"
            printf 'sudo setfacl -d -m "u:%s:rwx" "%s"\n' "${APP_UID}" "${caddy_host_dir}"
            return
        fi
        printf 'Install setfacl and run these commands as root:\n'
        printf '  setfacl -m "u:%s:rwx" "%s"\n' "${APP_UID}" "${caddy_host_dir}"
        printf '  setfacl -m "u:%s:rw" "%s"\n' "${APP_UID}" "${caddyfile_path}"
        printf '  setfacl -d -m "u:%s:rwx" "%s"\n' "${APP_UID}" "${caddy_host_dir}"
    else
        printf 'Skipped ACL changes.\n'
    fi
}

print_update_commands() {
    printf '\nNormal update commands:\n'
    printf '  Image-based deployment: docker compose pull && docker compose up -d\n'
    printf '  Local build deployment: docker compose up -d --build\n'
    printf 'After updating, check the Diagnostics page in the UI.\n'
}

run_configuration_flow() {
    local mode="$1"
    local default_container_name="$2"
    local default_caddy_host_dir="$3"
    local default_listen_ip="$4"
    local default_app_port="$5"
    local default_caddyfile_app_path="$6"
    local default_caddyfile_container_path="$7"
    local docker_gid="$8"
    local auto_confirm="$9"

    local caddy_container_name="$default_container_name"
    local caddy_host_dir="$default_caddy_host_dir"
    local caddyfile_path="${caddy_host_dir}/Caddyfile"
    local app_listen_ip="${default_listen_ip}"
    local app_port="${default_app_port}"
    local caddyfile_app_path="${default_caddyfile_app_path}"
    local caddyfile_container_path="${default_caddyfile_container_path}"
    local app_secret_key

    if [[ "${mode}" == "manual" ]]; then
        show_running_containers
        caddy_container_name="$(prompt_with_default "Caddy container name" "${default_container_name}")"
        caddy_host_dir="$(prompt_with_default "Host Caddy directory" "${default_caddy_host_dir}")"
        app_listen_ip="$(prompt_with_default "APP_LISTEN_IP" "${default_listen_ip}")"
        app_port="$(prompt_with_default "APP_PORT" "${default_app_port}")"
        caddyfile_container_path="$(prompt_with_default "CADDYFILE_CONTAINER_PATH" "${default_caddyfile_container_path}")"
    else
        if [[ -z "${caddy_container_name}" || -z "${caddy_host_dir}" ]]; then
            auto_detect_install_target
            caddy_container_name="${AUTO_CADDY_CONTAINER_NAME}"
            caddy_host_dir="${AUTO_CADDY_HOST_DIR}"
            caddyfile_container_path="${AUTO_CADDYFILE_CONTAINER_PATH}"
        fi
    fi

    caddyfile_path="${caddy_host_dir}/Caddyfile"
    if [[ ! -f "${caddyfile_path}" ]]; then
        printf 'Caddyfile not found: %s\n' "${caddyfile_path}" >&2
        exit 1
    fi

    if [[ "${mode}" == "manual" ]]; then
        caddyfile_app_path="$(prompt_with_default "CADDYFILE_APP_PATH" "${default_caddyfile_app_path}")"
    fi

    if [[ "${mode}" != "manual" && "${app_port}" == "5059" ]] && detect_port_in_use "${app_port}"; then
        printf 'Port %s is already in use.\n' "${app_port}" >&2
        app_port="$(prompt_with_default "APP_PORT" "5058")"
    fi

    if have_command openssl; then
        app_secret_key="$(openssl rand -hex 32)"
    else
        app_secret_key="$(gen_secret)"
    fi

    if [[ ! -f "${ENV_FILE}" ]]; then
        cp "${ENV_EXAMPLE}" "${ENV_FILE}"
        printf 'Created %s from %s\n' "${ENV_FILE}" "${ENV_EXAMPLE}"
    else
        printf 'Updating existing %s\n' "${ENV_FILE}"
    fi

    set_env_value "APP_LISTEN_IP" "${app_listen_ip}" "${ENV_FILE}"
    set_env_value "APP_PORT" "${app_port}" "${ENV_FILE}"
    set_env_value "APP_SECRET_KEY" "${app_secret_key}" "${ENV_FILE}"
    set_env_value "APP_ALLOWED_SUBNETS" "127.0.0.1/32,172.16.0.0/12,192.168.0.0/16,10.0.0.0/8" "${ENV_FILE}"
    set_env_value "CADDY_HOST_DIR" "${caddy_host_dir}" "${ENV_FILE}"
    set_env_value "CADDY_CONTAINER_NAME" "${caddy_container_name}" "${ENV_FILE}"
    set_env_value "DOCKER_GID" "${docker_gid}" "${ENV_FILE}"
    set_env_value "CADDYFILE_APP_PATH" "${caddyfile_app_path}" "${ENV_FILE}"
    set_env_value "CADDYFILE_CONTAINER_PATH" "${caddyfile_container_path}" "${ENV_FILE}"

    printf '\nInstaller summary:\n'
    printf '  APP_LISTEN_IP=%s\n' "${app_listen_ip}"
    printf '  APP_PORT=%s\n' "${app_port}"
    printf '  CADDY_HOST_DIR=%s\n' "${caddy_host_dir}"
    printf '  CADDY_CONTAINER_NAME=%s\n' "${caddy_container_name}"
    printf '  DOCKER_GID=%s\n' "${docker_gid}"
    printf '  CADDYFILE_APP_PATH=%s\n' "${caddyfile_app_path}"
    printf '  CADDYFILE_CONTAINER_PATH=%s\n' "${caddyfile_container_path}"
    printf '  APP_ALLOWED_SUBNETS=%s\n' "127.0.0.1/32,172.16.0.0/12,192.168.0.0/16,10.0.0.0/8"

    if [[ "${mode}" == "manual" ]]; then
        apply_acl_setup "${caddy_host_dir}" "${caddyfile_path}"
        printf '\nNext command:\n'
        printf '  docker compose up -d --build\n'
        return
    fi

    if [[ "${auto_confirm}" == "1" || "${YES}" == "1" ]] || confirm "Write .env with detected values and start the stack?"; then
        apply_acl_setup "${caddy_host_dir}" "${caddyfile_path}"
        if [[ ! -f "${COMPOSE_FILE}" ]]; then
            ensure_compose_file_for_first_install
        fi
        docker compose up -d
        printf '\nNext command:\n'
        printf '  docker compose up -d\n'
        printf '\nFinal URL:\n'
        printf '  http://%s:%s\n' "${app_listen_ip}" "${app_port}"
    else
        printf 'Cancelled.\n'
    fi
}

auto_detect_install_target() {
    local -a candidates=()
    local line name image
    while IFS='|' read -r name image; do
        [[ -n "${name}" ]] || continue
        [[ "${name}" == "caddy" ]] && candidates=("${name}" "${candidates[@]}") && continue
        [[ "${name}" == *caddy* || "${image}" == *caddy* ]] && candidates+=("${name}")
    done < <(docker ps --format '{{.Names}}|{{.Image}}')

    if [[ ${#candidates[@]} -eq 1 ]]; then
        AUTO_CADDY_CONTAINER_NAME="${candidates[0]}"
    elif [[ ${#candidates[@]} -gt 1 ]]; then
        printf 'Multiple Caddy-like containers found:\n'
        select candidate in "${candidates[@]}"; do
            if [[ -n "${candidate}" ]]; then
                AUTO_CADDY_CONTAINER_NAME="${candidate}"
                break
            fi
        done
    else
        AUTO_CADDY_CONTAINER_NAME="$(prompt_with_default "Caddy container name" "caddy")"
    fi

    if ! docker inspect "${AUTO_CADDY_CONTAINER_NAME}" >/dev/null 2>&1; then
        printf 'Container not found: %s\n' "${AUTO_CADDY_CONTAINER_NAME}" >&2
        exit 1
    fi

    AUTO_CADDY_HOST_DIR=""
    AUTO_CADDYFILE_CONTAINER_PATH="/etc/caddy/Caddyfile"
    while IFS='|' read -r source destination; do
        if [[ "${destination}" == "/etc/caddy" || "${destination}" == "/etc/caddy/Caddyfile" ]]; then
            AUTO_CADDY_HOST_DIR="${source%/}"
            AUTO_CADDYFILE_CONTAINER_PATH="${destination}"
            break
        fi
    done < <(detect_caddy_mount "${AUTO_CADDY_CONTAINER_NAME}")

    if [[ -z "${AUTO_CADDY_HOST_DIR}" ]]; then
        AUTO_CADDY_HOST_DIR="$(prompt_with_default "Host Caddy directory" "/srv/caddy")"
    fi
}

ensure_compose_file_for_first_install() {
    if [[ -f "${COMPOSE_FILE}" ]]; then
        return
    fi
    if [[ -f "${COMPOSE_EXAMPLE}" ]]; then
        cp "${COMPOSE_EXAMPLE}" "${COMPOSE_FILE}"
        printf 'Created %s from %s\n' "${COMPOSE_FILE}" "${COMPOSE_EXAMPLE}"
    fi
}

check_existing_install() {
    local docker_gid="$1"
    local env_docker_gid="$2"
    local env_container_name="$3"
    local env_caddy_host_dir="$4"
    local caddyfile_path

    printf '\nExisting installation check:\n'
    printf '  Docker socket GID on host: %s\n' "${docker_gid}"
    if [[ -n "${env_docker_gid}" ]]; then
        printf '  DOCKER_GID in .env: %s\n' "${env_docker_gid}"
        if [[ "${docker_gid}" != "${env_docker_gid}" ]]; then
            printf '  WARNING: DOCKER_GID in .env does not match the current Docker socket GID.\n'
        fi
    else
        printf '  WARNING: DOCKER_GID is not set in .env\n'
    fi

    if [[ -n "${env_container_name}" ]]; then
        if docker inspect "${env_container_name}" >/dev/null 2>&1; then
            printf '  CADDY_CONTAINER_NAME exists: %s\n' "${env_container_name}"
        else
            printf '  WARNING: configured CADDY_CONTAINER_NAME not found: %s\n' "${env_container_name}"
        fi
    else
        printf '  WARNING: CADDY_CONTAINER_NAME is not set in .env\n'
    fi

    if [[ -n "${env_caddy_host_dir}" ]]; then
        if [[ -d "${env_caddy_host_dir}" ]]; then
            printf '  CADDY_HOST_DIR exists: %s\n' "${env_caddy_host_dir}"
        else
            printf '  WARNING: configured CADDY_HOST_DIR does not exist: %s\n' "${env_caddy_host_dir}"
        fi
        caddyfile_path="${env_caddy_host_dir}/Caddyfile"
        if [[ -f "${caddyfile_path}" ]]; then
            printf '  Caddyfile exists: %s\n' "${caddyfile_path}"
        else
            printf '  WARNING: Caddyfile not found: %s\n' "${caddyfile_path}"
        fi
    else
        printf '  WARNING: CADDY_HOST_DIR is not set in .env\n'
    fi

    if [[ -n "${env_caddy_host_dir}" && -f "${env_caddy_host_dir}/Caddyfile" ]]; then
        if confirm "Check or fix ACLs for UID ${APP_UID} on the configured Caddy directory?"; then
            apply_acl_setup "${env_caddy_host_dir}" "${env_caddy_host_dir}/Caddyfile"
        fi
    fi

    print_update_commands
}

printf 'caddy-admin-ui installer\n\n'

check_prerequisites
docker_gid="$(detect_socket_gid)"

if [[ ! -f "${ENV_FILE}" ]]; then
    printf 'No .env file found. Proceeding with first-install setup.\n'
    ensure_compose_file_for_first_install
    if [[ "${MANUAL}" == "1" ]]; then
        run_configuration_flow "manual" "caddy" "/srv/caddy" "0.0.0.0" "5059" "/managed-caddy/Caddyfile" "/etc/caddy/Caddyfile" "${docker_gid}" "0"
    else
        run_configuration_flow "auto" "" "" "0.0.0.0" "5059" "/managed-caddy/Caddyfile" "/etc/caddy/Caddyfile" "${docker_gid}" "${YES}"
    fi
    exit 0
fi

printf 'Existing installation detected. This installer is mainly for first install or deliberate reconfiguration.\n'
printf '\nChoose an action:\n'
printf '  1) Check current install only, no .env changes\n'
printf '  2) Reconfigure existing install\n'
printf '  3) Cancel\n'
if [[ "${CHECK_ONLY}" == "1" ]]; then
    selection="1"
else
    read -r -p 'Selection [1/2/3]: ' selection
fi

env_app_listen_ip="$(get_env_value "APP_LISTEN_IP" "${ENV_FILE}" || true)"
env_app_port="$(get_env_value "APP_PORT" "${ENV_FILE}" || true)"
env_caddy_host_dir="$(get_env_value "CADDY_HOST_DIR" "${ENV_FILE}" || true)"
env_container_name="$(get_env_value "CADDY_CONTAINER_NAME" "${ENV_FILE}" || true)"
env_docker_gid="$(get_env_value "DOCKER_GID" "${ENV_FILE}" || true)"
env_caddyfile_app_path="$(get_env_value "CADDYFILE_APP_PATH" "${ENV_FILE}" || true)"
env_caddyfile_container_path="$(get_env_value "CADDYFILE_CONTAINER_PATH" "${ENV_FILE}" || true)"

case "${selection}" in
    1)
        check_existing_install "${docker_gid}" "${env_docker_gid}" "${env_container_name}" "${env_caddy_host_dir}"
        if [[ "${CHECK_ONLY}" == "1" ]]; then
            exit 0
        fi
        ;;
    2)
        printf '\nReconfigure mode will update values in %s.\n' "${ENV_FILE}"
        if ! confirm "Continue with reconfiguration?"; then
            printf 'Cancelled.\n'
            exit 0
        fi
        run_configuration_flow \
            "manual" \
            "${env_container_name:-caddy}" \
            "${env_caddy_host_dir:-/srv/caddy}" \
            "${env_app_listen_ip:-0.0.0.0}" \
            "${env_app_port:-5059}" \
            "${env_caddyfile_app_path:-/managed-caddy/Caddyfile}" \
            "${env_caddyfile_container_path:-/etc/caddy/Caddyfile}" \
            "${docker_gid}" \
            "0"
        ;;
    *)
        printf 'Cancelled.\n'
        ;;
esac
