FROM madiator2011/better-forge:light

# Pre-install the anapnoe UX extension into the baked Forge directory.
# On first pod start, pre_start.sh rsyncs /stable-diffusion-webui-forge/
# into /workspace/ – the extension is carried along automatically.
RUN git clone --depth=1 \
    https://github.com/anapnoe/sd-webui-ux.git \
    /stable-diffusion-webui-forge/extensions/anapnoe-sd-webui-ux

# Replace pre_start.sh with our clean single-instance version.
COPY pre_start.sh /pre_start.sh
RUN chmod +x /pre_start.sh

# Keep the original ENTRYPOINT (/opt/nvidia/nvidia_entrypoint.sh)
# and CMD (/start.sh) from the base image – nginx, SSH, code-server
# are all wired up there already, including the 7861→7860 nginx proxy.
