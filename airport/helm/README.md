# Airport Helm chart

> **Coming soon** — copy templates from `office/helm/` when the airport demo is implemented.

```bash
cp airport/helm/values.yaml.example airport/helm/values.yaml
# edit values.yaml, then:
helm upgrade --install rmf-airport-demo airport/helm -f airport/helm/values.yaml -n rmf-demos --create-namespace
```
