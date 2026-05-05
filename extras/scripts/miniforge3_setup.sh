#!/bin/bash

# Capture this script's absolute path BEFORE any cd, so the inline
# git-provenance block lower down can resolve the script in the repo
# even after the build has cd'd into a temp dir. (BASH_SOURCE[0] is
# whatever path was used to invoke the script -- often relative when
# called from main_setup.sh -- so we absolutize it once, here.)
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
SUDO="sudo"
PYTHON_VERSION="10"
BUILD_MINIFORGE3=0
MODULE_PATH=/etc/lmod/modules/LinuxPlus/miniforge3/
MINIFORGE3_VERSION="24.9.0"
MINIFORGE3_VERSION_DOWNLOAD=${MINIFORGE3_VERSION}-0
MINIFORGE3_PATH=/opt/miniforge3-v${MINIFORGE3_VERSION}
MINIFORGE3_PATH_INPUT=""
# --install-path: parent dir; the script appends
# miniforge3-v${MINIFORGE3_VERSION} itself. Used by main_setup.sh so
# the orchestrator never has to know the version. miniforge3 lives
# OUTSIDE the rocmplus tree (it is ROCm-version-independent); the
# --install-path argument matches main_setup.sh's TOP_INSTALL_PATH
# semantics (parent dir; script appends versioned subdir).
# --install-path-no-version (full leaf dir, no version appended) wins
# over --install-path when both are set, for callers that need exact
# control of the final install directory.
TOP_INSTALL_PATH_INPUT=""


if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path-no-version and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --python-version [ PYTHON_VERSION ], python3 minor release, default $PYTHON_VERSION"
   echo "  --build-miniforge3 [ BUILD_MINIFORGE3 ], installs Miniforge3, default $BUILD_MINIFORGE3"
   echo "  --miniforge3-version [ MINIFORGE3_VERSION ], Miniforge3 version, default $MINIFORGE3_VERSION"
   echo "  --install-path-no-version [ MINIFORGE3_PATH_INPUT ], default is $MINIFORGE3_PATH "
   echo "  --install-path [ TOP_INSTALL_PATH_INPUT ] parent dir; if set (and --install-path-no-version is not), MINIFORGE3_PATH = TOP_INSTALL_PATH/miniforge3-v\${MINIFORGE3_VERSION}"
   echo "  --module-path [ MODULE_PATH ], default is $MODULE_PATH "
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
      "--miniforge3-version")
          shift
          MINIFORGE3_VERSION=${1}
	  reset-last
          ;;
       "--build-miniforge3")
          shift
          BUILD_MINIFORGE3=${1}
          reset-last
          ;;
       "--install-path-no-version")
          shift
          MINIFORGE3_PATH_INPUT=${1}
          reset-last
          ;;
       "--install-path")
          shift
          TOP_INSTALL_PATH_INPUT=${1}
          reset-last
          ;;
       "--module-path")
          shift
          MODULE_PATH=${1}
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

if [ "${MINIFORGE3_PATH_INPUT}" != "" ]; then
   MINIFORGE3_PATH=${MINIFORGE3_PATH_INPUT}
elif [ "${TOP_INSTALL_PATH_INPUT}" != "" ]; then
   # Orchestrator-friendly: caller passes the top-level parent dir;
   # this script appends miniforge3-v${MINIFORGE3_VERSION} from its own
   # default. Lets main_setup.sh stay version-agnostic for miniforge3.
   MINIFORGE3_PATH=${TOP_INSTALL_PATH_INPUT}/miniforge3-v${MINIFORGE3_VERSION}
else
   # override path in case MINIFORGE3_VERSION has been supplied as input
   MINIFORGE3_PATH=/opt/miniforge3-v${MINIFORGE3_VERSION}
fi

echo ""
echo "============================"
echo " Installing Miniforge3 with:"
echo "MINIFORGE3_VERSION is $MINIFORGE3_VERSION"
echo "PYTHON_VERSION (python3 minor release) is $PYTHON_VERSION"
echo "BUILD_MINIFORGE3 is $BUILD_MINIFORGE3"
echo "Installing in: $MINIFORGE3_PATH"
echo "Creating module file in: $MODULE_PATH"
echo "============================"
echo ""

# ── BUILD_MINIFORGE3=0 short-circuit: operator opt-out ───────────────
# See miniconda3_setup.sh for the full rationale; same canonical
# pattern as the 23 packages that went through the refactor.
NOOP_RC=43
if [ "${BUILD_MINIFORGE3}" = "0" ]; then
   echo "[miniforge3 BUILD_MINIFORGE3=0] operator opt-out; skipping."
   exit ${NOOP_RC}
fi

# ── Existence guard: skip if this version is already installed ───────
# See miniconda3_setup.sh for the full rationale (same broken
# main_setup.sh `[[ ! -d ${TOP_INSTALL_PATH}/miniforge3 ]]` clause
# that this replaces; same intentional non-threading of --replace;
# same operator-driven `rm -rf` workflow on failure).
if [ -d "${MINIFORGE3_PATH}" ]; then
   echo "[miniforge3 existence-check] ${MINIFORGE3_PATH} already installed; skipping."
   echo "                             remove ${MINIFORGE3_PATH} by hand to force a rebuild"
   echo "                             (--replace is intentionally not threaded; see main_setup.sh)."
   exit ${NOOP_RC}
fi

echo ""
echo "============================"
echo " Building Miniforge3"
echo "============================"
echo ""

# don't use sudo if user has write access to install path
if [ -d "$MINIFORGE3_PATH" ]; then
   # don't use sudo if user has write access to install path
   if [ -w ${MINIFORGE3_PATH} ]; then
      SUDO=""
   else
      echo "WARNING: using an install path that requires sudo"
   fi
else
   # if install path does not exist yet, the check on write access will fail
   echo "WARNING: using sudo, make sure you have sudo privileges"
fi

# Per-job throwaway dir for the installer; replaces a fixed
# /tmp/Miniforge3-*.sh path / glob that would race with -- and
# could clobber -- any other concurrent miniforge3 install on the
# same node.
MINIFORGE_BUILD_ROOT=$(mktemp -d -t miniforge-build.XXXXXX)
trap '[ -n "${MINIFORGE_BUILD_ROOT:-}" ] && ${SUDO:-sudo} rm -rf "${MINIFORGE_BUILD_ROOT}"' EXIT
MINIFORGE_INSTALLER="${MINIFORGE_BUILD_ROOT}/Miniforge3-$(uname)-$(uname -m).sh"
wget -q "https://github.com/conda-forge/miniforge/releases/download/${MINIFORGE3_VERSION_DOWNLOAD}/Miniforge3-$(uname)-$(uname -m).sh" -O "${MINIFORGE_INSTALLER}"
chmod +x "${MINIFORGE_INSTALLER}"
${SUDO} mkdir -p ${MINIFORGE3_PATH}
${SUDO} "${MINIFORGE_INSTALLER}" -b -u -p ${MINIFORGE3_PATH}
# trap handles cleanup of ${MINIFORGE_BUILD_ROOT}

# Create a module file for miniforge3
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

# Modulefile name was previously hardcoded to 24.9.0.lua, which
# silently ignored --miniforge3-version overrides (sister bug to
# what miniconda3_setup.sh did right at line ${MINICONDA3_VERSION}.lua).
# Now keyed on ${MINIFORGE3_VERSION} so multi-version coexistence
# actually works.
cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${MINIFORGE3_VERSION}.lua
	whatis("Miniforge3 - conda-forge installer with mamba")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")
	conflict("miniconda3")
	local root = "${MINIFORGE3_PATH}"
	setenv("MINIFORGE3_ROOT", root)
	setenv("CONDA_ENVS_PATH", pathJoin(root, "envs"))
	setenv("MAMBA_ROOT_PREFIX", root)
	prepend_path("PATH",pathJoin(root,"bin"))
	prepend_path("PATH",pathJoin(root,"condabin"))

	local myShell = myShellName()
	if (mode() == "load") then
	   if (myShell == "bash") then
	      cmd = "source " .. root .. "/etc/profile.d/conda.sh"
	      cmd1 = "source " .. root .. "/etc/profile.d/mamba.sh"
	   else
	      cmd = "source " .. root .. "/etc/profile.d/conda.csh"
	      cmd1 = "source " .. root .. "/etc/profile.d/mamba.csh"
	   end
	   execute{cmd=cmd, modeA = {"load"}}
	   execute{cmd=cmd1, modeA = {"load"}}
	end

	if (mode() == "unload") then
	   remove_path("PATH",pathJoin(root,"bin"))
	   remove_path("PATH",pathJoin(root,"condabin"))

	   if (myShell == "bash") then
	      cmd2 = "unset CONDA_EXE; unset _CE_CONDA; unset _CE_M; " ..
	            "unset CONDA_PYTHON_EXE; unset CONDA_SHLVL; " ..
	            "unset MAMBA_ROOT_PREFIX; " ..
	            "unset -f __m_activate; unset -f __conda_reactivate; " ..
	            "unset -f __conda_hashr; unset -f conda; " ..
	            "unset CONDA_PREFIX; unset CONDA_DEFAULT_ENV; " ..
	            "unset CONDA_PROMPT_MODIFIER; unset CONDA_ENV_PATH; " ..
	            "unset _CONDA_EXE; unset _CONDA_ROOT; unset CONDA_BACKUP_PATH; " ..
	            "unset MAMBA_NO_BANNER; " ..
	            "unset -f __conda_activate; unset -f __conda_reactivate; " ..
	            "unset -f __conda_hashr; unset -f conda; unset -f __conda_exe"
	   else
	      cmd2 = "unsetenv CONDA_EXE; unsetenv CONDA_PYTHON_EXE; unsetenv CONDA_SHLVL; " ..
	             "unsetenv _CONDA_EXE; unsetenv _CONDA_ROOT;" ..
	             "unsetenv MAMBA_NO_BANNER; unalias conda; " ..
	             "unsetenv _CE_CONDA; unsetenv _CE_M; " ..
	             "unsetenv CONDA_PREFIX; unsetenv CONDA_DEFAULT_ENV; " ..
	             "unsetenv CONDA_PROMPT_MODIFIER; unsetenv CONDA_ENV_PATH; " ..
	             "unsetenv CONDA_BACKUP_PATH; unsetenv MAMBA_ROOT_PREFIX; "
	   end
	   execute{cmd=cmd2, modeA={"unload"}}
	end

EOF
