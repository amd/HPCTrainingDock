#!/bin/bash

# Capture this script's absolute path BEFORE any cd, so the inline
# git-provenance block lower down can resolve the script in the repo
# even after the build has cd'd into a temp dir. (BASH_SOURCE[0] is
# whatever path was used to invoke the script -- often relative when
# called from main_setup.sh -- so we absolutize it once, here.)
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi

# PKG_SUDO is independent of the install-path-derived SUDO: apt operates
# on root-owned /var/lib/{apt,dpkg} regardless of where the package files
# end up. See openmpi_setup.sh / audit_2026_05_01.md Issue 2.
PKG_SUDO=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")


usage()
{
   echo "Usage:"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --help: this usage information"
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
      "--help")
         usage
         ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
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

# if ROCM_VERSION is greater than 6.1.2, the awk command will give the ROCM_VERSION number
# if ROCM_VERSION is less than or equal to 6.1.2, the awk command result will be blank
result=`echo $ROCM_VERSION | awk '$1>6.1.2'` && echo $result
if [[ "${result}" == "${ROCM_VERSION}" ]]; then
   echo "ROCm built-in profiling tools should already be installed on ROCm versions after 6.2.0"
   exit
fi

TOOL_NAME=omnitrace
TOOL_EXEC_NAME=omnitrace
TOOL_NAME_MC=Omnitrace
TOOL_NAME_UC=OMNITRACE
# if ROCM_VERSION is greater than 6.2.9, the awk command will give the ROCM_VERSION number
result=`echo ${ROCM_VERSION} | awk '$1>6.2.9'` && echo $result
if [[ "${result}" ]]; then
   TOOL_NAME=rocprofiler-systems
   TOOL_EXEC_NAME=rocprof-sys-avail
   TOOL_NAME_MC=Rocprofiler-systems
   TOOL_NAME_UC=ROCPROFILER_SYSTEMS
fi

echo ""
echo "=================================="
echo "Starting ROCm ${TOOL_NAME_MC} Install with"
echo "DISTRO: $DISTRO"
echo "DISTRO_VERSION: $DISTRO_VERSION"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "AMDGPU_ROCM_VERSION: $AMDGPU_ROCM_VERSION"
echo "AMDGPU_INSTALL_VERSION: $AMDGPU_INSTALL_VERSION"
echo "=================================="
echo ""

# if ROCM_VERSION is greater than 6.1.2, the awk command will give the ROCM_VERSION number
# if ROCM_VERSION is less than or equal to 6.1.2, the awk command result will be blank
result=`echo $ROCM_VERSION | awk '$1>6.1.2'` && echo $result
if [[ "${result}" == "" ]]; then
   echo "ROCm built-in ${TOOL_NAME_MC} version cannot be installed on ROCm versions before 6.2.0"
   exit
fi
if [[ -f /opt/rocm-${ROCM_VERSION}/bin/${TOOL_EXEC_NAME} ]] ; then
   echo "ROCm built-in ${TOOL_NAME_MC} already installed"
else
   if [ "${DISTRO}" == "ubuntu" ]; then
      ${PKG_SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -q -y ${TOOL_NAME}
   fi
fi

if [[ -f /opt/rocm-${ROCM_VERSION}/bin/${TOOL_EXEC_NAME} ]] ; then
   export MODULE_PATH=/etc/lmod/modules/ROCm/${TOOL_NAME}
   ${SUDO} mkdir -p ${MODULE_PATH}
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
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${ROCM_VERSION}.lua
	whatis("Name: ${TOOL_NAME}")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")
	whatis("Version: ${ROCM_VERSION}")
	whatis("Category: AMD")
	whatis("${TOOL_NAME}")

        -- Export environmental variables
        local topDir="/opt/rocm-${ROCM_VERSION}"
        local binDir="/opt/rocm-${ROCM_VERSION}/bin"
        local shareDir="/opt/rocm-${ROCM_VERSION}/share/${TOOL_NAME}"

        setenv("${TOOL_NAME_UC}_DIR",topDir)
        setenv("${TOOL_NAME_UC}_BIN",binDir)
        setenv("${TOOL_NAME_UC}_SHARE",shareDir)
        prepend_path("PATH", pathJoin(shareDir, "bin"))

	load("${ROCM_MODULE_NAME}")
	setenv("ROCP_METRICS", pathJoin(os.getenv("ROCM_PATH"), "/lib/rocprofiler/metrics.xml"))
        set_shell_function("omnitrace-avail",'/opt/rocm-${ROCM_VERSION}/bin/rocprof-sys-avail "$@"',"/opt/rocm-${ROCM_VERSION}/bin/rocprof-sys-avail $*")
        set_shell_function("omnitrace-instrument",'/opt/rocm-${ROCM_VERSION}/bin/rocprof-sys-instrument "$@"',"/opt/rocm-${ROCM_VERSION}/bin/rocprof-sys-instrument $*")
        set_shell_function("omnitrace-run",'/opt/rocm-${ROCM_VERSION}/bin/rocprof-sys-run "$@"',"/opt/rocm-${ROCM_VERSION}/bin/rocprof-sys-run $*")
EOF

fi
