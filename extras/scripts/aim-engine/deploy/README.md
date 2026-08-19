# Deploying AIM

`aim_deploy.sh` deploys AIM into a Kubernetes cluster that already exists, one
level at a time. The levels form a ladder: a higher level assumes less is
already installed and does more, and each level preflights its own preconditions
before acting. We select a level with `--level`, and the script dispatches to
the building-block scripts described below rather than duplicating their logic.

```bash
./aim_deploy.sh --level 1         # base-image serve, no operator
./aim_deploy.sh --level 4         # install prerequisites + AIM Engine, then serve
```

Each level has a dedicated usage guide that walks through running it and then
actually using the served model:

- [Level 1: base-image serve](level-1.md), no operator.
- [Level 2: operator serve](level-2.md), on a cluster that already has AIM Engine.
- [Level 3: install the operator, then serve](level-3.md).
- [Level 4: install prerequisites and the operator, then serve](level-4.md).

## Which level do I want

The levels map to how much of the platform is already in place, which usually
follows who set up the cluster:

| Situation | Level |
| --- | --- |
| We just want to prove a cluster's GPU serves a model, with nothing installed | 1 |
| The platform team already installed AIM Engine and its prerequisites; we only submit workloads | 2 |
| The prerequisites are managed for us, but installing the operator is our job | 3 |
| We own a fresh cluster and install everything ourselves | 4 |

Level 2 is the common case on a managed cluster, including the laptop-with-a-
kubeconfig case where an administrator has already deployed the reference stack.
Level 4 is the turnkey case for a cluster we control. Level 3 is the increment
between them, for when the prerequisites are curated separately from the
operator. Level 1 is a different flow entirely: a plain Deployment with no
operator, useful for a first-contact check on any GPU cluster.

## Supplying a kubeconfig

When we run from a laptop or any machine that is not already pointed at the
cluster, we pass the downloaded kubeconfig with `--kubeconfig`, which exports
`KUBECONFIG` for the run and is inherited by the setup scripts `aim_deploy.sh`
dispatches to:

```bash
./aim_deploy.sh --level 4 --kubeconfig ~/Downloads/kubeconfig.yaml
```

Any `kubectl` commands we run ourselves afterward need the same kubeconfig, so
it is simplest to export it once in the shell: `export
KUBECONFIG=~/Downloads/kubeconfig.yaml`. All four scripts accept `--kubeconfig`
and show it under `--help`.

## Forwarded options and tokens

Options that a level's underlying script understands are exposed directly on
`aim_deploy.sh` and forwarded for us. On level 1 we pass `--keep` and
`--verbose` through to `aim_base_check.sh`; on levels 3 and 4 we pass
`--replace`, `--aim-version`, `--crds-chart`, and `--chart` through to
`aim_engine_setup.sh`. For example, we reinstall the operator cleanly while
deploying with `./aim_deploy.sh --level 3 --replace 1`.

The default models are ungated, so no Hugging Face token is needed: level 1
serves a small open model (Qwen2.5-1.5B-Instruct) through the base image, and
levels 2 to 4 serve an ungated model-specific image. A token is required only if
we deliberately point a level at a gated model such as Llama or Gemma, by
exporting `HF_TOKEN` before running.

## Building-block scripts

`aim_deploy.sh` is a thin wrapper; the real work lives in three scripts we can
also run directly.

`aim_engine_setup.sh` installs AIM Engine. It preflights the eight prerequisites
and, when they are all present, Helm-installs the CRDs and operator; if any
prerequisite is missing it exits 42 and lists the gaps. We run it from a login
or management node and assume a reachable cluster, cluster-admin credentials in
the kubeconfig, and `kubectl` and `helm` on `PATH`. No local GPU is needed, since
the served pods consume the cluster's GPU nodes, which are expected to already
run the AMD GPU Operator. Level 3 calls it directly, and level 4 calls it with
`--install-prereqs 1`.

```bash
./aim_engine_setup.sh                        # preflight, then install if prerequisites pass
./aim_engine_setup.sh --install-prereqs 1    # install the non-GPU add-ons first, then AIM Engine
./aim_engine_setup.sh --replace 1            # reinstall over an existing release
```

`aim_prereqs_setup.sh` installs the seven cluster add-ons AIM depends on:
cert-manager, Gateway API, kgateway, KServe, KEDA, keda-otel-add-on, and the
OpenTelemetry Operator. It assumes the same client access as above plus
permission to create cluster-scoped resources. The AMD GPU Operator is assumed
already present and is not installed here. On a shared cluster these add-ons are
normally managed by administrators, so we run this mainly on self-managed or
test clusters. Chart versions are overridable through environment variables.

```bash
./aim_prereqs_setup.sh
```

`aim_base_check.sh` runs an AIM container as a plain Deployment plus Service
instead of an `AIMService`, requests one GPU, and confirms the model answers a
single request. By default it is ungated and needs no token: it runs the generic
base image with a small open model (Qwen2.5-1.5B-Instruct), which the base image
serves through a general profile selected from in-pod GPU detection. It uses no
operator, no CRDs, and no accelerator labels, so its only assumptions are a
reachable cluster and a node advertising `amd.com/gpu`. It cleans up its own
resources on exit unless we pass `--keep 1`. This check matches the operator
only on the runtime (image, GPU detection, weight download, engine start): it
does not exercise the operator's label-driven profile resolution, so we treat a
green result as necessary but not sufficient. See [level 1](level-1.md) for the
full walkthrough.

## Verifying a level

Each level prints how to confirm it worked once it finishes, so we do not have
to guess whether the deployment went through. We look for two things: the model
answers a request, and the GPU is actually in use. Level 1 makes both checks
automatically and prints a "level 1 verified" line. Levels 2 to 4 print the
exact commands to watch the `AIMService` and `InferenceService` report Ready,
run an inference through the predictor, and confirm GPU use in the serving pod.
The per-level guides above give the concrete commands.

One rule applies to every level: vLLM registers the model under its real id (the
image or Hugging Face repo name), not the `AIMService` name, so we always read
the id from `/v1/models` rather than hardcoding it in an inference request.

## Known limits

- The operator resolves a serving profile by matching node labels the AMD GPU
  Operator's AcceleratorDetector stamps: the accelerator-model label
  (`aim-accelerator.<MODEL>`) and the unpartitioned sentinel
  (`aim-accelerator.partitioning-scheme.default`), which the v1alpha2 resolver
  AND-s together. Resolution still succeeds only if the model image ships a
  profile for that GPU. AIM serving profiles target discrete Instinct GPUs
  (MI300X, MI325X, MI350X, MI355X), so an MI300A APU has no matching profile and
  serving there is not expected to work.
- The models used here (for example Qwen2.5-1.5B-Instruct and Qwen3-32B) are
  ungated convenience picks chosen so the scripts run without a token. They
  exercise the serving path only; they are not tuned or representative for
  benchmarking, so we should not read performance or hardware conclusions from
  them.
- The operator ranks each model's published serving profiles by tier and, by
  default, requires at least an optimized (pre-tuned) one. Whether an optimized
  profile exists is a property of that model's AIM catalog entry, not of the
  GPU, so the resolver can report `ProfileNotFound` on a community model even
  though the hardware is capable and candidates matched the node. We therefore
  set `spec.profile.selector.minimumType: any` on the `AIMService` we apply,
  which still prefers optimized profiles but allows a generic one. To require
  tuned profiles only, raise this floor back to `optimized`.
- The operator's default caching provisions a per-profile PVC with a
  ReadWriteMany (RWX) access mode so replicas share one copy of the weights, and
  routing needs a Gateway or load balancer. A single-node ReadWriteOnce
  provisioner such as local-path cannot satisfy the RWX claim even when it is the
  default StorageClass, so the cache PVC stays Pending and the service hangs in
  Starting. The operator path therefore needs an RWX-capable StorageClass (for
  example NFS, CephFS, or Longhorn) and a load balancer, which a full platform
  installer supplies and which we assume the existing cluster already provides.
  The [test harness](../test/README.md) stands in for this with an in-cluster
  NFS provisioner.
- KServe is installed in Standard mode (`RawDeployment`, native Kubernetes
  Deployments) rather than the Knative-backed Serverless default, since the
  prerequisites ship Gateway API and kgateway instead of Knative. Override with
  `KSERVE_DEPLOYMENT_MODE` if needed.
- An auto-generated profile can omit a memory request, in which case KServe
  applies its `2Gi` default and the predictor is OOM-killed (exit 137) as it
  starts loading weights. We therefore set an explicit `spec.resources` floor on
  the `AIMService`, sized for the default 32B image and overridable via
  `AIM_CPU_REQUEST`, `AIM_MEM_REQUEST`, `AIM_CPU_LIMIT`, and `AIM_MEM_LIMIT`.
  AIM Engine replaces the requests and limits maps wholesale rather than
  deep-merging, so `spec.resources` must restate every key it needs, including
  `amd.com/gpu`. We set that to `AIM_ACCELERATOR_COUNT`: omitting it drops the
  GPU limit, the pod gets no isolated device, and on a bare-passthrough node the
  container then sees every host GPU, which breaks in-container `rocminfo`.
- The AIM Engine service controller does not always re-queue an `AIMService`
  when its `AIMProfileCache` reaches Ready, so the service can sit in `Starting`
  with a stale `ProfileCacheNotReady` message even though the cache is done.
  Because this reproduces on clean runs, `aim_deploy.sh` starts a one-shot
  background watcher that forces a single reconcile once the cache is Ready, so
  we do not have to nudge by hand. Disable it with `AIM_AUTO_NUDGE=0`. This is an
  operator bug we also track upstream rather than treating the workaround as
  permanent.

For an overview of both directories and the test-first workflow, see the
[top-level README](../README.md).
