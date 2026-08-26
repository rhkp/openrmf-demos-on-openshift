# Lightweight noVNC + websockify sidecar for OpenShift (arbitrary non-root UID)
# Hummingbird-based: quay.io/hummingbird/python is the unsigned mirror of
# Red Hat's supported hardened tier (registry.access.redhat.com/hi/python),
# usable without a Red Hat entitlement. The -builder variant retains
# dnf/pip/git for this install step; see ../../hummingbird/README.md.
FROM quay.io/hummingbird/python:3.12-builder

# The base image sets USER 65532 (unprivileged) at the end of its own
# Containerfile — switch back to root so dnf/pip install system-wide
# instead of falling back to a per-user ~/.local install under /tmp.
USER 0

RUN dnf install -y git && dnf clean all \
    && pip install --no-cache-dir websockify \
    && git clone --depth 1 https://github.com/novnc/noVNC.git /opt/novnc \
    && chgrp -R 0 /opt/novnc \
    && chmod -R g+rwX /opt/novnc

USER 1001
WORKDIR /opt/novnc

EXPOSE 8080

ENTRYPOINT ["websockify"]
CMD ["--web", "/opt/novnc", "8080", "127.0.0.1:5900"]
