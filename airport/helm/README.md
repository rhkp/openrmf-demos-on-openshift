# Airport Helm Chart

Deploys the OpenRMF airport terminal world on OpenShift. See [../README.md](../README.md) for launch and task instructions.

```bash
cp values.yaml.example values.yaml
helm dependency update .
helm upgrade --install rmf-airport-demo . -f values.yaml -n <namespace> --wait
```
