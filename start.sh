#!/usr/bin/env bash
set -euo pipefail

CODE_PORT="${CODE_PORT:-7777}"
FORGE_PORT="${FORGE_PORT:-7862}"
UX_PORT="${UX_PORT:-7861}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-/workspace}"
VENV_DIR="${VENV_DIR:-${WORKSPACE_ROOT}/bforge}"
FORGE_DIR="${FORGE_DIR:-${WORKSPACE_ROOT}/stable-diffusion-webui-forge}"
UX_FORGE_DIR="${UX_FORGE_DIR:-${WORKSPACE_ROOT}/stable-diffusion-webui-ux-forge}"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
print_feedback() { echo -e "${GREEN}[start]:${NC} $1"; }
print_error()    { echo -e "${RED}[start]:${NC} $1" >&2; }

kill_port() {
    local port="$1"
    if command -v lsof >/dev/null 2>&1; then
        local pids
        pids="$(lsof -t -iTCP:${port} -sTCP:LISTEN 2>/dev/null || true)"
        if [[ -n "${pids}" ]]; then
            print_feedback "killing stale processes on port ${port}: ${pids}"
            kill -9 ${pids} || true
        fi
    fi
}

wait_for_port() {
    local port="$1"
    local name="$2"
    local timeout="${3:-360}"
    local elapsed=0
    print_feedback "waiting for ${name} on port ${port} (max ${timeout}s)..."
    while ! ss -lntp 2>/dev/null | grep -q ":${port} "; do
        sleep 5
        elapsed=$((elapsed + 5))
        if [[ "${elapsed}" -ge "${timeout}" ]]; then
            print_error "timeout waiting for ${name} on port ${port} after ${timeout}s"
            return 1
        fi
    done
    print_feedback "${name} is up on port ${port}"
}

rsync_with_progress() {
    rsync -aHx --info=progress2 --ignore-existing --update "$@"
}

setup_ssh() {
    if [[ -n "${PUBLIC_KEY:-}" ]]; then
        print_feedback "setting up SSH..."
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
    print_feedback "exporting environment variables..."
    printenv | grep -E '^RUNPOD_|^PATH=|^_=' \
        | awk -F= '{ print "export " $1 "=\"" $2 "\"" }' >> /etc/rp_environment
    echo 'source /etc/rp_environment' >> ~/.bashrc
}

prepare_workspace() {
    mkdir -p "${WORKSPACE_ROOT}/logs"

    if [[ ! -d "${VENV_DIR}" ]] || [[ -z "$(ls -A "${VENV_DIR}" 2>/dev/null)" ]]; then
        print_feedback "extracting virtual environment..."
        mkdir -p "${VENV_DIR}"
        tar -xzf /bforge.tar.gz -C "${VENV_DIR}"
    else
        print_feedback "virtual environment already present, skipping extraction"
    fi

    source "${VENV_DIR}/bin/activate"

    if [[ ! -d "${FORGE_DIR}" ]] || [[ -z "$(ls -A "${FORGE_DIR}" 2>/dev/null)" ]]; then
        print_feedback "syncing Classic Forge into workspace..."
        mkdir -p "${FORGE_DIR}"
        rsync_with_progress /stable-diffusion-webui-forge/ "${FORGE_DIR}/"
    else
        print_feedback "Classic Forge already present"
    fi

    if [[ ! -d "${UX_FORGE_DIR}" ]] || [[ -z "$(ls -A "${UX_FORGE_DIR}" 2>/dev/null)" ]]; then
        print_feedback "creating UX Forge directory from Classic Forge..."
        mkdir -p "${UX_FORGE_DIR}"
        rsync_with_progress "${FORGE_DIR}/" "${UX_FORGE_DIR}/"
    else
        print_feedback "UX Forge directory already present"
    fi

    for target in "${FORGE_DIR}" "${UX_FORGE_DIR}"; do
        if [[ -f "${target}/webui.sh" ]] && grep -q "can_run_as_root=0" "${target}/webui.sh"; then
            sed -i 's/can_run_as_root=0/can_run_as_root=1/' "${target}/webui.sh"
        fi
    done
}

write_webui_user() {
    local target="$1"
    # Blank out webui-user.sh so any stale COMMANDLINE_ARGS from persistent
    # volume can't interfere — we inject args via environment instead.
    printf '#!/bin/bash\n# Managed by start.sh — do not set COMMANDLINE_ARGS here.\n' \
        > "${target}/webui-user.sh"
}

start_code_server() {
    kill_port "${CODE_PORT}"
    print_feedback "starting code-server on :${CODE_PORT}"
    code-server \
        --bind-addr "0.0.0.0:${CODE_PORT}" \
        --auth none \
        --disable-telemetry \
        /workspace \
        >> "${WORKSPACE_ROOT}/logs/code-server.log" 2>&1 &
    CODE_PID=$!
    print_feedback "code-server pid=${CODE_PID}"
}

start_classic_forge() {
    kill_port "${FORGE_PORT}"
    print_feedback "starting Classic Forge on :${FORGE_PORT}"
    write_webui_user "${FORGE_DIR}"
    (
        cd "${FORGE_DIR}"
        mkdir -p tmp/gradio
        export GRADIO_SERVER_PORT="${FORGE_PORT}"
        export GRADIO_TEMP_DIR="${FORGE_DIR}/tmp/gradio"
        export PYTORCH_CUDA_ALLOC_CONF="expandable_segments:True"
        export COMMANDLINE_ARGS="--listen --port ${FORGE_PORT} --api --theme dark --enable-insecure-extension-access"
        # tee streams output to both the log file and container stdout (RunPod pod log)
        bash webui.sh -f 2>&1 | tee "${WORKSPACE_ROOT}/logs/webui-classic.log"
    ) &
    FORGE_PID=$!
    print_feedback "Classic Forge pid=${FORGE_PID}"
}

start_ux_forge() {
    # UX Forge must wait for Classic to finish its pip install phase first.
    # They share the same venv — concurrent writes corrupt it.
    if ! wait_for_port "${FORGE_PORT}" "Classic Forge" 360; then
        print_error "Classic Forge never came up — skipping UX Forge"
        UX_PID=""
        return 0
    fi

    kill_port "${UX_PORT}"
    print_feedback "starting UX Forge on :${UX_PORT}"
    write_webui_user "${UX_FORGE_DIR}"
    (
        cd "${UX_FORGE_DIR}"
        mkdir -p tmp/gradio
        export GRADIO_SERVER_PORT="${UX_PORT}"
        export GRADIO_TEMP_DIR="${UX_FORGE_DIR}/tmp/gradio"
        export PYTORCH_CUDA_ALLOC_CONF="expandable_segments:True"
        # --skip-install: venv was already set up by Classic Forge above.
        # Running pip checks twice on the same venv causes lock conflicts.
        export COMMANDLINE_ARGS="--listen --port ${UX_PORT} --api --theme dark --enable-insecure-extension-access --skip-install"
        bash webui.sh -f 2>&1 | tee "${WORKSPACE_ROOT}/logs/webui-ux.log"
    ) &
    UX_PID=$!
    print_feedback "UX Forge pid=${UX_PID}"
}

# ── main ──────────────────────────────────────────────────────────────────────

setup_ssh
export_env_vars
prepare_workspace

start_code_server
start_classic_forge
# start_ux_forge is called inside a background job so the wait_for_port
# block doesn't stall this script — code-server stays responsive.
(start_ux_forge) &
UX_LAUNCHER_PID=$!

print_feedback "all launchers fired; monitoring services..."

# Monitor: exit only when a critical service (code-server or Classic Forge) dies.
# UX Forge failure is logged but does not bring down the container.
set +e
while true; do
    # Check code-server
    if [[ -n "${CODE_PID}" ]] && ! kill -0 "${CODE_PID}" 2>/dev/null; then
        print_error "code-server (pid=${CODE_PID}) exited unexpectedly"
        [[ -f "${WORKSPACE_ROOT}/logs/code-server.log" ]] \
            && tail -40 "${WORKSPACE_ROOT}/logs/code-server.log" >&2
        exit 1
    fi
    # Check Classic Forge
    if [[ -n "${FORGE_PID}" ]] && ! kill -0 "${FORGE_PID}" 2>/dev/null; then
        print_error "Classic Forge (pid=${FORGE_PID}) exited unexpectedly"
        [[ -f "${WORKSPACE_ROOT}/logs/webui-classic.log" ]] \
            && tail -80 "${WORKSPACE_ROOT}/logs/webui-classic.log" >&2
        exit 1
    fi
    # Check UX Forge — only warn, do not exit
    if [[ -n "${UX_PID:-}" ]] && ! kill -0 "${UX_PID}" 2>/dev/null; then
        print_error "UX Forge (pid=${UX_PID}) exited — container keeps running without it"
        [[ -f "${WORKSPACE_ROOT}/logs/webui-ux.log" ]] \
            && tail -80 "${WORKSPACE_ROOT}/logs/webui-ux.log" >&2
        UX_PID=""   # stop checking it
    fi
    sleep 10
done
