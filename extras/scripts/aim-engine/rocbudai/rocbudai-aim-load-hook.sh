#!/usr/bin/env bash

# ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
# Called by the rocbudai (AIM) Lmod modulefile at load time. Mirrors the stock
# rocBudAI load hook: it guards against recursion and a missing TTY, then hands
# off to setup_rocbudai_aim.sh with the site defaults the modulefile exported.
#
# Why a separate file (not inline in the modulefile): Lmod collapses
# execute{cmd=...} onto a single eval line, which breaks inline if/then/fi. A
# real script keeps the logic readable and the modulefile small.
#
# This runs in a subshell (Lmod evals `bash <this-script>`), so the
# ROCBUDAI_AIM_ACTIVE guard it exports does not leak back into the login shell;
# it only suppresses a nested auto-launch from inside the agent's own shell
# tools (which do inherit this environment).
#
# Inputs (exported by the modulefile before this hook runs):
#   ROCBUDAI_AIM_DIR (required) and any of ROCBUDAI_AIM_{ENDPOINT,NAMESPACE,
#   SERVICE,ARCH,SRC,REF,WORKDIR}.
# ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

set -u

DIR="${ROCBUDAI_AIM_DIR:-}"
if [[ -z "${DIR}" || ! -f "${DIR}/setup_rocbudai_aim.sh" ]]; then
   echo "[rocBudAI] ROCBUDAI_AIM_DIR is unset or wrong (${DIR:-<unset>}); check the modulefile." >&2
   exit 1
fi

if [[ -n "${ROCBUDAI_AIM_ACTIVE:-}" ]]; then
   echo "[rocBudAI] already inside a rocbudai session (ROCBUDAI_AIM_ACTIVE set); not re-launching." >&2
   exit 0
fi
if [[ ! -t 0 || ! -t 1 ]]; then
   echo "[rocBudAI] loaded (no TTY; not auto-launching)." >&2
   echo "[rocBudAI] start it manually with: setup_rocbudai_aim.sh" >&2
   exit 0
fi

export ROCBUDAI_AIM_ACTIVE=1

# Translate the modulefile's site defaults into explicit flags. Only pass the
# ones that are set, so setup_rocbudai_aim.sh applies its own defaults for the
# rest.
args=()
[[ -n "${ROCBUDAI_AIM_ENDPOINT:-}"  ]] && args+=(--endpoint     "${ROCBUDAI_AIM_ENDPOINT}")
[[ -n "${ROCBUDAI_AIM_NAMESPACE:-}" ]] && args+=(--namespace    "${ROCBUDAI_AIM_NAMESPACE}")
[[ -n "${ROCBUDAI_AIM_SERVICE:-}"   ]] && args+=(--service      "${ROCBUDAI_AIM_SERVICE}")
[[ -n "${ROCBUDAI_AIM_ARCH:-}"      ]] && args+=(--arch         "${ROCBUDAI_AIM_ARCH}")
[[ -n "${ROCBUDAI_AIM_SRC:-}"       ]] && args+=(--rocbudai-src "${ROCBUDAI_AIM_SRC}")
[[ -n "${ROCBUDAI_AIM_REF:-}"       ]] && args+=(--rocbudai-ref "${ROCBUDAI_AIM_REF}")
[[ -n "${ROCBUDAI_AIM_WORKDIR:-}"   ]] && args+=(--workdir      "${ROCBUDAI_AIM_WORKDIR}")
case "${ROCBUDAI_AIM_LOCAL_GPU:-}" in
   no)  args+=(--no-local-gpu) ;;
   yes) args+=(--local-gpu) ;;
esac

bash "${DIR}/setup_rocbudai_aim.sh" "${args[@]}"
rc=$?
[[ ${rc} -ne 0 ]] && echo "[rocBudAI] session exited with code ${rc}" >&2
exit 0
