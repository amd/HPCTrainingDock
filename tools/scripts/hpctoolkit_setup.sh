#!/bin/bash

# Fail fast on errors and surface failures inside pipes. Not using -u
# (nounset) because some conditional code paths rely on unset variables.
set -eo pipefail

# ── Preflight: declare and load required Lmod modules ─────────────────
# Inlined (formerly bare_system/lib/preflight.sh) so this script is
# self-contained and can be copied/run standalone. preflight_modules
# loads each module in order; on the first failure it prints the Lmod
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

# Variables controlling setup process
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
MODULE_PATH=/etc/lmod/modules/ROCmPlus/hpctoolkit
BUILD_HPCTOOLKIT=0
HPCTOOLKIT_VERSION=2025.1.2
# Spack-resolved upstream version of hpcviewer. Pinned (vs. left as
# spack's default "latest") so the install dir name + cache tar name
# + modulefile path + replace-cleanup all agree on the same concrete
# string across runs. Job 8063 audit: spack actually emits a clean
# semver in the install dir (.../hpcviewer-2026.0.0-<spackhash>/),
# which contradicted the prior "no clean upstream version" comment
# that justified leaving hpcviewer unversioned. Override with
# `--hpcviewer-version X.Y.Z` (or HPCVIEWER_VERSION=... env) when a
# new spack-known release is needed.
HPCVIEWER_VERSION=2026.0.0
ROCM_VERSION=6.2.0
SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"
# Versioned hpctoolkit + hpcviewer install dirs let multiple releases
# coexist under one ROCm tree (matches the convention used by every
# other versioned package: magma-v*, openblas-v*, fftw-v*, etc.).
# hpcviewer was previously unversioned on the (incorrect) belief that
# spack didn't expose a clean upstream version; job 8063 disk audit
# showed otherwise -- spack puts hpcviewer-${VERSION}-<hash> right
# in the install path -- so we now extract that ${VERSION} via the
# HPCVIEWER_VERSION pin above and write to a parallel versioned dir.
HPCTOOLKIT_PATH=/opt/rocmplus-${ROCM_VERSION}/hpctoolkit-v${HPCTOOLKIT_VERSION}
HPCVIEWER_PATH=/opt/rocmplus-${ROCM_VERSION}/hpcviewer-v${HPCVIEWER_VERSION}
HPCTOOLKIT_PATH_INPUT=""
HPCVIEWER_PATH_INPUT=""
# --replace 1: rm -rf both hpctoolkit and hpcviewer install dirs +
# ${HPCTOOLKIT_VERSION}.lua before building. They're versioned together
# under the single hpctoolkit modulefile so we treat them as one unit.
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup. See hypre_setup.sh.
REPLACE=0
KEEP_FAILED_INSTALLS=0


if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi

# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --hpctoolkit-install-path, --hpcviewer-install-path  and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --hpctoolkit-version [ HPCTOOLKIT_VERSION ] default $HPCTOOLKIT_VERSION"
   echo "  --hpcviewer-version [ HPCVIEWER_VERSION ] spack-resolved upstream version, default $HPCVIEWER_VERSION"
   echo "  --hpctoolkit-install-path [ HPCTOOLKIT_PATH_INPUT ] default $HPCTOOLKIT_PATH "
   echo "  --hpcviewer-install-path [ HPCVIEWER_PATH_INPUT ] default $HPCVIEWER_PATH "
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected"
   echo "  --build-hpctoolkit [ BUILD_HPCTOOLKIT ] default is 0"
   echo "  --replace [ 0|1 ] remove prior hpctoolkit + hpcviewer installs and modulefile before building, default $REPLACE"
   echo "  --keep-failed-installs [ 0|1 ] skip EXIT-trap cleanup of partial installs on failure, default $KEEP_FAILED_INSTALLS"
   echo "  --help: print this usage information"
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

n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
          reset-last
          ;;
      "--build-hpctoolkit")
          shift
          BUILD_HPCTOOLKIT=${1}
          reset-last
          ;;
      "--hpctoolkit-install-path")
          shift
          HPCTOOLKIT_PATH_INPUT=${1}
          reset-last
          ;;
      "--hpctoolkit-version")
          shift
          HPCTOOLKIT_VERSION=${1}
          reset-last
          ;;
      "--hpcviewer-version")
          shift
          HPCVIEWER_VERSION=${1}
          reset-last
          ;;
      "--hpcviewer-install-path")
          shift
          HPCVIEWER_PATH_INPUT=${1}
          reset-last
          ;;
      "--help")
          usage
          ;;
      "--module-path")
          shift
          MODULE_PATH=${1}
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
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
      "--*")
          send-error "Unsupported argument at position $((${n} + 1)) :: ${1}"
          ;;
      *)
         last ${1}
         ;;
   esac
   n=$((${n} + 1))
   shift
done

# Recompute install paths now that ROCM_VERSION / HPCTOOLKIT_VERSION /
# HPCVIEWER_VERSION may have been overridden by --rocm-version /
# --hpctoolkit-version / --hpcviewer-version.
HPCTOOLKIT_PATH=/opt/rocmplus-${ROCM_VERSION}/hpctoolkit-v${HPCTOOLKIT_VERSION}
HPCVIEWER_PATH=/opt/rocmplus-${ROCM_VERSION}/hpcviewer-v${HPCVIEWER_VERSION}
if [ "${HPCTOOLKIT_PATH_INPUT}" != "" ]; then
   HPCTOOLKIT_PATH=${HPCTOOLKIT_PATH_INPUT}
fi
if [ "${HPCVIEWER_PATH_INPUT}" != "" ]; then
   HPCVIEWER_PATH=${HPCVIEWER_PATH_INPUT}
fi

# HPCVIEWER_TOP: the versioned top-level install dir we own and that
# every "is hpcviewer there?" / "remove hpcviewer" / "lock down
# hpcviewer perms" question is asked against. It is captured here,
# BEFORE the spack section below reassigns HPCVIEWER_PATH to spack's
# `spack location -i hpcviewer` deep-hash subdir (see line ~410 area)
# for use in the modulefile's PATH prepend. Job 8063 audit: that
# reassignment is what caused the post-install chmod/chown to only
# affect the spack hash subdir and leave the top dir at 777 -- the
# top vs spack-hash distinction is exactly what HPCVIEWER_TOP locks
# in, so every "operate on the install" path uses HPCVIEWER_TOP and
# only the modulefile gets the spack-hash subdir.
HPCVIEWER_TOP="${HPCVIEWER_PATH}"

# ── --replace + EXIT trap (see hypre_setup.sh for design) ────────────
# ── BUILD_HPCTOOLKIT=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_HPCTOOLKIT}" = "0" ]; then
   echo "[hpctoolkit BUILD_HPCTOOLKIT=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

if [ "${REPLACE}" = "1" ]; then
   echo "[hpctoolkit --replace 1] removing prior installs + modulefile if present"
   echo "  hpctoolkit dir: ${HPCTOOLKIT_PATH}"
   echo "  hpcviewer dir:  ${HPCVIEWER_TOP}"
   echo "  modulefile:     ${MODULE_PATH}/${HPCTOOLKIT_VERSION}.lua"
   ${SUDO} rm -rf "${HPCTOOLKIT_PATH}" "${HPCVIEWER_TOP}"
   ${SUDO} rm -f  "${MODULE_PATH}/${HPCTOOLKIT_VERSION}.lua"
fi

# ── Existence guard (see hypre_setup.sh) ─────────────────────────────
# Multi-component: skip ONLY if BOTH hpctoolkit-v${VER} AND hpcviewer-
# v${HPCVIEWER_VERSION} are present. If either is missing the modulefile
# would prereq a path that does not exist, so we proceed to (re)build.
# Checks the versioned top dir HPCVIEWER_TOP (not the spack-hash
# subdir) so a spack-side rename of the leaf hash doesn't false-
# positive this guard; main_setup.sh's old `[[ ! -d hpctoolkit-v${VER}
# ]]` guard knew about the hpctoolkit half only.
NOOP_RC=43
if [ -d "${HPCTOOLKIT_PATH}" ] && [ -d "${HPCVIEWER_TOP}" ]; then
   echo ""
   echo "[hpctoolkit existence-check] both components already installed; skipping."
   echo "  hpctoolkit dir: ${HPCTOOLKIT_PATH}"
   echo "  hpcviewer dir:  ${HPCVIEWER_TOP}"
   echo "  pass --replace 1 to force a clean rebuild of this version."
   echo ""
   exit ${NOOP_RC}
fi

# ── Combined EXIT trap: install fail-cleanup + build-dir cleanup ─────
# Job 8063 audit: previously _hpctoolkit_on_exit (registered here) was
# silently OVERWRITTEN by a second `trap '...' EXIT` in the spack
# section, which cleaned the build-tmpdirs but not the partial
# install dirs/modulefile -- a hpcviewer build failure then left
# /opt/rocmplus-X/{hpctoolkit-v*,hpcviewer-v*} on disk and the next
# sweep's existence-guard above false-positively skipped the rebuild.
# Combined trap below fires once on EXIT and does both: install
# cleanup (gated by KEEP_FAILED_INSTALLS) THEN build-tmpdir cleanup
# (always, whether success or fail). The build-tmpdir vars are not
# yet set at this point, so the trap parameter-expands them lazily
# from the EXIT context (the `:-/nonexistent` defaults make rm a
# no-op when a section never reached its mktemp).
_hpctoolkit_on_exit() {
   local rc=$?
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[hpctoolkit fail-cleanup] rc=${rc}: removing partial hpctoolkit + hpcviewer installs + modulefile"
      ${SUDO:-sudo} rm -rf "${HPCTOOLKIT_PATH}" "${HPCVIEWER_TOP}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/${HPCTOOLKIT_VERSION}.lua"
   elif [ ${rc} -ne 0 ]; then
      echo "[hpctoolkit fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   # Build-tmpdir cleanup (always, regardless of rc): each var is
   # initialized later in the build path; defaulting to /nonexistent
   # makes the rm a no-op for sections that never ran (e.g. cache-
   # restore branch which sets neither).
   ${SUDO:-sudo} rm -rf \
      "${HPCTOOLKIT_BUILD_DIR:-/nonexistent}" \
      "${HPCVIEWER_BUILD_DIR:-/nonexistent}" \
      "${SPACK_USER_CONFIG_PATH:-/nonexistent}" \
      "${SPACK_USER_CACHE_PATH:-/nonexistent}"
   return ${rc}
}
trap _hpctoolkit_on_exit EXIT

echo ""
echo "==================================="
echo "Starting HPCToolkit Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_HPCTOOLKIT: $BUILD_HPCTOOLKIT"
echo "==================================="
echo ""

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

if [ "${BUILD_HPCTOOLKIT}" = "0" ]; then

   echo "HPCToolkit will not be built, according to the specified value of BUILD_HPCTOOLKIT"
   echo "BUILD_HPCTOOLKIT: $BUILD_HPCTOOLKIT"
   exit

else
   if [ -f ${CACHE_FILES}/hpctoolkit-v${HPCTOOLKIT_VERSION}.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached HPCToolkit v${HPCTOOLKIT_VERSION}"
      echo "============================"
      echo ""

      # install the cached version. Tarball top-level dir is
      # hpctoolkit-v${HPCTOOLKIT_VERSION}/ -- matches the versioned
      # HPCTOOLKIT_PATH layout used by the from-source branch.
      # hpcviewer is bundled as a SEPARATE tar (different upstream
      # release cadence than hpctoolkit) and is now versioned to
      # hpcviewer-v${HPCVIEWER_VERSION}.tgz so multiple hpcviewer
      # releases can coexist in the cache and on disk (job 8063
      # audit; the prior unversioned hpcviewer.tgz had a 1:1 mapping
      # to whatever spack picked at cache-bake time, which was opaque
      # to the operator). Pre-existing unversioned hpcviewer.tgz
      # files in the cache are now stale and should be re-baked.
      cd /opt/rocmplus-${ROCM_VERSION}
      ${SUDO} tar -xpzf ${CACHE_FILES}/hpctoolkit-v${HPCTOOLKIT_VERSION}.tgz
      ${SUDO} chown -R root:root ${HPCTOOLKIT_PATH}
      if [ -f ${CACHE_FILES}/hpcviewer-v${HPCVIEWER_VERSION}.tgz ]; then
         ${SUDO} tar -xpzf ${CACHE_FILES}/hpcviewer-v${HPCVIEWER_VERSION}.tgz
         ${SUDO} chown -R root:root ${HPCVIEWER_TOP}
      fi
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm -f ${CACHE_FILES}/hpctoolkit-v${HPCTOOLKIT_VERSION}.tgz
         ${SUDO} rm -f ${CACHE_FILES}/hpcviewer-v${HPCVIEWER_VERSION}.tgz
      fi

   else
      echo ""
      echo "============================"
      echo " Building HPCToolkit"
      echo "============================"
      echo ""

      REQUIRED_MODULES=( "rocm/${ROCM_VERSION}" "openmpi" )
      preflight_modules "${REQUIRED_MODULES[@]}" || exit $?

      # Install-time sudo: canonical PKG_SUDO pattern (job 8063
      # follow-up audit). The previous block here ran an "is the
      # install dir writable?" probe (`if [ -d ... ] / if [ -w ... ]
      # ; then SUDO=""; ...`) that, in the rare case where an
      # operator pre-created both install dirs with their own
      # ownership, would drop SUDO -- otherwise it left the file-
      # top default `SUDO="sudo"` (line ~52) untouched. Same lying-
      # probe failure mode as the netcdf-c modulefile bug from job
      # 8063: a mid-build chown by a sibling block could flip the
      # dir's writability between the probe and the actual mkdir/
      # chmod, leaving the script with the wrong sudo decision.
      # Replaced with the same identity-only PKG_SUDO computation
      # used everywhere else: "no sudo if EUID==0, sudo otherwise".
      # Net behaviour change vs. the prior code:
      #   * EUID==0 (root)              : SUDO=""    (was: SUDO="" if
      #                                    BOTH dirs pre-existed AND
      #                                    were writable, else "sudo".
      #                                    Either way, root never
      #                                    actually needed sudo for
      #                                    these ops.)
      #   * Singularity                 : SUDO=""    (unchanged --
      #                                    set by the file-top
      #                                    Singularity branch, which
      #                                    runs before this point and
      #                                    is left intact.)
      #   * non-root, non-Singularity   : SUDO="sudo" (was: same in
      #                                    the common case; the only
      #                                    operator escape hatch lost
      #                                    is the manual `chmod u+w
      #                                    /opt/...` workflow, which
      #                                    was undocumented and not
      #                                    used by any caller in
      #                                    bare_system/ or extras/.
      #                                    To restore that behaviour,
      #                                    run inside Singularity or
      #                                    as root.)
      # Skips the override inside Singularity (the file-top branch
      # has already set SUDO="" for that case and we don't want to
      # clobber it).
      if [ ! -f /.singularity.d/Singularity ]; then
         SUDO=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
      fi

      # openmpi library being installed as dependency of libboost-all-dev.
      # PKG_SUDO computed identically to SUDO above; kept under its
      # own name as a documentation contract: PKG_SUDO is "this op
      # ALWAYS needs root authority" (apt), SUDO is "this op needs
      # root authority unless we're inside something special". They
      # happen to take the same value on this code path but the
      # callers shouldn't rely on that. See openmpi_setup.sh /
      # audit_2026_05_01.md Issue 2.
      PKG_SUDO=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
      ${PKG_SUDO} ${DEB_FRONTEND} apt-get install -q -y pipx libboost-all-dev liblzma-dev libgtk-3-dev

      # Per-job throwaway build dir for the hpctoolkit clone.
      # Replaces a fixed `cd /tmp; rm -rf /tmp/hpctoolkit` pattern
      # that would race between two concurrent rocm-version jobs on
      # the same compute node. The hpcviewer spack section below
      # creates its own HPCVIEWER_BUILD_DIR (kept separate so the
      # spack clone can be cleaned independently of the hpctoolkit
      # source tree).
      HPCTOOLKIT_BUILD_DIR=$(mktemp -d -t hpctoolkit-build.XXXXXX)
      cd "${HPCTOOLKIT_BUILD_DIR}"

      ${SUDO} mkdir -p ${HPCTOOLKIT_PATH}
      ${SUDO} mkdir -p ${HPCVIEWER_TOP}

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+w ${HPCTOOLKIT_PATH}
         ${SUDO} chmod a+w ${HPCVIEWER_TOP}
      fi

      # ------------ Installing HPCToolkit

      pipx install 'meson>=1.3.2'
      export PATH=$HOME/.local/bin:$PATH
      git clone -b ${HPCTOOLKIT_VERSION} https://gitlab.com/hpctoolkit/hpctoolkit.git
      cd hpctoolkit
      export CMAKE_PREFIX_PATH=$ROCM_PATH:$CMAKE_PREFIX_PATH

      # Force subproject headers to use -I instead of -isystem so they take
      # priority over the system libunwind-dev 1.3.2 headers at /usr/include/
      sed -i "s/include_type: 'system'/include_type: 'non-system'/g" meson.build

      meson setup -Drocm=enabled -Dopencl=disabled --prefix=${HPCTOOLKIT_PATH} --libdir=${HPCTOOLKIT_PATH}/lib build
      cd build
      meson compile || { echo "ERROR: meson compile failed"; exit 1; }
      meson install

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find ${HPCTOOLKIT_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${HPCTOOLKIT_PATH} -type d -execdir chown root:root "{}" +
      fi

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${HPCTOOLKIT_PATH}
      fi

      cd ../..
      rm -rf hpctoolkit

      # ------------ Installing HPCViewer

      # Spack user-scope isolation: see scorep_setup.sh for the full
      # rationale. Per-job throwaway dirs prevent ~/.spack/{packages,
      # config}.yaml from accumulating state across rocm versions and
      # prevent a stale user-scope install_tree.root from over-riding
      # the per-clone defaults edit below.
      SPACK_USER_CONFIG_PATH=$(mktemp -d -t spack-user-config.XXXXXX)
      SPACK_USER_CACHE_PATH=$(mktemp -d -t spack-user-cache.XXXXXX)
      export SPACK_USER_CONFIG_PATH SPACK_USER_CACHE_PATH

      # Spack clone goes under /tmp (compute-node local disk) so
      # concurrent rocm-version builds don't race on ${PWD}/spack in
      # the shared HPCTrainingDock checkout. EXIT cleanup of this
      # build dir is handled by the combined _hpctoolkit_on_exit
      # trap registered above (job 8063 audit: a second `trap '...'
      # EXIT` here used to silently overwrite the install fail-
      # cleanup trap; that pattern is gone now -- both concerns
      # live in _hpctoolkit_on_exit).
      HPCVIEWER_BUILD_DIR=$(mktemp -d -t hpcviewer-build.XXXXXX)
      cd "${HPCVIEWER_BUILD_DIR}"

      git clone --depth 1 https://github.com/spack/spack.git

      # load spack environment
      source spack/share/spack/setup-env.sh

      # find already installed libs for spack
      spack external find --all

      # change spack install dir for hpcviewer
      ${SUDO} sed -i 's|$spack/opt/spack|'"${HPCVIEWER_TOP}"'|g' spack/etc/spack/defaults/base/config.yaml

      # open permissions to use spack to install hpcviewer
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+rwX ${HPCVIEWER_TOP}
      fi

      # install hpcviewer with spack -- pinned to ${HPCVIEWER_VERSION}
      # so the install dir name matches the versioned HPCVIEWER_TOP we
      # advertised above and, more importantly, so the cache tar name
      # (hpcviewer-v${HPCVIEWER_VERSION}.tgz) and the on-disk version
      # always agree across runs. Without the @version pin spack would
      # silently pick "latest" and a cache baked today would mismatch
      # an install rebuilt next quarter.
      spack install hpcviewer@${HPCVIEWER_VERSION}

      # get hpcviewer install dir created by spack -- this is the deep
      # spack-hash subdir (e.g. ${HPCVIEWER_TOP}/linux-zen4/hpcviewer-
      # ${HPCVIEWER_VERSION}-<spackhash>). Reassigning HPCVIEWER_PATH
      # here is INTENTIONAL: only the modulefile's PATH prepend below
      # needs the spack-hash bin/ dir. Every "operate on the install"
      # action (chown, chmod, fail-cleanup, --replace, existence
      # guard) uses HPCVIEWER_TOP so it walks the whole versioned
      # tree, not just the spack-hash subdir (job 8063 audit: prior
      # code used the post-reassignment HPCVIEWER_PATH for the
      # post-install chmod, leaving HPCVIEWER_TOP at 777 root:root).
      HPCVIEWER_PATH=$(spack location -i hpcviewer)

      # HPCVIEWER_BUILD_DIR (under /tmp, contains the spack clone) +
      # the spack user-scope dirs are removed by the combined
      # _hpctoolkit_on_exit trap.

      # Lock down ALL of HPCVIEWER_TOP (top + spack-hash subdir +
      # bin views + .spack-db) -- not just the spack-hash dir as
      # before. Recursive chown + recursive go-w is the only way to
      # undo the `chmod -R a+rwX HPCVIEWER_TOP` we did above to let
      # spack write under it as a non-root user.
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find ${HPCVIEWER_TOP} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${HPCVIEWER_TOP} -type d -execdir chown root:root "{}" +
      fi
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R go-w ${HPCVIEWER_TOP}
      fi

      module unload rocm/${ROCM_VERSION}

   fi

   # Create a module file for hpctoolkit
   #
   # Modulefile-write sudo: canonical PKG_SUDO pattern (job 8063 audit;
   # see netcdf_setup.sh for the lying-probe failure mode this replaces).
   # This is the 11th call site migrated off the old "if [ -d ] / if
   # [ ! -w ] / SUDO=sudo / else / echo / fi" probe pattern; see also
   # the install-side migration earlier in this file (search "Install-
   # time sudo: canonical PKG_SUDO pattern").
   PKG_SUDO_MOD=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
   ${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${HPCTOOLKIT_VERSION}.lua
	whatis("HPCToolkit - integrated suite of tools for measurement and analysis of program performance")

	local base = "${HPCTOOLKIT_PATH}"

	prereq("rocm/${ROCM_VERSION}")
	setenv("HPCTOOLKIT_PATH", base)
	prepend_path("PATH",pathJoin(base, "bin"))
	prepend_path("PATH","${HPCVIEWER_PATH}/bin")
	prepend_path("LD_LIBRARY_PATH",pathJoin(base, "lib"))
	prepend_path("LD_LIBRARY_PATH","/usr/lib")
EOF

fi

