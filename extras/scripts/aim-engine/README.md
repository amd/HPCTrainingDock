# AIM Engine deployment

These scripts install and test AMD's AIM (AMD Inference Microservices) Engine, a
Kubernetes (k8s) operator that serves models on AMD GPUs. Unlike the
module-based scripts in this repository, we deploy a cluster-scoped operator
(Custom Resource Definitions plus a Helm chart) through `kubectl` and `helm`;
there is no Lmod module. We drive everything through a single incremental
entrypoint, `aim_deploy.sh`, which layers on top of three building-block scripts
and a `kind`-based test harness.

## Incremental deployment

`aim_deploy.sh` deploys AIM into a cluster that already exists, one level at a
time. The levels form a ladder: a higher level assumes less is installed and
does more, and each level preflights its own preconditions before acting. We
select a level with `--level`, and the script dispatches to the building-block
scripts below rather than duplicating their logic. The levels are:

- Level 1, base-image serve: we deploy the model as a plain Deployment with no
  operator, assuming only a reachable cluster and a node advertising
  `amd.com/gpu`. This is the least we can do and the quickest way to prove the
  hardware serves a model.
- Level 2, operator serve: we apply an `AIMService`, assuming the AIM Engine
  operator and the seven prerequisites are already installed.
- Level 3, operator install: we install AIM Engine and then serve, assuming the
  seven prerequisites are already installed.
- Level 4, prerequisites install: we install the seven add-ons and AIM Engine
  and then serve, assuming only that the cluster's GPU nodes run the AMD GPU
  Operator.

```bash
export HF_TOKEN=hf_...            # for gated models (Llama, Gemma)
./aim_deploy.sh --level 1         # base-image serve, no operator
./aim_deploy.sh --level 4         # install prereqs + AIM Engine, then serve
```

Creating the cluster itself ("from zero") is deliberately out of scope here: for
a throwaway cluster we use `aim_engine_test.sh`, and for a real bare-metal
install we defer to AMD's Cluster Bloom and Cluster Forge (see Relationship to
the reference stack).

## Building-block scripts

`aim_engine_setup.sh` installs AIM Engine. It preflights the eight prerequisites
and, when they are all present, Helm-installs the CRDs and operator; if any
prerequisite is missing it exits 42 and lists the gaps. We run it from a login
or management node and assume a reachable cluster, cluster-admin credentials in
the kubeconfig, and `kubectl`/`helm` on `PATH`. No local GPU is needed, since the
served pods consume the cluster's GPU nodes, which are expected to already run
the AMD GPU Operator. Level 3 calls it directly, and level 4 calls it with
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

`aim_base_check.sh` runs the same runtime container the operator would serve, but
as a plain Deployment plus Service instead of an `AIMService`, requests one GPU,
and confirms the model answers a single request. By default it deploys the
model-specific image (the operator's by-image predictor runs that same image),
and the image self-selects its tuned profile from in-pod GPU detection. It uses
no operator, no CRDs, and no accelerator labels, so its only assumptions are a
reachable cluster and a node advertising `amd.com/gpu` (from the AMD GPU device
plugin or Operator); a gated model needs `HF_TOKEN` in the environment. It cleans
up its own resources on exit unless we pass `--keep 1`. Passing a bare `aim-base`
image together with `--model-id` serves an arbitrary Hugging Face model through
the generic runtime.

This check matches the operator only on the runtime (image, GPU detection, weight
download, engine start): it does not exercise the operator's profile resolution,
which keys off the node labels described under Known limits. We therefore treat a
green result as necessary but not sufficient, since the label-driven resolution
is validated only by the full operator flow.

```bash
./aim_base_check.sh                                             # serve the default image, assert, clean up
./aim_base_check.sh --image amdenterpriseai/aim-base:0.11 \
                    --model-id Qwen/Qwen2.5-1.5B-Instruct       # generic runtime, arbitrary model
```

## Testing on a throwaway cluster

`aim_engine_test.sh` stands up a throwaway `kind` (Kubernetes IN Docker) cluster
with real AMD GPU passthrough so we can exercise the whole flow, including
inference. It assumes a GPU host with `docker` and the `/dev/kfd` and `/dev/dri`
devices; `kind`, `kubectl`, and `helm` are downloaded as user-local binaries when
absent. This harness owns only the "from zero" foundation that `aim_deploy.sh`
does not: it creates the cluster, deploys the ROCm device plugin so a node
advertises `amd.com/gpu`, and injects the accelerator labels a real GPU Operator
would set. It does not install the prerequisites or the operator itself; those
remain the job of the levels, which we run on top of it. When `HF_TOKEN` is set
it wires that token in for gated models.

```bash
export HF_TOKEN=hf_...                    # for gated models
./aim_engine_test.sh                      # bring up kind + GPU, then drop into a sandbox shell
./aim_engine_test.sh --auto-run 1         # run install, idempotency, and an inference check, then clean up
./aim_engine_test.sh --base-image-only 1  # skip the operator; run only the base-image serve check
```

The default (`--auto-run 0`) leaves us in a shell inside the kind node, with the
scripts at `/aim-engine`, `kubectl`/`helm` on `PATH`, and `KUBECONFIG` already
pointing at the cluster. From there we run any level, since the cluster is the
foundation the levels build on:

```bash
./aim_deploy.sh --level 4
kubectl get aimservice,inferenceservice,pods -n default
```

We exit the sandbox to tear down the cluster and remove the work dir. The overlap
between this harness and the levels is confined to that foundation: the harness
substitutes a bare device plugin and injected labels for the AMD GPU Operator
(which `kind` cannot easily host), while the prerequisite and operator installs
that levels 3 and 4 perform are not done by the harness.

## Relationship to the reference stack

AMD's on-premises reference stack installs an entire platform from bare metal
through Cluster Bloom and Cluster Forge: it creates an RKE2 cluster, installs
host ROCm, provisions Longhorn storage and MetalLB, and adds the AMD GPU
Operator, the AI Workbench, the Resource Manager, identity, and GitOps, with AIM
Engine as one component among many. Our scripts capture only two layers of that:
the cluster add-ons (`aim_prereqs_setup.sh`) and the AIM Engine operator
(`aim_engine_setup.sh`), installed into a cluster that already exists. This suits
a shared cluster we do not own, such as a mixed Slurm and Kubernetes system,
where standing up a fresh RKE2 cluster and the full platform is neither possible
nor wanted. For a real from-zero bare-metal install we use the reference stack
rather than reproducing it here.

## Known limits

- The kind node uses the bare ROCm device plugin, so the harness injects the
  labels a real AcceleratorDetector would: the accelerator-model label
  (`aim-accelerator.<MODEL>`) and the unpartitioned sentinel
  (`aim-accelerator.partitioning-scheme.default`), which the v1alpha2 resolver
  AND-s together when matching a profile to a node. Profile resolution still
  succeeds only if the model image ships a profile for that GPU. AIM serving
  profiles target discrete Instinct GPUs (MI300X, MI325X, MI350X, MI355X), so an
  MI300A APU has no matching profile and serving there is not expected to work.
- Gated models such as Llama and Gemma need a Hugging Face token in `HF_TOKEN`,
  from an account granted access to the model. Ungated models avoid this, but
  the small ones are limited.
- The operator's default caching provisions a PVC per profile and routing needs
  a Gateway or load balancer. On a bare cluster without a default StorageClass or
  load balancer, the cache PVC stays Pending and the service hangs in Starting;
  the reference stack supplies these through Longhorn and MetalLB, whereas we
  assume the existing cluster already provides them.
- KServe is installed with defaults. For serving on a real cluster we apply AMD's
  Standard-mode `kserve-values.yaml` (see the AIM KServe configuration docs).
