FROM madiator2011/better-forge:light

# nginx.conf in this base image is monolithic – it has no include for conf.d.
# We patch it: remove the closing } of the http block, inject our include, then close.
COPY nginx-dual-forge.conf /etc/nginx/conf.d/dual-forge.conf
RUN head -n -1 /etc/nginx/nginx.conf > /tmp/nginx_patched.conf \
    && echo '    include /etc/nginx/conf.d/*.conf;' >> /tmp/nginx_patched.conf \
    && echo '}' >> /tmp/nginx_patched.conf \
    && mv /tmp/nginx_patched.conf /etc/nginx/nginx.conf \
    && nginx -t

COPY pre_start.sh /pre_start.sh
RUN chmod +x /pre_start.sh

# Advertise the actual public ports this derived image expects in Runpod.
EXPOSE 22 7777 7861 7862
