# AIM Engine deployment

These scripts install and test AMD's AIM (AMD Inference Microservices) Engine, a
Kubernetes (k8s) operator that serves models on AMD GPUs. Unlike the
module-based scripts in this repository, we deploy a cluster-scoped operator
(Custom Resource Definitions plus a Helm chart) through `kubectl` and `helm`;
there is no Lmod module. Three scripts cover the install, its prerequisites, and
end-to-end testing.

## What each script does

`aim_engine_setup.sh` is the entrypoint we run to install AIM Engine. It
preflights the eight prerequisites and, when they are all present, Helm-installs
the AIM Engine CRDs and operator; if any prerequisite is missing it exits 42 and
lists the gaps. We run it from a login or management node and assume a reachable
cluster, cluster-admin credentials in the kubeconfig, and `kubectl`/`helm` on
`PATH`. No local GPU is needed, since the served pods consume the cluster's GPU
nodes, which are expected to already run the AMD GPU Operator.

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
test clusters; `aim_engine_setup.sh --install-prereqs 1` invokes it for us.
Chart versions are overridable through environment variables.

```bash
./aim_prereqs_setup.sh
```

`aim_engine_test.sh` stands up a throwaway `kind` (Kubernetes IN Docker) cluster
with real AMD GPU passthrough so we can exercise the whole flow, including
inference. It assumes a GPU host with `docker` and the `/dev/kfd` and `/dev/dri`
devices; `kind`, `kubectl`, and `helm` are downloaded as user-local binaries
when absent. It labels the node with the detected GPU model so profile
resolution matches (a real cluster gets that label from the GPU Operator), and
when `HF_TOKEN` is set it wires that token in for gated models.

```bash
export HF_TOKEN=hf_...              # for gated models (Llama, Gemma)
./aim_engine_test.sh                # bring up kind + GPU, then drop into a sandbox shell
./aim_engine_test.sh --auto-run 1   # run install, idempotency, and an inference check, then clean up
```

## End-to-end test in the sandbox

The default (`--auto-run 0`) leaves us in a shell inside the kind node, with the
scripts at `/aim-engine`, `kubectl`/`helm` on `PATH`, and `KUBECONFIG` already
pointing at the cluster. From there we install AIM Engine and confirm the
operator is running:

```bash
./aim_engine_setup.sh --install-prereqs 1
kubectl get pods -n aim-system
```

We then deploy a model and query it, choosing a tag that fits the GPU:

```bash
kubectl apply -f - <<'EOF'
apiVersion: aim.eai.amd.com/v1alpha2
kind: AIMService
metadata:
  name: aim-smoke
  namespace: default
  annotations:
    aim.eai.amd.com/reconciler-pipeline: profile
spec:
  model:
    image: amdenterpriseai/aim-meta-llama-llama-3-2-1b-instruct:0.11.1
EOF

kubectl describe aimservice aim-smoke -n default
isvc=$(kubectl get inferenceservice -n default -l aim.eai.amd.com/service.name=aim-smoke -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward -n default "svc/${isvc}-predictor" 8080:80 &
curl -sS http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"aim-smoke","messages":[{"role":"user","content":"Hello!"}]}'
```

We exit the sandbox to tear down the cluster and remove the work dir;
`--auto-run 1` performs this whole sequence unattended and asserts on the
returned completion.

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
- KServe is installed with defaults. For serving on a real cluster we apply
  AMD's Standard-mode `kserve-values.yaml` (see the AIM KServe configuration
  docs).
