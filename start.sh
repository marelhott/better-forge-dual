#!/usr/bin/env bash
set -euo pipefail

CODE_PORT="${CODE_PORT:-7777}"
FORGE_PORT="${FORGE_PORT:-7862}"
UX_PORT="${UX_PORT:-7861}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-/workspace}"
VENV_DIR="${VENV_DIR:-${WORKSPACE_ROOT}/bforge}"
FORGE_DIR="${FORGE_DIR:-${WORKSPACE_ROOT}/stable-diffusion-webui-forge}"
UX_FORGE_DIR="${UX_FORGE_DIR:-${WORKSPACE_ROOT}/stable-diffusion-webui-ux-forge}"

print_feedback() {
    GREEN='\033[0;32m'
    NC='\033[0m'
    echo -e "${GREEN}[start]:${NC} $1"
}

kill_port() {
    local port="$1"
    if command -v lsof >/dev/null 2>&1; then
        local pids
        pids="$(lsof -t -iTCP:${port} -sTCP:LISTEN || true)"
        if [[ -n "${pids}" ]]; then
            print_feedback "killing processes on port ${port}: ${pids}"
            kill -9 ${pids} || true
        fi
    fi
}

rsync_with_progress() {
    rsync -aHvx --info=progress2 --ignore-existing --update --stats "$@"
}

setup_ssh() {
    if [[ -n "${PUBLIC_KEY:-}" ]]; then
        print_feedback "Setting up SSH..."
        mkdir -p ~/.ssh
        echo "$PUBLIC_KEY" >> ~/.ssh/authorized_keys
        chmod 700 -R ~/.ssh

        for key_type in rsa dsa ecdsa ed25519; do
            key_path="/etc/ssh/ssh_host_${key_type}_key"
            if [[ ! -f "${key_path}" ]]; then
                ssh-keygen -t "${key_type}" -f "${key_path}" -q -N ''
            fi
        done

        service ssh start
    fi
}

export_env_vars() {
    print_feedback "Exporting environment variables..."
    printenv | grep -E '^RUNPOD_|^PATH=|^_=' | awk -F = '{ print "export " $1 "=\"" $2 "\"" }' >> /etc/rp_environment
    echo 'source /etc/rp_environment' >> ~/.bashrc
}

prepare_workspace() {
    mkdir -p "${WORKSPACE_ROOT}/logs"

    if [[ ! -d "${VENV_DIR}" ]]; then
        print_feedback "Extracting virtual environment..."
        mkdir -p "${VENV_DIR}"
        tar -xzf /bforge.tar.gz -C "${VENV_DIR}"
    else
        print_feedback "Virtual environment already exists, skipping extraction..."
    fi

    # shellcheck disable=SC1090
    source "${VENV_DIR}/bin/activate"

    if [[ ! -d "${FORGE_DIR}" ]] || [[ -z "$(ls -A "${FORGE_DIR}" 2>/dev/null)" ]]; then
        print_feedback "Syncing classic Forge into workspace..."
        mkdir -p "${FORGE_DIR}"
        rsync_with_progress /stable-diffusion-webui-forge/ "${FORGE_DIR}/"
    else
        print_feedback "Classic Forge already present."
    fi

    if [[ ! -d "${UX_FORGE_DIR}" ]] || [[ -z "$(ls -A "${UX_FORGE_DIR}" 2>/dev/null)" ]]; then
        print_feedback "Creating UX Forge from classic Forge..."
        mkdir -p "${UX_FORGE_DIR}"
        rsync_with_progress "${FORGE_DIR}/" "${UX_FORGE_DIR}/"
    else
        print_feedback "UX Forge already present."
    fi

    for target in "${FORGE_DIR}" "${UX_FORGE_DIR}"; do
        if [[ -f "${target}/webui.sh" ]] && grep -q "can_run_as_root=0" "${target}/webui.sh"; then
            sed -i 's/can_run_as_root=0/can_run_as_root=1/' "${target}/webui.sh"
        fi
    done
}

start_code_server() {
    print_feedback "starting code-server on :${CODE_PORT}"
    (
        export PORT="${CODE_PORT}"
        exec code-server --bind-addr 0.0.0.0:${CODE_PORT} --auth none --disable-telemetry /workspace
    ) >> "${WORKSPACE_ROOT}/logs/code-server.log" 2>&1 &
    CODE_PID=$!
}

start_forge() {
    print_feedback "starting Forge on :${FORGE_PORT}"
    (
        cd "${FORGE_DIR}"
        mkdir -p "${FORGE_DIR}/tmp/gradio"
        export GRADIO_SERVER_PORT="${FORGE_PORT}"
        export GRADIO_TEMP_DIR="${FORGE_DIR}/tmp/gradio"
        export COMMANDLINE_ARGS="--listen --port ${FORGE_PORT} --api --theme dark"
        exec bash webui.sh -f
    ) >> "${WORKSPACE_ROOT}/logs/webui.log" 2>&1 &
    FORGE_PID=$!
}

start_ux_forge() {
    print_feedback "starting UX Forge on :${UX_PORT}"
    (
        cd "${UX_FORGE_DIR}"
        mkdir -p "${UX_FORGE_DIR}/tmp/gradio"
        export GRADIO_SERVER_PORT="${UX_PORT}"
        export GRADIO_TEMP_DIR="${UX_FORGE_DIR}/tmp/gradio"
        export COMMANDLINE_ARGS="--listen --port ${UX_PORT} --api --theme dark"
        exec bash webui.sh -f
    ) >> "${WORKSPACE_ROOT}/logs/webui-ux.log" 2>&1 &
    UX_PID=$!
}

kill_port "${CODE_PORT}"
kill_port "${FORGE_PORT}"
kill_port "${UX_PORT}"

setup_ssh
export_env_vars
prepare_workspace

start_code_server
start_forge
start_ux_forge

print_feedback "services started: code-server=${CODE_PID}, forge=${FORGE_PID}, ux=${UX_PID}"

wait -n "${CODE_PID}" "${FORGE_PID}" "${UX_PID}"
print_feedback "a service exited; stopping container"
exit 1
