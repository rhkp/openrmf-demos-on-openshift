# Shared OpenRMF demos image — ROS 2 Jazzy + rmf_demos workspace + Zenoh middleware
# Built from the certified ROS 2 Jazzy base image.
FROM docker.io/osrf/ros:jazzy-desktop

ENV DEBIAN_FRONTEND=noninteractive

# Runtime paths (avoid /root — OpenShift runs as arbitrary non-root UID)
ENV RMF_WS=/opt/rmf/rmf_demos_ws
ENV ROS_LOG_DIR=/opt/rmf/.ros/log
ENV HOME=/opt/rmf

# 1. Install ALL apt packages upfront (before any pip installs to avoid conflicts)
RUN apt-get update && apt-get install -y \
    python3-pip \
    git \
    python3-colcon-common-extensions \
    ros-dev-tools \
    ros-jazzy-rmf-dev \
    ros-jazzy-rmw-zenoh-cpp \
    ros-jazzy-navigation2 \
    ros-jazzy-nav2-bringup \
    ros-jazzy-slam-toolbox \
    ros-jazzy-robot-localization \
    ros-jazzy-pointcloud-to-laserscan \
    ros-jazzy-laser-filters \
    ros-jazzy-rviz2 \
    xvfb \
    x11vnc \
    x11-utils \
    openbox \
    && rm -rf /var/lib/apt/lists/*

# 2. Install Python packages AFTER all apt packages to avoid dpkg conflicts
RUN pip3 install --break-system-packages --ignore-installed \
    "fastapi>=0.79.0" "uvicorn>=0.18.2" pydantic flask-socketio \
    datamodel_code_generator websockets

# 3. Initialize and clone the Open-RMF Demos Workspace
WORKDIR ${RMF_WS}
RUN mkdir -p src && cd src && \
    git clone https://github.com/open-rmf/rmf_demos.git -b jazzy && \
    git clone https://github.com/robo-friends/m-explore-ros2.git -b main

# 4. Resolve workspace package dependencies via rosdep
RUN apt-get update && \
    rosdep update && \
    rosdep install --from-paths src --ignore-src --rosdistro jazzy -y && \
    rm -rf /var/lib/apt/lists/*

# 4b. Fix RViz Map display shader for Mesa software rendering (noVNC uses llvmpipe).
#     Mesa's GLSL linker rejects sampler1D + sampler2D on the same program.
#     Replace the palette-based shader with one that hardcodes map colors directly,
#     eliminating the palette texture and the sampler type conflict entirely.
RUN MATERIALS=/opt/ros/jazzy/share/rviz_rendering/ogre_media/materials && \
    printf '%s\n' \
      '#version 120' \
      'varying vec2 UV;' \
      'uniform sampler2D eight_bit_image;' \
      'uniform float alpha;' \
      'void main()' \
      '{' \
      '  float val = texture2D(eight_bit_image, UV).x;' \
      '  float is_unknown = step(0.99, val);' \
      '  float is_free = step(val, 0.004);' \
      '  float is_occ = (1.0 - is_unknown) * (1.0 - is_free);' \
      '  float occ_shade = 1.0 - clamp(val * 255.0 / 100.0, 0.0, 1.0);' \
      '  vec3 color = is_free * vec3(0.94, 0.94, 0.94)' \
      '             + is_unknown * vec3(0.6, 0.6, 0.6)' \
      '             + is_occ * vec3(occ_shade);' \
      '  gl_FragColor = vec4(color, alpha);' \
      '}' \
      > "${MATERIALS}/glsl120/indexed_8bit_image.frag" && \
    sed -i '/param_named palette/d' \
      "${MATERIALS}/scripts/indexed_8bit_image.material" && \
    sed -i '/test_20x20/d' \
      "${MATERIALS}/scripts/indexed_8bit_image.material"

# 5. Compile the demo layout workspace with symlink support
#    Explicit bash — Podman OCI format ignores Dockerfile SHELL directive
RUN /bin/bash -c "source /opt/ros/jazzy/setup.bash && colcon build --symlink-install"

# 5b. Inject gz::sim::systems::Sensors plugin into office world
#     (required for gpu_lidar sensor data generation)
COPY common/scripts/inject_sensors_plugin.py /tmp/inject_sensors_plugin.py
RUN python3 /tmp/inject_sensors_plugin.py \
    "${RMF_WS}/install/rmf_demos_maps/share/rmf_demos_maps/maps/office/office.world" && \
    python3 /tmp/inject_sensors_plugin.py \
    "${RMF_WS}/install/rmf_demos_maps/share/rmf_demos_maps/maps/airport_terminal/airport_terminal.world"

# 5c-ii. Extract gz-sim world element names for ros_gz_bridge topic construction
RUN mkdir -p /opt/rmf/config && \
    for world_file in office/office airport_terminal/airport_terminal; do \
      demo=$(dirname "$world_file"); \
      python3 -c "import re; \
        m=re.search(r'<world name=\"([^\"]+)\"', \
        open('${RMF_WS}/install/rmf_demos_maps/share/rmf_demos_maps/maps/${world_file}.world').read()); \
        print(m.group(1))" > "/opt/rmf/config/${demo}_gz_world_name.txt"; \
    done

# 5c. Create Open-RMF/ symlink directory so Fuel-style model URIs
#     (model://Open-RMF/TinyRobot) resolve from GZ_SIM_RESOURCE_PATH
RUN MODELS_DIR="${RMF_WS}/install/rmf_demos_assets/share/rmf_demos_assets/models" && \
    mkdir -p "${MODELS_DIR}/Open-RMF" && \
    for m in "${MODELS_DIR}"/*/; do \
      name=$(basename "$m"); \
      [ "$name" = "Open-RMF" ] && continue; \
      ln -sf "../${name}" "${MODELS_DIR}/Open-RMF/${name}"; \
    done

# 6. Override stock TinyRobot model with lidar-equipped version (+ colored variant for Robot2)
COPY common/models/TinyRobot/ ${RMF_WS}/install/rmf_demos_assets/share/rmf_demos_assets/models/TinyRobot/
COPY common/models/TinyRobot2/ ${RMF_WS}/install/rmf_demos_assets/share/rmf_demos_assets/models/TinyRobot2/
RUN MODELS_DIR="${RMF_WS}/install/rmf_demos_assets/share/rmf_demos_assets/models" && \
    ln -sf "../TinyRobot2" "${MODELS_DIR}/Open-RMF/TinyRobot2"

# 6b. Copy shared helper scripts, launch files, config files, and custom worlds
COPY common/scripts/ /opt/rmf/scripts/
COPY common/launch/ /opt/rmf/demos/common/launch/
COPY common/config/ /opt/rmf/config/
COPY common/models/ /opt/rmf/models/
COPY common/worlds/ /opt/rmf/worlds/

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