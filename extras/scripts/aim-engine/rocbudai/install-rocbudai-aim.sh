#!/usr/bin/env bash
# Copyright (C) 2026 Advanced Micro Devices, Inc.
# Use of this source code is governed by an MIT-style license that can be
# found in the LICENSE file or at https://opensource.org/licenses/MIT.
#
# install-rocbudai-aim.sh — install rocBudAI as a thin client of an AIM Engine
# model service. It clones rocBudAI at a pinned ref, applies the AIM backend
# patch, drops in the no-GPU addendum, and writes an Lmod modulefile so users
# get the stock `module load rocbudai` experience while the model is served
# remotely on a trusted, in-boundary Kubernetes cluster instead of local ollama.
#
# The rocBudAI session picker, naming, banner, resume, auto-nudge, and
# rocbudai-submit paths are reused unchanged; only model resolution, the
# opencode provider config, and the launch call come from the patch.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEPLOY_DIR="$(cd "${SELF_DIR}/../deploy" && pwd -P)"
PATCH="${SELF_DIR}/patches/rocbudai-aim.patch"
ADDENDUM="${SELF_DIR}/no-gpu-addendum.md"

# Pinned rocBudAI commit the patch is authored against. Override with
# --rocbudai-ref (a clean apply is required, so only move this when the patch
# is re-cut) or bypass git entirely with --rocbudai-src for an air-gapped host.
ROCBUDAI_REPO_URL="https://github.com/AMD-HPC/rocBudAI.git"
ROCBUDAI_REF="e694eb91acb7ea3202fafe78af67554c3d7d0e53"

PREFIX="${HOME}/rocbudai-aim"
GFX_ARCH=""
NAMESPACE=""
ENDPOINT=""
SUBMIT_PARTITION=""
ROCBUDAI_SRC=""
DO_DEPLOY=0
ASSERT_TRUST=""
FORCE=0
DRY_RUN=0
DEPLOY_ARGS=()

err()  { echo "[install-rocbudai-aim] error: $*" >&2; }
info() { echo "[install-rocbudai-aim] $*"; }
run()  { if [[ $DRY_RUN -eq 1 ]]; then echo "  + $*"; else "$@"; fi; }

usage() {
    cat <<EOF
Usage: install-rocbudai-aim.sh [options]

Client:
  --prefix DIR         install root (default: \$HOME/rocbudai-aim)
  --gfx-arch ARCH      optionally pin the profiling-target persona:
                       gfx90a | mi300x | gfx950 | mi300a. Omit it (the usual case
                       on a shared login node) and the launcher asks per session.
  --namespace NS       AIM namespace; the launcher port-forwards the predictor.
  --endpoint URL       direct OpenAI-compatible base URL (e.g. http://host:8080/v1);
                       skips port-forward. Use --namespace OR --endpoint.
  --submit-partition P Slurm partition rocbudai-submit dispatches GPU jobs to
                       (baked as ROCBUDAI_SUBMIT_PARTITION; "" => cluster default;
                       override per run with rocbudai-submit -p).
  --trust              assert this cluster is trusted + in-boundary (no prompt).
  --rocbudai-ref REF   git ref to pin (default: the ref the patch targets).
  --rocbudai-src PATH  use a local rocBudAI checkout instead of cloning.
  --force              overwrite an existing --prefix.
  --dry-run            print actions without changing anything.
  --help               this message.

Serving (delegated to deploy/aim_deploy.sh --level 2; requires --namespace):
  --deploy             serve/refresh the model before installing the client.
  --model-image IMAGE  AIM model image.
  --max-model-len N    context window (>= 65536 recommended for the full persona).
  --engine-arg K=V     extra vLLM engine arg, repeatable.
  (AIM_ACCELERATOR_COUNT, AIM_ENGINE_ARGS, AIM_MAX_MODEL_LEN env vars are
   inherited by aim_deploy.sh as documented there.)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)        PREFIX="$2"; shift 2 ;;
        --gfx-arch)      GFX_ARCH="$2"; shift 2 ;;
        --namespace)     NAMESPACE="$2"; shift 2 ;;
        --endpoint)      ENDPOINT="$2"; shift 2 ;;
        --submit-partition) SUBMIT_PARTITION="$2"; shift 2 ;;
        --trust)         ASSERT_TRUST=1; shift ;;
        --rocbudai-ref)  ROCBUDAI_REF="$2"; shift 2 ;;
        --rocbudai-src)  ROCBUDAI_SRC="$2"; shift 2 ;;
        --force)         FORCE=1; shift ;;
        --dry-run)       DRY_RUN=1; shift ;;
        --deploy)        DO_DEPLOY=1; shift ;;
        --model-image)   DEPLOY_ARGS+=(--model-image "$2"); shift 2 ;;
        --max-model-len) DEPLOY_ARGS+=(--max-model-len "$2"); shift 2 ;;
        --engine-arg)    DEPLOY_ARGS+=(--engine-arg "$2"); shift 2 ;;
        --help|-h)       usage; exit 0 ;;
        *)               err "unknown argument: $1"; usage; exit 2 ;;
    esac
done

# Optionally resolve a persona to pin. With no --gfx-arch the launcher asks per
# session (the agent host has no local GPU to autodetect the target from).
PERSONA=""
case "${GFX_ARCH}" in
    "")            ;;
    gfx90a)        PERSONA="AGENTS-gfx90a.md" ;;
    gfx942|mi300x) PERSONA="AGENTS-gfx942-mi300x.md" ;;
    gfx950)        PERSONA="AGENTS-gfx950.md" ;;
    mi300a)        PERSONA="AGENTS-default.md" ;;
    *) err "unsupported --gfx-arch '${GFX_ARCH}' (use gfx90a|mi300x|gfx950|mi300a)"; exit 2 ;;
esac

[[ -f "${PATCH}" ]]    || { err "patch not found: ${PATCH}"; exit 1; }
[[ -f "${ADDENDUM}" ]] || { err "no-gpu addendum not found: ${ADDENDUM}"; exit 1; }
if [[ -n "${NAMESPACE}" && -n "${ENDPOINT}" ]]; then
    err "use --namespace OR --endpoint, not both."; exit 1
fi
if [[ -z "${NAMESPACE}" && -z "${ENDPOINT}" ]]; then
    err "one of --namespace or --endpoint is required."; exit 1
fi

# Optionally serve the model first, delegating every knob to aim_deploy.sh.
if [[ ${DO_DEPLOY} -eq 1 ]]; then
    [[ -n "${NAMESPACE}" ]] || { err "--deploy requires --namespace."; exit 1; }
    [[ -x "${DEPLOY_DIR}/aim_deploy.sh" ]] || { err "aim_deploy.sh not found in ${DEPLOY_DIR}"; exit 1; }
    info "serving model via aim_deploy.sh --level 2 (namespace ${NAMESPACE})"
    run "${DEPLOY_DIR}/aim_deploy.sh" --level 2 --namespace "${NAMESPACE}" ${DEPLOY_ARGS[@]+"${DEPLOY_ARGS[@]}"}
fi

# Trust: refuse silently baking trust; require an explicit assertion. The
# launcher enforces the same flag at runtime and verifies the endpoint is
# in-boundary before it starts.
TRUSTED=0
if [[ -n "${ASSERT_TRUST}" ]]; then
    TRUSTED=1
elif [[ $DRY_RUN -eq 1 ]]; then
    TRUSTED=1
else
    echo
    echo "rocBudAI's promise is that your code, prompts, and model output never leave"
    echo "a boundary you trust. Over AIM that boundary is the cluster serving the model."
    printf "Is '%s' a trusted, internet-severed cluster you control? [y/N] " "${NAMESPACE:-${ENDPOINT}}"
    read -r _ans || _ans=""
    case "${_ans}" in y|Y|yes|YES) TRUSTED=1 ;; *) TRUSTED=0 ;; esac
fi
[[ ${TRUSTED} -eq 1 ]] || info "trust NOT asserted — the modulefile is written with ROCBUDAI_AIM_TRUSTED=0 and the launcher will refuse until you re-run with --trust."

# Prepare the install prefix.
if [[ -e "${PREFIX}" ]]; then
    if [[ ${FORCE} -eq 1 ]]; then
        info "removing existing ${PREFIX} (--force)"
        run rm -rf "${PREFIX}"
    else
        err "${PREFIX} already exists (pass --force to overwrite)."; exit 1
    fi
fi

# Obtain the rocBudAI tree at the pinned ref, in place at the prefix.
if [[ -n "${ROCBUDAI_SRC}" ]]; then
    [[ -d "${ROCBUDAI_SRC}" ]] || { err "--rocbudai-src not a directory: ${ROCBUDAI_SRC}"; exit 1; }
    info "copying rocBudAI from ${ROCBUDAI_SRC}"
    run cp -r "${ROCBUDAI_SRC}" "${PREFIX}"
else
    command -v git >/dev/null 2>&1 || { err "git not found; use --rocbudai-src for an offline install."; exit 1; }
    info "cloning rocBudAI (${ROCBUDAI_REF})"
    run git clone --quiet "${ROCBUDAI_REPO_URL}" "${PREFIX}"
    run git -C "${PREFIX}" checkout --quiet "${ROCBUDAI_REF}"
fi

# Apply the AIM backend patch (must apply cleanly against the pinned ref).
info "applying AIM backend patch"
if [[ $DRY_RUN -eq 0 ]]; then
    if ! git -C "${PREFIX}" apply --check "${PATCH}" 2>/dev/null; then
        err "patch does not apply cleanly to this rocBudAI tree."
        err "pin the matching ref (--rocbudai-ref ${ROCBUDAI_REF}) or re-cut the patch."
        exit 1
    fi
    git -C "${PREFIX}" apply "${PATCH}"
else
    echo "  + git -C ${PREFIX} apply ${PATCH}"
fi

# Drop the no-GPU addendum where the launcher looks for it.
info "installing no-gpu addendum"
run cp "${ADDENDUM}" "${PREFIX}/share/rocbudai/no-gpu-addendum.md"

# Confirm a pinned persona exists in the tree (skipped when none is pinned).
if [[ -n "${PERSONA}" && $DRY_RUN -eq 0 && ! -f "${PREFIX}/share/rocbudai/${PERSONA}" ]]; then
    err "persona ${PERSONA} not found under ${PREFIX}/share/rocbudai (ref mismatch?)."
    exit 1
fi

# Locate opencode for the modulefile (raw opencode honours OPENCODE_CONFIG).
OPENCODE_BIN="$(command -v opencode 2>/dev/null || true)"
OPENCODE_DIR=""
if [[ -n "${OPENCODE_BIN}" ]]; then
    OPENCODE_DIR="$(dirname "${OPENCODE_BIN}")"
else
    err "opencode not found on PATH; install it (npm i -g opencode-ai@1.14.28) before launching."
fi

# Write the modulefile.
MODDIR="${PREFIX}/modulefiles/rocbudai"
MODFILE="${MODDIR}/aim.lua"
info "writing modulefile ${MODFILE}"
if [[ $DRY_RUN -eq 1 ]]; then
    echo "  + generate ${MODFILE} (backend=aim, arch=${GFX_ARCH:-asked at launch}, trusted=${TRUSTED})"
else
    mkdir -p "${MODDIR}"
    {
        echo "-- rocbudai/aim — rocBudAI over AIM Engine (generated by install-rocbudai-aim.sh)"
        echo "-- The model is served remotely by AIM Engine; this host is a thin client."
        echo "-- Loading on an interactive TTY auto-launches the OpenCode TUI."
        echo
        echo 'help([['
        echo "rocBudAI (AIM client) — AMD GPU profiling/optimisation AI assistant."
        echo
        echo "The model runs on a trusted, in-boundary AIM Engine cluster; your code,"
        echo "prompts, and model output stay within that boundary. GPU work is dispatched"
        echo "to a GPU node via rocbudai-submit (this host may have no GPU)."
        echo
        echo "  cd <project-dir>"
        echo "  module load rocbudai        # launches the OpenCode TUI"
        echo "  rocbudai --continue         # resume the last session in this dir"
        echo "  rocbudai-airgap-check       # verify the in-boundary baseline"
        echo ']])'
        echo
        echo 'whatis("Name        : rocbudai (AIM client)")'
        echo 'whatis("Description : AMD GPU profiling AI assistant (OpenCode + AIM Engine)")'
        echo
        echo "local root = \"${PREFIX}\""
        echo 'prepend_path("PATH", pathJoin(root, "bin"))'
        echo 'setenv("ROCBUDAI_ROOT", root)'
        [[ -n "${OPENCODE_BIN}" ]] && echo "setenv(\"ROCBUDAI_OPENCODE_BIN\", \"${OPENCODE_BIN}\")"
        [[ -n "${OPENCODE_DIR}" ]] && echo "setenv(\"ROCBUDAI_OPENCODE_DIR\", \"${OPENCODE_DIR}\")"
        echo
        echo "-- opencode phone-home suppression (soft airgap layer)."
        echo 'setenv("OPENCODE_DISABLE_AUTOUPDATE",      "1")'
        echo 'setenv("OPENCODE_DISABLE_LSP_DOWNLOAD",    "1")'
        echo 'setenv("OPENCODE_DISABLE_MODELS_FETCH",    "1")'
        echo 'setenv("OPENCODE_DISABLE_EXTERNAL_SKILLS", "1")'
        echo 'setenv("OPENCODE_DISABLE_SHARE",           "1")'
        echo
        echo "-- AIM backend selection."
        echo 'setenv("ROCBUDAI_BACKEND", "aim")'
        echo "setenv(\"ROCBUDAI_AIM_TRUSTED\", \"${TRUSTED}\")"
        if [[ -n "${ENDPOINT}" ]]; then
            echo "setenv(\"ROCBUDAI_AIM_ENDPOINT\", \"${ENDPOINT}\")"
        else
            echo "setenv(\"ROCBUDAI_AIM_NAMESPACE\", \"${NAMESPACE}\")"
        fi
        echo
        echo "-- Slurm partition rocbudai-submit dispatches GPU jobs to (empty => cluster default)."
        echo "setenv(\"ROCBUDAI_SUBMIT_PARTITION\", \"${SUBMIT_PARTITION}\")"
        if [[ -n "${PERSONA}" ]]; then
            echo
            echo "-- Pinned profiling-target persona (honour a user export to force one)."
            echo 'if os.getenv("ROCBUDAI_AGENTS_TEMPLATE") == nil or os.getenv("ROCBUDAI_AGENTS_TEMPLATE") == "" then'
            echo "    setenv(\"ROCBUDAI_AGENTS_TEMPLATE\", pathJoin(root, \"share/rocbudai/${PERSONA}\"))"
            echo "end"
        fi
        echo
        echo "-- Auto-launch the TUI on load (recursion-guarded by ROCBUDAI_ACTIVE)."
        echo "if mode() == \"load\" then"
        echo "    execute{"
        echo "        cmd = \"bash \" .. pathJoin(root, \"libexec/rocbudai-load-hook.sh\"),"
        echo "        modeA = {\"load\"},"
        echo "    }"
        echo "end"
    } > "${MODFILE}"
fi

echo
info "done. To use it:"
echo "  module use ${PREFIX}/modulefiles"
echo "  cd <your-project-dir>"
echo "  module load rocbudai"
if [[ -n "${NAMESPACE}" ]]; then
    echo
    echo "Authenticate kubectl once first (clears any OIDC login prompt):"
    echo "  kubectl get svc -n ${NAMESPACE}"
fi
