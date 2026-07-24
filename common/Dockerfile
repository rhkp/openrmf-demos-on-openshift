# Shared OpenRMF demos image — ROS 2 Jazzy + rmf_demos workspace + Zenoh middleware
# Built from the certified ROS 2 Jazzy base image.
FROM docker.io/osrf/ros:jazzy-desktop

ENV DEBIAN_FRONTEND=noninteractive

# Runtime paths (avoid /root — OpenShift runs as arbitrary non-root UID)
ENV RMF_WS=/opt/rmf/rmf_demos_ws
ENV ROS_LOG_DIR=/opt/rmf/.ros/log
ENV HOME=/opt/rmf

# 1. Install core system packages & pre-compiled RMF C++ development files
RUN apt-get update && apt-get install -y \
    python3-pip \
    git \
    python3-colcon-common-extensions \
    ros-dev-tools \
    ros-jazzy-rmf-dev \
    ros-jazzy-rmw-zenoh-cpp \
    xvfb \
    x11vnc \
    x11-utils \
    && rm -rf /var/lib/apt/lists/*

# 2. Install Python packages with our critical system-level websockets override
# This prevents the silent fleet manager uvicorn crash
RUN pip3 install --break-system-packages --ignore-installed \
    "fastapi>=0.79.0" "uvicorn>=0.18.2" pydantic flask-socketio \
    datamodel_code_generator websockets

# 3. Initialize and clone the Open-RMF Demos Workspace
WORKDIR ${RMF_WS}
RUN mkdir -p src && cd src && \
    git clone https://github.com/open-rmf/rmf_demos.git -b jazzy

# 4. Resolve workspace package dependencies via rosdep
RUN apt-get update && \
    rosdep update && \
    rosdep install --from-paths src --ignore-src --rosdistro jazzy -y && \
    rm -rf /var/lib/apt/lists/*

# 5. Compile the demo layout workspace with symlink support
#    Explicit bash — Podman OCI format ignores Dockerfile SHELL directive
RUN /bin/bash -c "source /opt/ros/jazzy/setup.bash && colcon build --symlink-install"

# 5b. Create Open-RMF/ symlink directory so Fuel-style model URIs
#     (model://Open-RMF/TinyRobot) resolve from GZ_SIM_RESOURCE_PATH
RUN MODELS_DIR="${RMF_WS}/install/rmf_demos_assets/share/rmf_demos_assets/models" && \
    mkdir -p "${MODELS_DIR}/Open-RMF" && \
    for m in "${MODELS_DIR}"/*/; do \
      name=$(basename "$m"); \
      [ "$name" = "Open-RMF" ] && continue; \
      ln -sf "../${name}" "${MODELS_DIR}/Open-RMF/${name}"; \
    done

# 6. Copy shared helper scripts and launch files for robot-as-pod architecture
COPY common/scripts/ /opt/rmf/scripts/
COPY common/launch/ /opt/rmf/demos/common/launch/

# 7. Copy per-demo scripts (add a COPY line when introducing a new demo)
COPY office/scripts/ /opt/rmf/demos/office/scripts/
COPY hotel/scripts/ /opt/rmf/demos/hotel/scripts/
COPY airport/scripts/ /opt/rmf/demos/airport/scripts/

RUN find /opt/rmf/scripts /opt/rmf/demos -name '*.sh' -exec chmod +x {} + && \
    chmod +x /opt/rmf/scripts/wait-for-world.sh

# 8. OpenShift UID/GID pattern:
#    - USER 1001 for local non-root runs
#    - group 0 + g+rwX so an assigned arbitrary UID can still write logs
RUN mkdir -p /opt/rmf/.ros/log && \
    chown -R 1001:0 /opt/rmf && \
    chmod -R g+rwX /opt/rmf

USER 1001

WORKDIR /opt/rmf

CMD ["tail", "-f", "/dev/null"]
