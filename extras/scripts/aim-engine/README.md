# AIM Engine deployment

Install and test AMD's AIM (AMD Inference Microservices) Engine, a Kubernetes
(k8s) operator that serves models on AMD GPUs. Unlike the module-based scripts,
this deploys a cluster-scoped operator (Custom Resource Definitions + Helm
chart) via `kubectl`/`helm`; there is no Lmod module.

## Scripts

- `aim_engine_setup.sh`: entrypoint. Preflights the 8 prerequisites, then Helm-
  installs the AIM Engine CRDs + operator. Errors (exit 42) listing gaps if any
  prerequisite is missing. `--install-prereqs 1` runs the prereqs script first;
  `--replace 1` reinstalls over an existing release.
- `aim_prereqs_setup.sh`: installs 7 cluster add-ons (cert-manager, Gateway
  API, kgateway, KServe, KEDA, keda-otel-add-on, OpenTelemetry Operator). The
  AMD GPU Operator is assumed already present. Versions are env-overridable.
- `aim_engine_test.sh`: throwaway `kind` (Kubernetes IN Docker) cluster with
  real AMD GPU passthrough for end-to-end testing. Requires a GPU host.

## Real system

Run from a login/management node with `kubectl`/`helm` and a cluster-admin
kubeconfig (no local GPU needed, since GPUs are used by the served pods):

```bash
./aim_engine_setup.sh            # preflight; installs if prerequisites pass
```

If preflight lists gaps, install them (or coordinate with cluster admins), then
re-run. `--install-prereqs 1` self-installs the non-GPU add-ons.

## Test on a GPU host (kind)

The harness brings up the cluster with GPU passthrough, labels the node with the
detected GPU model so AIM profile resolution matches (a real cluster gets this
from the AMD GPU Operator; the bare device plugin here does not), and, if
`HF_TOKEN` is set, wires it in for gated models. Pass `--gpu-model` to override
detection, and set `AIM_TEST_MODEL_IMAGE` to pick the model.

```bash
export HF_TOKEN=hf_...            # needed for gated models (Llama, Gemma)
./aim_engine_test.sh             # brings up kind+GPU, drops you into a sandbox shell
```

Inside the sandbox (`/aim-engine`, with `kubectl`/`helm` on PATH):

```bash
./aim_engine_setup.sh --install-prereqs 1     # prereqs + AIM Engine
kubectl get pods -n aim-system                # operator Running
```

Deploy a small model and query it (pick a tag that fits the GPU):

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

kubectl describe aimservice aim-smoke -n default          # watch Conditions
isvc=$(kubectl get inferenceservice -n default -l aim.eai.amd.com/service.name=aim-smoke -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward -n default "svc/${isvc}-predictor" 8080:80 &
curl -sS http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"aim-smoke","messages":[{"role":"user","content":"Hello!"}]}'
```

`exit` the sandbox to tear down the cluster and remove the work dir.
`--auto-run 1` runs the whole flow (incl. an inference assertion) unattended.

## Known limits

- The `kind` node uses the bare ROCm device plugin, so the harness injects the
  accelerator-model label itself. Profile resolution still only succeeds if the
  model image actually ships a profile for that GPU. AIM serving profiles target
  discrete Instinct GPUs (MI300X, MI325X, MI350X, MI355X); an MI300A APU has no
  matching profile, so serving there is not expected to work.
- Gated models (Llama, Gemma) require a Hugging Face token via `HF_TOKEN`, with
  the account granted access to that model on Hugging Face. Ungated models avoid
  this but the small ones are limited.
- KServe is installed with defaults; for serving on a real cluster apply AMD's
  Standard-mode `kserve-values.yaml` (see the AIM KServe configuration docs).
