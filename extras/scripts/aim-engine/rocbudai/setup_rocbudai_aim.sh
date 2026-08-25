#!/bin/bash

# ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
# Use rocBudAI (the AMD-HPC opencode agent + GPU-profiling personas) as a CLIENT
# of a model already served by AIM Engine, instead of the stock rocBudAI path
# that serves the model locally with ollama.
#
# This is NOT a rocBudAI install. It stands up nothing on the cluster and needs
# no root, no Slurm, no systemd, no Lmod, and no ollama. It assumes an AIM
# Engine (vLLM, OpenAI-compatible) endpoint is already serving a model (see
# ../deploy) and simply wires opencode to talk to it with the rocBudAI persona:
#
#   1. Resolve the AIM endpoint (a URL you pass, or a kubectl port-forward to
#      the predictor Service).
#   2. Read the served model id + max_model_len from GET /v1/models.
#   3. Fetch the rocBudAI persona (AGENTS.md) from the upstream rocBudAI repo at
#      a pinned ref (or from a local checkout you point at, for air-gapped use).
#   4. Generate opencode.json (AIM provider, tool-calling on, share disabled,
#      absolute instructions path, and the rocBudAI ASK-mode permission policy)
#      from opencode.json.tmpl next to this script.
#   5. Write the session files the persona expects (.rocbudai-banner.md,
#      .rocbudai-runtime.md), stage the rocbudai-name-session helper, and write a
#      run-opencode.sh that launches opencode with the rocBudAI environment.
#
# Scope: this delivers the rocBudAI AGENT experience (persona + discovery
# interview + banner + permission policy + KB + opencode TUI) over AIM. It
# deliberately does NOT provide rocbudai-bench / rocbudai-submit, the Slurm
# --comment gating, the ollama hardening / airgap nft tooling, the auto-nudge
# watcher, the session picker, or model management -- those belong to a full
# rocBudAI HPC-admin install. GPU work is expected to be dispatched via a
# site-provided rocbudai-submit (see README). In this flow the airgap is
# provided by the cluster (trusted, internet-severed), not by rocBudAI.
#
# Two serving prerequisites (see README.md for why):
#   * Serve a large, tools-strong model (rocBudAI targets ~120B class). Small
#     models follow the strict persona/first-turn rules unreliably.
#   * Give vLLM enough context (--max-model-len). The full arch personas are
#     large (~28k tokens); a 32k window leaves no room and stalls. Prefer >=64k.
# ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/opencode.json.tmpl"

# --- defaults (override via flags or environment) --------------------------------------------------------------------------------------------------------------------------------------------------------------
: ${NAMESPACE:=default}
# Full AIM base URL ending in /v1. If set, no port-forward is done and the
# cluster flags are ignored (use this on a node that can already reach AIM).
: ${ENDPOINT:=}
# Predictor Service name. Empty => auto-discover by the AIM predictor label.
: ${SERVICE:=}
: ${LOCAL_PORT:=8088}
: ${REMOTE_PORT:=80}       # predictor Service port (targets container 8000)
: ${API_KEY:=unused}       # AIM is unauthenticated in-cluster; dummy key satisfies opencode.
# Which rocBudAI persona (profiling-target GPU arch). One of:
#   gfx90a | mi300x | gfx950 | mi300a | demo
: ${ARCH:=gfx950}
# rocBudAI source: a git URL (cloned at ROCBUDAI_REF) or a local checkout path
# (used as-is, for air-gapped clusters where you pre-vendor the repo).
: ${ROCBUDAI_REPO:=https://github.com/AMD-HPC/rocBudAI.git}
: ${ROCBUDAI_REF:=main}
: ${ROCBUDAI_SRC:=}        # local checkout path; if set, skips cloning.
# Where to cache the rocBudAI clone when ROCBUDAI_SRC is not given. Deliberately
# NOT under WORKDIR, so pointing --workdir at your own code dir does not nest a
# full rocBudAI clone inside your repo. Shared across sessions/workdirs.
: ${ROCBUDAI_SRC_CACHE:=${XDG_CACHE_HOME:-${HOME}/.cache}/rocbudai-aim/rocbudai-src}
# Session working dir = the opencode project root. Set this to the directory
# holding the code you want rocBudAI to profile.
: ${WORKDIR:=${HOME}/rocbudai-aim}
# Whether this agent host has a usable local GPU. auto|yes|no. When "no", a
# runtime addendum is appended to opencode's instructions that overrides the
# persona's local-execution guidance (no rocbudai-bench; dispatch GPU work).
: ${LOCAL_GPU:=auto}
: ${OUTPUT_TOKENS:=8192}   # opencode model "limit.output"
: ${MIN_CONTEXT:=65536}    # warn below this served max_model_len
: ${LAUNCH:=1}             # 1: exec opencode; 0: just write files and print the command.
: ${SEED:=Waiting for the model to warm up -- begin the rocBudAI session now: emit the welcome banner and the first discovery question (Q1/7).}
: ${OPENCODE_BIN:=opencode}

usage()
{
   echo "Usage:"
   echo "  --namespace [ NS ]      k8s namespace holding the AIM predictor, default ${NAMESPACE}"
   echo "  --endpoint [ URL ]      AIM base URL ending in /v1 (skips port-forward)"
   echo "  --service [ NAME ]      predictor Service name (else auto-discovered)"
   echo "  --local-port [ PORT ]   local port for the port-forward, default ${LOCAL_PORT}"
   echo "  --arch [ ARCH ]         persona arch: gfx90a|mi300x|gfx950|mi300a|demo, default ${ARCH}"
   echo "  --no-local-gpu          agent host has no GPU: forbid local GPU runs (no rocbudai-bench)"
   echo "  --local-gpu             agent host has a GPU: allow local runs (default: autodetect)"
   echo "  --rocbudai-src [ PATH ] use a local rocBudAI checkout (air-gapped; skips clone)"
   echo "  --rocbudai-ref [ REF ]  git ref to clone when --rocbudai-src is not given, default ${ROCBUDAI_REF}"
   echo "  --workdir [ PATH ]      opencode project root: your code dir to profile, default ${WORKDIR}"
   echo "  --clean-cache           remove the cached rocBudAI clone and exit"
   echo "  --no-launch             write files and print the launch command, do not exec opencode"
   echo "  --kubeconfig [ PATH ]   kubeconfig to use for this run (exports KUBECONFIG)"
   echo "  --help                  print this usage information"
   echo ""
   echo "Env: ENDPOINT, SERVICE, LOCAL_PORT, ARCH, LOCAL_GPU, ROCBUDAI_REPO, ROCBUDAI_REF,"
   echo "     ROCBUDAI_SRC, ROCBUDAI_SRC_CACHE, WORKDIR, MIN_CONTEXT, SEED, OPENCODE_BIN, API_KEY."
}

send-error() { usage; echo -e "\nError: ${@}" >&2; exit 1; }
reset-last() { last() { send-error "Unsupported argument :: ${1}"; }; }

if [ -t 1 ]; then
   C_TAG=$'\033[1;36m'; C_HEAD=$'\033[1;36m'; C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'; C_OFF=$'\033[0m'
else
   C_TAG=''; C_HEAD=''; C_OK=''; C_WARN=''; C_ERR=''; C_OFF=''
fi
say()  { echo -e "${C_TAG}[rocbudai-aim]${C_OFF} ${*}"; }
warn() { echo -e "${C_TAG}[rocbudai-aim]${C_OFF} ${C_WARN}warning:${C_OFF} ${*}" >&2; }

# Define the bad-argument handler up front so an unsupported FIRST argument is
# reported cleanly (reset-last is re-invoked after each known flag too).
reset-last

while [[ $# -gt 0 ]]; do
   case "${1}" in
      "--namespace")     shift; NAMESPACE=${1}; reset-last ;;
      "--endpoint")      shift; ENDPOINT=${1}; reset-last ;;
      "--service")       shift; SERVICE=${1}; reset-last ;;
      "--local-port")    shift; LOCAL_PORT=${1}; reset-last ;;
      "--arch")          shift; ARCH=${1}; reset-last ;;
      "--no-local-gpu")  LOCAL_GPU=no ;;
      "--local-gpu")     LOCAL_GPU=yes ;;
      "--rocbudai-src")  shift; ROCBUDAI_SRC=${1}; reset-last ;;
      "--rocbudai-ref")  shift; ROCBUDAI_REF=${1}; reset-last ;;
      "--workdir")       shift; WORKDIR=${1}; reset-last ;;
      "--clean-cache")   CLEAN_CACHE=1 ;;
      "--no-launch")     LAUNCH=0 ;;
      "--kubeconfig")    shift; [ -f "${1}" ] || send-error "kubeconfig file not found :: ${1}"; export KUBECONFIG="${1}"; reset-last ;;
      "--help")          usage; exit 0 ;;
      *)                 last ${1} ;;
   esac
   shift
done

# --- optional cache teardown -----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
# Remove the cached rocBudAI clone and exit. The cache is otherwise persistent
# (refreshed via git fetch on reruns); this is the explicit way to reclaim it.
if [ "${CLEAN_CACHE:-0}" = "1" ]; then
   if [ -d "${ROCBUDAI_SRC_CACHE}" ]; then
      rm -rf "${ROCBUDAI_SRC_CACHE}" && say "removed cached rocBudAI clone :: ${ROCBUDAI_SRC_CACHE}"
   else
      say "no cached rocBudAI clone to remove :: ${ROCBUDAI_SRC_CACHE}"
   fi
   exit 0
fi

[ -f "${TEMPLATE}" ] || send-error "template not found next to this script :: ${TEMPLATE}"

# --- map persona arch -> rocBudAI AGENTS file ------------------------------------------------------------------------------------------------------------------------------------------------------------------
case "${ARCH}" in
   gfx90a)  PERSONA_FILE="AGENTS-gfx90a.md" ;;         # MI250X / MI210 (CDNA2)
   mi300x)  PERSONA_FILE="AGENTS-gfx942-mi300x.md" ;;  # MI300X (discrete gfx942)
   gfx950)  PERSONA_FILE="AGENTS-gfx950.md" ;;         # MI355X / MI350X (CDNA4)
   mi300a)  PERSONA_FILE="AGENTS-default.md" ;;        # MI300A APU (gfx942)
   demo)    PERSONA_FILE="AGENTS-container-demo.md" ;; # compact demo persona (fits small context)
   *)       send-error "unknown --arch '${ARCH}' (expected gfx90a|mi300x|gfx950|mi300a|demo)" ;;
esac

# --- obtain the rocBudAI persona source ------------------------------------------------------------------------------------------------------------------------------------------------------------------------
mkdir -p "${WORKDIR}" || send-error "cannot create workdir :: ${WORKDIR}"
WORKDIR="$(cd "${WORKDIR}" && pwd)"

if [ -n "${ROCBUDAI_SRC}" ]; then
   [ -d "${ROCBUDAI_SRC}" ] || send-error "rocBudAI source dir not found :: ${ROCBUDAI_SRC}"
   SRC_DIR="$(cd "${ROCBUDAI_SRC}" && pwd)"
   say "using local rocBudAI checkout: ${SRC_DIR}"
else
   command -v git >/dev/null 2>&1 || send-error "git not found on PATH (needed to fetch the persona; or pass --rocbudai-src)."
   # Clone into a cache dir OUTSIDE the workdir so --workdir can safely be your
   # own code directory without a rocBudAI clone landing inside it.
   SRC_DIR="${ROCBUDAI_SRC_CACHE}"
   mkdir -p "$(dirname "${SRC_DIR}")" || send-error "cannot create cache dir :: $(dirname "${SRC_DIR}")"
   if [ -d "${SRC_DIR}/.git" ]; then
      say "refreshing rocBudAI checkout (${ROCBUDAI_REF}) in ${SRC_DIR}"
      git -C "${SRC_DIR}" fetch --depth 1 origin "${ROCBUDAI_REF}" >/dev/null 2>&1 \
         && git -C "${SRC_DIR}" checkout -q FETCH_HEAD 2>/dev/null \
         || warn "could not refresh existing checkout; using what is on disk."
   else
      say "cloning rocBudAI (${ROCBUDAI_REF}) into ${SRC_DIR}"
      git clone --depth 1 --branch "${ROCBUDAI_REF}" "${ROCBUDAI_REPO}" "${SRC_DIR}" >/dev/null 2>&1 \
         || git clone --depth 1 "${ROCBUDAI_REPO}" "${SRC_DIR}" >/dev/null 2>&1 \
         || send-error "failed to clone ${ROCBUDAI_REPO} (no internet? pass --rocbudai-src with a pre-vendored checkout)."
   fi
fi

PERSONA_SRC="${SRC_DIR}/share/rocbudai/${PERSONA_FILE}"
[ -f "${PERSONA_SRC}" ] || send-error "persona not found in rocBudAI source :: ${PERSONA_SRC}"

# --- resolve the AIM endpoint ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
pf=""
cleanup() { [ -n "${pf}" ] && kill "${pf}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

if [ -n "${ENDPOINT}" ]; then
   ENDPOINT="${ENDPOINT%/}"
   say "using provided endpoint: ${ENDPOINT}"
else
   command -v kubectl >/dev/null 2>&1 || send-error "kubectl not found on PATH (or pass --endpoint URL to skip the port-forward)."
   if [ -z "${SERVICE}" ]; then
      say "discovering AIM predictor Service in namespace '${NAMESPACE}'"
      # Prefer the AIM operator's predictor label; fall back to a name match.
      SERVICE="$(kubectl get svc -n "${NAMESPACE}" -l component=predictor -o name 2>/dev/null | head -n1 | cut -d/ -f2)"
      [ -z "${SERVICE}" ] && SERVICE="$(kubectl get svc -n "${NAMESPACE}" -o name 2>/dev/null | grep -m1 predictor | cut -d/ -f2)"
      if [ -z "${SERVICE}" ]; then
         say "${C_ERR}no predictor Service found in namespace '${NAMESPACE}'.${C_OFF} Services there:"
         kubectl get svc -n "${NAMESPACE}" 2>&1 | sed 's/^/[rocbudai-aim]   svc: /'
         send-error "pass the right one with --service NAME (or --namespace NS), or --endpoint URL to skip discovery."
      fi
      say "found predictor Service: ${SERVICE}"
   fi
   say "port-forwarding svc/${SERVICE} ${LOCAL_PORT}->${REMOTE_PORT} (namespace ${NAMESPACE})"
   ENDPOINT="http://localhost:${LOCAL_PORT}/v1"
   pf_log="$(mktemp)"
   serve_ok=""
   for _ in $(seq 1 12); do
      if [ -z "${pf}" ] || ! kill -0 "${pf}" 2>/dev/null; then
         kubectl port-forward -n "${NAMESPACE}" "svc/${SERVICE}" "${LOCAL_PORT}:${REMOTE_PORT}" >"${pf_log}" 2>&1 &
         pf=$!
      fi
      sleep 3
      curl -sf "${ENDPOINT}/models" >/dev/null 2>&1 && { serve_ok=1; break; }
   done
   if [ -z "${serve_ok}" ]; then
      say "${C_ERR}could not reach ${ENDPOINT} via port-forward${C_OFF}; port-forward log:"
      sed 's/^/[rocbudai-aim]   pf: /' "${pf_log}" 2>/dev/null
      send-error "port-forward to the AIM predictor failed (check namespace/service/login)."
   fi
fi

# --- read model id + context from /v1/models -------------------------------------------------------------------------------------------------------------------------------------------------------------------
models_json="$(curl -sS "${ENDPOINT}/models" 2>/dev/null)"
[ -n "${models_json}" ] || send-error "empty response from ${ENDPOINT}/models."
MODEL_ID="$(printf '%s' "${models_json}" | tr ',' '\n' | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n1)"
[ -n "${MODEL_ID}" ] || send-error "could not parse a model id from ${ENDPOINT}/models :: ${models_json}"
CONTEXT="$(printf '%s' "${models_json}" | tr ',' '\n' | sed -n 's/.*"max_model_len":\([0-9]*\).*/\1/p' | head -n1)"
[ -n "${CONTEXT}" ] || CONTEXT=32768
say "served model id: ${MODEL_ID}"
say "served max_model_len: ${CONTEXT}"

if [ "${CONTEXT}" -lt "${MIN_CONTEXT}" ] && [ "${ARCH}" != "demo" ]; then
   warn "served context ${CONTEXT} < ${MIN_CONTEXT}. The full '${PERSONA_FILE}' persona (~28k tokens) may not fit"
   warn "and can stall on prefill. Redeploy AIM with a larger --max-model-len, or use --arch demo for a quick test."
fi

# opencode's output limit cannot exceed the model window; clamp for tiny windows.
if [ "${OUTPUT_TOKENS}" -ge "${CONTEXT}" ]; then
   OUTPUT_TOKENS=$(( CONTEXT / 4 ))
fi

# --- write AGENTS.md + opencode.json ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------
AGENTS_PATH="${WORKDIR}/AGENTS.md"
cp "${PERSONA_SRC}" "${AGENTS_PATH}" || send-error "failed to write ${AGENTS_PATH}"
say "wrote persona: ${AGENTS_PATH} (${PERSONA_FILE})"

# Resolve whether this agent host has a usable local GPU. When it does not (the
# common AIM case: the agent runs on a login node/laptop while the model is
# served remotely), append a runtime addendum that OVERRIDES the persona's
# local-execution guidance -- otherwise the persona tells the agent to use
# rocbudai-bench, which cannot work without a local GPU. GPU work must instead be
# dispatched (rocbudai-submit or the site equivalent).
case "${LOCAL_GPU}" in
   auto)
      if command -v rocminfo >/dev/null 2>&1 && rocminfo 2>/dev/null | grep -qE 'gfx(90a|942|950)'; then
         LOCAL_GPU=yes
      else
         LOCAL_GPU=no
      fi
      ;;
   yes|no) ;;
   *) send-error "invalid LOCAL_GPU='${LOCAL_GPU}' (expected auto|yes|no)" ;;
esac

# Build the opencode "instructions" array (JSON). Absolute paths only, so no
# escaping is needed.
INSTRUCTIONS_JSON="[\"${AGENTS_PATH}\"]"
if [ "${LOCAL_GPU}" = "no" ]; then
   ADDENDUM_SRC="${SCRIPT_DIR}/no-gpu-addendum.md"
   if [ -f "${ADDENDUM_SRC}" ]; then
      ADDENDUM_PATH="${WORKDIR}/no-gpu-addendum.md"
      cp "${ADDENDUM_SRC}" "${ADDENDUM_PATH}" || send-error "failed to write ${ADDENDUM_PATH}"
      INSTRUCTIONS_JSON="[\"${AGENTS_PATH}\", \"${ADDENDUM_PATH}\"]"
      warn "no local GPU detected on this host: rocbudai-bench and local GPU runs are disabled;"
      warn "the agent is instructed to dispatch all GPU work (rocbudai-submit or site equivalent)."
   else
      warn "no local GPU detected but ${ADDENDUM_SRC} is missing; the persona may still suggest rocbudai-bench."
   fi
else
   say "local GPU detected: local runs (rocbudai-bench) left enabled per the persona."
fi

# Fill the template. Bash ${var//search/replace} handles slashes in values
# (e.g. the "Org/Model" id and absolute paths), unlike sed with a / delimiter.
tmpl="$(cat "${TEMPLATE}")"
tmpl="${tmpl//__BASE_URL__/${ENDPOINT}}"
tmpl="${tmpl//__API_KEY__/${API_KEY}}"
tmpl="${tmpl//__MODEL_ID__/${MODEL_ID}}"
tmpl="${tmpl//__CONTEXT__/${CONTEXT}}"
tmpl="${tmpl//__OUTPUT__/${OUTPUT_TOKENS}}"
tmpl="${tmpl//__INSTRUCTIONS_JSON__/${INSTRUCTIONS_JSON}}"
CONFIG_PATH="${WORKDIR}/opencode.json"
printf '%s\n' "${tmpl}" > "${CONFIG_PATH}" || send-error "failed to write ${CONFIG_PATH}"
say "wrote config:  ${CONFIG_PATH}"

# --- session runtime + banner files (the persona §0 reads these) -----------------------------------------------------------------------------------------------------------------------------------------------
# The arch personas silently Read .rocbudai-banner.md on the first turn and print
# it verbatim as the welcome, then emit Q1/7; .rocbudai-runtime.md carries the
# session context. Stock rocbudai-tui writes both -- without them the persona
# falls back to a degraded "banner not generated" message. Generate AIM-adapted
# versions so the banner/discovery UX matches. (The compact demo persona emits
# its own welcome and ignores these, but writing them is harmless.)
_now="$(date -Is 2>/dev/null || date)"
_host="$(hostname 2>/dev/null || echo unknown)"
_user="${USER:-$(id -un 2>/dev/null || echo unknown)}"

cat > "${WORKDIR}/.rocbudai-runtime.md" <<EOF
# rocbudai session runtime context

Generated by the rocBudAI AIM launcher at session start. The agent reads
this file as part of §0 of its operating instructions. Safe to delete; it
is regenerated on the next launch.

| Key                  | Value                                |
|----------------------|--------------------------------------|
| Node                 | ${_host}                             |
| User name            | ${_user}                             |
| Model                | ${MODEL_ID}                          |
| Served by            | AIM Engine (${ENDPOINT})             |
| Local GPU            | ${LOCAL_GPU}                         |
| Working dir          | ${WORKDIR}                           |
| Session ID           | (new)                                |
| Session name         | (unnamed)                            |
| Started at           | ${_now}                              |
EOF

if [ "${LOCAL_GPU}" = "no" ]; then
   _gpu_line="IMPORTANT: this host has no local GPU. All GPU work (build, run, and
profilers) is dispatched with rocbudai-submit; rocbudai-bench (local
single-GPU runs) is disabled here."
else
   _gpu_line="IMPORTANT: use rocbudai-bench for single-rank and/or single-GPU runs,
and rocbudai-submit for multi-rank and/or multi-GPU runs."
fi

cat > "${WORKDIR}/.rocbudai-banner.md" <<EOF
Welcome to rocBudAI — your AMD GPU profiling assistant (AIM Engine backend).

${_gpu_line}

Session info:
  Node:        ${_host}
  Model:       ${MODEL_ID}
  Served by:   AIM Engine — ${ENDPOINT}
  Working dir: ${WORKDIR}

Privacy: this session talks to a model served inside your trusted,
internet-severed cluster; your code, prompts, and the model's replies
stay within that boundary.

I am running in ASK mode. Every non-trivial bash command pauses for your
y/Enter approval; read-only commands (ls, cat, rocminfo, rocm-smi, module
list) are pre-approved so I do not nag you for trivial introspection.

To exit: type /exit or Ctrl-D.
Your files persist in ${WORKDIR} after you leave.

Let's scope the run. I will ask seven short questions, one at a time.
Here's the first:
EOF
say "wrote runtime + banner (.rocbudai-runtime.md, .rocbudai-banner.md)"

# Stage rocbudai-name-session (the persona's Q1/7 runs it to name the session)
# into a session-local helper bin. We copy ONLY this one helper -- not the rest
# of rocBudAI's bin/ -- so we never shadow a site-installed rocbudai-submit /
# rocbudai-bench, and so rocbudai-bench is not exposed on a GPU-less host.
HELPER_BIN="${WORKDIR}/.rocbudai-bin"
mkdir -p "${HELPER_BIN}"
if [ -f "${SRC_DIR}/bin/rocbudai-name-session" ]; then
   cp "${SRC_DIR}/bin/rocbudai-name-session" "${HELPER_BIN}/rocbudai-name-session" \
      && chmod +x "${HELPER_BIN}/rocbudai-name-session"
else
   warn "rocbudai-name-session not found in ${SRC_DIR}/bin; Q1/7 session naming will no-op."
fi

# --- write a self-contained launcher so LAUNCH and --no-launch behave identically ------------------------------------------------------------------------------------------------------------------------------
# Bakes in the same environment stock rocbudai-tui / the modulefile set: our
# opencode.json (OPENCODE_CONFIG), the name-session helper on PATH,
# ROCBUDAI_ROOT so the persona's §7 KB path (${ROCBUDAI_ROOT}/share/rocbudai/kb)
# resolves to the fetched checkout, ROCBUDAI_OPENCODE_BIN for the helper, the
# opencode phone-home suppressors, and the long bash-tool timeout (profilers
# routinely exceed the 120 s upstream default). ${VAR:-default} lets a caller
# override any of them. A pre-existing ROCBUDAI_ROOT (e.g. a loaded site module)
# is respected so we do not clobber the site's full KB / tooling.
RUN_SH="${WORKDIR}/run-opencode.sh"
_opencode_abs="$(command -v "${OPENCODE_BIN}" 2>/dev/null || echo "${OPENCODE_BIN}")"
cat > "${RUN_SH}" <<EOF
#!/bin/bash
# Generated by setup_rocbudai_aim.sh. Launches opencode against AIM with the
# rocBudAI persona. Re-run to reconnect (start/keep your port-forward first if
# the endpoint is a localhost port-forward).
cd "${WORKDIR}" || exit 1
export OPENCODE_CONFIG="${CONFIG_PATH}"
export PATH="${HELPER_BIN}:\$PATH"
export ROCBUDAI_ROOT="\${ROCBUDAI_ROOT:-${SRC_DIR}}"
export ROCBUDAI_OPENCODE_BIN="\${ROCBUDAI_OPENCODE_BIN:-${_opencode_abs}}"
export OPENCODE_DISABLE_AUTOUPDATE="\${OPENCODE_DISABLE_AUTOUPDATE:-1}"
export OPENCODE_DISABLE_LSP_DOWNLOAD="\${OPENCODE_DISABLE_LSP_DOWNLOAD:-1}"
export OPENCODE_DISABLE_MODELS_FETCH="\${OPENCODE_DISABLE_MODELS_FETCH:-1}"
export OPENCODE_DISABLE_EXTERNAL_SKILLS="\${OPENCODE_DISABLE_EXTERNAL_SKILLS:-1}"
export OPENCODE_DISABLE_SHARE="\${OPENCODE_DISABLE_SHARE:-1}"
export OPENCODE_EXPERIMENTAL_BASH_DEFAULT_TIMEOUT_MS="\${OPENCODE_EXPERIMENTAL_BASH_DEFAULT_TIMEOUT_MS:-600000}"
exec "${_opencode_abs}" --prompt "${SEED}" "\$@"
EOF
chmod +x "${RUN_SH}"
say "wrote launcher: ${RUN_SH}"

# --- launch (or print the command) -----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
if ! command -v "${OPENCODE_BIN}" >/dev/null 2>&1; then
   warn "opencode not found on PATH as '${OPENCODE_BIN}'."
   warn "install it (e.g. 'curl -fsSL https://opencode.ai/install | bash') and ensure it is on PATH."
   LAUNCH=0
fi

echo ""
if [ "${LAUNCH}" = "1" ]; then
   say "${C_OK}launching opencode against AIM${C_OFF} (model ${MODEL_ID}); type /exit or Ctrl-D to leave."
   if [ -n "${pf}" ]; then
      warn "the port-forward stops when this session exits; re-run this script to reconnect."
   fi
   # Run in the foreground (not exec) so the EXIT trap still runs afterwards and
   # tears down the transient port-forward instead of orphaning it.
   bash "${RUN_SH}"
else
   echo -e "${C_HEAD}Files ready.${C_OFF} To start rocBudAI against AIM:"
   echo ""
   if [ -z "${ENDPOINT##http://localhost:*}" ] && [ -n "${SERVICE}" ]; then
      echo "  # 1) keep a port-forward to the predictor alive (this run's forward is transient):"
      echo "  kubectl port-forward -n ${NAMESPACE} svc/${SERVICE} ${LOCAL_PORT}:${REMOTE_PORT} >/tmp/aim-pf.log 2>&1 &"
      echo ""
      echo "  # 2) launch opencode:"
   fi
   echo "  cd ${WORKDIR}"
   echo "  bash run-opencode.sh"
   echo ""
fi
