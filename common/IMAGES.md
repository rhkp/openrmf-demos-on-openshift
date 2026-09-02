# Image map

Every container image this repo builds, where its Dockerfile lives, what
builds/pushes it, and who actually consumes it. Nothing here is inferred —
each row was traced through the real (non-`.example`) `values.yaml` files
and the `bootc-vm/containers/*.container` Quadlet units.

There is no naming convention tying an image to its Dockerfile — that's
the whole reason this file exists. When in doubt, this table is the source
of truth, not folder proximity or image tags.

## App/workload images (consumed by both OpenShift Helm demos and bootc-vm)

| Dockerfile | Image | Build script | Consumers |
|---|---|---|---|
| `common/Dockerfile` | `quay.io/rhkp/openrmf-openshift-office-demo:nav2-sensors` (office, airport)<br>`quay.io/rhkp/openrmf-openshift-hotel-demo:certified` (hotel) | `common/build-and-push.sh` (per-demo, via `common/build-all-demos.sh`) | `office/helm/values.yaml`, `hotel/helm/values.yaml`, `airport/helm/values.yaml` (`image.fullRef`); `bootc-vm/containers/rmf-simulation.container`, `rmf-fleet-coordinator.container`, `rmf-fleet-monitor.container`, `rmf-task-dispatch.container`, `rmf-robot-tinyRobot{1,2,3,4}.container` |
| `common/novnc/Dockerfile` | `quay.io/rhkp/openrmf-openshift-office-demo:novnc` (office, airport)<br>`quay.io/rhkp/openrmf-openshift-hotel-demo:novnc` (hotel) | `common/build-and-push.sh` (builds this too, conditionally, if `novnc.enabled: true` in the `VALUES_FILE`) | `office/hotel/airport` `helm/values.yaml` (`novnc.image`); `bootc-vm/containers/rmf-novnc.container` |
| `common/zenoh-router/Dockerfile` | `quay.io/rhkp/openrmf-zenoh-router:latest` | `common/zenoh-router/build.sh` | `office/hotel/airport` `helm/values.yaml` (`zenohRouter.image`); `bootc-vm/containers/rmf-zenoh-router.container` |
| `common/rmf-web-zenoh/Dockerfile` | `quay.io/rhkp/openrmf-rmf-web-zenoh:latest` | `common/rmf-web-zenoh/build.sh` | `office/hotel/airport` `helm/values.yaml` (`rmfWeb.apiServer.image`) — OpenShift-only, no bootc-vm equivalent (rmf-web dashboard is out of scope there, see `bootc-vm/README.md` Status) |

`zenoh-router` and `rmf-web-zenoh` had **no build script at all** until
this file was added — they were built and pushed manually at some point,
with no repeatable way to redo it. `zenoh-router/build.sh` and
`rmf-web-zenoh/build.sh` fix that, matching `build-and-push.sh`'s own
`IMAGE=`/`SKIP_PUSH=` override conventions.

Note: `airport` has no dedicated app image of its own — its real
`values.yaml` points `image.fullRef` at the same office image/tag. Only
`office` and `hotel` are actually distinct workloads at the image level.

## Host OS image (a different kind of thing — not an app/workload image)

| Containerfile | Image | Build script | Consumer |
|---|---|---|---|
| `bootc-vm/Containerfile` | `quay.io/rhkp/openrmf-office-bootc-host:latest` | `bootc-vm/scripts/build-host-image.sh` (build+push); `bootc-vm/scripts/build-ami.sh` (turns it into a bootable AWS AMI) | Not referenced by any Helm `values.yaml` — this is the bootc **host** OS that the `bootc-vm/containers/*.container` Quadlet units boot into, one level below all the app images in the table above. See `bootc-vm/README.md` for why this is architecturally distinct from a Pod base image. |

## Experimental, not currently used anywhere

| Containerfile | Status |
|---|---|
| `bootc/Containerfile` | RoboStack-on-`centos-bootc` replacement for `common/Dockerfile`, office-only scope. Written and buildable, but never built+pushed or deployed — see `bootc/README.md` Status. Not referenced by any `values.yaml` or Quadlet unit. |
| `hummingbird/Containerfile` | RoboStack-on-Hummingbird replacement for `common/Dockerfile`, ported from `bootc/Containerfile`. Same story — see `hummingbird/README.md` Status. Not referenced anywhere either. |

Neither is dead code to delete — both are active spikes per their own
READMEs — but neither currently backs any running demo, unlike everything
in the tables above.
