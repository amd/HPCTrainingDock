# Level 4: install prerequisites and the operator, then serve

Level 4 is the turnkey path for a cluster we control: it installs the seven
cluster add-ons AIM depends on, installs AIM Engine, and then serves, assuming
only that the cluster's GPU nodes run the AMD GPU Operator. It needs
cluster-admin in the kubeconfig, since it creates cluster-scoped resources for
both the prerequisites and the operator.

## Run

```bash
export KUBECONFIG=~/Downloads/kubeconfig.yaml   # from a laptop; skip if already pointed at the cluster
./aim_deploy.sh --level 4
```

This calls `aim_engine_setup.sh --install-prereqs 1`, which runs
`aim_prereqs_setup.sh` to install the add-ons (cert-manager, Gateway API,
kgateway, KServe, KEDA, keda-otel-add-on, and the OpenTelemetry Operator), then
Helm-installs the AIM Engine CRDs and operator. It then applies the same
`AIMService` and prints the same verification steps as [level 2](level-2.md).

To serve a specific model image instead of the ungated default, pass
`--model-image`; a gated image additionally needs `HF_TOKEN` exported:

```bash
./aim_deploy.sh --level 4 --model-image amdenterpriseai/aim-qwen-qwen3-32b:0.13.0
```

## Verify and use

The serve, verify, inference, and cleanup steps are identical to level 2. See
[level 2](level-2.md) for the commands to confirm the `AIMService` is Ready, run
an inference through the predictor, drive it with the example app, and check GPU
use.

## Rehearse first

Level 4 is the flow the [test harness](../test/README.md) runs end to end on a
throwaway `kind` cluster. Running it there first is the closest rehearsal of a
real level-4 deploy, since it exercises these same scripts and only substitutes
the cluster, the GPU advertisement and labels, and the shared storage.
