# Airport Demo — SLAM Exploration

Autonomous SLAM mapping of the airport terminal from [rmf_demos](https://github.com/open-rmf/rmf_demos#airport-terminal-world) using **robot-as-pod** architecture. A single robot (tinyRobot_0) autonomously explores the entire terminal using frontier-based exploration, building a map from scratch with no pre-built nav graphs.

**Stack:** Podman build → Quay.io → Helm on OpenShift
**Navigation:** Nav2 (SmacPlanner2D) + SLAM Toolbox + explore_lite
**Visualization:** noVNC (Gazebo + RViz SLAM map in browser) + RMF Web dashboard

---

## Architecture

**Robot-as-pod:** The simulation world and each robot run in separate Kubernetes pods, connected via Zenoh.

| Pod | Containers | Role |
|---|---|---|
| `rmf-airport-demo` | simulation, fleet-monitor, task-dispatch, novnc | Gazebo world (no robots spawned), noVNC browser stream |
| `rmf-airport-demo-robot-tinyrobot-0` | fleet-adapter | Nav2 + SLAM Toolbox + explore_lite + RMF fleet adapter |
| `rmf-airport-demo-rmf-web` | rmf-api-server, rmf-dashboard | RMF Web API + dashboard UI |
| `rmf-airport-demo-zenoh-router` | zenoh-router | Central Zenoh message broker connecting all pods |

The robot pod runs the full autonomy stack:
1. **Nav2 TF publisher** — publishes odom→base_footprint from Gazebo ground truth
2. **SLAM Toolbox** — builds occupancy grid map from lidar scans
3. **Nav2 navigation stack** — path planning (SmacPlanner2D), path following (Regulated Pure Pursuit), recovery behaviors (spin, backup, wait)
4. **explore_lite** — detects frontiers (boundaries between known and unknown space), sends Nav2 goals to explore them
5. **RMF-Nav2 bridge** — translates between RMF fleet commands and Nav2
6. **Fleet adapter** — connects to the RMF system for fleet coordination

---

## Prerequisites

- OpenShift 4.x cluster and `oc` logged in
- `helm` and **Podman** on your build machine
- Quay.io account with push access (`podman login quay.io`)

---

## 1. Configure (once)

```bash
cp airport/helm/values.yaml.example airport/helm/values.yaml
```

Edit `airport/helm/values.yaml`:

| Key | Set to |
|---|---|
| `namespace.name` | Your OpenShift project |
| `image.fullRef` | `quay.io/<org>/openrmf-openshift-office-demo:nav2-sensors` |
| `novnc.image` | Same image ref (noVNC runs from the same image) |
| `robots.enabled` | `true` (enables robot-as-pod mode) |
| `novnc.enabled` | `true` (enables Gazebo + RViz visualization) |

`values.yaml` is gitignored.

---

## 2. Build and deploy

```bash
# Build image on your build machine
podman build -t quay.io/<org>/openrmf-openshift-office-demo:nav2-sensors -f common/Dockerfile .
podman push quay.io/<org>/openrmf-openshift-office-demo:nav2-sensors

# Deploy with Helm
helm dependency update airport/helm
helm upgrade --install rmf-airport-demo airport/helm \
  -f airport/helm/values.yaml \
  -n <namespace> --create-namespace --wait --timeout 25m
```

Re-deploy after config changes (no image rebuild needed):

```bash
helm upgrade rmf-airport-demo airport/helm -f airport/helm/values.yaml -n <namespace>
oc rollout restart deployment/rmf-airport-demo -n <namespace>
oc rollout restart deployment/rmf-airport-demo-robot-tinyrobot-0 -n <namespace>
```

### Check the pods

```bash
oc get pods -n <namespace>
```

**Pass:** sim pod `4/4 Running`, robot pod `1/1 Running`, rmf-web `2/2`, zenoh-router `1/1`.

---

## 3. View the demo

Routes are disabled by default. Use port-forward:

```bash
oc port-forward pod/<sim-pod-name> 8080:8080 -n <namespace>
```

Open `http://localhost:8080` in a browser for noVNC. You should see:
- **Gazebo:** Airport terminal world with the robot moving
- **RViz:** SLAM map being built in real-time as the robot explores

---

## 4. Monitor exploration

The robot starts exploring autonomously ~30 seconds after pod startup. No manual task dispatch needed.

```bash
# Watch frontier exploration goals
oc logs -f deployment/rmf-airport-demo-robot-tinyrobot-0 -n <namespace> -c fleet-adapter \
  | grep -E "Begin navigating|explore"

# Verify SmacPlanner2D is active
oc logs deployment/rmf-airport-demo-robot-tinyrobot-0 -n <namespace> -c fleet-adapter \
  | grep "SmacPlanner2D"

# Check for planning errors (should be none after startup)
oc logs deployment/rmf-airport-demo-robot-tinyrobot-0 -n <namespace> -c fleet-adapter \
  | grep -i "failed to create plan"
```

---

## Key Technical Decisions & Learnings

### 1. SmacPlanner2D over NavFn

NavFn has a [known bug (#4655)](https://github.com/ros-navigation/navigation2/issues/4655) where path extraction fails on growing SLAM maps with "Failed to create plan from potential when a legal potential was found." This happens because NavFn's potential array doesn't resize correctly when SLAM Toolbox expands the map. SmacPlanner2D uses a different algorithm (A* on a 2D grid) that handles dynamic map resizing correctly.

**Symptom:** Robot explores fine for 10-20 goals, then permanently stops as the blacklist fills with failed goals.
**Fix:** `plugin: "nav2_smac_planner::SmacPlanner2D"` in `nav2_params.yaml`.

### 2. Costmap inflation radius matters — a lot

Nav2 costmap inflation creates a potential field around obstacles. The `inflation_radius` determines how far this field extends:

- **Too small (0.35m):** Sharp cost cliffs at obstacle edges. The controller sees "free → lethal" with no gradient, can't find smooth paths through corridors, and frequently fails.
- **Correct global (1.75m):** Smooth potential field across the full corridor width. The robot naturally follows corridor centers. The `cost_scaling_factor` (3.0) controls how steeply cost drops with distance.
- **Correct local (0.55m):** Moderate inflation for local maneuvering. Larger than global would prevent the robot from navigating near any obstacle.

**Rule of thumb:** Global inflation_radius should be roughly half the corridor width. Local inflation_radius should be ~2.5x the robot radius.

### 3. explore_lite over custom frontier exploration

The [m-explore-ros2](https://github.com/robo-friends/m-explore-ros2) `explore_lite` package is a proven, maintained frontier exploration solution. Our custom `frontier_explorer.py` accumulated workarounds (blacklist expiry, backtracking, scored selection, odom tracking) that masked root causes instead of fixing them.

explore_lite provides:
- Proper frontier detection on OccupancyGrid
- `progress_timeout` to cancel stuck goals (set to 30s)
- `potential_scale` weighting for frontier selection (prefers closer frontiers)
- `min_frontier_size` filtering (0.75m avoids noise frontiers)
- Native Nav2 action client integration

### 4. Namespaced ROS 2 params require fully qualified node names

When a ROS 2 node runs in a namespace (e.g., `/tinyRobot_0/explore_node`), the `--params-file` YAML must use the fully qualified node name as the top-level key:

```yaml
# WRONG — params won't load for namespaced node:
explore_node:
  ros__parameters:
    costmap_topic: map

# CORRECT — matches /tinyRobot_0/explore_node:
/tinyRobot_0/explore_node:
  ros__parameters:
    costmap_topic: map
```

We use `ROBOT_PLACEHOLDER` in the YAML and `sed` to substitute the robot name at launch time.

### 5. Ground truth odometry: relative coordinates only

The Nav2 TF publisher converts Gazebo absolute poses to odometry-frame-relative coordinates with yaw rotation correction. Using absolute Gazebo coordinates directly breaks the odom→base_footprint TF chain because SLAM Toolbox expects odometry to be relative to the robot's spawn pose.

---

## Configuration reference

| Setting | Value |
|---|---|
| World | `airport_terminal` (Gazebo) |
| Robot | `tinyRobot_0` (lidar-equipped TinyRobot) |
| Planner | SmacPlanner2D (nav2_smac_planner) |
| Controller | Regulated Pure Pursuit (`allow_reversing: true`) |
| SLAM | SLAM Toolbox (sync mode) |
| Explorer | explore_lite (m-explore-ros2) |
| Global inflation | radius: 1.75m, cost_scaling_factor: 3.0 |
| Local inflation | radius: 0.55m, cost_scaling_factor: 3.0 |
| Explore progress timeout | 30s |
| Explore planner frequency | 0.25 Hz |
| Min frontier size | 0.75m |
| Helm release | `rmf-airport-demo` |

### Tear down

```bash
helm uninstall rmf-airport-demo -n <namespace>
```

---

## Troubleshooting

| Problem | Check |
|---|---|
| Robot not moving | `oc logs ... -c fleet-adapter \| grep explore` — is explore_lite running? |
| "Failed to create plan" errors | Verify SmacPlanner2D is active, not NavFn |
| Robot hugging walls / getting stuck | Check inflation_radius in nav2_params.yaml (global should be 1.75) |
| noVNC "Failed to connect" | Restart x11vnc: `oc exec ... -c simulation -- bash -c "x11vnc -display :99 -forever -nopw -rfbport 5900 -bg"` |
| Port-forward not serving | Kill stale port-forward process and restart |
| explore_lite "Waiting for costmap" | Params not loading — check YAML uses `/ROBOT_NAME/explore_node:` as top-level key |

---

## Notes

- Uses the **same Docker image** as the office demo (`openrmf-openshift-office-demo:nav2-sensors`), not a separate airport image.
- Airport terminal is a large map — first build takes 30+ minutes. Subsequent builds use layer caching.
- The robot explores autonomously. No patrol tasks need to be dispatched.
- SLAM map quality depends on lidar range (10m for TinyRobot) — narrow corridors map well, large open areas take longer.
