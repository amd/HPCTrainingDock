# rocBudAI over AIM Engine

[rocBudAI](https://github.com/AMD-HPC/rocBudAI) is AMD-HPC's ROCm profiling
assistant: an [opencode](https://opencode.ai) TUI (terminal user interface)
driven by GPU-architecture personas that walk a user through profiling and
optimizing their code. Its stock
deployment serves the model locally with ollama and gates the launcher behind
Slurm, so a user must be inside a `--comment=ollama` GPU allocation to start it.

This directory installs rocBudAI as a thin client of a model already served by
AIM (AMD Inference Microservices) Engine: the vLLM, OpenAI-compatible endpoint
stood up by [`../deploy`](../deploy/README.md). The user experience is the stock rocBudAI
experience, unchanged: the session picker, `rocbudai --continue`, session naming,
the welcome banner, the idle auto-nudge, resume hints, and `rocbudai-submit` all
behave exactly as they do upstream. Only the model moves: instead of an ollama
daemon on a local GPU, the model runs remotely on the cluster, and the agent can
run from a login node or a laptop that has no GPU of its own.

## How it works

`install-rocbudai-aim.sh` does four things: it clones rocBudAI at a pinned ref,
applies a small AIM backend patch, drops in the no-GPU addendum, and writes an
Lmod modulefile that reuses rocBudAI's own load hook. We install into a prefix in
your home directory by default and touch nothing system-wide.

The patch (`patches/rocbudai-aim.patch`) adds one backend branch to the stock
tree, keyed on `ROCBUDAI_BACKEND=aim`, and leaves the ollama path untouched. When
the AIM backend is active the launcher:

1. asserts the cluster is trusted (`ROCBUDAI_AIM_TRUSTED=1`) and refuses
   otherwise;
2. resolves the endpoint, either a URL we pass or a `kubectl port-forward` to the
   predictor Service, and verifies it is in-boundary (loopback or RFC1918);
3. reads the served model id and `max_model_len` from `GET /v1/models`, warning
   if the context window is below 64k;
4. skips the ollama and Slurm gates, writes `opencode.json` with the AIM provider
   (OpenAI-compatible, tool-calling on, `share` disabled, rocBudAI's ASK-mode
   permission policy inherited from the stock template), and launches raw opencode
   rather than `ollama launch`.

Everything else, the persona seeding and the whole session machinery, is stock
rocBudAI running unmodified. Because we drive raw opencode, which honors
`OPENCODE_CONFIG`, the recipe needs none of the global-`AGENTS.md` workaround the
ollama launch path requires.

## The trust boundary

rocBudAI's promise is that your code, prompts, and model output never leave a
boundary you trust. With a local ollama model that boundary is your GPU node;
over AIM it becomes the cluster that serves the model. The recipe therefore
treats trust as an explicit, verifiable assertion rather than an assumption.

The installer asks you to confirm (or takes `--trust`) that the cluster is one
you control and that is severed from the internet, and bakes
`ROCBUDAI_AIM_TRUSTED=1` into the modulefile only if so. At launch the patched
`rocbudai-tui` re-checks that flag and refuses to start without it, and it
resolves the endpoint only if it points at an in-boundary address. `rocbudai-airgap-check`
verifies the rest on demand: the trust assertion, the in-boundary endpoint,
opencode's phone-home suppression and `share: disabled`, an advisory host-egress
probe, and, with `--deep`, that the predictor Service is a ClusterIP (not a
publicly reachable LoadBalancer or NodePort).

This is a defensible ceiling, not a proof: on a host you control nothing can stop
you from setting an env var, so the assertion is the human judgment and the checks
are what make it verifiable. Cluster admins are trusted, and login nodes often
have open egress; the checks catch obvious leaks rather than a determined one.

## Prerequisites

- An AIM Engine endpoint already serving a capable model (see
  [`../deploy`](../deploy/README.md)), or use `--deploy` below to stand one up.
- `opencode` on `PATH` (`npm i -g opencode-ai@1.14.28`), and, on first run, the
  `@ai-sdk/openai-compatible` provider package that opencode fetches on demand.
  On an internet-severed cluster, pre-stage both during cluster prep.
- To reach AIM by port-forward: `kubectl` and a kubeconfig (see
  [Supplying a kubeconfig](../deploy/README.md#supplying-a-kubeconfig)). To reach
  it directly, pass `--endpoint` and no `kubectl` is needed.
- `git` to fetch rocBudAI, unless you pass `--rocbudai-src` with a local checkout.

Two serving properties matter for the persona to work. The model must be a large,
tools-strong model (~120B class): small models follow the strict persona and
first-turn rules unreliably. And the context window must fit the persona, which
is ~28k tokens: a vLLM `--max-model-len` of 32k stalls on prefill, so prefer 64k
or more. The launcher reads the served `max_model_len` and warns when it is small.

## Quick start

Install once, then use `module load rocbudai` from any project directory. There
are two ways to reach the model.

With a routable endpoint (Ingress, LoadBalancer, NodePort, or a port-forward you
already run), pass it directly and no `kubectl` is involved:

```bash
./install-rocbudai-aim.sh --endpoint http://localhost:8080/v1
```

Otherwise let the launcher port-forward to the predictor. This path uses
`kubectl`, so first point it at your cluster and confirm it is authenticated: if
`kubectl` is not logged in, endpoint discovery waits on it and appears to hang.

```bash
export KUBECONFIG=/path/to/your/kubeconfig
kubectl get svc -n <your-namespace>     # completes any OIDC login prompt
./install-rocbudai-aim.sh --namespace <your-namespace>
```

On a headless login node (no local browser, the usual case here) the OIDC
`authcode` flow redirects to `http://localhost:8000`, which the node cannot open.
SSH to the node forwarding that callback port so the redirect reaches the login
server on the node, then run `kubectl` in the same session and open the printed
URL in your laptop browser:

```bash
ssh -L 8000:localhost:8000 <user>@<login-node>
# then, in that same session on the node:
kubectl get svc -n <your-namespace>     # open the printed URL in your browser
```

Match the forwarded port to kubelogin's `--listen-address` if it is not the
default `8000` (check `kubectl config view`). Avoid
`--grant-type=authcode-keyboard`: it relies on the out-of-band redirect
(`urn:ietf:wg:oauth:2.0:oob`), which recent Keycloak rejects with
"Invalid parameter: redirect_uri".

Either way the installer prints the two lines that finish setup:

```bash
module use $HOME/rocbudai-aim/modulefiles
cd <your-project-dir>          # the code you want rocBudAI to profile
module load rocbudai
```

Loading the module launches the TUI exactly as stock rocBudAI does: a session
picker if this directory has prior sessions, otherwise the welcome banner and the
seven-question discovery interview. On a fresh session the launcher first asks
which GPU you are profiling, since the agent host has no local GPU to detect it
from, and loads the matching persona; a resumed session keeps its persona and is
not asked again. `rocbudai --continue` resumes the last session in the directory,
and `rocbudai --new` forces a fresh one. Session files (`AGENTS.md`,
`opencode.json`, `.rocbudai-*`) are written into the project directory; add them
to your `.gitignore`.

## GPU execution: where the workload runs

Serving the model on AIM is separate from running your GPU code. The agent runs
wherever you load the module, often a login node or laptop with no local GPU,
which breaks a core rocBudAI assumption: the persona tells the agent to profile
with `rocbudai-bench`, which runs the workload on a local GPU. The recipe handles
this automatically. When the launcher detects no local GPU it appends
`no-gpu-addendum.md` to opencode's instructions, which overrides the persona: the
agent is told not to run GPU work locally and to dispatch every build, run, and
profiler job through `rocbudai-submit` instead. On a real GPU node the addendum is
omitted and the stock local flow applies.

The intended topology is a model served on the Kubernetes cluster and GPU
workloads submitted to a Slurm HPC system with `rocbudai-submit`. Today the recipe
targets running the agent on the HPC login node itself: no local GPU, so the
addendum engages, but Slurm and `rocbudai-submit` are on `PATH` and the compute
nodes share its filesystem, so the agent submits jobs directly. `rocbudai-submit`
comes with the rocBudAI tree the installer stages, so it is always on `PATH`.

`rocbudai-submit` carries no hardcoded cluster information: it reads the target
partition from `ROCBUDAI_SUBMIT_PARTITION` (falling back to the Slurm cluster
default when unset), and `-p` overrides it per run. Pass `--submit-partition` at
install time to bake the site's GPU partition into the modulefile so dispatched
jobs land where they should; leave it unset only if the cluster default partition
is already the right GPU partition.

## Options

| Flag | Meaning |
| --- | --- |
| `--prefix DIR` | install root (default `$HOME/rocbudai-aim`) |
| `--gfx-arch ARCH` | optionally pin the profiling-target persona (`gfx90a`, `mi300x`, `gfx950`, `mi300a`); omit it and the launcher asks per session |
| `--namespace NS` | AIM namespace; the launcher port-forwards the predictor |
| `--endpoint URL` | direct base URL ending in `/v1`; skips the port-forward |
| `--submit-partition P` | Slurm partition `rocbudai-submit` dispatches GPU jobs to (baked as `ROCBUDAI_SUBMIT_PARTITION`; empty means the cluster default) |
| `--trust` | assert the cluster is trusted and in-boundary (no prompt) |
| `--rocbudai-ref REF` | git ref to pin (default: the ref the patch targets) |
| `--rocbudai-src PATH` | use a local rocBudAI checkout instead of cloning (air-gapped) |
| `--force` | overwrite an existing `--prefix` |
| `--dry-run` | print actions without changing anything |
| `--help` | usage |

The persona is chosen for the profiling target you work on, independent of the
GPU serving the model, so one shared install drives every supported arch: the
launcher asks at the start of each fresh session. `--gfx-arch` is for a
single-arch site that prefers to pin one default (baked into the modulefile as
`ROCBUDAI_AGENTS_TEMPLATE`); `export ROCBUDAI_GFX_ARCH=<arch>` before
`module load rocbudai` answers the prompt non-interactively.

## Serving the model at install time

If the model is not yet served, pass `--deploy` (with `--namespace`) and the
installer delegates to [`../deploy/aim_deploy.sh --level 2`](../deploy/level-2.md),
forwarding every serving knob so we never duplicate deploy logic:

```bash
./install-rocbudai-aim.sh --namespace <ns> --deploy \
    --model-image amdenterpriseai/aim-gpt-oss-120b:<tag> --max-model-len 65536
```

`--model-image`, `--max-model-len`, and repeatable `--engine-arg KEY=VALUE` map
one-to-one onto `aim_deploy.sh`, and its `AIM_ACCELERATOR_COUNT`,
`AIM_ENGINE_ARGS`, and `AIM_MAX_MODEL_LEN` environment variables are inherited as
documented there. Without `--deploy` the installer configures the client only and
never mutates a running model; the AIMService model is immutable once created, so
switching models means deleting and recreating it.

## Air-gapped and shared installs

On a trusted, internet-severed cluster, pre-vendor a pinned rocBudAI checkout and
pass `--rocbudai-src /path/to/rocBudAI`, pre-stage `opencode` and the
`@ai-sdk/openai-compatible` package, and reach the endpoint on the trusted network
(or by port-forward). An administrator who wants a shared, site-wide module runs
the same installer with `--prefix` pointed at a shared path and publishes the one
`module use` line in the site profile:

```bash
./install-rocbudai-aim.sh --prefix /shared/apps/rocbudai-aim --namespace <ns> --trust
module use /shared/apps/rocbudai-aim/modulefiles
```

## Files

- `install-rocbudai-aim.sh`: the installer described above.
- `patches/rocbudai-aim.patch`: the AIM backend branch for `rocbudai-tui`,
  `rocbudai-airgap-check`, and the load hook, applied to the pinned rocBudAI ref.
- `no-gpu-addendum.md`: the instructions overlay appended when the agent host has
  no local GPU (forbids `rocbudai-bench`; mandates dispatched GPU execution).
