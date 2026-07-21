# Zenoh router for OpenRMF — uses the rmw_zenoh bundled router (rmw_zenohd)
# to guarantee protocol version compatibility with rmw_zenoh_cpp clients.
FROM docker.io/ros:jazzy

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends ros-jazzy-rmw-zenoh-cpp && \
    rm -rf /var/lib/apt/lists/*

COPY router-config.json5 /etc/zenoh/router-config.json5

RUN mkdir -p /var/zenoh && \
    chgrp -R 0 /var/zenoh /etc/zenoh && \
    chmod -R g+rwX /var/zenoh /etc/zenoh

USER 1001
WORKDIR /var/zenoh

EXPOSE 7447

ENTRYPOINT ["/bin/bash", "-c"]
CMD ["source /opt/ros/jazzy/setup.bash && exec ros2 run rmw_zenoh_cpp rmw_zenohd -- --config /etc/zenoh/router-config.json5"]
