# AIM Engine deployment and testing

These scripts install, test, and serve models with AMD's AIM (AMD Inference
Microservices) Engine, a Kubernetes (k8s) operator that serves models on AMD
GPUs. Unlike the module-based scripts elsewhere in this repository, we deploy a
cluster-scoped operator (Custom Resource Definitions plus a Helm chart) through
`kubectl` and `helm`; there is no Lmod module. The scripts install AIM Engine
into a Kubernetes cluster that already exists; they do not provision the cluster
itself. Provisioning from bare metal, together with storage, networking,
identity, and a web console, is instead the job of the AMD Enterprise AI
reference stack (see References), of which AIM Engine is one component.

AMD's stack distinguishes two things these scripts both cover. An AIM (AMD
Inference Microservice) is the inference container that serves one model and
self-selects optimized runtime parameters for the hardware. AIM Engine is the
Kubernetes operator that deploys and manages those containers at scale. We run
an AIM container directly at level 1, and we install and drive AIM Engine at
levels 2 to 4.

## Layout

The directory is split into the deployment scripts we run against a real
cluster and a self-contained harness that rehearses them on a throwaway one:

- [`deploy/`](deploy/README.md): the deployment entrypoint `aim_deploy.sh`, its
  three building-block scripts, and a per-level usage guide. This is what we run
  against a real cluster, from a login node or from a laptop that has a
  kubeconfig for the cluster.
- [`test/`](test/README.md): `aim_engine_test.sh`, which stands up a disposable
  `kind` (Kubernetes IN Docker) cluster with real AMD GPU passthrough and runs
  the `deploy/` scripts on it end to end, then discards everything on exit.

## Test first

We recommend running the test harness before deploying to a cluster we care
about. The harness is intended to be the closest environment to a real deploy,
because it exercises the very same `deploy/` scripts we run in production: it
mounts them into the `kind` node and, in its interactive mode, hands us the same
`aim_deploy.sh --level N` commands we would run for real. What it adds is only
the foundation a real cluster already provides for us:

- the cluster itself, created with `kind` and real `/dev/kfd` and `/dev/dri`
  passthrough;
- a node that advertises `amd.com/gpu`, via the ROCm device plugin, plus the
  accelerator labels a production AMD GPU Operator would stamp, which the
  operator's profile resolution needs;
- a ReadWriteMany default StorageClass, via an in-cluster NFS provisioner,
  standing in for the shared storage a real system supplies.

Because those three are the only substitutions, a green run in the harness tells
us the scripts, the operator install, and GPU-backed inference all work before
we point anything at a shared cluster. The one caveat is scale and provenance:
the harness is a single `kind` node with a stand-in device plugin rather than a
multi-node cluster with the real GPU Operator, so it validates correctness of
the flow, not cluster capacity. See [`test/README.md`](test/README.md) for the
harness modes, including a Kubernetes-free path for hosts without Docker or
`cgroup` v2.

## Prerequisites

- To deploy: `kubectl` and `helm` on `PATH`, and access to a Kubernetes cluster
  whose GPU nodes run the AMD GPU Operator. Levels that install cluster-scoped
  components need cluster-admin in the kubeconfig. See
  [`deploy/README.md`](deploy/README.md).
- To test: a GPU host with `docker` and the `/dev/kfd` and `/dev/dri` devices.
  `kind`, `kubectl`, and `helm` are downloaded as user-local binaries when
  absent. See [`test/README.md`](test/README.md).

## References

- [AMD Enterprise AI reference stacks overview](https://enterprise-ai.docs.amd.com/en/latest/reference-stacks.html)
- [AMD Enterprise AI reference stack, on-premises installation](https://enterprise-ai.docs.amd.com/en/latest/platform-infrastructure/on-premises-installation.html)
- [Cluster Bloom](https://github.com/silogen/cluster-bloom)
- [Cluster Forge](https://github.com/silogen/cluster-forge)
