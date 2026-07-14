# Hotel Helm Chart

Deploys the OpenRMF hotel world on OpenShift. See [../README.md](../README.md) for launch and task instructions.

```bash
cp values.yaml.example values.yaml
helm dependency update .
helm upgrade --install rmf-hotel-demo . -f values.yaml -n <namespace> --wait
```
