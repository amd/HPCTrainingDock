#!/bin/bash
#
# backfill_skip_markers.sh - retroactive marker drop for already-skipped
# SDKs.
#
# The per-package setup scripts (pytorch / tau / magma / kokkos / hypre /
# hipfort) drop a <pkg>.SKIPPED or <pkg>.BUNDLED marker at the moment
# they take a no-op path (afar-skip / rocm-bundled). This helper does the
# same probe out-of-band so the inventory tool
# (bare_system/inventory_packages.py) shows the right symbol on existing
# installs without waiting for the next sweep.
#
# Idempotent: skips any cell where (a) an install dir already exists for
# that package, or (b) the marker file already exists, or (c) the SDK
# fails the probe (i.e. no longer matches the no-op condition).
#
# Probes are kept in lock-step with the in-script guards:
#
#   pytorch.SKIPPED   ROCM_PATH==*afar* AND no <ROCM_PATH>/lib/libMIOpen.so*
#   tau.SKIPPED       ROCM_PATH==*afar* AND no clang/Basic/SourceManager.h
#   magma.SKIPPED     ROCM_PATH==*afar* AND no hipblas-config.cmake
#   kokkos.SKIPPED    ROCM_PATH==*afar* AND no rocthrust-config.cmake
#   hypre.SKIPPED     ROCM_PATH==*afar* AND no rocblas-config.cmake
#   hipfort.BUNDLED   <ROCM_PATH>/include/hipfort/   exists      (STANDARD layout)
#                  OR <ROCM_PATH>/lib/llvm/include/hipfort/ exists (THEROCK layout)
#
# Marker layout matches the in-script writer so inventory_packages.py
# sees a uniform world.
#
# Usage:
#   sudo bash bare_system/backfill_skip_markers.sh                    # dry run
#   sudo bash bare_system/backfill_skip_markers.sh --apply            # actually write
#   sudo bash bare_system/backfill_skip_markers.sh --apply --root /foo

set -uo pipefail

APPLY=0
ROOT=/shared/apps/ubuntu/opt
ROCM_BASE=/shared/apps/ubuntu/opt    # parallel tree where rocm-${TOK}/ live

usage() { echo "Usage: $0 [--apply] [--root <path>] [--rocm-base <path>]" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
   case "$1" in
      --apply)     APPLY=1 ;;
      --root)      shift; ROOT="$1" ;;
      --rocm-base) shift; ROCM_BASE="$1" ;;
      -h|--help)   usage ;;
      *)           usage ;;
   esac
   shift
done

SUDO=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
WROTE=0
SKIPPED=0
NOT_APPLICABLE=0

# Resolve ROCM_PATH for a given rocmplus suffix. Maps the install-dir
# token (e.g. afar-7.1.0, therock-7.13.0, 7.0.0) back to the SDK root
# under ${ROCM_BASE}. We need this because the SDK basename is
# rocm-<token-with-different-numeric>, e.g. afar-7.1.0 install lives
# under rocm-afar-22.1.0/, therock-7.12.0 install under rocm-therock-23.1.0/.
# We just iterate every rocm-<...> dir and ask its .info/version what its
# numeric is.
declare -A SUFFIX_TO_ROCMPATH
# Iteration order matters when two rocm-* SDKs report the same numeric
# in their .info/version. Concretely: rocm-afar-22.1.0 and rocm-afar-7.0.5
# both report .info/version=7.1.0 (the legacy `rocm-afar-7.0.5` is an
# older drop kept around for the orphaned modulefile we fixed last week;
# the canonical SDK that backs rocmplus-afar-7.1.0/ is rocm-afar-22.1.0).
# We want the canonical AFAR-versioned (22.x / 23.x ...) and THEROCK SDKs
# to win, with the legacy numeric-named afar-7.x.x SDKs as last-resort
# fallbacks. Use first-wins assignment.
ordered_sdks=()
for pat in "${ROCM_BASE}"/rocm-[0-9]* \
           "${ROCM_BASE}"/rocm-therock-* \
           "${ROCM_BASE}"/rocm-afar-22* \
           "${ROCM_BASE}"/rocm-afar-23* \
           "${ROCM_BASE}"/rocm-afar-2[4-9]* \
           "${ROCM_BASE}"/rocm-afar-[3-9]* \
           "${ROCM_BASE}"/rocm-afar-7* \
           "${ROCM_BASE}"/rocm-afar-[0-6].* ; do
   [ -d "${pat}" ] || continue
   ordered_sdks+=("${pat}")
done
for d in "${ordered_sdks[@]}"; do
   bn=$(basename "$d")
   sx=${bn#rocm-}
   ver_file="${d}/.info/version"
   [ -r "${ver_file}" ] || continue
   numeric=$(cut -f1 -d- "${ver_file}")
   case "${sx}" in
      therock-*) suffix="therock-${numeric}" ;;
      afar-*)    suffix="afar-${numeric}"    ;;
      *)         suffix="${numeric}"         ;;
   esac
   if [ -z "${SUFFIX_TO_ROCMPATH[${suffix}]:-}" ]; then
      SUFFIX_TO_ROCMPATH[${suffix}]="${d}"
   else
      echo "[map] suffix '${suffix}' already mapped to ${SUFFIX_TO_ROCMPATH[${suffix}]}; ignoring also-matching ${d}" >&2
   fi
done

drop_marker() {
   local marker_dir="$1" pkg="$2" kind="$3" suffix="$4" rocmpath="$5" reason="$6"
   local marker_path="${marker_dir}/${pkg}.${kind}"
   if [ -e "${marker_path}" ]; then
      echo "  [SKIP-existing] ${marker_path} already exists"
      SKIPPED=$((SKIPPED + 1))
      return 0
   fi
   echo "  [WRITE] ${marker_path}"
   if [ "${APPLY}" = "1" ]; then
      ${SUDO} mkdir -p "${marker_dir}" 2>/dev/null || true
      ${SUDO} tee "${marker_path}" >/dev/null 2>/dev/null <<MARKER_EOF || {
${kind} package: ${pkg}
ROCm SDK:        ${rocmpath}
ROCm token:      ${suffix}
Date:            ${NOW}
Setup script:    backfill_skip_markers.sh (retroactive write)
Reason:          ${reason}
MARKER_EOF
         echo "  [WARN] failed to write ${marker_path}" >&2
         return 1
      }
   fi
   WROTE=$((WROTE + 1))
}

probe_pytorch() {
   local rocmpath="$1"
   [[ "${rocmpath}" != *afar* ]] && return 1
   ! ls "${rocmpath}"/lib/libMIOpen.so* >/dev/null 2>&1
}
probe_tau() {
   local rocmpath="$1"
   [[ "${rocmpath}" != *afar* ]] && return 1
   [ ! -f "${rocmpath}/lib/llvm/include/clang/Basic/SourceManager.h" ] \
      && [ ! -f "${rocmpath}/llvm/include/clang/Basic/SourceManager.h" ]
}
probe_magma() {
   local rocmpath="$1"
   [[ "${rocmpath}" != *afar* ]] && return 1
   [ ! -f "${rocmpath}/lib/cmake/hipblas/hipblas-config.cmake" ]
}
probe_kokkos() {
   local rocmpath="$1"
   [[ "${rocmpath}" != *afar* ]] && return 1
   [ ! -f "${rocmpath}/lib/cmake/rocthrust/rocthrust-config.cmake" ]
}
probe_hypre() {
   local rocmpath="$1"
   [[ "${rocmpath}" != *afar* ]] && return 1
   [ ! -f "${rocmpath}/lib/cmake/rocblas/rocblas-config.cmake" ]
}
probe_hipfort_bundled() {
   local rocmpath="$1"
   { [ -d "${rocmpath}/include/hipfort" ] \
        && [ -f "${rocmpath}/lib/libhipfort-amdgcn.a" ]; } \
   || { [ -d "${rocmpath}/lib/llvm/include/hipfort" ] \
        && [ -f "${rocmpath}/lib/llvm/lib/libhipfort-amdgcn.a" ]; }
}

# Reason strings -- must mirror the in-script messages so the marker
# files are interchangeable.
REASON_PYTORCH="AFAR SDK is missing <ROCM_PATH>/lib/libMIOpen.so* (cmake config refs nonexistent .so). pytorch's find_package(miopen) requires the runtime lib; cannot build on this SDK."
REASON_TAU="AFAR SDK is missing the clang dev tree (<ROCM_PATH>/{lib/llvm,llvm}/include/clang/Basic/SourceManager.h). tau plugins/llvm requires <clang/Basic/SourceManager.h>; cannot build on this SDK."
REASON_MAGMA="AFAR SDK is missing <ROCM_PATH>/lib/cmake/hipblas/hipblas-config.cmake. magma's CMake requires the roc::hipblas imported target; cannot build on this SDK."
REASON_KOKKOS="AFAR SDK is missing <ROCM_PATH>/lib/cmake/rocthrust/rocthrust-config.cmake. kokkos requires find_package(rocthrust); cannot build on this SDK."
REASON_HYPRE="AFAR SDK is missing <ROCM_PATH>/lib/cmake/rocblas/rocblas-config.cmake. hypre requires find_package(rocblas); cannot build on this SDK."
REASON_HIPFORT="hipfort is shipped with this ROCm SDK. No separate from-source build or modulefile is needed."

echo "=================================================================="
echo " backfill_skip_markers.sh"
echo "   ROOT (rocmplus-* trees):   ${ROOT}"
echo "   ROCM_BASE (rocm-* SDKs):   ${ROCM_BASE}"
echo "   APPLY:                     $([ "${APPLY}" = "1" ] && echo "yes" || echo "DRY-RUN (use --apply to write)")"
echo "=================================================================="
echo ""

for tree in "${ROOT}"/rocmplus-*; do
   [ -d "${tree}" ] || continue
   suffix=$(basename "${tree}")
   suffix=${suffix#rocmplus-}
   rocmpath=${SUFFIX_TO_ROCMPATH[${suffix}]:-}
   if [ -z "${rocmpath}" ]; then
      echo "[skip] no rocm-${suffix} SDK under ${ROCM_BASE} for rocmplus-${suffix}/"
      NOT_APPLICABLE=$((NOT_APPLICABLE + 1))
      continue
   fi
   echo "[probe] rocmplus-${suffix}/   <-   ${rocmpath}"

   for pkg_kind in \
      "pytorch:SKIPPED:probe_pytorch:${REASON_PYTORCH}" \
      "tau:SKIPPED:probe_tau:${REASON_TAU}" \
      "magma:SKIPPED:probe_magma:${REASON_MAGMA}" \
      "kokkos:SKIPPED:probe_kokkos:${REASON_KOKKOS}" \
      "hypre:SKIPPED:probe_hypre:${REASON_HYPRE}" \
      "hipfort:BUNDLED:probe_hipfort_bundled:${REASON_HIPFORT}"
   do
      pkg=$(echo "${pkg_kind}" | cut -d: -f1)
      kind=$(echo "${pkg_kind}" | cut -d: -f2)
      probe=$(echo "${pkg_kind}" | cut -d: -f3)
      reason=$(echo "${pkg_kind}" | cut -d: -f4-)

      # if an install dir for this pkg already exists, leave it alone
      case "${pkg}" in
         pytorch) install_glob="${tree}/pytorch-v*" ;;
         tau)     install_glob="${tree}/tau" ;;
         magma)   install_glob="${tree}/magma${tree:+ ${tree}/magma-v*}" ;;
         kokkos)  install_glob="${tree}/kokkos${tree:+ ${tree}/kokkos-v*}" ;;
         hypre)   install_glob="${tree}/hypre${tree:+ ${tree}/hypre-v*}" ;;
         hipfort) install_glob="${tree}/hipfort${tree:+ ${tree}/hipfort-v*}" ;;
      esac
      _have_install=0
      for g in ${install_glob}; do
         [ -d "${g}" ] && _have_install=1 && break
      done
      if [ "${_have_install}" = "1" ]; then
         continue
      fi

      if "${probe}" "${rocmpath}"; then
         drop_marker "${tree}" "${pkg}" "${kind}" "${suffix}" "${rocmpath}" "${reason}"
      fi
   done
done

echo ""
echo "=================================================================="
echo " summary: would-write=${WROTE} already-have=${SKIPPED} no-rocm-sdk=${NOT_APPLICABLE}"
[ "${APPLY}" = "1" ] || echo " (dry run; re-run with --apply to actually write)"
echo "=================================================================="
