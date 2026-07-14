# Airport Demo

> **Coming soon** — placeholder for the airport world (`airport.launch.xml`).

## To add this demo

1. Create `airport/scripts/dispatch-task.sh` with airport-specific tasks.
2. Add to `common/Dockerfile`:
   ```dockerfile
   COPY airport/scripts/ /opt/rmf/demos/airport/scripts/
   ```
3. Create `airport/helm/` templates (copy from `office/helm/templates/`)
4. Create `airport/deploy-openshift.sh` (copy from `office/`)
5. Rebuild and push: `VALUES_FILE=airport/helm/values.yaml ./common/build-and-push.sh`
