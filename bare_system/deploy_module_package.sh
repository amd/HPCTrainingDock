#!/bin/bash
#
# deploy_module_package.sh - package Lmod modulefiles for one package into a
# tarball that, when extracted under /nfsapps/modules/, lands in the right slot
# (base/, rocm-<v>/, rocmplus-<v>/) matching the structure of
# /shared/apps/modules/ubuntu/lmodfiles.
#
# Container-form paths inside the .lua files (/opt/rocm-<v>,
# /etc/lmod/modules/<category>/...) are PRESERVED in the tarball and rewritten
# at extract time on the host by run_rocm_build.sh's Phase 3.5 sed pass.
#
# Runs inside the build container (called by Makefile <pkg>_module_package).

set -eo pipefail

PACKAGE=""
: ${ROCM_VERSION:=""}
: ${SRC_MODULE_ROOT:="/etc/lmod/modules"}
: ${DISTRO:=$(grep '^NAME' /etc/os-release | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]')}
: ${DISTRO_VERSION:=$(grep '^VERSION_ID' /etc/os-release | sed -e 's/VERSION_ID="//' -e 's/"$//')}
: ${AMDGPU_GFXMODEL:=""}

usage() {
   echo "Usage: $0 --package <name> --rocm-version <X.Y.Z>"
   echo "  --package <name>          rocm | openmpi | kokkos | cupy | rocprof-sys | ..."
   echo "  --rocm-version <X.Y.Z>"
   echo "  --src-module-root <dir>   (default $SRC_MODULE_ROOT)"
   exit 1
}

while [[ $# -gt 0 ]]; do
   case "${1}" in
      --package)         shift; PACKAGE=${1} ;;
      --rocm-version)    shift; ROCM_VERSION=${1} ;;
      --src-module-root) shift; SRC_MODULE_ROOT=${1} ;;
      --help|-h)         usage ;;
      *)                 echo "Unknown arg: ${1}" >&2; usage ;;
   esac
   shift
done

[[ -z "${PACKAGE}" ]]      && { echo "ERROR: --package is required" >&2; exit 1; }
[[ -z "${ROCM_VERSION}" ]] && { echo "ERROR: --rocm-version is required" >&2; exit 1; }

# Discover the source category dir for this package.
SRC_PKG_DIR=$(find "${SRC_MODULE_ROOT}" -mindepth 2 -maxdepth 2 -type d -name "${PACKAGE}" -print -quit 2>/dev/null || true)
if [[ -z "${SRC_PKG_DIR}" || ! -d "${SRC_PKG_DIR}" ]]; then
   echo "ERROR: no module dir found at ${SRC_MODULE_ROOT}/*/${PACKAGE}; was the package built?" >&2
   exit 1
fi
CATEGORY=$(basename "$(dirname "${SRC_PKG_DIR}")")

# Map (category, package) -> destination slot under /nfsapps/modules.
case "${CATEGORY}" in
   ROCm)
      if [[ "${PACKAGE}" == "rocm" ]]; then
         SLOT="base/rocm"
      else
         SLOT="rocm-${ROCM_VERSION}/${PACKAGE}"
      fi
      ;;
   ROCmPlus|ROCmPlus-MPI|ROCmPlus-AI|ROCmPlus-AMDResearchTools|ROCmPlus-LatestCompilers|misc)
      SLOT="rocmplus-${ROCM_VERSION}/${PACKAGE}"
      ;;
   LinuxPlus)
      SLOT="base/${PACKAGE}"
      ;;
   *)
      echo "ERROR: unknown module category '${CATEGORY}' for package ${PACKAGE}" >&2
      exit 1
      ;;
esac

echo "deploy_module_package: ${PACKAGE} (category ${CATEGORY}) -> ${SLOT}"

AMDGPU_GFXMODEL_STRING=$(echo "${AMDGPU_GFXMODEL}" | sed -e 's/;/_/g')
CACHE_DIR_NAME="${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}"
CACHE_DIR="/CacheFiles/${CACHE_DIR_NAME}"
if [[ ! -d "${CACHE_DIR}" ]]; then
   echo "ERROR: ${CACHE_DIR} does not exist (is /CacheFiles bind-mounted?)" >&2
   exit 1
fi

STAGE=$(mktemp -d)
trap "rm -rf '${STAGE}'" EXIT

# For --package rocm we bundle the ENTIRE ROCm/ category, because rocm_setup.sh
# also creates ROCm/amdclang, ROCm/hipfort, ROCm/opencl, ROCm/<tool>, ... that
# all belong to this build but have no separate Make timestamp to hang a
# <pkg>_module_package target on. The SDK meta module goes to base/rocm; the
# other ROCm/* subdirs go to rocm-<v>/<sub>.
if [[ "${PACKAGE}" == "rocm" && "${CATEGORY}" == "ROCm" ]]; then
   mkdir -p "${STAGE}/base" "${STAGE}/rocm-${ROCM_VERSION}"
   for sub in "${SRC_MODULE_ROOT}/ROCm/"*; do
      [[ -d "${sub}" ]] || continue
      name=$(basename "${sub}")
      if [[ "${name}" == "rocm" ]]; then
         cp -r "${sub}" "${STAGE}/base/rocm"
      else
         cp -r "${sub}" "${STAGE}/rocm-${ROCM_VERSION}/${name}"
      fi
   done
   for f in "${SRC_MODULE_ROOT}/ROCm/"*.lua; do
      [[ -f "${f}" ]] || continue
      cp "${f}" "${STAGE}/rocm-${ROCM_VERSION}/"
   done
else
   mkdir -p "${STAGE}/$(dirname "${SLOT}")"
   cp -r "${SRC_PKG_DIR}" "${STAGE}/${SLOT}"
fi

# Note: the SDK rocm modulefile (written by rocm/scripts/rocm_setup.sh) already
# emits two prepend_path("MODULEPATH", ...) lines using its own `mbase` local.
# We previously appended duplicate prepend_paths here; that's not needed. The
# host-side Phase 3.5 sed pass in run_rocm_build.sh has a targeted rule that
# rewrites the existing line
#     local mbase = " /etc/lmod/modules/ROCm/rocm"
# to
#     local mbase = "${NFSAPPS_MODULES}"
# so the existing prepend_path lines resolve to
# /nfsapps/modules/{rocm-<v>, rocmplus-<v>} as intended.

TARBALL="${CACHE_DIR}/${PACKAGE}-modules-${ROCM_VERSION}.tgz"
sudo rm -f "${TARBALL}" 2>/dev/null || rm -f "${TARBALL}"

# Force the staged dirs to be world-readable; otherwise the umask/mktemp-default
# mode of the staging root (0700) would be applied to the extraction target by
# `tar -xzpf -C /nfsapps/modules`, locking down /nfsapps/modules itself.
chmod 755 "${STAGE}"
find "${STAGE}" -mindepth 1 -type d -exec chmod 755 {} +
find "${STAGE}" -mindepth 1 -type f -exec chmod 644 {} +

# Tar only the named subdirs (NOT `.`), so the tarball doesn't carry a `./`
# entry that would re-mode the target directory on extract.
TAR_ENTRIES=()
for d in "${STAGE}"/*; do
   [[ -e "${d}" ]] || continue
   TAR_ENTRIES+=( "$(basename "${d}")" )
done
if (( ${#TAR_ENTRIES[@]} == 0 )); then
   echo "ERROR: nothing to package under ${STAGE}" >&2
   exit 1
fi
SUDO=""
if [ -f /.singularity.d/Singularity ]; then SUDO=""; else SUDO="sudo"; fi
${SUDO} tar --owner=root --group=root -czpf "${TARBALL}" -C "${STAGE}" "${TAR_ENTRIES[@]}"

echo "Wrote ${TARBALL}"
ls -la "${TARBALL}"
