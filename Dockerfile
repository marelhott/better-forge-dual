FROM madiator2011/better-forge:light

ENV CODE_PORT=7777
ENV FORGE_PORT=7862
ENV UX_PORT=7861

COPY start.sh /start.sh
RUN chmod +x /start.sh

# Advertise the actual public ports this derived image expects in Runpod.
EXPOSE 22 7777 7861 7862

ENTRYPOINT ["/start.sh"]
