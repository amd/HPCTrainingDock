#!/bin/bash

# ── In-flight-edit safety: self-snapshot to per-job tmpdir ────────────
# Defence: on entry, copy ourselves to /tmp/admin/${SLURM_JOB_ID}/ and
# re-exec from the snapshot.
if [[ -z "${_PYTORCH_SETUP_SH_FROM_SNAPSHOT:-}" ]] && \
   [[ -n "${SLURM_JOB_ID:-}" ]] && \
   [[ -f "${BASH_SOURCE[0]}" ]]; then
   _PT_SNAP_DIR="/tmp/admin/${SLURM_JOB_ID}"
   _PT_SNAP="${_PT_SNAP_DIR}/pytorch_setup.sh.snap"
   mkdir -p "${_PT_SNAP_DIR}" 2>/dev/null || true
   if cp -p "${BASH_SOURCE[0]}" "${_PT_SNAP}" 2>/dev/null; then
      export _PYTORCH_SETUP_SH_FROM_SNAPSHOT=1
      echo "pytorch_setup.sh: in-flight-edit safety: re-exec from ${_PT_SNAP}"
      exec bash "${_PT_SNAP}" "$@"
   fi
fi

# ── Preflight: declare and load required Lmod modules ─────────────────
# preflight_modules loads each module in order; on the first failure it prints the Lmod
# diagnostic and returns MISSING_PREREQ_RC=42, which the parent
# main_setup.sh re-classifies as SKIPPED rather than FAILED.
MISSING_PREREQ_RC=42
if ! type module >/dev/null 2>&1; then
   [ -r /etc/profile.d/lmod.sh ]            && . /etc/profile.d/lmod.sh
   [ -r /usr/share/lmod/lmod/init/bash ]    && . /usr/share/lmod/lmod/init/bash
fi
preflight_modules() {
   [ "$#" -eq 0 ] && return 0
   if ! type module >/dev/null 2>&1; then
      echo "ERROR: Lmod 'module' command not available; needed:$(printf ' %s' "$@")" >&2
      return ${MISSING_PREREQ_RC}
   fi
   echo "preflight: required modules:$(printf ' %s' "$@")"
   local m err
   err=$(mktemp -t preflight.XXXXXX.err 2>/dev/null || echo /tmp/preflight.$$.err)
   for m in "$@"; do
      if ! module load "${m}" 2>"${err}"; then
         echo "ERROR: required module '${m}' could not be loaded." >&2
         [ -s "${err}" ] && sed 's/^/  module> /' "${err}" >&2
         rm -f "${err}"
         return ${MISSING_PREREQ_RC}
      fi
   done
   rm -f "${err}"
   echo "preflight: all required modules loaded."
}

ROCM_VERSION=7.2.0
# Skip rocminfo autodetect if --amdgpu-gfxmodel was supplied. Under
# `set -eo pipefail`, an unguarded rocminfo can kill the script when
# the SDK is built against a newer glibc than the host (ROCm 7.2.3
# binaries need GLIBC_2.38; jammy has 2.35). Audited in 7.2.3 sweep.
if [[ " $* " == *" --amdgpu-gfxmodel "* ]]; then
   AMDGPU_GFXMODEL=""
else
   AMDGPU_GFXMODEL=$(rocminfo 2>/dev/null | grep gfx | sed -e 's/Name://' | head -1 | sed 's/ //g' || true)
fi
BUILD_PYTORCH=0
# PYTORCH_VERSION's role: this 2.9.1 default is only the LAST-RESORT
# fallback. The runtime default is auto-derived by
# default_pytorch_version_for_rocm() (defined further below) from the
# loaded/--rocm-version ROCm major.minor — e.g. ROCm 6.2 -> 2.6.0,
# ROCm 7.1 -> 2.10.0, ROCm 7.3+ -> 2.12.0. The auto-derive runs inside
# resolve_pytorch_stack_versions when PYTORCH_VERSION_USER_SET=0.
# Passing --pytorch-version flips the sentinel to 1 and bypasses the
# auto-derive. The 2.9.1 here is what sticks if the resolver runs with
# an unrecognised ROCm.
PYTORCH_VERSION=2.9.1
PYTORCH_VERSION_USER_SET=0
PYTHON_VERSION=10
# torchvision / torchaudio defaults are placeholders; the resolution
# block below the arg parser overwrites them from
# PYTORCH_COMPANION_VERSIONS using PYTORCH_VERSION's major.minor key
# unless the user explicitly passed --torchvision-version /
# --torchaudio-version. The values seeded here only get used if
# PYTORCH_VERSION's major.minor has no row in the table (in which case
# the script also prints a warning).
TORCHVISION_VERSION=0.24.1
TORCHVISION_VERSION_USER_SET=0
TORCHAUDIO_VERSION=2.9.1
TORCHAUDIO_VERSION_USER_SET=0
# AOTRITON_VERSION default is "" (empty); resolve_pytorch_stack_versions
# below populates it from the PYTORCH_STACK_MANIFEST cell hit, or from
# resolve_aotriton_for_pt_only() (the historical PT-major.minor table)
# when the manifest cell has no aotriton field. The user can pin via
# --aotriton-version. AOTRITON_VERSION_USER_SET=1 means the user passed
# the flag; the resolver respects that and skips both fallbacks.
AOTRITON_VERSION=""
AOTRITON_VERSION_USER_SET=0
FLASHATTENTION_VERSION=2.8.3
FLASHATTENTION_VERSION_USER_SET=0
TRITON_VERSION=3.4.0
TRITON_VERSION_USER_SET=0
TRITON_WHEEL_NAME="triton"
PILLOW_VERSION=12.1.1
PILLOW_VERSION_USER_SET=0
SAGEATTENTION_VERSION="1.0.6" #SageAttention 2 does not support ROCm
SAGEATTENTION_VERSION_USER_SET=0
DEEPSPEED_VERSION="latest"
DEEPSPEED_VERSION_USER_SET=0

# PyTorch ecosystem companion-version table.
# Keyed on PyTorch major.minor (e.g. "2.9", NOT "2.9.1") so any patch
# release inherits the .0 row's companions automatically. This matches
# upstream PyTorch's policy: torchvision / torchaudio releases are
# pinned to a major.minor of PyTorch core, and patch releases (2.9.0,
# 2.9.1, ...) ship without bumping companions.
#
# Value format: "<torchvision_version>:<torchaudio_version>" (colon-
# separated; neither version contains a colon, so split is unambiguous).
# Source for the pairings: pytorch.org/get-started/previous-versions/
# cross-checked against the user-supplied table at the time this code
# was added (PT 2.6 ... 2.12). Future-tentative rows (2.11, 2.12) are
# included so a sweep can drive a build attempt the moment the upstream
# tag goes live; if the tag doesn't exist yet, wget below fails fast
# and the per-package summary shows a clear FAILED instead of silently
# falling back to the previous version's companions.
#
# To add a new PyTorch release: add ONE row keyed on its major.minor.
# To override the table for a specific patch release without editing
# the table: pass --torchvision-version / --torchaudio-version on the
# command line (or via the run_and_log_versioned plumbing in
# main_setup.sh, which forwards --pytorch-version but leaves the
# companion overrides for direct CLI use).
declare -A PYTORCH_COMPANION_VERSIONS=(
   [2.6]="0.21.0:2.6.0"
   [2.7]="0.22.0:2.7.0"
   [2.8]="0.22.1:2.7.1"
   [2.9]="0.24.1:2.9.1"
   [2.10]="0.25.0:2.10.0"
   [2.11]="0.26.0:2.11.0"
   [2.12]="0.27.0:2.11.0"
)

# ── PyTorch stack manifest: (PT major.minor, ROCm major.minor) → all pins ──
# Single source of truth for every version pin in the PyTorch ecosystem
# for combinations we have evidence for. Cells are looked up by the
# resolver below (resolve_pytorch_stack_versions) using the key
# "${PT_MAJOR_MINOR}|${ROCM_MAJOR_MINOR}" (e.g. "2.9|7.1"). Patch
# releases on either axis inherit from the major.minor row (PyTorch
# 2.9.1 + rocm 7.1.1 → cell "2.9|7.1"), matching upstream's release-
# pairing policy.
#
# Value format: ";"-separated "key=value" records. Keys (no aliases here;
# parser may accept short aliases at the CLI):
#   aotriton, torchvision, torchaudio, triton, flashattention,
#   pillow, sageattention, deepspeed
# Every cell SHOULD list every key (resolver tolerates partial cells but
# warns; missing keys fall through to PT-only fallback / file default).
#
# Resolution priority (per pin, highest first):
#   1. user CLI flag (e.g. --aotriton-version) — *_USER_SET=1
#   2. manifest cell value for that pin
#   3. PT-only fallback (resolve_aotriton_for_pt_only / PYTORCH_COMPANION_VERSIONS)
#   4. file-default constant near the top of this script
#
# Leniency: a (PT, ROCm) combination not in the manifest does NOT fail
# the build — the resolver warns loudly and falls through to PT-only
# fallbacks. The user can pass --aotriton-version / --triton-version /
# etc. to pin specific versions for off-table combinations.
#
# How to add a row: pick the (PT major.minor, ROCm major.minor) pair,
# fill in every pin from a known-good build (see logs_*/rocm-X.Y.Z_*/
# log_pytorch*.txt for evidence). Alphabetize within the row so diffs
# stay readable.
declare -A PYTORCH_STACK_MANIFEST=(
   # ── PT 2.7 / 2.8 stack pins (ALL shim cells, NOT canonical) ──
   # Canonical upstream PT/AOTriton pairings are:
   #   PT 2.7 -> aotriton 0.9.2b + Triton 3.2.0
   #   PT 2.8 -> aotriton 0.10b  + Triton 3.2.0
   # We do NOT use those canonical pins on any sh5 build host. Reason:
   # the HSA code-object metadata that Triton 3.2.0 emits is rejected
   # by the system /usr/bin/ld.lld with:
   #   ld.lld: error: unknown abi version:
   #   ERROR: aotriton ninja install failed (rc=1)
   # /usr/bin/ld.lld is the SYSTEM lld -- it is NOT shipped by ROCm
   # and is therefore the SAME binary regardless of which rocm/X.Y.Z
   # module is loaded. So the bug is host-side, not ROCm-version-side.
   # Confirmed across the entire rocm-6.x..7.x range:
   #   rocm-6.4.3   : slurm-9334 PT 2.7.1 & PT 2.8.0 leaves (2026-05-14
   #                  04:30 CDT, log_pytorch_v2.7.1 line 280 + log_pytorch
   #                  line 3956)
   #   rocm-7.0.2   : slurm-9333 PT 2.7.1 leaf hit the same bug BEFORE
   #                  the 7.0 shim cell was added (now superseded by
   #                  the unified 0.11.2b pin below)
   #   rocm-7.1.1   : slurm-9316/9319/9323 (the original regression)
   #   rocm-7.2.3   : slurm-9331 PT 2.7.1 leaf
   # See logs_05_{13,14}_2026/rocm-*_93{16,19,23,31,33,34}/
   # log_pytorch_v*.txt for the full traces.
   #
   # Fix: pin EVERY PT-2.7 and PT-2.8 cell to
   #   aotriton=0.11.2b ; triton=3.4.0
   # 0.11.2b bundles Triton 3.4.0, whose metadata the same system lld
   # accepts. PT-version-appropriate companions (torchvision/torchaudio/
   # flashattention/pillow/sageattention/deepspeed) are kept at their
   # PT-2.7 or PT-2.8 values; only the AOTriton+Triton axis is bumped.
   # Cells are listed (PT, ROCm) in increasing-ROCm order within each PT
   # to keep diffs readable. All 11 cells (3 ROCm-6.x + 3 ROCm-7.x for
   # PT 2.7, plus 2 ROCm-6.x + 3 ROCm-7.x for PT 2.8) carry the
   # IDENTICAL aotriton/triton pin set; companions split on PT only.
   #
   # Caveat: AOTriton 0.11.2b's CMake API was developed against PyTorch
   # 2.9, and the linker step against torch._inductor symbols may
   # mismatch when used with PT 2.7/2.8. 2026-05-13/14 sweep evidence:
   # the 7.1-shim cells unblocked the AOTriton stage but exposed
   # downstream PT-source-tree issues that surface DURING the pytorch
   # wheel build, not at the link step:
   #   amd_warp_functions.h:{90,115} 'cannot compile this builtin yet'
   #   in Embedding.hip + Normalization.hip
   # which is a clang-builtin-not-implemented bug, distinct from the
   # constexpr family my block_reduce.cuh sed patch fixed. Those need
   # additional source-tree patches to fully unblock PT 2.7/2.8 on
   # rocm-7.x; the AOTriton stage itself is no longer the failure
   # boundary for any of these cells.
   #
   # Forward path: if a future rocm-X.Y minor changes the lld
   # behaviour (either by accepting older Triton 3.2.0 metadata, or by
   # breaking the newer 3.4.0 metadata), split that minor's cell off
   # from this block with its own pinned aotriton/triton pair and a
   # comment explaining the divergence.
   # ─ PT 2.7/2.8 cells: aotriton reverted to canonical (0.9.2b/0.10b) ─
   # 2026-05-16: cells reverted from aotriton=0.11.2b back to canonical
   # PT/AOTriton pairings (PT 2.7 -> 0.9.2b, PT 2.8 -> 0.10b). The
   # 0.11.2b shim was originally chosen to dodge the host /usr/bin/ld.lld
   # ABI bug that rejects HSA code-object metadata emitted by Triton
   # 3.2.0 (bundled inside AOTriton 0.9.x/0.10b). However, AOTriton
   # 0.11.2b's adaptor API is incompatible with PT 2.7/2.8's
   # aten/.../mha_all_aot.hip:
   #   - PT 2.7: hard #error "This adaptor code is only tested with
   #             AOTriton 0.9.x" (mha_all_aot.hip:68).
   #   - PT 2.8: implicit conversion failure aotriton::TensorView<2>
   #             -> LazyTensor<2> (mha_all_aot.hip:696, :937).
   # Both failures observed on EVERY ROCm version in the matrix
   # (rocm-6.2..7.2), most recently in 9747 (rocm-6.4.3) on 2026-05-16.
   # The PT 2.7/2.8 cells are now skipped unconditionally by the
   # compatibility gate at the top of resolve_pytorch_stack_versions
   # (search "is not a supported combination"), so these manifest
   # values are effectively documentation-only; they record the
   # AOTriton release that PyTorch 2.7/2.8 were actually tested with
   # upstream, in case a future change re-enables source-build of
   # AOTriton 0.9.x/0.10b (e.g. via prebuilt-tarball install path) and
   # the gate is widened/removed.
   ["2.7|6.2"]="aotriton=0.9.2b;torchvision=0.22.0;torchaudio=2.7.0;triton=3.2.0;flashattention=2.7.4.post1;pillow=11.0.0;sageattention=1.0.5;deepspeed=latest"
   ["2.7|6.3"]="aotriton=0.9.2b;torchvision=0.22.0;torchaudio=2.7.0;triton=3.2.0;flashattention=2.7.4.post1;pillow=11.0.0;sageattention=1.0.5;deepspeed=latest"
   ["2.7|6.4"]="aotriton=0.9.2b;torchvision=0.22.0;torchaudio=2.7.0;triton=3.2.0;flashattention=2.7.4.post1;pillow=11.0.0;sageattention=1.0.5;deepspeed=latest"
   ["2.7|7.0"]="aotriton=0.9.2b;torchvision=0.22.0;torchaudio=2.7.0;triton=3.2.0;flashattention=2.7.4.post1;pillow=11.0.0;sageattention=1.0.5;deepspeed=latest"
   ["2.7|7.1"]="aotriton=0.9.2b;torchvision=0.22.0;torchaudio=2.7.0;triton=3.2.0;flashattention=2.7.4.post1;pillow=11.0.0;sageattention=1.0.5;deepspeed=latest"
   ["2.7|7.2"]="aotriton=0.9.2b;torchvision=0.22.0;torchaudio=2.7.0;triton=3.2.0;flashattention=2.7.4.post1;pillow=11.0.0;sageattention=1.0.5;deepspeed=latest"
   ["2.8|6.3"]="aotriton=0.10b;torchvision=0.22.1;torchaudio=2.7.1;triton=3.2.0;flashattention=2.7.4.post1;pillow=11.0.0;sageattention=1.0.5;deepspeed=latest"
   ["2.8|6.4"]="aotriton=0.10b;torchvision=0.22.1;torchaudio=2.7.1;triton=3.2.0;flashattention=2.7.4.post1;pillow=11.0.0;sageattention=1.0.5;deepspeed=latest"
   ["2.8|7.0"]="aotriton=0.10b;torchvision=0.22.1;torchaudio=2.7.1;triton=3.2.0;flashattention=2.7.4.post1;pillow=11.0.0;sageattention=1.0.5;deepspeed=latest"
   ["2.8|7.1"]="aotriton=0.10b;torchvision=0.22.1;torchaudio=2.7.1;triton=3.2.0;flashattention=2.7.4.post1;pillow=11.0.0;sageattention=1.0.5;deepspeed=latest"
   ["2.8|7.2"]="aotriton=0.10b;torchvision=0.22.1;torchaudio=2.7.1;triton=3.2.0;flashattention=2.7.4.post1;pillow=11.0.0;sageattention=1.0.5;deepspeed=latest"
   ["2.9|7.0"]="aotriton=0.11.2b;torchvision=0.24.1;torchaudio=2.9.1;triton=3.4.0;flashattention=2.8.3;pillow=12.1.1;sageattention=1.0.6;deepspeed=latest"
   ["2.9|7.1"]="aotriton=0.11.2b;torchvision=0.24.1;torchaudio=2.9.1;triton=3.4.0;flashattention=2.8.3;pillow=12.1.1;sageattention=1.0.6;deepspeed=latest"
   ["2.9|7.2"]="aotriton=0.11.2b;torchvision=0.24.1;torchaudio=2.9.1;triton=3.4.0;flashattention=2.8.3;pillow=12.1.1;sageattention=1.0.6;deepspeed=latest"
)

# ── PT-only AOTriton fallback (extracted from the historical if/else) ─
# Returns the canonical AOTriton release for a PyTorch major.minor.
# Used by resolve_pytorch_stack_versions when the manifest cell is
# missing or has no aotriton field. Empty stdout means "no canonical
# pairing for this PT version" -- the resolver treats that as a fatal
# error unless the user passed --aotriton-version.
#
# Provenance of each pairing: each historical row corresponds to the
# AOTriton release published by ROCm/aotriton with PyTorch 2.X release
# notes naming it as the matched bundle. See
# https://github.com/ROCm/aotriton/releases . The earliest supported
# PT line is 2.3 (AOTriton 0.4b); older PTs predate AOTriton entirely.
resolve_aotriton_for_pt_only() {
   local pt_short="$1"
   case "${pt_short}" in
      # 2.10..2.12 added per the user-supplied "Version Alignment Matrix"
      # (PT 2.10+) table:
      #   PT 2.12 -> AOTriton 0.13b / 0.14b   (Experimental, upcoming)
      #   PT 2.11 -> AOTriton 0.12b           (Active Release)
      #   PT 2.10 -> AOTriton 0.11b           (Stable Standard; we use
      #                                       the 0.11.2b patch tag,
      #                                       same as PT 2.9 since both
      #                                       leverage the 0.11 line)
      #
      # ── 2026-05-13 demotion: PT 2.11 / 2.12 -> 0.11.2b ────────────────
      # The matrix-prescribed AOTriton tags 0.12b (PT 2.11) and 0.13b /
      # 0.14b (PT 2.12) DO NOT EXIST upstream as of this commit:
      #   $ git ls-remote --heads --tags https://github.com/ROCm/aotriton.git
      #   <highest is refs/tags/0.11.210b ; refs/heads/release/0.11.50 ;
      #    refs/tags/0.11.2b ; nothing in the 0.12.x or 0.13.x series>
      # Symptom we hit (slurm-9331-rocmplus-7.2.3, log_pytorch_05_13_2026.txt):
      #   ROCm 7.2.3 + bare-default PT 2.11.0 sweep
      #   -> default_pytorch_version_for_rocm("7.2") returns 2.11.0
      #   -> manifest "2.11|7.2" missing -> PT-only fallback runs
      #   -> resolve_aotriton_for_pt_only("2.11") returned 0.12b (this row)
      #   -> aotriton stage: `git clone --branch 0.12b ...` fails:
      #      warning: Could not find remote branch 0.12b to clone.
      #      fatal: Remote branch 0.12b not found in upstream origin
      #      ERROR: aotriton cmake configure failed (rc=1)
      # We DEMOTE both rows to 0.11.2b (the highest existing release line).
      # 0.11.2b bundles Triton 3.4.0, which the rocm-7.x ld.lld accepts
      # (same property that makes the 7.x manifest shims for PT 2.7/2.8
      # work, see PYTORCH_STACK_MANIFEST below).
      # Caveat: 0.11.2b's CMake API was developed against PT 2.9 and there
      # is a known risk that PT 2.11 / 2.12 link steps mismatch against
      # torch._inductor symbols. First successful build of these combos
      # will validate the pairing; if it fails at a post-clone step,
      # add a (PT, ROCm) cell to PYTORCH_STACK_MANIFEST with a working
      # explicit pin (or pass --aotriton-version on the CLI).
      # ACTION ITEM: when upstream cuts 0.12b / 0.13b / 0.14b, flip these
      # rows back to the matrix-prescribed values. Both are non-breaking.
      2.12) echo "0.11.2b" ;;   # was 0.13b (matrix); upstream tag missing
      2.11) echo "0.11.2b" ;;   # was 0.12b (matrix); upstream tag missing
      2.10) echo "0.11.2b" ;;
      2.9)  echo "0.11.2b" ;;
      2.8)  echo "0.10b"   ;;
      2.7)  echo "0.9.2b"  ;;
      2.6)  echo "0.8b"    ;;
      2.5)  echo "0.7b"    ;;
      2.4)  echo "0.6b"    ;;
      2.3)  echo "0.4b"    ;;
      *)    echo ""        ;;
   esac
}

# ── Per-ROCm default PyTorch version (auto-derive when user omits flag) ──
# Returns a sensible default PYTORCH_VERSION (full M.m.p tag) for the
# given ROCm major.minor. Called by resolve_pytorch_stack_versions when
# PYTORCH_VERSION_USER_SET=0. Empty stdout means "no canonical pairing"
# and the caller falls through to the file-default constant
# (PYTORCH_VERSION=2.9.1 near the top of this script).
#
# Source tables (both supplied by the maintainer; merged here):
#   Table 1 ("PyTorch Version / ROCm Version / AOTriton" rows 2.3..2.9):
#     2.9 -> ROCm 7.1+
#     2.8 -> ROCm 6.3 - 7.0
#     2.7 -> ROCm 6.3
#     2.6 -> ROCm 6.2
#     2.5 -> ROCm 6.1
#     2.4 -> ROCm 6.0
#     2.3 -> ROCm 5.7
#   Table 2 ("Version Alignment Matrix (PyTorch 2.10+)"):
#     2.12 -> ROCm 7.3+ (Experimental)
#     2.11 -> ROCm 7.2
#     2.10 -> ROCm 7.1
#
# Overlap-resolution rule: where multiple PT versions cover the same
# ROCm (e.g. PT 2.9 says "7.1+" and PT 2.10 says "7.1"; PT 2.7 and PT 2.8
# both list 6.3), pick the NEWEST PT — that's the upstream "latest stable
# pairing" intent.
#
# Patch tags ('M.m.p') reflect the maintainer's stated "valid versions
# at this time": 2.6.0, 2.7.1, 2.8.0, 2.9.1, 2.10.0, 2.11.0, 2.12.0.
# 2.5.0 / 2.4.0 / 2.3.0 use .0 since no patch was specified.
#
# Off-table ROCm: rocm < 5.7 -> 2.3.0 (oldest known); rocm > 7.x not
# explicitly listed -> 2.12.0 (newest known). Both branches print the
# normal "Manifest cell missing" warning further downstream so the user
# is reminded to validate.
default_pytorch_version_for_rocm() {
   local rocm_mm="$1"
   case "${rocm_mm}" in
      5.7)                                  echo "2.3.0"  ;;
      6.0)                                  echo "2.4.0"  ;;
      6.1)                                  echo "2.5.0"  ;;
      6.2)                                  echo "2.6.0"  ;;
      6.3|6.4|6.5|6.6|6.7|6.8|6.9|7.0)      echo "2.8.0"  ;;
      7.1)                                  echo "2.10.0" ;;
      7.2)                                  echo "2.11.0" ;;
      7.3|7.4|7.5|7.6|7.7|7.8|7.9)          echo "2.12.0" ;;
      # Off-table guards: too-old / too-new ROCm. Empty stdout means
      # "I don't know" and the resolver keeps the file-default (2.9.1).
      *)                                    echo ""       ;;
   esac
}

# ── AOTriton CMake flags keyed off AOTRITON_VERSION (not PT) ──────────
# AOTriton's CMake API changed between releases:
#   * 0.11.2b+: new -DAOTRITON_TARGET_ARCH/-DAOTRITON_OVERRIDE_TARGET_GPUS
#               + -DAOTRITON_USE_TORCH=0 (skip torch as a build dep -- the
#               aotriton SDK is what we're producing FOR torch; the cyclic
#               dependency in the build was resolved upstream by carving
#               out a torch-free build path).
#   * 0.10b/0.11b: new -DAOTRITON_TARGET_ARCH/-DAOTRITON_OVERRIDE_TARGET_GPUS
#               (no USE_TORCH yet; the build still wants torch as input).
#   * 0.9.2b and older: legacy -DTARGET_GPUS only.
# Keying off AOTRITON_VERSION (not PT) means the user can pass
# --aotriton-version 0.11.2b on PT 2.7/2.8 and the right CMake API gets
# selected, even though the canonical PT-major.minor pairing would have
# picked an older AOTriton.
#
# AMDGPU_GFXMODEL and AMDGPU_GFXMODEL_MOD0 must be set in the caller's
# scope before invoking this; same for TARGET_GPUS (used only by the
# legacy branch).
resolve_aotriton_extra_cmake_flags() {
   local av="$1"
   case "${av}" in
      0.11.2b|0.11.3b|0.11.4b|0.12*|0.13*)
         echo "-DAOTRITON_TARGET_ARCH=${AMDGPU_GFXMODEL} -DAOTRITON_OVERRIDE_TARGET_GPUS=${AMDGPU_GFXMODEL_MOD0} -DAOTRITON_USE_TORCH=0"
         ;;
      0.10b|0.10.1b|0.11b)
         echo "-DAOTRITON_TARGET_ARCH=${AMDGPU_GFXMODEL} -DAOTRITON_OVERRIDE_TARGET_GPUS=${AMDGPU_GFXMODEL_MOD0}"
         ;;
      *)
         echo "-DTARGET_GPUS=${TARGET_GPUS}"
         ;;
   esac
}

# ── Whole-stack resolver: walks user > manifest > PT-fallback > defaults ──
# Inputs (globals): PYTORCH_VERSION, ROCM_VERSION, plus all
#   <PIN>_VERSION + <PIN>_VERSION_USER_SET globals seeded near the top
#   of this script and updated by the arg parser.
# Outputs (globals): every <PIN>_VERSION is set to its resolved value;
#   every <PIN>_VERSION_SOURCE is set to a human-readable attribution
#   string (used by _print_pytorch_stack_audit_table). PT_MAJOR_MINOR,
#   ROCM_MAJOR_MINOR, MANIFEST_CELL_KEY, MANIFEST_CELL_HIT (0|1) are
#   also exported so the audit print can reuse them.
# Side effect: prints the audit table to stdout via
#   _print_pytorch_stack_audit_table.
# Idempotent: re-running just rewrites globals to the same values.
resolve_pytorch_stack_versions() {
   ROCM_MAJOR_MINOR=$(echo "${ROCM_VERSION}" | cut -f1-2 -d'.')

   # Auto-derive PYTORCH_VERSION from the loaded ROCm if the user didn't
   # pass --pytorch-version. The mapping is in
   # default_pytorch_version_for_rocm() (defined above). User flag wins
   # (PYTORCH_VERSION_USER_SET=1 short-circuits this branch); off-table
   # ROCm leaves the file-default 2.9.1 untouched.
   if [[ "${PYTORCH_VERSION_USER_SET}" -eq 1 ]]; then
      PYTORCH_VERSION_SOURCE="user --pytorch-version"
   else
      local _pt_default
      _pt_default=$(default_pytorch_version_for_rocm "${ROCM_MAJOR_MINOR}")
      if [[ -n "${_pt_default}" ]]; then
         PYTORCH_VERSION="${_pt_default}"
         PYTORCH_VERSION_SOURCE="auto-derived from ROCm ${ROCM_MAJOR_MINOR} (default_pytorch_version_for_rocm -> ${PYTORCH_VERSION})"
      else
         PYTORCH_VERSION_SOURCE="file default (no auto-derive row for ROCm ${ROCM_MAJOR_MINOR})"
      fi
   fi

   PT_MAJOR_MINOR=$(echo "${PYTORCH_VERSION}" | cut -f1-2 -d'.')
   # PYTORCH_SHORT_VERSION is the legacy name for the same value
   # (PT_MAJOR_MINOR was introduced later by the manifest plumbing).
   # Four pre-existing gates in this script reference PYTORCH_SHORT_VERSION
   # but the variable was NEVER assigned anywhere in the repo (silent
   # latent bug; verified with `grep -rE 'PYTORCH_SHORT_VERSION\s*=' .`).
   # Concrete consequences for the 2026-05-13 overnight sweep:
   #   pytorch_setup.sh:2016  USE_FBGEMM_GENAI=0 kill-switch never fired
   #                          -> PT 2.9.1 on ROCm 7.x hit
   #                          third_party/fbgemm/external/composable_kernel/
   #                          include/ck/utility/get_id.hpp:10: error:
   #                          constexpr function never produces a constant
   #                          expression
   #                          (slurm-9332 + slurm-9333, both PT 2.9.1 leaves)
   #   pytorch_setup.sh:2241  PT 2.4 jit/ir/ir.cpp USE_ROCM workaround dead
   #   pytorch_setup.sh:2251  PT 2.9 third_party CMakeLists 3.5-bump dead
   #   pytorch_setup.sh:2314  PT 2.9 pip-redirect install COPY dead, so
   #                          torch wheel never lands in
   #                          ${PYTORCH_PATH}/lib/python3.X/site-packages
   #                          -> "hollow install": script returns rc=0 and
   #                          writes the modulefile, but the install tree's
   #                          pytorch/ subdir is an empty 4 KB stub. First
   #                          observed in 9334 PT 2.9.1 on ROCm 6.4.3 last
   #                          night (only build of the sweep that didn't
   #                          hit one of the upstream build failures and
   #                          therefore exposed this latent paper-PASS).
   # All four gates expect the major.minor form ("2.4", "2.9", ...), which
   # is exactly what PT_MAJOR_MINOR holds, so the fix is one assignment.
   PYTORCH_SHORT_VERSION="${PT_MAJOR_MINOR}"
   MANIFEST_CELL_KEY="${PT_MAJOR_MINOR}|${ROCM_MAJOR_MINOR}"

   #   - AOTriton 0.9.2b bundles Triton 3.2.0, which emits HSA
   #     code-object metadata with an "abi version" field that
   #     Ubuntu jammy's stock /usr/bin/ld.lld (LLVM 14) rejects:
   #         ld.lld: error: unknown abi version:
   #     The same .hsaco loads cleanly through ROCm-bundled
   #     ld.lld 19+ (in every rocm-X.Y.Z/llvm/bin we ship).
   #
   #   - Triton 3.2.0's path_to_rocm_lld() (cited verbatim in
   #     this commit's audit notes; see
   #     third_party/triton bda2acff, file
   #     third_party/amd/backend/compiler.py:172) walks an
   #     ordered list: $TRITON_HIP_LLD_PATH first, then
   #     <wheel>/triton/backends/amd/llvm/bin/ld.lld, then
   #     /opt/rocm/llvm/bin/ld.lld (hardcoded), then
   #     /usr/bin/ld.lld, then raise. We do not deploy /opt/rocm
   #     (warewulf imaging made that symlink different per node;
   #     operator removed it ~2026-04-22). Without the env
   #     override, Triton falls all the way to the system LLD 14
   #     and dies.
   #
   # Fix landed in the AOTriton build region of this script
   # (search "TRITON_HIP_LLD_PATH"): we now export
   #     TRITON_HIP_LLD_PATH="${ROCM_PATH}/llvm/bin/ld.lld"
   # before the AOTriton clone/cmake/ninja steps and validate
   # the file exists. That pins kernel codegen to the
   # ROCm-bundled LLD 19, which accepts Triton 3.2.0's
   # HSA metadata. With this in place the canonical pairing
   # holds end-to-end:
   #   PT 2.7.x -> AOTriton 0.9.2b -> mha_all_aot.hip compiles
   #               cleanly (no #error trip)
   #   PT 2.8.x -> AOTriton 0.10b  -> same logic; same fix
   #

   local cell_value="${PYTORCH_STACK_MANIFEST[${MANIFEST_CELL_KEY}]:-}"
   if [[ -n "${cell_value}" ]]; then
      MANIFEST_CELL_HIT=1
   else
      MANIFEST_CELL_HIT=0
   fi

   # Parse cell into per-pin manifest_<pin> locals. Format: ";"-separated
   # "key=value" records; an unrecognised key is a non-fatal warning so
   # the manifest can grow new pins without breaking older sweeps that
   # haven't been redeployed.
   local manifest_aotriton="" manifest_torchvision="" manifest_torchaudio="" \
         manifest_triton="" manifest_flashattention="" manifest_pillow="" \
         manifest_sageattention="" manifest_deepspeed=""
   if [[ ${MANIFEST_CELL_HIT} -eq 1 ]]; then
      local _kvs _kv _k _v
      IFS=';' read -ra _kvs <<< "${cell_value}"
      for _kv in "${_kvs[@]}"; do
         [[ -z "${_kv}" ]] && continue
         if [[ "${_kv}" != *"="* ]]; then
            echo "ERROR: corrupt PYTORCH_STACK_MANIFEST cell '${MANIFEST_CELL_KEY}' (entry '${_kv}' missing '=')" >&2
            exit 1
         fi
         _k="${_kv%%=*}"
         _v="${_kv#*=}"
         case "${_k}" in
            aotriton)       manifest_aotriton="${_v}"       ;;
            torchvision)    manifest_torchvision="${_v}"    ;;
            torchaudio)     manifest_torchaudio="${_v}"     ;;
            triton)         manifest_triton="${_v}"         ;;
            flashattention) manifest_flashattention="${_v}" ;;
            pillow)         manifest_pillow="${_v}"         ;;
            sageattention) manifest_sageattention="${_v}"   ;;
            deepspeed)      manifest_deepspeed="${_v}"      ;;
            *) echo "WARNING: unknown key '${_k}' in PYTORCH_STACK_MANIFEST cell '${MANIFEST_CELL_KEY}'; ignoring" ;;
         esac
      done
   fi

   # PYTORCH_VERSION + PYTORCH_VERSION_SOURCE are already populated above
   # (auto-derive from ROCm OR user --pytorch-version OR file default).
   # The audit table prints whichever attribution applied. PT version is
   # the LOOKUP key for the manifest cell, not a field inside the cell,
   # so the manifest never overrides PT — only the per-pin pins below.

   # AOTRITON: user > manifest > PT-fallback > error.
   if [[ "${AOTRITON_VERSION_USER_SET}" -eq 1 ]]; then
      AOTRITON_VERSION_SOURCE="user --aotriton-version"
   elif [[ -n "${manifest_aotriton}" ]]; then
      AOTRITON_VERSION="${manifest_aotriton}"
      AOTRITON_VERSION_SOURCE="manifest cell '${MANIFEST_CELL_KEY}'"
   else
      AOTRITON_VERSION=$(resolve_aotriton_for_pt_only "${PT_MAJOR_MINOR}")
      if [[ -z "${AOTRITON_VERSION}" ]]; then
         echo "ERROR: No AOTriton release known for PyTorch ${PYTORCH_VERSION} (major.minor ${PT_MAJOR_MINOR})." >&2
         echo "       Either add a row to PYTORCH_STACK_MANIFEST for cell '${MANIFEST_CELL_KEY}'" >&2
         echo "       (near the top of pytorch_setup.sh), or pass --aotriton-version explicitly." >&2
         echo "       Upstream AOTriton releases: https://github.com/ROCm/aotriton/releases" >&2
         exit 1
      fi
      AOTRITON_VERSION_SOURCE="PT-only fallback (resolve_aotriton_for_pt_only ${PT_MAJOR_MINOR} -> ${AOTRITON_VERSION})"
   fi

   # TORCHVISION: user > manifest > PYTORCH_COMPANION_VERSIONS > file default.
   if [[ "${TORCHVISION_VERSION_USER_SET}" -eq 1 ]]; then
      TORCHVISION_VERSION_SOURCE="user --torchvision-version"
   elif [[ -n "${manifest_torchvision}" ]]; then
      TORCHVISION_VERSION="${manifest_torchvision}"
      TORCHVISION_VERSION_SOURCE="manifest cell '${MANIFEST_CELL_KEY}'"
   else
      local _row="${PYTORCH_COMPANION_VERSIONS[${PT_MAJOR_MINOR}]:-}"
      if [[ -n "${_row}" ]]; then
         TORCHVISION_VERSION="${_row%%:*}"
         TORCHVISION_VERSION_SOURCE="PT-only fallback (PYTORCH_COMPANION_VERSIONS '${PT_MAJOR_MINOR}')"
      else
         TORCHVISION_VERSION_SOURCE="file default (no companion row for PT ${PT_MAJOR_MINOR})"
      fi
   fi

   # TORCHAUDIO: same pattern as torchvision but reads the second
   # colon-separated field of the companion row.
   if [[ "${TORCHAUDIO_VERSION_USER_SET}" -eq 1 ]]; then
      TORCHAUDIO_VERSION_SOURCE="user --torchaudio-version"
   elif [[ -n "${manifest_torchaudio}" ]]; then
      TORCHAUDIO_VERSION="${manifest_torchaudio}"
      TORCHAUDIO_VERSION_SOURCE="manifest cell '${MANIFEST_CELL_KEY}'"
   else
      local _row2="${PYTORCH_COMPANION_VERSIONS[${PT_MAJOR_MINOR}]:-}"
      if [[ -n "${_row2}" ]]; then
         TORCHAUDIO_VERSION="${_row2#*:}"
         TORCHAUDIO_VERSION_SOURCE="PT-only fallback (PYTORCH_COMPANION_VERSIONS '${PT_MAJOR_MINOR}')"
      else
         TORCHAUDIO_VERSION_SOURCE="file default (no companion row for PT ${PT_MAJOR_MINOR})"
      fi
   fi

   # TRITON / FLASHATTENTION / PILLOW / SAGEATTENTION / DEEPSPEED: user
   # > manifest > file default (no PT-only fallback table for these --
   # they're either pinned per-cell or the file default is reasonable).
   if [[ "${TRITON_VERSION_USER_SET}" -eq 1 ]]; then
      TRITON_VERSION_SOURCE="user --triton-version"
   elif [[ -n "${manifest_triton}" ]]; then
      TRITON_VERSION="${manifest_triton}"
      TRITON_VERSION_SOURCE="manifest cell '${MANIFEST_CELL_KEY}'"
   else
      TRITON_VERSION_SOURCE="file default"
   fi

   if [[ "${FLASHATTENTION_VERSION_USER_SET}" -eq 1 ]]; then
      FLASHATTENTION_VERSION_SOURCE="user --flashattention-version"
   elif [[ -n "${manifest_flashattention}" ]]; then
      FLASHATTENTION_VERSION="${manifest_flashattention}"
      FLASHATTENTION_VERSION_SOURCE="manifest cell '${MANIFEST_CELL_KEY}'"
   else
      FLASHATTENTION_VERSION_SOURCE="file default"
   fi

   if [[ "${PILLOW_VERSION_USER_SET}" -eq 1 ]]; then
      PILLOW_VERSION_SOURCE="user --pillow-version"
   elif [[ -n "${manifest_pillow}" ]]; then
      PILLOW_VERSION="${manifest_pillow}"
      PILLOW_VERSION_SOURCE="manifest cell '${MANIFEST_CELL_KEY}'"
   else
      PILLOW_VERSION_SOURCE="file default"
   fi

   if [[ "${SAGEATTENTION_VERSION_USER_SET}" -eq 1 ]]; then
      SAGEATTENTION_VERSION_SOURCE="user --sageattention-version"
   elif [[ -n "${manifest_sageattention}" ]]; then
      SAGEATTENTION_VERSION="${manifest_sageattention}"
      SAGEATTENTION_VERSION_SOURCE="manifest cell '${MANIFEST_CELL_KEY}'"
   else
      SAGEATTENTION_VERSION_SOURCE="file default"
   fi

   if [[ "${DEEPSPEED_VERSION_USER_SET}" -eq 1 ]]; then
      DEEPSPEED_VERSION_SOURCE="user --deepspeed-version"
   elif [[ -n "${manifest_deepspeed}" ]]; then
      DEEPSPEED_VERSION="${manifest_deepspeed}"
      DEEPSPEED_VERSION_SOURCE="manifest cell '${MANIFEST_CELL_KEY}'"
   else
      DEEPSPEED_VERSION_SOURCE="file default"
   fi

   # Export manifest values as globals so compute_pytorch_install_suffix
   # (defined below) can compare user-overridden values against the
   # canonical manifest pin and only emit a suffix on actual divergence.
   # Only the curated-set keys (aotriton, triton, flashattention) need to
   # leak out; the other pins use the canonical install path regardless.
   # Empty value means "manifest had no opinion" — any user-set value is
   # treated as a divergence from canonical (suffix emitted).
   MANIFEST_AOTRITON="${manifest_aotriton}"
   MANIFEST_TRITON="${manifest_triton}"
   MANIFEST_FLASHATTENTION="${manifest_flashattention}"

   _print_pytorch_stack_audit_table
}

# ── Audit table: source attribution per pin (FACT/INFERENCE discipline) ──
# Printed once by resolve_pytorch_stack_versions. Format mirrors the
# Installation Configuration Summary used in main_setup.sh -- 80-col
# rule, two columns "name value [source]".
_print_pytorch_stack_audit_table() {
   local cell_status
   if [[ ${MANIFEST_CELL_HIT} -eq 1 ]]; then
      cell_status="HIT"
   else
      cell_status="MISSING -> PT-only fallback for AOTriton + companions"
   fi
   echo
   echo "======================================================"
   echo "  Resolved PyTorch stack versions"
   echo "    PyTorch:        ${PYTORCH_VERSION} (major.minor ${PT_MAJOR_MINOR})"
   echo "    ROCm:           ${ROCM_VERSION} (major.minor ${ROCM_MAJOR_MINOR})"
   echo "    Manifest cell:  ${MANIFEST_CELL_KEY} [${cell_status}]"
   echo "======================================================"
   printf "  %-16s %-20s [%s]\n" "pytorch"        "${PYTORCH_VERSION}"        "${PYTORCH_VERSION_SOURCE}"
   printf "  %-16s %-20s [%s]\n" "aotriton"       "${AOTRITON_VERSION}"       "${AOTRITON_VERSION_SOURCE}"
   printf "  %-16s %-20s [%s]\n" "torchvision"    "${TORCHVISION_VERSION}"    "${TORCHVISION_VERSION_SOURCE}"
   printf "  %-16s %-20s [%s]\n" "torchaudio"     "${TORCHAUDIO_VERSION}"     "${TORCHAUDIO_VERSION_SOURCE}"
   printf "  %-16s %-20s [%s]\n" "triton"         "${TRITON_VERSION}"         "${TRITON_VERSION_SOURCE}"
   printf "  %-16s %-20s [%s]\n" "flashattention" "${FLASHATTENTION_VERSION}" "${FLASHATTENTION_VERSION_SOURCE}"
   printf "  %-16s %-20s [%s]\n" "pillow"         "${PILLOW_VERSION}"         "${PILLOW_VERSION_SOURCE}"
   printf "  %-16s %-20s [%s]\n" "sageattention"  "${SAGEATTENTION_VERSION}"  "${SAGEATTENTION_VERSION_SOURCE}"
   printf "  %-16s %-20s [%s]\n" "deepspeed"      "${DEEPSPEED_VERSION}"      "${DEEPSPEED_VERSION_SOURCE}"
   echo "======================================================"
   if [[ ${MANIFEST_CELL_HIT} -eq 0 ]]; then
      echo "  WARNING: no PYTORCH_STACK_MANIFEST cell for '${MANIFEST_CELL_KEY}'."
      echo "  Build is proceeding with leniency: AOTriton from PT-only table,"
      echo "  companions (torchvision/torchaudio) from PYTORCH_COMPANION_VERSIONS,"
      echo "  remainder from file defaults. Pass --aotriton-version /"
      echo "  --triton-version / etc. to pin specific versions, or add a row"
      echo "  to PYTORCH_STACK_MANIFEST near the top of pytorch_setup.sh once"
      echo "  this combination is validated."
      echo "======================================================"
   fi
   echo
}

# ── Variant-suffix builder for INSTALL_PATH / modulefile name ─────────
# Modelled on the openmpi naming convention
# (openmpi-5.0.10-ucc-1.6.0-ucx-1.19.1-xpmem-2.7.4): emit a "-key-value"
# segment per build-time-linked dep that the user overrode AWAY from the
# canonical manifest pin. Lets multiple variants of the same PT version
# coexist on disk, e.g.
#   pytorch=2.8.0                     -> pytorch-v2.8.0
#   pytorch=2.8.0:aotriton=0.10b      -> pytorch-v2.8.0-aotriton-0.10b
#                                        (when manifest cell pins 0.11.2b)
#   pytorch=2.8.0:aotriton=0.11.2b    -> pytorch-v2.8.0
#                                        (matches manifest, no divergence)
#
# Curated set: aotriton, triton, flashattention. These are the linked-
# in-at-build-time deps that materially change runtime behavior (SDPA
# performance, codegen backend, attention impl) — the PyTorch analogues
# of openmpi's ucc/ucx/xpmem. Excluded:
#   * pillow / sageattention / deepspeed: peripheral.
#   * torchvision / torchaudio: tightly version-coupled to PT core; a
#     standalone override is rare and the resolver auto-derives them
#     from PT version anyway.
# Extending the set later means adding a stanza below AND making sure
# the new dep's _USER_SET sentinel + MANIFEST_<KEY> global are wired up
# in resolve_pytorch_stack_versions.
#
# Divergence rule: emit a suffix segment iff the user passed the flag
# (*_VERSION_USER_SET=1) AND the resulting *_VERSION differs from the
# manifest cell value (MANIFEST_<KEY>). Empty MANIFEST_<KEY> (cell
# missed or pin not in cell) counts as divergence — without a manifest
# value to compare to, "user passed it" implies "user knows what they
# want", so we encode it. Order is alphabetical (aotriton, flash, triton)
# so suffixes are stable across runs and easy to grep for.
#
# Returns the suffix on stdout (empty string for the canonical case).
# Caller uses it as ${PYTORCH_VERSION}${PYTORCH_INSTALL_SUFFIX}.
compute_pytorch_install_suffix() {
   local suffix=""
   if [[ "${AOTRITON_VERSION_USER_SET}" -eq 1 ]] \
      && [[ "${AOTRITON_VERSION}" != "${MANIFEST_AOTRITON}" ]]; then
      suffix+="-aotriton-${AOTRITON_VERSION}"
   fi
   if [[ "${FLASHATTENTION_VERSION_USER_SET}" -eq 1 ]] \
      && [[ "${FLASHATTENTION_VERSION}" != "${MANIFEST_FLASHATTENTION}" ]]; then
      suffix+="-flashattention-${FLASHATTENTION_VERSION}"
   fi
   if [[ "${TRITON_VERSION_USER_SET}" -eq 1 ]] \
      && [[ "${TRITON_VERSION}" != "${MANIFEST_TRITON}" ]]; then
      suffix+="-triton-${TRITON_VERSION}"
   fi
   echo "${suffix}"
}

MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/pytorch
# Versioned install root: /opt/rocmplus-X/pytorch-v${PYTORCH_VERSION}.
# All companion subdirs (vision, audio, triton, aotriton, transformers,
# flashattention, sageattention, deepspeed) live UNDER this root, so
# versioning the parent dir versions the whole stack and lets multiple
# pytorch releases coexist.
INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/pytorch-v${PYTORCH_VERSION}
INSTALL_PATH_INPUT=""
# --install-path: parent dir; the script appends pytorch-v${PYTORCH_VERSION}
# itself. Used by main_setup.sh so the orchestrator never has to know
# the version. --install-path-no-version (full leaf dir) wins over --install-path
# when both are set, for callers that need exact control of the final install directory.
ROCMPLUS_PATH_INPUT=""
MPI_MODULE="openmpi"
SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"
USE_WHEEL=0
DEBUG=0
# pytorch + all its companion packages (aotriton, triton, vision, audio,
# transformers, flashattention, sageattention, deepspeed) are installed
# as subdirectories under one ${INSTALL_PATH} root, so a single
# --replace flag cleans the whole stack. Two modulefiles get written:
# ${PYTORCH_VERSION}${PYTORCH_INSTALL_SUFFIX}.lua and ${PYTORCH_VERSION}${PYTORCH_INSTALL_SUFFIX}_tunableop_enabled.lua.
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup. See hypre_setup.sh.
REPLACE=0
KEEP_FAILED_INSTALLS=0

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

RHEL_COMPATIBLE=0
if [[ "${DISTRO}" = "red hat enterprise linux" || "${DISTRO}" == *"rocky"* || "${DISTRO}" == "almalinux" ]]; then
   RHEL_COMPATIBLE=1
fi


if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path-no-version and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "--amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default is autodetected"
   echo "--build-pytorch [ BUILD_PYTORCH ] set to 1 to build jax default is 0"
   echo "--pytorch-version [ PYTORCH_VERSION ] version of PyTorch."
   echo "    Default is auto-derived from the loaded ROCm major.minor by"
   echo "    default_pytorch_version_for_rocm() (see top of this script). Mapping:"
   echo "      ROCm 5.7         -> PT 2.3.0   (PT-only fallback, AOTriton 0.4b)"
   echo "      ROCm 6.0         -> PT 2.4.0   (PT-only fallback, AOTriton 0.6b)"
   echo "      ROCm 6.1         -> PT 2.5.0   (PT-only fallback, AOTriton 0.7b)"
   echo "      ROCm 6.2         -> PT 2.6.0   (PT-only fallback, AOTriton 0.8b)"
   echo "      ROCm 6.3 - 7.0   -> PT 2.8.0   (validated: '2.8|6.3' '2.8|6.4'; AOTriton 0.10b)"
   echo "      ROCm 7.1         -> PT 2.10.0  (PT-only fallback, AOTriton 0.11.2b)"
   echo "      ROCm 7.2         -> PT 2.11.0  (PT-only fallback, AOTriton 0.12b)"
   echo "      ROCm 7.3+        -> PT 2.12.0  (PT-only fallback, AOTriton 0.13b — Experimental)"
   echo "      anything else    -> file default ${PYTORCH_VERSION} (last-resort)"
   echo "    Pass --pytorch-version VER to override the auto-derive. Recognised explicit values:"
   echo "      2.3.0  2.4.0  2.5.0  2.6.0  2.7.1  2.8.0  2.9.1  2.10.0  2.11.0  2.12.0"
   echo "    Validated (manifest cell) (PT, ROCm) combinations — bare-default sweeps land on these:"
   echo "      '2.7|6.2'  '2.7|6.3'  '2.7|6.4'  '2.7|7.1'"
   echo "      '2.8|6.3'  '2.8|6.4'  '2.8|7.1'"
   echo "      '2.9|7.0'  '2.9|7.1'  '2.9|7.2'"
   echo "    Off-table (PT, ROCm) combos warn and fall back to the PT-only AOTriton table; the"
   echo "    build still proceeds. Setting --pytorch-version also auto-derives --torchvision-version"
   echo "    and --torchaudio-version from PYTORCH_COMPANION_VERSIONS by major.minor (e.g. 2.9.1 -> '2.9'"
   echo "    row). Pass either of those flags explicitly to override."
   echo "--torchvision-version [ TORCHVISION_VERSION ] version of torchvision."
   echo "    Default is auto-derived from PYTORCH_VERSION's major.minor row in PYTORCH_COMPANION_VERSIONS;"
   echo "    set this flag to pin a specific torchvision (e.g. for nightlies or off-table combinations)."
   echo "--torchaudio-version [ TORCHAUDIO_VERSION ] version of torchaudio."
   echo "    Default is auto-derived from PYTORCH_VERSION's major.minor row in PYTORCH_COMPANION_VERSIONS;"
   echo "    set this flag to pin a specific torchaudio. Pairs cleanly with --torchvision-version."
   echo "--aotriton-version [ AOTRITON_VERSION ] AOTriton release tag (e.g. 0.10b, 0.11.2b)."
   echo "    Default: PYTORCH_STACK_MANIFEST cell hit if (PT major.minor, ROCm major.minor) is in"
   echo "    the manifest, else resolve_aotriton_for_pt_only() (the canonical PT->AOTriton table)."
   echo "    Override to try a newer AOTriton on an older PyTorch (e.g. AOTriton 0.11.2b on PT 2.8"
   echo "    if the canonical AOTriton 0.10b's bundled triton 3.2.0 fails on the host's lld)."
   echo "--triton-version [ TRITON_VERSION ] post-build triton wheel version (default $TRITON_VERSION)."
   echo "    This is the standalone triton installed via 'pip install triton==VER' AFTER pytorch is"
   echo "    built, NOT the triton vendored inside aotriton (which is implicit via --aotriton-version)."
   echo "--flashattention-version [ FLASHATTENTION_VERSION ] flash-attention release tag (default $FLASHATTENTION_VERSION)."
   echo "--pillow-version [ PILLOW_VERSION ] Pillow version (default $PILLOW_VERSION)."
   echo "--sageattention-version [ SAGEATTENTION_VERSION ] SageAttention version (default $SAGEATTENTION_VERSION)."
   echo "--deepspeed-version [ DEEPSPEED_VERSION ] DeepSpeed version (default $DEEPSPEED_VERSION; 'latest' = unpinned)."
   echo ""
   echo "  Resolution priority for every pin above (highest first):"
   echo "    1. user CLI flag (e.g. --aotriton-version)"
   echo "    2. PYTORCH_STACK_MANIFEST cell '\${PT_MM}|\${ROCM_MM}' (e.g. '2.9|7.1')"
   echo "    3. PT-only fallback (resolve_aotriton_for_pt_only / PYTORCH_COMPANION_VERSIONS)"
   echo "    4. file-default constant near the top of this script"
   echo "  resolve_pytorch_stack_versions runs after the arg parser and prints an audit table"
   echo "  attributing each resolved value to its source. Off-table (PT, ROCm) combinations"
   echo "  trigger a warning + per-pin fallback (lenient: build proceeds, user can pin via flags)."
   echo ""
   echo "--python-version [ PYTHON_VERSION ] version of Python, default is $PYTHON_VERSION"
   echo "--install-path-no-version [ INSTALL_PATH ] directory where PyTorch, Torchaudio and Torchvision will be installed, default is $INSTALL_PATH"
   echo "--install-path [ ROCMPLUS_PATH_INPUT ] parent dir; if set (and --install-path-no-version is not), INSTALL_PATH ="
   echo "    ROCMPLUS_PATH/pytorch-v\${PYTORCH_VERSION}\${PYTORCH_INSTALL_SUFFIX}, where the suffix is empty for"
   echo "    canonical (manifest-pinned) builds and -aotriton-X-flashattention-Y-triton-Z when an inline override"
   echo "    diverges from the manifest cell. Lets variants coexist on disk (modeled on openmpi naming)."
   echo "--mpi-module [ MPI_MODULE ] mpi module to build pytorch with, default is $MPI_MODULE"
   echo "--help: this usage information"
   echo "--module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "--rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "--use-wheel [ USE_WHEEL ] build with a wheel instead of from source, default is $USE_WHEEL"
   echo "--replace [ 0|1 ] remove prior pytorch+companion installs and modulefiles before building, default $REPLACE"
   echo "--keep-failed-installs [ 0|1 ] skip EXIT-trap cleanup of partial installs on failure, default $KEEP_FAILED_INSTALLS"
   exit 1
}

send-error()
{
    usage
    echo -e "\nError: ${@}"
    exit 1
}

reset-last()
{
   last() { send-error "Unsupported argument :: ${1}"; }
}

# ── HIP bf16 host-compat patch for therock-23.2.0+ (SDK header fixup) ────
# Why this exists:
#   amd_hip_bf16.h on rocm-therock-23.2.0 (and by inference rocm 7.3+) uses
#   the bare `__bf16` keyword unconditionally at namespace scope:
#     line 136:  static_assert(sizeof(__bf16) == sizeof(unsigned short));
#     line 167:  __bf16 __x_bf16;            (struct __hip_bfloat16 member)
#     line 1312+: 13 host-fallback __hmax/__hmin/__hlt... bodies casting
#                 (__bf16)a > (__bf16)b ...
#   `__bf16` is a clang/amdclang/hipcc built-in. gcc-13 added it for x86
#   under `-mavx512bf16`; gcc-11 (Ubuntu 22.04 default, what /usr/bin/c++
#   resolves to here) has no concept of it.
#
#   On rocm-7.0.0 ... 7.2.1 g++ never reached this header because the
#   public hipblaslt-types.h didn't pull in <hip/hip_bf16.h>. On
#   therock-23.2.0 the new hipblaslt_e5m3.h:30 unconditionally drags
#   <hip/hip_bf16.h> in, exposing the latent bug to every host-side TU
#   that includes <hipblaslt/hipblaslt.h>.
#
#   PyTorch's torch_hip target builds 5 such TUs as plain CXX (host
#   compiler with HIP headers visible -- intentional, see L929-942
#   amdclang firewall): HIPBlas.cpp, HIPSparseBlas.cpp, Blas.cpp,
#   SparseHIPBlas.cpp, SparseBlasImpl.cpp. All five fail identically at
#   ninja step ~7300/7920 with the __bf16 errors above (slurm 8225,
#   2026-05-05, rocm-therock-23.2.0).
#
# What the fix does:
#   Three coordinated edits, all gated on the sentinel macro
#   __HPCTRAINING_BF16_GUARD_DEFINED so amdclang/hipcc/gcc-13+ see no
#   source change at all (the macro is only defined when __bf16 is not
#   a built-in type):
#
#   1. Right after the include guard, insert a `typedef unsigned short
#      __bf16` fallback. sizeof(unsigned short) == 2 == sizeof(__bf16)
#      so `static_assert(sizeof(__bf16) == sizeof(unsigned short))` at
#      line 136 holds, and the `__bf16 __x_bf16` struct member at
#      line 167 becomes a 2-byte unsigned short field.
#
#   2. Wrap `__hip_bfloat16(const __bf16 val) : __x_bf16(val) {}`
#      (line 201 in stock therock-23.2.0) in
#      `#if !defined(__HPCTRAINING_BF16_GUARD_DEFINED) ... #endif`.
#      Reason: when the typedef makes `__bf16 == unsigned short`, this
#      ctor becomes a duplicate of the `__hip_bfloat16(unsigned short)`
#      ctor at line 186. Skipping the redundant declaration eliminates
#      the gcc "cannot be overloaded" error.
#
#   3. Wrap `operator __bf16() const { return __x_bf16; }` (line 261)
#      in the same sentinel guard. Same reason: it duplicates the
#      `operator unsigned short() const` at line 257.
#
#   Casts (`static_cast<__bf16>(val)`) and arithmetic in the inline
#   __hmax/__hmin/__hlt/... fallback functions become unsigned-short
#   ops -- semantically wrong for true bf16 -- but pytorch's host TUs
#   only need the type for ABI/layout (they call hipblaslt host APIs,
#   no bf16 arithmetic). The device-side bf16 builtins live inside
#   pre-existing `#if defined(__clang__) && defined(__HIP__)` blocks
#   (line 96, 322, 626, 844) so gcc never sees them.
#
# Why this is in pytorch_setup.sh:
#   PyTorch is the first known victim. Other packages on therock-23.2.0
#   that compile host TUs against <hipblaslt/...> with gcc would hit the
#   same wall -- if/when they do, the same one-shot SDK fixup helps them
#   too (SDK file persists once patched).
#
# Idempotency: the inserted block carries the sentinel
# `HPCTRAINING_BF16_GUARD_v1`. The function greps for it and exits
# early on a re-run. A `.hpctraining.bak` of the original file is kept
# next to the header for one-command revert.
patch_rocm_bf16_header_for_gcc()
{
   local hdr="${ROCM_PATH:-}/include/hip/amd_detail/amd_hip_bf16.h"
   if [ -z "${ROCM_PATH:-}" ] || [ ! -f "${hdr}" ]; then
      echo "pytorch: no ${hdr} -- skipping bf16 host-compat patch"
      return 0
   fi
   if grep -q 'HPCTRAINING_BF16_GUARD_v2' "${hdr}"; then
      echo "pytorch: ${hdr} already has HPCTRAINING_BF16_GUARD_v2 -- skipping"
      return 0
   fi
   if grep -q 'HPCTRAINING_BF16_GUARD_v1' "${hdr}"; then
      echo "pytorch: ${hdr} has stale HPCTRAINING_BF16_GUARD_v1 -- restoring from .hpctraining.bak so v2 can apply cleanly"
      if [ ! -f "${hdr}.hpctraining.bak" ]; then
         echo "pytorch: ERROR no ${hdr}.hpctraining.bak to restore from -- refusing to patch (manual revert needed)"
         return 1
      fi
      ${PKG_SUDO:-sudo} cp -p "${hdr}.hpctraining.bak" "${hdr}"
   fi
   if ! grep -q 'static_assert(sizeof(__bf16)' "${hdr}"; then
      echo "pytorch: ${hdr} has no bare __bf16 static_assert -- header has changed upstream, skipping (please re-audit)"
      return 0
   fi
   if ! grep -q '__hip_bfloat16(const __bf16 val) : __x_bf16(val) {}' "${hdr}"; then
      echo "pytorch: ${hdr} has no '__hip_bfloat16(const __bf16 val)' anchor -- header has changed upstream, skipping (please re-audit)"
      return 0
   fi
   if ! grep -q 'operator __bf16() const { return __x_bf16; }' "${hdr}"; then
      echo "pytorch: ${hdr} has no 'operator __bf16()' anchor -- header has changed upstream, skipping (please re-audit)"
      return 0
   fi
   echo "pytorch: patching ${hdr} with __bf16 typedef fallback + duplicate-overload guards for gcc<13 hosts (one-time, sentinel HPCTRAINING_BF16_GUARD_v2)"
   if [ ! -f "${hdr}.hpctraining.bak" ]; then
      ${PKG_SUDO:-sudo} cp -p "${hdr}" "${hdr}.hpctraining.bak"
   fi
   ${PKG_SUDO:-sudo} python3 - "${hdr}" <<'PY'
import sys
p = sys.argv[1]
src = open(p).read()
# 1. Insert typedef block after the include guard.
anchor1 = '#ifndef _HIP_INCLUDE_HIP_AMD_DETAIL_HIP_BF16_H_\n#define _HIP_INCLUDE_HIP_AMD_DETAIL_HIP_BF16_H_\n'
ins1 = (
'\n'
'/* HPCTRAINING_BF16_GUARD_v2: __bf16 fallback for non-clang/non-gcc-13+ hosts.\n'
'   Inserted by HPCTrainingDock pytorch_setup.sh patch_rocm_bf16_header_for_gcc().\n'
'   Restores host-side compile of TUs that include <hipblaslt/...> with gcc-11/12,\n'
'   which on therock-23.2.0+ now transitively pulls <hip/hip_bf16.h> via the new\n'
'   hipblaslt_e5m3.h chain. Clang/amdclang/hipcc/gcc>=13 see no source change. */\n'
'#if !defined(__clang__) && !(defined(__GNUC__) && __GNUC__ >= 13) \\\n'
'    && !defined(__HPCTRAINING_BF16_GUARD_DEFINED)\n'
'#define __HPCTRAINING_BF16_GUARD_DEFINED 1\n'
'typedef unsigned short __bf16;\n'
'#endif\n\n'
)
if anchor1 not in src:
    sys.stderr.write("amd_hip_bf16.h include-guard anchor not found; refusing to patch\n")
    sys.exit(2)
src = src.replace(anchor1, anchor1 + ins1, 1)

# 2. Gate the redundant __hip_bfloat16(__bf16) ctor.
anchor2 = '  __BF16_HOST_DEVICE__ __hip_bfloat16(const __bf16 val) : __x_bf16(val) {}\n'
guard2 = (
'#if !defined(__HPCTRAINING_BF16_GUARD_DEFINED)  /* HPCTRAINING_BF16_GUARD_v2: avoid duplicate of __hip_bfloat16(unsigned short) when __bf16==unsigned short */\n'
'  __BF16_HOST_DEVICE__ __hip_bfloat16(const __bf16 val) : __x_bf16(val) {}\n'
'#endif\n'
)
if src.count(anchor2) != 1:
    sys.stderr.write("amd_hip_bf16.h: __hip_bfloat16(const __bf16 val) anchor not unique; refusing to patch\n")
    sys.exit(3)
src = src.replace(anchor2, guard2, 1)

# 3. Gate the redundant operator __bf16().
anchor3 = '  __BF16_HOST_DEVICE__ operator __bf16() const { return __x_bf16; }\n'
guard3 = (
'#if !defined(__HPCTRAINING_BF16_GUARD_DEFINED)  /* HPCTRAINING_BF16_GUARD_v2: avoid duplicate of operator unsigned short() when __bf16==unsigned short */\n'
'  __BF16_HOST_DEVICE__ operator __bf16() const { return __x_bf16; }\n'
'#endif\n'
)
if src.count(anchor3) != 1:
    sys.stderr.write("amd_hip_bf16.h: operator __bf16() anchor not unique; refusing to patch\n")
    sys.exit(4)
src = src.replace(anchor3, guard3, 1)

open(p, 'w').write(src)
print("amd_hip_bf16.h patched: HPCTRAINING_BF16_GUARD_v2 (typedef + 2 overload guards) applied")
PY
   echo "pytorch: bf16 host-compat patch verify:"
   grep -nE 'HPCTRAINING_BF16_GUARD|typedef unsigned short __bf16' "${hdr}" | sed 's/^/    /'
   ls -la "${hdr}.hpctraining.bak" "${hdr}" | sed 's/^/    /'
}


n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
	  reset-last
          ;;
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
	  reset-last
          ;;
      "--build-pytorch")
          shift
          BUILD_PYTORCH=${1}
	  reset-last
          ;;
      "--help")
         usage
         ;;
      "--python-version")
          shift
          PYTHON_VERSION=${1}
	  reset-last
          ;;
      "--mpi-module")
          shift
          MPI_MODULE=${1}
	  reset-last
          ;;
      "--pytorch-version")
          shift
          PYTORCH_VERSION=${1}
          PYTORCH_VERSION_USER_SET=1
	  reset-last
          ;;
      "--torchvision-version")
          shift
          TORCHVISION_VERSION=${1}
          TORCHVISION_VERSION_USER_SET=1
          reset-last
          ;;
      "--torchaudio-version")
          shift
          TORCHAUDIO_VERSION=${1}
          TORCHAUDIO_VERSION_USER_SET=1
          reset-last
          ;;
      "--aotriton-version")
          shift
          AOTRITON_VERSION=${1}
          AOTRITON_VERSION_USER_SET=1
          reset-last
          ;;
      "--triton-version")
          shift
          TRITON_VERSION=${1}
          TRITON_VERSION_USER_SET=1
          reset-last
          ;;
      "--flashattention-version")
          shift
          FLASHATTENTION_VERSION=${1}
          FLASHATTENTION_VERSION_USER_SET=1
          reset-last
          ;;
      "--pillow-version")
          shift
          PILLOW_VERSION=${1}
          PILLOW_VERSION_USER_SET=1
          reset-last
          ;;
      "--sageattention-version")
          shift
          SAGEATTENTION_VERSION=${1}
          SAGEATTENTION_VERSION_USER_SET=1
          reset-last
          ;;
      "--deepspeed-version")
          shift
          DEEPSPEED_VERSION=${1}
          DEEPSPEED_VERSION_USER_SET=1
          reset-last
          ;;
      "--module-path")
          shift
          MODULE_PATH=${1}
	  reset-last
          ;;
      "--install-path-no-version")
          shift
          INSTALL_PATH_INPUT=${1}
	  reset-last
          ;;
      "--install-path")
          shift
          ROCMPLUS_PATH_INPUT=${1}
	  reset-last
          ;;
      "--use-wheel")
          shift
          USE_WHEEL=${1}
	  reset-last
          ;;
      "--replace")
          shift
          REPLACE=${1}
          reset-last
          ;;
      "--keep-failed-installs")
          shift
          KEEP_FAILED_INSTALLS=${1}
          reset-last
          ;;
      *)
         last ${1}
         ;;
   esac
   n=$((${n} + 1))
   shift
done

# ── Resolve every version pin in the PyTorch stack ────────────────────
# resolve_pytorch_stack_versions walks (highest priority first):
#   1. user CLI flag (e.g. --aotriton-version)         <PIN>_VERSION_USER_SET=1
#   2. manifest cell PYTORCH_STACK_MANIFEST[PT_MM|ROCm_MM]
#   3. PT-only fallback (resolve_aotriton_for_pt_only / PYTORCH_COMPANION_VERSIONS)
#   4. file-default constant near the top of this script
# and prints an audit table that attributes each pin to its source.
#
# Argument-order independence: this block runs AFTER the parser loop, so
# any combination of --pytorch-version / --rocm-version / --aotriton-version /
# --torchvision-version / etc. resolves to the same final state regardless
# of CLI ordering.
resolve_pytorch_stack_versions

# Variant-suffix from curated overrides (aotriton/triton/flashattention).
# Empty for canonical (manifest-pinned) builds; "-aotriton-X-..." when
# the user pinned a non-canonical value via :override or --flag. See
# compute_pytorch_install_suffix() above for the divergence rule.
PYTORCH_INSTALL_SUFFIX=$(compute_pytorch_install_suffix)
if [[ -n "${PYTORCH_INSTALL_SUFFIX}" ]]; then
   echo "[pytorch variant] override-driven install-suffix active: '${PYTORCH_INSTALL_SUFFIX}'"
   echo "[pytorch variant]   install dir + modulefile name will include this suffix so this"
   echo "[pytorch variant]   variant coexists with the canonical pytorch-v${PYTORCH_VERSION} build."
fi

if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   # --install-path-no-version: caller passed the FULL leaf dir, so it
   # already encodes whatever variant naming the caller wants. Leave
   # PYTORCH_INSTALL_SUFFIX out of this branch -- the caller is in
   # charge of disambiguation. (The modulefile naming further down
   # still uses ${PYTORCH_VERSION}${PYTORCH_INSTALL_SUFFIX}.lua because
   # those live under MODULE_PATH, which is independent.)
   INSTALL_PATH=${INSTALL_PATH_INPUT}
elif [ "${ROCMPLUS_PATH_INPUT}" != "" ]; then
   # Orchestrator-friendly: caller passes the rocmplus parent dir;
   # this script appends pytorch-v${PYTORCH_VERSION}${PYTORCH_INSTALL_SUFFIX}
   # from its own default. Lets main_setup.sh stay version-agnostic.
   INSTALL_PATH=${ROCMPLUS_PATH_INPUT}/pytorch-v${PYTORCH_VERSION}${PYTORCH_INSTALL_SUFFIX}
else
   # override path in case ROCM_VERSION or PYTORCH_VERSION has been supplied as input
   INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/pytorch-v${PYTORCH_VERSION}${PYTORCH_INSTALL_SUFFIX}
fi

TRANSFORMERS_PATH=$INSTALL_PATH/transformers
TRITON_PATH=$INSTALL_PATH/triton
SAGEATTENTION_PATH=$INSTALL_PATH/sageattention
FLASHATTENTION_PATH=$INSTALL_PATH/flashattention
AOTRITON_PATH=$INSTALL_PATH/aotriton
PYTORCH_PATH=$INSTALL_PATH/pytorch
TORCHVISION_PATH=$INSTALL_PATH/vision
TORCHAUDIO_PATH=$INSTALL_PATH/audio
DEEPSPEED_PATH=$INSTALL_PATH/deepspeed

# ── --replace + EXIT trap (see hypre_setup.sh for design) ────────────
# All companion subdirs live under ${INSTALL_PATH}, so a single rm -rf
# of the root cleans pytorch + aotriton + triton + vision + audio +
# transformers + flashattention + sageattention + deepspeed in one go.
# Two modulefiles need cleaning: ${PYTORCH_VERSION}${PYTORCH_INSTALL_SUFFIX}.lua and
# ${PYTORCH_VERSION}${PYTORCH_INSTALL_SUFFIX}_tunableop_enabled.lua.
# ── BUILD_PYTORCH=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_PYTORCH}" = "0" ]; then
   echo "[pytorch BUILD_PYTORCH=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

# ── afar SDK incompatibility detection ───────────────────────────────
# AMD's pre-release "AFAR" ROCm drops (rocm-afar-22.x, rocm-afar-7.0.5)
# are runtime-only / partial SDKs. Verified empirically on this cluster
# (audit_2026_05_06, job 8489, log_pytorch_05_06_2026.txt:46050-46089):
#
#   afar-22.2.0  $ ls <ROCM_PATH>/lib/libMIOpen*
#                -> No such file or directory
#   afar-22.2.0  $ cat <ROCM_PATH>/lib/cmake/miopen/miopen-targets-release.cmake
#                -> IMPORTED_LOCATION_RELEASE ".../lib/libMIOpen.so.1.0.70200"
#   rocm-7.2.1   $ ls <ROCM_PATH>/lib/libMIOpen*
#                -> libMIOpen.so, .so.1, .so.1.0.70201
#
# pytorch's cmake find_package(miopen) loads miopen-config.cmake (which
# IS present on afar) and then dies at the IMPORTED_LOCATION existence
# check on libMIOpen.so. Skipping here turns 8489-style FAILED pytorch
# (rc=1) into the correct SKIPPED(no-op) bucket and saves ~3.5h of
# CPU per afar sweep on a build that has no chance.
#
# Probe shape: gated on `${ROCM_PATH}` matching `*afar*` AND no
# libMIOpen.so* present. The runtime-library check exists so this
# block self-corrects if AMD ships a more complete afar drop later
# (matches the rocm-bundled hipfort policy in
# extras/scripts/hipfort_setup.sh).
if [[ "${ROCM_PATH:-}" == *afar* ]]; then
   if [[ -z "${ROCM_PATH:-}" ]] && type module >/dev/null 2>&1; then
      module load "rocm/${ROCM_VERSION}" 2>/dev/null || true
   fi
   if ! ls "${ROCM_PATH}"/lib/libMIOpen.so* >/dev/null 2>&1; then
      echo ""
      echo "[pytorch afar-skip] ROCM_PATH=${ROCM_PATH} is an AMD AFAR partial SDK"
      echo "                    missing : <ROCM_PATH>/lib/libMIOpen.so* (cmake config refs nonexistent .so)"
      echo "                    pytorch's find_package(miopen) requires the runtime lib; cannot build on afar SDK."
      echo "                    Skipping (no source build, no cache restore)."
      echo ""
      if [ -d "${INSTALL_PATH}" ]; then
         echo "[pytorch afar-skip] removing stale from-source install: ${INSTALL_PATH}"
         ${SUDO} rm -rf "${INSTALL_PATH}"
      fi
      for _mf in "${MODULE_PATH}/${PYTORCH_VERSION}${PYTORCH_INSTALL_SUFFIX}.lua" "${MODULE_PATH}/${PYTORCH_VERSION}${PYTORCH_INSTALL_SUFFIX}_tunableop_enabled.lua"; do
         if [ -f "${_mf}" ]; then
            echo "[pytorch afar-skip] removing stale modulefile: ${_mf}"
            ${SUDO} rm -f "${_mf}"
         fi
      done
      unset _mf
      # ── Drop a SKIPPED marker so the inventory tool can distinguish ──
      # "skipped on this SDK" from "absent / failed". The marker lands as
      # a sibling of the install dir, i.e. directly under the
      # rocmplus-${PREFIX}-${NUMERIC}/ root, named pytorch.SKIPPED.
      # Best-effort: never aborts the script. See
      # bare_system/inventory_packages.py for how this is surfaced
      # ('N' symbol -- Not possible to build on this SDK -- in the
      # per-version package matrix).
      _SKIP_MARKER_DIR="$(dirname "${INSTALL_PATH}")"
      ${SUDO} mkdir -p "${_SKIP_MARKER_DIR}" 2>/dev/null || true
      if [ -d "${_SKIP_MARKER_DIR}" ]; then
         ${SUDO} tee "${_SKIP_MARKER_DIR}/pytorch.SKIPPED" >/dev/null 2>/dev/null <<MARKER_EOF || true
SKIPPED package: pytorch
ROCm SDK:        ${ROCM_PATH:-unknown}
ROCm token:      ${ROCM_VERSION:-unknown}
Date:            $(date -u +%Y-%m-%dT%H:%M:%SZ)
Setup script:    pytorch_setup.sh (afar-skip guard)
Reason:          AFAR SDK is missing <ROCM_PATH>/lib/libMIOpen.so* (cmake
                 config refs nonexistent .so). pytorch's find_package(miopen)
                 requires the runtime lib; cannot build on this SDK.
                 Self-corrects on the next sweep if AMD ships a more
                 complete AFAR drop.
MARKER_EOF
      fi
      unset _SKIP_MARKER_DIR
      exit ${NOOP_RC}
   fi
fi

if [ "${REPLACE}" = "1" ]; then
   echo "[pytorch --replace 1] removing prior install + modulefiles if present"
   echo "  install dir:        ${INSTALL_PATH}"
   echo "  modulefile:         ${MODULE_PATH}/${PYTORCH_VERSION}${PYTORCH_INSTALL_SUFFIX}.lua"
   echo "  modulefile (tunop): ${MODULE_PATH}/${PYTORCH_VERSION}${PYTORCH_INSTALL_SUFFIX}_tunableop_enabled.lua"
   ${SUDO} rm -rf "${INSTALL_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${PYTORCH_VERSION}${PYTORCH_INSTALL_SUFFIX}.lua" \
                  "${MODULE_PATH}/${PYTORCH_VERSION}${PYTORCH_INSTALL_SUFFIX}_tunableop_enabled.lua"
fi

# ── Existence guard: skip if already installed (see hypre_setup.sh) ──
NOOP_RC=43
if [ -d "${INSTALL_PATH}" ]; then
   echo ""
   echo "[pytorch existence-check] ${INSTALL_PATH} already installed; skipping."
   echo "                          pass --replace 1 to force a clean rebuild of this version."
   echo ""
   exit ${NOOP_RC}
fi

# Consolidated EXIT trap: triton + pytorch build-dir cleanup
# (TRITON_BUILD_ROOT, PYTORCH_BUILD_ROOT, set later under
# BUILD_PYTORCH=1) PLUS fail-cleanup of partial install + both
# modulefiles. Replaces the inline two-target trap that lived next to
# the mktemp calls.
_pytorch_on_exit() {
   local rc=$?
   [ -n "${TRITON_BUILD_ROOT:-}" ]  && ${SUDO:-sudo} rm -rf "${TRITON_BUILD_ROOT}"
   [ -n "${PYTORCH_BUILD_ROOT:-}" ] && ${SUDO:-sudo} rm -rf "${PYTORCH_BUILD_ROOT}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[pytorch fail-cleanup] rc=${rc}: removing partial install + modulefiles"
      ${SUDO:-sudo} rm -rf "${INSTALL_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/${PYTORCH_VERSION}${PYTORCH_INSTALL_SUFFIX}.lua" \
                           "${MODULE_PATH}/${PYTORCH_VERSION}${PYTORCH_INSTALL_SUFFIX}_tunableop_enabled.lua"
   elif [ ${rc} -ne 0 ]; then
      echo "[pytorch fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _pytorch_on_exit EXIT

# Derive the rocm modulefile token to (re-)load. Three sources, in
# decreasing order of authority:
#   1. LMOD's LOADEDMODULES: the literal modulefile name currently
#      loaded (e.g. rocm/therock-afar-23.2.1). Only source that
#      handles the therock-afar dual scheme where install dir is
#      rocm-therock-afar-<NUMERIC> but the module is keyed on the
#      release tag (rocm/therock-afar-<RELEASE>).
#   2. ROCM_PATH basename: install-dir basename minus the `rocm-`
#      prefix. Correct for regular releases + afar (install-dir
#      basename == module name) but wrong for therock-afar.
#   3. rocm/${ROCM_VERSION}: standalone-invocation fallback when
#      neither LOADEDMODULES nor ROCM_PATH is populated.
ROCM_MODULE_NAME=""
if [[ -n "${LOADEDMODULES:-}" ]]; then
   _OLD_IFS="${IFS}"; IFS=":"
   for _m in ${LOADEDMODULES}; do
      case "${_m}" in
         rocm/*) ROCM_MODULE_NAME="${_m}"; break ;;
      esac
   done
   IFS="${_OLD_IFS}"; unset _OLD_IFS _m
fi
if [[ -z "${ROCM_MODULE_NAME}" ]]; then
   if [[ -n "${ROCM_PATH:-}" ]]; then
      _rp_bn="${ROCM_PATH##*/}"
      ROCM_MODULE_NAME="rocm/${_rp_bn#rocm-}"
      unset _rp_bn
   else
      ROCM_MODULE_NAME="rocm/${ROCM_VERSION}"
   fi
fi

# Provenance: capture this leaf script's git state for the modulefile
# whatis() lines emitted by the pytorch + tunableop heredocs below.
# Self-contained (no source dependency); falls back to "unknown" when
# the install runs from a stripped-of-.git context (Docker layer,
# release tarball, or git binary missing).
#
# Why the absolute-path dance: BASH_SOURCE[0] is whatever path was used
# to invoke the script -- often the relative `extras/scripts/pytorch_setup.sh`
# when called from bare_system/main_setup.sh. Passing that relative path
# to `git -C "${_leaf_dir}" log -- "${BASH_SOURCE[0]}"` makes git look for
# `${_leaf_dir}/extras/scripts/pytorch_setup.sh` (a path that does not
# exist), `git log` succeeds with empty output, and LEAF_SCRIPT_COMMIT
# ends up as the empty string -- which is what produced the
# `whatis("Built by: pytorch_setup.sh@ (clean)")` lines (no SHA, no
# "unknown") that the 2026-05-08 audit flagged across every rocmplus-*
# pytorch + ftorch modulefile in this sweep. Absolutize once, here,
# and feed the absolute path to every git query (matches cupy_setup.sh).
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
LEAF_SCRIPT_NAME="$(basename "${LEAF_SCRIPT_PATH}")"
LEAF_SCRIPT_COMMIT=unknown
LEAF_SCRIPT_DIRTY=unknown
_leaf_dir="$(dirname "${LEAF_SCRIPT_PATH}")"
if [ -d "${_leaf_dir}" ] && command -v git >/dev/null 2>&1 \
   && git -C "${_leaf_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
   _commit="$(git -C "${_leaf_dir}" log -n 1 --pretty=format:%H -- "${LEAF_SCRIPT_PATH}" 2>/dev/null)"
   [ -n "${_commit}" ] && LEAF_SCRIPT_COMMIT="${_commit}"
   unset _commit
   if [ -n "$(git -C "${_leaf_dir}" status --porcelain -- "${LEAF_SCRIPT_PATH}" 2>/dev/null)" ]; then
      LEAF_SCRIPT_DIRTY=dirty
   else
      LEAF_SCRIPT_DIRTY=clean
   fi
fi
unset _leaf_dir

if [ "${BUILD_PYTORCH}" = "0" ]; then

   echo "pytorch will not be built, according to the specified value of BUILD_PYTORCH"
   echo "BUILD_PYTORCH: $BUILD_PYTORCH"
   exit

else

   # Per-job triton/torchinductor scratch dirs so concurrent pytorch
   # builds on the same node do not race on -- or clobber -- each
   # other's compiled kernel cache. The previous code allowed triton
   # to drop kernels at its default location (/tmp/amd_triton_kernel_*
   # and friends) and then ran a blanket `${SUDO} rm -rf
   # /tmp/amd_triton_kernel* /tmp/can*` at end-of-build, which would
   # nuke any concurrent job's in-flight triton cache (and, in the
   # `/tmp/can*` case, anything else under /tmp starting with "can").
   # Redirecting the cache up front + cleaning via the EXIT trap is
   # both safer and collision-free. See audit_2026_05_01.md follow-up
   # to commit fc21433 (mktemp build dirs sweep).
   TRITON_BUILD_ROOT=$(mktemp -d -t pytorch-triton-cache.XXXXXX)
   # PYTORCH_BUILD_ROOT is the on-/tmp working dir for the source-build
   # branch (aotriton, pytorch_build venv, vision/audio/flash-attn
   # checkouts). Created here so the EXIT trap is single-source-of-truth.
   # The previous behavior cloned and built directly under the script's
   # CWD (the HPCTrainingDock NFS checkout), which (a) was slow and
   # (b) collided with concurrent ROCm-version builds in the same repo.
   PYTORCH_BUILD_ROOT=$(mktemp -d -t pytorch-build.XXXXXX)
   # NOTE: build-dir cleanup for both TRITON_BUILD_ROOT and
   # PYTORCH_BUILD_ROOT is consolidated into _pytorch_on_exit installed
   # above (which also fail-cleans the install + modulefiles).
   export TRITON_CACHE_DIR="${TRITON_BUILD_ROOT}/triton"
   export TORCHINDUCTOR_CACHE_DIR="${TRITON_BUILD_ROOT}/torchinductor"
   mkdir -p "${TRITON_CACHE_DIR}" "${TORCHINDUCTOR_CACHE_DIR}"

   if [[ "${AMDGPU_GFXMODEL}" == "gfx90a" ]]; then
      TARGET_GPUS="MI200"
   elif [[ "${AMDGPU_GFXMODEL}" == "gfx942" ]]; then
      TARGET_GPUS="MI300X"
   elif [[ "${AMDGPU_GFXMODEL}" == "gfx942;gfx90a" ]]; then
      TARGET_GPUS="MI300X;MI200"
   elif [[ "${AMDGPU_GFXMODEL}" == "gfx90a;gfx942" ]]; then
      TARGET_GPUS="MI200;MI300X"
   else
      echo "Please select gfx90a, gfx942, or both separated with a ; as AMDGPU_GFXMODEL"
      exit 1
   fi
  
   # aotriton's gpu_targets.py requires the `_mod0` suffix on EVERY entry
   # in --target_gpus (e.g. gfx942_mod0;gfx90a_mod0). The previous
   # `${AMDGPU_GFXMODEL}_mod0` only appended the suffix to the last
   # arch, so a multi-arch sweep ("gfx942;gfx90a") produced
   # "gfx942;gfx90a_mod0" and aotriton's configure errored with
   # `argument --target_gpus: invalid choice: 'gfx942'` (audit job 7975
   # log_pytorch_05_01_2026.txt). The sed expression below rewrites
   # each ;-separated arch token to <token>_mod0.
   AMDGPU_GFXMODEL_MOD0=$(echo "${AMDGPU_GFXMODEL}" | sed -e 's/[^;][^;]*/&_mod0/g')

   # AOTRITON_VERSION was already resolved by resolve_pytorch_stack_versions
   # (user CLI > manifest cell > resolve_aotriton_for_pt_only fallback).
   # Compute AOTRITON_EXTRA_CMAKE_FLAGS keyed off the resolved AOTriton
   # release so the right CMake API surface is selected (see comments on
   # resolve_aotriton_extra_cmake_flags). Historical AOTriton<->PT 2.9
   # bump rationale (0.11b -> 0.11.2b for the lld INSERT-AFTER-.comment
   # bug on rocm-7.2.1, audit log_pytorch_05_02_2026.txt:4631 in
   # logs_05_02_2026/rocm-7.2.1_8014/) is preserved by the manifest
   # cells "2.9|7.0|7.1|7.2" pinning aotriton=0.11.2b.
   AOTRITON_EXTRA_CMAKE_FLAGS=$(resolve_aotriton_extra_cmake_flags "${AOTRITON_VERSION}")

   echo ""
   echo "======================================"
   echo "Starting Pytorch Install with"
   echo "PyTorch Version: $PYTORCH_VERSION"
   echo "PyTorch Install Directory: $PYTORCH_PATH"
   echo "Torchvision Version: $TORCHVISION_VERSION"
   echo "Torchvision Install Directory: $TORCHVISION_PATH"
   echo "Torchaudio Version: $TORCHAUDIO_VERSION"
   echo "Torchaudio Install Directory: $TORCHAUDIO_PATH"
   echo "DeepSpeed Install Directory: $DEEPSPEED_PATH"
   echo "AOTriton Version: $AOTRITON_VERSION"
   echo "AOTriton Install Directory: $AOTRITON_PATH"
   echo "ROCm Version: $ROCM_VERSION"
   echo "Module Directory: $MODULE_PATH"
   echo "Use Wheel to Build?: $USE_WHEEL"
   echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL"
   echo "======================================"
   echo ""

   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
   if [ -f ${CACHE_FILES}/pytorch-v${PYTORCH_VERSION}${PYTORCH_INSTALL_SUFFIX}.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached Pytorch v${PYTORCH_VERSION}"
      echo "============================"
      echo ""

      # Install the cached version. Tarball top-level dir is
      # pytorch-v${PYTORCH_VERSION}/{pytorch,vision,audio,triton,...}
      # -- matches the versioned INSTALL_PATH layout the from-source
      # branch writes to, so multiple pytorch releases coexist on disk.
      cd /opt/rocmplus-${ROCM_VERSION}
      ${SUDO} tar -xzf ${CACHE_FILES}/pytorch-v${PYTORCH_VERSION}${PYTORCH_INSTALL_SUFFIX}.tgz
      ${SUDO} chown -R root:root ${INSTALL_PATH}
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/pytorch-v${PYTORCH_VERSION}${PYTORCH_INSTALL_SUFFIX}.tgz
      fi

   elif [ "${USE_WHEEL}" == "1" ]; then

      # don't use sudo if user has write access to install path
      if [ -d "$INSTALL_PATH" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${INSTALL_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      ${SUDO} mkdir -p ${INSTALL_PATH}
      ${SUDO} mkdir -p ${TRANSFORMERS_PATH}
      ${SUDO} mkdir -p ${TRITON_PATH}
      ${SUDO} mkdir -p ${DEEPSPEED_PATH}
      ${SUDO} mkdir -p ${SAGEATTENTION_PATH}
      ${SUDO} mkdir -p ${FLASHATTENTION_PATH}
      ${SUDO} mkdir -p ${PYTORCH_PATH}
      ${SUDO} mkdir -p ${TORCHAUDIO_PATH}
      ${SUDO} mkdir -p ${TORCHVISION_PATH}
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${INSTALL_PATH}
      fi

      python3 -m venv pytorch_build
      source pytorch_build/bin/activate
      cd pytorch_build

      # install of pre-built pytorch using a wheel
      ROCM_VERSION_WHEEL=${ROCM_VERSION}
      echo "Installing PyTorch, Torchaudio and Torchvision with wheel"
      if [[ `echo ${ROCM_VERSION} | cut -f3-3 -d'.'` == 0 ]]; then
         ROCM_VERSION_WHEEL=`echo ${ROCM_VERSION} | cut -f1-2 -d'.'`
      fi
      echo "ROCM_VERSION_WHEEL is ${ROCM_VERSION_WHEEL}"
      pip3 install torch==${PYTORCH_VERSION} --no-index -f https://repo.radeon.com/rocm/manylinux/rocm-rel-${ROCM_VERSION_WHEEL}/ --no-cache-dir --target=${PYTORCH_PATH}

      export PYTHONPATH=$PYTORCH_PATH:$PYTHONPATH

      # Installing Torchaudio

      pip3 install torchaudio==${TORCHAUDIO_VERSION} --no-index -f https://repo.radeon.com/rocm/manylinux/rocm-rel-${ROCM_VERSION_WHEEL}/ --no-cache-dir --target=${TORCHAUDIO_PATH} --no-build-isolation

      export PYTHONPATH=$PYTORCH_PATH:$PYTHONPATH

      # Installing Torchvision

      pip3 install torchvision==${TORCHVISION_VERSION} --no-index -f https://repo.radeon.com/rocm/manylinux/rocm-rel-${ROCM_VERSION_WHEEL}/ --no-cache-dir --target=${TORCHVISION_PATH} --no-build-isolation

      export PYTHONPATH=$PYTORCH_PATH:$PYTHONPATH

      # Installing Transformers

      pip3 install --target=${TRANSFORMERS_PATH} transformers --no-build-isolation

      export PYTHONPATH=$PYTORCH_PATH:$PYTHONPATH

      # Installing Sage Attention

      pip3 install --target=${SAGEATTENTION_PATH} sageattention==${SAGEATTENTION_VERSION} --no-build-isolation

      export PYTHONPATH=$PYTORCH_PATH:$PYTHONPATH

      # ── setuptools<81 pin (Bug 2 fix, wheel-install branch) ──
      # Twin of the pin block in the source-build branch (see comment
      # there for the full rationale: setuptools 81/82 removed
      # `pkg_resources` and any setup.py whose first executable line
      # is `from pkg_resources import ...` now crashes immediately).
      #
      # The wheel-install branch (this one) generally does NOT bump
      # setuptools above the venv-creation default (typically 59.6.0
      # on Ubuntu 22.04), because no PT source build runs `pip install
      # -r requirements.txt` here to drag in a 82.x update. So in the
      # common case this pin is a no-op even for PT >= 2.10 wheel
      # installs. We still apply it defensively because:
      #   (a) some future addition (e.g. another pip install above)
      #       could quietly upgrade the venv to setuptools 82+; and
      #   (b) flashattention's setup.py is the only source build in
      #       this branch, so a single pin here protects the whole
      #       wheel-branch chain through the rest of the function.
      #
      # Gated on PT >= 2.10 to stay byte-stable for the
      # already-passing PT 2.7-2.9 wheel-branch builds (their venvs
      # resolve setuptools organically and we have no reason to
      # change that).
      PT_PIN_MAJOR=$(echo "${PYTORCH_VERSION}" | cut -d. -f1)
      PT_PIN_MINOR=$(echo "${PYTORCH_VERSION}" | cut -d. -f2)
      if [ "${PT_PIN_MAJOR}" -gt 2 ] || \
         { [ "${PT_PIN_MAJOR}" -eq 2 ] && [ "${PT_PIN_MINOR}" -ge 10 ]; }; then
         echo "[setuptools<81 pin/wheel-branch] PT ${PYTORCH_VERSION} >= 2.10 -- pinning build-venv setuptools before flashattention setup.py"
         echo "[setuptools<81 pin/wheel-branch]   before: setuptools=$(python3 -c 'import setuptools; print(setuptools.__version__)' 2>&1)"
         pip3 install --upgrade --force-reinstall --no-deps 'setuptools<81' || {
            echo "ERROR: failed to pin setuptools<81 in the wheel-branch PT-build venv."        >&2
            echo "ERROR: flashattention setup.py may crash on 'from pkg_resources import ...'." >&2
            echo "ERROR: investigate pip3 / network / venv writability before retrying."        >&2
            exit 1
         }
         echo "[setuptools<81 pin/wheel-branch]   after:  setuptools=$(python3 -c 'import setuptools; print(setuptools.__version__)' 2>&1) (must be < 81)"
         if ! python3 -c 'from pkg_resources import DistributionNotFound, get_distribution, parse_version' 2>/dev/null; then
            echo "ERROR: post-pin probe failed: 'from pkg_resources import ...' still does not import."        >&2
            echo "ERROR: the pinned setuptools either did not install or another setuptools is shadowing it." >&2
            python3 -c 'import sys; [print("  sys.path:", p) for p in sys.path]'                               >&2
            exit 1
         fi
         echo "[setuptools<81 pin/wheel-branch]   probe:  pkg_resources import OK"
      else
         echo "[setuptools<81 pin/wheel-branch] PT ${PYTORCH_VERSION} < 2.10 -- no pin needed (legacy setuptools path)."
      fi

      # Installing Flash Attention

      pip3 install --target=${FLASHATTENTION_PATH} packaging
      export PYTHONPATH=$PYTHONPATH:${FLASHATTENTION_PATH}
      git clone --depth 1 --branch v${FLASHATTENTION_VERSION} https://github.com/Dao-AILab/flash-attention.git
      cd flash-attention
      python3 setup.py install --prefix=${FLASHATTENTION_PATH}

      export PYTHONPATH=$PYTORCH_PATH:$PYTHONPATH

      # Installing Triton

      ROCM_VERSION_WHEEL=${ROCM_VERSION}
      if [[ `echo ${ROCM_VERSION} | cut -f3-3 -d'.'` == 0 ]]; then
         ROCM_VERSION_WHEEL=`echo ${ROCM_VERSION} | cut -f1-2 -d'.'`
      fi

      # TRITON_VERSION was resolved by resolve_pytorch_stack_versions
      # (manifest cells "2.X|6.4" pin triton=3.2.0 because the rocm-rel-6.4
      # wheel index only ships 3.2.0; "2.9|7.x" pins triton=3.4.0). The
      # historical ROCm 6.4.2/6.4.3 conditional that hard-coded 3.2.0 is
      # subsumed by those manifest rows. For off-table combos the
      # resolver warns + falls through to the file default; the user can
      # pin via --triton-version.
      if [ "$(printf '%s\n' "$ROCM_VERSION" "7.0" | sort -V | head -n1)" = "$ROCM_VERSION" ]; then
        TRITON_WHEEL_NAME="pytorch_triton_rocm"
      fi

      echo "pip3 install ${TRITON_WHEEL_NAME}==${TRITON_VERSION} -f https://repo.radeon.com/rocm/manylinux/rocm-rel-${ROCM_VERSION_WHEEL}/ --no-cache-dir --target=${TRITON_PATH} --no-build-isolation"
      pip3 install ${TRITON_WHEEL_NAME}==${TRITON_VERSION} -f https://repo.radeon.com/rocm/manylinux/rocm-rel-${ROCM_VERSION_WHEEL}/ --no-cache-dir --target=${TRITON_PATH} --no-build-isolation

      export PYTHONPATH=$PYTORCH_PATH:$PYTHONPATH

      # Buidling Deep Speed

      DS_BUILD_AIO=1 \
      DS_BUILD_CCL_COMM=0 \
      DS_BUILD_CPU_ADAM=1 \
      DS_BUILD_CPU_LION=1 \
      DS_BUILD_EVOFORMER_ATTN=0 \
      DS_BUILD_FUSED_ADAM=1 \
      DS_BUILD_FUSED_LION=1 \
      DS_BUILD_FUSED_LAMB=1 \
      DS_BUILD_QUANTIZER=1 \
      DS_BUILD_RANDOM_LTD=1 \
      DS_BUILD_TRANSFORMER=1 \
      DS_BUILD_STOCHASTIC_TRANSFORMER=1 \
      DS_BUILD_SPARSE_ATTN=0 \
      DS_BUILD_TRANSFORMER_INFERENCE=0 \
      DS_BUILD_INFERENCE_CORE_OPS=0 \
      DS_BUILD_SPATIAL_INFERENCE=0 \
      DS_BUILD_CUTLASS_OPS=0 \
      DS_BUILD_RAGGED_OPS=0 \
      DS_BUILD_RAGGED_DEVICE_OPS=0 \
      DS_BUILD_OPS=0 \
      pip3 install --upgrade deepspeed einops psutil pydantic==2.11.9 hjson pydantic-core==2.33.2 msgpack typing_inspection annotated_types py-cpuinfo --no-cache-dir --target=$DEEPSPEED_PATH --no-build-isolation --no-deps

      # ── Shebang rewrite (wheel branch) ─────────────────────────────
      # Each pip3 install --target= above ran while the pytorch_build
      # venv (line 677) was active, so every console_script wrapper
      # (cmake, ninja, ctest, torchrun, transformers-cli, deepspeed,
      # ...) was baked with `#!${PYTORCH_BUILD_DIR}/bin/python3` -- a
      # /tmp path that disappears with the EXIT trap. PATH-resolved
      # invocations afterwards fail with "bad interpreter". Same root
      # cause + same fix as the source-build branch (further down at
      # the venv-relocation step). See bare_system/
      # fix_python_venv_shebangs.sh for the cluster-wide hot-fix
      # that addressed yesterday's installs (audit 2026-05-07: ~377
      # broken wrappers across pytorch satellite trees).
      # /usr/bin/env python3 works because each satellite's path is
      # added to PYTHONPATH by the pytorch modulefile, so imports
      # resolve under the system python3 once `module load pytorch`
      # is in effect.
      for _pt_bin in ${PYTORCH_PATH}/bin \
                     ${TORCHAUDIO_PATH}/bin \
                     ${TORCHVISION_PATH}/bin \
                     ${TRANSFORMERS_PATH}/bin \
                     ${SAGEATTENTION_PATH}/bin \
                     ${FLASHATTENTION_PATH}/bin \
                     ${TRITON_PATH}/bin \
                     ${DEEPSPEED_PATH}/bin; do
         [ -d "${_pt_bin}" ] || continue
         ${SUDO} find "${_pt_bin}" -maxdepth 1 -type f \
            -exec sed -i '1s|^#!.*python3.*$|#!/usr/bin/env python3|' {} + 2>/dev/null || true
      done
      unset _pt_bin

      deactivate
      cd ..
      rm -rf pytorch_build

      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} find ${INSTALL_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${INSTALL_PATH} -type d -execdir chown root:root "{}" +
      fi

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${INSTALL_PATH}
      fi

   else

      #source /etc/profile.d/lmod.sh
      #source /etc/profile.d/z00_lmod.sh

      # Replaces the previous bare `module load rocm/${ROCM_VERSION}` and
      # `module load magma` (which silently continued on failure). With
      # preflight_modules, a missing rocm or magma module aborts the
      # build IMMEDIATELY with a clear Lmod diagnostic and returns
      # MISSING_PREREQ_RC=42 -- main_setup.sh then reports the package
      # as SKIPPED rather than FAILED, which is the correct downstream
      # signal for "you must build magma first".
      #
      # openmpi (the GPU-aware UCX/UCC build) is a hard prereq because we
      # set USE_MPI=1 below. PyTorch's CMake glue does NOT propagate the
      # MPI -I include directory to the torch_python target -- so even
      # though FindMPI succeeds and `c10d` itself links libmpi.so, the
      # later compile of caffe2/torch/.../c10d/init.cpp (which transitively
      # includes ProcessGroupMPI.hpp -> <mpi.h>) fails with
      #   fatal error: 'mpi.h' file not found
      # unless openmpi's CPLUS_INCLUDE_PATH (set by its modulefile) puts
      # the openmpi headers on amdclang++'s default search path.
      # Audited failure: slurm 8052 log_pytorch_05_02_2026.txt:98270.
      # NOTE: "amdclang" is intentionally NOT in this list. Loading the
      # amdclang module exports CC=amdclang, CXX=amdclang++, which makes
      # PyTorch build libtorch_cpu with clang 22 -- triggering the
      # libtorch_cpu/libtorch_hip mangling drift documented in the
      # "Compiler selection: rely on system GCC" block below. Letting
      # CC/CXX fall through to PyTorch CMake's autodetect (system GCC)
      # matches the working 7.1.0/7.1.1/7.2.0/7.2.1 builds in the user
      # success study and produces SHORT-form const_data_ptr mangling
      # that matches the HIP-side references.
      REQUIRED_MODULES=( "${ROCM_MODULE_NAME}" "openmpi" "magma" )
      preflight_modules "${REQUIRED_MODULES[@]}" || exit $?

      # ── Toolchain: magma no longer poisons CC/CXX/FC ──────────────────
      # The amdclang-firewall `unset CC CXX FC F77 F90 OMPI_CC OMPI_CXX
      # OMPI_FC` block that used to live here was removed 2026-05-04
      # after magma_setup.sh stopped doing `load("amdclang")` in its
      # modulefile heredoc and switched to a direct prepend_path of the
      # LLVM lib dir on LD_LIBRARY_PATH/LD_RUN_PATH (Option B). Magma
      # still gets libomp.so resolved at runtime, but loading it no
      # longer rewrites the toolchain env, so PyTorch's CMake autodetect
      # picks system GCC for libtorch_cpu naturally -- matching the
      # working 7.1.0/7.1.1/7.2.0/7.2.1 builds in the user success
      # study (libtorch_cpu .comment = "GCC: 11.4"; SHORT-form mangling
      # of std::enable_if NTTPs that matches HIP TU references).
      #
      # If "import torch" ever fails again with the const_data_ptr
      # undefined-symbol signature, the most likely regression is that
      # magma_setup.sh's modulefile heredoc reverted to load("amdclang");
      # the C1 validation block below (search "C1 validation") catches
      # it within seconds of the build finishing.

      # Preflight: detect system libmagma-dev. Ubuntu's libmagma-dev
      # ships /usr/include/magma_v2.h whose magma_types.h:63 includes
      # <cuda.h>. If MAGMA_HOME is unset, PyTorch's FindMAGMA
      # (cmake/Modules/FindMAGMA.cmake) HINTS go nowhere and the
      # FIND_PATH falls through to /usr/include, then the wheel build
      # aborts ~65 min in at HIPHooks.cpp.o on `cuda.h: No such file
      # or directory` (verify: line 90085 of
      # logs_05_01_2026/rocm-7.2.1_7979/log_pytorch_05_01_2026.txt).
      # We unconditionally `module load magma` and export MAGMA_HOME
      # below, so this detector is informational; it gives operators
      # a one-liner to remove the trap entirely if they want defense
      # in depth.
      if dpkg-query -W -f='${Status}\n' libmagma-dev 2>/dev/null | grep -q "^install ok installed"; then
         echo ""
         echo "############################################################"
         echo "WARNING: system libmagma-dev (CUDA-flavored) is installed."
         echo "WARNING: This script sets MAGMA_HOME via the magma module"
         echo "WARNING: below so the build is safe; you may also fully"
         echo "WARNING: remove the system magma with:"
         echo "WARNING:   sudo apt purge libmagma-dev libmagma2 libmagma-sparse2"
         echo "############################################################"
         echo ""
      fi

      # Pin PyTorch's FindMAGMA HINTS to the rocmplus magma. The magma
      # modulefile (cite: extras/scripts/magma_setup.sh) sets
      # MAGMA_PATH and MAGMA_HOME (and MAGMA_ROOT/MAGMA_DIR). The magma
      # module was already loaded above by preflight_modules; we keep
      # the MAGMA_HOME fallback as belt-and-suspender for older
      # deployed magma modules that only set MAGMA_PATH (no MAGMA_HOME),
      # per the audit_2026_05_01.md plan.
      : "${MAGMA_HOME:=${MAGMA_PATH}}"
      export MAGMA_HOME
      echo "pytorch: MAGMA_HOME=${MAGMA_HOME}"
      if [ ! -f "${MAGMA_HOME}/include/magma_v2.h" ]; then
         echo "ERROR: MAGMA_HOME=${MAGMA_HOME} but magma_v2.h not found there."
         echo "ERROR: refusing to start the wheel build -- it would pick up"
         echo "ERROR: /usr/include/magma_v2.h (CUDA-flavored) and crash"
         echo "ERROR: ~65 min in at HIPHooks.cpp.o. Fix the magma module"
         echo "ERROR: install for rocm-${ROCM_VERSION} and retry."
         exit 1
      fi

      # OpenMP runtime hints. PyTorch's cmake/Modules/FindOpenMP.cmake
      # autodetects the OpenMP runtime via find_library; on Ubuntu 22.04
      # with ROCm clang it picks /usr/lib/gcc/x86_64-linux-gnu/12/libgomp.so
      # first. fbgemm's omp-outlined regions are compiled with
      # `-fopenmp=libomp` (clang's runtime ABI -> __kmpc_* symbols), so
      # the final libtorch_cpu.so / test-binary link fails with:
      #   ld.lld: error: undefined symbol: __kmpc_barrier
      #     >>> referenced by libfbgemm.a Utils.cc.o (.omp_outlined)
      # libgomp only provides the GOMP_* ABI -- distinct from __kmpc_*.
      # ROCm 7.2.1 ships clang's libomp at ${ROCM_PATH}/llvm/lib/libomp.so;
      # forcing FindOpenMP to resolve to that file fixes the link.
      # (verify: log_pytorch_05_02_2026.txt:45895-46258 in
      # logs_05_02_2026/rocm-7.2.1_8016/ -- the audit-time evidence
      # for this incident.)
      export OpenMP_C_FLAGS="-fopenmp=libomp"
      export OpenMP_CXX_FLAGS="-fopenmp=libomp"
      export OpenMP_C_LIB_NAMES="omp"
      export OpenMP_CXX_LIB_NAMES="omp"
      export OpenMP_omp_LIBRARY="${ROCM_PATH}/llvm/lib/libomp.so"
      # Belt-and-suspender: many CMake projects ignore the OpenMP_* env
      # vars and re-do find_library with the system search path. Putting
      # ROCm's llvm/lib first in LIBRARY_PATH makes the GCC tree lose
      # the find_library race even if env vars are dropped.
      export LIBRARY_PATH="${ROCM_PATH}/llvm/lib:${LIBRARY_PATH:-}"
      # Bake ROCm's llvm/lib into libtorch_cpu.so's DT_RUNPATH at link
      # time so libomp.so resolves even when LD_LIBRARY_PATH is stripped
      # by an external tool (e.g. rocprof-compute v3.4.0, whose
      # rocprofiler-sdk backend overwrites LD_LIBRARY_PATH with just
      # ${ROCM_PATH}/lib in the profiled child -- see
      # /shared/apps/ubuntu/opt/rocm-${ROCM_VERSION}/libexec/rocprofiler-compute/
      # rocprof_compute_profile/profiler_rocprofiler_sdk.py:73 +
      # utils/utils.py:766-767, which clobbers the inherited
      # LD_LIBRARY_PATH because options merge after os.environ.copy()).
      # Without this rpath, libtorch_cpu.so has NEEDED libomp.so but
      # only ${ROCM_PATH}/lib in RUNPATH, so the dlopen fails:
      #   ImportError: libomp.so: cannot open shared object file
      # surfaced by Pytorch_Profile_Rocprof-compute_ROCm test on
      # rocm-7.2.1 in cdash nightly 2026-05-05 (LastTest_20260506-0100.log
      # line 342). LDFLAGS uses --enable-new-dtags-compatible -Wl,-rpath
      # which the GCC linker records as DT_RUNPATH (consulted for direct
      # NEEDED entries; that's exactly what libomp.so is for libtorch_cpu).
      # Belt-and-suspender post-build patchelf below covers the case where
      # PyTorch's setup.py drops env LDFLAGS for a particular TU.
      export LDFLAGS="${LDFLAGS:-} -Wl,-rpath,${ROCM_PATH}/llvm/lib"
      if [ ! -f "${OpenMP_omp_LIBRARY}" ]; then
         echo "ERROR: OpenMP_omp_LIBRARY=${OpenMP_omp_LIBRARY} not found."
         echo "ERROR: ROCm clang's libomp.so is required to link fbgemm-using"
         echo "ERROR: targets in pytorch. Check the rocm/${ROCM_VERSION} install."
         exit 1
      fi
      echo "pytorch: OpenMP_omp_LIBRARY=${OpenMP_omp_LIBRARY}"
      echo "pytorch: LDFLAGS=${LDFLAGS}"

      # don't use sudo if user has write access to install path
      if [ -d "$INSTALL_PATH" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${INSTALL_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      # PKG_SUDO: apt/dnf need root regardless of the install-path-derived
      # SUDO. The original `if [[ ${SUDO} != "" ]]` guard conflated
      # "install path needs sudo to write" with "I have sudo authority
      # for apt", which broke any build to an admin-writable install
      # path. We change the guard to a sudo-availability check
      # (root or passwordless sudo); the no-sudo branch -- pip-install
      # mkl as a userspace fallback -- is preserved for environments
      # that genuinely lack sudo. See openmpi_setup.sh /
      # audit_2026_05_01.md Issue 2.
      PKG_SUDO=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")

      # ── No Intel MKL on ROCm builds ───────────────────────────────────
      # This script used to download and install Intel oneAPI MKL
      # (intel-onemkl-2025.0.0.940.sh) on every PyTorch build. That was
      # wrong for two reasons:
      #
      #  1. The MKL-only installer ships libmkl_intel_thread.so which
      #     NEEDS libiomp5.so (Intel's OpenMP runtime). libiomp5 ships
      #     with the Intel compilers package, which we never install.
      #     Result: at first `import torch`, ctypes loads
      #     libtorch_global_deps -> libmkl_intel_thread -> unresolved
      #     symbol omp_get_max_active_levels -> OSError. First seen in
      #     slurm 8032 (2026-05-02 17:00); the wheel build itself
      #     succeeded and the failure surfaced when deepspeed's setup.py
      #     did `import torch`.
      #
      #  2. ROCm-flavored PyTorch is supposed to use OpenBLAS (CPU) and
      #     rocBLAS (GPU); MKL was the x86/CUDA path. Upstream pytorch
      #     and AMD's rocm/pytorch container both set USE_MKL=0 for HIP
      #     builds.
      #
      # USE_MKL=0 / BLAS=OpenBLAS exports above are belt-and-suspender
      # in case oneAPI is on the system from an earlier (pre-fix) run
      # of this script -- they neutralize PyTorch's CMake auto-detect.
      # The operator-visible warning below makes that situation loud.
      if [ -d /opt/intel/oneapi ]; then
         echo ""
         echo "############################################################"
         echo "WARNING: /opt/intel/oneapi exists on this system."
         echo "WARNING: This is leftover from a pre-2026-05-02 PyTorch"
         echo "WARNING: build of this repo. We deliberately do NOT use"
         echo "WARNING: it; USE_MKL=0 / BLAS=OpenBLAS above keep PyTorch"
         echo "WARNING: from auto-detecting it. To remove fully:"
         echo "WARNING:   sudo rm -rf /opt/intel"
         echo "############################################################"
         echo ""
      fi

      if [[ "${DISTRO}" == "ubuntu" ]]; then
         if [ "${EUID:-$(id -u)}" -eq 0 ] || sudo -n true 2>/dev/null; then
            ${PKG_SUDO} apt-get update
            ${PKG_SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -y python-is-python3 liblzma-dev libzstd-dev git-lfs
            module load ${MPI_MODULE}
            if [[ `which mpicc | wc -l` -eq 0 ]]; then
               ${PKG_SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -y libopenmpi-dev
            fi
         else
            ln -s $(which python3) ~/bin/python
            export PATH="$HOME/bin:$PATH"
            source $HOME/.bashrc
         fi
      elif [[ "${RHEL_COMPATIBLE}" == 1 ]]; then
         if [ "${EUID:-$(id -u)}" -eq 0 ] || sudo -n true 2>/dev/null; then
            ${PKG_SUDO} dnf install -y ninja-build
            module load ${MPI_MODULE}
         else
            dnf install -y ninja-build
	 fi
      fi


      ${SUDO} mkdir -p ${INSTALL_PATH}
      ${SUDO} mkdir -p ${TRANSFORMERS_PATH}
      ${SUDO} mkdir -p ${TRITON_PATH}
      ${SUDO} mkdir -p ${DEEPSPEED_PATH}
      ${SUDO} mkdir -p ${SAGEATTENTION_PATH}
      ${SUDO} mkdir -p ${FLASHATTENTION_PATH}
      ${SUDO} mkdir -p ${AOTRITON_PATH}
      ${SUDO} mkdir -p ${PYTORCH_PATH}
      ${SUDO} mkdir -p ${TORCHAUDIO_PATH}
      ${SUDO} mkdir -p ${TORCHVISION_PATH}
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${INSTALL_PATH}
      fi

      # Move the entire source-build (aotriton, pytorch venv,
      # vision/audio/flash-attn checkouts) onto /tmp via the
      # PYTORCH_BUILD_ROOT created at the top of this branch. The
      # subsequent `cd ../..` / `rm -rf` patterns within this block
      # were authored relative to this single CWD, so a single
      # chdir-then-restore brackets the whole tree without disturbing
      # those relative paths.
      PYTORCH_ORIG_CWD="$(pwd)"
      cd "${PYTORCH_BUILD_ROOT}"

      echo ""
      echo "=================================="
      echo " Installing AOTriton from source "
      echo "=================================="
      echo " build dir: ${PYTORCH_BUILD_ROOT} (off NFS)"
      echo ""

      export GPU_TARGETS=${AMDGPU_GFXMODEL}
      export AMDGPU_TARGETS=${AMDGPU_GFXMODEL}

      # ── TRITON_HIP_LLD_PATH (critical; do NOT remove) ─────────────────
      # The AOTriton build below invokes a vendored Triton (3.2.0 for
      # AOTriton 0.9.2b, 3.2.0 for 0.10b, 3.4.0 for 0.11.x). Triton's
      # AMD backend (third_party/amd/backend/compiler.py: path_to_rocm_lld)
      # picks ld.lld by walking, in order:
      #   1. $TRITON_HIP_LLD_PATH
      #   2. <wheel>/triton/backends/amd/llvm/bin/ld.lld   (wheel-only)
      #   3. /opt/rocm/llvm/bin/ld.lld                      (hardcoded)
      #   4. /usr/bin/ld.lld
      #   5. raise.
      # On this cluster /opt/rocm does not exist (warewulf imaging put
      # a different symlink target on every compute node; operator
      # removed it ~2026-04-22). Compute nodes installed lld:amd64
      # 1:14.0-55 on 2026-04-26 20:49, which made /usr/bin/ld.lld
      # appear (LLVM 14). LLD 14 rejects the HSA code-object metadata
      # that Triton 3.2.0 emits ("ld.lld: error: unknown abi
      # version:"), nuking the AOTriton kernel codegen across every
      # gfx target. The ROCm-bundled lld at ${ROCM_PATH}/llvm/bin/ld.lld
      # is AMD LLD 19.0.0+ on every rocm we deploy and accepts that
      # metadata cleanly.
      #
      # We point Triton at the ROCm-bundled lld via the env var and
      # validate the path before letting the AOTriton clone proceed.
      # If the file is missing the build aborts here with a clear
      # diagnostic, instead of failing 90+ min later inside ninja
      # codegen with the cryptic "unknown abi version" message.
      #
      # Self-corrects if the operator passes a custom --aotriton-version
      # with a different bundled Triton ABI; the env var still wins
      # (it is checked first by path_to_rocm_lld).
      if [ -z "${ROCM_PATH:-}" ]; then
         echo "ERROR: ROCM_PATH is empty; cannot set TRITON_HIP_LLD_PATH."
         echo "ERROR: rocm/${ROCM_VERSION} module must be loaded before"
         echo "ERROR: the AOTriton build (see preflight_modules above)."
         exit 1
      fi
      export TRITON_HIP_LLD_PATH="${ROCM_PATH}/llvm/bin/ld.lld"
      if [ ! -f "${TRITON_HIP_LLD_PATH}" ]; then
         echo "######################################################"
         echo "ERROR: TRITON_HIP_LLD_PATH=${TRITON_HIP_LLD_PATH}"
         echo "ERROR: does not exist. This is the ROCm-bundled lld"
         echo "ERROR: that AOTriton's vendored Triton needs to accept"
         echo "ERROR: the HSA code-object 'abi version' field it emits."
         echo "ERROR:"
         echo "ERROR: Without it, Triton falls through to /usr/bin/ld.lld"
         echo "ERROR: (LLVM 14 on Ubuntu jammy) which rejects the metadata"
         echo "ERROR: with 'ld.lld: error: unknown abi version:' and the"
         echo "ERROR: build dies ~90 min into pytorch wheel link."
         echo "ERROR:"
         echo "ERROR: Reinstall the rocm/${ROCM_VERSION} SDK so that"
         echo "ERROR: ${ROCM_PATH}/llvm/bin/ld.lld is present, or set"
         echo "ERROR: TRITON_HIP_LLD_PATH manually before re-invoking."
         echo "######################################################"
         exit 1
      fi
      # Print version for the log so the audit trail is unambiguous.
      _lld_v=$("${TRITON_HIP_LLD_PATH}" --version 2>&1 | head -1 || echo "<probe failed>")
      echo "pytorch: TRITON_HIP_LLD_PATH=${TRITON_HIP_LLD_PATH}"
      echo "pytorch: TRITON_HIP_LLD_PATH version: ${_lld_v}"
      unset _lld_v

      # Clean up stale source tree from prior interrupted runs.
      # No zstd build needed: aotriton 0.8+ replaced its zstd
      # compression path with liblzma (already installed via apt at
      # the top of this branch). The Ubuntu 22.04 system zstd CLI
      # (v1.4.8 at /usr/bin/zstd) covers the only remaining mention
      # in v2python/generate_compile.py, which is gated behind
      # --test-clustering and not invoked during a normal build.
      # See aotriton README L30, CMakeLists.txt:131 (liblzma path),
      # and bindings/CMakeLists.txt:13 (zstd_interface guarded by
      # AOTRITON_COMPRESS_KERNEL, which is never set in 0.11.2b).
      rm -rf aotriton

      git clone --depth 1 --branch ${AOTRITON_VERSION}  https://github.com/ROCm/aotriton.git

      cd aotriton
      git submodule update --init --recursive --depth 1

      # Triton (vendored under aotriton/third_party/triton, not the
      # standalone TRITON_VERSION pin earlier in this script) sets
      # `-Werror -Wno-covered-switch-default` unconditionally in its
      # top-level CMakeLists.txt. On Ubuntu 22.04 (libstdc++ 12) two
      # TUs reach `std::stable_sort` -> `std::_Temporary_buffer` ->
      # `std::get_temporary_buffer`, which libstdc++ marks
      # _GLIBCXX17_DEPRECATED. amdclang++ promotes it to
      # -Werror,-Wdeprecated-declarations and the compile fails:
      #   - lib/Analysis/Allocation.cpp.o
      #   - third_party/amd/lib/TritonAMDGPUTransforms/BlockPingpong.cpp.o
      # (verify: logs_05_02_2026/rocm-7.2.1_8013/log_pytorch_05_02_2026.txt
      #  lines 2894 and 2989). Append `-Wno-error=deprecated-declarations`
      # so the deprecation stays a warning while every other -Werror
      # promotion is preserved. Targeted, reversible, version-pinned to
      # the aotriton checkout we just produced.
      TRITON_CMAKELISTS="third_party/triton/CMakeLists.txt"
      if [ -f "${TRITON_CMAKELISTS}" ] && grep -q -- "-Werror" "${TRITON_CMAKELISTS}"; then
         echo "pytorch: patching ${TRITON_CMAKELISTS} to neutralise -Werror,-Wdeprecated-declarations"
         sed -i 's/-Werror\b/-Werror -Wno-error=deprecated-declarations/g' "${TRITON_CMAKELISTS}"
         grep -n -- "-Werror" "${TRITON_CMAKELISTS}" || echo "pytorch: WARNING: -Werror disappeared after sed; review patch"
      else
         echo "pytorch: NOTE: ${TRITON_CMAKELISTS} has no -Werror; skip patch (aotriton may have changed triton pin)"
      fi

      mkdir -p build && cd build

      if [[ "${AMDGPU_GFXMODEL}" == "gfx90a" ]]; then
         TARGET_GPUS="MI200"
      elif [[ "${AMDGPU_GFXMODEL}" == "gfx942" ]]; then
	 TARGET_GPUS="MI300X"
      elif [[ "${AMDGPU_GFXMODEL}" == "gfx942;gfx90a" ]]; then
	 TARGET_GPUS="MI300X;MI200"
      elif [[ "${AMDGPU_GFXMODEL}" == "gfx90a;gfx942" ]]; then
	 TARGET_GPUS="MI200;MI300X"
      else
         echo "Please select gfx90a, gfx942, or both separated with a ; as AMDGPU_GFXMODEL"
	 exit 1
      fi

      # ── HIP-discovery override (do NOT remove) ────────────────────────
      # aotriton's CMakeLists.txt (verified across 0.9.2b, 0.10b, 0.11b,
      # 0.11.2b) unconditionally appends "/opt/rocm" to CMAKE_PREFIX_PATH
      # before find_package(hip). On every Slurm build node /opt/rocm is
      # a symlink to whichever rocm major was bare-installed first
      # (currently /opt/rocm-7.1.1). Without this override aotriton
      # therefore links against rocm 7.1.1's libamdhip64.so.7 even when
      # ROCM_PATH points at /shared/apps/ubuntu/opt/rocm-6.4.0 -- the
      # resulting libaotriton_v2.so.0.11.2 has DT_NEEDED
      # libamdhip64.so.7, which does not exist on rocm 6.4.x, so
      # `import torch` fails at the C1 validation step with
      # ImportError: libamdhip64.so.7: cannot open shared object file.
      # On rocm 7.x this contamination is silent (a 7.0.x install
      # ends up with aotriton symbols from 7.1.1), but it is fatal
      # on 6.4.x. (Verified: logs_05_06_2026/rocm-6.4.0_8391/
      # log_pytorch_05_06_2026.txt: 30+ "warning: libamdhip64.so.7,
      # needed by libaotriton_v2.so.0.11.2, not found" at lines
      # 98119-98291; readelf -d on
      # /shared/apps/ubuntu/opt/rocmplus-7.0.0/pytorch-v2.9.1/aotriton/
      # lib/libaotriton_v2.so.0.11.2 also shows NEEDED libamdhip64.so.7.)
      #
      # Fix: pre-set every cmake variable that find_package(hip) and its
      # transitive find_dependency() walk consult, so aotriton's later
      #   list(APPEND CMAKE_PREFIX_PATH "/opt/rocm")
      # is harmless (it only ever appends *after* the entries we set).
      #   - hip_DIR / hsa-runtime64_DIR / AMDDeviceLibs_DIR /
      #     amd_comgr_DIR : direct package-config locations, highest
      #     priority in CMake's find_package() search order.
      #   - CMAKE_PREFIX_PATH = ${ROCM_PATH} : front-of-list fallback
      #     so any *_DIR we forgot still resolves to our rocm tree
      #     before /opt/rocm is searched.
      AOTRITON_HIP_OVERRIDES=( \
         "-DCMAKE_PREFIX_PATH=${ROCM_PATH}" \
         "-Dhip_DIR=${ROCM_PATH}/lib/cmake/hip" \
         "-Dhsa-runtime64_DIR=${ROCM_PATH}/lib/cmake/hsa-runtime64" \
         "-DAMDDeviceLibs_DIR=${ROCM_PATH}/lib/cmake/AMDDeviceLibs" \
         "-Damd_comgr_DIR=${ROCM_PATH}/lib/cmake/amd_comgr" \
         "-Dhsakmt_DIR=${ROCM_PATH}/lib/cmake/hsakmt" \
      )
      cmake -DAOTRITON_HIPCC_PATH=${ROCM_PATH}/bin "${AOTRITON_HIP_OVERRIDES[@]}" ${AOTRITON_EXTRA_CMAKE_FLAGS} -DCMAKE_INSTALL_PREFIX=${AOTRITON_PATH} -DCMAKE_BUILD_TYPE=Release -DAOTRITON_GPU_BUILD_TIMEOUT=0  -G Ninja ..
      AOTRITON_CONFIGURE_RC=$?
      if [ ${AOTRITON_CONFIGURE_RC} -ne 0 ]; then
         echo ""
         echo "ERROR: aotriton cmake configure failed (rc=${AOTRITON_CONFIGURE_RC})"
         echo "ERROR: AOTRITON_EXTRA_CMAKE_FLAGS='${AOTRITON_EXTRA_CMAKE_FLAGS}'"
         echo "ERROR: refusing to continue -- a missing libaotriton_v2.so"
         echo "ERROR: would only show up later during pytorch's ninja link"
         echo "ERROR: as 'missing and no known rule to make it', wasting"
         echo "ERROR: ~30-90 min of cmake/ninja work in pytorch's wheel build"
         echo "ERROR: (audit job 7975, log_pytorch_05_01_2026.txt)."
         exit 1
      fi

      ninja install
      AOTRITON_NINJA_RC=$?
      if [ ${AOTRITON_NINJA_RC} -ne 0 ]; then
         echo ""
         echo "ERROR: aotriton ninja install failed (rc=${AOTRITON_NINJA_RC})"
         echo "ERROR:"
         echo "ERROR: The most common failure here is the Triton kernel"
         echo "ERROR: codegen step rejecting HSA code-object metadata:"
         echo "ERROR:    'ld.lld: error: unknown abi version: '"
         echo "ERROR: which means Triton fell through to /usr/bin/ld.lld"
         echo "ERROR: (LLVM 14 on Ubuntu jammy) and rejected the metadata."
         echo "ERROR: Check that TRITON_HIP_LLD_PATH (set near the top of"
         echo "ERROR: this build region) actually pointed at the"
         echo "ERROR: ROCm-bundled lld 19+ and that the file existed."
         exit 1
      fi

      # ── Post-install sanity probe (critical short-circuit) ────────────
      # User directive 2026-05-16: short-circuit the build if AOTriton
      # did not actually produce the artifacts pytorch will need ~90 min
      # from now. Without this probe a silent codegen failure (e.g. all
      # .hsaco emit successfully but the final libaotriton_v2.so link
      # gets skipped, or vice versa) is only discovered late in the
      # pytorch wheel link as "missing libaotriton_v2.so, no rule" --
      # exactly the failure mode the configure-rc guard above protects
      # against, but staged later in the pipeline.
      #
      # Each check fails-fast with the operator-actionable signal:
      #   1. libaotriton_v2.so present and non-empty at the install path.
      #   2. At least one kernel object (.hsaco OR .aks2) present under
      #      the install tree (catches "ninja install completed rc=0 but
      #      kernel codegen produced zero objects" -- a known mode when
      #      Triton's target-arch filter mis-classifies our GFX list).
      #      Both extensions are accepted because AOTriton's packaging
      #      changed across the releases we currently build:
      #        - 0.9.2b  : .aks2 only (kernel-set v2 envelopes wrapping
      #                    the gfx ELF; no loose .hsaco are emitted).
      #                    Empirical: 9802-9814 each installed thousands
      #                    of .aks2 under aotriton/lib/aotriton.images/
      #                    amd-gfx942/flash/...___MI300X.aks2 with zero
      #                    .hsaco -- the original probe (.hsaco-only)
      #                    false-positived all 13 jobs (~28 node-h lost,
      #                    audit_2026_05_17.md).
      #        - 0.10b   : .aks2 + some loose .hsaco.
      #        - 0.11.x  : .aks2 + .hsaco (both populated).
      #      The genuine "linked .so, emitted no kernels" failure mode
      #      this guard catches zeroes BOTH counts simultaneously, so
      #      OR-ing them does not weaken the probe.
      #   3. The installed .so is linked against libamdhip64 from
      #      ${ROCM_PATH}, not /opt/rocm or any other rocm tree (catches
      #      the "wrong rocm major" contamination documented in the
      #      AOTRITON_HIP_OVERRIDES block above).
      _aot_lib_glob=("${AOTRITON_PATH}"/lib/libaotriton_v2.so*)
      _aot_lib="${_aot_lib_glob[0]:-}"
      if [ ! -s "${_aot_lib}" ]; then
         echo ""
         echo "######################################################"
         echo "ERROR: AOTriton post-install probe (1/3) FAILED:"
         echo "ERROR:   ${AOTRITON_PATH}/lib/libaotriton_v2.so* not found"
         echo "ERROR:   (or zero-byte)."
         echo "ERROR: ninja install returned rc=0 but did not deposit the"
         echo "ERROR: main shared library. Refusing to start pytorch wheel"
         echo "ERROR: build -- it would only fail at link time."
         echo "ERROR:"
         echo "ERROR: Listing of ${AOTRITON_PATH}:"
         ls -la "${AOTRITON_PATH}" "${AOTRITON_PATH}/lib" 2>&1 | sed 's/^/ERROR:   /'
         echo "######################################################"
         exit 1
      fi
      _aot_hsaco_count=$(find "${AOTRITON_PATH}" -name '*.hsaco' 2>/dev/null | wc -l)
      _aot_aks2_count=$(find "${AOTRITON_PATH}" -name '*.aks2' 2>/dev/null | wc -l)
      _aot_kernel_count=$(( ${_aot_hsaco_count:-0} + ${_aot_aks2_count:-0} ))
      if [ "${_aot_kernel_count}" -lt 1 ]; then
         echo ""
         echo "######################################################"
         echo "ERROR: AOTriton post-install probe (2/3) FAILED:"
         echo "ERROR:   no kernel objects (.hsaco or .aks2) under"
         echo "ERROR:   ${AOTRITON_PATH}"
         echo "ERROR: AOTriton produced libaotriton_v2.so but emitted"
         echo "ERROR: zero kernel objects -- triton codegen ran but"
         echo "ERROR: filtered out every (target,kernel) cell. Either"
         echo "ERROR: TARGET_GPUS=${TARGET_GPUS} is unsupported by this"
         echo "ERROR: AOTriton version, or the kernel codegen silently"
         echo "ERROR: skipped emission. Refusing to start pytorch wheel"
         echo "ERROR: build."
         echo "######################################################"
         exit 1
      fi
      _aot_needed=$(readelf -d "${_aot_lib}" 2>/dev/null \
         | awk '/NEEDED.*libamdhip64/{ for(i=1;i<=NF;i++) if($i ~ /libamdhip64/) print $i }' \
         | tr -d '[]' | head -1)
      if [ -n "${_aot_needed}" ]; then
         # Resolve where this DT_NEEDED actually points by tracing
         # against the current LD_LIBRARY_PATH + ${ROCM_PATH}/lib. If
         # the resolved path is NOT inside ${ROCM_PATH}, the wrong
         # rocm major slipped in -- exactly the bug the
         # AOTRITON_HIP_OVERRIDES block above is meant to prevent.
         # (We don't fail on a mere SONAME mismatch -- some rocm
         # majors bump SONAME minor without an API break -- so we
         # actually trace the resolution.)
         _aot_hip_resolved=$(LD_LIBRARY_PATH="${ROCM_PATH}/lib:${LD_LIBRARY_PATH:-}" \
            ldd "${_aot_lib}" 2>/dev/null | awk -v want="${_aot_needed}" \
            '$1 == want { print $3; exit }')
         case "${_aot_hip_resolved}" in
            "${ROCM_PATH}"/*)
               echo "pytorch: AOTriton probe (3/3) OK: ${_aot_needed} -> ${_aot_hip_resolved}"
               ;;
            "")
               echo ""
               echo "######################################################"
               echo "ERROR: AOTriton post-install probe (3/3) FAILED:"
               echo "ERROR:   libaotriton_v2.so DT_NEEDED ${_aot_needed} but"
               echo "ERROR:   ldd cannot resolve it from ${ROCM_PATH}/lib."
               echo "ERROR: Without that resolution 'import torch' will fail"
               echo "ERROR: at the C1 validation step with"
               echo "ERROR:   ImportError: ${_aot_needed}: cannot open shared object file."
               echo "ERROR: Refusing to start pytorch wheel build."
               echo "######################################################"
               exit 1
               ;;
            *)
               echo ""
               echo "######################################################"
               echo "ERROR: AOTriton post-install probe (3/3) FAILED:"
               echo "ERROR:   libaotriton_v2.so DT_NEEDED ${_aot_needed}"
               echo "ERROR:   resolves to ${_aot_hip_resolved}"
               echo "ERROR:   which is OUTSIDE ${ROCM_PATH}."
               echo "ERROR: A different rocm major leaked into the AOTriton"
               echo "ERROR: link (typically via the /opt/rocm fallback path"
               echo "ERROR: in aotriton's CMakeLists.txt). 'import torch'"
               echo "ERROR: against this AOTriton will load the wrong"
               echo "ERROR: libamdhip64 and crash. Refusing to start"
               echo "ERROR: pytorch wheel build."
               echo "######################################################"
               exit 1
               ;;
         esac
      else
         echo "pytorch: AOTriton probe (3/3) skipped: ${_aot_lib} has no DT_NEEDED libamdhip64 (unusual but not fatal)"
      fi
      echo "pytorch: AOTriton post-install probes OK"
      echo "pytorch:   libaotriton_v2.so : ${_aot_lib} ($(stat -c%s "${_aot_lib}") bytes)"
      echo "pytorch:   kernel objects    : ${_aot_kernel_count} (.hsaco=${_aot_hsaco_count} .aks2=${_aot_aks2_count})"
      unset _aot_lib _aot_lib_glob _aot_hsaco_count _aot_aks2_count _aot_kernel_count _aot_needed _aot_hip_resolved

      cd ../..
      rm -rf aotriton

      echo ""
      echo "============================"
      echo " Installing Pytorch, "
      echo " Torchaudio and Torchvision"
      echo " from source"
      echo "============================"
      echo ""

      # Remove any stale build directory from a prior interrupted run.
      # Uses sudo because a previous build may have created root-owned
      # files via the sed fixup of torchrun scripts.
      ${SUDO} rm -rf pytorch_build
      python3 -m venv pytorch_build
      source pytorch_build/bin/activate
      cd pytorch_build
      export PYTORCH_BUILD_DIR=`pwd`

      export _GLIBCXX_USE_CXX11_ABI=1
      export ROCM_HOME=${ROCM_PATH}
      export ROCM_SOURCE_DIR=${ROCM_PATH}
      export USE_ROCM=1
      export USE_CUDA=0
      export MAX_JOBS=40
      export USE_MPI=1

      # ── Disable libtorch C++ test binaries ────────────────────────────
      # PyTorch's source build defaults BUILD_TEST=ON, which compiles
      # ~150 upstream-CI C++ test binaries (Dict_test, Dimname_test,
      # test_api, test_jit, test_lazy, test_cpp_c10d/Process*Gloo*Test,
      # Process*NCCLTest, etc.) into pytorch_build/build/bin/. NONE of
      # those binaries ship in the wheel and NONE of them get installed
      # by `setup.py install --prefix=...` -- they exist only so
      # upstream's CI can run them in their own containers.
      #
      # We disable them for two reasons:
      #
      # (1) Build-time + disk savings: skipping ~150 link steps and
      #     their associated ATen/c10/torch_hip object dependencies
      #     shaves 10-20 min off every PT source build (more on small
      #     nodes), with zero impact on the deployed install.
      #
      # (2) Hard build break on Ubuntu 22.04 + gcc-11 toolchain with
      #     PT 2.12.0 on ROCm 7.2.3. The test binaries link against
      #     libtorch_hip.so via `-Wl,--no-as-needed` using /usr/bin/c++
      #     (system gcc-11.4). PT 2.12 emits bfloat16 conversion calls
      #     to the compiler-rt builtin __truncsfbf2 inside HIP TUs that
      #     end up in libtorch_hip.so as an undefined reference (the
      #     .so's own link did NOT pull in clang_rt.builtins). Probes
      #     on a build-class node:
      #         gcc:                     11.4.0
      #         libgcc.a __truncsfbf2:   NOT FOUND
      #         clang_rt.builtins.a:     T __truncsfbf2     (ROCm 7.2.3)
      #     With BUILD_TEST=ON, every Dict_test/Dimname_test/test_api/
      #     ... link step fires:
      #         /usr/bin/ld: …/libtorch_hip.so: undefined reference
      #                      to `__truncsfbf2'
      #         collect2: error: ld returned 1 exit status
      #         ninja: build stopped: subcommand failed.
      #         ERROR: pytorch wheel build failed (rc=1).
      #     The libtorch_hip.so itself links fine -- the unresolved
      #     symbol only matters at downstream consumer-link time, and
      #     in a BUILD_TEST=OFF build there are no downstream C++
      #     consumers inside the build tree.
      #     First seen in slurm 9968 (rocm-7.2.3 + PT 2.12.0, 2026-05-18
      #     ~20:03 fail). See log line 68374:
      #       FAILED: [code=1] bin/Dict_test
      #       /usr/bin/ld: …libtorch_hip.so: undefined reference to
      #                    `__truncsfbf2'
      #     log: logs_05_18_2026/rocm-7.2.3_9968/log_pytorch_v2.12.0_05_18_2026.txt
      #
      # PT 2.10 / 2.11 may or may not also trip on this depending on
      # whether their bf16 codegen path emits __truncsfbf2 in the same
      # spot; BUILD_TEST=0 is the correct config for all release-style
      # builds regardless, since we never use those test binaries.
      #
      # PyTorch honours BUILD_TEST via tools/setup_helpers: setup.py
      # reads `check_env_flag("BUILD_TEST", default="ON")`, so a
      # plain export here flows through pip / pyproject build.
      export BUILD_TEST=0

      # ── Inject ROCm clang's compiler-rt builtins into all link steps ──
      # PT 2.12+ HIP TUs emit references to bfloat16 conversion builtins
      # (__truncsfbf2, __extendbfsf2, __truncdfbf2, ...) that come from
      # the LLVM compiler-rt runtime. These references propagate into
      # libtorch_hip.so. With:
      #   (a) BUILD_TEST=0 above, the build no longer dies at the
      #       Dict_test/Dimname_test C++ unit-test link step (9968).
      #   (b) But libtorch_hip.so itself is still linked by the system
      #       /usr/bin/c++ (Ubuntu 22.04 gcc-11.4), and gcc-11.4's
      #       libgcc.a / libgcc_s.so.1 do NOT carry __truncsfbf2 (added
      #       in libgcc only at GCC 13). Linkers happily produce a .so
      #       with unresolved refs (no `--no-undefined`), so the link
      #       step prints `[N/M] Linking CXX shared library
      #       lib/libtorch_hip.so` and exits 0.
      #   (c) The failure surfaces at runtime when dlopen(libtorch_hip)
      #       checks symbols. Surfaced by slurm 9980 (PT 2.12.0 +
      #       rocm-7.2.3, 2026-05-18 22:25), C1 validation step:
      #          ImportError: …/libtorch_hip.so: undefined symbol:
      #                      __truncsfbf2
      #       log: logs_05_18_2026/rocm-7.2.3_9980/log_pytorch_v2.12.0_05_18_2026.txt
      #
      # The static archive libclang_rt.builtins-x86_64.a inside ROCm's
      # bundled clang (clang/19 on ROCm 6.4, clang/20 on ROCm 7.0/7.1,
      # clang/22 on ROCm 7.2+) defines __truncsfbf2 (and friends).
      # Probe on 2026-05-18:
      #   ROCm 6.4.3 → clang/19/.../libclang_rt.builtins-x86_64.a: T __truncsfbf2
      #   ROCm 7.0.2 → clang/20/.../libclang_rt.builtins-x86_64.a: T __truncsfbf2
      #   ROCm 7.1.1 → clang/20/.../libclang_rt.builtins-x86_64.a: T __truncsfbf2
      #   ROCm 7.2.0 → clang/22/.../libclang_rt.builtins-x86_64.a: T __truncsfbf2
      #   ROCm 7.2.2 → clang/22/.../libclang_rt.builtins-x86_64.a: T __truncsfbf2
      #   ROCm 7.2.3 → clang/22/.../libclang_rt.builtins-x86_64.a: T __truncsfbf2
      # Only the .a is shipped (no .so), so we link it at build time
      # rather than relying on LD_LIBRARY_PATH at import time.
      #
      # Why LDFLAGS (with --whole-archive) and not
      # CMAKE_SHARED_LINKER_FLAGS / TORCH_HIP_LINK_FLAGS:
      # PyTorch's setup.py + cmake glue passes LDFLAGS through to
      # CMAKE_EXE/SHARED/MODULE_LINKER_FLAGS_INIT (cmake's standard
      # env-var-to-flag bridge). Those LINKER_FLAGS variables are
      # placed by cmake near the FRONT of the final link command
      # (before the .o object files), e.g. confirmed in slurm 9996
      # log line 83733 for torch/_C.cpython-310-x86_64-linux-gnu.so:
      #   gcc -shared … -Wl,-rpath,…/llvm/lib \
      #     /shared/.../libclang_rt.builtins-x86_64.a \
      #     build/temp.../torch/csrc/stub.o \
      #     -L… -ltorch_python -o …
      # That ordering breaks plain static-archive scan semantics:
      # when ld processes the .a, NOTHING is undefined yet (no .o has
      # been scanned), so ld pulls 0 symbols from the .a; then the
      # .o file references __truncsfbf2 -- too late, .a has already
      # been finalized. Net effect of plain LDFLAGS injection: the
      # .so is built EXACTLY as if the .a weren't there at all and
      # dlopen still fails with `undefined symbol: __truncsfbf2`
      # (slurm 9996, 2026-05-19 00:49 fail). This silent "the flag
      # is there but useless" mode is why the cmake configure dump
      # at log line 46707 shows the .a in `Shared LD flags` and
      # yet the runtime import still trips.
      #
      # Force the bf16 builtins in via --whole-archive: this tells
      # ld to bring in EVERY symbol from the named archive regardless
      # of scan order, so position-in-command-line stops mattering.
      # libclang_rt.builtins-x86_64.a is small (a few hundred KB) and
      # only carries low-level runtime helper routines; pulling all
      # of it into every torch .so is a tiny size cost in exchange
      # for a deterministic resolution of __truncsfbf2 and friends.
      # `--push-state` / `--pop-state` (binutils ≥ 2.30, present on
      # Ubuntu 22.04 and RHEL 9) localises the --whole-archive scope
      # so it does NOT affect any subsequent libraries the linker
      # picks up via -l flags. References:
      #   ld(1) man page: "--push-state, --pop-state"
      #   GCC bug 90453 (rationale for --push-state on static libs)
      #
      # ── Gating: PT 2.12+ only ─────────────────────────────────────────
      # PT 2.10 and PT 2.11 do not emit unresolved __truncsfbf2 in
      # libtorch_hip.so (verified by all-green builds 9967/9989/9990/9991
      # without any LDFLAGS injection, see audit 2026-05-19). Injecting
      # the builtins archive for those versions is at best inert and at
      # worst breaks the build (see "fmaxl/logbl" regression below), so
      # we only enable it for PT 2.12+ where it actually matters.
      #
      # ── -lm safety net (anti-regression) ──────────────────────────────
      # 2026-05-19 regression: with --whole-archive, CMake's basic C
      # compiler sanity check (CMakeTestCCompiler.cmake -> /usr/bin/cc
      # linking testCCompiler.c with NO -lm) pulls in __divxc3 (complex
      # long double division) from the archive, which references fmaxl
      # and logbl from libm. Those go unresolved and CMake aborts:
      #     /usr/bin/ld: …libclang_rt.builtins-x86_64.a(divxc3.c.o):
      #       in function `__divxc3':
      #     divxc3.c:(.text+0x47): undefined reference to `fmaxl'
      #     divxc3.c:(.text+0x4f): undefined reference to `logbl'
      #     collect2: error: ld returned 1 exit status
      # Surfaced by slurm 9992 (PT 2.11.0+rocm-7.1.0) and 9993 (PT 2.11.0
      # +rocm-7.0.2), both failing at log line 45530.
      #     log: logs_05_19_2026/rocm-7.1.0_9992/log_pytorch_v2.11.0_05_19_2026.txt
      #
      # CMake propagates env LDFLAGS into try-compile via
      # CMAKE_EXE_LINKER_FLAGS_INIT, so EVERY try-compile inherits the
      # archive. We append `-Wl,--as-needed -lm -Wl,--no-as-needed` at
      # the end of LDFLAGS so:
      #   - libm satisfies fmaxl/logbl pulled in by --whole-archive of
      #     the builtins archive (resolves the cmTC failure above);
      #   - --as-needed prevents adding a spurious DT_NEEDED on libm
      #     in .so files that don't actually use libm symbols (keeps
      #     ldd output of torch's .so files clean);
      #   - --no-as-needed restores the linker default state so later
      #     LDFLAGS contributions from PyTorch's own cmake glue keep
      #     their original semantics. Empirically verified on all 8
      #     ROCm versions (rocm-7.0.0 → 7.2.3) on 2026-05-19.
      _CLANG_RT_GLOB="${ROCM_PATH}/llvm/lib/clang/*/lib/linux/libclang_rt.builtins-x86_64.a"
      _CLANG_RT_BUILTINS=$(ls -1 ${_CLANG_RT_GLOB} 2>/dev/null | head -1)
      _PT_MAJOR=$(echo "${PT_MAJOR_MINOR:-0.0}" | cut -d. -f1)
      _PT_MINOR=$(echo "${PT_MAJOR_MINOR:-0.0}" | cut -d. -f2)
      _PT_NEEDS_BF16_INJECTION=0
      if [ "${_PT_MAJOR:-0}" -gt 2 ] 2>/dev/null; then
         _PT_NEEDS_BF16_INJECTION=1
      elif [ "${_PT_MAJOR:-0}" -eq 2 ] 2>/dev/null && [ "${_PT_MINOR:-0}" -ge 12 ] 2>/dev/null; then
         _PT_NEEDS_BF16_INJECTION=1
      fi
      if [ "${_PT_NEEDS_BF16_INJECTION}" -eq 1 ]; then
         if [ -f "${_CLANG_RT_BUILTINS}" ]; then
            export LDFLAGS="${LDFLAGS:-} -Wl,--push-state,--whole-archive ${_CLANG_RT_BUILTINS} -Wl,--pop-state -Wl,--as-needed -lm -Wl,--no-as-needed"
            echo "[bf16-builtins] PT ${PT_MAJOR_MINOR} >= 2.12 -- injecting compiler-rt builtins archive (--whole-archive) + -lm safety net into LDFLAGS:"
            echo "                ${_CLANG_RT_BUILTINS}"
         else
            echo "WARNING: clang_rt.builtins-x86_64.a not found under" >&2
            echo "         ${_CLANG_RT_GLOB}" >&2
            echo "         PT 2.12+ may fail at 'import torch' with" >&2
            echo "         ImportError: undefined symbol __truncsfbf2" >&2
         fi
      else
         echo "[bf16-builtins] PT ${PT_MAJOR_MINOR} < 2.12 -- skipping compiler-rt builtins LDFLAGS injection"
         echo "                (PT 2.10/2.11 do not emit unresolved __truncsfbf2; injection breaks CMake sanity check via fmaxl/logbl, see 9992/9993)"
      fi
      unset _CLANG_RT_GLOB _CLANG_RT_BUILTINS _PT_MAJOR _PT_MINOR _PT_NEEDS_BF16_INJECTION

      # ── Compiler selection: rely on system GCC (NOT amdclang) ─────────
      # We deliberately do NOT load the amdclang module for the build,
      # AND magma's modulefile (post-2026-05-04 Option B fix) no longer
      # transitively loads it either. So CC/CXX fall through to
      # PyTorch's CMake autodetect, which picks the system GCC
      # (Ubuntu 22.04: GCC 11.4). This matches the four ROCm versions
      # in the user's success study (7.1.0 / 7.1.1 / 7.2.0 / 7.2.1, all
      # PyTorch 2.9.1, all built before "amdclang" was briefly added to
      # REQUIRED_MODULES).
      #
      # Why GCC and not amdclang: ROCm 7.x bundles clang 22, which per
      # LLVM #85656 mangles SFINAE-defaulted std::enable_if NTTPs with
      # the long form (..Tn..enable_if..Li0EEE..). HIP TUs (driven via
      # hipcc) still emit short-form references (..Li0EEE.. only). When
      # CPU TUs are also built by amdclang the libtorch_cpu /
      # libtorch_hip dynamic-symbol tables drift: cpu defines LONG, hip
      # references SHORT, dlopen fails at "import torch":
      #   ImportError: libtorch_hip.so: undefined symbol:
      #   _ZNK2at10TensorBase14const_data_ptrIN3c104HalfELi0EEEPKT_v
      # GCC 11.4 emits the SHORT form (matching the historical clang<=17
      # ABI), which matches the HIP-side references. The C1 import-torch
      # validation block below catches any future regression of this
      # class (search "C1 validation"). References:
      #   PyTorch issue #173707 (still open, 2026-02-24)
      #   LLVM issue #85656 (mangling change clang>=18)
      #   slurm 8065 (rocm-7.2.1, amdclang build, FAILED at runtime)
      #   slurm 8066 (rocm-7.2.0, amdclang build, FAILED at runtime)
      #   slurm 8093 (transitive amdclang via magma; needed CC/CXX firewall)
      #   slurm 8096 (firewall worked, build OK; firewall now obsolete
      #               after Option B moved the fix to magma's modulefile)

      # ── Disable Intel MKL detection on ROCm builds ────────────────────
      # When Intel oneAPI is visible on the build host (e.g. via
      # /opt/intel/oneapi/mkl on PATH/LD_LIBRARY_PATH/CPATH), PyTorch's
      # CMake auto-detects MKL and links libtorch_cpu / libtorch_global_deps
      # against /opt/intel/oneapi/mkl/.../libmkl_intel_thread.so.
      # That DSO needs Intel's libiomp5.so for the OpenMP API symbols
      # (omp_get_max_active_levels, etc).  iomp5 is NOT in the chain we
      # ship -- our MAGMA + ROCm-libomp.so combination uses LLVM-OMP --
      # so at "import torch" time the ctypes.CDLL of libtorch_global_deps
      # raises:
      #   OSError: /opt/intel/oneapi/mkl/.../libmkl_intel_thread.so.2:
      #            undefined symbol: omp_get_max_active_levels
      # First seen in slurm 8032 (2026-05-02 17:00) right after the wheel
      # install succeeded -- the error only fires at first import, so
      # main_setup.sh's per-package check passed, and the failure surfaced
      # during the *next* package (deepspeed) which does `import torch`
      # in its setup.py.
      # Fix: keep MKL OUT of the build entirely; CPU BLAS comes from
      # OpenBLAS (which magma_setup.sh now installs at the right version),
      # MKLDNN/oneDNN can still build, just without the MKL backend.
      export USE_MKL=0
      export BLAS=OpenBLAS
      export OpenBLAS_HOME=${MAGMA_PATH:-/usr}
      export PYTORCH_ROCM_ARCH=${AMDGPU_GFXMODEL}
      export PYTORCH_INSTALL_DIR=${PYTORCH_PATH}
      export AOTRITON_INSTALLED_PREFIX=${AOTRITON_PATH}
      # ── PT 2.9+ fbgemm_genai kill-switch ───────────────────────────
      # fbgemm_genai is an experimental feature introduced in PT 2.9
      # and carried forward to PT 2.10/2.11/2.12. It pulls in
      # third_party/fbgemm/external/composable_kernel headers. On
      # ROCm 7.x those headers fail to compile:
      #   ck/utility/get_id.hpp:10: error: constexpr function never
      #     produces a constant expression
      #   ck/tensor_operation/gpu/block/blockwise_gemm_pipeline_xdlops_v2.hpp:
      #     {143,145,148,633,635}: error: constexpr variable must be
      #     initialized by a constant expression
      #   ck/tensor_operation/gpu/device/impl/
      #     device_grouped_gemm_multiple_d_xdl_cshuffle_tile_loop.hpp:208:
      #     error: reference to __host__ variable in __global__ function
      # First observed in slurm-9332-rocmplus-7.1.1 PT 2.9.1 leaf
      # (log line 50085) and slurm-9333-rocmplus-7.0.2 PT 2.9.1 leaf
      # (log line 50109) on 2026-05-13/14.
      #
      # Arch match expanded from *gfx942* to *gfx9* on 2026-05-14:
      # the original gate was written when only gfx942 was tested. The
      # sweep on 2026-05-13 ran with AMDGPU_GFXMODEL='gfx942;gfx90a'
      # and the failure was identical -- composable_kernel's constexpr/
      # builtin-non-constant issue is a HOST-side compile error that
      # fires regardless of the gfx target, but the fbgemm_genai source
      # only ever compiles when at least one gfx9-class arch is
      # requested (it's CDNA-only code). Matching the whole gfx9 family
      # (gfx906/908/90a/942/950) is the future-proof minimum; RDNA
      # (gfx10/11/12) is untested here and stays enabled.
      #
      # PT version gate widened from "2.9" to "2.9|2.10|2.11|2.12" on
      # 2026-05-14: the 2026-05-14 sweep showed PT 2.11 on ROCm 7.2.3
      # (slurm 9422 default PT) reached `Successfully built torch` /
      # `Finished setup.py install` and falsely passed the C1 import
      # check, then produced a hollow install (pytorch/ subdir 4 KB,
      # libtorch_cpu.so missing) -- exactly the same upstream
      # pip-redirect symptom that motivated the PT 2.9 gate. Until
      # upstream restores `setup.py install` semantics this gate must
      # cover all post-PT-2.9 versions.
      case "${PYTORCH_SHORT_VERSION}" in
         2.9|2.10|2.11|2.12)
            if [[ "${AMDGPU_GFXMODEL}" == *"gfx9"* ]]; then
               export USE_FBGEMM_GENAI=0
            fi
            ;;
      esac

      # ── PyTorch CORE source: shallow recursive git clone ─────────────
      # We previously used `wget` of the GitHub release tarball
      # (https://github.com/pytorch/pytorch/releases/download/v${VER}/
      # pytorch-v${VER}.tar.gz). That is faster (~smaller, no .git/) but
      # the release tarball OMITS the .ci/ directory -- it is in the git
      # tree only. PT 2.7.x's tools/build_pytorch_libs.py:97
      # read_nccl_pin() unconditionally opens
      #   .ci/docker/ci_commit_pins/nccl-cu12.txt
      # so setup.py install fails with
      #   FileNotFoundError: [Errno 2] ... .ci/docker/ci_commit_pins/nccl-cu12.txt
      # First seen in slurm 9324 + 9326 (PT 2.7.1 on rocm-7.1.1, after the
      # ld.lld shim cells were added). PT 2.8+ does not call
      # read_nccl_pin() so it would not have hit this codepath, but
      # reverting CORE to git clone is the smallest version-agnostic fix
      # and matches the historical (commented-out) shape this script used
      # before the wget switch.
      #
      # The wget-based downloads for torchvision and torchaudio (further
      # down) STAY: those projects do not have .ci/-style ancillary files
      # and the smaller tarball saves on each companion build.
      #
      # We clone INTO the directory name pytorch-v${PYTORCH_VERSION} so
      # the rest of this script (cd, source-tree patches, modulefile
      # naming) is unchanged from the wget+tar flow.
      #
      # Retry loop guards against transient github.com flakes; matches
      # the shape used by openmpi_setup.sh / magma_setup.sh.
      RETRIES=6
      DELAY=30
      COUNT=1
      while [ ${COUNT} -le ${RETRIES} ]; do
         git clone --recursive --depth 1 --branch v${PYTORCH_VERSION} \
            https://github.com/pytorch/pytorch pytorch-v${PYTORCH_VERSION}
         if [ $? -eq 0 ]; then
            break
         fi
         if [ ${COUNT} -eq ${RETRIES} ]; then
            echo "ERROR: git clone of pytorch v${PYTORCH_VERSION} failed after ${RETRIES} attempts"
            exit 1
         fi
         echo "git clone attempt ${COUNT} failed; sleeping ${DELAY}s and retrying..."
         ${SUDO} rm -rf "pytorch-v${PYTORCH_VERSION}"
         COUNT=$((COUNT + 1))
         sleep ${DELAY}
      done

      cd pytorch-v${PYTORCH_VERSION}

      # ── MAGMA 2.10+ compatibility (backport of pytorch PR #180388) ───
      # PyTorch v2.9.1 (and earlier) encodes AT_MAGMA_VERSION as
      #   MAJOR*100 + MINOR*10 + MICRO
      # which overflows when MAGMA's MINOR reaches 10 (current MAGMA
      # master tag is v2.10.0).  A hard #error in
      #   aten/src/ATen/native/cuda/linalg/BatchLinearAlgebra.cpp
      # then aborts the build with:
      #   "MAGMA release minor or micro version >= 10, please correct
      #    AT_MAGMA_VERSION"
      # First seen in slurm 8017 (rc=1, magma=2.10.0, pytorch=2.9.1).
      # Upstream pytorch fixed this in PR #180388 (commit 5c3f8fd1,
      # 2026-04-16) by widening the encoding to
      #   MAJOR*10000 + MINOR*100 + MICRO
      # and bumping the (only) magic-number consumer (>= 254) to its
      # new-encoding equivalent (>= 20504).  We backport the same patch
      # here.  Hipify regenerates the HIP variant from this CUDA source
      # at configure time, so patching the CUDA file alone propagates
      # to torch_hip.  The grep guard makes this idempotent and a no-op
      # on PyTorch versions that already include PR #180388.
      _BLA="aten/src/ATen/native/cuda/linalg/BatchLinearAlgebra.cpp"
      if [ -f "${_BLA}" ] && grep -q 'MAGMA_VERSION_MAJOR\*100 + MAGMA_VERSION_MINOR\*10' "${_BLA}"; then
         echo "Patching ${_BLA} for MAGMA 2.10+ compatibility (backport of pytorch PR #180388)"
         sed -i \
            -e 's#MAGMA_VERSION_MAJOR\*100 + MAGMA_VERSION_MINOR\*10 + MAGMA_VERSION_MICRO#MAGMA_VERSION_MAJOR*10000 + MAGMA_VERSION_MINOR*100 + MAGMA_VERSION_MICRO#g' \
            -e 's#MAGMA_VERSION_MINOR >= 10 || MAGMA_VERSION_MICRO >= 10#MAGMA_VERSION_MINOR >= 100 || MAGMA_VERSION_MICRO >= 100#g' \
            -e 's#MAGMA release minor or micro version >= 10#MAGMA release minor or micro version >= 100#g' \
            -e 's#AT_MAGMA_VERSION >= 254#AT_MAGMA_VERSION >= 20504#g' \
            "${_BLA}"
         echo "  -> patched (verify):"
         grep -nE 'AT_MAGMA_VERSION|MAGMA release minor' "${_BLA}" | sed 's/^/    /'
      else
         echo "Skipping ${_BLA} MAGMA 2.10+ patch (file missing or already patched)"
      fi

      # ── kCUDABlockReduceMaxThreads constexpr fix (PT 2.7/2.8 + ROCm 7.x)
      # On ROCm 7.1.1+, /opt/rocm/include/hip/amd_detail/amd_warp_functions.h
      # declares warpSize as
      #   __device__ __attribute__((always_inline, const))
      #     operator int() const noexcept { ... }
      # i.e. a runtime device function (because RDNA wave32 vs CDNA
      # wave64 is per-target and HIP refuses to commit to a literal at
      # compile time). c10/macros/Macros.h:315 then has
      #   #define C10_WARP_SIZE warpSize
      # so any constexpr expression that multiplies C10_WARP_SIZE is no
      # longer a constant expression.
      # PT 2.7 + 2.8 ship aten/src/ATen/native/cuda/block_reduce.cuh:17
      #   constexpr int kCUDABlockReduceMaxThreads = C10_WARP_SIZE * C10_WARP_SIZE;
      # which -- on ROCm 7.x -- fails to compile with
      #   error: constexpr variable 'kCUDABlockReduceMaxThreads' must be
      #   initialized by a constant expression
      #   note: non-constexpr function 'operator int' cannot be used in
      #   a constant expression
      # First seen in slurm 9324 (PT 2.8.0 on rocm-7.1.1, ninja step
      # 6967/7867 ~ 88% through HIP compilation; the same header is
      # included by DepthwiseConv2d, DistanceKernel, and ~20 other .hip
      # sources, so the same diagnostic fires repeatedly).
      # Upstream PT 2.9+ rewrote this to use a runtime constant
      # (at::cuda::warp_size() etc.) so the bug is gone there -- hence
      # this gate is restricted to PT major.minor in {2.7, 2.8}.
      # Fix: relax `constexpr` -> `static const`. The two consumers
      # (BlockReduceSum, BlockReduce in ATen) use this as a kernel size
      # hint; nothing here is a template parameter or array-bound that
      # requires constexpr semantics on a non-device translation unit.
      # We patch the CUDA source -- hipify regenerates the HIP variant
      # from this CUDA source at build time, so the patch propagates to
      # aten/src/ATen/native/hip/block_reduce.cuh automatically (same
      # propagation pattern as the MAGMA patch above).
      # The grep guard makes this idempotent and a no-op on PT 2.9+ or
      # any future PT that has already been fixed upstream. The (Max|Num)
      # alternation is forward-defensive: PT 2.8 has only Max, but if a
      # future-but-still-pre-2.9 patch adds a Num twin, both get caught.
      _BR=aten/src/ATen/native/cuda/block_reduce.cuh
      case "${PT_MAJOR_MINOR}" in
         2.7|2.8)
            if [ -f "${_BR}" ] && grep -qE '^[[:space:]]*constexpr[[:space:]]+int[[:space:]]+kCUDABlockReduce(Max|Num)Threads' "${_BR}"; then
               echo "Patching ${_BR} for ROCm 7.x warpSize-not-constexpr (PT ${PYTORCH_VERSION})"
               sed -i -E 's#^([[:space:]]*)constexpr([[:space:]]+)int([[:space:]]+)kCUDABlockReduce(Max|Num)Threads#\1static const\2int\3kCUDABlockReduce\4Threads#' "${_BR}"
               echo "  -> patched (verify):"
               grep -nE 'kCUDABlockReduce(Max|Num)Threads' "${_BR}" | sed 's/^/    /'
            else
               echo "Skipping ${_BR} constexpr patch (file missing or already patched)"
            fi
            ;;
         *)
            echo "Skipping ${_BR} constexpr patch (PT ${PYTORCH_VERSION} not in {2.7, 2.8} gate; PT 2.9+ has the upstream fix)"
            ;;
      esac

      # ── Root-cause patch: warpSize / C10_WARP_SIZE on ROCm 7.x ──
      # (covers Failure D, E, and F, all observed across the 2026-05-13
      #  to 2026-05-15 sweeps; see audit_2026_05_15.md for the matrix)
      #
      # Background. PT 2.7 / 2.8 sources reference the wavefront size in
      # three distinct ways:
      #   (a) `warpSize`                          (host-illegal builtin)
      #   (b) `C10_WARP_SIZE`  (= warpSize macro) (host-illegal, same)
      #   (c) `__AMDGCN_WAVEFRONT_SIZE`           (clang-defined int macro)
      # And ROCm has THREE distinct compiler regimes:
      #   ROCm 6.x      : both (a) and (c) work; (c) is a constexpr-int
      #                   macro set by --offload-arch.
      #   ROCm 7.0/7.1  : (a) host-illegal (Failure D); (c) declared but
      #                   no longer constexpr-evaluable in CK template
      #                   contexts (Failure E in third_party/CK headers).
      #   ROCm 7.2.x    : (a) host-illegal; (c) UNDECLARED in the host
      #                   compile pass (Failure F in DepthwiseConv3d.hip
      #                   when reached via the C10_WARP_SIZE redirect).
      # PT 2.9+ replaced `#define C10_WARP_SIZE warpSize` with a runtime
      # helper (`at::cuda::warp_size()` etc.) so all of D/E/F are gone
      # there; this patch is gated to PT major.minor in {2.7, 2.8}.
      #
      # Why a literal `64` and not __AMDGCN_WAVEFRONT_SIZE.
      # The 2026-05-14 staging swap (Fix 3 v1) redirected
      #   #define C10_WARP_SIZE  warpSize    ->    __AMDGCN_WAVEFRONT_SIZE
      # which fixed Failure D on rocm-7.0/7.1 but UNMASKED Failure F on
      # rocm-7.2.x (DepthwiseConv3d.hip line 221: 'use of undeclared
      # identifier __AMDGCN_WAVEFRONT_SIZE') and did nothing for the
      # CK-third_party Failure E on either rocm-7.0 or rocm-7.1. Both
      # symbols (warpSize, __AMDGCN_WAVEFRONT_SIZE) are moving targets
      # across rocm-7 minors. The literal `64` is stable across all
      # three regimes and yields a valid constant expression in EVERY
      # constexpr/template/array-bound use site.
      #
      # Why this is safe.
      # We sweep gfx942;gfx90a only, both gfx9 (wavefront size 64).
      # Clang's --offload-arch=gfx9* already implies __AMDGCN_WAVEFRONT_SIZE=64
      # so this substitution does NOT change runtime semantics for any
      # supported target. If the sweep ever extends to gfx10/11/12
      # (wavefront 32), gate this block on AMDGPU_GFXMODEL containing
      # only gfx9, or compute the literal from AMDGPU_GFXMODEL at patch
      # time. The block_reduce.cuh `constexpr -> static const` patch
      # above remains belt-and-suspenders for the same reason.
      #
      # Two patch sites:
      #   (1) c10/macros/Macros.h         -- redirect C10_WARP_SIZE -> 64
      #                                      (closes D in PT-core sources
      #                                       and F in DepthwiseConv3d.hip)
      #   (2) third_party/composable_kernel/include/ck/**/*.hpp
      #                                   -- substitute the literal 64
      #                                      everywhere CK references
      #                                      __AMDGCN_WAVEFRONT_SIZE
      #                                      (closes E)
      _GFX_LIT=64   # gfx9 wavefront size (literal); see "Why this is safe" above
      _MACROS_H=c10/macros/Macros.h
      case "${PT_MAJOR_MINOR}" in
         2.7|2.8)
            if [ -f "${_MACROS_H}" ] && grep -qE '^#define[[:space:]]+C10_WARP_SIZE[[:space:]]+warpSize' "${_MACROS_H}"; then
               echo "Patching ${_MACROS_H} C10_WARP_SIZE -> ${_GFX_LIT} (literal) for ROCm 7.x (PT ${PYTORCH_VERSION}, Failures D+F)"
               sed -i -E "s|^(#define[[:space:]]+C10_WARP_SIZE[[:space:]]+)warpSize|\\1${_GFX_LIT}|" "${_MACROS_H}"
               echo "  -> patched (verify):"
               grep -nE 'C10_WARP_SIZE' "${_MACROS_H}" | sed 's/^/    /'
            else
               echo "Skipping ${_MACROS_H} C10_WARP_SIZE patch (file missing or already patched)"
            fi

            # ── (2) composable_kernel third_party headers (Failure E) ──
            # CK template parameter computations (WgpPerCU,
            # FullMemBandPrefetchStages, PrefetchStages, GlobalBufferNum,
            # plus a chain of constexpr-if conditions in
            # device_batched_gemm_multiple_d_xdl_cshuffle_v3.hpp) all
            # transitively call ck::get_warp_size() in
            # third_party/composable_kernel/include/ck/utility/get_id.hpp:
            #   __host__ __device__ constexpr index_t get_warp_size()
            #   {
            #       return warpSize;            // <-- the culprit
            #   }
            # On rocm-7.0.x and rocm-7.1.x clang, `warpSize` is a
            # struct with a non-constexpr `operator int()`
            # (= __builtin_amdgcn_wavefrontsize), so the constexpr
            # function "never produces a constant expression". The
            # cascade was observed in slurm-9479 PT 2.7.1 (rocm-7.1.1),
            # slurm-9480 PT 2.7.1 + PT 2.8.0 (rocm-7.0.2), and most
            # recently slurm-9694 PT 2.7.1 + PT 2.8.0 (rocm-7.0.2):
            # get_id.hpp:10:39 + 13:12, blockwise_gemm_pipeline*
            # :143-148, device_batched_gemm_multiple_d* :486-684, and
            # gridwise_gemm_xdl_cshuffle_v3_multi_d* :1336.
            #
            # Fix-3 v2 (2026-05-15) only sed'd __AMDGCN_WAVEFRONT_SIZE
            # in CK headers and skipped CK with "no __AMDGCN_WAVEFRONT_SIZE
            # references" -- correctly, since CK doesn't use that symbol;
            # it uses bare `warpSize`. Slurm-9694 confirmed the skip and
            # that PT 2.7.1 + PT 2.8.0 still failed in the same
            # constexpr-cascade as before.
            #
            # Fix-3 v3 (this block): substitute `warpSize` (with `\b`
            # word boundaries to avoid clobbering identifiers like
            # `someWarpSizeBoundary`) AND keep the historical
            # __AMDGCN_WAVEFRONT_SIZE substitution as a defensive
            # belt-and-suspenders for any future CK pin that introduces
            # the symbol. Both map to the same literal 64 (gfx9-only
            # sweep; see "Why this is safe" comment above the c10
            # redirect for the gfx-extension story). Idempotent
            # (already-patched headers have zero occurrences of either
            # symbol and the grep returns an empty file list).
            # NB: use `#` as the sed delimiter (NOT `|`) -- the regex
            # contains an alternation `\b(A|B)\b`, and a `|` delimiter
            # would terminate the pattern at the first `|` of the
            # alternation, producing
            #   sed: -e expression #1, char 44: unknown option to `s'
            # silently failing to patch anything. (Verified live in
            # slurm-9703/9704 PT 2.7.1+2.8.0 logs: sed errored, the
            # subsequent `grep` showed all `warpSize` references intact,
            # and the build hit the identical Failure-E cascade.) `#`
            # appears nowhere in the regex, replacement, or input lines
            # so it's safe.
            _CK_DIR=third_party/composable_kernel/include/ck
            if [ -d "${_CK_DIR}" ]; then
               # shellcheck disable=SC2207
               _CK_FILES=( $(grep -rlE --include='*.hpp' --include='*.h' \
                                '\b(__AMDGCN_WAVEFRONT_SIZE|warpSize)\b' \
                                "${_CK_DIR}" 2>/dev/null || true) )
               if [ "${#_CK_FILES[@]}" -gt 0 ]; then
                  echo "Patching ${#_CK_FILES[@]} composable_kernel header(s) under ${_CK_DIR}: {warpSize, __AMDGCN_WAVEFRONT_SIZE} -> ${_GFX_LIT} (Failure E)"
                  if ! sed -i -E "s#\\b(__AMDGCN_WAVEFRONT_SIZE|warpSize)\\b#${_GFX_LIT}#g" "${_CK_FILES[@]}"; then
                     echo "ERROR: sed substitution on CK headers FAILED (rc=$?). Refusing to continue -- the constexpr cascade will not be closed and the wheel build is destined to fail." >&2
                     exit 1
                  fi
                  _CK_RESID=$(grep -rnE --include='*.hpp' --include='*.h' \
                               '\b(__AMDGCN_WAVEFRONT_SIZE|warpSize)\b' "${_CK_DIR}" 2>/dev/null || true)
                  if [ -z "${_CK_RESID}" ]; then
                     echo "  -> patched ${#_CK_FILES[@]} files (0 residual occurrences -- OK)"
                  else
                     echo "ERROR: ${#_CK_FILES[@]} CK headers patched but residual {warpSize, __AMDGCN_WAVEFRONT_SIZE} occurrences remain (sed escape / boundary mismatch). Aborting." >&2
                     echo "${_CK_RESID}" | sed 's/^/    /' >&2
                     exit 1
                  fi
               else
                  echo "Skipping ${_CK_DIR} CK header patch (no warpSize / __AMDGCN_WAVEFRONT_SIZE references; either upstream-fixed or already patched)"
               fi
            else
               echo "Skipping ${_CK_DIR} CK header patch (directory missing -- PT ${PYTORCH_VERSION} likely vendors CK at a different path)"
            fi
            ;;
         *)
            echo "Skipping ${_MACROS_H} C10_WARP_SIZE patch (PT ${PYTORCH_VERSION} not in {2.7, 2.8} gate; PT 2.9+ has the upstream fix via at::cuda::warp_size())"
            echo "Skipping composable_kernel CK header patch (PT ${PYTORCH_VERSION} not in {2.7, 2.8} gate)"
            ;;
      esac

      # ── HIP bf16 host-compat patch for therock-23.2.0+ ────────────────
      # SDK-level patch (NOT in pytorch source tree) -- see the function
      # comment block above patch_rocm_bf16_header_for_gcc() for the full
      # diagnosis. Idempotent + sentinel-guarded; on rocm-7.0.0...7.2.1
      # this is not strictly needed (no e5m3 chain to expose the bug)
      # but the patch is still applied because the header is identically
      # broken there too -- the typedef block stays #if-skipped on
      # clang/amdclang/hipcc, so it's a no-op runtime-wise on those SDKs.
      patch_rocm_bf16_header_for_gcc

      # ── HIP_CXX_FLAGS leak to torch_python C sources (issue #103222) ──
      # caffe2/CMakeLists.txt:1768 (v2.9.1; same line in upstream main):
      #   target_compile_options(torch_hip PUBLIC ${HIP_CXX_FLAGS})  # experiment
      # HIP_CXX_FLAGS contains "-std=c++17" (Dependencies.cmake:1011).
      # PUBLIC propagation drags those flags into every consumer of
      # torch_hip, including torch_python -- which compiles plain C
      # sources (csrc/dynamo/cpython_defs.c).  amdclang then errors:
      #   error: invalid argument '-std=c++17' not allowed with 'C'
      # First seen in slurm 8024 (2026-05-02 14:44, ninja step 7591/8074).
      # Upstream issue #103222 is OPEN (unfixed) as of today; main has
      # the same broken line.  Fix: wrap HIP_CXX_FLAGS in a
      # $<COMPILE_LANGUAGE:CXX> generator expression so the flags only
      # apply to C++ compilations.  The "# experiment" comment is the
      # unique anchor; grep guard makes the patch idempotent.
      _CAF=caffe2/CMakeLists.txt
      if [ -f "${_CAF}" ] && grep -q 'target_compile_options(torch_hip PUBLIC ${HIP_CXX_FLAGS})  # experiment' "${_CAF}"; then
         echo "Patching ${_CAF} for HIP_CXX_FLAGS C-leak (workaround for pytorch issue #103222)"
         sed -i 's|target_compile_options(torch_hip PUBLIC ${HIP_CXX_FLAGS})  # experiment|target_compile_options(torch_hip PUBLIC "$<$<COMPILE_LANGUAGE:CXX>:${HIP_CXX_FLAGS}>")  # filter to CXX so -std=c++17 etc. do not leak to .c files via PUBLIC propagation (workaround for #103222)|' "${_CAF}"
         echo "  -> patched (verify):"
         grep -nE 'torch_hip PUBLIC.*HIP_CXX_FLAGS' "${_CAF}" | sed 's/^/    /'
      else
         echo "Skipping ${_CAF} HIP_CXX_FLAGS patch (file missing or already patched)"
      fi

      # ── Autograd codegen: increase shard count for the long-tail TUs ──
      # The 4 ninja monsters that dominate caffe2/torch_cpu wall time are:
      #   TraceType_3.cpp.o, TraceType_4.cpp.o,
      #   ADInplaceOrViewType_0.cpp.o, ADInplaceOrViewType_1.cpp.o
      # Each compiles single-threaded for 35-45 min on amdclang++ at -O3
      # (see slurm 8032 .ninja_log: TraceType_4 finished at ninja step
      # 7126/8074 while step ~6500 already had everything else done).
      # The shard counts come from autograd codegen:
      #   tools/autograd/gen_trace_type.py        : num_shards=5  (TraceType_*)
      #   tools/autograd/gen_inplace_or_view_type.py: num_shards=2  (ADInplaceOrViewType_*)
      # Doubling them splits each monster TU into ~half-size shards and
      # roughly halves the long-tail wall time (~15-20 min off every
      # PyTorch build).  Each shard is independent so the total compile
      # work is unchanged; we trade more parallelism for more files.
      # The sed anchors the substitution on the unique env_callable line
      # immediately above num_shards, so the patch is robust against
      # other "num_shards=5" / "num_shards=2" occurrences elsewhere in
      # torchgen.  Each grep guard makes the patch idempotent.
      _GTT=tools/autograd/gen_trace_type.py
      if [ -f "${_GTT}" ] && grep -q 'env_callable=gen_trace_type_func,' "${_GTT}"; then
         echo "Patching ${_GTT}: TraceType num_shards 5 -> 10 (long-tail mitigation)"
         sed -i '/env_callable=gen_trace_type_func,/{n;s/num_shards=5,/num_shards=10,/}' "${_GTT}"
         echo "  -> patched (verify):"
         grep -nB1 'num_shards=' "${_GTT}" | grep -A1 gen_trace_type_func | sed 's/^/    /'
      else
         echo "Skipping ${_GTT} shard patch (file missing or anchor not found)"
      fi

      _GIV=tools/autograd/gen_inplace_or_view_type.py
      if [ -f "${_GIV}" ] && grep -q 'env_callable=gen_inplace_or_view_type_env,' "${_GIV}"; then
         echo "Patching ${_GIV}: ADInplaceOrViewType num_shards 2 -> 4 (long-tail mitigation)"
         sed -i '/env_callable=gen_inplace_or_view_type_env,/{n;s/num_shards=2,/num_shards=4,/}' "${_GIV}"
         echo "  -> patched (verify):"
         grep -nB1 'num_shards=' "${_GIV}" | grep -A1 gen_inplace_or_view_type_env | sed 's/^/    /'
      else
         echo "Skipping ${_GIV} shard patch (file missing or anchor not found)"
      fi

      if [[ "${USER}" == "root" ]]; then
	 # we will add the environment variables above the line that says "# set up appropriate env variable" in setup.py
	 LINE=`sed -n '/# set up appropriate env variable/=' setup.py | grep -n ""`
	 LINE=`echo ${LINE} | cut -c 3-`

         sed -i ''"${LINE}"'i os.environ["ROCM_HOME"] = '"${ROCM_HOME}"'' setup.py
         sed -i ''"${LINE}"'i os.environ["ROCM_SOURCE_DIR"] = '"${ROCM_SOURCE_DIR}"'' setup.py
         sed -i ''"${LINE}"'i os.environ["PYTORCH_ROCM_ARCH"] = '"${PYTORCH_ROCM_ARCH}"'' setup.py
         sed -i ''"${LINE}"'i os.environ["AOTRITON_INSTALLED_PREFIX"] = '"${AOTRITON_INSTALLED_PREFIX}"'' setup.py
         sed -i ''"${LINE}"'i os.environ["CMAKE_INCLUDE_PATH"] = '"${CMAKE_INCLUDE_PATH}"'' setup.py
         sed -i ''"${LINE}"'i os.environ["LIBS"] = '"${LIBS}"'' setup.py
      fi

      if [ "${PYTORCH_SHORT_VERSION}" == "2.4" ]; then
         # the USE_ROCM define is not passed to the CAFFE2 build
         # https://github.com/pytorch/pytorch/issues/103312
         # We comment out the lines within the USE_ROCM block in the torch/csrc/jit/ir/ir.cpp file
         sed -i -e 's/case cuda/\/\/case cuda/' torch/csrc/jit/ir/ir.cpp
         # prevent Caffe2 from writing into /usr/local/
         sed -i '/install(DIRECTORY ${CMAKE_BINARY_DIR}\/caffe2 DESTINATION ${PYTHON_LIB_REL_PATH}/s/^/#/g' caffe2/CMakeLists.txt
         sed -i '/FILES_MATCHING PATTERN \"\*\.py")/s/^/#/g' caffe2/CMakeLists.txt
      fi

      # ── PT 2.9+ third_party cmake_minimum_required patch ──────────
      # Some bundled third_party submodules (notably the `six` python
      # package that NNPACK's confu fetcher pulls in) ship a top-level
      # CMakeLists.txt whose first line is
      #   cmake_minimum_required(VERSION 2.6)
      # Modern cmake (>= 4.x) hard-errors on this with:
      #   CMake Error at CMakeLists.txt:1 (CMAKE_MINIMUM_REQUIRED):
      #     Compatibility with CMake < 3.5 has been removed from CMake.
      #   ...
      #   -- Configuring incomplete, errors occurred!
      #   Error: could not find CMAKE_PROJECT_NAME in Cache
      # PyTorch's NNPACK build silently falls back when this fetch
      # fails (verified in slurm 9422 PT 2.11 / 9423 PT 2.10 logs
      # where the error appears at the cmake configure stage but the
      # build proceeds to `Successfully built torch`), so the patch
      # is purely about silencing scary-looking error messages in the
      # logs that mask the real failure modes during triage.
      #
      # Gate widened from "2.9" to "2.9|2.10|2.11|2.12" on 2026-05-14
      # after observing the same CMAKE_PROJECT_NAME error in PT 2.10/
      # 2.11 logs (slurm 9422, 9423).
      case "${PYTORCH_SHORT_VERSION}" in
         2.9|2.10|2.11|2.12)
            cd third_party
            find . -name 'CMakeLists.txt' -exec sed -i 's/^CMAKE_MINIMUM_REQUIRED(VERSION .*/CMAKE_MINIMUM_REQUIRED(VERSION 3.5)/' {} +
            cd ..
            ;;
      esac

      # Ensure PyTorch's bundled flatbuffers headers are found before any
      # ROCm-provided flatbuffers headers to avoid version mismatches.
      # Must use target_include_directories on torch_cpu (not global
      # include_directories) because target-level includes take priority
      # over directory-level includes in CMake's compile command ordering.
      echo 'target_include_directories(torch_cpu BEFORE PRIVATE "${CMAKE_SOURCE_DIR}/third_party/flatbuffers/include")' >> caffe2/CMakeLists.txt

      python3 -m pip install -r requirements.txt
      pip3 install -r requirements.txt --target=${INSTALL_PATH}/pypackages

      echo ""
      echo "===================="
      echo "Running build_amd.py (hipification)"
      echo "===================="
      echo ""
      python3 tools/amd_build/build_amd.py
      if [ $? -ne 0 ]; then
         echo "ERROR: build_amd.py (hipification) failed"
         exit 1
      fi

      echo ""
      echo "===================="
      echo "Starting setup.py install"
      echo "===================="
      echo ""
      python3 setup.py install --prefix=${PYTORCH_PATH}
      SETUP_PY_RC=$?
      if [ ${SETUP_PY_RC} -ne 0 ]; then
         echo ""
         echo "######################################################"
         echo "ERROR: pytorch wheel build failed (rc=${SETUP_PY_RC})."
         echo "ERROR: refusing to silently continue with vision/audio/"
         echo "ERROR: triton/sageattention/flash-attn/deepspeed -- those"
         echo "ERROR: would 'install' against a non-existent torch and"
         echo "ERROR: produce a fake-OK install tree (which then fools"
         echo "ERROR: main_setup.sh's per-package summary into reporting"
         echo "ERROR: pytorch=OK while disk has no torch/ directory --"
         echo "ERROR: see audit_2026_05_01.md for the original incident)."
         echo "ERROR:"
         echo "ERROR: Common root causes (search the log above for the"
         echo "ERROR: first 'error:' line):"
         echo "ERROR:   - magma_v2.h cuda.h missing  -> MAGMA_HOME unset"
         echo "ERROR:                                   or pointed at"
         echo "ERROR:                                   /usr (CUDA magma)."
         echo "ERROR:                                   See preflight above."
         echo "ERROR:   - libaotriton_v2.so missing  -> aotriton configure"
         echo "ERROR:                                   failed earlier."
         echo "ERROR:   - HIPHooks.cpp.o failure     -> ROCm/LLVM toolchain"
         echo "ERROR:                                   mismatch."
         echo "######################################################"
         exit 1
      fi
      cd ..
      rm -rf pytorch
      # ── PT 2.9+ site-packages copy (hollow-install fix) ────────────
      # PyTorch 2.9 introduced an upstream pip-redirect:
      #   WARNING: Redirecting 'python setup.py install' to
      #            'pip install . -v --no-build-isolation'
      # see https://github.com/pytorch/pytorch/issues/152276
      # Effect: the torch wheel lands in the VENV's
      # ${PYTORCH_BUILD_DIR}/lib/python3.X/site-packages/, NOT in
      # ${PYTORCH_PATH}/lib/python3.X/site-packages/ (which is what
      # the modulefile prepends to PYTHONPATH).
      # Without the copy step below:
      #   1) setup.py install returns rc=0
      #   2) the C1 `import torch` validation falsely PASSES because
      #      the venv's sys.path is still active during the leaf script
      #   3) the C2 RUNPATH patch step finds libtorch_cpu.so missing
      #      and warns-but-does-not-fail (see Fix 2 in this patch)
      #   4) the modulefile gets written
      #   5) `du -sh ${PYTORCH_PATH}` shows 4 KB -- a hollow install
      # Anyone who `module load`s the resulting modulefile gets
      # everything EXCEPT torch itself (satellites are populated).
      #
      # Gate widened from "2.9" to "2.9|2.10|2.11|2.12" on 2026-05-14
      # after slurm 9422 default PT (PT 2.11.0 on ROCm 7.2.3) reproduced
      # the hollow-install symptom: `Successfully built torch` +
      # `Finished setup.py install` + C1 PASS, but pytorch/ subdir on
      # disk was 4.0 KB and libtorch_cpu.so was missing. PT 2.10 on
      # 9423 was cancelled at flash-attention build but had the same
      # pip-redirect upstream so would have produced the same hollow
      # install if allowed to finish. Until upstream restores
      # `setup.py install` semantics, the copy step must cover all
      # post-PT-2.9 versions.
      case "${PYTORCH_SHORT_VERSION}" in
         2.9|2.10|2.11|2.12)
            PYTORCH_PATH_SITE_PACKAGES=${PYTORCH_PATH}/lib/python3.${PYTHON_VERSION}/site-packages
            ${SUDO} mkdir -p ${PYTORCH_PATH_SITE_PACKAGES}
            ${SUDO} cp -a lib/python*/site-packages/* ${PYTORCH_PATH_SITE_PACKAGES}
            ${SUDO} mkdir -p ${PYTORCH_PATH}/bin
            # ── Shebang rewrite ─────────────────────────────────────
            # pip console_script wrappers (cmake/ninja/ctest/torchrun/pip/...)
            # get baked with `#!${PYTORCH_BUILD_DIR}/bin/python3` -- a /tmp
            # path that disappears with the EXIT trap at end-of-job. Without
            # rewriting, every PATH-resolved cmake/ninja/etc under `module
            # load pytorch` fails with "bad interpreter: No such file or
            # directory" (verified slurm 8161 cmake breakage on rocm-7.2.1;
            # same pattern was present on all 13 installed pytorch trees,
            # hot-fixed by bare_system/fix_python_venv_shebangs.sh on 2026-05-07).
            #
            # The PRIOR rewrite used `which python3` while the venv was still
            # active, so PYTHON3_PATH resolved to the SAME /tmp path that was
            # already in the shebang -> no-op sed. Switching the rewrite
            # target to `/usr/bin/env python3` is correct because:
            #   (1) the modulefile prepends ${PYTORCH_PATH}/lib/python3.X/
            #       site-packages onto PYTHONPATH, so `from cmake import cmake`
            #       (and ninja, torch, etc.) resolves under the system python3
            #       once `module load pytorch/...` is in effect.
            #   (2) the modulefile also prepends ${PYTORCH_PATH}/bin onto PATH,
            #       so `env python3` finds ${PYTORCH_PATH}/bin/python3 (a
            #       symlink to /usr/bin/python3 placed there by `cp -a` below).
            # Tested end-to-end: cmake --version returns 4.3.2 on rocm-7.2.1.
            ${SUDO} find bin/ -maxdepth 1 -type f ! -name 'python*' \
               -exec sed -i '1s|^#!.*python3.*$|#!/usr/bin/env python3|' {} +
            ${SUDO} cp -a bin/* ${PYTORCH_PATH}/bin
            ;;
      esac
      echo ""
      echo "===================="
      echo "Finished setup.py install"
      echo "===================="
      echo ""

      # ── C1: Mandatory `import torch` validation ─────────────────────────
      # Catches the libtorch_cpu/libtorch_hip ABI-mismatch class of bug
      # the moment it surfaces (vs in a downstream pip subprocess), so
      # main_setup.sh's per-package gate fails the script cleanly here
      # instead of marking pytorch DONE and letting the failure cascade
      # into deepspeed / flash-attention installs that import torch in
      # their setup.py (jobs 8049-8065 silently produced "DONE pytorch"
      # then "metadata-generation-failed deepspeed" -- the post-mortem
      # signal pointed at deepspeed even though pytorch was the real
      # cause). Replaces the prior `if [[ "${DEBUG}" != 0 ]]` gate
      # which made these checks dead code in production.
      export PYTHONPATH=${PYTORCH_PATH}/lib/python3.${PYTHON_VERSION}/site-packages
      export PYTHONPATH=${PYTHONPATH}:${INSTALL_PATH}/pypackages
      echo ""
      echo "[pytorch C1 validation] PYTHONPATH=${PYTHONPATH}"
      echo "[pytorch C1 validation] running 'import torch' check"
      if ! python3 -c "
import torch
print('  torch.__version__   =', torch.__version__)
print('  torch.version.hip   =', getattr(torch.version, 'hip', None))
print('  torch.version.cuda  =', torch.version.cuda)
print('  torch.cuda.is_available() =', torch.cuda.is_available())
"; then
         echo "" >&2
         echo "######################################################################" >&2
         echo "[pytorch C1 validation] FAILED -- 'import torch' did not succeed." >&2
         echo "" >&2
         echo "This is the failure mode that silently passed in slurm 8049 / 8061 /" >&2
         echo "8063 / 8065 because the validation was gated by DEBUG=0. The libtorch" >&2
         echo "shared objects were built but cannot be loaded -- the most common" >&2
         echo "cause is CC=amdclang for CPU TUs, which (per LLVM #85656) emits" >&2
         echo "long-form mangling of std::enable_if NTTP defaults that does not" >&2
         echo "match the short-form references emitted by hipcc for HIP TUs." >&2
         echo "See PyTorch issue #173707 for context." >&2
         echo "" >&2
         echo "Diagnostic next steps:" >&2
         echo "  1. readelf -p .comment libtorch_cpu.so | head" >&2
         echo "     EXPECT 'GCC: ...'. If 'AMD clang version', then magma's" >&2
         echo "     modulefile probably reverted to load(\"amdclang\") -- check" >&2
         echo "     extras/scripts/magma_setup.sh's heredoc (Option B comment" >&2
         echo "     block) and the live .lua under" >&2
         echo "     /shared/apps/modules/.../rocmplus-\${ROCM_VERSION}/magma/." >&2
         echo "     The expected form is 'prepend_path(\"LD_LIBRARY_PATH\",..llvm/lib..)'" >&2
         echo "     NOT 'load(\"amdclang\")'. Less likely: \"amdclang\" was added" >&2
         echo "     back into pytorch_setup.sh's REQUIRED_MODULES." >&2
         echo "  2. nm -D libtorch_cpu.so | grep ' T ' | grep const_data_ptr | head" >&2
         echo "     EXPECT short-form (...Li0EEEPKT_v). Long-form (...Tn..enable_if..)" >&2
         echo "     means clang built libtorch_cpu and the ABI does not match HIP." >&2
         echo "  3. nm -D libtorch_hip.so | grep ' U ' | grep const_data_ptr | head" >&2
         echo "     Always short-form; libtorch_cpu MUST also be short-form." >&2
         echo "######################################################################" >&2
         exit 1
      fi
      echo "[pytorch C1 validation] OK"
      echo ""

      # ── C2: bake ${ROCM_PATH}/llvm/lib into libtorch_cpu.so's RUNPATH ──
      # Belt-and-suspender to the LDFLAGS=-Wl,-rpath block far above.
      # PyTorch's setup.py / cmake occasionally drops the env LDFLAGS
      # for individual link rules (it composes its own LINK_FLAGS for
      # libtorch_cpu in caffe2/CMakeLists.txt and torch/CMakeLists.txt),
      # so we re-assert the rpath unconditionally on the installed
      # libtorch_cpu.so. That makes "import torch" survive any
      # consumer that strips LD_LIBRARY_PATH (notably rocprof-compute
      # v3.4.0 -- see profiler_rocprofiler_sdk.py:73 in the libexec
      # tree of the loaded rocm module). libtorch_cpu.so is the only
      # SO under torch/lib that has a direct DT_NEEDED libomp.so;
      # libtorch_hip.so / libtorch_python.so etc. pick libomp up
      # transitively, so patching libtorch_cpu alone is sufficient.
      LIBTORCH_CPU="${PYTORCH_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/torch/lib/libtorch_cpu.so"
      # ── Hollow-install hard fail ──────────────────────────────────
      # If libtorch_cpu.so is missing from the install tree at this
      # point, the install is "hollow": setup.py reported success but
      # torch never landed in ${PYTORCH_PATH}. This happens on PT 2.9+
      # when the site-packages copy step (gated above on PT 2.9-2.12)
      # is skipped or fails silently, AND the upstream pip-redirect
      # left the wheel only in the venv. C1 falsely passes because
      # the venv's sys.path is still active. Without this gate, the
      # build proceeds, writes a modulefile, and ships ~2 GB of
      # satellites (vision/audio/triton/...) wrapped around an empty
      # torch -- and anyone who `module load`s the result gets
      # everything except torch itself.
      # First observed in slurm 9422 PT 2.11.0 on rocm-7.2.3, 2026-05-14:
      # `Successfully built torch` + C1 PASS + this WARNING in the log,
      # then `du -sh pytorch/` was 4.0 KB. Was a WARNING-not-ERROR
      # before; promoted to hard fail on 2026-05-14.
      if [ ! -f "${LIBTORCH_CPU}" ]; then
         echo "######################################################################" >&2
         echo "ERROR: HOLLOW INSTALL DETECTED"                                          >&2
         echo "ERROR:   ${LIBTORCH_CPU}"                                                >&2
         echo "ERROR: does not exist after setup.py install reported success."          >&2
         echo "ERROR:"                                                                  >&2
         echo "ERROR: This is the PT 2.9+ pip-redirect symptom"                         >&2
         echo "ERROR: (https://github.com/pytorch/pytorch/issues/152276):"              >&2
         echo "ERROR:   setup.py is silently redirected to pip install . , which"       >&2
         echo "ERROR:   drops the torch wheel into the build venv's site-packages"      >&2
         echo "ERROR:   instead of ${PYTORCH_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/."  >&2
         echo "ERROR:"                                                                  >&2
         echo "ERROR: Fix: check that the PT-version case block above the"              >&2
         echo "ERROR:      'Finished setup.py install' banner includes"                 >&2
         echo "ERROR:      \"${PYTORCH_SHORT_VERSION}\" in its match list."             >&2
         echo "ERROR:      That block is what copies lib/python*/site-packages/* into"  >&2
         echo "ERROR:      \${PYTORCH_PATH_SITE_PACKAGES}. Without it, the install"     >&2
         echo "ERROR:      is hollow and C1 falsely passes via the venv's sys.path."    >&2
         echo "######################################################################" >&2
         exit 1
      fi
      if command -v patchelf >/dev/null 2>&1; then
         CURRENT_RUNPATH=$(patchelf --print-rpath "${LIBTORCH_CPU}" 2>/dev/null || true)
         if [[ ":${CURRENT_RUNPATH}:" != *":${ROCM_PATH}/llvm/lib:"* ]]; then
            NEW_RUNPATH="${CURRENT_RUNPATH:+${CURRENT_RUNPATH}:}${ROCM_PATH}/llvm/lib"
            echo "[pytorch C2 RUNPATH patch] libtorch_cpu.so before: ${CURRENT_RUNPATH}"
            ${SUDO} patchelf --set-rpath "${NEW_RUNPATH}" "${LIBTORCH_CPU}"
            echo "[pytorch C2 RUNPATH patch] libtorch_cpu.so after : $(patchelf --print-rpath "${LIBTORCH_CPU}")"
            # Verify libomp.so resolves with LD_LIBRARY_PATH stripped to
            # the env that rocprof-compute presents to its child. If
            # this fails, the patchelf didn't take and we want to know
            # about it before main_setup.sh marks pytorch DONE.
            if ! LD_LIBRARY_PATH="${ROCM_PATH}/lib" \
                  ldd "${LIBTORCH_CPU}" 2>/dev/null \
                  | grep -F "libomp.so" \
                  | grep -qF "${ROCM_PATH}/llvm/lib/libomp.so"; then
               echo "ERROR: post-patchelf, libomp.so still does not resolve" >&2
               echo "ERROR: from libtorch_cpu.so under a stripped"          >&2
               echo "ERROR: LD_LIBRARY_PATH=${ROCM_PATH}/lib environment."  >&2
               echo "ERROR: This means the Pytorch_Profile_Rocprof-compute" >&2
               echo "ERROR: regression will fail on this build. Check that" >&2
               echo "ERROR: patchelf is recent enough (>= 0.10) and that"   >&2
               echo "ERROR: the runpath edit was not blocked by SELinux/"   >&2
               echo "ERROR: read-only mount on \${PYTORCH_PATH}."           >&2
               exit 1
            fi
            echo "[pytorch C2 RUNPATH patch] OK -- libomp.so resolves under stripped LD_LIBRARY_PATH"
         else
            echo "[pytorch C2 RUNPATH patch] libtorch_cpu.so already has ${ROCM_PATH}/llvm/lib in RUNPATH (no-op)"
         fi
      else
         # patchelf missing on the build host is the ONLY case where
         # we stay at WARNING here -- libtorch_cpu.so exists (the
         # hollow-install gate above ruled that out), we just cannot
         # rewrite its RUNPATH. Pytorch_Profile_Rocprof-compute_ROCm
         # will fail at test time on stripped LD_LIBRARY_PATH, but
         # everything else works.
         echo "WARNING: skipping C2 RUNPATH patch: patchelf not in PATH"                              >&2
         echo "WARNING: this build will fail Pytorch_Profile_Rocprof-compute_ROCm regression"        >&2
         echo "WARNING: unless something else (e.g. amdclang module) puts llvm/lib on RUNPATH."      >&2
         echo "WARNING: install patchelf >= 0.10 on the build host and re-run with --replace 1"      >&2
         echo "WARNING: to fix. (libtorch_cpu.so exists; not a hollow install.)"                      >&2
      fi

      # Installing Torchvision
      #
      # Source acquisition: GitHub auto-generated source tarball for the
      # release tag (extracts to vision-${TORCHVISION_VERSION}/). This
      # replaces the prior `git clone --recursive --depth 1 --branch v$V`
      # for two reasons:
      #   1. Without a .git tree on disk, torchvision's setup.py does not
      #      append a "+<git-sha>" local-version-identifier suffix to the
      #      installed egg directory name. The egg is just
      #         torchvision-${TORCHVISION_VERSION}-py3.X-linux-x86_64.egg
      #      which is stable across builds and lets the modulefile
      #      reference it without hardcoding a per-version git hash.
      #   2. Tarball downloads are reproducible from a release tag and
      #      avoid the recursive submodule clone (none of torchvision's
      #      current submodules are needed for the torchvision-with-ROCm
      #      build path; system libpng-dev / libjpeg-dev / libavcodec-dev
      #      satisfy the runtime deps already).
      # If torchvision later gains a build-required submodule, swap this
      # block back to git clone --recursive (and update the egg-detection
      # block below to handle the +sha suffix again).
      #
      # ── setuptools<81 pin (Bug 2 fix, applies to torchvision+torchaudio) ──
      # setuptools 81 (released 2026-05) marked the `pkg_resources`
      # package as removed-from-the-public-API; setuptools 82.0.1 dropped
      # it from the wheel entirely (no more
      # site-packages/pkg_resources/). torchvision and torchaudio's
      # setup.py both call
      #    from pkg_resources import DistributionNotFound, get_distribution, parse_version
      # on the first executable line of setup.py (line 14 in
      # vision-0.25.0 / audio-2.10.0). On the build venv that PT >= 2.10
      # produces, the auto-upgraded setuptools is now 82.0.1, so
      # setup.py crashes with `ModuleNotFoundError: No module named
      # 'pkg_resources'` *before* a single source file compiles, and
      # because the legacy invocation does not check rc the build
      # script historically silently swallowed the failure (see rc-gate
      # Bug 2b further down).
      #
      # Fix: downgrade setuptools in the active build venv to a version
      # that still ships pkg_resources. setuptools 80.10.2 is the last
      # release with the API intact and is the version chosen by the
      # tier-1/tier-2 isolation tests on rocm-7.2.3 + PT 2.10.0
      # (2026-05-18, .scratch_pin_test/tier{1,2}.log).
      #
      # Gating: only applied for PT major.minor >= 2.10. Older PT
      # builds (2.7/2.8/2.9) were already passing because the build
      # venv resolved to setuptools < 81 organically (PT's own
      # requirements.txt-driven `python -m pip install -r ...` step
      # produced a 65.x..80.x setuptools in those venvs). Keeping the
      # gate is what makes this patch byte-stable for the
      # already-passing PT 2.7-2.9 build matrix.
      #
      # The pin is applied here (just before torchvision) rather than
      # before each setup.py call because the same build venv stays
      # active through the torchaudio install that follows, so one
      # pin covers both. If a future refactor splits these into
      # separate venvs, move/duplicate the pin alongside the new venv
      # activation.
      PT_PIN_MAJOR=$(echo "${PYTORCH_VERSION}" | cut -d. -f1)
      PT_PIN_MINOR=$(echo "${PYTORCH_VERSION}" | cut -d. -f2)
      if [ "${PT_PIN_MAJOR}" -gt 2 ] || \
         { [ "${PT_PIN_MAJOR}" -eq 2 ] && [ "${PT_PIN_MINOR}" -ge 10 ]; }; then
         echo "[setuptools<81 pin] PT ${PYTORCH_VERSION} >= 2.10 -- pinning build-venv setuptools to restore pkg_resources for torchvision/torchaudio setup.py"
         echo "[setuptools<81 pin]   before: setuptools=$(python3 -c 'import setuptools; print(setuptools.__version__)' 2>&1)"
         pip3 install --upgrade --force-reinstall --no-deps 'setuptools<81' || {
            echo "ERROR: failed to pin setuptools<81 in the PT-build venv."                      >&2
            echo "ERROR: torchvision setup.py will crash on 'from pkg_resources import ...'."   >&2
            echo "ERROR: investigate pip3 / network / venv writability before retrying."         >&2
            exit 1
         }
         echo "[setuptools<81 pin]   after:  setuptools=$(python3 -c 'import setuptools; print(setuptools.__version__)' 2>&1) (must be < 81)"
         if ! python3 -c 'from pkg_resources import DistributionNotFound, get_distribution, parse_version' 2>/dev/null; then
            echo "ERROR: post-pin probe failed: 'from pkg_resources import ...' still does not import." >&2
            echo "ERROR: the pinned setuptools either did not install or another setuptools is shadowing it on PYTHONPATH." >&2
            python3 -c 'import sys; [print("  sys.path:", p) for p in sys.path]'                >&2
            exit 1
         fi
         echo "[setuptools<81 pin]   probe:  pkg_resources import OK"
      else
         echo "[setuptools<81 pin] PT ${PYTORCH_VERSION} < 2.10 -- no pin needed (legacy setuptools path)."
      fi

      TORCHVISION_TGZ="vision-${TORCHVISION_VERSION}.tar.gz"
      TORCHVISION_URL="https://github.com/pytorch/vision/archive/refs/tags/v${TORCHVISION_VERSION}.tar.gz"
      echo "Downloading torchvision v${TORCHVISION_VERSION} from ${TORCHVISION_URL}"
      wget -q --tries=10 "${TORCHVISION_URL}" -O "${TORCHVISION_TGZ}" || {
         echo "ERROR: failed to download ${TORCHVISION_URL}"
         echo "       Check that the upstream tag v${TORCHVISION_VERSION} exists at https://github.com/pytorch/vision/releases"
         exit 1
      }
      tar -xzf "${TORCHVISION_TGZ}"
      rm -f "${TORCHVISION_TGZ}"
      cd "vision-${TORCHVISION_VERSION}"
      export PYTHONPATH=${TORCHVISION_PATH}/lib/python3.${PYTHON_VERSION}/site-packages:$PYTHONPATH
      python3 setup.py install --prefix=${TORCHVISION_PATH}
      TORCHVISION_INSTALL_RC=$?
      # rc gate (Bug 2b): historically this script ignored setup.py's
      # exit status, so an early crash (e.g. setuptools-82.0.1
      # `pkg_resources` ModuleNotFoundError in job 9875) produced an
      # empty/partial ${TORCHVISION_PATH} tree but the build kept
      # going, emitted a modulefile pointing at the missing tree, and
      # failed only later at `import torchvision` time. Fail fast here
      # so the operator sees the real first-failure log line.
      if [ "${TORCHVISION_INSTALL_RC}" != "0" ]; then
         echo "ERROR: torchvision setup.py install failed (rc=${TORCHVISION_INSTALL_RC})"      >&2
         echo "ERROR:   src tree: $(pwd)"                                                       >&2
         echo "ERROR:   prefix:   ${TORCHVISION_PATH}"                                          >&2
         echo "ERROR:   PT:       ${PYTORCH_VERSION}    torchvision: ${TORCHVISION_VERSION}"    >&2
         echo "ERROR:   inspect the log above for the first traceback (commonly: "             >&2
         echo "ERROR:   'from pkg_resources import ...' -> setuptools<81 pin missing/broken,"  >&2
         echo "ERROR:   or a torch ABI mismatch if a hipcc/cmake configure step failed)."      >&2
         exit 1
      fi
      cd ..
      # Detect the actual installed torchvision egg directory and capture
      # its basename for both the post-build PYTHONPATH and the
      # modulefile written near the bottom of this script. This avoids
      # hardcoding the egg name; setuptools may suffix the version with
      # "+<sha>" (git build) or "a0" (pre-release tag) depending on the
      # source acquisition method, and detecting the actual name keeps
      # the modulefile correct regardless. Same trick PILLOW_VERSION
      # uses below.
      TORCHVISION_EGG=$(ls -d "${TORCHVISION_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/torchvision-${TORCHVISION_VERSION}"*.egg 2>/dev/null | head -1)
      if [ -n "${TORCHVISION_EGG}" ]; then
         TORCHVISION_EGG_NAME=$(basename "${TORCHVISION_EGG}")
         echo "Detected installed torchvision egg: ${TORCHVISION_EGG_NAME}"
      else
         TORCHVISION_EGG_NAME="torchvision-${TORCHVISION_VERSION}-py3.${PYTHON_VERSION}-linux-x86_64.egg"
         echo "WARNING: no torchvision-${TORCHVISION_VERSION}*.egg found under ${TORCHVISION_PATH}/lib/python3.${PYTHON_VERSION}/site-packages"
         echo "         falling back to expected name '${TORCHVISION_EGG_NAME}' for PYTHONPATH and modulefile (may not exist)"
      fi
      export PYTHONPATH=${TORCHVISION_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/${TORCHVISION_EGG_NAME}:$PYTHONPATH
      # Detect the actual installed pillow version from the egg directory name,
      # since torchvision pulls pillow as a dependency and the version may differ
      # from what PILLOW_VERSION specifies.
      PILLOW_EGG=$(ls -d ${TORCHVISION_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/pillow-*-py3.${PYTHON_VERSION}-linux-x86_64.egg 2>/dev/null | head -1)
      if [ -n "${PILLOW_EGG}" ]; then
         PILLOW_VERSION=$(basename "${PILLOW_EGG}" | sed 's/^pillow-\(.*\)-py3\..*/\1/')
      fi
      export PYTHONPATH=${TORCHVISION_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/pillow-${PILLOW_VERSION}-py3.${PYTHON_VERSION}-linux-x86_64.egg:$PYTHONPATH
      if [[ "${DEBUG}" != 0 ]]; then
         echo "Testing import torchvision"
         python3 -c 'import torchvision'
         echo "Finished testing import torchvision"
      fi

      # Installing Torchaudio
      #
      # Source acquisition: GitHub auto-generated source tarball (extracts
      # to audio-${TORCHAUDIO_VERSION}/). Same rationale as the
      # torchvision block above: dropping the .git tree eliminates the
      # "+<sha>" local-version-identifier suffix in the installed egg
      # name (and historically the "a0" pre-release tag), so the egg
      # name shape is stable and detectable post-install rather than
      # version-pinned in the modulefile.
      TORCHAUDIO_TGZ="audio-${TORCHAUDIO_VERSION}.tar.gz"
      TORCHAUDIO_URL="https://github.com/pytorch/audio/archive/refs/tags/v${TORCHAUDIO_VERSION}.tar.gz"
      echo "Downloading torchaudio v${TORCHAUDIO_VERSION} from ${TORCHAUDIO_URL}"
      wget -q --tries=10 "${TORCHAUDIO_URL}" -O "${TORCHAUDIO_TGZ}" || {
         echo "ERROR: failed to download ${TORCHAUDIO_URL}"
         echo "       Check that the upstream tag v${TORCHAUDIO_VERSION} exists at https://github.com/pytorch/audio/releases"
         exit 1
      }
      tar -xzf "${TORCHAUDIO_TGZ}"
      rm -f "${TORCHAUDIO_TGZ}"
      cd "audio-${TORCHAUDIO_VERSION}"
      export PYTHONPATH=${TORCHAUDIO_PATH}/lib/python3.${PYTHON_VERSION}/site-packages:$PYTHONPATH
      python3 setup.py install --prefix=${TORCHAUDIO_PATH}
      TORCHAUDIO_INSTALL_RC=$?
      # rc gate (Bug 2b, twin of the torchvision rc gate above). Same
      # rationale: the setuptools<81 pin block earlier in this branch
      # covers the pkg_resources crash for both, but a different
      # failure mode here (e.g. failed sox/lame/ffmpeg header probe,
      # cmake error, etc.) would otherwise silently land in
      # ${TORCHAUDIO_PATH}'s eggless tree and only surface at
      # `import torchaudio` time.
      if [ "${TORCHAUDIO_INSTALL_RC}" != "0" ]; then
         echo "ERROR: torchaudio setup.py install failed (rc=${TORCHAUDIO_INSTALL_RC})"        >&2
         echo "ERROR:   src tree: $(pwd)"                                                       >&2
         echo "ERROR:   prefix:   ${TORCHAUDIO_PATH}"                                           >&2
         echo "ERROR:   PT:       ${PYTORCH_VERSION}    torchaudio:  ${TORCHAUDIO_VERSION}"     >&2
         echo "ERROR:   inspect the log above for the first traceback (commonly: "             >&2
         echo "ERROR:   'from pkg_resources import ...' -> setuptools<81 pin missing/broken,"  >&2
         echo "ERROR:   or missing sox/lame/ffmpeg dev headers reported by setup.py probe)."   >&2
         exit 1
      fi
      # Detect the actual installed torchaudio egg directory; same
      # pattern as torchvision above, see comment block there.
      TORCHAUDIO_EGG=$(ls -d "${TORCHAUDIO_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/torchaudio-${TORCHAUDIO_VERSION}"*.egg 2>/dev/null | head -1)
      if [ -n "${TORCHAUDIO_EGG}" ]; then
         TORCHAUDIO_EGG_NAME=$(basename "${TORCHAUDIO_EGG}")
         echo "Detected installed torchaudio egg: ${TORCHAUDIO_EGG_NAME}"
      else
         TORCHAUDIO_EGG_NAME="torchaudio-${TORCHAUDIO_VERSION}-py3.${PYTHON_VERSION}-linux-x86_64.egg"
         echo "WARNING: no torchaudio-${TORCHAUDIO_VERSION}*.egg found under ${TORCHAUDIO_PATH}/lib/python3.${PYTHON_VERSION}/site-packages"
         echo "         falling back to expected name '${TORCHAUDIO_EGG_NAME}' for PYTHONPATH and modulefile (may not exist)"
      fi
      export PYTHONPATH=${TORCHAUDIO_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/${TORCHAUDIO_EGG_NAME}:$PYTHONPATH
      if [[ "${DEBUG}" != 0 ]]; then
         echo "Testing import torchaudio"
         python3 -c 'import torchaudio'
         echo "Finished testing import torchaudio"
      fi
      cd ..

      # Installing Transformers

      pip3 install --target=${TRANSFORMERS_PATH} transformers --no-build-isolation

      # Installing Triton

      ROCM_VERSION_WHEEL=${ROCM_VERSION}
      if [[ `echo ${ROCM_VERSION} | cut -f3-3 -d'.'` == 0 ]]; then
         ROCM_VERSION_WHEEL=`echo ${ROCM_VERSION} | cut -f1-2 -d'.'`
      fi

      # TRITON_VERSION was resolved by resolve_pytorch_stack_versions
      # (see comment in the source-build branch above; same rationale).
      if [ "$(printf '%s\n' "$ROCM_VERSION" "7.0" | sort -V | head -n1)" = "$ROCM_VERSION" ]; then
        TRITON_WHEEL_NAME="pytorch_triton_rocm"
      fi

      pip3 install ${TRITON_WHEEL_NAME}==${TRITON_VERSION} -f https://repo.radeon.com/rocm/manylinux/rocm-rel-${ROCM_VERSION_WHEEL}/ --no-cache-dir --target=${TRITON_PATH} --no-build-isolation

      # Installing Sage Attention

      pip3 install --target=${SAGEATTENTION_PATH} sageattention==${SAGEATTENTION_VERSION} --no-build-isolation

      # Building Flash Attention

      pip3 install --target=${FLASHATTENTION_PATH} packaging
      export PYTHONPATH=$PYTHONPATH:${FLASHATTENTION_PATH}
      export PYTHONPATH=$PYTHONPATH:${FLASHATTENTION_PATH}/lib/python3.${PYTHON_VERSION}/site-packages
      git clone --depth 1 --branch v${FLASHATTENTION_VERSION} https://github.com/Dao-AILab/flash-attention.git
      cd flash-attention
      #FLASH_ATTENTION_SKIP_CUDA_BUILD="FALSE" FLASH_ATTENTION_TRITON_AMD_ENABLE="TRUE" python3 setup.py install --prefix=${FLASHATTENTION_PATH}
      BUILD_TARGET="rocm" GPU_ARCHS="$AMDGPU_GFXMODEL" FLASH_ATTENTION_SKIP_CUDA_BUILD="FALSE" python3 setup.py install --prefix=${FLASHATTENTION_PATH}

      # Building Deep Speed

      DS_BUILD_AIO=1 \
      DS_BUILD_CCL_COMM=0 \
      DS_BUILD_CPU_ADAM=1 \
      DS_BUILD_CPU_LION=1 \
      DS_BUILD_EVOFORMER_ATTN=0 \
      DS_BUILD_FUSED_ADAM=1 \
      DS_BUILD_FUSED_LION=1 \
      DS_BUILD_FUSED_LAMB=1 \
      DS_BUILD_QUANTIZER=1 \
      DS_BUILD_RANDOM_LTD=1 \
      DS_BUILD_TRANSFORMER=1 \
      DS_BUILD_STOCHASTIC_TRANSFORMER=1 \
      DS_BUILD_SPARSE_ATTN=0 \
      DS_BUILD_TRANSFORMER_INFERENCE=0 \
      DS_BUILD_INFERENCE_CORE_OPS=0 \
      DS_BUILD_SPATIAL_INFERENCE=0 \
      DS_BUILD_CUTLASS_OPS=0 \
      DS_BUILD_RAGGED_OPS=0 \
      DS_BUILD_RAGGED_DEVICE_OPS=0 \
      DS_BUILD_OPS=0 \
      pip3 install --upgrade deepspeed einops psutil pydantic==2.11.9 hjson pydantic-core==2.33.2 msgpack typing_inspection annotated_types py-cpuinfo --no-cache-dir --target=$DEEPSPEED_PATH --no-build-isolation --no-deps

      # ── Shebang rewrite (source-build branch satellites) ───────────
      # Each pip3 install --target= above (transformers, triton,
      # sageattention, flashattention, deepspeed) ran while the
      # pytorch_build venv (line 1183) was active, so every console
      # script was baked with `#!${PYTORCH_BUILD_DIR}/bin/python3`
      # -- the same /tmp dir that disappears with the EXIT trap.
      # The pytorch core sweep further up (around line 1492) only
      # covers ${PYTORCH_PATH}/bin; this loop catches the satellites.
      # Same root cause + same fix as the wheel branch above and as
      # bare_system/fix_python_venv_shebangs.sh (audit 2026-05-07).
      for _pt_bin in ${PYTORCH_PATH}/bin \
                     ${TORCHAUDIO_PATH}/bin \
                     ${TORCHVISION_PATH}/bin \
                     ${TRANSFORMERS_PATH}/bin \
                     ${SAGEATTENTION_PATH}/bin \
                     ${FLASHATTENTION_PATH}/bin \
                     ${TRITON_PATH}/bin \
                     ${DEEPSPEED_PATH}/bin; do
         [ -d "${_pt_bin}" ] || continue
         ${SUDO} find "${_pt_bin}" -maxdepth 1 -type f \
            -exec sed -i '1s|^#!.*python3.*$|#!/usr/bin/env python3|' {} + 2>/dev/null || true
      done
      unset _pt_bin

      deactivate
      # cd from pytorch_build/flash-attention back to the starting directory
      cd ../..
      rm -rf pytorch_build


      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} find ${INSTALL_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${INSTALL_PATH} -type d -execdir chown root:root "{}" +
      fi

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${INSTALL_PATH}
      fi

      # cleanup: the EXIT trap on TRITON_BUILD_ROOT and PYTORCH_BUILD_ROOT
      # (set at the start of the BUILD_PYTORCH=1 branch) handles
      # triton/torchinductor cache and source-build tree removal. The
      # previous blanket
      #   ${SUDO} rm -rf /tmp/amd_triton_kernel* /tmp/can*
      # was unsafe (`/tmp/can*` matches arbitrary unrelated files
      # under /tmp) and racy with concurrent pytorch builds.
      # Restore the original CWD (we cd'd into PYTORCH_BUILD_ROOT for the
      # source-build above). The intel-onemkl installer cleanup that used
      # to live here is gone -- we no longer download it.
      cd "${PYTORCH_ORIG_CWD}"

   fi
fi

# create a module file for pytorch
#
# Modulefile-write sudo: canonical PKG_SUDO pattern (job 8063 audit;
# see netcdf_setup.sh for the lying-probe failure mode this replaces).
PKG_SUDO_MOD=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

# Companion package (torchvision / torchaudio / pillow) PYTHONPATH
# emission for the modulefile: VERSION-AWARE.
#
# Bug fix (audit 2026-05-17): for PT >= 2.10 the wheel-based
# torchvision/torchaudio install (pip3 install --target=...) and the
# modern-setuptools source build (`setup.py install` with
# setuptools >= ~60) both lay out the package FLAT under
#   ${PKG}/lib/python3.X/site-packages/torchvision/      (+ .egg-info/)
#   ${PKG}/lib/python3.X/site-packages/torchaudio/       (+ .egg-info/)
# *not* as a `torchvision-X-py3.X-linux-x86_64.egg/` directory.
#
# The legacy heredoc unconditionally referenced a `.egg` path that
# does not exist for those layouts -> the modulefile prepended a
# bogus PYTHONPATH entry and `import torchvision` / `import torchaudio`
# failed at module load time. PT 2.10.0 on rocmplus-{6.4.3,7.1.0,
# 7.1.1,7.2.0,7.2.2} all reproduced this. PT <= 2.9 source builds
# still produced real .egg dirs on the build hosts at the time and
# were unaffected.
#
# Strategy:
#   * PT >= 2.10  -> prepend the parent `site-packages/` directory
#                    (which works for both flat and .egg layouts
#                    because Python's importer treats either
#                    `torchvision/__init__.py` or
#                    `torchvision-*.egg/` as a child entry).
#                    Also emit explicit .egg-path lines, but ONLY
#                    when a real .egg exists on disk (defensive
#                    belt-and-suspenders in case a future setuptools
#                    pin restores egg emission).
#   * PT <  2.10  -> emit the legacy 3 lines BYTE-IDENTICAL to the
#                    pre-fix script, so re-runs against existing
#                    2.7 / 2.8 / 2.9 cells regenerate the same
#                    modulefile content.
#
# The bare `${TORCHAUDIO_PATH}` / `${TORCHVISION_PATH}` prepends
# below (kept in the heredoc unchanged) cover the wheel-branch
# layout where pip3 --target=DIR drops packages at DIR/ root.
IS_PT_2_10_PLUS=0
if [ "$(printf '%s\n' "${PYTORCH_VERSION}" "2.10.0" | sort -V | head -n1)" = "2.10.0" ]; then
   IS_PT_2_10_PLUS=1
fi
_nl=$'\n'
if [ "${IS_PT_2_10_PLUS}" = "1" ]; then
   MODULE_COMPANION_PREPENDS="prepend_path(\"PYTHONPATH\",\"${TORCHAUDIO_PATH}/lib/python3.${PYTHON_VERSION}/site-packages\")"
   MODULE_COMPANION_PREPENDS+="${_nl}prepend_path(\"PYTHONPATH\",\"${TORCHVISION_PATH}/lib/python3.${PYTHON_VERSION}/site-packages\")"
   if [ -n "${TORCHAUDIO_EGG_NAME:-}" ] && [ -e "${TORCHAUDIO_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/${TORCHAUDIO_EGG_NAME}" ]; then
      MODULE_COMPANION_PREPENDS+="${_nl}prepend_path(\"PYTHONPATH\",\"${TORCHAUDIO_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/${TORCHAUDIO_EGG_NAME}\")"
   fi
   if [ -n "${TORCHVISION_EGG_NAME:-}" ] && [ -e "${TORCHVISION_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/${TORCHVISION_EGG_NAME}" ]; then
      MODULE_COMPANION_PREPENDS+="${_nl}prepend_path(\"PYTHONPATH\",\"${TORCHVISION_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/${TORCHVISION_EGG_NAME}\")"
   fi
   _pillow_egg_path="${TORCHVISION_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/pillow-${PILLOW_VERSION}-py3.${PYTHON_VERSION}-linux-x86_64.egg"
   if [ -e "${_pillow_egg_path}" ]; then
      MODULE_COMPANION_PREPENDS+="${_nl}prepend_path(\"PYTHONPATH\",\"${_pillow_egg_path}\")"
   fi
   unset _pillow_egg_path
else
   MODULE_COMPANION_PREPENDS="prepend_path(\"PYTHONPATH\",\"${TORCHAUDIO_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/${TORCHAUDIO_EGG_NAME:-torchaudio-${TORCHAUDIO_VERSION}-py3.${PYTHON_VERSION}-linux-x86_64.egg}\")"
   MODULE_COMPANION_PREPENDS+="${_nl}prepend_path(\"PYTHONPATH\",\"${TORCHVISION_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/${TORCHVISION_EGG_NAME:-torchvision-${TORCHVISION_VERSION}-py3.${PYTHON_VERSION}-linux-x86_64.egg}\")"
   MODULE_COMPANION_PREPENDS+="${_nl}prepend_path(\"PYTHONPATH\",\"${TORCHVISION_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/pillow-${PILLOW_VERSION}-py3.${PYTHON_VERSION}-linux-x86_64.egg\")"
fi

# ── flashattention modulefile-prepend (egg-vs-flat split, PT >= 2.10) ──
# Twin of the MODULE_COMPANION_PREPENDS gating above, applied to
# flashattention because flash_attn is the ONLY package built via
# `setup.py install --prefix=...` (rather than `pip install --target=...`)
# whose modulefile emission still hardcodes the egg-name path.
#
# Bug history: with PT 2.9.x, setuptools shipped by the build venv
# laid flash_attn out under
#   ${FLASHATTENTION_PATH}/lib/python3.X/site-packages/flash_attn-${VER}-py3.X-linux-x86_64.egg/
# (a real .egg directory), so the legacy emit (line "prepend egg path"
# below) worked. With PT 2.10+, the Bug-2 setuptools<81 pin (which is
# still >= the modern-flat threshold of ~setuptools 65) makes
# `setup.py install` produce a FLAT layout:
#   ${FLASHATTENTION_PATH}/lib/python3.X/site-packages/flash_attn/
#   ${FLASHATTENTION_PATH}/lib/python3.X/site-packages/flash_attn-${VER}-py3.X.egg-info/   (metadata, not .egg)
#   ${FLASHATTENTION_PATH}/lib/python3.X/site-packages/flash_attn_2_cuda...so
# The legacy egg-named prepend then DANGLES (the .egg/ directory does
# not exist) and `import flash_attn` raises ModuleNotFoundError
# because the parent site-packages was never on PYTHONPATH.
# (HPCTrainingExamples ctest Pytorch_FlashAttention_Check_Import
# reproduced this on rocmplus-7.2.3 + pytorch/2.10.0 on 2026-05-18.)
#
# Fix: for PT >= 2.10, emit the parent site-packages directory and
# keep the .egg path only as a conditional fallback (matches the
# torchvision/torchaudio pattern above). For PT < 2.10, leave the
# legacy two-line emit byte-stable so the 2.7-2.9 modulefiles regenerate
# identically.
if [ "${IS_PT_2_10_PLUS}" = "1" ]; then
   MODULE_FA_PREPENDS="prepend_path(\"PYTHONPATH\",\"${FLASHATTENTION_PATH}\")"
   MODULE_FA_PREPENDS+="${_nl}prepend_path(\"PYTHONPATH\",\"${FLASHATTENTION_PATH}/lib/python3.${PYTHON_VERSION}/site-packages\")"
   _fa_egg_path="${FLASHATTENTION_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/flash_attn-${FLASHATTENTION_VERSION}-py3.${PYTHON_VERSION}-linux-x86_64.egg"
   if [ -e "${_fa_egg_path}" ]; then
      MODULE_FA_PREPENDS+="${_nl}prepend_path(\"PYTHONPATH\",\"${_fa_egg_path}\")"
   fi
   unset _fa_egg_path
else
   MODULE_FA_PREPENDS="prepend_path(\"PYTHONPATH\",\"${FLASHATTENTION_PATH}\")"
   MODULE_FA_PREPENDS+="${_nl}prepend_path(\"PYTHONPATH\",\"${FLASHATTENTION_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/flash_attn-${FLASHATTENTION_VERSION}-py3.${PYTHON_VERSION}-linux-x86_64.egg\")"
fi

unset _nl
echo "[modulefile-emit] IS_PT_2_10_PLUS=${IS_PT_2_10_PLUS}; companion prepends:"
printf '  %s\n' "${MODULE_COMPANION_PREPENDS}" | sed 's/^/    /'

# the - option suppresses tabs
cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${PYTORCH_VERSION}${PYTORCH_INSTALL_SUFFIX}.lua
	whatis("PyTorch version ${PYTORCH_VERSION} with ROCm Support${PYTORCH_INSTALL_SUFFIX:+ (variant: ${PYTORCH_INSTALL_SUFFIX#-})}")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")
	whatis("AOTriton: ${AOTRITON_VERSION}")
	whatis("Triton (post-build wheel): ${TRITON_VERSION}")
	whatis("FlashAttention: ${FLASHATTENTION_VERSION}")

	prereq("${ROCM_MODULE_NAME}")
	-- openmpi is required because libtorch_cpu links libmpi.so when
	-- USE_MPI=1 was set at build time (which it is in pytorch_setup.sh).
	load("${MPI_MODULE}")
	-- magma provides libmagma.so on LD_LIBRARY_PATH (and MAGMA_HOME
	-- for any downstream cmake build that re-uses our toolchain).
	-- Without this, "import torch" fails at runtime with
	-- ImportError: libmagma.so: cannot open shared object file.
	load("magma")
	conflict("miniconda3")
	${MODULE_FA_PREPENDS}
	prepend_path("PYTHONPATH","${SAGEATTENTION_PATH}")
	prepend_path("PYTHONPATH","${TRANSFORMERS_PATH}")
	${MODULE_COMPANION_PREPENDS}
	prepend_path("PYTHONPATH","${PYTORCH_PATH}/lib/python3.${PYTHON_VERSION}/site-packages")
	prepend_path("PYTHONPATH","${PYTORCH_PATH}")
	prepend_path("PYTHONPATH","${TORCHAUDIO_PATH}")
	prepend_path("PYTHONPATH","${TORCHVISION_PATH}")
	prepend_path("PYTHONPATH","${DEEPSPEED_PATH}")
	prepend_path("PYTHONPATH","${INSTALL_PATH}/pypackages")
	prepend_path("PYTHONPATH","${TRITON_PATH}")

	prepend_path("PATH","${PYTORCH_PATH}/bin")
	-- LD_LIBRARY_PATH for torch/lib so runtime dlopen() of libcaffe2_nvrtc.so
	-- (and any other lazily-loaded sibling library in torch/lib) resolves.
	-- Why this is needed:
	--   PyTorch's CUDA/HIP init lazy-loads libcaffe2_nvrtc.so from inside
	--   libtorch_hip.so via a bare-name dlopen("libcaffe2_nvrtc.so", ...).
	--   libtorch_hip.so has DT_RUNPATH (not DT_RPATH) with \$ORIGIN at the
	--   front, but glibc's ld.so does NOT consult the calling DSO's
	--   DT_RUNPATH for runtime dlopen() -- DT_RUNPATH is only used for
	--   the calling DSO's direct DT_NEEDED entries (see ld.so(8) man page,
	--   "Rpath token expansion" + "DT_RUNPATH"). DT_RPATH would have
	--   worked, but binutils ld defaults to RUNPATH and our build does
	--   not pass --disable-new-dtags. Without LD_LIBRARY_PATH, the
	--   dlopen falls through to the system cache and fails:
	--     RuntimeError: Error in dlopen: libcaffe2_nvrtc.so: cannot open
	--                   shared object file: No such file or directory
	--   Surfaced by Pytorch_Profile_Rocprof-sys_ROCm test on rocm-7.2.1
	--   in the cdash nightly (cdash-nightly-8394, 2026-05-05). Pytorch_Mnist
	--   passes only because its simple CNN never reaches the nvrtc stub,
	--   not because it has a working environment.
	prepend_path("LD_LIBRARY_PATH","${PYTORCH_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/torch/lib")
	-- LD_LIBRARY_PATH for ROCm's llvm/lib so libtorch_cpu.so's
	-- DT_NEEDED libomp.so resolves WITHOUT relying on magma's
	-- modulefile transitively prepending it (Option B from
	-- magma_setup.sh) AND without relying on libtorch_cpu.so's
	-- RUNPATH (which we now also patch in C2 above, but that
	-- belt-and-suspenders the modulefile, not the other way around).
	-- Why this is needed:
	--   PyTorch's libtorch_cpu.so directly NEEDED's libomp.so
	--   (LLVM OpenMP), which lives at \${ROCM_PATH}/llvm/lib --
	--   NOT in \${ROCM_PATH}/lib (which is what the rocm modulefile
	--   adds to LD_LIBRARY_PATH). If LD_LIBRARY_PATH gets stripped
	--   down to just \${ROCM_PATH}/lib (rocprof-compute v3.4.0's
	--   rocprofiler-sdk backend does exactly this -- see
	--   profiler_rocprofiler_sdk.py:73 in the loaded rocm module's
	--   libexec tree), python crashes on "import torch" with:
	--     ImportError: libomp.so: cannot open shared object file
	--   Surfaced by Pytorch_Profile_Rocprof-compute_ROCm test on
	--   rocm-7.2.1 in cdash nightly 2026-05-05.
	prepend_path("LD_LIBRARY_PATH","${ROCM_PATH}/llvm/lib")
	local user = os.getenv("USER")
	setenv("MIOPEN_USER_DB_PATH", "/tmp/" .. user .. "/my-miopen-cache")
	setenv("MIOPEN_CUSTOM_CACHE_DIR", "/tmp/" .. user .. "/my-miopen-cache")
	setenv("Torch_DIR","${PYTORCH_PATH}/lib/python3.${PYTHON_VERSION}/site-packages")
	-- Re-export the gfx arch list pytorch was built for. Without this,
	-- ANY downstream cmake project that does find_package(Torch) (which
	-- transitively pulls in Caffe2Config -> LoadHIP.cmake) hard-errors
	-- with:
	--   "No GPU arch specified for ROCm build. Please use
	--    PYTORCH_ROCM_ARCH environment variable"
	-- because LoadHIP.cmake checks the env var, not anything baked into
	-- the cmake configs themselves. Surfaced by the
	-- ftorch_multigpu_test_amdflang.sh on rocm-7.0.2 (job 8596,
	-- 2026-05-07) where FTorchConfig -> TorchConfig -> Caffe2Config ->
	-- LoadHIP failed, and the gfortran ftorch_multigpu_test.sh has the
	-- same bug masked by missing set -e. Value matches the build-time
	-- export at pytorch_setup.sh:1305.
	setenv("PYTORCH_ROCM_ARCH","${AMDGPU_GFXMODEL}")
EOF
# An alternate module with tunable gemms
cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${PYTORCH_VERSION}${PYTORCH_INSTALL_SUFFIX}_tunableop_enabled.lua
	whatis("PyTorch version ${PYTORCH_VERSION} with ROCm Support and Tunable GEMMS${PYTORCH_INSTALL_SUFFIX:+ (variant: ${PYTORCH_INSTALL_SUFFIX#-})}")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")
	whatis("AOTriton: ${AOTRITON_VERSION}")
	whatis("Triton (post-build wheel): ${TRITON_VERSION}")
	whatis("FlashAttention: ${FLASHATTENTION_VERSION}")

	load("pytorch")
	setenv("PYTORCH_TUNABLEOP_ENABLED","1")
EOF
#	cmd1="mkdir -p $$HOME/miopen_tmpdir; export TMPDIR=$$HOME/miopen_tmpdir"
#	cmd2="rm -rf $$HOME/miopen_tmpdir; unset TMPDIR"
#	execute{cmd=cmd1, modeA={"load"}}
#	execute{cmd=cmd2, modeA={"unload"}}

#pip download --only-binary :all: --dest /opt/wheel_files_6.0/pytorch-rocm --no-cache --pre torch torchvision --index-url https://download.pytorch.org/whl/nightly/rocm6.0
#cat > /opt/wheel_files_6.0/README_pytorch <<-EOF
#	To install the pytorch package for ROCM 6.0
#	   pip3 install /opt/wheel_files-6.0/pytorch-rocm/torch-2.3.0.dev20240301+rocm6.0-cp310-cp310-linux_x86_64.whl
#	   pip3 install /opt/wheel_files-6.0/pytorch-rocm/torchvision-0.18.0.dev20240301+rocm6.0-cp310-cp310-linux_x86_64.whl
#EOF

