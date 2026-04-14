FROM madiator2011/better-forge:light

COPY nginx-dual-forge.conf /etc/nginx/conf.d/dual-forge.conf
COPY pre_start.sh /pre_start.sh
RUN chmod +x /pre_start.sh
