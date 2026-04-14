#!/bin/bash
set -e

print_feedback() {
    GREEN='\033[0;32m'
    NC='\033[0m'
    echo -e "${GREEN}[Forge Startup]:${NC} $1"
}

rsync_with_progress() {
    rsync -aHvx --info=progress2 --ignore-existing --update --stats "$@"
}

start_forge_instance() {
    local root="$1"
    local name="$2"
    local port="$3"
    local log_file="$4"
    shift 4

    print_feedback "Starting ${name} on port ${port}..."
    cd "$root"

    if grep -q "can_run_as_root=0" webui.sh; then
        sed -i 's/can_run_as_root=0/can_run_as_root=1/' webui.sh
    fi

    COMMANDLINE_ARGS="--listen --port ${port} --enable-insecure-extension-access --api $*" ./webui.sh -f > >(tee "$log_file") 2>&1 &
}

if [ "${NO_SYNC}" == "true" ]; then
    print_feedback "Skipping sync and startup as per environment variable setting."
    exec bash -c 'sleep infinity'
fi

MODE="${FORGE_MODE:-classic}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-/workspace}"
CLASSIC_ROOT="${CLASSIC_ROOT:-${WORKSPACE_ROOT}/stable-diffusion-webui-forge}"
UX_ROOT="${UX_ROOT:-${WORKSPACE_ROOT}/stable-diffusion-webui-ux-forge}"

print_feedback "Starting Forge setup in mode: ${MODE}"

if [ ! -d "${WORKSPACE_ROOT}/bforge" ]; then
    print_feedback "Extracting virtual environment..."
    mkdir -p "${WORKSPACE_ROOT}/bforge"
    tar -xzf /bforge.tar.gz -C "${WORKSPACE_ROOT}/bforge"
else
    print_feedback "Virtual environment already exists, skipping extraction..."
fi

source "${WORKSPACE_ROOT}/bforge/bin/activate"

if [ ! -d "${CLASSIC_ROOT}" ] || [ -z "$(ls -A "${CLASSIC_ROOT}" 2>/dev/null)" ]; then
    print_feedback "Classic Forge not found or empty. Syncing all files..."
    mkdir -p "${CLASSIC_ROOT}"
    rsync_with_progress /stable-diffusion-webui-forge/ "${CLASSIC_ROOT}/"
    print_feedback "Initial classic sync completed."
else
    print_feedback "Classic Forge found. Skipping sync to preserve user modifications."
fi

if [ ! -d "${UX_ROOT}" ] || [ -z "$(ls -A "${UX_ROOT}" 2>/dev/null)" ]; then
    print_feedback "UX Forge not found or empty. Creating from classic Forge as a safe fallback..."
    mkdir -p "${UX_ROOT}"
    rsync_with_progress "${CLASSIC_ROOT}/" "${UX_ROOT}/"
else
    print_feedback "UX Forge found. Skipping sync to preserve user modifications."
fi

mkdir -p "${WORKSPACE_ROOT}/logs"

COMMON_MODEL_ARGS="--ckpt-dir ${CLASSIC_ROOT}/models/Stable-diffusion --lora-dir ${CLASSIC_ROOT}/models/Lora --vae-dir ${CLASSIC_ROOT}/models/VAE --embeddings-dir ${CLASSIC_ROOT}/embeddings --hypernetwork-dir ${CLASSIC_ROOT}/models/hypernetworks --gfpgan-models-path ${CLASSIC_ROOT}/models/GFPGAN --codeformer-models-path ${CLASSIC_ROOT}/models/Codeformer --esrgan-models-path ${CLASSIC_ROOT}/models/ESRGAN --realesrgan-models-path ${CLASSIC_ROOT}/models/RealESRGAN --controlnet-dir ${CLASSIC_ROOT}/models/ControlNet"

case "${MODE}" in
    classic)
        start_forge_instance "${CLASSIC_ROOT}" "classic Forge" 7860 "${WORKSPACE_ROOT}/logs/webui.log"
        ;;
    ux)
        start_forge_instance "${UX_ROOT}" "UX Forge" 7862 "${WORKSPACE_ROOT}/logs/webui-ux.log" ${COMMON_MODEL_ARGS} --output-path "${UX_ROOT}/outputs"
        ;;
    both)
        start_forge_instance "${CLASSIC_ROOT}" "classic Forge" 7860 "${WORKSPACE_ROOT}/logs/webui.log"
        start_forge_instance "${UX_ROOT}" "UX Forge" 7862 "${WORKSPACE_ROOT}/logs/webui-ux.log" ${COMMON_MODEL_ARGS} --output-path "${UX_ROOT}/outputs"
        ;;
    *)
        echo "Unsupported FORGE_MODE=${MODE}; use classic, ux, or both" >&2
        exit 1
        ;;
esac
