# Deploying AIM

`aim_deploy.sh` deploys AIM into an existing cluster, one level at a time. The
levels form a ladder: a higher level assumes less is installed and does more,
and each preflights its preconditions before acting. We pick a level with
`--level`; the script dispatches to the building-block scripts below.

```bash
./aim_deploy.sh --level 1         # base-image serve, no operator
./aim_deploy.sh --level 4         # install prerequisites + AIM Engine, then serve
```

Each level has a usage guide covering how to run it and use the served model:

- [Level 1: base-image serve](level-1.md), no operator.
- [Level 2: operator serve](level-2.md), on a cluster that already has AIM Engine.
- [Level 3: install the operator, then serve](level-3.md).
- [Level 4: install prerequisites and the operator, then serve](level-4.md).

## Which level do I want

| Situation | Level |
| --- | --- |
| Prove a cluster's GPU serves a model, with nothing installed | 1 |
| AIM Engine and its prerequisites are already installed; we only submit workloads | 2 |
| The prerequisites are managed for us, but installing the operator is our job | 3 |
| We own a fresh cluster and install everything ourselves | 4 |

Level 2 is the common case on a managed cluster, including a laptop with a
kubeconfig for a cluster an administrator already set up; level 4 is turnkey for
a cluster we own; level 3 is the increment between them; level 1 is a separate
no-operator flow for a first-contact GPU check.

## Supplying a kubeconfig

From a machine not already pointed at the cluster, pass `--kubeconfig`, which
exports `KUBECONFIG` for the run and is inherited by the setup scripts:

```bash
./aim_deploy.sh --level 4 --kubeconfig ~/Downloads/kubeconfig.yaml
```

Our own later `kubectl` commands need it too, so it is simplest to `export
KUBECONFIG=~/Downloads/kubeconfig.yaml` once. All four scripts accept
`--kubeconfig` and show it under `--help`.

A kubeconfig that authenticates through an OIDC provider (common on managed
clusters) runs an exec credential plugin such as `kubectl oidc-login`, which
needs the kubelogin plugin installed on `PATH` as `kubectl-oidc_login`. The
first `kubectl` call then performs a browser login: on a headless host we open
the URL it prints manually, or add `--grant-type=authcode-keyboard` to the
kubeconfig's exec args to paste the returned code back instead. Without the
plugin, `kubectl` cannot obtain a token and the scripts report that the cluster
is unreachable.

## Forwarded options and tokens

`aim_deploy.sh` forwards a level's flags to its underlying script: `--keep` and
`--verbose` to `aim_base_check.sh` on level 1; `--replace`, `--aim-version`,
`--crds-chart`, and `--chart` to `aim_engine_setup.sh` on levels 3 and 4 (for
example `./aim_deploy.sh --level 3 --replace 1`). The default models are ungated,
so no token is needed; a gated model such as Llama or Gemma needs `HF_TOKEN`
exported.

## Building-block scripts

`aim_deploy.sh` is a thin wrapper over three scripts we can also run directly:

- `aim_engine_setup.sh`: preflights the eight prerequisites and, if they pass,
  Helm-installs the AIM Engine CRDs and operator, else exits 42 listing the gaps.
  Needs a reachable cluster, cluster-admin, and `kubectl` and `helm`; no local
  GPU. Level 3 calls it, level 4 with `--install-prereqs 1`.
- `aim_prereqs_setup.sh`: installs the seven add-ons AIM depends on
  (cert-manager, Gateway API, kgateway, KServe, KEDA, keda-otel-add-on, and the
  OpenTelemetry Operator). The AMD GPU Operator is assumed present. On shared
  clusters these are usually admin-managed, so we run this mainly on self-managed
  or test clusters.
- `aim_base_check.sh`: runs an AIM as a plain Deployment plus Service (not an
  `AIMService`), requests one GPU, and confirms a single request. Ungated by
  default, cleans up unless `--keep 1`. It matches the operator only on the
  runtime, not its label-driven profile resolution, so a pass is necessary but
  not sufficient. See [level 1](level-1.md).

## Verifying a level

Each level prints how to confirm it worked: the model answers a request and the
GPU is in use. Level 1 checks both automatically; levels 2 to 4 print commands
to watch the `AIMService` and `InferenceService` reach Ready, run an inference,
and check GPU use. One rule holds everywhere: vLLM registers the model under its
real id (the image or Hugging Face repo name), not the `AIMService` name, so we
read the id from `/v1/models` rather than hardcoding it.

## Known limits

- Profile resolution matches node labels the GPU Operator stamps
  (`aim-accelerator.<MODEL>` and `aim-accelerator.partitioning-scheme.default`,
  AND-ed by the v1alpha2 resolver) and succeeds only if the image ships a profile
  for that GPU. Profiles target discrete Instinct GPUs (MI300X, MI325X, MI350X,
  MI355X), so an MI300A APU has none and is not expected to serve.
- The default models (for example Qwen2.5-1.5B-Instruct and Qwen3-32B) are
  ungated convenience picks: they exercise the serving path only and are not
  representative for benchmarking.
- The operator requires at least an optimized (pre-tuned) profile by default,
  which is a property of the model's catalog entry, not the GPU, so a community
  model can report `ProfileNotFound` even on capable hardware. We set
  `spec.profile.selector.minimumType: any` to allow a generic profile; raise it
  back to `optimized` to require tuned ones.
- The operator's cache PVC is ReadWriteMany so replicas share one copy of the
  weights, and routing needs a Gateway or load balancer. A ReadWriteOnce default
  (such as local-path) leaves the PVC Pending and the service in Starting, so the
  operator path needs an RWX StorageClass (NFS, CephFS, or Longhorn) and a load
  balancer, which we assume the cluster provides. The
  [test harness](../test/README.md) supplies both with an in-cluster NFS
  provisioner.
- KServe runs in Standard mode (`RawDeployment`), not the Knative-backed
  Serverless default, since the prerequisites ship Gateway API and kgateway.
  Override with `KSERVE_DEPLOYMENT_MODE`.
- A generated profile can omit a memory request, so KServe applies its `2Gi`
  default and the predictor is OOM-killed as it loads weights. We set an explicit
  `spec.resources` floor (overridable via `AIM_CPU_REQUEST`, `AIM_MEM_REQUEST`,
  `AIM_CPU_LIMIT`, and `AIM_MEM_LIMIT`). AIM Engine replaces the resource maps
  wholesale rather than deep-merging, so `spec.resources` must restate every key
  including `amd.com/gpu` (set to `AIM_ACCELERATOR_COUNT`); omitting it drops the
  GPU limit, the pod gets no isolated device, and in-container `rocminfo` then
  sees every host GPU and fails.
- The service controller does not always re-queue an `AIMService` when its
  `AIMProfileCache` reaches Ready, so it can sit in `Starting` with a stale
  message. `aim_deploy.sh` runs a one-shot watcher that forces one reconcile once
  the cache is Ready (disable with `AIM_AUTO_NUDGE=0`). This is an operator bug we
  track upstream.

For an overview of both directories, see the [top-level README](../README.md).
