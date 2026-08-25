# rocBudAI over AIM Engine

[rocBudAI](https://github.com/AMD-HPC/rocBudAI) is AMD-HPC's ROCm profiling
assistant: an [opencode](https://opencode.ai) TUI driven by GPU-architecture
personas that walk a user through profiling and optimizing their code. Its stock
deployment serves the model locally with ollama and depends on Slurm, Lmod, and
systemd.

This directory wires rocBudAI as a **client of a model already served by AIM
Engine** (the vLLM, OpenAI-compatible endpoint stood up by [`../deploy`](../deploy/README.md)),
so users get the rocBudAI agent experience without any local model server. It is
the agent-shaped counterpart to the `icf_4agent` example in
[level 2](../deploy/level-2.md#drive-it-with-an-example-app): another consumer of
the served `/v1` endpoint.

## What this is (and is not)

We install nothing on the cluster and need no root, Slurm, systemd, Lmod, or
ollama. The script only:

1. resolves the AIM endpoint (a URL we pass, or a `kubectl port-forward` to the
   predictor Service);
2. reads the served model id and `max_model_len` from `GET /v1/models`;
3. fetches the rocBudAI persona from the upstream repo at a pinned ref (or a
   local checkout, for air-gapped clusters);
4. generates an `opencode.json` (AIM provider, tool-calling on, `share`
   disabled, absolute `instructions` path, and rocBudAI's ASK-mode permission
   policy) from `opencode.json.tmpl`;
5. writes the session files the persona expects (`.rocbudai-banner.md`,
   `.rocbudai-runtime.md`), stages the `rocbudai-name-session` helper, and
   launches opencode (via a generated `run-opencode.sh`) with a session-start
   seed prompt.

It delivers the rocBudAI **agent + persona + discovery interview** over AIM. It
deliberately does **not** provide `rocbudai-bench` / `rocbudai-submit`, the
Slurm `--comment` daemon gating, the ollama hardening / airgap `nft` tooling, or
model management — those belong to a full rocBudAI HPC-admin install. Here the
airgap is a property of the cluster (trusted, internet-severed), not of
rocBudAI.

Ownership stays clean: rocBudAI remains the single source of truth for personas
and agent behavior; this recipe is just the glue that points opencode at AIM.

### Matching the stock runtime

The arch personas don't just need `AGENTS.md` — at runtime they read files and
call a helper that stock `rocbudai-tui` provides. To keep the experience faithful
(and not degrade to fallbacks), the script reproduces the relevant pieces:

- **Welcome banner + session context.** The persona (§0) silently reads
  `.rocbudai-banner.md` and prints it verbatim as the welcome, then reads
  `.rocbudai-runtime.md` for context. The script generates both, adapted for AIM
  (model served remotely, no Slurm/ollama rows, cluster-provided airgap).
- **Permission policy.** `opencode.json` carries the same ASK-mode `permission`
  block as stock (`opencode-default.json`): read-only commands pre-approved,
  dangerous ones (`rm -rf` of key paths, `module purge/reset`, obfuscated
  commands) denied, and `rocbudai-name-session` allowed.
- **Session naming.** The persona's Q1/7 runs `rocbudai-name-session`; the script
  stages just that one helper on `PATH` (not the rest of rocBudAI's `bin/`, so a
  site `rocbudai-submit`/`rocbudai-bench` is never shadowed) and sets
  `ROCBUDAI_OPENCODE_BIN` for it.
- **Knowledge base.** The persona (§7) resolves a KB directory and prefers
  `${ROCBUDAI_ROOT}/share/rocbudai/kb/`. The launcher exports `ROCBUDAI_ROOT`
  (pointing at the fetched checkout, unless a site value is already set) so the
  public ROCm-tool KB resolves.
- **Phone-home suppression + timeouts.** The same `OPENCODE_DISABLE_*` vars and
  the long bash-tool timeout stock uses are exported at launch.

Not reproduced (intentionally): the **auto-nudge watcher** (idle "continue"
injection) and the **session picker/resume** — these are conveniences of the full
install; an interactive user drives the session directly here.

## Prerequisites

- An AIM Engine endpoint already serving a model (see [`../deploy`](../deploy/README.md)).
- `opencode` on `PATH` (`curl -fsSL https://opencode.ai/install | bash`), and,
  on first run, the `@ai-sdk/openai-compatible` provider package, which opencode
  fetches on demand. **On an internet-severed cluster, pre-stage both** during
  cluster prep.
- To reach AIM by port-forward: `kubectl` and a kubeconfig (see
  [Supplying a kubeconfig](../deploy/README.md#supplying-a-kubeconfig)). To reach
  it directly, pass `--endpoint`.
- `git` to fetch the persona, unless you pass `--rocbudai-src` with a local
  (pre-vendored) rocBudAI checkout.

## Two serving prerequisites that matter

1. **Model size.** rocBudAI's personas are written for large, tools-strong
   models (~120B class). Small models follow the strict persona and first-turn
   rules unreliably (they may ignore the "emit the welcome banner + Q1/7"
   instruction or hallucinate tool/agent types). Serve a capable model.
2. **Context window.** The full arch personas are large (~28k tokens). A vLLM
   `--max-model-len` of 32k leaves no room and stalls on prefill; prefer
   **>= 64k**. The script warns when the served `max_model_len` is below
   `MIN_CONTEXT` (default 65536). Use `--arch demo` (a compact persona) to smoke
   the flow on a small window.

## GPU execution: where the workload actually runs

Serving the **model** on AIM is separate from running the **user's GPU code**.
The agent (opencode) runs wherever the user launches it — often a login node or
laptop **with no local GPU**. That breaks a core rocBudAI assumption: the persona
tells the agent to use `rocbudai-bench`, which runs the workload *locally* on the
node's GPU. Without a local GPU that cannot work; all GPU execution (build, run,
profilers) must be **dispatched to a GPU node**.

This recipe handles the guidance half automatically: when it detects no local
GPU (or you pass `--no-local-gpu`), it appends `no-gpu-addendum.md` to opencode's
instructions, which overrides the persona — the agent is told not to use
`rocbudai-bench` or run GPU work locally, and to dispatch it instead. Pass
`--local-gpu` to force local runs on a GPU node.

### Intended topology

- **Model serving** runs on the Kubernetes cluster (AIM Engine); the agent
  reaches it by kubeconfig/port-forward or a direct `--endpoint` URL.
- **GPU workloads** (build, run, profilers) run on a **separate Slurm HPC
  system** and are submitted with `rocbudai-submit`.

**Current assumption (what this recipe targets today):** the user runs the agent
**on the HPC login node** itself. That node has no local GPU (so the addendum
engages automatically) but does have Slurm and `rocbudai-submit` on `PATH` and a
shared filesystem with the compute nodes — so the agent submits GPU jobs
directly. `rocbudai-submit` comes from the HPC's rocBudAI/Slurm tooling, not from
this recipe (which ships neither `rocbudai-bench` nor `rocbudai-submit`).

**Future (not yet implemented):** run the agent on a laptop with only the
kubeconfig, and have it SSH into the HPC system to submit jobs there. That
remote-dispatch path is deliberately out of scope for now.

## Why a port-forward? (rocBudAI still runs on your machine)

rocBudAI — opencode, the persona, and all agent logic — runs **locally** on your
laptop/login node. The only remote piece is the **model**, a vLLM pod inside the
Kubernetes cluster. opencode just needs an HTTP URL to send chat requests to:

```
[your machine: opencode + rocBudAI persona] --HTTP--> localhost:PORT --tunnel--> [in-cluster vLLM model]
```

AIM exposes the model as a **ClusterIP** Service (e.g. `10.243.x.x`), which is
reachable only from inside the cluster network — your machine can't route to it.
`kubectl port-forward` is simply the tunnel that maps a local port to that
in-cluster Service. It is **not** rocBudAI running remotely.

If your AIM endpoint is exposed on a routable URL (Ingress / LoadBalancer /
NodePort), skip the tunnel entirely and pass `--endpoint https://<host>/v1`; then
no `kubectl`/kubeconfig is needed at all.

### Finding the predictor Service

You normally don't need its name — pass `--namespace` and the script
auto-discovers it (by the AIM operator's `component=predictor` label, then a name
match) and manages the port-forward for you. To look it up manually:

```bash
kubectl get svc -n <namespace> -l component=predictor
# or, if unlabeled:
kubectl get svc -n <namespace> | grep predictor
```

Pass a specific one with `--service NAME` if auto-discovery picks the wrong one.
On failure the script prints every Service in the namespace so you can choose.

## Quick start

Point at an existing endpoint:

```bash
./setup_rocbudai_aim.sh --endpoint http://localhost:8088/v1 --arch gfx950
```

Or let the script port-forward to the predictor (needs kubeconfig + namespace):

```bash
export KUBECONFIG=/path/to/your/kubeconfig
./setup_rocbudai_aim.sh --namespace <your-namespace> --arch gfx950
```

Then opencode opens and, from the seed prompt, emits the rocBudAI welcome banner
and begins the 7-question discovery interview.

## Options

| Flag | Meaning |
| --- | --- |
| `--namespace NS` | namespace holding the AIM predictor (default `default`) |
| `--endpoint URL` | AIM base URL ending in `/v1`; skips the port-forward |
| `--service NAME` | predictor Service name (else auto-discovered by the `component=predictor` label) |
| `--local-port PORT` | local port for the port-forward (default `8088`) |
| `--arch ARCH` | persona for the profiling-target GPU: `gfx90a` (MI250X/MI210), `mi300x` (MI300X), `gfx950` (MI355X/MI350X), `mi300a` (MI300A APU), `demo` (compact) |
| `--rocbudai-src PATH` | use a local rocBudAI checkout (air-gapped; skips clone) |
| `--rocbudai-ref REF` | git ref to clone when `--rocbudai-src` is not given (default `main`) |
| `--workdir PATH` | opencode project root — **set this to the code directory you want rocBudAI to profile** (default `~/rocbudai-aim`) |
| `--clean-cache` | remove the cached rocBudAI clone (`~/.cache/rocbudai-aim/rocbudai-src`) and exit |
| `--no-launch` | write files and print the launch command instead of exec'ing opencode |
| `--kubeconfig PATH` | kubeconfig for this run (exports `KUBECONFIG`) |
| `--help` | usage |

Most flags also read from matching environment variables (see `--help`).

The persona is chosen for the **profiling target** the user works on, which is
independent of the GPU serving the model — so a user on any supported arch can
drive a model served centrally on Instinct nodes.

### Workdir vs. the rocBudAI clone

These are two separate directories:

- **`--workdir`** is the opencode *project root*. Point it at the directory
  holding the code you want rocBudAI to profile. opencode runs there, reads/edits
  your code, and writes its small session files into it (`AGENTS.md`,
  `opencode.json`, `.rocbudai-banner.md`, `.rocbudai-runtime.md`,
  `run-opencode.sh`, `.rocbudai-bin/`). Add those to your `.gitignore`.
- **The rocBudAI clone** (only needed for the persona files) is cached
  *outside* your workdir at `${XDG_CACHE_HOME:-~/.cache}/rocbudai-aim/rocbudai-src`
  (override with `ROCBUDAI_SRC_CACHE`), or supplied via `--rocbudai-src`. It is
  never nested inside your code directory.

The cache is **persistent by design** — reruns `git fetch` it instead of
re-cloning, so launches stay fast and it works offline after the first pull. It
is *not* removed automatically. Because it lives under `~/.cache`, it is safe to
delete anytime and the script re-clones on the next run. To reclaim it
explicitly:

```bash
./setup_rocbudai_aim.sh --clean-cache
```

## Set up as a module (`module load rocbudai`)

So users get the familiar `module load rocbudai` experience, this directory ships
an Lmod modulefile (`modulefiles/rocbudai.lua`) that auto-launches the TUI on
load — the same pattern the stock rocBudAI module uses, minus ollama/Slurm.

Admin steps (once):

1. Copy the whole `rocbudai/` directory to a shared path, e.g.
   `/shared/apps/aim-engine/rocbudai`.
2. Edit the **SITE CONFIG** block at the top of
   `modulefiles/rocbudai.lua` to match your cluster: `root` (the install path
   from step 1), `aim_namespace` or `aim_endpoint`, `aim_arch`, and — for an
   internet-severed cluster — `aim_src` (a pre-vendored rocBudAI checkout) and
   optionally `aim_kubeconfig`.
3. Put the modulefiles directory on `MODULEPATH`:

```bash
module use /shared/apps/aim-engine/rocbudai/modulefiles
```

Add that `module use` line to your site profile so it is always available.

Users then do exactly what they are used to:

```bash
module load rocbudai
```

On load, `rocbudai-aim-load-hook.sh` runs (guarding against recursion and a
missing TTY), resolves the AIM endpoint, generates the config, and launches
opencode. Users can still override per session before loading, e.g.
`export ROCBUDAI_AIM_ARCH=gfx90a` or `export KUBECONFIG=…`.

Notes:
- Reaching AIM by port-forward needs each user's `KUBECONFIG` (or a shared one
  set via `aim_kubeconfig`). If the AIM endpoint is directly reachable on the
  trusted network, set `aim_endpoint` and no kubeconfig is required.
- This module is named `rocbudai`; do not install it on the same `MODULEPATH` as
  a stock (ollama-based) rocBudAI module, or the names will collide.

## Air-gapped use

On a trusted, internet-severed cluster:

1. Pre-vendor a pinned rocBudAI checkout and pass `--rocbudai-src /path/to/rocBudAI`.
2. Pre-stage `opencode` and the `@ai-sdk/openai-compatible` package.
3. Ensure the AIM endpoint is reachable on the trusted network (or via
   port-forward) and pass `--endpoint` or `--namespace`/`--service`.

## Files

- `setup_rocbudai_aim.sh` — the entrypoint described above.
- `opencode.json.tmpl` — the opencode config template (AIM provider +
  tool-calling + absolute instructions path + ASK-mode permission block) filled
  in per run.
- `modulefiles/rocbudai.lua` — Lmod modulefile so users can `module load rocbudai`.
- `rocbudai-aim-load-hook.sh` — the load-time hook the modulefile invokes.
- `no-gpu-addendum.md` — instructions overlay appended when the agent host has no
  local GPU (disables `rocbudai-bench`; mandates dispatched GPU execution).

Generated per run into the working dir (default `~/rocbudai-aim`): `AGENTS.md`,
`opencode.json`, `.rocbudai-banner.md`, `.rocbudai-runtime.md`,
`.rocbudai-bin/rocbudai-name-session`, `run-opencode.sh`, and (no local GPU)
`no-gpu-addendum.md`.
