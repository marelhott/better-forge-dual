#!/bin/bash
# pre_start.sh – single-instance UX Forge startup
# Called by the base image's /start.sh after nginx/SSH/code-server are up.
# Forge listens internally on 7860; nginx in the base image proxies 7861→7860.

set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[Forge]:${NC} $1"; }
err()  { echo -e "${RED}[Forge]:${NC} $1" >&2; }

WORKSPACE_ROOT="${WORKSPACE_ROOT:-/workspace}"
VENV_DIR="${WORKSPACE_ROOT}/bforge"
FORGE_DIR="${WORKSPACE_ROOT}/stable-diffusion-webui-forge"
LOG_FILE="${WORKSPACE_ROOT}/logs/webui.log"

# ── skip mode ─────────────────────────────────────────────────────────────────
if [[ "${NO_SYNC:-}" == "true" ]]; then
    log "NO_SYNC=true – skipping startup"
    exec sleep infinity
fi

# ── venv ──────────────────────────────────────────────────────────────────────
# Check for bin/activate – a missing activate script means the venv was only
# partially extracted (e.g. pod was terminated mid-tar).  Re-extract cleanly.
if [[ ! -f "${VENV_DIR}/bin/activate" ]]; then
    log "extracting virtual environment (bin/activate missing)..."
    rm -rf "${VENV_DIR}"
    mkdir -p "${VENV_DIR}"
    tar -xzf /bforge.tar.gz -C "${VENV_DIR}"
else
    log "virtual environment present"
fi

# ── forge install ─────────────────────────────────────────────────────────────
if [[ ! -d "${FORGE_DIR}" ]] || [[ -z "$(ls -A "${FORGE_DIR}" 2>/dev/null)" ]]; then
    log "syncing Forge into workspace (first run)..."
    mkdir -p "${FORGE_DIR}"
    # -aHx: archive + hardlinks + stay on filesystem
    # --ignore-existing: never overwrite user changes on subsequent syncs
    rsync -aHx --info=progress2 --ignore-existing --update \
        /stable-diffusion-webui-forge/ "${FORGE_DIR}/"
    log "sync complete"
else
    log "Forge already in workspace – skipping sync"
fi

mkdir -p "${WORKSPACE_ROOT}/logs" "${FORGE_DIR}/tmp/gradio"

# ── patch webui.sh for root ───────────────────────────────────────────────────
if grep -q 'can_run_as_root=0' "${FORGE_DIR}/webui.sh" 2>/dev/null; then
    sed -i 's/can_run_as_root=0/can_run_as_root=1/' "${FORGE_DIR}/webui.sh"
fi

# ── neutralise webui-user.sh ──────────────────────────────────────────────────
# The workspace volume persists between pod restarts. An old webui-user.sh
# with stale COMMANDLINE_ARGS would override our env-var-based config.
# Write a minimal stub – we inject everything via environment below.
cat > "${FORGE_DIR}/webui-user.sh" << 'STUB'
#!/bin/bash
# Managed by pre_start.sh – do not set COMMANDLINE_ARGS here.
export PYTORCH_CUDA_ALLOC_CONF="expandable_segments:True"
STUB

# ── launch ────────────────────────────────────────────────────────────────────
log "launching Forge on port 7860 (public: 7861 via nginx)..."
log "log → ${LOG_FILE}"

(
    cd "${FORGE_DIR}"

    # unset VIRTUAL_ENV so webui.sh activates our bforge venv properly
    # and sets python_cmd to bforge/bin/python (not system python3).
    unset VIRTUAL_ENV
    export venv_dir="${VENV_DIR}"

    export GRADIO_TEMP_DIR="${FORGE_DIR}/tmp/gradio"
    export COMMANDLINE_ARGS="\
--listen \
--port 7860 \
--api \
--enable-insecure-extension-access \
--opt-sdp-attention \
--cuda-malloc \
${EXTRA_FORGE_ARGS:-}"

    log "COMMANDLINE_ARGS: ${COMMANDLINE_ARGS}"
    bash webui.sh -f >> "${LOG_FILE}" 2>&1
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Forge exited with code $?" >> "${LOG_FILE}"
) &

FORGE_PID=$!
log "Forge PID=${FORGE_PID}"

# pre_start.sh returns here; /start.sh in the base image continues with
# its own sleep infinity – the Forge background process keeps running.
