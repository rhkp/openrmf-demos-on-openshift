# Lightweight noVNC + websockify sidecar for OpenShift (arbitrary non-root UID)
FROM python:3.12-alpine

RUN apk add --no-cache git \
    && pip install --no-cache-dir websockify \
    && git clone --depth 1 https://github.com/novnc/noVNC.git /opt/novnc \
    && chgrp -R 0 /opt/novnc \
    && chmod -R g+rwX /opt/novnc

USER 1001
WORKDIR /opt/novnc

EXPOSE 8080

ENTRYPOINT ["websockify"]
CMD ["--web", "/opt/novnc", "8080", "127.0.0.1:5900"]
