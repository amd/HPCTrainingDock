# AIM Engine deployment

These scripts install and test AMD's AIM (AMD Inference Microservices) Engine, a
Kubernetes (k8s) operator that serves models on AMD GPUs. Unlike the
module-based scripts in this repository, we deploy a cluster-scoped operator
(Custom Resource Definitions plus a Helm chart) through `kubectl` and `helm`;
there is no Lmod module. These scripts install AIM Engine into a Kubernetes
cluster that already exists; they do not provision the cluster itself.
Provisioning a cluster from bare metal, together with storage, networking,
identity, and a web console, is instead the job of the AMD Enterprise AI
reference stack (see References), of which AIM Engine is one component. We drive
everything through a single incremental entrypoint, `aim_deploy.sh`, which layers
on top of three building-block scripts and a `kind`-based test harness.

AMD's stack distinguishes two things that our scripts both cover (see
References). An AIM (AMD Inference Microservice) is the inference container that
serves one model and self-selects optimized runtime parameters for the hardware;
AIM Engine is the Kubernetes operator that deploys and manages those containers
at scale. We run an AIM container directly at level 1 (through `aim_base_check.sh`),
and we install and drive AIM Engine at levels 2 to 4.

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

The default models are ungated, so no Hugging Face token is needed: level 1
serves a small open model (Qwen2.5-1.5B-Instruct) through the base image, and
levels 2 to 4 serve an ungated model-specific image. A token is required only if
we deliberately point a level at a gated model such as Llama or Gemma.

```bash
./aim_deploy.sh --level 1         # base-image serve, no operator
./aim_deploy.sh --level 4         # install prereqs + AIM Engine, then serve
```

Options that a level's underlying script understands are exposed directly on
`aim_deploy.sh` and forwarded for us. On level 1 we pass `--keep` and `--verbose`
through to `aim_base_check.sh`, and on levels 3 and 4 we pass `--replace`,
`--aim-version`, `--crds-chart`, and `--chart` through to `aim_engine_setup.sh`.
For example, we reinstall the operator cleanly while deploying with
`./aim_deploy.sh --level 3 --replace 1`.

Creating the cluster itself ("from zero") is deliberately out of scope here: for
a throwaway cluster we use `aim_engine_test.sh`, and for a real bare-metal
install we defer to the AMD Enterprise AI reference stack (see References).

## Verifying a level succeeded

Each level prints how to confirm it worked once it finishes, so we do not have to
guess whether the deployment went through. We look for two things: the model
answers a request, and the GPU is actually in use.

For level 1 the check is automatic: the base-image path serves a small
completion and then runs `rocm-smi` inside the pod to show the model is resident
on the GPU, printing a "level 1 verified" line on success. To probe it by hand we
re-run with `--keep 1` so the Deployment stays up, then port-forward its Service
and curl `/v1/models`.

For levels 2 to 4 the script prints the exact commands to run against the
operator-managed service: we watch the `AIMService` and `InferenceService` report
Ready, port-forward the predictor Service and curl `/v1/chat/completions` for a
small inference, and exec `rocm-smi` in the serving pod to confirm GPU use. The
same assertions run automatically in `aim_engine_test.sh --auto-run 1`.

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

`aim_base_check.sh` runs an AIM container as a plain Deployment plus Service
instead of an `AIMService`, requests one GPU, and confirms the model answers a
single request. By default it is ungated and needs no token: it runs the generic
base image with a small open model (Qwen2.5-1.5B-Instruct), which the base image
serves through a general profile selected from in-pod GPU detection. It uses no
operator, no CRDs, and no accelerator labels, so its only assumptions are a
reachable cluster and a node advertising `amd.com/gpu` (from the AMD GPU device
plugin or Operator). It cleans up its own resources on exit unless we pass
`--keep 1`. Pointing `--image` at a model-specific image (and dropping
`--model-id`) runs the exact container the operator's by-image predictor would
run, which we use when we want the check to match the operator container for
container.

This check matches the operator only on the runtime (image, GPU detection, weight
download, engine start): it does not exercise the operator's profile resolution,
which keys off the node labels described under Known limits. We therefore treat a
green result as necessary but not sufficient, since the label-driven resolution
is validated only by the full operator flow.

```bash
./aim_base_check.sh                                            # ungated default, assert, clean up
./aim_base_check.sh --image amdenterpriseai/aim-qwen-qwen3-32b:0.13.0 \
                    --model-id ""                              # match the operator's model-specific container
```

## Testing on a throwaway cluster

`aim_engine_test.sh` stands up a throwaway `kind` (Kubernetes IN Docker) cluster
with real AMD GPU passthrough so we can exercise the whole flow, including
inference. It assumes a GPU host with `docker` and the `/dev/kfd` and `/dev/dri`
devices; `kind`, `kubectl`, and `helm` are downloaded as user-local binaries when
absent. This harness owns only the "from zero" foundation that `aim_deploy.sh`
does not: it creates the cluster, deploys the ROCm device plugin so a node
advertises `amd.com/gpu`, injects the accelerator labels a real GPU Operator
would set, and installs an in-cluster NFS provisioner so the default StorageClass
offers the ReadWriteMany access mode the operator's profile cache needs (a real
system supplies this through its own shared storage). It does not install the
prerequisites or the operator itself; those
remain the job of the levels, which we run on top of it. Its default models are
ungated; when `HF_TOKEN` is set it wires that token in for the rare case of a
gated model.

```bash
./aim_engine_test.sh                      # bring up kind + GPU, then drop into a sandbox shell
./aim_engine_test.sh --auto-run 1         # run install, idempotency, and an inference check, then clean up
./aim_engine_test.sh --base-image-only 1  # skip the operator; run only the base-image serve check
./aim_engine_test.sh --container-only 1   # no Kubernetes at all; run the AIM container directly
```

The `kind`, `--base-image-only`, and `--auto-run` paths all need a container
runtime that can host a Kubernetes node. `kind` uses Docker by default and Podman
when we set the provider, but its rootless Podman path requires cgroup v2, so on a
cgroup v1 host without root it cannot create a cluster (this is a `kind` and
rootless-container limitation, not something the scripts can work around). For
that case, and for anyone without sudo, we provide `--container-only`: it skips
`kind`, `kubectl`, and `helm` and runs the AIM container directly through
docker/podman with GPU passthrough, serving a small ungated model and confirming
the GPU is in use. It validates the AIM microservice layer only, not the operator
or the Kubernetes scripts, but it needs no cluster, no cgroup v2, and no sudo.

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

## Known limits

- The kind node uses the bare ROCm device plugin, so the harness injects the
  labels a real AcceleratorDetector would: the accelerator-model label
  (`aim-accelerator.<MODEL>`) and the unpartitioned sentinel
  (`aim-accelerator.partitioning-scheme.default`), which the v1alpha2 resolver
  AND-s together when matching a profile to a node. Profile resolution still
  succeeds only if the model image ships a profile for that GPU. AIM serving
  profiles target discrete Instinct GPUs (MI300X, MI325X, MI350X, MI355X), so an
  MI300A APU has no matching profile and serving there is not expected to work.
- The defaults are ungated and need no token. If we deliberately pick a gated
  model such as Llama or Gemma, it needs a Hugging Face token in `HF_TOKEN` from
  an account granted access to that model.
- The models used here (for example Qwen2.5-1.5B-Instruct and Qwen3-32B) are
  ungated convenience picks chosen so the scripts run without a token. They
  exercise the serving path only; they are not tuned or representative for
  benchmarking, so we should not read performance or hardware conclusions from
  them. For performance work we use a model that ships an optimized AIM profile
  and follow AMD's tuning guidance.
- The operator ranks each model's published serving profiles by tier and, by
  default, requires at least an "optimized" (pre-tuned) one. Whether an optimized
  profile exists is a property of that model's entry in the AIM catalog, not of
  the GPU: AMD's featured models ship tuned profiles while an ungated community
  model often ships only a generic one. So the resolver can report
  `ProfileNotFound` on such a model even though the hardware is fully capable and
  candidates matched the node. We therefore set
  `spec.profile.selector.minimumType: any` on the AIMService we apply, which still
  prefers optimized profiles but allows a generic one so serving proceeds. To
  require tuned profiles only, raise this floor back to `optimized`.
- The operator's default caching provisions a per-profile PVC with a
  ReadWriteMany (RWX) access mode, so replicas can share one copy of the weights,
  and routing needs a Gateway or load balancer. A single-node ReadWriteOnce
  provisioner such as local-path or hostPath cannot satisfy the RWX claim even
  when it is the default StorageClass, so the cache PVC stays Pending and the
  service hangs in Starting. The operator path therefore needs an RWX-capable
  StorageClass (for example NFS, CephFS, or Longhorn) and a load balancer. A full
  platform installer such as the AMD Enterprise AI reference stack (see
  References) supplies these, for example through Longhorn and MetalLB, whereas we
  assume the existing cluster already provides them. The `aim_engine_test.sh`
  harness stands in for that shared storage by installing an in-cluster NFS
  provisioner as the RWX default StorageClass, so the same scripts bind the cache
  PVC unchanged on the throwaway cluster.
- KServe is installed with defaults. For serving on a real cluster we apply AMD's
  Standard-mode `kserve-values.yaml` (see the AIM KServe configuration docs).

## References

- [AMD Enterprise AI reference stacks overview](https://enterprise-ai.docs.amd.com/en/latest/reference-stacks.html)
- [AMD Enterprise AI reference stack, on-premises installation](https://enterprise-ai.docs.amd.com/en/latest/platform-infrastructure/on-premises-installation.html)
- [Cluster Bloom](https://github.com/silogen/cluster-bloom)
- [Cluster Forge](https://github.com/silogen/cluster-forge)
