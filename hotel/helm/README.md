# Hotel Helm chart

> **Coming soon** — copy templates from `office/helm/` when the hotel demo is implemented.

```bash
cp hotel/helm/values.yaml.example hotel/helm/values.yaml
# edit values.yaml, then:
helm upgrade --install rmf-hotel-demo hotel/helm -f hotel/helm/values.yaml -n rmf-demos --create-namespace
```
