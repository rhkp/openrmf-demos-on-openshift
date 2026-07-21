# Extend the RMF Web API server image with Zenoh middleware support.
# The upstream image only ships rmw_fastrtps_cpp and rmw_cyclonedds_cpp.
FROM ghcr.io/open-rmf/rmf-web/api-server:jazzy-nightly

USER root

RUN apt-get update && \
    apt-get install -y --no-install-recommends ros-jazzy-rmw-zenoh-cpp && \
    rm -rf /var/lib/apt/lists/*

USER 1001
