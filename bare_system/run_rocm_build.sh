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
   echo "  --keep-tarballs [N]:                    prune policy; keep N most recent (default $KEEP_TARBALLS)"
   echo "  --skip-extract [0 or 1]:                skip phase 3 (default $SKIP_EXTRACT)"
   echo "  --skip-patches [0 or 1]:                skip phase 3.6 (rocm_patches.sh) (default $SKIP_PATCHES)"
   echo "  --skip-prune [0 or 1]:                  skip phase 4 (default $SKIP_PRUNE)"
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
      "--keep-tarballs")       shift; KEEP_TARBALLS=${1};      reset-last ;;
      "--skip-extract")        shift; SKIP_EXTRACT=${1};       reset-last ;;
      "--skip-patches")        shift; SKIP_PATCHES=${1};       reset-last ;;
      "--skip-prune")          shift; SKIP_PRUNE=${1};         reset-last ;;
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

: ${IMAGE_NAME:="bare-rocm-${ROCM_VERSION}"}
: ${BARE_LOG:="bare_${ROCM_VERSION}.out"}
: ${MAKE_LOG:="make_rocm_package_${ROCM_VERSION}.out"}
: ${PATCHES_LOG:="patches_${ROCM_VERSION}.out"}

AMDGPU_GFXMODEL_STRING=$(echo "${AMDGPU_GFXMODEL}" | sed -e 's/;/_/g')
CACHE_DIR="CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}"
TARBALL="${CACHE_DIR}/rocm-${ROCM_VERSION}.tgz"
mkdir -p "${CACHE_DIR}"

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
   # Match rocm-X.Y.Z.tgz but exclude rocm-modules-*.tgz from the prune set.
   mapfile -t TARBALLS < <(find CacheFiles -maxdepth 2 -type f -name 'rocm-*.tgz' \
                              ! -name 'rocm-modules-*.tgz' \
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
if [[ "${SKIP_EXTRACT}" != "1" ]]; then
   if ! sudo -n test -w "${TOP_INSTALL_PATH}" 2>/dev/null; then
      echo "Attempting to remount ${TOP_INSTALL_PATH%/*} rw..."
      sudo mount -o remount,rw "${TOP_INSTALL_PATH%/*}" 2>/dev/null || true
   fi
fi

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

DISTRO_BUILD_ARG="${DISTRO}"
[[ "${DISTRO_BUILD_ARG}" == *"rocky"* ]] && DISTRO_BUILD_ARG="rockylinux/rockylinux"

# ---------------- Phase 1: docker build -------------------------------
echo "============================================================"
echo "  Phase 1: docker build (-> ${BARE_LOG})"
echo "============================================================"
${BUILDER} build --no-cache ${ADD_OPTIONS} \
             --build-arg DISTRO=${DISTRO_BUILD_ARG}  \
             --build-arg DISTRO_VERSION=${DISTRO_VERSION} \
             --build-arg ROCM_VERSION=${ROCM_VERSION} \
             --build-arg ROCM_INSTALLPATH=${ROCM_INSTALLPATH} \
             --build-arg AMDGPU_GFXMODEL="${AMDGPU_GFXMODEL}" \
             --build-arg USE_MAKEFILE=${USE_MAKEFILE} \
             --build-arg PYTHON_VERSION=${PYTHON_VERSION} \
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
echo "============================================================"
echo "  Phase 2: container run -- make rocm, rocm_package, rocm_module_package"
echo "  NAME=${NAME}  PORT=${PORT_NUMBER}  (-> ${MAKE_LOG})"
echo "============================================================"
${BUILDER} run --device=/dev/kfd --device=/dev/dri \
    --group-add video --group-add render ${ADD_OPTIONS_RUN} \
    -p ${PORT_NUMBER}:22 --name ${NAME}  --security-opt seccomp=unconfined \
    --rm -v $PWD/CacheFiles:/CacheFiles ${IMAGE_NAME} \
    -c 'set -eo pipefail; cd /home/sysadmin && make rocm && make rocm_package && make rocm_module_package' \
    2>&1 | tee "${MAKE_LOG}"

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
      sudo install -d -o root -g root -m 0755 "${TOP_INSTALL_PATH}"
   fi
   if [[ -d "${TOP_INSTALL_PATH}/rocm-${ROCM_VERSION}" ]]; then
      echo "Removing existing ${TOP_INSTALL_PATH}/rocm-${ROCM_VERSION} for re-extract (--replace-existing was set)"
      sudo rm -rf "${TOP_INSTALL_PATH}/rocm-${ROCM_VERSION}"
   fi
   sudo tar -xzpf "${TARBALL}" -C "${TOP_INSTALL_PATH}/"
   sudo chown -R root:root "${TOP_INSTALL_PATH}/rocm-${ROCM_VERSION}"
   sudo chmod 755 "${TOP_INSTALL_PATH}/rocm-${ROCM_VERSION}"
   echo "Extracted: ${TOP_INSTALL_PATH}/rocm-${ROCM_VERSION}"

   echo "============================================================"
   echo "  Phase 3b: extract every *-modules-${ROCM_VERSION}.tgz -> ${TOP_MODULE_PATH}/"
   echo "============================================================"
   if [[ ! -d "${TOP_MODULE_PATH}" ]]; then
      sudo mkdir -p "${TOP_MODULE_PATH}"
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
         sudo rm -f "${TOP_MODULE_PATH}/base/${pkg}/${ROCM_VERSION}.lua" 2>/dev/null || true
         [[ "${pkg}" == "rocm" ]] && sudo rm -f "${TOP_MODULE_PATH}/base/rocm/${ROCM_VERSION}.lua" 2>/dev/null || true
         sudo rm -rf "${TOP_MODULE_PATH}/rocm-${ROCM_VERSION}/${pkg}" 2>/dev/null || true
         sudo rm -rf "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/${pkg}" 2>/dev/null || true
      fi
      sudo tar -xzpf "${MTGZ}" -C "${TOP_MODULE_PATH}/"
   done

   # Normalize ownership/perms on extracted module trees: the tarball entries
   # may be owned by the in-container builder UID and/or carry mode 0700 on the
   # top-level dir. Make everything root:root, dirs 755, files 644, and ensure
   # ${TOP_MODULE_PATH} itself is world-traversable so non-root users can `ls` it.
   for d in "${TOP_MODULE_PATH}/base" \
            "${TOP_MODULE_PATH}/rocm-${ROCM_VERSION}" \
            "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}" ; do
      [[ -e "${d}" ]] || continue
      sudo chown -R root:root "${d}"
      sudo find "${d}" -type d -exec chmod 755 {} +
      sudo find "${d}" -type f -exec chmod 644 {} +
   done
   sudo chown root:root "${TOP_MODULE_PATH}"
   sudo chmod 755 "${TOP_MODULE_PATH}"

   # ---------------- Phase 3.5: rewrite container-form paths ----------
   echo "============================================================"
   echo "  Phase 3.5: rewrite container-form paths in deployed .lua files"
   echo "============================================================"
   LUA_TARGETS=()
   for cand in \
      "${TOP_MODULE_PATH}/base/rocm/${ROCM_VERSION}.lua" \
      "${TOP_MODULE_PATH}/rocm-${ROCM_VERSION}" \
      "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}" ; do
      [[ -e "${cand}" ]] && LUA_TARGETS+=("${cand}")
   done
   for MTGZ in "${MOD_TARBALLS[@]}"; do
      pkg=$(basename "${MTGZ}")
      pkg=${pkg%-modules-${ROCM_VERSION}.tgz}
      [[ "${pkg}" == "rocm" ]] && continue
      cand="${TOP_MODULE_PATH}/base/${pkg}/${ROCM_VERSION}.lua"
      [[ -e "${cand}" ]] && LUA_TARGETS+=("${cand}")
   done
   if (( ${#LUA_TARGETS[@]} > 0 )); then
      sudo find "${LUA_TARGETS[@]}" -name '*.lua' -print0 | sudo xargs -0 sed -i \
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
         sudo chown -R root:root "${TOP_INSTALL_PATH}/rocm-patches-${ROCM_VERSION}"
         sudo find "${TOP_INSTALL_PATH}/rocm-patches-${ROCM_VERSION}" -type d -exec chmod 755 {} +
      fi
      echo "[Phase 3.6] patches applied for ROCm ${ROCM_VERSION}"
   fi
fi

echo "============================================================"
echo "  Done: ROCm ${ROCM_VERSION}"
echo "============================================================"
# Phase 4 (prune) runs via trap on EXIT.
