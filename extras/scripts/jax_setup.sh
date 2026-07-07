#!/bin/bash

# Capture this script's absolute path BEFORE any cd, so the inline
# git-provenance block lower down can resolve the script in the repo
# even after the build has cd'd into a temp dir. (BASH_SOURCE[0] is
# whatever path was used to invoke the script -- often relative when
# called from main_setup.sh -- so we absolutize it once, here.)
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

# Variables controlling setup process
ROCM_VERSION=6.2.0
BUILD_JAX=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/jax
AMDGPU_GFXMODEL_INPUT=""
JAX_VERSION=8.0
# Tracked separately so the post-arg-parsing policy block (search
# "JAX policy gate") can tell "user passed --jax-version" from "we
# fell through to the default", and only override the default when
# the user has not asked for a specific version.
JAX_VERSION_USER_SET=0
# Versioned install dirs: /opt/rocmplus-X/jax-v0.${JAX_VERSION},
# /opt/rocmplus-X/jaxlib-v0.${JAX_VERSION}. Modulefile is
# 0.${JAX_VERSION}.lua so the version naming matches across all three.
JAX_PATH=/opt/rocmplus-${ROCM_VERSION}/jax-v0.${JAX_VERSION}
JAX_PATH_INPUT=""
JAXLIB_PATH=/opt/rocmplus-${ROCM_VERSION}/jaxlib-v0.${JAX_VERSION}
JAXLIB_PATH_INPUT=""
# --install-path: parent dir; the script appends both
# jax-v0.${JAX_VERSION} and jaxlib-v0.${JAX_VERSION} itself (after the
# JAX policy gate has finalized JAX_VERSION). Used by main_setup.sh so
# the orchestrator never has to know the version (which is itself ROCm-
# aware here). Per-component --jax-install-path-no-version / --jaxlib-install-path-no-version
# (full leaf dirs) still win when set.
ROCMPLUS_PATH_INPUT=""
PATCHELF_VERSION=0.18.0
# jax is multi-component (jax + jaxlib both written by this script).
# Like openmpi_setup.sh's --replace-xpmem/--replace-ucx pattern:
#   --replace-jax     removes jax + 0.${JAX_VERSION}.lua
#   --replace-jaxlib  removes jaxlib (no separate modulefile of its own;
#                     the jax modulefile prepends both into PYTHONPATH)
# --replace is a convenience alias that flips both on and is what
# main_setup.sh threads through from --replace-existing.
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup. See hypre_setup.sh.
REPLACE=0
REPLACE_JAX=0
REPLACE_JAXLIB=0
KEEP_FAILED_INSTALLS=0

SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
# Compatibility-driven JAX_VERSION / BUILD_JAX selection lives in the
# "JAX policy gate" block AFTER arg parsing (so we have the final
# ROCM_VERSION + a flag indicating whether the user passed
# --jax-version). The earlier per-distro fixup that lived here used
# to force JAX_VERSION=6.0 on Ubuntu 22.04, but 6.0 is not in the
# upstream ROCm/JAX compatibility matrix at all (job 8063 audit) so
# every 22.04 build wedged on the Python-3.10 check; that fixup has
# been removed in favor of the policy gate further down.

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --jax-install-path-no-version, --jaxlib-install-path-no-version, and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "--amdgpu-gfxmodel [ AMDGPU-GFXMODEL ] default autodetected, specify as a comma separated list"
   echo "--build-jax [ BUILD_JAX ] set to 1 to build jax default is 0"
   echo "--jax-version [ JAX_VERSION ] version of JAX, XLA, and JAXLIB, default is $JAX_VERSION"
   echo "--jax-install-path-no-version [ JAX_PATH ] directory where JAX will be installed, default is $JAX_PATH"
   echo "--jaxlib-install-path-no-version [ JAXLIB_PATH ] directory where JAX will be installed, default is $JAXLIB_PATH"
   echo "--install-path [ ROCMPLUS_PATH_INPUT ] parent dir; if set, fills both component install paths from \${ROCMPLUS_PATH}/{jax,jaxlib}-v0.\${JAX_VERSION}"
   echo "--help: this usage information"
   echo "--module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "--rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "--replace [ 0|1 ] convenience: same as --replace-jax 1 --replace-jaxlib 1, default $REPLACE"
   echo "--replace-jax [ 0|1 ] remove prior jax install + modulefile before building, default $REPLACE_JAX"
   echo "--replace-jaxlib [ 0|1 ] remove prior jaxlib install before building, default $REPLACE_JAXLIB"
   echo "--keep-failed-installs [ 0|1 ] skip EXIT-trap cleanup of partial installs on failure, default $KEEP_FAILED_INSTALLS"
   echo "--help: print this usage information"
}

compat_info()
{
   echo " List of compatible versions according to https://github.com/ROCm/jax/releases: "
   echo " JAX version 8.0 --> ROCm version 7.0.0 or higher and Python higher than 3.10 "
   echo " JAX version 7.1 --> ROCm version 7.0.0 or higher and Python higher than 3.10 "
   echo " JAX version 6.0 --> ROCm version 7.0.0 or higher and Python 3.10 supported (transition release) "
   echo " JAX version 5.0 --> ROCm versions 6.0.3, 6.2.4 and 6.3.1 "
   echo " JAX version 4.35 --> ROCm versions 6.0.3, 6.1.3 and 6.2.4 "
   echo " JAX version 4.34 --> ROCm versions 6.0.3, 6.1.3 and 6.2.3 "
   echo " JAX version 4.33 --> ROCm versions 6.0.3, 6.1.3 and 6.2.3 "
   echo " JAX version 4.31 --> ROCm versions 6.0.3, 6.1.3 and 6.2.3 "
   echo " JAX version 4.30 --> ROCm versions 6.1.1, 6.0.2 "
   echo " ... see https://github.com/ROCm/jax/releases for full list ... "
   echo " NOTE: ROCm versions not listed in the compatibility matrix might still work! "
   echo " For instance, ROCm 6.4.0 can be selected in this script with JAX version 5.0 and 4.35 "
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
          AMDGPU_GFXMODEL_INPUT=${1}
	  reset-last
          ;;
      "--build-jax")
          shift
          BUILD_JAX=${1}
	  reset-last
          ;;
      "--jax-version")
          shift
          JAX_VERSION=${1}
          JAX_VERSION_USER_SET=1
	  reset-last
          ;;
      "--jax-install-path-no-version")
          shift
          JAX_PATH_INPUT=${1}
	  reset-last
          ;;
      "--jaxlib-install-path-no-version")
          shift
          JAXLIB_PATH_INPUT=${1}
	  reset-last
          ;;
      "--install-path")
          shift
          ROCMPLUS_PATH_INPUT=${1}
	  reset-last
          ;;
      "--help")
          usage
          compat_info
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
      "--replace-jax")
          shift
          REPLACE_JAX=${1}
          reset-last
          ;;
      "--replace-jaxlib")
          shift
          REPLACE_JAXLIB=${1}
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

# 1 = policy gate below blocked a requested build (for jax.SKIPPED / inventory 'N').
JAX_POLICY_SKIP=0

# ── JAX policy gate ──────────────────────────────────────────────────
# Compatibility table (per upstream ROCm/JAX release notes, also
# echoed by compat_info() further down):
#   JAX 8.0  -- ROCm >= 7.0,  Python > 3.10 (i.e. 3.11+)
#   JAX 7.1  -- ROCm >= 7.0,  Python > 3.10
#   JAX 6.0  -- ROCm >= 7.0,  Python 3.10 wheels ship (cp310, jax_rocm7_*
#                              plugin) -- the transition release that
#                              bridges the ROCm 7 ABI to Python 3.10.
#   JAX 5.0  -- ROCm 6.0.3 / 6.2.4 / 6.3.1, Python 3.10 supported
#   (older JAX lines drop further into the 6.x series.)
#
# Two facts force the policy here:
#   1. Ubuntu 22.04 ships Python 3.10 as system python; this driver
#      auto-detects PYTHON_VERSION=3.10 (bare_system/main_setup.sh).
#      JAX 7.1 / 8.0 drop Python 3.10 support, so the default 8.0
#      cannot be used on 22.04. (Job 8063: 9 s bail at the "Python
#      3.10 is not supported from JAX 7.1" check.) JAX 6.0 IS still
#      buildable on ROCm 7.x + Python 3.10 -- it ships cp310 wheels
#      and the jax_rocm7_* plugin -- so we downshift to it instead
#      of skipping entirely (as the prior policy did).
#   2. JAX 6.0 requires ROCm 7.x; on ROCm 6.x JAX 5.0 is still the
#      newest line that supports Python 3.10.
#
# Resulting policy (applied AFTER arg parsing so user CLI overrides
# can defeat it deliberately):
#   * ROCm major >= 7  AND  Ubuntu 22.04  AND  user did NOT pass
#     --jax-version  ->  default JAX_VERSION to 6.0 (the transition
#       release that supports both ROCm 7 ABI and Python 3.10).
#   * ROCm major == 6  AND  user did NOT pass --jax-version  ->
#       default JAX_VERSION to 5.0 (the newest line that supports
#       both ROCm 6.x and Python 3.10).
#
# Operator escape hatches:
#   * To force-attempt JAX 7.1/8.0 on Ubuntu 22.04 anyway, pass
#     --jax-version 8.0 (or 7.1). JAX_VERSION_USER_SET will keep
#     that override intact; the inner Python-3.10 gate inside the
#     7.1/8.0 build branch will then fail fast via compat_info()
#     so the failure is cheap and legible instead of opaque.
#   * To use a non-5.0 JAX line on ROCm 6.x, pass --jax-version X.Y
#     and JAX_VERSION_USER_SET will keep that override intact.
# ── Ensure a JAX-capable Python, preferring Cray-python ──────────────
# The JAX_VERSION policy below is keyed on the *effective* Python
# version (MAJOR.MINOR of the python3 that will actually drive
# build/build.py and the final pip install), NOT on the distro. The
# old gate keyed on Ubuntu 22.04 and silently mis-fired on RHEL9/Cray,
# where the system python is 3.9 -- too old for ANY ROCm-7 JAX line and
# the direct cause of the job-8354 failure ("Specified python version:
# 3.9 ... available: 3.11, 3.12, 3.13, 3.14").
#
# Preferred remedy on a Cray: load a cray-python module that provides
# Python >= 3.11 (e.g. cray-python/3.11.7, cray-python/3.12.12). That
# lets us keep the newest JAX line (8.0). We only do this when the
# current python3 is < 3.11 so we never perturb an already-adequate
# interpreter. If no such module exists (non-Cray host), we fall
# through to selecting an older JAX line that matches the python we
# have (see policy gate below).
_jax_pymajor() { python3 -c 'import sys; print(sys.version_info.major)' 2>/dev/null || echo 0; }
_jax_pyminor() { python3 -c 'import sys; print(sys.version_info.minor)' 2>/dev/null || echo 0; }
PYMAJOR=$(_jax_pymajor); PYMINOR=$(_jax_pyminor)
echo "jax: system python3 is ${PYMAJOR}.${PYMINOR} ($(command -v python3 2>/dev/null))"
if { [ "${PYMAJOR}" -lt 3 ] || { [ "${PYMAJOR}" -eq 3 ] && [ "${PYMINOR}" -lt 11 ]; }; } 2>/dev/null; then
   echo "jax: python3 < 3.11; looking for a cray-python >= 3.11 module ..."
   # Pick the newest cray-python whose version is >= 3.11.
   # Split on any whitespace so this works with both terse (`-t`, one
   # module per line) and verbose (`cray-python/3.11.7  cray-python/...`)
   # `module avail` output, on Lmod or environment-modules.
   _cray_py_mod=$(module -t avail cray-python 2>&1 \
                    | tr '[:space:]' '\n' | sed 's/(default)//' \
                    | grep -E '^cray-python/3\.(1[1-9]|[2-9][0-9])(\.|$)' \
                    | sort -V | tail -1)
   if [ -n "${_cray_py_mod}" ]; then
      echo "jax: loading ${_cray_py_mod} to satisfy the JAX >= 3.11 Python requirement"
      module load "${_cray_py_mod}" 2>&1 || echo "jax: WARNING: 'module load ${_cray_py_mod}' failed"
      PYMAJOR=$(_jax_pymajor); PYMINOR=$(_jax_pyminor)
      echo "jax: python3 is now ${PYMAJOR}.${PYMINOR} ($(command -v python3 2>/dev/null))"
   else
      echo "jax: no cray-python >= 3.11 module available; will select an older JAX line if the python allows it."
   fi
fi
unset -f _jax_pymajor _jax_pyminor

# ── JAX_VERSION policy gate (python-version-keyed) ───────────────────
# Only applies when the operator did NOT pass --jax-version (that
# override always wins; see JAX_VERSION_USER_SET). Compatibility:
#   python >= 3.11  ->  keep default JAX 8.0 (ROCm 7+)
#   python == 3.10  ->  JAX 6.0 (transition line, cp310 wheels)  (ROCm 7+)
#   python <  3.10  ->  no ROCm-7 JAX line supports it; mark not-buildable
#   ROCm 6.x        ->  JAX 5.0 (newest line for ROCm 6.x + py3.10)
ROCM_MAJOR=${ROCM_VERSION%%.*}
if [ "${JAX_VERSION_USER_SET}" = "0" ]; then
   if [ "${ROCM_MAJOR}" -ge 7 ] 2>/dev/null; then
      if [ "${PYMAJOR}" -eq 3 ] && [ "${PYMINOR}" -ge 11 ] 2>/dev/null; then
         echo "[jax policy] python ${PYMAJOR}.${PYMINOR} (>= 3.11) on ROCm ${ROCM_VERSION}: keeping JAX ${JAX_VERSION}."
      elif [ "${PYMAJOR}" -eq 3 ] && [ "${PYMINOR}" -eq 10 ] 2>/dev/null; then
         echo "[jax policy] python 3.10 on ROCm ${ROCM_VERSION}: JAX 7.1/8.0 dropped 3.10;"
         echo "             defaulting JAX_VERSION to 6.0 (transition release, cp310 wheels)."
         echo "             Override with --jax-version X.Y for a different line."
         JAX_VERSION=6.0
      else
         echo "[jax policy] python ${PYMAJOR}.${PYMINOR} is too old for any ROCm-7 JAX line"
         echo "             (JAX 6.0 needs 3.10, JAX 7.1/8.0 need >= 3.11) and no cray-python"
         echo "             >= 3.11 module was found: marking jax NOT buildable on this stack."
         echo "             Fixes: load/install Python >= 3.11 (cray-python) or use ROCm 6.x."
         JAX_POLICY_SKIP=1
         BUILD_JAX=0
      fi
   elif [ "${ROCM_MAJOR}" = "6" ]; then
      echo "[jax policy] ROCm ${ROCM_VERSION} (6.x): defaulting JAX_VERSION to 5.0"
      echo "             (the newest line that supports both ROCm 6.x and Python 3.10)."
      echo "             Override with --jax-version X.Y if you want a different line."
      JAX_VERSION=5.0
   fi
fi
unset ROCM_MAJOR

if [ "${JAX_PATH_INPUT}" != "" ]; then
   JAX_PATH=${JAX_PATH_INPUT}
elif [ "${ROCMPLUS_PATH_INPUT}" != "" ]; then
   # Orchestrator-friendly: caller passes the rocmplus parent dir;
   # this script appends jax-v0.${JAX_VERSION} from the (now
   # policy-gate-resolved) JAX_VERSION.
   JAX_PATH=${ROCMPLUS_PATH_INPUT}/jax-v0.${JAX_VERSION}
else
   # override jax path in case ROCM_VERSION or JAX_VERSION has been supplied as input
   JAX_PATH=/opt/rocmplus-${ROCM_VERSION}/jax-v0.${JAX_VERSION}
fi

if [ "${JAXLIB_PATH_INPUT}" != "" ]; then
   JAXLIB_PATH=${JAXLIB_PATH_INPUT}
elif [ "${ROCMPLUS_PATH_INPUT}" != "" ]; then
   # Same as JAX_PATH above but for the jaxlib companion.
   JAXLIB_PATH=${ROCMPLUS_PATH_INPUT}/jaxlib-v0.${JAX_VERSION}
else
   # override jaxlib path in case ROCM_VERSION or JAX_VERSION has been supplied as input
   JAXLIB_PATH=/opt/rocmplus-${ROCM_VERSION}/jaxlib-v0.${JAX_VERSION}
fi

# Sibling markers for bare_system/inventory_packages.py ('N' = not buildable on
# this stack), mirroring pytorch.SKIPPED / ftorch.SKIPPED.
_jax_write_policy_skip_markers() {
   local _root _line
   _root="$(dirname "${JAX_PATH}")"
   ${SUDO} mkdir -p "${_root}" 2>/dev/null || true
   if [ ! -d "${_root}" ]; then
      echo "jax: could not create skip-marker dir ${_root}" >&2
      return 0
   fi
   _line="ROCm ${ROCM_VERSION} on Ubuntu ${DISTRO_VERSION}: JAX lines for ROCm 7+ need Python 3.11+; this stack uses Python 3.10. Not buildable without upgrading Python or using ROCm 6.x with JAX 5.0."
   for _pkg in jax jaxlib; do
      ${SUDO} tee "${_root}/${_pkg}.SKIPPED" >/dev/null 2>/dev/null <<MARKER_EOF || true
SKIPPED package: ${_pkg} (jax driver also governs jaxlib)
ROCm version:    ${ROCM_VERSION}
Distro:          ${DISTRO} ${DISTRO_VERSION}
JAX line:        ${JAX_VERSION} (see jax_setup.sh policy gate)
Date:            $(date -u +%Y-%m-%dT%H:%M:%SZ)
Setup script:    jax_setup.sh (ROCm 7+ vs Python 3.10 policy)
Reason:          ${_line}
MARKER_EOF
   done
   unset _pkg _line
}

# ── --replace + EXIT trap (see hypre_setup.sh for design) ────────────
# Modulefile name is 0.${JAX_VERSION}.lua to match the
# `tee ${MODULE_PATH}/0.${JAX_VERSION}.lua` write below.
# ── BUILD_JAX=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_JAX}" = "0" ]; then
   if [ "${JAX_POLICY_SKIP}" = "1" ]; then
      _jax_write_policy_skip_markers
      echo "[jax BUILD_JAX=0] policy skip: ROCm 7+ on Ubuntu 22.04 requires Python 3.11+ for JAX; wrote jax.SKIPPED + jaxlib.SKIPPED under $(dirname "${JAX_PATH}")."
   else
      echo "[jax BUILD_JAX=0] operator opt-out; skipping (no jax build, no jaxlib build, no cache restore)."
   fi
   exit ${NOOP_RC}
fi

if [ "${REPLACE}" = "1" ]; then
   REPLACE_JAX=1
   REPLACE_JAXLIB=1
fi
_root_mark="$(dirname "${JAX_PATH}")"
if [ "${REPLACE}" = "1" ] || [ "${REPLACE_JAX}" = "1" ] || [ "${REPLACE_JAXLIB}" = "1" ]; then
   ${SUDO} rm -f "${_root_mark}/jax.SKIPPED" "${_root_mark}/jaxlib.SKIPPED"
fi
unset _root_mark
if [ "${REPLACE_JAX}" = "1" ]; then
   echo "[jax --replace-jax 1] removing prior jax install + modulefile if present"
   echo "  install dir: ${JAX_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/0.${JAX_VERSION}.lua"
   ${SUDO} rm -rf "${JAX_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/0.${JAX_VERSION}.lua"
fi
if [ "${REPLACE_JAXLIB}" = "1" ]; then
   echo "[jax --replace-jaxlib 1] removing prior jaxlib install"
   echo "  install dir: ${JAXLIB_PATH}"
   ${SUDO} rm -rf "${JAXLIB_PATH}"
fi

# ── Existence guard (see hypre_setup.sh) ─────────────────────────────
# Multi-component: skip ONLY if BOTH jax-v0.${VER} AND jaxlib-v0.${VER}
# are present. Either alone is non-functional (jax python imports
# jaxlib at runtime).
NOOP_RC=43
if [ -d "${JAX_PATH}" ] && [ -d "${JAXLIB_PATH}" ]; then
   echo ""
   echo "[jax existence-check] both components already installed; skipping."
   echo "  jax:    ${JAX_PATH}"
   echo "  jaxlib: ${JAXLIB_PATH}"
   echo "  pass --replace 1 (or --replace-jax/--replace-jaxlib) to rebuild."
   echo ""
   exit ${NOOP_RC}
fi

# Consolidated EXIT trap: build-dir cleanup (JAX_BUILD_ROOT, set later
# under BUILD_JAX=1) PLUS fail-cleanup of jax + jaxlib installs +
# modulefile. Replaces inline `trap '... rm JAX_BUILD_ROOT ...' EXIT`.
_jax_on_exit() {
   local rc=$?
   [ -n "${JAX_BUILD_ROOT:-}" ] && ${SUDO:-sudo} rm -rf "${JAX_BUILD_ROOT}"
   # attempted-but-failed markers (inventory 'F' glyph): persistent siblings
   # of the install dirs that survive the rm -rf below; cleared on success.
   # Inventory tracks 'jax' and 'jaxlib' as separate rows, so drop one
   # marker each (this script builds the pair together).
   _jax_fail_marker="$(dirname "${JAX_PATH}")/jax.FAILED"
   _jaxlib_fail_marker="$(dirname "${JAXLIB_PATH}")/jaxlib.FAILED"
   if [ ${rc} -ne 0 ]; then
      ${SUDO:-sudo} mkdir -p "$(dirname "${JAX_PATH}")" 2>/dev/null || true
      ${SUDO:-sudo} tee "${_jax_fail_marker}" >/dev/null 2>/dev/null <<MARKER_EOF || true
FAILED package: jax
ROCm SDK:        ${ROCM_PATH:-unknown}
ROCm token:      ${ROCM_VERSION:-unknown}
Date:            $(date -u +%Y-%m-%dT%H:%M:%SZ)
Setup script:    jax_setup.sh (EXIT-trap fail marker)
Reason:          build exited rc=${rc}; partial install wiped (see log_jax_*.txt).
MARKER_EOF
      ${SUDO:-sudo} mkdir -p "$(dirname "${JAXLIB_PATH}")" 2>/dev/null || true
      ${SUDO:-sudo} tee "${_jaxlib_fail_marker}" >/dev/null 2>/dev/null <<MARKER_EOF || true
FAILED package: jaxlib
ROCm SDK:        ${ROCM_PATH:-unknown}
ROCm token:      ${ROCM_VERSION:-unknown}
Date:            $(date -u +%Y-%m-%dT%H:%M:%SZ)
Setup script:    jax_setup.sh (EXIT-trap fail marker)
Reason:          build exited rc=${rc}; partial install wiped (see log_jax_*.txt).
MARKER_EOF
   else
      ${SUDO:-sudo} rm -f "${_jax_fail_marker}" "${_jaxlib_fail_marker}"
   fi
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[jax fail-cleanup] rc=${rc}: removing partial jax + jaxlib installs + modulefile"
      ${SUDO:-sudo} rm -rf "${JAX_PATH}" "${JAXLIB_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/0.${JAX_VERSION}.lua"
   elif [ ${rc} -ne 0 ]; then
      echo "[jax fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _jax_on_exit EXIT

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

# Load the ROCm version for this JAX build
#source /etc/profile.d/lmod.sh
#source /etc/profile.d/z00_lmod.sh
module load ${ROCM_MODULE_NAME}

if [[ "$AMDGPU_GFXMODEL_INPUT" != "" ]]; then
   AMDGPU_GFXMODEL=$AMDGPU_GFXMODEL_INPUT
else
   # Stderr-silenced + `|| true`: rocminfo can fail when the SDK is built
   # against a newer glibc than the host (ROCm 7.2.3 binaries need
   # GLIBC_2.38; jammy has 2.35) and under pipefail would kill the script.
   AMDGPU_GFXMODEL=$(rocminfo 2>/dev/null | grep gfx | sed -e 's/Name://' | head -1 | sed 's/ //g' || true)
fi

echo ""
echo "====================================="
echo " Installing JAXLIB and JAX"
echo " JAX Install directory: $JAX_PATH"
echo " JAXLIB Install directory: $JAXLIB_PATH"
echo " JAX Module directory: $MODULE_PATH"
echo " ROCm Version: $ROCM_VERSION"
echo "====================================="
echo ""

if [ "${BUILD_JAX}" = "0" ]; then

   echo "JAX will not be built, according to the specified value of BUILD_JAX"
   echo "BUILD_JAX: $BUILD_JAX"
   exit

else
   # Per-job throwaway build dir; replaces a fixed `cd /tmp` (and the
   # later `rm -rf /tmp/{jax,rocm-jax,xla}` cleanup) that would race
   # with -- and clobber -- any other concurrent jax build on the
   # same node (different ROCm versions, sweeps, etc.).
   JAX_BUILD_ROOT=$(mktemp -d -t jax-build.XXXXXX)
   # NOTE: build-dir cleanup is consolidated into _jax_on_exit
   # installed above (so the same EXIT handler also does fail-cleanup
   # of jax + jaxlib installs and the modulefile).
   cd "${JAX_BUILD_ROOT}"

   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
   if [ -f "${CACHE_FILES}/jax-v0.${JAX_VERSION}.tgz" ] && [ -f "${CACHE_FILES}/jaxlib-v0.${JAX_VERSION}.tgz" ]; then
      echo ""
      echo "==================================="
      echo " Installing Cached JAXLIB and JAX v0.${JAX_VERSION}"
      echo "==================================="
      echo ""

      # Install the cached version. Tarball top-level dirs are
      # jax-v0.${JAX_VERSION}/ and jaxlib-v0.${JAX_VERSION}/ -- match the
      # versioned JAX_PATH / JAXLIB_PATH layout the from-source branch
      # writes to, so multiple jax releases coexist on disk.
      cd /opt/rocmplus-${ROCM_VERSION}

      ${SUDO} tar -xzpf ${CACHE_FILES}/jax-v0.${JAX_VERSION}.tgz
      ${SUDO} chown -R root:root ${JAX_PATH}

      ${SUDO} tar -xzpf ${CACHE_FILES}/jaxlib-v0.${JAX_VERSION}.tgz
      ${SUDO} chown -R root:root ${JAXLIB_PATH}

      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm  ${CACHE_FILES}/jax-v0.${JAX_VERSION}.tgz ${CACHE_FILES}/jaxlib-v0.${JAX_VERSION}.tgz
      fi
   else
      echo ""
      echo "======================================="
      echo " Installing JAXLIB and JAX from source"
      echo "======================================="
      echo ""

      # don't use sudo if user has write access to both install paths
      if [ -d "$JAX_PATH" ]; then
         if [ -d "$JAXLIB_PATH" ]; then
            # don't use sudo if user has write access to both install paths
            if [ -w ${JAX_PATH} ]; then
               if [ -w ${JAXLIB_PATH} ]; then
               SUDO=""
               else
                  echo "WARNING: using install paths that require sudo"
               fi
            fi
         fi
      else
         # if install paths do not both exist yet
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      ROCM_VERSION_BAZEL=`echo "$ROCM_VERSION" | sed 's/therock-//' | awk -F. '{print $1}'`
      if [[ "${ROCM_VERSION_BAZEL}" == "6" ]]; then
         ROCM_VERSION_BAZEL="${ROCM_VERSION_BAZEL}0"
      fi

      # PKG_SUDO: apt needs root regardless of the install-path-derived
      # SUDO. The original `if [[ ${SUDO} != "" ]]` guard conflated
      # "install path needs sudo to write" with "I have sudo authority
      # for apt", which broke any build to an admin-writable install
      # path. We change the guard to a sudo-availability check
      # (root or passwordless sudo); the no-sudo branch -- the
      # ~/bin/python symlink workaround -- is preserved for
      # environments that genuinely lack sudo. See openmpi_setup.sh /
      # audit_2026_05_01.md Issue 2.
      PKG_SUDO=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
      if [[ `which python | wc -l` -eq 0 ]]; then
         if [ "${EUID:-$(id -u)}" -eq 0 ] || sudo -n true 2>/dev/null; then
            echo "============================"
   	    echo "WARNING: python needs to be linked to python3 for the build to work"
	    echo ".....Installing python-is-python3 with sudo......"
            echo "============================"
    	    ${PKG_SUDO} apt-get update
            ${PKG_SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -y python-is-python3
         else
            ln -s $(which python3) ~/bin/python
            export PATH="$HOME/bin:$PATH"
            source $HOME/.bashrc
         fi
      fi

      source /etc/profile.d/lmod.sh
      # /etc/profile.d/z01_lmod.sh removal (job 8063 audit): the file
      # is part of an older Lmod packaging that does not exist on this
      # distro (Ubuntu 22.04 + the system Lmod we use). Sourcing it
      # produced a spurious "No such file or directory" line in every
      # jax_setup.sh run; the real lmod.sh above is sufficient to
      # bring `module` into scope. Restore only if a future Lmod
      # repackaging actually ships z01_lmod.sh.
      module load ${ROCM_MODULE_NAME}

      # ---------------------------------------------------------------------
      # Bazel performance tuning applied to every `python3 build/build.py`
      # invocation below (audit_2026_05_01.md, bazel-perf inventory items B
      # + C). Each --bazel_options / --bazel_startup_options pair below
      # accumulates -- Bazel allows --host_jvm_args to be repeated.
      #
      # JVM startup args (sized for the long "Computing main repo mapping"
      # / "Loading" / "Analyzing" phases that hold up jaxlib for ~20-30 min
      # on a cold workspace):
      #   -Xmx16g            : the previous values of -Xmx512m / -Xmx4g
      #                         force constant GC during JAX's external-
      #                         repo resolution (jax + xla + ~400
      #                         transitive). 16g eliminates GC pressure.
      #   -XX:+UseG1GC       : reduces resolve-phase pause clusters.
      #   -XX:+AlwaysPreTouch: pre-faults the heap so the resolution loop
      #                         doesn't stall on lazy page faults.
      #
      # Build flag:
      #   --noexperimental_check_external_repository_files :
      #     skip per-build re-stat of the freshly-extracted external repos
      #     (they were just unpacked into the per-job mktemp workspace --
      #     no opportunity for drift between extraction and analysis).
      # ---------------------------------------------------------------------

      export JAX_PLATFORMS="rocm,cpu"

      # Bazel output_base off NFS, per-job. By default bazel writes its
      # server state and external/ tree under ${HOME}/.cache/bazel which
      # on this cluster is NFS (/home/admin), producing the warning
      #   WARNING: Output base '/home/admin/.cache/bazel/_bazel_admin/...'
      #     is on NFS. This may lead to surprising failures and undetermined
      #     behavior.
      # observed in the tensorflow run of job 7974 and equally applicable
      # to jax (same bazel server, different workspace). Putting it under
      # the per-job mktemp ${JAX_BUILD_ROOT} keeps each build independent
      # AND off NFS. Cleaned up by the EXIT trap on JAX_BUILD_ROOT.
      # Used below in every `python3 build/build.py` invocation as
      #   --bazel_startup_options=--output_base="${BAZEL_OUTPUT_BASE}"
      BAZEL_OUTPUT_BASE="${JAX_BUILD_ROOT}/bazel-output"
      mkdir -p "${BAZEL_OUTPUT_BASE}"
      echo "jax: bazel --output_base=${BAZEL_OUTPUT_BASE} (off NFS, per-job)"

      # Pin HERMETIC_PYTHON_VERSION to the system python3's MAJOR.MINOR.
      # JAX's hermetic_python rule defaults to a hardcoded version that
      # may not match the python3 used to drive build/build.py and the
      # final pip3 install --target=${JAX_PATH} step, leading to silent
      # ABI / extension-module mismatches. Same pattern as
      # tensorflow_setup.sh.
      HERMETIC_PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
      export HERMETIC_PYTHON_VERSION
      echo "jax: HERMETIC_PYTHON_VERSION=${HERMETIC_PYTHON_VERSION}"

      # ── Keep ROCm's include dirs off the vendored-LLVM compiles ───────
      # The rocm modulefile does `prepend-path CPATH $ROCM_PATH/include`
      # (and the Cray build adds $ROCM_PATH/mpich-wrappers/include).
      # Bazel's autoconfigured C++ toolchain bakes CPATH into EVERY
      # compile action as explicit -I flags -- including the compiles of
      # jax's *vendored* @llvm-project (e.g. mlir:CAPIIR) -- even though
      # each action runs under `env -`. On ROCm 7.13.0 the packaged
      # $ROCM_PATH/include/mlir-c/Dialect/Func.h #includes a generated
      # companion (mlir/Dialect/Func/Transforms/Passes.capi.h.inc) that
      # ROCm ships only under $ROCM_PATH/lib/llvm/include, so that stray
      # -I$ROCM_PATH/include makes clang pick up the system mlir-c header
      # whose .inc companion is absent from that prefix -> "file not
      # found" and jaxlib_wheel fails to build (job 8406, ROCm 7.13.0).
      # jax/xla receive their ROCm headers through --rocm_path, not
      # CPATH, so scrub the ROCm entries out of the *_INCLUDE_PATH vars
      # before invoking bazel. Call this immediately before each
      # `python3 build/build.py` (after any `module load amdclang`, which
      # can re-prepend CPATH).
      _jax_strip_rocm_cpath() {
         local _var _out _dir _p _OLD_IFS
         for _var in CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH; do
            _p="${!_var:-}"
            [ -z "${_p}" ] && continue
            _out=""
            _OLD_IFS="${IFS}"; IFS=":"
            for _dir in ${_p}; do
               case "${_dir}" in
                  "${ROCM_PATH}"/include|"${ROCM_PATH}"/mpich-wrappers/include) ;;
                  *) _out="${_out:+${_out}:}${_dir}" ;;
               esac
            done
            IFS="${_OLD_IFS}"
            export "${_var}=${_out}"
         done
         echo "jax: sanitized include env for bazel (dropped \$ROCM_PATH include dirs): CPATH='${CPATH:-}'"
      }

      AMDGPU_GFXMODEL=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/,/g'`

      git clone --depth 1 --branch rocm-jaxlib-v0.${JAX_VERSION} https://github.com/ROCm/xla.git
      cd xla
      export XLA_PATH=$PWD
      cd ..
      git clone --depth 1 --branch rocm-jaxlib-v0.${JAX_VERSION} https://github.com/ROCm/jax.git
      cd jax
      sed -i "s|gfx900,gfx906,gfx908,gfx90a,gfx940,gfx941,gfx942,gfx1030,gfx1100,gfx1200,gfx1201|$AMDGPU_GFXMODEL|g" .bazelrc
      sed -i "s|gfx906,gfx908,gfx90a,gfx942,gfx1030,gfx1100,gfx1101,gfx1200,gfx1201|$AMDGPU_GFXMODEL|g" .bazelrc

      # install necessary packages in installation directory
      ${SUDO} mkdir -p ${JAXLIB_PATH}
      ${SUDO} mkdir -p ${JAX_PATH}
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+w ${JAX_PATH}
         ${SUDO} chmod a+w ${JAXLIB_PATH}
      fi

      # this here is to take into account that the ROCm/jax repo has been deprecated
      # after the release of ROCm 7.1.0 and now it is all located at ROCm/rocm-jax
      if [[ $JAX_VERSION == "7.1" || $JAX_VERSION == "8.0" ]]; then
         result=`echo ${ROCM_VERSION} | awk '$1>7.0'` && echo $result
         # check if ROCm version is greater than or equal to 7.0
         if [[ "${result}" ]]; then

            PYTHON_VERSION=$(python3 -V 2>&1 | awk '{print $2}')
            if [[ "$PYTHON_VERSION" == 3.10.* ]]; then
               echo "Python 3.10 is not supported from JAX 7.1 : https://docs.jax.dev/en/latest/deprecation.html"
               compat_info
            fi

            # we are building jaxlib with the ROCm/jax repo
            PATCHELF_PATH=${JAX_PATH}/patchelf
            ${SUDO} mkdir -p ${PATCHELF_PATH}
            git clone -b ${PATCHELF_VERSION} https://github.com/NixOS/patchelf.git
            cd patchelf
            ./bootstrap.sh
            ./configure --prefix=$PATCHELF_PATH
            make -j
            ${SUDO} make install
            export PATH=$PATH:$PATCHELF_PATH/bin
            cd ../
            rm -rf patchelf
            module load amdclang
            export CLANG_COMPILER=`which clang`
            sed -i "s|/usr/lib/llvm-18/bin/clang|$CLANG_COMPILER|g" .bazelrc
            _jax_strip_rocm_cpath
            python3 build/build.py build --rocm_path=$ROCM_PATH \
                                         --bazel_options=--override_repository=xla=$XLA_PATH \
                                         --rocm_amdgpu_targets=$AMDGPU_GFXMODEL \
                                         --clang_path=$ROCM_PATH/llvm/bin/clang \
                                         --rocm_version=$ROCM_VERSION_BAZEL \
                                         --use_clang=true \
                                         --wheels=jaxlib \
                                         --bazel_options=--jobs=128 \
                                         --bazel_options=--noexperimental_check_external_repository_files \
                                         --bazel_startup_options=--output_base="${BAZEL_OUTPUT_BASE}" \
                                         --bazel_startup_options=--host_jvm_args=-Xmx16g \
                                         --bazel_startup_options=--host_jvm_args=-XX:+UseG1GC \
                                         --bazel_startup_options=--host_jvm_args=-XX:+AlwaysPreTouch

	    # install the wheel for jaxlib
            pip3 install -v --target=${JAXLIB_PATH} dist/jax*.whl --force-reinstall
            # next we need to install the jax python module
            pip3 install --no-deps --target=${JAX_PATH} .
            pip3 install --no-deps --target=${JAX_PATH} opt-einsum

            cd ..
	    # then we are using the ROCm/rocm-jax repo to build the other wheels
   	    git clone  --depth 1 --branch rocm-jax-v0.${JAX_VERSION} https://github.com/ROCm/rocm-jax.git
	    cd rocm-jax/jax_rocm_plugin
            sed -i "s|/usr/lib/llvm-18/bin/clang|$CLANG_COMPILER|g" .bazelrc
            sed -i "s|gfx906,gfx908,gfx90a,gfx942,gfx1030,gfx1100,gfx1101,gfx1200,gfx1201|$AMDGPU_GFXMODEL|g" .bazelrc
	    _jax_strip_rocm_cpath
	    python3 build/build.py build --rocm_path=$ROCM_PATH \
                                         --bazel_options=--override_repository=xla=$XLA_PATH \
                                         --rocm_amdgpu_targets=$AMDGPU_GFXMODEL \
                                         --clang_path=$ROCM_PATH/llvm/bin/clang \
                                         --rocm_version=$ROCM_VERSION_BAZEL \
                                         --use_clang=true \
                                         --wheels=jax-rocm-plugin,jax-rocm-pjrt \
                                         --bazel_options=--jobs=128 \
                                         --bazel_options=--noexperimental_check_external_repository_files \
                                         --bazel_startup_options=--output_base="${BAZEL_OUTPUT_BASE}" \
                                         --bazel_startup_options=--host_jvm_args=-Xmx16g \
                                         --bazel_startup_options=--host_jvm_args=-XX:+UseG1GC \
                                         --bazel_startup_options=--host_jvm_args=-XX:+AlwaysPreTouch
            # next we need to install the wheels that we built
            pip3 install -v --target=${JAXLIB_PATH} dist/jax*.whl --force-reinstall

         else
	    echo "For JAX version 7.1 you need at least ROCm 7.0.0"
            compat_info	    
         fi		 
      else 	      
         result=`echo ${ROCM_VERSION} | awk '$1>6.3.9'` && echo $result
         # check if ROCm version is greater than or equal to 6.4.0
         if [[ "${result}" ]]; then
            if [[ $JAX_VERSION == "4.35" ]]; then
               sed -i '$a build:rocm --copt=-Wno-error=c23-extensions' .bazelrc
               module load amdclang
               export CLANG_COMPILER=`which clang`
               sed -i "s|/usr/lib/llvm-18/bin/clang|$CLANG_COMPILER|g" .bazelrc
               # build the wheel for jaxlib using clang (which is the default)
               _jax_strip_rocm_cpath
               python3 build/build.py --enable_rocm --rocm_path=$ROCM_PATH \
                                      --bazel_options=--override_repository=xla=$XLA_PATH \
                                      --rocm_amdgpu_targets=$AMDGPU_GFXMODEL \
                                      --build_gpu_plugin --gpu_plugin_rocm_version=$ROCM_VERSION_BAZEL --build_gpu_kernel_plugin=rocm \
                                      --bazel_options=--jobs=128 \
                                      --bazel_options=--noexperimental_check_external_repository_files \
                                      --bazel_startup_options=--output_base="${BAZEL_OUTPUT_BASE}" \
                                      --bazel_startup_options=--host_jvm_args=-Xmx16g \
                                      --bazel_startup_options=--host_jvm_args=-XX:+UseG1GC \
                                      --bazel_startup_options=--host_jvm_args=-XX:+AlwaysPreTouch

               # install the wheel for jaxlib
               pip3 install -v --target=${JAXLIB_PATH} dist/jax*.whl --force-reinstall

               # next we need to install the jax python module
               pip3 install --no-deps --target=${JAX_PATH} .
               pip3 install --no-deps --target=${JAX_PATH} opt-einsum

            elif [[ $JAX_VERSION == "5.0" || $JAX_VERSION == "6.0" ]]; then
               PATCHELF_PATH=${JAX_PATH}/patchelf
               ${SUDO} mkdir -p ${PATCHELF_PATH}
               git clone -b ${PATCHELF_VERSION} https://github.com/NixOS/patchelf.git
               cd patchelf
               ./bootstrap.sh
               ./configure --prefix=$PATCHELF_PATH
               make -j
               ${SUDO} make install
               export PATH=$PATH:$PATCHELF_PATH/bin
               cd ../
               rm -rf patchelf
               module load amdclang
               export CLANG_COMPILER=`which clang`
               sed -i "s|/usr/lib/llvm-18/bin/clang|$CLANG_COMPILER|g" .bazelrc
               _jax_strip_rocm_cpath
               python3 build/build.py build --rocm_path=$ROCM_PATH \
                                            --bazel_options=--override_repository=xla=$XLA_PATH \
                                            --rocm_amdgpu_targets=$AMDGPU_GFXMODEL \
                                            --clang_path=$ROCM_PATH/llvm/bin/clang \
                                            --rocm_version=$ROCM_VERSION_BAZEL \
                                            --use_clang=true \
                                            --wheels=jaxlib,jax-rocm-plugin,jax-rocm-pjrt \
                                            --bazel_options=--jobs=128 \
                                            --bazel_options=--noexperimental_check_external_repository_files \
                                            --bazel_startup_options=--output_base="${BAZEL_OUTPUT_BASE}" \
                                            --bazel_startup_options=--host_jvm_args=-Xmx16g \
                                            --bazel_startup_options=--host_jvm_args=-XX:+UseG1GC \
                                            --bazel_startup_options=--host_jvm_args=-XX:+AlwaysPreTouch
 
               # install the wheel for jaxlib
               pip3 install -v --target=${JAXLIB_PATH} dist/jax*.whl --force-reinstall

               # next we need to install the jax python module
               pip3 install --no-deps --target=${JAX_PATH} .
               pip3 install --no-deps --target=${JAX_PATH} opt-einsum

            else
               echo " JAX version $JAX_VERSION not compatible with ROCm 6.4.0 "
               compat_info
            fi
         else
            if [[ $JAX_VERSION == "5.0" || $JAX_VERSION == "6.0" ]]; then
               PATCHELF_PATH=${JAX_PATH}/patchelf
               ${SUDO} mkdir -p ${PATCHELF_PATH}
               git clone -b ${PATCHELF_VERSION} https://github.com/NixOS/patchelf.git
               cd patchelf
               ./bootstrap.sh
               ./configure --prefix=$PATCHELF_PATH
               make -j
               ${SUDO} make install
               export PATH=$PATH:$PATCHELF_PATH/bin
               cd ../
               rm -rf patchelf
               module load amdclang
               export CLANG_COMPILER=`which clang`
               sed -i "s|/usr/lib/llvm-18/bin/clang|$CLANG_COMPILER|g" .bazelrc
               _jax_strip_rocm_cpath
               python3 build/build.py build --rocm_path=$ROCM_PATH \
                                            --bazel_options=--override_repository=xla=$XLA_PATH \
                                            --rocm_amdgpu_targets=$AMDGPU_GFXMODEL \
                                            --clang_path=$ROCM_PATH/llvm/bin/clang \
                                            --rocm_version=$ROCM_VERSION_BAZEL \
                                            --use_clang=true \
                                            --wheels=jaxlib,jax-rocm-plugin,jax-rocm-pjrt \
                                            --bazel_options=--jobs=128 \
                                            --bazel_options=--noexperimental_check_external_repository_files \
                                            --bazel_startup_options=--output_base="${BAZEL_OUTPUT_BASE}" \
                                            --bazel_startup_options=--host_jvm_args=-Xmx16g \
                                            --bazel_startup_options=--host_jvm_args=-XX:+UseG1GC \
                                            --bazel_startup_options=--host_jvm_args=-XX:+AlwaysPreTouch

               # install the wheel for jaxlib
               pip3 install -v --target=${JAXLIB_PATH} dist/jax*.whl --force-reinstall

               # next we need to install the jax python module
               pip3 install --no-deps --target=${JAX_PATH} .
               pip3 install --no-deps --target=${JAX_PATH} opt-einsum

            else
               # build the wheel for jaxlib using gcc
               _jax_strip_rocm_cpath
               python3 build/build.py --enable_rocm --rocm_path=$ROCM_PATH \
                                      --bazel_options=--override_repository=xla=$XLA_PATH \
                                      --rocm_amdgpu_targets=$AMDGPU_GFXMODEL \
                                      --bazel_options=--action_env=CC=/usr/bin/gcc --nouse_clang \
                                      --build_gpu_plugin --gpu_plugin_rocm_version=$ROCM_VERSION_BAZEL --build_gpu_kernel_plugin=rocm \
                                      --bazel_options=--jobs=128 \
                                      --bazel_options=--noexperimental_check_external_repository_files \
                                      --bazel_startup_options=--output_base="${BAZEL_OUTPUT_BASE}" \
                                      --bazel_startup_options=--host_jvm_args=-Xmx16g \
                                      --bazel_startup_options=--host_jvm_args=-XX:+UseG1GC \
                                      --bazel_startup_options=--host_jvm_args=-XX:+AlwaysPreTouch

               # install the wheel for jaxlib
               pip3 install -v --target=${JAXLIB_PATH} dist/jax*.whl --force-reinstall

               # next we need to install the jax python module
               pip3 install --no-deps --target=${JAX_PATH} .
               pip3 install --no-deps --target=${JAX_PATH} opt-einsum

            fi
         fi
      fi	 

      # cleanup: trap on JAX_BUILD_ROOT (set in the build entry below)
      # handles removal of jax / rocm-jax / xla source trees. The
      # original `rm -rf /tmp/jax /tmp/rocm-jax /tmp/xla` pattern
      # would clobber any other concurrent jax build on the same node.
      cd /

      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} find ${JAXLIB_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${JAXLIB_PATH} -type d -execdir chown root:root "{}" +
         ${SUDO} find ${JAX_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${JAX_PATH} -type d -execdir chown root:root "{}" +
      fi

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${JAXLIB_PATH}
         ${SUDO} chmod go-w ${JAX_PATH}
      fi

      # Capture ROCM_PATH BEFORE the unload so the modulefile heredoc
      # below resolves it correctly. Without this the heredoc's
      # ${ROCM_PATH} expanded to empty, producing the LD_PRELOAD line
      # `prepend_path("LD_PRELOAD","/lib/llvm/lib/libunwind.so.1")`
      # which then hit `cannot be preloaded ... ignored` at every
      # module-load and silently disabled the libunwind workaround
      # that commit b173acf added to keep jax compute kernels from
      # segfaulting on ROCm 7.x. (Cached-install branch above does not
      # unload, so ROCM_PATH is still valid there; we set ROCM_PATH_FOR_MODULE
      # in both branches for symmetry via the fallback below.)
      ROCM_PATH_FOR_MODULE="${ROCM_PATH}"
      module unload ${ROCM_MODULE_NAME}
   fi
   : "${ROCM_PATH_FOR_MODULE:=${ROCM_PATH}}"

   # Create a module file for jax
   #
   # Modulefile-write sudo: canonical PKG_SUDO pattern (job 8063 audit;
   # see netcdf_setup.sh for the lying-probe failure mode this replaces).
   PKG_SUDO_MOD=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
   ${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

   # Provenance: capture this leaf script's git state for the modulefile
   # whatis() line below. Uses LEAF_SCRIPT_PATH (absolute path captured
   # at the top of this script before any cd) so this works even after
   # the script has cd'd into a temp build dir. Self-contained: falls
   # back to "unknown" when run from a stripped-of-.git context (Docker
   # layer, release tarball, or git binary missing).
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

   # The - option suppresses tabs
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/0.${JAX_VERSION}.lua
	whatis("JAX version ${JAX_VERSION} with ROCm support")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	prereq("${ROCM_MODULE_NAME}")
	setenv("XLA_FLAGS","--xla_gpu_enable_triton_gemm=False --xla_gpu_autotune_level=3")
	setenv("JAX_PLATFORMS","rocm,cpu")
	prepend_path("LD_PRELOAD","${ROCM_PATH_FOR_MODULE}/lib/llvm/lib/libunwind.so.1")
	prepend_path("PYTHONPATH","${JAX_PATH}")
	prepend_path("PYTHONPATH","${JAXLIB_PATH}")
EOF

fi
