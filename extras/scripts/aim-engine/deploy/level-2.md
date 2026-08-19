# Level 2: operator serve

Level 2 serves a model through the AIM Engine operator by applying an
`AIMService`. It assumes the operator and its seven prerequisites are already
installed, so it installs nothing itself: it is the common case on a managed
cluster, including a laptop with a kubeconfig for a cluster where an
administrator has already deployed the reference stack. If the operator is
absent, the level stops with a message pointing at [level 3](level-3.md) or
[level 4](level-4.md). This guide is also the reference for the serve-and-verify
flow that levels 3 and 4 reuse after their install step.

## Run

```bash
export KUBECONFIG=~/Downloads/kubeconfig.yaml   # from a laptop; skip if already pointed at the cluster
./aim_deploy.sh --level 2
```

The script applies an `AIMService` named `aim-smoke` (an ungated model-specific
image by default) with an explicit resource floor and a single-GPU profile
selector, then starts a one-shot background watcher that clears a known operator
reconcile stall for us. It prints the verification steps below.

## Verify it is Ready

The first image pull and weight download can take many minutes. We check the
`AIMService` for a Ready status and a reason:

```bash
kubectl get aimservice aim-smoke -n default \
  -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,REASON:.status.conditions[?(@.type=="Ready")].reason'
```

While it is not Ready yet, one line tells us why:

```bash
kubectl describe aimservice aim-smoke -n default | grep -iE 'reason:|message:' | tail -n2
```

## Run an inference

We block until Ready, port-forward the predictor Service, and query it. vLLM
registers the model under its real id (the image or Hugging Face repo name), not
the `AIMService` name, so we read the id from `/v1/models` rather than
hardcoding it:

```bash
kubectl wait --for=condition=Ready aimservice/aim-smoke -n default --timeout=1800s
isvc=$(kubectl get inferenceservice -n default -l aim.eai.amd.com/service.name=aim-smoke -o name | head -n1)
kubectl port-forward -n default svc/$(basename $isvc)-predictor 8080:80 >/tmp/pf.log 2>&1 &
sleep 3

model=$(curl -sS localhost:8080/v1/models | grep -o '"id":"[^"]*"' | head -n1 | cut -d'"' -f4)
curl -sS localhost:8080/v1/chat/completions -H 'Content-Type: application/json' \
  -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"What is ROCm?\"}],\"max_tokens\":200}"
```

## Drive it with an example app

The predictor is a standard OpenAI-compatible endpoint, so any such client works
against it. To drive it with the `icf_4agent` multi-agent example in the
HPCTrainingExamples repository (`MLExamples/icf_4agent`), we point it at the
port-forwarded predictor and reuse the served id from above:

```bash
export ICF_BASE_URL=http://localhost:8080/v1
export ICF_MODEL="$model"
export ICF_API_KEY=unused
cd /path/to/HPCTrainingExamples/MLExamples/icf_4agent && ./start_app.sh
```

Levels 3 and 4 reach this same endpoint once serving starts, so the same wiring
applies there.

## Confirm the GPU is in use

```bash
pod=$(kubectl get pods -n default -l aim.eai.amd.com/service.name=aim-smoke -o name | head -n1)
kubectl exec -n default $pod -- rocm-smi
```

If the service never reaches Ready, the usual cause is storage: the operator's
cache PVC needs a ReadWriteMany StorageClass. See Known limits in
[`deploy/README.md`](README.md).

## Clean up

```bash
kubectl delete aimservice aim-smoke -n default
```
