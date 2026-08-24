# Level 2: operator serve

Level 2 serves a model through the AIM Engine operator by applying an
`AIMService`, installing nothing itself: it assumes the operator and its seven
prerequisites are present. This is the common case on a managed cluster,
including a laptop with a kubeconfig for a cluster an administrator already set
up. If the operator is absent it stops and points at [level 3](level-3.md) or
[level 4](level-4.md). This guide is the reference for the serve-and-verify flow
levels 3 and 4 reuse.

## Run

First point `KUBECONFIG` at the cluster's kubeconfig, substituting our own path
for the placeholder (skip if we are already pointed at the cluster), and confirm
it resolves to a real file:

```bash
export KUBECONFIG=/path/to/your/kubeconfig
echo "${KUBECONFIG}"; test -s "${KUBECONFIG}" && echo "kubeconfig found" || echo "set KUBECONFIG to a real file"
```

Then run the level, passing `--namespace` for a project we can write to on a
shared cluster (see [Choosing a namespace](README.md#choosing-a-namespace));
where `default` is writable we omit it:

```bash
./aim_deploy.sh --level 2 --namespace <your-namespace>
```

It applies an `AIMService` named `aim-smoke` (ungated model-specific image by
default) with a resource floor and a single-GPU selector, and starts a one-shot
watcher that clears a known reconcile stall. It then prints the steps below.

## Verify and run an inference

The first pull and weight download take many minutes. We check readiness, then
query the predictor, reading the model id from `/v1/models` (vLLM registers it
under the image or Hugging Face repo name, not the `AIMService` name):

```bash
NS=<your-namespace>   # the namespace we deployed into; use default if we omitted --namespace
kubectl get aimservice aim-smoke -n "$NS" \
  -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,REASON:.status.conditions[?(@.type=="Ready")].reason'
# while not Ready, this says why:
kubectl describe aimservice aim-smoke -n "$NS" | grep -iE 'reason:|message:' | tail -n2

kubectl wait --for=condition=Ready aimservice/aim-smoke -n "$NS" --timeout=1800s
isvc=$(kubectl get inferenceservice -n "$NS" -l aim.eai.amd.com/service.name=aim-smoke -o name | head -n1)
kubectl port-forward -n "$NS" svc/$(basename $isvc)-predictor 8080:80 >/tmp/pf.log 2>&1 &
sleep 3
model=$(curl -sS localhost:8080/v1/models | grep -o '"id":"[^"]*"' | head -n1 | cut -d'"' -f4)
curl -sS localhost:8080/v1/chat/completions -H 'Content-Type: application/json' \
  -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"What is ROCm?\"}],\"max_tokens\":200}"
```

## Drive it with an example app

Point the `icf_4agent` example (HPCTrainingExamples, `MLExamples/icf_4agent`) at
the predictor and reuse the served id; levels 3 and 4 reach the same endpoint:

```bash
export ICF_BASE_URL=http://localhost:8080/v1
export ICF_MODEL="$model"
export ICF_API_KEY=unused
cd /path/to/HPCTrainingExamples/MLExamples/icf_4agent && ./start_app.sh
```

## Confirm the GPU and clean up

```bash
pod=$(kubectl get pods -n "$NS" -l aim.eai.amd.com/service.name=aim-smoke -o name | head -n1)
kubectl exec -n "$NS" $pod -- rocm-smi
kubectl delete aimservice aim-smoke -n "$NS"
```

If it never reaches Ready, the usual cause is storage: the cache PVC needs a
ReadWriteMany StorageClass (see Known limits in [`deploy/README.md`](README.md)).
