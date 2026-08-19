# Level 1: base-image serve

Level 1 is the quickest way to prove a cluster's GPU serves a model. It deploys
the generic AIM base image as a plain Kubernetes Deployment plus Service, with no
operator, no Custom Resource Definitions, and no accelerator labels. Its only
assumptions are a reachable cluster and a node advertising `amd.com/gpu`. The
default model is small and ungated (Qwen2.5-1.5B-Instruct), so no Hugging Face
token is needed.

## Run and keep it serving

A plain `--level 1` deploys the model, proves inference works, and then deletes
everything on exit. To keep the Deployment and Service running so we can use
them, we pass `--keep 1`. From a laptop we also point at the cluster; it is
simplest to export the kubeconfig once so our later `kubectl` commands use it
too:

```bash
export KUBECONFIG=~/Downloads/kubeconfig.yaml
./aim_deploy.sh --level 1 --keep 1
```

The script waits for the pod to become Ready (the first image pull and weight
download can take a few minutes, with progress lines), serves a test completion,
confirms vLLM placed its KV cache on the GPU, and prints a "level 1 verified"
line. Because of `--keep 1` it leaves the Deployment `aim-base-check` running.

## Use the served model

The script's own port-forward is transient, so we open our own:

```bash
kubectl port-forward -n default svc/aim-base-check 8000:80 >/tmp/pf.log 2>&1 &
sleep 3
```

The endpoint is OpenAI-compatible. We read the served model id from
`/v1/models` rather than hardcoding it, since the base image registers the model
under its real Hugging Face repo name:

```bash
curl -sS localhost:8000/v1/models
MODEL=$(curl -sS localhost:8000/v1/models | grep -o '"id":"[^"]*"' | head -n1 | cut -d'"' -f4)

curl -sS localhost:8000/v1/chat/completions -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"What is ROCm?\"}],\"max_tokens\":200}"

curl -sS localhost:8000/metrics | grep cache_usage_perc   # vLLM confirms a GPU KV cache
```

Anything that speaks the OpenAI protocol works against this endpoint, for
example the `openai` Python package or a LangChain client pointed at
`http://localhost:8000/v1`.

## Drive it with an example app

The `icf_4agent` multi-agent example in the HPCTrainingExamples repository
(`MLExamples/icf_4agent`) is a ready-made client that is configured entirely
through environment variables, so we point it at our port-forwarded endpoint and
reuse the served id from above:

```bash
export ICF_BASE_URL=http://localhost:8000/v1
export ICF_MODEL="$MODEL"
export ICF_API_KEY=unused
cd /path/to/HPCTrainingExamples/MLExamples/icf_4agent && ./start_app.sh
```

The app reasons best with a capable chat model such as a gpt-oss variant. The
small level-1 default exercises the wiring but answers weakly, so for real use
we serve a larger model (below) or move to the operator path.

## Serve a different model

Level 1 serves the base image's small default. To serve a larger open model, we
set the model id the base check reads; the environment is inherited by the
underlying script:

```bash
MODEL_ID="Qwen/Qwen2.5-7B-Instruct" ./aim_deploy.sh --level 1 --keep 1
```

A gated model such as Llama or Gemma additionally needs `HF_TOKEN` exported from
an account granted access. For a model-specific AIM image and the full operator
path, use [level 4](level-4.md) with `--model-image`.

## Clean up

```bash
kill %1 2>/dev/null                                        # stop the port-forward
kubectl delete deployment,service aim-base-check -n default
```

## Scope

This check matches the operator only on the runtime: the image, in-pod GPU
detection, weight download, and engine start. It does not exercise the operator's
label-driven profile resolution, so a green result here is necessary but not
sufficient for the operator path. To validate that, use
[level 2](level-2.md) or above.
