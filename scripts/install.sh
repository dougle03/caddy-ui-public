#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_EXAMPLE="${ROOT_DIR}/.env.example"
COMPOSE_EXAMPLE="${ROOT_DIR}/docker-compose.example.yml"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"
ENV_FILE="${ROOT_DIR}/.env"
APP_UID="10001"

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
    if confirm "Apply ACLs for UID ${APP_UID} now?"; then
        require_command setfacl
        setfacl -m "u:${APP_UID}:rwx" "${caddy_host_dir}"
        setfacl -m "u:${APP_UID}:rw" "${caddyfile_path}"
        setfacl -d -m "u:${APP_UID}:rwx" "${caddy_host_dir}"
        printf 'Applied ACLs for UID %s\n' "${APP_UID}"
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
    local default_container_name="$1"
    local default_caddy_host_dir="$2"
    local default_listen_ip="$3"
    local default_app_port="$4"
    local default_caddyfile_app_path="$5"
    local default_caddyfile_container_path="$6"
    local docker_gid="$7"

    show_running_containers

    local caddy_container_name
    local caddy_host_dir
    local caddyfile_path
    local app_listen_ip
    local app_port
    local caddyfile_app_path
    local caddyfile_container_path

    caddy_container_name="$(prompt_with_default "Caddy container name" "${default_container_name}")"
    if ! docker inspect "${caddy_container_name}" >/dev/null 2>&1; then
        printf 'Container not found: %s\n' "${caddy_container_name}" >&2
        exit 1
    fi

    caddy_host_dir="$(prompt_with_default "Host Caddy directory" "${default_caddy_host_dir}")"
    if [[ ! -d "${caddy_host_dir}" ]]; then
        printf 'Directory not found: %s\n' "${caddy_host_dir}" >&2
        exit 1
    fi

    caddyfile_path="${caddy_host_dir}/Caddyfile"
    if [[ ! -f "${caddyfile_path}" ]]; then
        printf 'Caddyfile not found: %s\n' "${caddyfile_path}" >&2
        exit 1
    fi

    app_listen_ip="$(prompt_with_default "APP_LISTEN_IP" "${default_listen_ip}")"
    app_port="$(prompt_with_default "APP_PORT" "${default_app_port}")"
    caddyfile_app_path="$(prompt_with_default "CADDYFILE_APP_PATH" "${default_caddyfile_app_path}")"
    caddyfile_container_path="$(prompt_with_default "CADDYFILE_CONTAINER_PATH" "${default_caddyfile_container_path}")"

    if [[ ! -f "${ENV_FILE}" ]]; then
        cp "${ENV_EXAMPLE}" "${ENV_FILE}"
        printf 'Created %s from %s\n' "${ENV_FILE}" "${ENV_EXAMPLE}"
    else
        printf 'Updating existing %s\n' "${ENV_FILE}"
    fi

    set_env_value "APP_LISTEN_IP" "${app_listen_ip}" "${ENV_FILE}"
    set_env_value "APP_PORT" "${app_port}" "${ENV_FILE}"
    set_env_value "CADDY_HOST_DIR" "${caddy_host_dir}" "${ENV_FILE}"
    set_env_value "CADDY_CONTAINER_NAME" "${caddy_container_name}" "${ENV_FILE}"
    set_env_value "DOCKER_GID" "${docker_gid}" "${ENV_FILE}"
    set_env_value "CADDYFILE_APP_PATH" "${caddyfile_app_path}" "${ENV_FILE}"
    set_env_value "CADDYFILE_CONTAINER_PATH" "${caddyfile_container_path}" "${ENV_FILE}"

    printf '\nThe default Compose setup uses a named Docker volume for app data.\n'
    printf 'No local app data directories need to be created for that default.\n'

    apply_acl_setup "${caddy_host_dir}" "${caddyfile_path}"

    printf '\nInstaller summary:\n'
    printf '  APP_LISTEN_IP=%s\n' "${app_listen_ip}"
    printf '  APP_PORT=%s\n' "${app_port}"
    printf '  CADDY_HOST_DIR=%s\n' "${caddy_host_dir}"
    printf '  CADDY_CONTAINER_NAME=%s\n' "${caddy_container_name}"
    printf '  DOCKER_GID=%s\n' "${docker_gid}"
    printf '  CADDYFILE_APP_PATH=%s\n' "${caddyfile_app_path}"
    printf '  CADDYFILE_CONTAINER_PATH=%s\n' "${caddyfile_container_path}"

    if grep -q '^APP_SECRET_KEY=replace-with-at-least-32-random-bytes$' "${ENV_FILE}"; then
        printf '\nWARNING: APP_SECRET_KEY still uses the placeholder value in %s\n' "${ENV_FILE}"
    fi

    printf '\nNext command:\n'
    printf '  docker compose up -d --build\n'
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
docker_gid="$(stat -c '%g' /var/run/docker.sock)"

if [[ ! -f "${ENV_FILE}" ]]; then
    printf 'No .env file found. Proceeding with first-install setup.\n'
    ensure_compose_file_for_first_install
    run_configuration_flow "caddy" "/srv/caddy" "0.0.0.0" "5059" "/managed-caddy/Caddyfile" "/etc/caddy/Caddyfile" "${docker_gid}"
    exit 0
fi

printf 'Existing installation detected. This installer is mainly for first install or deliberate reconfiguration.\n'
printf '\nChoose an action:\n'
printf '  1) Check current install only, no .env changes\n'
printf '  2) Reconfigure existing install\n'
printf '  3) Cancel\n'
read -r -p 'Selection [1/2/3]: ' selection

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
        ;;
    2)
        printf '\nReconfigure mode will update values in %s.\n' "${ENV_FILE}"
        if ! confirm "Continue with reconfiguration?"; then
            printf 'Cancelled.\n'
            exit 0
        fi
        run_configuration_flow \
            "${env_container_name:-caddy}" \
            "${env_caddy_host_dir:-/srv/caddy}" \
            "${env_app_listen_ip:-0.0.0.0}" \
            "${env_app_port:-5059}" \
            "${env_caddyfile_app_path:-/managed-caddy/Caddyfile}" \
            "${env_caddyfile_container_path:-/etc/caddy/Caddyfile}" \
            "${docker_gid}"
        ;;
    *)
        printf 'Cancelled.\n'
        ;;
esac
