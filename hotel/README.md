# Hotel Demo

> **Coming soon** — placeholder for the hotel world (`hotel.launch.xml`).

## To add this demo

1. Create `hotel/scripts/dispatch-task.sh` with hotel-specific tasks.
2. Add to `common/Dockerfile`:
   ```dockerfile
   COPY hotel/scripts/ /opt/rmf/demos/hotel/scripts/
   ```
3. Create `hotel/helm/` templates (copy from `office/helm/templates/`)
4. Create `hotel/deploy-openshift.sh` (copy from `office/`)
5. Rebuild and push: `VALUES_FILE=hotel/helm/values.yaml ./common/build-and-push.sh`
