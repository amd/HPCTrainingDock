#!/bin/bash
#
# run_rocm_build.sh - non-interactive build + extract for a single ROCm version.
#
# Phases:
#   0.  Pre-check: skip cleanly (exit 0) if /nfsapps/opt/rocm-<v> already exists
#       and --force-extract is not set.
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
: ${NFSAPPS_OPT:="/nfsapps/opt"}
: ${NFSAPPS_MODULES:="/nfsapps/modules"}
: ${KEEP_TARBALLS:="3"}
: ${SKIP_EXTRACT:="0"}
: ${SKIP_PRUNE:="0"}
: ${FORCE_EXTRACT:="0"}
BARE_LOG=""
MAKE_LOG=""

AMDGPU_GFXMODEL=$(rocminfo 2>/dev/null | grep gfx | sed -e 's/Name://' | head -1 | sed 's/ //g' || true)

send-error() { usage; echo -e "\nError: ${@}"; exit 1; }
reset-last() { last() { send-error "Unsupported argument :: ${1}"; }; }

usage() {
   echo "Usage:"
   echo "  --rocm-version [ ROCM_VERSION ]:        default $ROCM_VERSION"
   echo "  --rocm-install-path [ PATH ]:           default $ROCM_INSTALLPATH"
   echo "  --python-version [ N ]:                 python3 minor release (default $PYTHON_VERSION)"
   echo "  --amdgpu-gfxmodel [ GFX ]:              autodetected via rocminfo; can use 'gfx90a;gfx942'"
   echo "  --distro [DISTRO]:                      default $DISTRO"
   echo "  --distro-version [VER]:                 default $DISTRO_VERSION"
   echo "  --image-name [NAME]:                    default bare-rocm-\${ROCM_VERSION}"
   echo "  --use-makefile [0 or 1]:                default $USE_MAKEFILE"
   echo "  --bare-log [PATH]:                      docker build log; default bare_\${ROCM_VERSION}.out"
   echo "  --make-log [PATH]:                      make-phase log; default make_rocm_package_\${ROCM_VERSION}.out"
   echo "  --nfsapps-opt [DIR]:                    extract destination; default $NFSAPPS_OPT"
   echo "  --nfsapps-modules [DIR]:                modules destination; default $NFSAPPS_MODULES"
   echo "  --force-extract [0 or 1]:               overwrite existing /nfsapps/opt/rocm-<v> (default $FORCE_EXTRACT)"
   echo "  --keep-tarballs [N]:                    prune policy; keep N most recent (default $KEEP_TARBALLS)"
   echo "  --skip-extract [0 or 1]:                skip phase 3 (default $SKIP_EXTRACT)"
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
      "--nfsapps-opt")         shift; NFSAPPS_OPT=${1};        reset-last ;;
      "--nfsapps-modules")     shift; NFSAPPS_MODULES=${1};    reset-last ;;
      "--force-extract")       shift; FORCE_EXTRACT=${1};      reset-last ;;
      "--keep-tarballs")       shift; KEEP_TARBALLS=${1};      reset-last ;;
      "--skip-extract")        shift; SKIP_EXTRACT=${1};       reset-last ;;
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

AMDGPU_GFXMODEL_STRING=$(echo "${AMDGPU_GFXMODEL}" | sed -e 's/;/_/g')
CACHE_DIR="CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}"
TARBALL="${CACHE_DIR}/rocm-${ROCM_VERSION}.tgz"
mkdir -p "${CACHE_DIR}"

# ---------------- Phase 0: skip-if-installed pre-check ----------------
if [[ -d "${NFSAPPS_OPT}/rocm-${ROCM_VERSION}" && "${FORCE_EXTRACT}" != "1" ]]; then
   echo "[$(date)] SKIP rocm-${ROCM_VERSION}: ${NFSAPPS_OPT}/rocm-${ROCM_VERSION} already exists"
   echo "         Pass --force-extract 1 to rebuild & re-install."
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
   if ! sudo -n test -w "${NFSAPPS_OPT}" 2>/dev/null; then
      echo "Attempting to remount ${NFSAPPS_OPT%/*} rw..."
      sudo mount -o remount,rw "${NFSAPPS_OPT%/*}" 2>/dev/null || true
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
   echo "  Phase 3a: extract ${TARBALL} -> ${NFSAPPS_OPT}/"
   echo "============================================================"
   if [[ ! -f "${TARBALL}" ]]; then
      echo "ERROR: expected tarball not found: ${TARBALL}" >&2
      exit 1
   fi
   if [[ ! -d "${NFSAPPS_OPT}" ]]; then
      echo "Creating missing ${NFSAPPS_OPT}"
      sudo install -d -o root -g root -m 0755 "${NFSAPPS_OPT}"
   fi
   if [[ -d "${NFSAPPS_OPT}/rocm-${ROCM_VERSION}" ]]; then
      echo "Removing existing ${NFSAPPS_OPT}/rocm-${ROCM_VERSION} for re-extract (--force-extract was set)"
      sudo rm -rf "${NFSAPPS_OPT}/rocm-${ROCM_VERSION}"
   fi
   sudo tar -xzpf "${TARBALL}" -C "${NFSAPPS_OPT}/"
   sudo chown -R root:root "${NFSAPPS_OPT}/rocm-${ROCM_VERSION}"
   sudo chmod 755 "${NFSAPPS_OPT}/rocm-${ROCM_VERSION}"
   echo "Extracted: ${NFSAPPS_OPT}/rocm-${ROCM_VERSION}"

   echo "============================================================"
   echo "  Phase 3b: extract every *-modules-${ROCM_VERSION}.tgz -> ${NFSAPPS_MODULES}/"
   echo "============================================================"
   if [[ ! -d "${NFSAPPS_MODULES}" ]]; then
      sudo mkdir -p "${NFSAPPS_MODULES}"
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
      if [[ "${FORCE_EXTRACT}" == "1" ]]; then
         sudo rm -f "${NFSAPPS_MODULES}/base/${pkg}/${ROCM_VERSION}.lua" 2>/dev/null || true
         [[ "${pkg}" == "rocm" ]] && sudo rm -f "${NFSAPPS_MODULES}/base/rocm/${ROCM_VERSION}.lua" 2>/dev/null || true
         sudo rm -rf "${NFSAPPS_MODULES}/rocm-${ROCM_VERSION}/${pkg}" 2>/dev/null || true
         sudo rm -rf "${NFSAPPS_MODULES}/rocmplus-${ROCM_VERSION}/${pkg}" 2>/dev/null || true
      fi
      sudo tar -xzpf "${MTGZ}" -C "${NFSAPPS_MODULES}/"
   done

   # Normalize ownership/perms on extracted module trees: the tarball entries
   # may be owned by the in-container builder UID and/or carry mode 0700 on the
   # top-level dir. Make everything root:root, dirs 755, files 644, and ensure
   # /nfsapps/modules itself is world-traversable so non-root users can `ls` it.
   for d in "${NFSAPPS_MODULES}/base" \
            "${NFSAPPS_MODULES}/rocm-${ROCM_VERSION}" \
            "${NFSAPPS_MODULES}/rocmplus-${ROCM_VERSION}" ; do
      [[ -e "${d}" ]] || continue
      sudo chown -R root:root "${d}"
      sudo find "${d}" -type d -exec chmod 755 {} +
      sudo find "${d}" -type f -exec chmod 644 {} +
   done
   sudo chown root:root "${NFSAPPS_MODULES}"
   sudo chmod 755 "${NFSAPPS_MODULES}"

   # ---------------- Phase 3.5: rewrite container-form paths ----------
   echo "============================================================"
   echo "  Phase 3.5: rewrite container-form paths in deployed .lua files"
   echo "============================================================"
   LUA_TARGETS=()
   for cand in \
      "${NFSAPPS_MODULES}/base/rocm/${ROCM_VERSION}.lua" \
      "${NFSAPPS_MODULES}/rocm-${ROCM_VERSION}" \
      "${NFSAPPS_MODULES}/rocmplus-${ROCM_VERSION}" ; do
      [[ -e "${cand}" ]] && LUA_TARGETS+=("${cand}")
   done
   for MTGZ in "${MOD_TARBALLS[@]}"; do
      pkg=$(basename "${MTGZ}")
      pkg=${pkg%-modules-${ROCM_VERSION}.tgz}
      [[ "${pkg}" == "rocm" ]] && continue
      cand="${NFSAPPS_MODULES}/base/${pkg}/${ROCM_VERSION}.lua"
      [[ -e "${cand}" ]] && LUA_TARGETS+=("${cand}")
   done
   if (( ${#LUA_TARGETS[@]} > 0 )); then
      sudo find "${LUA_TARGETS[@]}" -name '*.lua' -print0 | sudo xargs -0 sed -i \
         -e "s|/opt/rocm-${ROCM_VERSION}|${NFSAPPS_OPT}/rocm-${ROCM_VERSION}|g" \
         -e "s|local mbase = \" /etc/lmod/modules/ROCm/rocm\"|local mbase = \"${NFSAPPS_MODULES}\"|" \
         -e "s|local mbase = \"/etc/lmod/modules/ROCm/rocm\"|local mbase = \"${NFSAPPS_MODULES}\"|" \
         -e "s|/etc/lmod/modules/ROCm/rocm|${NFSAPPS_MODULES}/base/rocm|g" \
         -e "s|/etc/lmod/modules/ROCmPlus-MPI|${NFSAPPS_MODULES}/rocmplus-${ROCM_VERSION}|g" \
         -e "s|/etc/lmod/modules/ROCmPlus-AI|${NFSAPPS_MODULES}/rocmplus-${ROCM_VERSION}|g" \
         -e "s|/etc/lmod/modules/ROCmPlus-AMDResearchTools|${NFSAPPS_MODULES}/rocmplus-${ROCM_VERSION}|g" \
         -e "s|/etc/lmod/modules/ROCmPlus-LatestCompilers|${NFSAPPS_MODULES}/rocmplus-${ROCM_VERSION}|g" \
         -e "s|/etc/lmod/modules/ROCmPlus|${NFSAPPS_MODULES}/rocmplus-${ROCM_VERSION}|g" \
         -e "s|/etc/lmod/modules/ROCm|${NFSAPPS_MODULES}/rocm-${ROCM_VERSION}|g" \
         -e "s|/etc/lmod/modules/LinuxPlus|${NFSAPPS_MODULES}/base|g" \
         -e "s|/etc/lmod/modules/misc|${NFSAPPS_MODULES}/rocmplus-${ROCM_VERSION}|g" \
         -e "s|/etc/lmod/modules|${NFSAPPS_MODULES}|g"
      echo "Path rewrite complete."
   else
      echo "WARNING: no deployed module targets found to rewrite."
   fi
fi

echo "============================================================"
echo "  Done: ROCm ${ROCM_VERSION}"
echo "============================================================"
# Phase 4 (prune) runs via trap on EXIT.
