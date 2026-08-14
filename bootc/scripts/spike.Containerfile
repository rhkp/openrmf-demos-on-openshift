# Throwaway spike image — NOT the real bootc/Containerfile.
# Purpose: settle the two biggest open risks before investing in the full build:
#   1. Does ros-jazzy-rmw-zenoh-cpp resolve on the robostack-jazzy conda channel?
#   2. Does the RoboStack-provided ROS2 env + Gazebo actually activate/run on a
#      CentOS-bootc base (no Ubuntu/apt anywhere)?
# Build on the build VM: podman build -f bootc/scripts/spike.Containerfile -t spike-bootc-robostack .
FROM quay.io/centos-bootc/centos-bootc:stream9

ENV MAMBA_ROOT_PREFIX=/opt/micromamba
ENV PATH=${MAMBA_ROOT_PREFIX}/envs/ros_env/bin:/usr/local/bin:${PATH}

RUN dnf -y install curl tar bzip2 which && dnf clean all

# Install micromamba (single static binary, no python bootstrap needed)
RUN curl -Ls https://micro.mamba.pm/api/micromamba/linux-64/latest | tar -xvj -C /usr/local/bin/ --strip-components=1 bin/micromamba

# Create the ROS2 Jazzy env from robostack-jazzy + conda-forge
RUN micromamba create -y -n ros_env -c robostack-jazzy -c conda-forge \
      ros-jazzy-desktop-full \
      ros-jazzy-ros-gz-sim \
      ros-jazzy-ros-gz-bridge \
      ros-jazzy-ros-gz-image \
      ros-jazzy-ros-gz-interfaces \
      ros-jazzy-navigation2 \
      ros-jazzy-nav2-bringup \
      ros-jazzy-slam-toolbox \
      ros-jazzy-rmw-zenoh-cpp \
      ros-jazzy-robot-localization \
      colcon-common-extensions \
      compilers \
    && micromamba clean -a -y

# NOTE: `SHELL ["micromamba", "run", ...]` is silently ignored by podman under
# OCI image format (only works with `docker` format) — so every RUN below
# sources RoboStack's setup.bash directly instead of relying on SHELL.
ENV ROS_ENV_SETUP=${MAMBA_ROOT_PREFIX}/envs/ros_env/setup.bash

# Verification checks — fail the build loudly if any of these don't work
RUN bash -c "source ${ROS_ENV_SETUP} && ros2 doctor --report | head -50"
RUN bash -c "source ${ROS_ENV_SETUP} && gz sim --version"
RUN bash -c "source ${ROS_ENV_SETUP} && python3 -c 'import rclpy; print(\"rclpy OK\")'"
RUN bash -c "source ${ROS_ENV_SETUP} && ros2 pkg list | grep -E '^(nav2_bringup|slam_toolbox|rmw_zenoh_cpp|ros_gz_sim)$'"

# --- Phase 2: does rmf_demos build from source against the conda-provided ROS2 env? ---
# rosdep normally targets a system package manager (apt/dnf); against a conda
# env there's no clean mapping, so skip it and let colcon/CMake surface exactly
# what's missing — more informative for a spike than fighting rosdep upfront.
# tinyxml-devel: menge_vendor needs the original TinyXML (not TinyXML2) via
# pkg-config; only available from EPEL (not base repos, not CRB this time).
RUN dnf -y install epel-release && \
    dnf -y install git gcc gcc-c++ cmake make patch libatomic boost-devel tinyxml-devel && \
    dnf clean all

# websocketpp (rmf_visualization_schedule): CMake looks for it via find_package
# in CONFIG mode — EPEL's websocketpp-devel is header-only with no CMake
# config, so it wouldn't satisfy that lookup even if installed. conda-forge
# packages it with proper CMake integration instead. Added as its own
# `micromamba install` (not folded into the original `micromamba create`
# above) so this doesn't invalidate that layer's cache and force a full env
# recreate — only this one extra package gets installed on top.
RUN micromamba install -y -n ros_env -c robostack-jazzy -c conda-forge websocketpp && \
    micromamba clean -a -y

# fiona (rmf_demos_maps / rmf_traffic_editor_test_maps): building_map_generator
# needs it for map/world/crowdsim/navgraph generation at build time.
# DELIBERATELY NOT INSTALLED — confirmed via `--freeze-installed` that fiona
# genuinely conflicts with numpy/GDAL versions already pinned by the rest of
# ros_env (not just a slow solve: the frozen solver fails fast and explicitly).
# Forcing it would mean letting the solver change already-working package
# versions elsewhere in this large environment, which risks breaking things
# that currently work, for stock demo maps our office demo doesn't even use —
# it renders the custom collision_test.world, not any of rmf_demos_maps's
# generated worlds. Both packages are excluded from workspace discovery via
# COLCON_IGNORE further down (right after the vcs import), not built —
# rmf_demos and rmf_demos_gz (which our launch files actually use) declare
# them as exec_depend, and colcon needs them fully absent from its package
# graph, not merely failed/skipped, or it still errors looking for their
# install-time environment hooks. See the COLCON_IGNORE comment for why.


# rclcpp optionally links LTTng-UST tracing hooks. The conda env already
# ships a compatible lttng-ust (2.13.9, incl. liblttng-ust-common.so.1) as an
# rclcpp dependency — EL9's system lttng-ust-devel is an older 2.12.0 that
# predates the liblttng-ust-common split, so installing it would link against
# the wrong ABI. The actual gap is just the unversioned dev symlinks conda's
# package omits — add those instead of pulling in the system package.
RUN ln -sf liblttng-ust.so.1.0.0 ${MAMBA_ROOT_PREFIX}/envs/ros_env/lib/liblttng-ust.so && \
    ln -sf liblttng-ust-common.so.1 ${MAMBA_ROOT_PREFIX}/envs/ros_env/lib/liblttng-ust-common.so

WORKDIR /tmp/rmf_ws
RUN mkdir -p src && cd src && \
    git clone --depth 1 https://github.com/open-rmf/rmf_demos.git -b jazzy

# rmf_demos depends on core Open-RMF packages (rmf_traffic, rmf_building_map_tools,
# rmf_fleet_adapter core lib, etc.) — on Ubuntu these come prebuilt via the
# ros-jazzy-rmf-dev apt metapackage; here there's no conda equivalent, so pull
# the same source repos Open-RMF's own build farm uses via their rmf.repos vcs manifest.
# vcstool needs pkg_resources, which newer setuptools no longer bundles by default
RUN bash -c "source ${ROS_ENV_SETUP} && pip install --no-cache-dir 'setuptools<81' vcstool"
# rmf.repos also vendors its own rmf_demos pinned at `main` — drop that entry
# so it doesn't collide with our explicit `-b jazzy` clone above.
COPY bootc/scripts/filter-rmf-repos.py /tmp/filter-rmf-repos.py
RUN curl -sL https://raw.githubusercontent.com/open-rmf/rmf/main/rmf.repos -o /tmp/rmf.repos.orig && \
    bash -c "source ${ROS_ENV_SETUP} && python3 /tmp/filter-rmf-repos.py /tmp/rmf.repos.orig /tmp/rmf.repos"
RUN cd src && \
    bash -c "source ${ROS_ENV_SETUP} && vcs import . < /tmp/rmf.repos"

# rmf_demos_maps / rmf_traffic_editor_test_maps both need fiona for build-time
# codegen we don't use (see the fiona note above). `--packages-skip` doesn't
# work here even though it sounds like it should: colcon's CMake build task
# sources the environment hook (package.sh) of every dependency declared in a
# package's package.xml — including exec_depend — for any package colcon
# still knows about, and a *skipped* package is still "known", just not
# built, so rmf_demos's build fails looking for an install dir that was never
# created (confirmed: `--packages-skip rmf_demos_maps rmf_traffic_editor_test_maps`
# turned "rmf_demos_maps/rmf_traffic_editor_test_maps fail" into "rmf_demos
# fails looking for rmf_demos_maps/share/rmf_demos_maps/package.sh instead).
# COLCON_IGNORE removes them from colcon's package discovery entirely, so
# they're treated like any other dependency living outside this workspace
# (silently not sourced) — the same way conda-provided packages already are.
RUN touch src/rmf_demos/rmf_demos_maps/COLCON_IGNORE \
    src/rmf/rmf_traffic_editor/rmf_traffic_editor_test_maps/COLCON_IGNORE

# rmf.repos's vendor packages (pybind11_json_vendor, menge_vendor,
# nlohmann_json_schema_validator_vendor) need ament_cmake_vendor_package, a
# generic ROS2 build-tool package that RoboStack's recipe doesn't package
# even though it packages the rest of ament_cmake. It lives in the
# ament/ament_cmake monorepo — only pull that one subdirectory, not the whole
# repo, since the rest of ament_cmake is already provided by conda and would
# otherwise create duplicate-package conflicts.
RUN cd src && \
    git clone --depth 1 -b jazzy https://github.com/ament/ament_cmake.git /tmp/ament_cmake_src && \
    mv /tmp/ament_cmake_src/ament_cmake_vendor_package . && \
    rm -rf /tmp/ament_cmake_src

# Genuine upstream bug in rmf_robot_sim_common, not an environment gap: it
# calls std::max/std::min with mismatched int/double arguments (bare unqualified
# abs() resolves to C's integer-only version, not the double-overloaded
# std::abs), which GCC 14 rejects under strict template argument deduction.
# Whatever built the upstream Ubuntu binaries apparently tolerated this; ours
# doesn't. No existing std::abs in this file, so a blanket qualify is safe.
RUN sed -i 's/\babs(/std::abs(/g' \
    src/rmf/rmf_simulation/rmf_robot_sim_common/src/utils.cpp

# GCC 11 (CentOS Stream 9's default) is stricter than whatever built the
# upstream Ubuntu binaries about requiring `#include <cassert>` before using
# assert() — hits rmf_traffic's vendored FCL (collision library) in multiple
# files (confirmed at least convex-inl.h and taylor_model-inl.h; likely more),
# a latent portability issue in that vendored code, not ours. Rather than
# whack-a-mole patching every affected file, force-include <cassert> into
# every translation unit via -include, fixing all instances at once.
#
# NOTE: --symlink-install is deliberately dropped — newer setuptools breaks
# `colcon build --symlink-install` for ament_python packages with
# "error: option --editable not recognized" (known colcon/setuptools
# incompatibility, unrelated to our stack). A shipped container image
# doesn't need dev-mode symlinks anyway, so a plain build is correct here.
#
# NOTE: no `| tail` here deliberately — piping colcon's output through tail
# made the RUN step's exit code come from `tail` (always 0) instead of
# `colcon build`, silently masking failed builds as successful Docker layers.
#
# The manual LIBRARY_PATH/LD_LIBRARY_PATH exports (tried previously) fixed
# the missing -llttng-ust link, but next surfaced a libstdc++ ABI mismatch:
# librclcpp.so (built by conda-forge with a newer GCC) needs GLIBCXX symbols
# newer than what the system GCC 11 toolchain links against by default, even
# with the conda lib dir on the search path. The robust fix — and RoboStack's
# own documented approach for building custom workspaces — is to use conda's
# own matched compiler toolchain (the `compilers` package added above)
# activated via `micromamba run`, which sets CC/CXX/library paths correctly
# via its own activation hooks instead of us hand-tuning them.
# CPATH: rmf_traffic_ros2 (and possibly others) use <Eigen/Geometry> without
# their own find_package(Eigen3) — rmf_traffic's CMake config doesn't forward
# that transitive include dir to consumers. Conda installs Eigen headers under
# include/eigen3/, not top-level include/, so add it globally rather than
# patch every downstream package with the same gap.
#
# PKG_CONFIG_PATH: same class of problem as LIBRARY_PATH/CPATH above — conda's
# own pkg-config binary has a hardcoded search path (its env's lib/pkgconfig
# + share/pkgconfig) that never includes system paths, and PKG_CONFIG_PATH is
# empty by default. menge_vendor needs tinyxml.pc, which dnf installed fine to
# /usr/lib64/pkgconfig — pkg-config just never looks there unless told to.
#
# The real root cause behind both of the above: conda-forge's `compilers`
# package ships its own isolated sysroot and does NOT search /usr/include or
# /usr/lib64 by default (deliberate, for hermetic conda builds) — unlike a
# normal system compiler. So pkg-config's own optimization of stripping
# "-I/usr/include" from its output (since it assumes that's always a default
# search path) actively breaks things here: tinyxml.pc's Cflags get stripped
# down to nothing usable, so <tinyxml.h> isn't found even though pkg-config
# itself resolves fine. Bridge /usr/include and /usr/lib64 globally, since any
# further dnf-installed system dep will hit this same wall.
# --continue-on-error: without it, colcon cancels whatever else happens to be
# mid-build (parallel, unrelated packages) the moment ANY package fails —
# useful as a safety net so one unexpected failure doesn't hide the full
# picture of everything else. rmf_demos_maps/rmf_traffic_editor_test_maps are
# already fully excluded from the workspace via COLCON_IGNORE above, so no
# --packages-skip is needed (or wanted — see the COLCON_IGNORE comment for
# why that flag alone doesn't actually work here).
RUN micromamba run -n ros_env bash -c "source ${ROS_ENV_SETUP} && \
    export CPATH=\"${MAMBA_ROOT_PREFIX}/envs/ros_env/include/eigen3:/usr/include:\${CPATH}\" && \
    export LIBRARY_PATH=\"/usr/lib64:\${LIBRARY_PATH}\" && \
    export PKG_CONFIG_PATH=\"/usr/lib64/pkgconfig:\${PKG_CONFIG_PATH}\" && \
    export CXXFLAGS=\"-include cassert -fpermissive \${CXXFLAGS}\" && \
    colcon build --continue-on-error --event-handlers console_direct+"

CMD ["bash", "-c", "source ${ROS_ENV_SETUP} && exec bash"]
