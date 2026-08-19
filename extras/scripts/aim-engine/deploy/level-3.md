# Level 3: install the operator, then serve

Level 3 installs AIM Engine and then serves, assuming the seven prerequisites
(cert-manager, Gateway API, kgateway, KServe, KEDA, keda-otel-add-on, and the
OpenTelemetry Operator) are already present. It suits a cluster where the
prerequisites are curated separately, for example by a platform team through
GitOps, but installing the operator is left to us. It needs cluster-admin in the
kubeconfig, since it creates cluster-scoped Custom Resource Definitions.

## Run

```bash
export KUBECONFIG=~/Downloads/kubeconfig.yaml   # from a laptop; skip if already pointed at the cluster
./aim_deploy.sh --level 3
```

This calls `aim_engine_setup.sh`, which preflights the prerequisites and, when
they all pass, Helm-installs the AIM Engine CRDs and operator. If a prerequisite
is missing it stops and lists the gap; in that case install the add-ons (or use
[level 4](level-4.md), which installs them too). To reinstall the operator
cleanly over an existing release, add `--replace 1`:

```bash
./aim_deploy.sh --level 3 --replace 1
```

Once the operator is installed, the level applies the same `AIMService` and
prints the same verification steps as [level 2](level-2.md).

## Verify and use

The serve, verify, inference, and cleanup steps are identical to level 2. See
[level 2](level-2.md) for the commands to confirm the `AIMService` is Ready, run
an inference through the predictor, drive it with the example app, and check GPU
use.
