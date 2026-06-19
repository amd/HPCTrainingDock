#!/bin/bash
#
# run_rocm_build.sh - non-interactive build + extract for a single ROCm version.
#
# Phases:
#   0.  Pre-check: skip cleanly (exit 0) if /nfsapps/opt/rocm-<v> already exists
#       and --replace-existing is not set.
#   1.  docker build (mirrors bare_system/test_install.sh's build phase).
#   2.  container run -- make rocm && make rocm_package && make rocm_module_package
#       (and any future <pkg>_package / <pkg>_module_package added to the chain).
#   3a. extract CacheFiles/.../rocm-<v>.tgz to /nfsapps/opt/.
#   3b. extract every CacheFiles/.../*-modules-<v>.tgz to /nfsapps/modules/.
#   3.5 host-side sed pass to rewrite container-form paths in deployed .lua files.
#   4.  prune oldest CacheFiles rocm-*.tgz (always runs, via trap).

set -eo pipefail

: ${ROCM_VERSION:="6.4.1"}
: ${ROCM_INSTALLPATH:="/opt/"}
: ${USE_MAKEFILE:="1"}
: ${PYTHON_VERSION_INPUT:=""}
: ${PYTHON_VERSION:="12"}
: ${IMAGE_NAME:=""}
: ${DISTRO:="ubuntu"}
: ${DISTRO_VERSION:="24.04"}
: ${TOP_INSTALL_PATH:="/nfsapps/opt"}
: ${TOP_MODULE_PATH:="/nfsapps/modules"}
: ${KEEP_TARBALLS:="3"}
: ${SKIP_EXTRACT:="0"}
: ${SKIP_PRUNE:="0"}
: ${SKIP_PATCHES:="0"}
# --skip-build: extract-only mode. Skips the builder detection, Phase 1
# (docker/podman build) and Phase 2 (container run) entirely and goes straight
# to Phase 3 using a pre-staged ${TARBALL} (and *-modules-${ROCM_VERSION}.tgz)
# already present in CacheFiles. Used to install on a host that has no
# docker/podman/GPU (e.g. a login node) from tarballs built elsewhere.
: ${SKIP_BUILD:="0"}
# --no-sudo: extract into a user-writable destination (e.g. a home dir) without
# sudo. When set, Phase 3 drops the `sudo` prefix and skips the chown root:root
# normalization, leaving the extracted tree owned by the invoking user.
: ${NO_SUDO:="0"}
# --replace-existing is the rocm-sweep analog of run_rocmplus_install_sweep.sh's
# flag of the same name: when set, the existing /opt/rocm-<v> tree (and the
# matching modulefiles) are deleted and re-extracted from a fresh tarball.
# For backwards compatibility we still honour the old FORCE_EXTRACT env var if
# the caller set it without setting REPLACE_EXISTING.
if [ -z "${REPLACE_EXISTING:-}" ] && [ -n "${FORCE_EXTRACT:-}" ]; then
   echo "[run_rocm_build] NOTE: FORCE_EXTRACT is deprecated; map to REPLACE_EXISTING=${FORCE_EXTRACT}" >&2
   REPLACE_EXISTING="${FORCE_EXTRACT}"
fi
: ${REPLACE_EXISTING:="0"}
# Delta-release support (see bare_system/rocm_delta_releases.conf). When set,
# the base install precedes the ${ROCM_VERSION} install inside the container,
# and the trees are merged into a single self-contained /opt/rocm-${ROCM_VERSION}.
# A tombstone modulefile rocm/<SUPERSEDES_VERSION>.lua is also emitted.
: ${BASE_ROCM_VERSION:=""}
: ${SUPERSEDES_VERSION:=""}
BARE_LOG=""
MAKE_LOG=""
PATCHES_LOG=""

AMDGPU_GFXMODEL=$(rocminfo 2>/dev/null | grep gfx | sed -e 's/Name://' | head -1 | sed 's/ //g' || true)

send-error() { usage; echo -e "\nError: ${@}"; exit 1; }
reset-last() { last() { send-error "Unsupported argument :: ${1}"; }; }

usage() {
   echo "Usage:"
   echo "  --rocm-version [ ROCM_VERSION ]:        default $ROCM_VERSION"
   echo "  --rocm-install-path [ PATH ]:           default $ROCM_INSTALLPATH"
   echo "  --python-version [ N ]:                 python3 minor release (default $PYTHON_VERSION)"
   echo "  --amdgpu-gfxmodel [ GFX ]:              autodetected via rocminfo; can use 'gfx942;gfx90a' (order matters for kokkos fallback; first arch wins)"
   echo "  --distro [DISTRO]:                      default $DISTRO"
   echo "  --distro-version [VER]:                 default $DISTRO_VERSION"
   echo "  --image-name [NAME]:                    default bare-rocm-\${ROCM_VERSION}"
   echo "  --use-makefile [0 or 1]:                default $USE_MAKEFILE"
   echo "  --bare-log [PATH]:                      docker build log; default bare_\${ROCM_VERSION}.out"
   echo "  --make-log [PATH]:                      make-phase log; default make_rocm_package_\${ROCM_VERSION}.out"
   echo "  --patches-log [PATH]:                   rocm_patches.sh log; default patches_\${ROCM_VERSION}.out"
   echo "  --top-install-path [DIR]:               extract destination; default $TOP_INSTALL_PATH"
   echo "  --top-module-path [DIR]:                modules destination; default $TOP_MODULE_PATH"
   echo "  --replace-existing [0 or 1]:            overwrite existing \${TOP_INSTALL_PATH}/rocm-<v> (default $REPLACE_EXISTING)"
   echo "                                          (alias: --force-extract -- deprecated, kept for backward compat)"
   echo "  --base-rocm-version [VER]:              delta-release base (install <VER> first then merge \${ROCM_VERSION} on top). Default: empty (auto-consulted from bare_system/rocm_delta_releases.conf)"
   echo "  --supersedes [VER]:                     emit a tombstone rocm/<VER>.lua that redirects to rocm/\${ROCM_VERSION}. Default: empty"
   echo "  --keep-tarballs [N]:                    prune policy; keep N most recent (default $KEEP_TARBALLS)"
   echo "  --skip-extract [0 or 1]:                skip phase 3 (default $SKIP_EXTRACT)"
   echo "  --skip-patches [0 or 1]:                skip phase 3.6 (rocm_patches.sh) (default $SKIP_PATCHES)"
   echo "  --skip-prune [0 or 1]:                  skip phase 4 (default $SKIP_PRUNE)"
   echo "  --skip-build [0 or 1]:                  extract-only: skip builder detection + phase 1 (build) + phase 2 (container), install from pre-staged CacheFiles tarballs (default $SKIP_BUILD)"
   echo "  --no-sudo [0 or 1]:                     extract without sudo / chown root:root into a user-writable destination (default $NO_SUDO)"
   echo "  --help"
   exit 1
}

n=0
while [[ $# -gt 0 ]]; do
   case "${1}" in
      "--rocm-version")        shift; ROCM_VERSION=${1};       reset-last ;;
      "--rocm-install-path")   shift; ROCM_INSTALLPATH=${1};   reset-last ;;
      "--amdgpu-gfxmodel")     shift; AMDGPU_GFXMODEL=${1};    reset-last ;;
      "--python-version")      shift; PYTHON_VERSION_INPUT=${1}; reset-last ;;
      "--distro")              shift; DISTRO=${1};             reset-last ;;
      "--distro-versions")     shift; DISTRO_VERSION=${1};     reset-last ;;
      "--distro-version")      shift; DISTRO_VERSION=${1};     reset-last ;;
      "--image-name")          shift; IMAGE_NAME=${1};         reset-last ;;
      "--use-makefile")        shift; USE_MAKEFILE=${1};       reset-last ;;
      "--bare-log")            shift; BARE_LOG=${1};           reset-last ;;
      "--make-log")            shift; MAKE_LOG=${1};           reset-last ;;
      "--patches-log")         shift; PATCHES_LOG=${1};        reset-last ;;
      "--top-install-path")    shift; TOP_INSTALL_PATH=${1};   reset-last ;;
      "--top-module-path")     shift; TOP_MODULE_PATH=${1};    reset-last ;;
      "--replace-existing")    shift; REPLACE_EXISTING=${1};   reset-last ;;
      "--force-extract")       shift; REPLACE_EXISTING=${1};   reset-last
                               echo "[run_rocm_build] NOTE: --force-extract is deprecated; use --replace-existing" >&2 ;;
      "--base-rocm-version")   shift; BASE_ROCM_VERSION=${1};  reset-last ;;
      "--supersedes")          shift; SUPERSEDES_VERSION=${1}; reset-last ;;
      "--keep-tarballs")       shift; KEEP_TARBALLS=${1};      reset-last ;;
      "--skip-extract")        shift; SKIP_EXTRACT=${1};       reset-last ;;
      "--skip-patches")        shift; SKIP_PATCHES=${1};       reset-last ;;
      "--skip-prune")          shift; SKIP_PRUNE=${1};         reset-last ;;
      "--skip-build")          shift; SKIP_BUILD=${1};         reset-last ;;
      "--no-sudo")             shift; NO_SUDO=${1};            reset-last ;;
      "--help")                usage ;;
      *)                       last ${1} ;;
   esac
   n=$((${n} + 1))
   shift
done

if [[ "${PYTHON_VERSION_INPUT}" == "" ]]; then
   if [[ "${DISTRO}" == "ubuntu" ]]; then
      [[ "${DISTRO_VERSION}" == "24.04" ]] && PYTHON_VERSION="12"
      [[ "${DISTRO_VERSION}" == "22.04" ]] && PYTHON_VERSION="10"
   fi
else
   PYTHON_VERSION=${PYTHON_VERSION_INPUT}
fi

# ---------------- Privilege escalation prefix ------------------------
# Phase 3 (extract/chown/chmod/mkdir) defaults to running its filesystem
# mutations through sudo so it can write a root-owned tree under /nfsapps,
# /shared/apps, etc. When --no-sudo 1 is passed (e.g. a home-dir install on a
# login node where the user has no passwordless sudo), drop the prefix and let
# the ownership fall to the invoking user; the chown root:root normalizations
# are skipped in that mode (guarded individually below).
if [[ "${NO_SUDO}" == "1" ]]; then
   SUDO=""
else
   SUDO="sudo"
fi

# chown-to-root helper: chowning to root only works with privilege, so in
# --no-sudo mode it is a no-op (the tree stays owned by the invoking user).
chown_root() {
   [[ "${NO_SUDO}" == "1" ]] && return 0
   ${SUDO} chown "$@"
}
# directory-create helper: root-owned 0755 dir with sudo, plain mkdir -p in
# --no-sudo mode (so the user-owned parents are created without privilege).
make_dir_root() {
   if [[ "${NO_SUDO}" == "1" ]]; then
      mkdir -p "$1"
   else
      ${SUDO} install -d -o root -g root -m 0755 "$1"
   fi
}

# ---------------- Delta-release auto-detect from conf -----------------
# If the user did not pass --base-rocm-version, consult the registry file
# bare_system/rocm_delta_releases.conf. When ${ROCM_VERSION} is listed there,
# the matching base is used and SUPERSEDES_VERSION defaults to that base too.
# Pass --base-rocm-version explicitly to override.
DELTA_CONF="$(dirname "$0")/rocm_delta_releases.conf"
if [[ -z "${BASE_ROCM_VERSION}" && -f "${DELTA_CONF}" ]]; then
   _conf_base=$(awk -F= -v v="${ROCM_VERSION}" '
      /^[[:space:]]*#/ {next}
      /^[[:space:]]*$/ {next}
      $1 == v {print $2; exit}
   ' "${DELTA_CONF}")
   if [[ -n "${_conf_base}" ]]; then
      echo "[run_rocm_build] delta-release auto-config: ${ROCM_VERSION} is registered as a delta (base=${_conf_base}); setting --base-rocm-version ${_conf_base} --supersedes ${_conf_base}"
      BASE_ROCM_VERSION="${_conf_base}"
      [[ -z "${SUPERSEDES_VERSION}" ]] && SUPERSEDES_VERSION="${_conf_base}"
   fi
   unset _conf_base
fi

: ${IMAGE_NAME:="bare-rocm-${ROCM_VERSION}"}
: ${BARE_LOG:="bare_${ROCM_VERSION}.out"}
: ${MAKE_LOG:="make_rocm_package_${ROCM_VERSION}.out"}
: ${PATCHES_LOG:="patches_${ROCM_VERSION}.out"}

AMDGPU_GFXMODEL_STRING=$(echo "${AMDGPU_GFXMODEL}" | sed -e 's/;/_/g')
CACHE_DIR="CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}"
TARBALL="${CACHE_DIR}/rocm-${ROCM_VERSION}.tgz"
mkdir -p "${CACHE_DIR}"

# Delta-release mode: a stale tarball at ${TARBALL} from a previous build
# (pre-delta-merge) would otherwise be auto-extracted inside the container by
# rocm_setup.sh's "Installing Cached ROCm" branch, skipping the base+delta+merge
# work entirely. CacheFiles is bind-mounted into the container at /CacheFiles,
# so we wipe the host copy here before docker build.
if [[ -n "${BASE_ROCM_VERSION}" && -f "${TARBALL}" ]]; then
   echo "[run_rocm_build] delta-release mode: removing stale ${TARBALL} to force a fresh base+delta+merge build"
   rm -f "${TARBALL}"
fi

# ---------------- Phase 0: skip-if-installed pre-check ----------------
if [[ -d "${TOP_INSTALL_PATH}/rocm-${ROCM_VERSION}" && "${REPLACE_EXISTING}" != "1" ]]; then
   echo "[$(date)] SKIP rocm-${ROCM_VERSION}: ${TOP_INSTALL_PATH}/rocm-${ROCM_VERSION} already exists"
   echo "         Pass --replace-existing 1 to rebuild & re-install."
   exit 0
fi

# ---------------- Phase 4 (prune) trap setup --------------------------
prune_cache() {
   local rc=$?
   if [[ "${SKIP_PRUNE}" == "1" ]]; then
      return ${rc}
   fi
   echo "============================================================"
   echo "  Phase 4: prune CacheFiles/.../rocm-*.tgz (keep ${KEEP_TARBALLS} most recent)"
   echo "============================================================"
   df -h "$PWD/CacheFiles" 2>/dev/null || true
   # Match rocm-X.Y.Z.tgz but exclude rocm-modules-*.tgz and rocm-afar-*.tgz
   # from the prune set. The afar tarballs are the AMD AFAR flang-new
   # compiler payload (see Phase 3c); they are tied to a specific cache dir
   # (and therefore a specific ROCm version) and do not consume the
   # KEEP_TARBALLS budget the way the multi-GB rocm-X.Y.Z.tgz files do.
   mapfile -t TARBALLS < <(find CacheFiles -maxdepth 2 -type f -name 'rocm-*.tgz' \
                              ! -name 'rocm-modules-*.tgz' \
                              ! -name 'rocm-afar-*.tgz' \
                              -printf '%T@ %p\n' 2>/dev/null \
                              | sort -n | awk '{print $2}')
   local N=${#TARBALLS[@]}
   if (( N > KEEP_TARBALLS )); then
      local TO_DELETE=$(( N - KEEP_TARBALLS ))
      echo "Found ${N} rocm-*.tgz tarballs (excluding modules), removing ${TO_DELETE} oldest:"
      for ((i=0; i<TO_DELETE; i++)); do
         echo "  rm ${TARBALLS[$i]}"
         rm -f "${TARBALLS[$i]}"
      done
   else
      echo "Found ${N} rocm-*.tgz tarballs; <= keep-tarballs (${KEEP_TARBALLS}). Nothing to prune."
   fi
   df -h "$PWD/CacheFiles" 2>/dev/null || true
   return ${rc}
}
trap prune_cache EXIT

# ---------------- Defensive remount of /nfsapps as rw -----------------
# /etc/exports.d/nfsapps_sh5_rw.exports grants rw to sh5 admin nodes, but the
# warewulf-managed fstab still mounts /nfsapps ro by default. Remount rw if
# possible so Phase 3's sudo tar can write. No-op on hosts where rw is already
# granted or where we can't write regardless.
if [[ "${SKIP_EXTRACT}" != "1" && "${NO_SUDO}" != "1" ]]; then
   if ! sudo -n test -w "${TOP_INSTALL_PATH}" 2>/dev/null; then
      echo "Attempting to remount ${TOP_INSTALL_PATH%/*} rw..."
      sudo mount -o remount,rw "${TOP_INSTALL_PATH%/*}" 2>/dev/null || true
   fi
fi

# ---------------- Phases 1+2 (build) -- skipped in extract-only mode --
# --skip-build 1 jumps straight to Phase 3 using a pre-staged ${TARBALL}
# (and *-modules-${ROCM_VERSION}.tgz) already present in CacheFiles, so a host
# with no docker/podman/GPU can install tarballs built elsewhere.
if [[ "${SKIP_BUILD}" != "1" ]]; then

# ---------------- Builder detection (docker/podman) -------------------
ADD_OPTIONS=""
echo "Using Docker as default, falling back to Podman if Docker is not installed"
if command docker -v >/dev/null 2>&1; then
   BUILDER=docker
elif command podman -v >/dev/null 2>&1; then
   BUILDER=podman
else
   echo "ERROR: neither Podman nor Docker found"
   exit 1
fi
[[ "$BUILDER" == "podman" ]] && ADD_OPTIONS="${ADD_OPTIONS} --format docker"

# Base container image (FROM ...) decoupled from the DISTRO token. The DISTRO
# token is kept clean (no slashes) so it can be used verbatim in the host/
# container cache-dir name (${DISTRO}-${DISTRO_VERSION}-rocm-...); only the
# pullable image name is remapped here for RHEL-family distros whose Docker Hub
# image name differs from the os-release NAME.
#   rhel / "red hat enterprise linux" -> redhat/ubi9 (os-release reports
#                                        "Red Hat Enterprise Linux" / 9.6, so
#                                        the RHEL-compatible branches and the
#                                        amdgpu-install rhel/<minor> URL both
#                                        resolve correctly).
#   rocky / "rocky linux"             -> rockylinux/rockylinux
BASE_IMAGE="${DISTRO}"
case "${DISTRO}" in
   *rocky*)                          BASE_IMAGE="rockylinux/rockylinux" ;;
   rhel|"red hat enterprise linux")  BASE_IMAGE="redhat/ubi9" ;;
esac

# ---------------- Phase 1: docker build -------------------------------
echo "============================================================"
echo "  Phase 1: docker build (-> ${BARE_LOG})"
echo "============================================================"
${BUILDER} build --no-cache ${ADD_OPTIONS} \
             --build-arg DISTRO="${DISTRO}"  \
             --build-arg BASE_IMAGE="${BASE_IMAGE}" \
             --build-arg CRAY_SYSTEM="${CRAY_SYSTEM:-}" \
             --build-arg DISTRO_VERSION=${DISTRO_VERSION} \
             --build-arg ROCM_VERSION=${ROCM_VERSION} \
             --build-arg ROCM_INSTALLPATH=${ROCM_INSTALLPATH} \
             --build-arg AMDGPU_GFXMODEL="${AMDGPU_GFXMODEL}" \
             --build-arg USE_MAKEFILE=${USE_MAKEFILE} \
             --build-arg PYTHON_VERSION=${PYTHON_VERSION} \
             --build-arg BASE_ROCM_VERSION="${BASE_ROCM_VERSION}" \
             --build-arg SUPERSEDES_VERSION="${SUPERSEDES_VERSION}" \
             -t ${IMAGE_NAME} \
             -f bare_system/Dockerfile . 2>&1 | tee "${BARE_LOG}"

RHEL_COMPATIBLE=0
[[ "${DISTRO}" = "red hat enterprise linux" || "${DISTRO}" == *"rocky"* || "${DISTRO}" == "almalinux" ]] && RHEL_COMPATIBLE=1

ADD_OPTIONS_RUN=""
if [[ "${DISTRO}" == "ubuntu" || "${RHEL_COMPATIBLE}" == 1 ]]; then
   ADD_OPTIONS_RUN="${ADD_OPTIONS_RUN} --group-add renderalt"
fi

NAMEBASE=BareBuild
NAME=$NAMEBASE
NUMBER=0
while [ "$(${BUILDER} inspect --format='{{.Name}}' $NAME 2>&1 | grep /$NAME | wc -l)" != "0" ]; do
   NUMBER=$((NUMBER+1))
   NAME=$NAMEBASE$NUMBER
done
PORT_NUMBER=2222
while [ "$(${BUILDER} ps | grep -w "${PORT_NUMBER}" | wc -l)" != "0" ]; do
   PORT_NUMBER=$((PORT_NUMBER+1))
done

# ---------------- Phase 2: container run ------------------------------
# For ROCm 6.x.x, also build the AMD AFAR flang-new compiler (rocm/scripts/
# flang-new_setup.sh). This is the in-tree replacement for the deprecated
# ROCm 6 stock fortran toolchain; ROCm 7+ ships a working amdflang in the
# SDK directly so this extra step is gated on the major version. The
# Makefile target `flang-new` depends on `rocm.timestamp`; flang-new_package
# (writes ${CACHE_DIR}/rocm-afar-<rel>.tgz) and flang-new_module_package
# (writes ${CACHE_DIR}/amdflang-new-modules-${ROCM_VERSION}.tgz) are then
# extracted on the host in Phase 3c and Phase 3b respectively.
ROCM_MAJOR="${ROCM_VERSION%%.*}"
MAKE_TARGETS="make rocm && make rocm_package && make rocm_module_package"
if [[ "${ROCM_MAJOR}" == "6" ]]; then
   MAKE_TARGETS="${MAKE_TARGETS} && make flang-new && make flang-new_package && make flang-new_module_package"
   PHASE2_BANNER_TARGETS="rocm, rocm_package, rocm_module_package, flang-new, flang-new_package, flang-new_module_package"
else
   PHASE2_BANNER_TARGETS="rocm, rocm_package, rocm_module_package"
fi
echo "============================================================"
echo "  Phase 2: container run -- make ${PHASE2_BANNER_TARGETS}"
echo "  NAME=${NAME}  PORT=${PORT_NUMBER}  (-> ${MAKE_LOG})"
echo "============================================================"
${BUILDER} run --device=/dev/kfd --device=/dev/dri \
    --group-add video --group-add render ${ADD_OPTIONS_RUN} \
    -p ${PORT_NUMBER}:22 --name ${NAME}  --security-opt seccomp=unconfined \
    --rm -v $PWD/CacheFiles:/CacheFiles ${IMAGE_NAME} \
    -c "set -eo pipefail; cd /home/sysadmin && ${MAKE_TARGETS}" \
    2>&1 | tee "${MAKE_LOG}"

else
   echo "============================================================"
   echo "  --skip-build 1: skipping builder detection + Phase 1 (build) + Phase 2 (container)"
   echo "  Installing from pre-staged tarballs in ${CACHE_DIR}"
   echo "============================================================"
fi

# ---------------- Phase 3: extract tarballs ---------------------------
if [[ "${SKIP_EXTRACT}" != "1" ]]; then
   echo "============================================================"
   echo "  Phase 3a: extract ${TARBALL} -> ${TOP_INSTALL_PATH}/"
   echo "============================================================"
   if [[ ! -f "${TARBALL}" ]]; then
      echo "ERROR: expected tarball not found: ${TARBALL}" >&2
      exit 1
   fi
   if [[ ! -d "${TOP_INSTALL_PATH}" ]]; then
      echo "Creating missing ${TOP_INSTALL_PATH}"
      make_dir_root "${TOP_INSTALL_PATH}"
   fi
   if [[ -d "${TOP_INSTALL_PATH}/rocm-${ROCM_VERSION}" ]]; then
      echo "Removing existing ${TOP_INSTALL_PATH}/rocm-${ROCM_VERSION} for re-extract (--replace-existing was set)"
      ${SUDO} rm -rf "${TOP_INSTALL_PATH}/rocm-${ROCM_VERSION}"
   fi
   # Replacing the SDK invalidates any sibling rocm_patches.sh overlay
   # built against the prior tree (the overlay's librocprof-sys.so /
   # rocprof-compute.bin were linked to specific SDK headers/.so SONAMEs
   # which the fresh extract may bump). When --skip-patches 1 is set the
   # operator has explicitly opted out, so leaving the orphan tree on
   # disk produces a confusing false-positive in inventory_packages.py
   # (rocm_patches_presence() only checks file existence in the overlay
   # tree, not whether the SDK modulefile actually loads it). When
   # patches are enabled, Phase 3.6 rebuilds the overlay below, so the
   # rm here is harmless either way. The check is unconditional within
   # the REPLACE_EXISTING-gated block (the early-exit at the top of the
   # script already guarantees we only reach here when --replace-existing
   # 1 was supplied or the SDK dir was absent to begin with).
   if [[ -d "${TOP_INSTALL_PATH}/rocm-patches-${ROCM_VERSION}" ]]; then
      echo "Removing sibling overlay ${TOP_INSTALL_PATH}/rocm-patches-${ROCM_VERSION} (stale vs the fresh SDK extract)"
      ${SUDO} rm -rf "${TOP_INSTALL_PATH}/rocm-patches-${ROCM_VERSION}"
   fi
   ${SUDO} tar -xzpf "${TARBALL}" -C "${TOP_INSTALL_PATH}/"
   chown_root -R root:root "${TOP_INSTALL_PATH}/rocm-${ROCM_VERSION}"
   ${SUDO} chmod 755 "${TOP_INSTALL_PATH}/rocm-${ROCM_VERSION}"
   echo "Extracted: ${TOP_INSTALL_PATH}/rocm-${ROCM_VERSION}"

   echo "============================================================"
   echo "  Phase 3b: extract every *-modules-${ROCM_VERSION}.tgz -> ${TOP_MODULE_PATH}/"
   echo "============================================================"
   if [[ ! -d "${TOP_MODULE_PATH}" ]]; then
      ${SUDO} mkdir -p "${TOP_MODULE_PATH}"
   fi
   shopt -s nullglob
   MOD_TARBALLS=( "${CACHE_DIR}"/*-modules-"${ROCM_VERSION}".tgz )
   shopt -u nullglob
   if (( ${#MOD_TARBALLS[@]} == 0 )); then
      echo "WARNING: no *-modules-${ROCM_VERSION}.tgz tarballs found in ${CACHE_DIR}"
   fi
   for MTGZ in "${MOD_TARBALLS[@]}"; do
      pkg=$(basename "${MTGZ}")
      pkg=${pkg%-modules-${ROCM_VERSION}.tgz}
      echo "Extracting modules for ${pkg}: ${MTGZ}"
      if [[ "${REPLACE_EXISTING}" == "1" ]]; then
         ${SUDO} rm -f "${TOP_MODULE_PATH}/base/${pkg}/${ROCM_VERSION}.lua" 2>/dev/null || true
         [[ "${pkg}" == "rocm" ]] && ${SUDO} rm -f "${TOP_MODULE_PATH}/base/rocm/${ROCM_VERSION}.lua" 2>/dev/null || true
         ${SUDO} rm -rf "${TOP_MODULE_PATH}/rocm-${ROCM_VERSION}/${pkg}" 2>/dev/null || true
         ${SUDO} rm -rf "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/${pkg}" 2>/dev/null || true
      fi
      ${SUDO} tar -xzpf "${MTGZ}" -C "${TOP_MODULE_PATH}/"
   done

   # Normalize ownership/perms on extracted module trees: the tarball entries
   # may be owned by the in-container builder UID and/or carry mode 0700 on the
   # top-level dir. Make everything root:root, dirs 755, files 644, and ensure
   # ${TOP_MODULE_PATH} itself is world-traversable so non-root users can `ls` it.
   for d in "${TOP_MODULE_PATH}/base" \
            "${TOP_MODULE_PATH}/rocm-${ROCM_VERSION}" \
            "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}" ; do
      [[ -e "${d}" ]] || continue
      chown_root -R root:root "${d}"
      ${SUDO} find "${d}" -type d -exec chmod 755 {} +
      ${SUDO} find "${d}" -type f -exec chmod 644 {} +
   done
   chown_root root:root "${TOP_MODULE_PATH}"
   ${SUDO} chmod 755 "${TOP_MODULE_PATH}"

   # ---------------- Phase 3c: extract rocm-afar-*.tgz (flang-new) ----
   # ROCm 6.x.x adds the AMD AFAR flang-new compiler under /opt/rocmplus-<v>/
   # rocm-afar-<release>/ inside the container; deploy_package.sh produces
   # ${CACHE_DIR}/rocm-afar-<release>.tgz with `rocm-afar-<release>/...`
   # as a top-level entry. Extract every such tarball under
   # ${TOP_INSTALL_PATH}/rocmplus-${ROCM_VERSION}/ so the host modulefile's
   # `local base = "/opt/rocmplus-${ROCM_VERSION}/rocm-afar-<release>"`
   # (rewritten to ${TOP_INSTALL_PATH}/rocmplus-... in Phase 3.5) resolves.
   # Skipped silently when no afar tarballs exist (i.e. ROCm 7.x sweeps).
   shopt -s nullglob
   AFAR_TARBALLS=( "${CACHE_DIR}"/rocm-afar-*.tgz )
   shopt -u nullglob
   if (( ${#AFAR_TARBALLS[@]} > 0 )); then
      echo "============================================================"
      echo "  Phase 3c: extract rocm-afar-*.tgz -> ${TOP_INSTALL_PATH}/rocmplus-${ROCM_VERSION}/"
      echo "============================================================"
      ROCMPLUS_DEST="${TOP_INSTALL_PATH}/rocmplus-${ROCM_VERSION}"
      if [[ ! -d "${ROCMPLUS_DEST}" ]]; then
         make_dir_root "${ROCMPLUS_DEST}"
      fi
      for ATGZ in "${AFAR_TARBALLS[@]}"; do
         afar=$(basename "${ATGZ}")
         afar=${afar%.tgz}
         echo "Extracting ${afar}: ${ATGZ}"
         if [[ "${REPLACE_EXISTING}" == "1" && -d "${ROCMPLUS_DEST}/${afar}" ]]; then
            echo "  --replace-existing: removing existing ${ROCMPLUS_DEST}/${afar}"
            ${SUDO} rm -rf "${ROCMPLUS_DEST}/${afar}"
         fi
         ${SUDO} tar -xzpf "${ATGZ}" -C "${ROCMPLUS_DEST}/"
         chown_root -R root:root "${ROCMPLUS_DEST}/${afar}"
         ${SUDO} chmod 755 "${ROCMPLUS_DEST}/${afar}"
      done
      echo "Extracted: ${ROCMPLUS_DEST}/rocm-afar-*"
   fi

   # ---------------- Phase 3.5: rewrite container-form paths ----------
   echo "============================================================"
   echo "  Phase 3.5: rewrite container-form paths in deployed .lua files"
   echo "============================================================"
   # Cover the whole base/ tree (base/rocm, base/amd, base/<pkg>) plus the
   # versioned component/add-on trees. Using directories (rather than specific
   # *.lua paths) means the rewrite also reaches the extensionless Tcl
   # modulefiles emitted for Cray systems.
   LUA_TARGETS=()
   for cand in \
      "${TOP_MODULE_PATH}/base" \
      "${TOP_MODULE_PATH}/rocm-${ROCM_VERSION}" \
      "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}" ; do
      [[ -e "${cand}" ]] && LUA_TARGETS+=("${cand}")
   done
   if (( ${#LUA_TARGETS[@]} > 0 )); then
      # -type f matches both .lua (Lmod) and extensionless Tcl modulefiles. The
      # Lmod-specific mbase / .lua rules below simply don't match Tcl content,
      # while the /opt/rocm-<v> rewrite (needed by both) applies to all files.
      ${SUDO} find "${LUA_TARGETS[@]}" -type f -print0 | ${SUDO} xargs -0 sed -i \
         -e "s|/opt/rocmplus-${ROCM_VERSION}|${TOP_INSTALL_PATH}/rocmplus-${ROCM_VERSION}|g" \
         -e "s|/opt/rocm-${ROCM_VERSION}|${TOP_INSTALL_PATH}/rocm-${ROCM_VERSION}|g" \
         -e "s|local mbase = \" /etc/lmod/modules/ROCm/rocm\"|local mbase = \"${TOP_MODULE_PATH}\"|" \
         -e "s|local mbase = \"/etc/lmod/modules/ROCm/rocm\"|local mbase = \"${TOP_MODULE_PATH}\"|" \
         -e "s|/etc/lmod/modules/ROCm/rocm|${TOP_MODULE_PATH}/base/rocm|g" \
         -e "s|/etc/lmod/modules/ROCmPlus-MPI|${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}|g" \
         -e "s|/etc/lmod/modules/ROCmPlus-AI|${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}|g" \
         -e "s|/etc/lmod/modules/ROCmPlus-AMDResearchTools|${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}|g" \
         -e "s|/etc/lmod/modules/ROCmPlus-LatestCompilers|${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}|g" \
         -e "s|/etc/lmod/modules/ROCmPlus|${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}|g" \
         -e "s|/etc/lmod/modules/ROCm|${TOP_MODULE_PATH}/rocm-${ROCM_VERSION}|g" \
         -e "s|/etc/lmod/modules/LinuxPlus|${TOP_MODULE_PATH}/base|g" \
         -e "s|/etc/lmod/modules/misc|${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}|g" \
         -e "s|/etc/lmod/modules|${TOP_MODULE_PATH}|g"
      echo "Path rewrite complete."
   else
      echo "WARNING: no deployed module targets found to rewrite."
   fi
fi

# ---------------- Phase 3.6: apply vendored ROCm patches --------------
# Run rocm/scripts/rocm_patches.sh on the host against the just-extracted
# SDK tree at ${TOP_INSTALL_PATH}/rocm-${ROCM_VERSION} and the path-rewritten
# modulefile at ${TOP_MODULE_PATH}/base/rocm/${ROCM_VERSION}.lua.
#
# The script is selective by ROCM_VERSION (see rocm_version_to_patches()
# in rocm/scripts/rocm_patches.sh):
#   * 7.2.0 / 7.2.1                 -> rocprof-sys-1.3.0 cherry-pick + build (~30 min)
#   * 6.3.x / 6.4.x / 7.0.x / 7.1.x -> rocprof-compute nuitka build (~25-30 min)
#   * afar-22.x / therock-23.2.0    -> rocprof-compute, usually soft-noop 43
#   * everything else               -> exit 43 (NOOP_RC, fast no-op)
#
# Exit codes (rocm_patches.sh):
#   0  -- patches applied (or already up to date)
#   43 -- intentional no-op (no vendored fix for this version)
#   *  -- hard error
#
# Writes:
#   * ${TOP_INSTALL_PATH}/rocm-patches-${ROCM_VERSION}/        overlay tree
#   * appends LD_LIBRARY_PATH/PATH prepend to
#     ${TOP_MODULE_PATH}/base/rocm/${ROCM_VERSION}.lua    (idempotent)
#   * swaps ${TOP_INSTALL_PATH}/rocm-${ROCM_VERSION}/lib/librocprof-sys.so.X.Y.Z
#     to a symlink into the overlay; original preserved as .orig
#
# Gated by SKIP_EXTRACT (no tree to patch if we skipped extract) and
# SKIP_PATCHES (operator opt-out). PATCH_SOURCE_DIR is auto-detected
# next to rocm/scripts/rocm_patches.sh (repo layout).
if [[ "${SKIP_EXTRACT}" != "1" && "${SKIP_PATCHES}" != "1" ]]; then
   echo "============================================================"
   echo "  Phase 3.6: rocm_patches.sh on ${TOP_INSTALL_PATH}/rocm-${ROCM_VERSION} (-> ${PATCHES_LOG})"
   echo "============================================================"
   PATCHES_RC=0
   set +e
   rocm/scripts/rocm_patches.sh \
         --rocm-version    "${ROCM_VERSION}" \
         --rocm-path       "${TOP_INSTALL_PATH}/rocm-${ROCM_VERSION}" \
         --install-prefix  "${TOP_INSTALL_PATH}/rocm-patches-${ROCM_VERSION}" \
         --module-path     "${TOP_MODULE_PATH}/base" \
         2>&1 | tee "${PATCHES_LOG}"
   PATCHES_RC=${PIPESTATUS[0]}
   set -e
   if [[ "${PATCHES_RC}" -eq 43 ]]; then
      echo "[Phase 3.6] rocm_patches.sh returned 43 (NOOP_RC) -- no vendored fix for ROCm ${ROCM_VERSION}; treating as success"
   elif [[ "${PATCHES_RC}" -ne 0 ]]; then
      echo "ERROR: rocm_patches.sh failed for ROCm ${ROCM_VERSION} (rc=${PATCHES_RC})" >&2
      exit "${PATCHES_RC}"
   else
      # Normalize ownership/perms on the overlay tree so it matches the
      # SDK tree extracted in Phase 3a (root:root, dirs 755, files
      # preserved by `install -m 0755` inside the script).
      if [[ -d "${TOP_INSTALL_PATH}/rocm-patches-${ROCM_VERSION}" ]]; then
         chown_root -R root:root "${TOP_INSTALL_PATH}/rocm-patches-${ROCM_VERSION}"
         ${SUDO} find "${TOP_INSTALL_PATH}/rocm-patches-${ROCM_VERSION}" -type d -exec chmod 755 {} +
      fi
      echo "[Phase 3.6] patches applied for ROCm ${ROCM_VERSION}"
   fi
fi

echo "============================================================"
echo "  Done: ROCm ${ROCM_VERSION}"
echo "============================================================"
# Phase 4 (prune) runs via trap on EXIT.
