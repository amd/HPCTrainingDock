# Testing AIM on a throwaway cluster

`aim_engine_test.sh` stands up a disposable `kind` (Kubernetes IN Docker)
cluster with real AMD GPU passthrough so we can exercise the whole deployment
flow, including inference, before touching a cluster we care about. It runs the
scripts in the sibling [`deploy/`](../deploy/README.md) directory: it mounts them
into the `kind` node at `/aim-engine` and, in auto-run mode, calls
`aim_engine_setup.sh` directly. Everything lives in a working directory that is
removed on exit, so nothing is left behind.

It assumes a GPU host with `docker` and the `/dev/kfd` and `/dev/dri` devices;
`kind`, `kubectl`, and `helm` are downloaded as user-local binaries when absent.

## What the harness provides

The harness owns only the foundation a real cluster would already have, and
leaves the prerequisite and operator installs to the `deploy/` scripts we run on
top. It creates the cluster, deploys the ROCm device plugin so a node advertises
`amd.com/gpu`, injects the accelerator labels a real AMD GPU Operator would set,
and installs an in-cluster NFS provisioner so the default StorageClass offers the
ReadWriteMany access mode the operator's profile cache needs. This is why a run
here is the closest rehearsal of a real deploy: the scripts and the operator and
inference paths are identical, and only the cluster, the GPU advertisement and
labels, and the shared storage are substituted.

## Modes

```bash
./aim_engine_test.sh                      # bring up kind + GPU, then drop into a sandbox shell
./aim_engine_test.sh --auto-run 1         # run install, idempotency, and an inference check, then clean up
./aim_engine_test.sh --base-image-only 1  # skip the operator; run only the base-image serve check
./aim_engine_test.sh --container-only 1   # no Kubernetes at all; run the AIM container directly
```

The default (`--auto-run 0`) leaves us in a shell inside the `kind` node, with
the `deploy/` scripts at `/aim-engine`, `kubectl` and `helm` on `PATH`, and
`KUBECONFIG` already pointing at the cluster. From there we run any level exactly
as we would in production, since the cluster is the foundation the levels build
on:

```bash
./aim_deploy.sh --level 4
kubectl get aimservice,inferenceservice,pods -n default
```

We exit the sandbox to tear down the cluster and remove the work directory.

## Hosts without Docker or cgroup v2

The `kind`, `--base-image-only`, and `--auto-run` paths all need a container
runtime that can host a Kubernetes node. `kind` uses Docker by default and
Podman when we set the provider, but its rootless Podman path requires
`cgroup` v2, so on a `cgroup` v1 host without root it cannot create a cluster.
This is a `kind` and rootless-container limitation, not something the scripts
can work around.

For that case, and for anyone without sudo, we provide `--container-only`: it
skips `kind`, `kubectl`, and `helm` and runs the AIM container directly through
docker or podman with GPU passthrough, serving a small ungated model and
confirming the GPU is in use. It validates the AIM microservice layer only, not
the operator or the Kubernetes scripts, but it needs no cluster, no `cgroup` v2,
and no sudo. Its default (`--auto-run 0`) leaves the model serving and drops us
into a shell inside the container itself, a throwaway sandbox where nothing we do
touches the host, so we can send our own requests to `http://localhost:8000` and
remove the container by exiting. `--container-only 1 --auto-run 1` instead runs
the checks and cleans up.

For deploying to a real cluster once a run here is green, see
[`deploy/README.md`](../deploy/README.md); for an overview of both directories,
see the [top-level README](../README.md).
