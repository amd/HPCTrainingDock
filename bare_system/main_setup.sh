#!/bin/bash

# ---------------------------------------------------------------------
# Self-copy guard.
#
# Bash reads scripts incrementally by byte offset, not line number. If
# the source file is overwritten in-place while a long sweep is
# running (editor save, `sed -i`, Cursor StrReplace, etc.), bash's
# cached offset shifts, and it reads garbled bytes at its current
# position -- producing spurious .err noise like
#   bare_system/main_setup.sh: line 1033: LD_JAX}: command not found
# (the fragment is the middle of `${BUILD_JAX}` after an unrelated
# top-of-file insertion shifts the line down by ~440 bytes).
#
# Cross-ref: jobs 8052/8053 (May 2), 8224 (May 5), 8523 (May 7). Same
# root cause; different fragments because the offset drift differs
# per edit. POSIX/bash doc:
#   "If the script is modified while it is being read, the result is
#    unspecified."
#
# Fix: cp this script to a tempfile and re-exec from there. Once
# exec'd, the running bash holds the tempfile's inode; subsequent
# edits to the source path no longer affect this in-flight process.
# Idempotent via MAIN_SETUP_SELFCOPIED. Cleanup of the tempfile is
# folded into final_summary() so the existing
# `trap final_summary EXIT` (further down) is not displaced.
if [[ -z "${MAIN_SETUP_SELFCOPIED:-}" ]]; then
   _MS_SELF=$(mktemp -t main_setup.XXXXXX.sh) || exit 1
   cp -- "$0" "$_MS_SELF"
   export MAIN_SETUP_SELFCOPIED="$_MS_SELF"
   exec /bin/bash "$_MS_SELF" "$@"
fi
# ---------------------------------------------------------------------

: ${ROCM_VERSION:=""}
# Delta-release support: when set, BASE_ROCM_VERSION is installed first by
# rocm_setup.sh and the ROCM_VERSION delta is merged on top. When SUPERSEDES_VERSION
# is set, a tombstone modulefile is emitted at rocm/<SUPERSEDES_VERSION>.lua
# that redirects to rocm/<ROCM_VERSION>. See bare_system/rocm_delta_releases.conf.
: ${BASE_ROCM_VERSION:=""}
: ${SUPERSEDES_VERSION:=""}
: ${ROCM_INSTALLPATH:="/opt/"}
: ${TOP_INSTALL_PATH:="/opt"}
: ${TOP_MODULE_PATH:="/etc/lmod/modules"}
: ${ROCM_PATH:=""}
: ${SITE:=""}
# Resolution-source sentinels: flipped to 1 by the CLI parser when the
# corresponding flag is passed explicitly. Used by the post-CLI
# resolve_paths block to honor priority:
#   1. CLI primitives (--top-install-path/--top-module-path/--rocm-path/
#      --rocm-install-path) always win.
#   2. --site preset fills in any value not already set by CLI.
#   3. Auto-derive: TOP_MODULE_PATH from MODULEPATH (find '*/base' with
#      a 'rocm/' subdir, parent = TOP_MODULE_PATH); ROCM_PATH from
#      `module show rocm/<v>` (grep setenv ROCM_PATH); TOP_INSTALL_PATH
#      = dirname($ROCM_PATH).
#   4. Final fallback: /opt + /opt/modules.
# All four flags remain functional unchanged for callers that always
# pass them (the sbatch wrapper still does, so existing sweep behavior
# is byte-identical when the operator does not pass --site).
TOP_INSTALL_PATH_CLI=0
TOP_MODULE_PATH_CLI=0
ROCM_INSTALLPATH_CLI=0
ROCM_PATH_CLI=0
SITE_CLI=0
: ${BUILD_PYTORCH:="1"}
: ${BUILD_CUPY:="1"}
: ${BUILD_HIP_PYTHON:="1"}
: ${BUILD_TENSORFLOW:="1"}
: ${BUILD_JAX:="1"}
: ${BUILD_FTORCH:="1"}
# FTorch Fortran toolchain selector. Accepts:
#   gfortran  -- only build gfortran ftorch (legacy behavior)
#   amdflang  -- only build amdflang ftorch (sibling ftorch_amdflang
#                install + module)
#   both      -- build BOTH; ~2 min extra wall-time per sweep, no
#                module-load ambiguity since they live under separate
#                Lmod names (ftorch vs ftorch_amdflang)
# Default `both` so users can pick the toolchain at `module load` time
# without each having to wait for a custom rebuild. .mod files are not
# portable across Fortran compilers, so this is the only way to serve
# both communities from one sweep -- see ftorch_setup.sh for the .mod
# format diff (gfortran = gzip; amdflang = LLVM Flang text format).
: ${FTORCH_FC_COMPILER:="both"}
: ${BUILD_JULIA:="1"}
: ${BUILD_MAGMA:="1"}
: ${BUILD_ELPA:="1"}
: ${BUILD_PETSC:="1"}
: ${BUILD_HYPRE:="1"}
: ${BUILD_SCOREP:="1"}
: ${BUILD_KOKKOS:="1"}
: ${BUILD_HDF5:="1"}
: ${BUILD_NETCDF:="1"}
: ${BUILD_FFTW:="1"}
: ${BUILD_MINICONDA3:="1"}
: ${BUILD_MINIFORGE3:="1"}
: ${BUILD_LIKWID:="1"}
: ${BUILD_MDB:="1"}
: ${BUILD_INTELLIKIT:="1"}
: ${BUILD_HPCTOOLKIT:="1"}
: ${BUILD_MPI4PY:="1"}
: ${BUILD_TAU:="1"}
: ${BUILD_X11VNC:="0"}
: ${BUILD_FLANGNEW:="0"}
: ${BUILD_ROCPROFILER_SDK:="1"}
: ${HIPIFLY_MODULE:="1"}
# BUILD_<X> flags for packages that previously had no top-level gate.
# These default to 1 (matching the previous "always" behavior); when
# --packages is used these are flipped to 0 for every package not on the
# whitelist so each block becomes uniformly gated.
: ${BUILD_OPENMPI:="1"}
: ${BUILD_MVAPICH:="1"}
# NOTE: the Cray mpich-wrappers (a standalone MPICH built with FC=amdflang so
# PrgEnv-amd-new/* consumers get an amdflang-format mpi.mod) are no longer
# built in this rocmplus phase. They are now provisioned WITH the rocm-<ver>
# SDK tree by the run_rocm_build*/craywrap/therock scripts (see
# rocm/scripts/mpich_wrappers_setup.sh), so PrgEnv-amd-new has them at
# creation. The consumer blocks below (hdf5/netcdf/fftw/petsc/hypre/tau/
# rocshmem) still PROBE for the resulting module under
# rocmplus-<ver>/mpich-wrappers/<ver> and use it when present.
: ${BUILD_ROCSHMEM:="1"}
: ${BUILD_ROCPROF_SYS:="1"}
: ${BUILD_ROCPROF_COMPUTE:="1"}
: ${BUILD_HIPIFLY:="1"}
# emacs: ROCm-agnostic editor module (extras/scripts/emacs_setup.sh). Shared
# across ROCm versions (installs under TOP_INSTALL_PATH like miniconda3), so
# it builds once on the first sweep version and existence-skips the rest.
# Built --native-comp 0 (byte-compiled) so it pulls NO gcc-14 packages onto
# the image/nodes -- see the header note in emacs_setup.sh.
: ${BUILD_EMACS:="1"}
: ${PACKAGES_INPUT:=""}      # comma- or space-separated whitelist; empty = all (subject to other flags)
# PnetCDF version (build-time dep of netcdf, also a first-class
# versioned rocmplus module after 2026-05-20). Empty = leaf default
# (netcdf_setup.sh's PNETCDF_VERSION). When non-empty, forwarded to the
# netcdf run_and_log line below as --pnetcdf-version. Sweep-CLI knob
# is run_rocmplus_install_sweep.sh:--pnetcdf-version (threaded via the
# sbatch as the PNETCDF_VERSION env var, picked up here).
: ${PNETCDF_VERSION:=""}
# NETCDF_PNETCDF_TARBALL: operator-staged official PnetCDF tarball, consumed
# verbatim by netcdf_setup.sh (no network, pre-generated configure preserved
# -> skips autoreconf). The official tarball lives ONLY on
# parallel-netcdf.github.io, which some Cray COMPUTE nodes cannot reach (proxy
# allows github.com, blocks github.io). If left unset here, the netcdf block
# below auto-detects a staged tarball under NETCDF_SRC_STAGE_DIR (default
# /shareddata/src) -- matching the PnetCDF version when known -- and exports
# it so the leaf picks it up. Set explicitly to override or disable (point at
# a non-existent path) the auto-detection.
: ${NETCDF_PNETCDF_TARBALL:=""}
: ${NETCDF_SRC_STAGE_DIR:="/shareddata/src"}
: ${PYTHON_VERSION:="12"} # python3 minor release
: ${USE_MAKEFILE:="0"}
: ${QUICK_INSTALLS:="0"}     # 1 = skip packages whose wall is >= 20 min (long-pole gate) PLUS the explicit always-skip set intellikit (see QUICK_INSTALLS_PKGS below)
: ${REPLACE_EXISTING:="0"}   # 1 = remove prior rocmplus-<v> install + module dirs first
: ${KEEP_FAILED_INSTALLS:="0"}  # 1 = keep partial install dirs/modulefiles when a package fails (for post-mortem)
# SKIP_PATCHES: operator opt-out for the rocm_patches.sh step (line ~1651
# / line ~1670 below). 0 (default) runs rocm_patches.sh; for most ROCm
# versions the patches script self-no-ops via NOOP_RC=43 and the cost is
# nil. Set to 1 to bypass the call entirely -- the rocmplus sweep
# (bare_system/run_rocmplus_install_sweep.sh:--skip-patches) propagates
# this through bare_system/run_rocmplus_install.sbatch. Mirrors the
# bare_system/run_rocm_build.sh:--skip-patches gate which covers the
# build-time (Phase 3.6) patches call; this one covers the install-time
# call.
: ${SKIP_PATCHES:="0"}

# ── Per-package versions: leaf scripts own them ──────────────────────
# Every per-package setup script under {extras,tools,comm,rocm}/scripts/
# holds its own internal version default (PKG_VERSION declaration at
# the top of the script). main_setup.sh threads only the parent install
# directory via --install-path (which the migrated leaf scripts now
# treat as a parent dir + auto-append their own pkg-v${PKG_VERSION}
# subdir); --install-path-no-version is the leaf-side escape hatch for
# direct-invocation callers who want exact control of the final path.
# miniconda3 / miniforge3 use the same --install-path convention but
# rooted at TOP_INSTALL_PATH (outside the rocmplus tree, since they
# are ROCm-version-independent).
#
# Why: bumping a version is now a 1-line edit in the leaf script and
# the next sweep picks it up automatically. The older versioned install
# dir + .lua modulefile are left in place so multiple versions still
# coexist on disk. cupy_setup.sh additionally resolves CUPY_VERSION
# from a ROCm-aware default ("auto" -> 14.0.1 on ROCm >= 7.0, 13.6.0
# otherwise); jax_setup.sh has a similar policy gate that downshifts
# JAX_VERSION on ROCm 6.x.
#
# Operator escape hatches:
#   * Direct invocation:  pkg_setup.sh --<pkg>-version X.Y.Z ...
#   * Pin from main_setup.sh: edit the PKG_VERSION default in the leaf
#     script (NOT this file). Searches across the tree for the variable
#     name (e.g. `rg FFTW_VERSION extras/scripts/`) point at exactly
#     one place.
#
# mpi4py was the trial migration; the same shape (single PKG_VERSION,
# leaf appends version, orchestrator passes parent dir) applies to all
# 14 leaf scripts touched by this pass.

INSTALL_ROCPROF_SYS_FROM_SOURCE=0
INSTALL_ROCPROF_COMPUTE_FROM_SOURCE=0
AMDGPU_GFXMODEL_INPUT=""
SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

if [[ "${DISTRO}" == "ubuntu" ]]; then
   if [[ "${DISTRO_VERSION}" == "22.04" ]]; then
      PYTHON_VERSION="10"
   fi
fi

reset-last()
{
   last() { echo "Unsupported argument :: ${1}"; }
}

usage()
{
   echo "Usage:"
   echo "  --rocm-version [ ROCM_VERSION ]:  auto-detected from loaded module, or specify explicitly"
   echo "  --base-rocm-version [ VER ]:  for delta releases, install <VER> first and merge \$ROCM_VERSION on top (default: empty -- consulted from bare_system/rocm_delta_releases.conf when empty)"
   echo "  --supersedes [ VER ]:  emit a tombstone rocm/<VER>.lua that redirects to rocm/\$ROCM_VERSION (default: empty)"
   echo "  --rocm-install-path [ ROCM_INSTALL_PATH ]:  parent dir for the rocm SDK install (e.g. /opt -> /opt/rocm-<v>). Default is $ROCM_INSTALLPATH"
   echo "  --rocm-path [ ROCM_PATH ]:  full path to the rocm SDK (e.g. /shared/apps/ubuntu/opt/rocm-7.2.3). Default: auto-derived from a loaded rocm module's setenv(ROCM_PATH) or from \`module show rocm/<v>\`. CLI value overrides any derived value."
   echo "  --top-install-path [ TOP_INSTALL_PATH ]:  top-level directory for software installation (parent of rocmplus-<v>/). Default: --site preset, else dirname(\$ROCM_PATH), else $TOP_INSTALL_PATH"
   echo "  --top-module-path [ TOP_MODULE_PATH ]:  top-level directory for module files (parent of base/, rocm-<v>/, rocmplus-<v>/). Default: --site preset, else derived from \$MODULEPATH (entry ending in '/base' with a rocm/ subdir, parent), else /opt/modules"
   echo "  --site [ opt | nfsapps | shared-apps | /ABS/PATH ]:  shorthand preset for the three path flags above. Named presets: opt = /opt + /opt/modules; nfsapps = /nfsapps/opt + /nfsapps/modules (test tree); shared-apps = /shared/apps/ubuntu/opt + /shared/apps/modules/ubuntu/lmodfiles (live cluster tree, Ubuntu 22.04). Absolute path form: any value starting with '/' is treated as a parent prefix, expanded to PREFIX/opt + PREFIX/modules (e.g. --site /nfsapps/ubuntu-22.04 -> /nfsapps/ubuntu-22.04/opt + /nfsapps/ubuntu-22.04/modules) -- useful for distro-segregated test trees. Any --top-* / --rocm-* CLI flag overrides the corresponding preset value."
   echo "  --python-version [ PYTHON_VERSION ]: python3 minor release, default is $PYTHON_VERSION"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ]: auto-detected via rocminfo, can specify multiple separated by semicolons (e.g. gfx942;gfx90a)"
   echo "  --install-rocprof-compute-from-source [0 or 1]:  default is $INSTALL_ROCPROF_COMPUTE_FROM_SOURCE (false)"
   echo "  --install-rocprof-sys-from-source [0 or 1]:  default is $INSTALL_ROCPROF_SYS_FROM_SOURCE (false)"
   echo "  --use-makefile [0 or 1]:  default is 0 (false)"
   echo "  --quick-installs [0 or 1]:  skip packages whose wall >= 20 min (measured from job 8065 sweep): pytorch (91m), tensorflow (70m), jax (34m, when policy gate allows). Also skips ftorch (transitive: needs pytorch), julia (dormant: no install wired), and intellikit (explicit always-skip in quick mode regardless of wall, e.g. so per-tool iteration does not retrigger its build and its network-heavy monorepo clone does not block the long-pole iteration loop). likwid + mdb are now BUILT in quick mode (sub-minute builds, useful by default). Threshold raised from 15 -> 20 min after job 8065 audit moved petsc (17m) and scorep (17m) under the cutoff. Default $QUICK_INSTALLS"
   echo "  --replace-existing [0 or 1]:  per-package replacement -- before each package block, if its BUILD_<PKG> flag is 1, remove that one package's install + module dirs so the setup script reinstalls it. Packages whose BUILD_<PKG> is 0 (e.g. under --quick-installs 1 or not in --packages) keep their existing install untouched. Never touches \${TOP_INSTALL_PATH}/rocm-\${ROCM_VERSION} or \${TOP_MODULE_PATH}/rocm-\${ROCM_VERSION}. Also exempts miniconda3 and miniforge3, whose install dirs are shared across ROCm versions; to force a rebuild of those, manually rm -rf the versioned subdir under \${TOP_INSTALL_PATH} (the version itself lives in the leaf script). Default $REPLACE_EXISTING"
   echo "  --keep-failed-installs [0 or 1]:  on a per-package failure, default (0) wipes the partial install dir + half-written modulefile so the next run starts clean. Set to 1 to leave the artifacts on disk for post-mortem inspection. Default $KEEP_FAILED_INSTALLS"
   echo "  --skip-patches [0 or 1]:  operator opt-out for the rocm-patches step (rocm/scripts/rocm_patches.sh) AND the hipblaslt-patch step (rocm/scripts/hipblaslt_patch_setup.sh). Default 0 runs both; for most ROCm versions each script self-no-ops via NOOP_RC=43 so the cost is nil. Set to 1 when targeting a tree where the patches overlay would mismatch the runtime (e.g. 7.2.0 / 7.2.1 patches built for a newer userland and running on Ubuntu 22.04 nodes). When skipped, the per-package summary records 'rocm-patches(--skip-patches)' and 'hipblaslt-patch(--skip-patches)' in the DESELECTED bucket. Default $SKIP_PATCHES"
   echo "  --packages \"name1 name2 ...\":  whitelist; only these packages are built. Disables every other gated package (overrides --quick-installs for listed names). Recognized: flang-new, openmpi, mpi4py, mvapich, rocprof-sys, rocprof-compute, hpctoolkit, likwid, mdb, intellikit, scorep, tau, cupy, hip-python, tensorflow, jax, ftorch, pytorch, magma, elpa, kokkos, miniconda3, miniforge3, hipifly, hdf5, netcdf, fftw, petsc, hypre, emacs. Empty = all (subject to --quick-installs). Versioned form name=VERSION (with optional 'v' prefix, e.g. cupy=v13.0.1 or pytorch=2.7.1) is supported for: openmpi, mpi4py, hpctoolkit, likwid, mdb, intellikit, scorep, cupy, hip-python, tensorflow, jax, ftorch, pytorch, magma, elpa, kokkos, miniconda3, miniforge3, hdf5, netcdf, fftw, petsc, hypre, emacs. For netcdf, VERSION is the netcdf-c version; the matching netcdf-fortran is auto-derived inside the leaf script via its NETCDF_C_TO_F map (pass --netcdf-f-version directly to the leaf to override). Repeating the same name with different versions (e.g. \"pytorch=2.7.1 pytorch=2.8.0\") drives one build per version inside the same job; each lands in its own pkg-vVERSION/ install dir + VERSION.lua module so versions coexist. A bare name uses the leaf script's internal default version. Inline overrides via name=VERSION:OK1=OV1[:OK2=OV2...]: append \":\"-separated key=value pairs after the version to override per-package leaf-script flags. Currently supported only for pytorch; keys are aotriton, torchvision (alias tv), torchaudio (alias ta), triton, flashattention (alias flash), pillow, sageattention (alias sage), deepspeed (alias ds). Example: \"pytorch=2.8.0:flash=2.7.4:tv=0.22.1\" runs pytorch_setup.sh --pytorch-version 2.8.0 --flashattention-version 2.7.4 --torchvision-version 0.22.1. Each (name,version) pair carries its OWN override set, so \"pytorch=2.8.0:flash=2.7.4 pytorch=2.9.1\" overrides flash only on the 2.8.0 build."
   echo "  --rocm-rc-prefix [ FAMILY ]:  release-candidate family name (e.g. 'therock', 'afar'). Auto-detected from \${ROCM_PATH} basename for rocm-{therock,afar}-* trees. Empty for regular releases. When non-empty, install/module dirs become rocmplus-\${FAMILY}-\${ROCM_VERSION}/ instead of rocmplus-\${ROCM_VERSION}/ -- EXCEPT for FAMILY='afar', where the suffix is rocmplus-afar-\${ROCM_RC_COMPILER}-\${ROCM_VERSION}/ (compiler-AND-rocm-keyed; see --rocm-rc-compiler). Default: auto-detected (empty for regular releases)."
   echo "  --rocm-rc-compiler [ COMPILER ]:  compiler/AFAR release number for AFAR trees (e.g. '22.2.0' for rocm-afar-22.2.0, '23.2.1' for rocm-afar-23.2.1 a.k.a. the TheRock-AFAR drop). Auto-detected from \${ROCM_PATH} basename when ROCM_RC_PREFIX='afar'. Empty for non-afar trees. When non-empty AND ROCM_RC_PREFIX='afar', the rocmplus suffix becomes afar-\${COMPILER}-\${ROCM_VERSION} so two AFAR drops with the same SDK numeric but different compiler releases get distinct rocmplus trees. Default: auto-detected."
   echo "  --rocmplus-flavor [ amd|cray ]:  programming-environment whose downstream tree this build populates. 'amd' (default) -> rocmplus-\${SUFFIX} (PrgEnv-amd-new: AMD compiler + from-source mpich-wrappers). 'cray' -> rocmplus-cray-\${SUFFIX} (PrgEnv-cray-new: CCE + cray-mpich), the separate tree PrgEnv-cray-new modulefiles point at, so a cray build never clobbers the amd-new tree for the same ROCm numeric. Default: amd (byte-identical legacy behavior)."
   echo "  --pnetcdf-version [ PNETCDF_VERSION ]:  PnetCDF version threaded through to extras/scripts/netcdf_setup.sh --pnetcdf-version. Empty (default) -> leaf script's internal default. Install lands at rocmplus-<v>/pnetcdf-v\$PNETCDF_VERSION/ with a pnetcdf/\$PNETCDF_VERSION modulefile."
   echo "  --help: prints this message"
   exit 1
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
      "--base-rocm-version")
          shift
          BASE_ROCM_VERSION=${1}
          reset-last
          ;;
      "--supersedes")
          shift
          SUPERSEDES_VERSION=${1}
          reset-last
          ;;
      "--rocm-install-path")
          shift
          ROCM_INSTALLPATH=${1}
          ROCM_INSTALLPATH_CLI=1
          reset-last
          ;;
      "--rocm-path")
          shift
          ROCM_PATH=${1}
          ROCM_PATH_CLI=1
          reset-last
          ;;
      "--top-install-path")
          shift
          TOP_INSTALL_PATH=${1}
          TOP_INSTALL_PATH_CLI=1
          reset-last
          ;;
      "--top-module-path")
          shift
          TOP_MODULE_PATH=${1}
          TOP_MODULE_PATH_CLI=1
          reset-last
          ;;
      "--site")
          shift
          SITE=${1}
          SITE_CLI=1
          reset-last
          ;;
      "--python-version")
          shift
          PYTHON_VERSION=${1}
          reset-last
          ;;
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL_INPUT=${1}
          reset-last
          ;;
      "--install-rocprof-sys-from-source")
          shift
          INSTALL_ROCPROF_SYS_FROM_SOURCE=${1}
          reset-last
          ;;
      "--install-rocprof-compute-from-source")
          shift
          INSTALL_ROCPROF_COMPUTE_FROM_SOURCE=${1}
          reset-last
          ;;
      "--use-makefile")
          shift
          USE_MAKEFILE=${1}
          reset-last
          ;;
      "--quick-installs")
          shift
          QUICK_INSTALLS=${1}
          reset-last
          ;;
      "--replace-existing")
          shift
          REPLACE_EXISTING=${1}
          reset-last
          ;;
      "--keep-failed-installs")
          shift
          KEEP_FAILED_INSTALLS=${1}
          reset-last
          ;;
      "--skip-patches")
          shift
          SKIP_PATCHES=${1}
          reset-last
          ;;
      "--packages")
          shift
          PACKAGES_INPUT=${1}
          reset-last
          ;;
      "--pnetcdf-version")
          shift
          PNETCDF_VERSION=${1}
          reset-last
          ;;
      "--rocm-rc-prefix")
          shift
          ROCM_RC_PREFIX=${1}
          ROCM_RC_PREFIX_USER_SET=1
          reset-last
          ;;
      "--rocm-rc-compiler")
          shift
          ROCM_RC_COMPILER=${1}
          ROCM_RC_COMPILER_USER_SET=1
          reset-last
          ;;
      "--rocmplus-flavor")
          shift
          ROCMPLUS_FLAVOR=${1}
          reset-last
          ;;
      "--help")
          usage
          ;;
      *)
         last ${1}
         ;;
   esac
   n=$((${n} + 1))
   shift
done

# ── Path resolution (--site preset, MODULEPATH/module-show derive) ────
# Priority cascade for each of TOP_INSTALL_PATH, TOP_MODULE_PATH,
# ROCM_PATH, ROCM_INSTALLPATH:
#   1. CLI primitive (--top-install-path, --top-module-path, --rocm-path,
#      --rocm-install-path) -- if its _CLI sentinel is 1, the value is
#      already final and this block is a no-op for it.
#   2. --site preset (opt | nfsapps | shared-apps).
#   3. Auto-derive from the loaded module env: MODULEPATH -> '*/base'
#      parent for TOP_MODULE_PATH; `module show rocm/<v>` setenv
#      ROCM_PATH for ROCM_PATH (and its dirname for TOP_INSTALL_PATH).
#   4. Hard-coded /opt + /opt/modules fallback.
#
# *_SOURCE strings record which rung fired so the info block below
# can show the operator exactly where each path came from.
TOP_INSTALL_PATH_SOURCE=""
TOP_MODULE_PATH_SOURCE=""
ROCM_PATH_SOURCE=""
ROCM_INSTALLPATH_SOURCE=""

[ "${TOP_INSTALL_PATH_CLI}" = "1" ] && TOP_INSTALL_PATH_SOURCE="--top-install-path"
[ "${TOP_MODULE_PATH_CLI}"  = "1" ] && TOP_MODULE_PATH_SOURCE="--top-module-path"
[ "${ROCM_PATH_CLI}"        = "1" ] && ROCM_PATH_SOURCE="--rocm-path"
[ "${ROCM_INSTALLPATH_CLI}" = "1" ] && ROCM_INSTALLPATH_SOURCE="--rocm-install-path"
# ROCM_PATH may also have been inherited from the calling environment
# (e.g. an interactive shell with `module load rocm/<v>` already
# active). Treat that as an explicit external source rather than
# overwriting it via derive below.
if [ "${ROCM_PATH_CLI}" = "0" ] && [ -n "${ROCM_PATH}" ]; then
   ROCM_PATH_SOURCE="\$ROCM_PATH (inherited env)"
fi

# Step 2: --site preset
if [ -n "${SITE}" ]; then
   case "${SITE}" in
      opt)
         _SITE_TOP_INSTALL="/opt"
         _SITE_TOP_MODULE="/opt/modules"
         ;;
      nfsapps)
         _SITE_TOP_INSTALL="/nfsapps/opt"
         _SITE_TOP_MODULE="/nfsapps/modules"
         ;;
      shared-apps)
         _SITE_TOP_INSTALL="/shared/apps/ubuntu/opt"
         _SITE_TOP_MODULE="/shared/apps/modules/ubuntu/lmodfiles"
         ;;
      shareddata)
         # AAC7 (HPE/Cray) shared tree. Mirrors run_rocm_build_sweep.sh's
         # `shareddata` preset so the SDK build and the rocmplus install
         # land on the same tree.
         _SITE_TOP_INSTALL="/shareddata/opt"
         _SITE_TOP_MODULE="/shareddata/modules"
         ;;
      /*)
         # Absolute-path PREFIX form (e.g. --site /nfsapps/ubuntu-22.04):
         # symmetric layout PREFIX/opt + PREFIX/modules. Matches the
         # /opt and /nfsapps presets in shape, just with an arbitrary
         # parent (useful for distro-segregated test trees like
         # /nfsapps/ubuntu-22.04 vs /nfsapps/ubuntu-24.04). Trailing
         # slashes are tolerated. shared-apps's irregular
         # /shared/apps/ubuntu/opt + /shared/apps/modules/ubuntu/lmodfiles
         # layout is NOT reproduced by this form; if the operator needs
         # that exact split they should use --site shared-apps or pass
         # --top-install-path + --top-module-path explicitly.
         _SITE_PREFIX="${SITE%/}"
         _SITE_TOP_INSTALL="${_SITE_PREFIX}/opt"
         _SITE_TOP_MODULE="${_SITE_PREFIX}/modules"
         unset _SITE_PREFIX
         ;;
      *)
         echo "ERROR: --site must be a named preset (opt | nfsapps | shared-apps | shareddata) or an absolute path prefix starting with '/' (got '${SITE}')" >&2
         exit 1
         ;;
   esac
   if [ "${TOP_INSTALL_PATH_CLI}" = "0" ]; then
      TOP_INSTALL_PATH="${_SITE_TOP_INSTALL}"
      TOP_INSTALL_PATH_SOURCE="--site ${SITE}"
   fi
   if [ "${TOP_MODULE_PATH_CLI}" = "0" ]; then
      TOP_MODULE_PATH="${_SITE_TOP_MODULE}"
      TOP_MODULE_PATH_SOURCE="--site ${SITE}"
   fi
   if [ "${ROCM_INSTALLPATH_CLI}" = "0" ]; then
      # ROCM_INSTALLPATH is the parent dir of where rocm-<v> would be
      # laid down by amdgpu-install / extracted by run_rocm_build.sh.
      # For all three presets we co-locate it with TOP_INSTALL_PATH
      # (same parent dir contains rocm-<v> and rocmplus-<v>).
      ROCM_INSTALLPATH="${_SITE_TOP_INSTALL}"
      ROCM_INSTALLPATH_SOURCE="--site ${SITE}"
   fi
   unset _SITE_TOP_INSTALL _SITE_TOP_MODULE
fi

# Step 3a: derive TOP_MODULE_PATH from $MODULEPATH (find '*/base' entry
# whose directory contains a rocm/ subdir; the parent of that entry is
# TOP_MODULE_PATH). On a 22.04 cluster login node with rocm/<v> already
# active, this yields the canonical
# /shared/apps/modules/ubuntu/lmodfiles automatically.
if [ "${TOP_MODULE_PATH_CLI}" = "0" ] && [ -z "${SITE}" ] && [ -n "${MODULEPATH:-}" ]; then
   _derived_mod=""
   _IFS_BAK="${IFS}"
   IFS=':'
   set -- ${MODULEPATH}
   IFS="${_IFS_BAK}"
   for _e in "$@"; do
      if [[ "${_e}" == */base ]] && [ -d "${_e}/rocm" ]; then
         _derived_mod="${_e%/base}"
         break
      fi
   done
   if [ -n "${_derived_mod}" ]; then
      TOP_MODULE_PATH="${_derived_mod}"
      TOP_MODULE_PATH_SOURCE="derived from \$MODULEPATH (${_e})"
   fi
   unset _derived_mod _IFS_BAK _e
fi

# Step 3b: derive ROCM_PATH from `module show rocm/<v>` if still empty.
# Per spec: scan the modulefile body for setenv("ROCM_PATH", "..."), and
# take the value. Works even when rocm/<v> is not currently loaded.
if [ "${ROCM_PATH_CLI}" = "0" ] && [ -z "${ROCM_PATH}" ] && [ -n "${ROCM_VERSION}" ]; then
   if type module >/dev/null 2>&1; then
      _show=$(module show rocm/${ROCM_VERSION} 2>&1 || true)
      # Lua form:  setenv("ROCM_PATH", "/some/path")
      # Tcl form:  setenv      ROCM_PATH       /some/path
      _rp=$(echo "${_show}" | sed -n 's|.*setenv("ROCM_PATH"[[:space:]]*,[[:space:]]*"\([^"]*\)").*|\1|p' | head -1)
      [ -z "${_rp}" ] && _rp=$(echo "${_show}" | sed -n 's|^[[:space:]]*setenv[[:space:]]\+ROCM_PATH[[:space:]]\+\(.*\)$|\1|p' | head -1)
      if [ -n "${_rp}" ] && [ -d "${_rp}" ]; then
         ROCM_PATH="${_rp}"
         ROCM_PATH_SOURCE="module show rocm/${ROCM_VERSION} (setenv ROCM_PATH)"
      fi
      unset _show _rp
   fi
fi

# Step 3c: derive TOP_INSTALL_PATH from $ROCM_PATH if still unset.
if [ "${TOP_INSTALL_PATH_CLI}" = "0" ] && [ -z "${SITE}" ]; then
   if [ -n "${ROCM_PATH}" ] && [ -d "${ROCM_PATH}" ]; then
      TOP_INSTALL_PATH="$(dirname "${ROCM_PATH}")"
      TOP_INSTALL_PATH_SOURCE="dirname(\$ROCM_PATH)"
   fi
fi

# Step 4: final /opt fallback. The `: ${VAR:=default}` at top of file
# already gave us /opt + /etc/lmod/modules; here we upgrade
# /etc/lmod/modules -> /opt/modules to match the documented "/opt prefix
# for /opt/rocm-<ver> and /opt/modules/base" convention. /etc/lmod/modules
# remains a valid CLI value (just no longer a default).
if [ "${TOP_INSTALL_PATH_CLI}" = "0" ] && [ -z "${SITE}" ] && [ -z "${TOP_INSTALL_PATH_SOURCE}" ]; then
   TOP_INSTALL_PATH_SOURCE="default (/opt)"
fi
if [ "${TOP_MODULE_PATH_CLI}" = "0" ] && [ -z "${SITE}" ] && [ -z "${TOP_MODULE_PATH_SOURCE}" ]; then
   if [ "${TOP_MODULE_PATH}" = "/etc/lmod/modules" ]; then
      TOP_MODULE_PATH="/opt/modules"
   fi
   TOP_MODULE_PATH_SOURCE="default (/opt/modules)"
fi
# ROCM_INSTALLPATH: if still untouched, default to TOP_INSTALL_PATH so
# rocm-<v> and rocmplus-<v> land in the same parent dir (matches every
# preset above + matches the legacy /opt/ default's intent).
if [ "${ROCM_INSTALLPATH_CLI}" = "0" ] && [ -z "${SITE}" ]; then
   ROCM_INSTALLPATH="${TOP_INSTALL_PATH}"
   ROCM_INSTALLPATH_SOURCE="= TOP_INSTALL_PATH"
fi

# ── Detect ROCm version + RC prefix from loaded module (if any) ──────
# ROCM_MODULE_VERSION is the SDK numeric (from .info/version), used for
# both the loaded-vs-requested cross-check below and (when --rocm-version
# was not explicitly passed) as the fallback for ROCM_VERSION itself.
#
# ROCM_RC_PREFIX is empty for a regular release (rocm-7.2.1) and is the
# release-candidate FAMILY NAME for tagged trees (e.g. 'therock' for
# rocm-therock-23.2.0, 'afar' for rocm-afar-22.2.0). The dash separator
# between prefix and ROCM_VERSION is added downstream by the
# ${ROCM_RC_PREFIX:+${ROCM_RC_PREFIX}-} expansion when constructing
# install / module paths -- this keeps the regular-release path byte-
# identical to the prior behavior (no prefix, no dash, no change).
#
# The --rocm-rc-prefix CLI override (parsed above) wins if explicitly
# set; otherwise we auto-derive from the ROCM_PATH basename. The user-
# set sentinel ROCM_RC_PREFIX_USER_SET is what distinguishes "operator
# passed --rocm-rc-prefix '' to force regular semantics on a tagged
# install dir" (don't auto-detect) from "operator didn't pass it at
# all" (do auto-detect).
ROCM_MODULE_VERSION=""
: ${ROCM_RC_PREFIX:=""}
: ${ROCM_RC_PREFIX_USER_SET:=0}
: ${ROCM_RC_COMPILER:=""}
: ${ROCM_RC_COMPILER_USER_SET:=0}
# ROCMPLUS_FLAVOR selects which programming-environment's downstream tree
# this sweep populates:
#   * "amd"  (default) -> rocmplus-<suffix>      (PrgEnv-amd-new ecosystem:
#                          AMD compiler + from-source mpich-wrappers). Legacy
#                          behavior -- byte-identical when the flag is absent.
#   * "cray"           -> rocmplus-cray-<suffix> (PrgEnv-cray-new ecosystem:
#                          CCE + cray-mpich/cray-libsci). Matches the separate
#                          tree PrgEnv-cray-new modulefiles already point at
#                          (see emit_cray_prgenv_ecosystem in
#                          leaf_modulefile_helpers.sh: rocmplus-cray-<ver>).
# The "cray-" element is prepended to ROCMPLUS_SUFFIX below so BOTH the
# install dir and the module category dir land in the cray tree, never
# clobbering the amd-new tree for the same ROCm numeric.
: ${ROCMPLUS_FLAVOR:="amd"}
case "${ROCMPLUS_FLAVOR}" in
   amd|cray) : ;;
   *) echo "ERROR: --rocmplus-flavor must be 'amd' or 'cray' (got '${ROCMPLUS_FLAVOR}')" >&2; exit 1 ;;
esac

if [ -n "${ROCM_PATH}" ] && [ -d "${ROCM_PATH}" ]; then
   if [ -f "${ROCM_PATH}/.info/version" ]; then
      ROCM_MODULE_VERSION=$(cut -f1 -d'-' "${ROCM_PATH}/.info/version")
      echo "Detected loaded ROCm module numeric version ${ROCM_MODULE_VERSION} (ROCM_PATH=${ROCM_PATH})"
   fi
   if [ "${ROCM_RC_PREFIX_USER_SET}" != "1" ] || \
      ( [ "${ROCM_RC_PREFIX}" = "afar" ] && [ "${ROCM_RC_COMPILER_USER_SET}" != "1" ] ); then
      _rocm_basename="${ROCM_PATH##*/}"          # rocm-afar-22.2.0 | rocm-therock-7.13.0 | rocm-7.2.1
      _rocm_suffix="${_rocm_basename#rocm-}"      # afar-22.2.0 | therock-7.13.0 | 7.2.1
      # Strip the trailing -<X.Y[.Z]> from the install-dir suffix to get
      # both the family prefix AND the captured numeric tail. The
      # interpretation of the tail depends on the prefix (post unified-AFAR
      # naming, 2026-05-26):
      #   * prefix='afar'        -> tail is the COMPILER/AFAR release number
      #                             (e.g. '22.2.0' for rocm-afar-22.2.0; SDK
      #                             numeric '7.2.0' lives in .info/version)
      #   * prefix='therock'     -> tail IS the SDK numeric (e.g. '7.13.0'
      #                             for rocm-therock-7.13.0; no separate
      #                             compiler number to track)
      #   * prefix='' (regular)  -> tail is the SDK numeric
      # The naive ${_rocm_suffix%%-*} (first-dash cut) would also collapse
      # any multi-segment family prefix (legacy 'therock-afar' would become
      # 'therock'), so we use a regex with two capture groups instead.
      if [[ "${_rocm_suffix}" =~ ^(.+)-([0-9]+(\.[0-9]+){1,2})$ ]]; then
         if [ "${ROCM_RC_PREFIX_USER_SET}" != "1" ]; then
            ROCM_RC_PREFIX="${BASH_REMATCH[1]}"
            echo "Detected ROCm release-candidate prefix: '${ROCM_RC_PREFIX}' (numeric tail: '${BASH_REMATCH[2]}')"
         fi
         # Compiler number is meaningful ONLY for the afar family. For
         # therock and other prefixes the tail IS the SDK numeric and we
         # leave ROCM_RC_COMPILER empty so the ROCMPLUS_SUFFIX construction
         # below falls into the legacy <prefix>-<numeric> branch.
         if [ "${ROCM_RC_PREFIX}" = "afar" ] && [ "${ROCM_RC_COMPILER_USER_SET}" != "1" ]; then
            ROCM_RC_COMPILER="${BASH_REMATCH[2]}"
            echo "Detected ROCm afar compiler/release number: '${ROCM_RC_COMPILER}'"
         fi
      elif [[ ! "${_rocm_suffix}" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
         # Tree name doesn't end in -<NUMERIC>. Fall back to first-segment
         # cut so we still produce something rather than silently leaving
         # ROCM_RC_PREFIX empty (which would land in the regular-release
         # rocmplus tree, the worst-case collision).
         if [ "${ROCM_RC_PREFIX_USER_SET}" != "1" ]; then
            ROCM_RC_PREFIX="${_rocm_suffix%%-*}"
            echo "Detected ROCm release-candidate prefix: '${ROCM_RC_PREFIX}' (RC tag suffix: '${_rocm_suffix#${ROCM_RC_PREFIX}-}'; install-dir name did not end in -<NUMERIC>)"
         fi
      fi
      unset _rocm_basename _rocm_suffix
   fi
fi

# If --rocm-version was not provided, use detected version or fall back.
if [ -z "${ROCM_VERSION}" ]; then
   if [ -n "${ROCM_MODULE_VERSION}" ]; then
      ROCM_VERSION="${ROCM_MODULE_VERSION}"
      echo "Using detected ROCm version: ${ROCM_VERSION}"
   else
      echo "WARNING: ROCm version not specified and no ROCm module detected."
      echo -n "         Proceed with default ROCm version 6.2.0? [y/N] (timeout 60s, default N) "
      read -r -t 60 REPLY || true
      if [[ "${REPLY}" =~ ^[Yy]$ ]]; then
         ROCM_VERSION="6.2.0"
         echo "         Using default ROCm version ${ROCM_VERSION}"
      else
         echo "Aborting. Please load a ROCm module or specify --rocm-version."
         exit 1
      fi
   fi
fi

# ── GPU architecture detection ───────────────────────────────────────
# If --amdgpu-gfxmodel was provided, use it; otherwise try rocminfo.
if [ -n "${AMDGPU_GFXMODEL_INPUT}" ]; then
   AMDGPU_GFXMODEL="${AMDGPU_GFXMODEL_INPUT}"
else
   AMDGPU_GFXMODEL=$(rocminfo 2>/dev/null | grep gfx | sed -e 's/Name://' | head -1 | sed 's/ //g' || true)
   if [ -z "${AMDGPU_GFXMODEL}" ]; then
      echo "ERROR: No GPU architecture specified and rocminfo is not available or found no GPUs."
      echo "       Please provide --amdgpu-gfxmodel (e.g. --amdgpu-gfxmodel gfx942 or --amdgpu-gfxmodel 'gfx942;gfx90a')"
      exit 1
   fi
fi

if [ "${USE_MAKEFILE}" == 1 ]; then
   exit
fi

# ── Operator-deselection bookkeeping ─────────────────────────────────
# Tracks which packages were forced to BUILD_X=0 by an operator policy
# (--packages whitelist or --quick-installs blacklist), and *why*. The
# --quick-installs and --packages blocks below populate this; the
# run_and_log wrapper consults it so a NOOP_RC=43 from a deselected
# package gets bucketed as DESELECTED (not SKIPPED). Empty for default
# full-sweep runs; in that case run_and_log still hits the SKIPPED(no-op)
# path for any package whose BUILD_X defaulted to 0 (e.g. flang-new,
# x11vnc) -- those genuinely declined themselves, they were not deselected.
#
# Key:   user-facing package name (matches PKG_FLAG keys + run_and_log
#        first arg, e.g. 'pytorch', 'petsc').
# Value: short reason printed in the per-package summary, one of
#        'not-requested' (--packages excluded it) or 'quick-installs'
#        (--quick-installs blacklisted it). When both gates would
#        deselect the same package, --packages wins (it's the more
#        specific user intent and runs last).
declare -A DESELECTED_BY=()

# ── --quick-installs: disable packages whose wall time is >= 20 min ──
# Threshold raised from 15 -> 20 min after the job 8065 sweep (rocm-7.2.1)
# measured petsc at 17:09 and scorep at 16:59, both clearly under the new
# cutoff. The 5-min headroom keeps openmpi (16:29), tau (15:27), and the
# next time it surfaces, jax-on-rocm-6 (was 34m in job 7975) on the right
# sides of the line.
#
# Plus an explicit always-skip set (packages added to QUICK_INSTALLS_PKGS
# regardless of wall time): intellikit. It is heavier (~7 min: clones the
# monorepo, builds the C++ tools, pulls many PyPI deps) and network-dependent;
# it is here as an operator opt-out for the quick-installs iteration loop, NOT
# for the wall-time reason (it is under the 20-min cutoff). Operators who do
# want it in a quick run can pass --packages "... intellikit ..." explicitly:
# --packages always wins over --quick-installs.
#
# NOTE: likwid + mdb were previously in this always-skip set but are now BUILT
# under --quick-installs (they are sub-minute builds and useful by default);
# only intellikit remains an explicit quick-mode opt-out.
#
# Wall-time data sources, newest first (delta is mtime of the per-package
# log file vs. the previous one, in a full --quick-installs 0 run):
#
#   Package      Wall (8065)  Wall (7975)  Wall (7958)  Decision
#   pytorch      90:52        43:39        n/a          SKIP  (>= 20 min)
#   tensorflow   69:57        75:14        n/a          SKIP  (>= 20 min)
#   jax          policy-skip  34:27        n/a          SKIP  (>= 20 min when active)
#   petsc        17:09        15:44        n/a          BUILD (< 20 min, was SKIP at 15-min cutoff)
#   scorep       16:59        15:35        19:33        BUILD (< 20 min, was SKIP at 15-min cutoff;
#                                                              7958 measurement was the closest call)
#   openmpi      16:29        n/a          n/a          BUILD (< 20 min)
#   tau          15:27        10:23         9:42        BUILD (< 20 min)
#   cupy         14:31        14:21        n/a          BUILD (< 20 min)
#   netcdf        8:54         9:24         8:08        BUILD (< 20 min)
#   magma         8:21         7:18        n/a          BUILD (< 20 min)
#   miniconda3    6:32        n/a          n/a          BUILD (< 20 min)
#   hpctoolkit    4:08         4:30        n/a          BUILD (< 20 min)
#   fftw          3:28         4:04         4:01        BUILD (< 20 min)
#   miniforge3    3:08        n/a          n/a          BUILD (< 20 min)
#   hypre         3:13         3:08         2:55        BUILD (< 20 min)
#   hdf5          2:14         2:16         2:17        BUILD (< 20 min)
#   mpi4py        1:41         1:41         1:37        BUILD (< 20 min)
#   kokkos        1:31         0:30        n/a          BUILD (< 20 min)
#   hip-python    1:17         1:20        n/a          BUILD (< 20 min)
#   likwid       <1m          <1m          n/a          BUILD (< 20 min; now built in
#                                                              quick mode too)
#   mdb          <1m          <1m          n/a          BUILD (< 20 min; now built in
#                                                              quick mode too)
#   intellikit   ~7m          n/a          n/a          SKIP  (operator opt-out, not wall:
#                                                              explicit always-skip in
#                                                              QUICK_INSTALLS_PKGS;
#                                                              network-heavy monorepo build)
#   ftorch        0:49        <1m         <1m          SKIP  (transitive: preflight
#                                                              requires pytorch which
#                                                              is itself SKIP-ed)
#   hipfort     bundled     bundled      bundled      SKIP  (rocm-bundled since 6.3+;
#                                                              build-from-source removed
#                                                              from this orchestrator)
#   flang-new   skip-policy  <2m (untar) <2m            BUILD (< 20 min)
#   julia         dormant     dormant      dormant      SKIP  (BUILD_JULIA exists but
#                                                              there is no `run_and_log
#                                                              julia` call below; left
#                                                              in this list as a no-op
#                                                              placeholder so future
#                                                              julia wiring inherits
#                                                              the SKIP default until
#                                                              measured)
#
# This runs AFTER arg parsing so a user could (in theory) re-enable a single
# package by exporting BUILD_<name>=1 between this point and sub-script
# invocation; we don't expose per-package CLI flags here on purpose.
QUICK_INSTALLS_PKGS=( BUILD_PYTORCH BUILD_TENSORFLOW BUILD_JAX BUILD_FTORCH \
                     BUILD_JULIA BUILD_INTELLIKIT )
QUICK_INSTALLS_THRESHOLD_MIN=20
if [[ "${QUICK_INSTALLS}" == "1" ]]; then
   echo ""
   echo "QUICK_INSTALLS=1 -> disabling packages with wall >= ${QUICK_INSTALLS_THRESHOLD_MIN} min:"
   for v in "${QUICK_INSTALLS_PKGS[@]}"; do
      printf "  %-22s %s -> 0\n" "${v}" "${!v}"
      eval "${v}=0"
      # Track which packages were deselected by this gate so the
      # per-package summary can report DESELECTED(quick-installs)
      # instead of SKIPPED(no-op). Mapping BUILD_X -> user-facing
      # name is local here (PKG_FLAG isn't declared until below);
      # a missing case (e.g. BUILD_JULIA) means there is no
      # run_and_log call for that package, so it never reaches the
      # summary anyway. Safe to leave unmapped.
      case "${v}" in
         BUILD_PYTORCH)    DESELECTED_BY[pytorch]="quick-installs" ;;
         BUILD_TENSORFLOW) DESELECTED_BY[tensorflow]="quick-installs" ;;
         BUILD_JAX)        DESELECTED_BY[jax]="quick-installs" ;;
         BUILD_FTORCH)     DESELECTED_BY[ftorch]="quick-installs"
                           # ftorch_amdflang is a sibling run_and_log
                           # entry gated by the same BUILD_FTORCH flag
                           # (see the case-block at the bottom of this
                           # file). Map both so quick-installs gets the
                           # one-line marker for both, not the verbose
                           # 3-line "skipped" banner for ftorch_amdflang.
                           DESELECTED_BY[ftorch_amdflang]="quick-installs" ;;
         BUILD_INTELLIKIT) DESELECTED_BY[intellikit]="quick-installs" ;;
         BUILD_JULIA)      ;;  # dormant: no run_and_log call exists
      esac
   done
   echo ""
fi

# ── --packages: whitelist which packages to build ────────────────────
# Maps user-facing package names to their BUILD_<X> flag variable. Only
# names listed here are recognized by --packages; --packages "openmpi mpi4py"
# turns BUILD_<X>=0 for every package NOT in the list and BUILD_<X>=1 for
# every package that IS on the list (overriding any --quick-installs decision
# that might have turned it off). Order: --quick-installs runs first, then
# --packages, so explicitly whitelisted packages always build.
#
# --packages also accepts a "name=version" suffix for the subset of
# packages whose leaf script exposes a single --<name>-version flag (see
# PKG_VER_FLAG below). The version may be given with an optional leading
# 'v' (e.g. cupy=v13.0.1 and cupy=13.0.1 are equivalent). Repeating the
# same name with different versions ("pytorch=2.7.1 pytorch=2.8.0") drives
# one build per version inside the same job; each lands in its own
# pkg-vVERSION/ install dir + VERSION.lua module so the versions coexist
# (the leaf scripts already key both on their own version variable). A
# bare name with no =version uses the leaf script's internal default
# (unchanged from the original whitelist semantics).
declare -A PKG_FLAG=(
   [flang-new]=BUILD_FLANGNEW
   [openmpi]=BUILD_OPENMPI
   [mpi4py]=BUILD_MPI4PY
   [mvapich]=BUILD_MVAPICH
   [rocshmem]=BUILD_ROCSHMEM
   [rocprof-sys]=BUILD_ROCPROF_SYS
   [rocprof-compute]=BUILD_ROCPROF_COMPUTE
   [hpctoolkit]=BUILD_HPCTOOLKIT
   [likwid]=BUILD_LIKWID
   [mdb]=BUILD_MDB
   [intellikit]=BUILD_INTELLIKIT
   [scorep]=BUILD_SCOREP
   [tau]=BUILD_TAU
   [cupy]=BUILD_CUPY
   [hip-python]=BUILD_HIP_PYTHON
   [tensorflow]=BUILD_TENSORFLOW
   [jax]=BUILD_JAX
   [ftorch]=BUILD_FTORCH
   [pytorch]=BUILD_PYTORCH
   [magma]=BUILD_MAGMA
   [elpa]=BUILD_ELPA
   [kokkos]=BUILD_KOKKOS
   [miniconda3]=BUILD_MINICONDA3
   [miniforge3]=BUILD_MINIFORGE3
   [hipifly]=BUILD_HIPIFLY
   [hdf5]=BUILD_HDF5
   [netcdf]=BUILD_NETCDF
   [fftw]=BUILD_FFTW
   [petsc]=BUILD_PETSC
   [hypre]=BUILD_HYPRE
   [emacs]=BUILD_EMACS
)

# Subset of PKG_FLAG entries whose leaf script exposes a single
# --<name>-version flag. A "--packages name=VER" token is only valid for
# names in this map; the version is forwarded verbatim to the leaf via
# this flag (run_and_log_versioned, defined below, does the splice).
#
# Excluded on purpose:
#   * flang-new, mvapich, rocprof-sys, rocprof-compute, tau, hipifly --
#                no --<name>-version flag in the leaf script today; pinning
#                a version means editing the leaf script (these are mostly
#                track-the-rocm-SDK packages where the version is implicit
#                in the loaded ROCm module, not an independent dimension).
declare -A PKG_VER_FLAG=(
   [openmpi]="--openmpi-version"
   [mpi4py]="--mpi4py-version"
   [rocshmem]="--rocshmem-version"
   [hpctoolkit]="--hpctoolkit-version"
   [likwid]="--likwid-version"
   [mdb]="--mdb-version"
   [intellikit]="--intellikit-version"
   [scorep]="--scorep-version"
   [cupy]="--cupy-version"
   [hip-python]="--hip-python-version"
   [tensorflow]="--tensorflow-version"
   [jax]="--jax-version"
   [ftorch]="--ftorch-version"
   [pytorch]="--pytorch-version"
   [magma]="--magma-version"
   [elpa]="--elpa-version"
   [kokkos]="--kokkos-version"
   [miniconda3]="--miniconda3-version"
   [miniforge3]="--miniforge3-version"
   [hdf5]="--hdf5-version"
   # netcdf: single sweep-CLI knob is --netcdf-c-version. The leaf
   # netcdf_setup.sh auto-derives NETCDF_F_VERSION from NETCDF_C_VERSION
   # via its NETCDF_C_TO_F map (single source of truth for the C->F
   # compatibility matrix). Pass --netcdf-f-version directly to the leaf
   # if you need to override.
   [netcdf]="--netcdf-c-version"
   [fftw]="--fftw-version"
   [petsc]="--petsc-version"
   [hypre]="--hypre-version"
   [emacs]="--emacs-version"
)

# Per-package list of versions requested via --packages name=VER. Unset
# for a name that wasn't on the --packages list (or for the no-whitelist
# default-everything case): run_and_log_versioned then falls back to a
# single iteration with no --<name>-version flag, so the leaf script's
# own default version is used. Multiple versions of the same package are
# stored newline-separated (NOT space-separated, because an empty
# requested-version "" is a meaningful entry meaning "leaf default" --
# space-joining would silently coalesce it with adjacent values; mapfile
# -t on a newline-joined value preserves the empty entry as a distinct
# array element). run_and_log_versioned iterates over the parsed array,
# invoking the leaf script once per version.
declare -A PKG_VERSIONS_REQ=()

# Per-(name, version) inline overrides supplied via the extended
# --packages token syntax: name=version[:override_key=override_value...].
# Key:   "${pkg}|${ver}" (the same shape as PYTORCH_STACK_MANIFEST
#        cells in pytorch_setup.sh, intentional). For a bare-named token
#        with no =version, the key is "${pkg}|" (empty version segment).
# Value: newline-separated "--flag-name=value" records. Each record is
#        the leaf-script flag (resolved by get_override_flag below) and
#        the user-supplied value. run_and_log_versioned splits each
#        record on the FIRST '=' and appends the two halves as separate
#        argv elements to the leaf-script invocation, so values that
#        themselves contain '=' (rare but valid for some package
#        version strings) are preserved.
# Empty for tokens without a ':override' suffix (run_and_log_versioned
# treats "key unset" as "no overrides", same code path as today).
declare -A PKG_VERSION_OVERRIDES=()

# ── Override-key dispatch: maps short/long alias -> leaf-script flag ──
# Only pytorch has a rich override surface today (aotriton, torchvision,
# torchaudio, triton, flashattention, pillow, sageattention, deepspeed,
# plus their short aliases tv/ta/flash/sage/ds). Other versioned
# packages reject any override-key token at parse time: extending them
# means adding a case branch here AND adding the matching --<key>-version
# flag in their leaf script.
#
# Returns 0 + prints the resolved leaf-script flag on stdout for known
# (pkg, key) pairs; returns 1 (no stdout) for unknown ones. Callers
# capture both:
#   if _flag=$(get_override_flag "${name}" "${k}"); then ... ; fi
get_override_flag() {
   local pkg="$1" key="$2"
   local flag=""
   case "${pkg}" in
      pytorch)
         case "${key}" in
            aotriton)             flag="--aotriton-version" ;;
            torchvision|tv)       flag="--torchvision-version" ;;
            torchaudio|ta)        flag="--torchaudio-version" ;;
            triton)               flag="--triton-version" ;;
            flashattention|flash) flag="--flashattention-version" ;;
            pillow)               flag="--pillow-version" ;;
            sageattention|sage)   flag="--sageattention-version" ;;
            deepspeed|ds)         flag="--deepspeed-version" ;;
         esac
         ;;
   esac
   if [[ -z "${flag}" ]]; then
      return 1
   fi
   echo "${flag}"
   return 0
}

PACKAGES_NORM="${PACKAGES_INPUT//,/ }"
read -r -a PACKAGES_ARR <<< "${PACKAGES_NORM}"

if (( ${#PACKAGES_ARR[@]} > 0 )); then
   # Three-phase validation:
   #   1. Split each token on the first ':' into (pre, override_str).
   #      pre is the existing "name[=VERSION]" form; override_str is a
   #      ':'-separated list of "key=value" pairs (e.g.
   #      "pytorch=2.8.0:flash=2.7.4:tv=0.22.1"). ':' is safe as a
   #      separator because PEP 440 / semver versions and PKG_FLAG
   #      package names never contain ':'.
   #   2. Split pre at the first '=' into (name, version). Strip a
   #      leading 'v' from version (cupy=v13.0.1 and cupy=13.0.1 are
   #      equivalent; v prefix is the user-facing "release tag" form,
   #      bare semver is what the leaf scripts pass downstream).
   #   3. Reject any name not in PKG_FLAG, any versioned token whose
   #      name is not in PKG_VER_FLAG, and any override key that
   #      get_override_flag doesn't recognize for that package. All
   #      three error kinds are reported together so a single failed
   #      run lists every problem.
   UNKNOWN_PKGS=()
   VER_UNSUPPORTED=()
   UNKNOWN_OVERRIDES=()
   declare -a PARSED_NAMES=()
   declare -a PARSED_VERSIONS=()
   declare -a PARSED_OVERRIDES=()
   for p in "${PACKAGES_ARR[@]}"; do
      if [[ "${p}" == *:* ]]; then
         _pre="${p%%:*}"
         _override_str="${p#*:}"
      else
         _pre="${p}"
         _override_str=""
      fi
      if [[ "${_pre}" == *=* ]]; then
         _name="${_pre%%=*}"
         _ver="${_pre#*=}"
         _ver="${_ver#v}"
      else
         _name="${_pre}"
         _ver=""
      fi
      if [[ -z "${PKG_FLAG[${_name}]:-}" ]]; then
         UNKNOWN_PKGS+=("${p}")
         continue
      fi
      if [[ -n "${_ver}" && -z "${PKG_VER_FLAG[${_name}]:-}" ]]; then
         VER_UNSUPPORTED+=("${p}")
         continue
      fi
      _override_records=""
      if [[ -n "${_override_str}" ]]; then
         declare -a _override_chunks=()
         IFS=':' read -ra _override_chunks <<< "${_override_str}"
         for _chunk in "${_override_chunks[@]}"; do
            [[ -z "${_chunk}" ]] && continue
            if [[ "${_chunk}" != *=* ]]; then
               UNKNOWN_OVERRIDES+=("${p}: '${_chunk}' (missing '=')")
               continue
            fi
            _ok="${_chunk%%=*}"
            _ov="${_chunk#*=}"
            if _resolved_flag=$(get_override_flag "${_name}" "${_ok}"); then
               if [[ -z "${_override_records}" ]]; then
                  _override_records="${_resolved_flag}=${_ov}"
               else
                  _override_records+=$'\n'"${_resolved_flag}=${_ov}"
               fi
            else
               UNKNOWN_OVERRIDES+=("${p}: unknown override key '${_ok}' for package '${_name}'")
            fi
         done
      fi
      PARSED_NAMES+=("${_name}")
      PARSED_VERSIONS+=("${_ver}")
      PARSED_OVERRIDES+=("${_override_records}")
   done
   if (( ${#UNKNOWN_PKGS[@]} > 0 )) || (( ${#VER_UNSUPPORTED[@]} > 0 )) || (( ${#UNKNOWN_OVERRIDES[@]} > 0 )); then
      if (( ${#UNKNOWN_PKGS[@]} > 0 )); then
         echo "ERROR: --packages contains unknown name(s): ${UNKNOWN_PKGS[*]}" >&2
         echo "       Recognized names: ${!PKG_FLAG[*]}" >&2
      fi
      if (( ${#VER_UNSUPPORTED[@]} > 0 )); then
         echo "ERROR: --packages contains name=VERSION token(s) for packages whose leaf script has no single --<name>-version flag:" >&2
         echo "       ${VER_UNSUPPORTED[*]}" >&2
         echo "       Versioned syntax is supported for: ${!PKG_VER_FLAG[*]}" >&2
      fi
      if (( ${#UNKNOWN_OVERRIDES[@]} > 0 )); then
         echo "ERROR: --packages contains unknown override key(s):" >&2
         for _err in "${UNKNOWN_OVERRIDES[@]}"; do
            echo "       ${_err}" >&2
         done
         echo "       Override keys are recognized only for: pytorch" >&2
         echo "       Pytorch keys: aotriton, torchvision (alias tv), torchaudio (alias ta)," >&2
         echo "                     triton, flashattention (alias flash), pillow," >&2
         echo "                     sageattention (alias sage), deepspeed (alias ds)" >&2
      fi
      exit 1
   fi

   echo ""
   echo "PACKAGES whitelist active. Disabling all packages, then enabling:"
   # Disable every gated package first.
   for flag in "${PKG_FLAG[@]}"; do
      eval "${flag}=0"
   done
   # Mark every gated package as deselected (will be cleared below
   # for the whitelisted ones). 'not-requested' overrides any earlier
   # 'quick-installs' marker because --packages is the more specific
   # user intent and runs second.
   for p in "${!PKG_FLAG[@]}"; do
      DESELECTED_BY[${p}]="not-requested"
   done
   # Then enable the requested ones (overrides --quick-installs). The
   # PARSED_NAMES / PARSED_VERSIONS / PARSED_OVERRIDES arrays are aligned
   # (same length, same order) so a single index walks all three.
   # Repeated names accumulate into PKG_VERSIONS_REQ as a newline-
   # separated list (with dedup); inline overrides land in
   # PKG_VERSION_OVERRIDES keyed on "${name}|${ver}" so the same name
   # can carry different overrides for different versions.
   for ((_i = 0; _i < ${#PARSED_NAMES[@]}; _i++)); do
      _name="${PARSED_NAMES[${_i}]}"
      _ver="${PARSED_VERSIONS[${_i}]}"
      _ovr="${PARSED_OVERRIDES[${_i}]}"
      flag="${PKG_FLAG[${_name}]}"
      if [[ -n "${_ver}" ]]; then
         if [[ -n "${_ovr}" ]]; then
            _ovr_count=$(printf '%s\n' "${_ovr}" | grep -c '^--')
            printf "  %-18s -> %s=1 (version %s, %d override(s))\n" "${_name}" "${flag}" "${_ver}" "${_ovr_count}"
         else
            printf "  %-18s -> %s=1 (version %s)\n" "${_name}" "${flag}" "${_ver}"
         fi
      else
         if [[ -n "${_ovr}" ]]; then
            _ovr_count=$(printf '%s\n' "${_ovr}" | grep -c '^--')
            printf "  %-18s -> %s=1 (leaf default version, %d override(s))\n" "${_name}" "${flag}" "${_ovr_count}"
         else
            printf "  %-18s -> %s=1 (leaf default)\n" "${_name}" "${flag}"
         fi
      fi
      eval "${flag}=1"
      # Clear the deselection marker for whitelisted packages so they
      # land in OK / FAILED / SKIPPED depending on the actual outcome.
      unset "DESELECTED_BY[${_name}]"
      # Append the requested version (possibly empty) to this package's
      # list, newline-separated. Empty + concrete versions can coexist:
      # bare `pytorch` and `pytorch=2.7.1` together yield two builds
      # (leaf-default + 2.7.1) -- this works because mapfile -t in the
      # consumer preserves empty entries as distinct array elements.
      # Dedup on the EXACT (name,version) pair so repeating the same
      # token is a no-op rather than building twice into the same dir.
      # The +SET test distinguishes "key never set" from "key set to
      # empty string" (representing a bare token with no version).
      if [[ -z "${PKG_VERSIONS_REQ[${_name}]+SET}" ]]; then
         PKG_VERSIONS_REQ[${_name}]="${_ver}"
      else
         _dup=0
         while IFS= read -r _existing; do
            if [[ "${_existing}" == "${_ver}" ]]; then
               _dup=1
               break
            fi
         done <<< "${PKG_VERSIONS_REQ[${_name}]}"
         if (( _dup == 0 )); then
            PKG_VERSIONS_REQ[${_name}]+=$'\n'"${_ver}"
         fi
      fi
      # Stash overrides keyed on (name,version). If the same (name,
      # version) appears more than once with different override sets
      # (e.g. user typo), the LAST occurrence wins -- consistent with
      # CLI argument-list semantics where last write wins.
      if [[ -n "${_ovr}" ]]; then
         PKG_VERSION_OVERRIDES["${_name}|${_ver}"]="${_ovr}"
      fi
   done
   unset _i _name _ver _ovr _ovr_count _existing _dup
   # Sibling-name propagation: a few user-facing names spawn more than
   # one run_and_log entry (e.g. `ftorch` builds both `ftorch` and
   # `ftorch_amdflang` when FTORCH_FC_COMPILER=both). Mirror the
   # deselection state of the canonical name onto its siblings so the
   # per-package summary doesn't surface the verbose 3-line "skipped"
   # banner for packages the user never asked about. Also mirror
   # PKG_VERSIONS_REQ so a versioned `ftorch=0.7` request drives BOTH
   # the gfortran AND amdflang sibling call sites at the same version
   # (the user-facing "ftorch" name is one knob; FTORCH_FC_COMPILER
   # toolchain split is internal).
   if [[ -n "${DESELECTED_BY[ftorch]:-}" ]]; then
      DESELECTED_BY[ftorch_amdflang]="${DESELECTED_BY[ftorch]}"
   else
      unset "DESELECTED_BY[ftorch_amdflang]"
   fi
   if [[ -n "${PKG_VERSIONS_REQ[ftorch]:-}" ]]; then
      PKG_VERSIONS_REQ[ftorch_amdflang]="${PKG_VERSIONS_REQ[ftorch]}"
   fi

   # ── Build-dependency expansion (Cray) ────────────────────────────────
   # Parallel-Fortran HDF5/netcdf with the new LLVM Flang (amdflang / ftn on
   # ROCm 7.x) need a Fortran mpi.mod in the NEW-flang format. cray-mpich
   # ships only classic-Flang V34 mpi.mod (unreadable by new flang), so they
   # depend on the mpich-wrappers build (standalone MPICH w/ FC=amdflang).
   # netcdf additionally depends on hdf5 (it links libhdf5 + reuses hdf5's
   # HDF5_*_COMPILER / HDF5_MPI_MODULE). When the operator whitelists one of
   # these on a Cray but not its build deps, pull them in automatically so
   # `--packages netcdf` (or `--packages hdf5`) yields a working
   # parallel-Fortran build instead of SKIPping (no MPI) or silently falling
   # back to cray-mpich. Only on a Cray (CRAY_MPICH_VERSION set or
   # /opt/cray/pe/mpich present); a no-op elsewhere. netcdf is handled first
   # so enabling hdf5 cascades into the mpich-wrappers rule below.
   _is_cray_pe=0
   { [ -n "${CRAY_MPICH_VERSION:-}" ] || [ -d /opt/cray/pe/mpich ]; } && _is_cray_pe=1
   if [[ "${BUILD_NETCDF}" == "1" ]] && [[ "${BUILD_HDF5}" != "1" ]] && [ "${_is_cray_pe}" = "1" ]; then
      echo "  netcdf requested on a Cray -> auto-enabling hdf5 dependency (parallel HDF5 + new-flang .mod)"
      BUILD_HDF5=1
      unset "DESELECTED_BY[hdf5]"
   fi
   if [[ "${BUILD_HDF5}" == "1" ]] && [[ "${BUILD_MPICH_WRAPPERS}" != "1" ]] && [ "${_is_cray_pe}" = "1" ]; then
      echo "  hdf5 requested on a Cray -> auto-enabling mpich-wrappers dependency (new-flang mpi.mod)"
      BUILD_MPICH_WRAPPERS=1
      unset "DESELECTED_BY[mpich-wrappers]"
   fi
   unset _is_cray_pe
   echo ""
fi

# ── Logging setup ────────────────────────────────────────────────────
# Per-package logs go under logs_<date>/rocm-<version>_<jobid>/ so that
# concurrent or sequential same-day sweep jobs don't trample each other's
# log_<pkg>_<date>.txt files. Audited as P2 in slurm-7934-rocmplus-7.0.2.out:
# log_openmpi_04_30_2026.txt from job 7934 was overwritten by job 7935
# within minutes of 7934 ending, leaving us with no openmpi log for 7934.
# SLURM_JOB_ID is set in sbatch context; falls back to pid for ad-hoc runs.
TODAY=$(date +%m_%d_%Y)
LOG_DIR="${PWD}/logs_${TODAY}/rocm-${ROCM_VERSION}_${SLURM_JOB_ID:-pid$$}"
mkdir -p "${LOG_DIR}"

# Per-package outcome tracking. Three buckets:
#   SUCCESS_PKGS  -- built or already-installed and verified clean.
#   FAILED_PKGS   -- the setup script exited non-zero. Partial install
#                    artifacts are wiped automatically (unless
#                    --keep-failed-installs 1) so a re-run starts clean.
#   SKIPPED_PKGS  -- a declared dependency failed or was skipped, so the
#                    build was not even attempted.
#
# Without this, a failed sub-script silently returned rc=0 (because
# `tee` was the last command in the pipe), and main_setup.sh advertised
# success even when xpmem / pnetcdf / openmpi etc. blew up. Audited as
# P3 in slurm-7865-rocmplus-7.0.2.out.

# 2026-05-05: split SKIPPED_PKGS into two distinct buckets so the
# per-package summary tells the operator WHY a package wasn't built.
# DESELECTED_PKGS captures the operator-policy cases (--packages
# whitelist excluded the package, or --quick-installs blacklisted it),
# leaving SKIPPED_PKGS for genuine "couldn't build" cases (preflight
# missing, distro mismatch, --install-from-source 0). Without this
# split, a single-package run like --packages petsc reported "SKIPPED
# (24): pytorch(no-op) tensorflow(no-op) ..." which read like 24
# things went wrong, when in fact the operator deliberately deselected
# them. The associated DESELECTED_BY map (declared below) records the
# reason ('not-requested' or 'quick-installs') so the bucket label is
# specific. See run_and_log's NOOP_RC branch for the dispatch logic.
FAILED_PKGS=()
SUCCESS_PKGS=()
SKIPPED_PKGS=()
DESELECTED_PKGS=()

# NOTE: the cleanup_pkg() helper, the PKG_CLEAN_DIRS / PKG_CLEAN_MODS
# lookup tables, and the replace_pkg() pre-install helper that used to
# live here have all been removed. Their job (per-package install +
# modulefile removal on --replace-existing 1, fail-cleanup of partial
# installs) is now done by each setup script's own --replace flag and
# EXIT trap (canonical template: extras/scripts/hypre_setup.sh).
# main_setup.sh now just threads `--replace ${REPLACE_EXISTING}
# --keep-failed-installs ${KEEP_FAILED_INSTALLS}` (= ${REPLACE_OPTS},
# defined further below near COMMON_OPTIONS) into every migrated
# run_and_log invocation. The install-path knowledge lives in exactly
# one place per package, so the layout cannot drift.

# Sentinel return codes for setup scripts. Both reclassify the result as
# SKIPPED (not FAILED) and do not force a non-zero overall exit on their
# own. Distinguished so the per-package summary tells the operator WHY
# the package was skipped:
#
#   MISSING_PREREQ_RC=42 -- preflight_modules failed: a required module
#       wasn't loadable (e.g., openmpi failed earlier so its module was
#       never written, or the user typoed a module name). Each setup
#       script defines its own copy of this constant (see e.g.
#       comm/scripts/openmpi_setup.sh); kept in sync by convention.
#
#   NOOP_RC=43 -- the setup script intentionally declined to do anything
#       (e.g., mvapich on Ubuntu where the install path isn't
#       implemented; rocprof-sys/rocprof-compute when their
#       --install-from-source flag is 0 because the SDK already ships
#       these tools). The script ran cleanly to its no-op exit; no
#       artifacts to clean up. Audited as P5 in
#       slurm-7934-rocmplus-7.0.2.out: those scripts were misclassified
#       as OK, making the summary lie about what was actually built.
MISSING_PREREQ_RC=42
NOOP_RC=43

run_and_log() {
   local log_name="$1"
   shift
   # PIPESTATUS[0] is the exit status of the actual sub-script (before tee).
   "$@" 2>&1 | tee "${LOG_DIR}/log_${log_name}_${TODAY}.txt"
   local rc=${PIPESTATUS[0]}
   if [ "${rc}" -eq 0 ]; then
      SUCCESS_PKGS+=("${log_name}")
   elif [ "${rc}" -eq "${MISSING_PREREQ_RC}" ]; then
      # The sub-script's preflight_modules call failed: a required
      # module wasn't available. Treat as SKIPPED, not FAILED.
      # No cleanup -- the script aborted before installing anything.
      SKIPPED_PKGS+=("${log_name}(missing-prereq)")
      echo ""
      echo "### SKIP ${log_name}: a required module was not available."
      echo "### See ${LOG_DIR}/log_${log_name}_${TODAY}.txt for which module."
      echo "### No artifacts created; nothing to clean up."
      echo ""
   elif [ "${rc}" -eq "${NOOP_RC}" ]; then
      # The sub-script exited NOOP_RC (intentional no-op). Two distinct
      # reasons share this rc; we use the DESELECTED_BY map (populated
      # by the --packages / --quick-installs blocks above) to tell them
      # apart so the per-package summary is precise:
      #
      # 1. DESELECTED -- operator policy: --packages whitelist excluded
      #    this name, or --quick-installs blacklisted it as a long-pole
      #    build. The leaf script's BUILD_X=0 short-circuit ran cleanly
      #    and printed its own "[<pkg> BUILD_X=0] operator opt-out"
      #    line; the verbose three-line ### SKIP banner below would be
      #    redundant noise (24x for a single-package run), so we just
      #    emit a one-line marker.
      #
      # 2. SKIPPED (no-op) -- script declined itself: unsupported
      #    distro (e.g. mvapich on Ubuntu), --install-from-source 0
      #    when the SDK already ships the tool (rocprof-sys/compute),
      #    or BUILD_X defaulted to 0 in main_setup.sh (flang-new,
      #    x11vnc) without any operator gate having flipped it. These
      #    are non-obvious so the verbose banner is kept.
      if [[ -n "${DESELECTED_BY[${log_name}]:-}" ]]; then
         DESELECTED_PKGS+=("${log_name}(${DESELECTED_BY[${log_name}]})")
         echo ""
         echo "### deselected: ${log_name} (${DESELECTED_BY[${log_name}]})"
         echo ""
      else
         SKIPPED_PKGS+=("${log_name}(no-op)")
         echo ""
         echo "### SKIP ${log_name}: setup script intentionally declined to install."
         echo "### See ${LOG_DIR}/log_${log_name}_${TODAY}.txt for the reason."
         echo "### No artifacts created; nothing to clean up."
         echo ""
      fi
   else
      FAILED_PKGS+=("${log_name}(rc=${rc})")
      echo ""
      echo "######################################################"
      echo "### WARNING: ${log_name} setup script exited rc=${rc}."
      echo "### See ${LOG_DIR}/log_${log_name}_${TODAY}.txt for details."
      echo "### main_setup.sh will continue with remaining packages."
      echo "### Packages whose preflight requires ${log_name}'s module"
      echo "### will mark themselves SKIPPED on entry."
      echo "### main_setup.sh will exit non-zero at the end."
      echo "######################################################"
      echo ""
      # NOTE: per-package fail-cleanup is now done inside each setup
      # script's own EXIT trap (template established in
      # extras/scripts/hypre_setup.sh, controlled by --replace and
      # --keep-failed-installs flags threaded through REPLACE_OPTS).
      # The previous cleanup_pkg() helper + PKG_CLEAN_DIRS/MODS lookup
      # tables were removed because they had drifted out of sync with
      # the actual install layouts during the per-package versioning
      # pass; the install-path knowledge now lives in exactly one
      # place: each setup script.
   fi
   return ${rc}
}

# Multi-version variant of run_and_log: invokes the leaf script once per
# requested version of <pkg_name> (consulting the PKG_VERSIONS_REQ map
# populated by the --packages parser above). Used at the call sites of
# version-capable packages -- the subset whose names appear in
# PKG_VER_FLAG (pytorch, jax, cupy, magma, kokkos, ...).
#
# Three cases drive the loop body:
#   * No requested versions for <pkg_name> (bare token, package not in
#     --packages whitelist, or no --packages given at all): one call
#     with NO --<name>-version flag and label = "${pkg_name}". This is
#     byte-identical to the prior single-call wiring; the leaf script
#     uses its own internal default version. Behavior is preserved for
#     all existing operator workflows.
#   * One requested version: one call with "--<pkg>-version VER" appended
#     and label = "${pkg_name}_v${VER}". Per-package log file becomes
#     log_<pkg>_v<VER>_<date>.txt; per-package summary line becomes
#     "OK (1): <pkg>_v<VER>". Install lands in pkg-v${VER}/ (the leaf
#     scripts already key both the install dir AND the .lua module
#     filename on their PKG_VERSION variable, so this is purely a
#     plumbing change at the orchestrator level).
#   * Multiple requested versions: one call per version, each in
#     submission order. Each gets its own log file, its own summary
#     line, and its own install dir + module. A failure in one version
#     does NOT stop the next from being attempted (run_and_log records
#     it and returns; we keep iterating).
#
# DESELECTED_BY propagation: when the bare name is deselected (BUILD_X=0
# from --quick-installs or --packages), we mirror the marker to each
# per-version label so run_and_log's NOOP_RC=43 branch reports the
# concise one-line "deselected" form for every iteration instead of the
# verbose 3-line "SKIP" banner. The leaf scripts return NOOP_RC=43 on
# BUILD_X=0 short-circuit, so all iterations land cleanly in the same
# bucket.
#
# Usage: run_and_log_versioned <pkg_name> <leaf_script> <args...>
#        (Same calling convention as run_and_log -- args are word-split
#        at the call site, so unquoted ${COMMON_OPTIONS} expansions etc.
#        flow through unchanged.)
run_and_log_versioned() {
   local pkg_name="$1"; shift
   local leaf_script="$1"; shift
   local ver_flag="${PKG_VER_FLAG[${pkg_name}]:-}"
   local -a versions
   if [[ -z "${PKG_VERSIONS_REQ[${pkg_name}]+SET}" ]]; then
      # No --packages whitelist or this name isn't in it: do one call
      # with no version flag (leaf-default behavior, byte-identical to
      # the prior single-call wiring).
      versions=("")
   else
      # Parser populated this name's entry as a newline-separated list
      # of requested versions. mapfile -t preserves empty entries (which
      # mean "leaf default") as distinct array elements -- bare and
      # versioned tokens for the same name coexist in the loop.
      mapfile -t versions <<< "${PKG_VERSIONS_REQ[${pkg_name}]}"
   fi
   local v label override_records
   local -a override_args
   for v in "${versions[@]}"; do
      # Look up inline overrides supplied via --packages
      # name=version:override_key=override_value... The key shape
      # ("${pkg_name}|${v}") matches PYTORCH_STACK_MANIFEST cells in
      # pytorch_setup.sh. Each record is "--flag-name=value"; split on
      # the FIRST '=' so values that themselves contain '=' (rare but
      # possible) are preserved as a single argv element.
      override_args=()
      override_records="${PKG_VERSION_OVERRIDES["${pkg_name}|${v}"]:-}"
      if [[ -n "${override_records}" ]]; then
         local _rec _of _ov
         while IFS= read -r _rec; do
            [[ -z "${_rec}" ]] && continue
            _of="${_rec%%=*}"
            _ov="${_rec#*=}"
            override_args+=("${_of}" "${_ov}")
         done <<< "${override_records}"
      fi
      if [[ -z "${v}" ]]; then
         label="${pkg_name}"
         run_and_log "${label}" "${leaf_script}" "$@" "${override_args[@]}"
      else
         label="${pkg_name}_v${v}"
         # Mirror the deselection marker so run_and_log's NOOP branch
         # buckets this iteration as DESELECTED, not SKIPPED(no-op).
         if [[ -n "${DESELECTED_BY[${pkg_name}]:-}" ]]; then
            DESELECTED_BY[${label}]="${DESELECTED_BY[${pkg_name}]}"
         fi
         run_and_log "${label}" "${leaf_script}" "$@" "${ver_flag}" "${v}" "${override_args[@]}"
      fi
   done
}

# Print a per-run summary on EXIT and propagate failure as a non-zero
# exit code. Critical for the rocmplus sweep: dependent jobs use
# --dependency=afterany so the chain proceeds either way, but we still
# want sacct + the slurm log to clearly mark which versions had package
# failures. SKIPPED alone does NOT force non-zero -- the chain ran
# cleanly given the constraint imposed by the actual FAILED package.
final_summary() {
   local saved_rc=$?
   # Clean up the self-copy from the top-of-file guard, if any.
   # Folded in here (rather than as a separate EXIT trap) because bash
   # `trap ... EXIT` would replace this trap, not chain. Done first so
   # both exit paths below pick it up before they call `exit`.
   [[ -n "${MAIN_SETUP_SELFCOPIED:-}" ]] && rm -f -- "${MAIN_SETUP_SELFCOPIED}"
   echo ""
   echo "=================================================================="
   echo "  main_setup.sh per-package summary for rocm-${ROCM_VERSION:-?}"
   echo "=================================================================="
   if [ ${#SUCCESS_PKGS[@]} -gt 0 ]; then
      printf "  %-10s (%d): %s\n" "OK"         "${#SUCCESS_PKGS[@]}"    "${SUCCESS_PKGS[*]}"
   fi
   if [ ${#DESELECTED_PKGS[@]} -gt 0 ]; then
      printf "  %-10s (%d): %s\n" "DESELECTED" "${#DESELECTED_PKGS[@]}" "${DESELECTED_PKGS[*]}"
   fi
   if [ ${#SKIPPED_PKGS[@]} -gt 0 ]; then
      printf "  %-10s (%d): %s\n" "SKIPPED"    "${#SKIPPED_PKGS[@]}"    "${SKIPPED_PKGS[*]}"
   fi
   if [ ${#FAILED_PKGS[@]} -gt 0 ]; then
      printf "  %-10s (%d): %s\n" "FAILED"     "${#FAILED_PKGS[@]}"     "${FAILED_PKGS[*]}"
      echo "=================================================================="
      # Real failure: force exit 1 so the slurm sbatch reports an
      # unambiguous "FAILED 1:0" in sacct, regardless of which leaf script
      # ran last. Was previously `[ "${saved_rc}" -eq 0 ] && exit 1` which
      # propagated `saved_rc` when non-zero -- that meant a chain that
      # had a real failure earlier but ended on a NOOP_RC=43 deselected
      # leaf would propagate 43, and sacct would tag the whole job as
      # "FAILED 43:0" which visually looks identical to the all-deselected
      # no-failure case (also 43, but caught by the `else` branch below).
      # Always-1 collapses both ambiguity classes into a single
      # "real-failure" exit code that pairs cleanly with the per-package
      # summary above.
      exit 1
   else
      echo "=================================================================="
      # No real failures: every package landed in OK, DESELECTED, or
      # SKIPPED. The orchestrator ran cleanly; force rc=0 so slurm
      # reports COMPLETED instead of FAILED. Without this override,
      # saved_rc is whatever the LAST run_and_log returned -- which is
      # often NOOP_RC=43 (a deselected package processed last in the
      # alphabetic call order) or MISSING_PREREQ_RC=42 (a transitively
      # skipped package). Both got mis-reported as "FAILED 43:0" /
      # "FAILED 42:0" by sacct, contradicting the per-package summary
      # right above it. Single-package rebuilds (--packages petsc,
      # job 8313 on therock-23.2.0) were the most visible victims:
      # petsc itself succeeded but the job was tagged FAILED because
      # ftorch (the last call in the chain) had BUILD_FTORCH=0.
      # The per-package summary above is the source of truth for what
      # was/wasn't built; the slurm exit code just answers "did the
      # orchestrator finish without an internal error".
      exit 0
   fi
}
trap final_summary EXIT

# ── Configuration summary ────────────────────────────────────────────
# Computed early (also recomputed below at the canonical ROCMPLUS_SUFFIX
# assignment so the existing dependent code stays unchanged). Needed
# here so the info block can show the concrete destination paths the
# operator is about to write to.
#
# For afar trees (ROCM_RC_PREFIX='afar' AND ROCM_RC_COMPILER non-empty)
# the suffix is afar-<compiler>-<rocm_numeric>; for everything else it
# falls back to the legacy <prefix>-<numeric> shape (numeric alone for
# regular releases).
if [ "${ROCM_RC_PREFIX}" = "afar" ] && [ -n "${ROCM_RC_COMPILER}" ]; then
   _RPS_PREVIEW="afar-${ROCM_RC_COMPILER}-${ROCM_VERSION}"
else
   _RPS_PREVIEW="${ROCM_RC_PREFIX:+${ROCM_RC_PREFIX}-}${ROCM_VERSION}"
fi
# cray flavor lands in the separate rocmplus-cray-<suffix> tree (see
# ROCMPLUS_FLAVOR note above + the canonical assignment below).
[ "${ROCMPLUS_FLAVOR}" = "cray" ] && _RPS_PREVIEW="cray-${_RPS_PREVIEW}"

echo ""
echo "=================================================================="
echo "  rocmplus install plan"
echo "=================================================================="
echo "  ROCm version      : ${ROCM_VERSION}"
echo "  ROCM_RC_PREFIX    : '${ROCM_RC_PREFIX}'   (install/module suffix: rocmplus-${_RPS_PREVIEW})"
echo "  ROCM_RC_COMPILER  : '${ROCM_RC_COMPILER}'   (afar trees only; embedded in rocmplus suffix above)"
echo "  ROCMPLUS_FLAVOR   : '${ROCMPLUS_FLAVOR}'   (amd -> rocmplus-<suffix>; cray -> rocmplus-cray-<suffix>)"
echo "  AMDGPU_GFXMODEL   : ${AMDGPU_GFXMODEL}"
echo "  PYTHON_VERSION    : 3.${PYTHON_VERSION}"
echo "  DISTRO            : ${DISTRO} ${DISTRO_VERSION}"
echo ""
echo "  --- Path resolution (CLI > --site preset > derived > default) ---"
printf "  %-22s %s\n" "--site"               "${SITE:-<unset>}${SITE_CLI:+ (CLI)}"
printf "  %-22s %s\n" "--rocm-path"          "${ROCM_PATH:-<unset>}   (${ROCM_PATH_SOURCE:-<none>})"
printf "  %-22s %s\n" "--top-install-path"   "${TOP_INSTALL_PATH}   (${TOP_INSTALL_PATH_SOURCE:-default})"
printf "  %-22s %s\n" "--top-module-path"    "${TOP_MODULE_PATH}   (${TOP_MODULE_PATH_SOURCE:-default})"
printf "  %-22s %s\n" "--rocm-install-path"  "${ROCM_INSTALLPATH}   (${ROCM_INSTALLPATH_SOURCE:-default})"
echo ""
echo "  --- Where things will be written ---"
echo "    rocmplus packages -> ${TOP_INSTALL_PATH}/rocmplus-${_RPS_PREVIEW}/<pkg>-v<ver>/"
echo "    rocmplus modules  -> ${TOP_MODULE_PATH}/rocmplus-${_RPS_PREVIEW}/<pkg>/<ver>.lua"
echo "    rocm SDK (if rebuilt) -> ${ROCM_INSTALLPATH}/rocm-${ROCM_VERSION}/"
echo "    shared modules    -> ${TOP_MODULE_PATH}/base/  (miniconda3, miniforge3)"
echo "    Per-job log dir     -> ${LOG_DIR}"
echo ""
echo "  --- Knobs ---"
printf "  %-22s %s\n" "QUICK_INSTALLS"   "${QUICK_INSTALLS}"
printf "  %-22s %s\n" "REPLACE_EXISTING" "${REPLACE_EXISTING}"
printf "  %-22s %s\n" "KEEP_FAILED"      "${KEEP_FAILED_INSTALLS}"
printf "  %-22s %s\n" "PACKAGES"         "${PACKAGES_INPUT:-<all>}"
echo "=================================================================="
echo ""

unset _RPS_PREVIEW

# The interactive confirmation prompt is skipped when stdin is not a
# TTY (i.e. when invoked from sbatch / a pipe), because there's no one
# to answer it -- the previous behavior was to ECHO the prompt and
# then wait 30s for a read() that could never return on /dev/null
# input, which just added 30s of misleading log spam to every batch
# job. When invoked interactively (e.g. ssh login + direct
# main_setup.sh) the prompt still fires.
if [ -t 0 ]; then
   echo -n "Does this look correct? [Y/n] (default Y, continuing in 30s) "
   if read -r -t 30 CONFIRM; then
      if [[ "${CONFIRM}" =~ ^[Nn]$ ]]; then
         echo "Aborting."
         exit 1
      fi
   else
      echo ""
      echo "No response received, assuming yes..."
   fi
fi

# ── Derived paths ────────────────────────────────────────────────────
# ROCMPLUS_SUFFIX is the suffix used after `rocmplus-` for both install
# dirs and module category dirs. Three shapes:
#   * Regular release:   ROCM_RC_PREFIX='' + ROCM_RC_COMPILER=''
#                        -> ROCMPLUS_SUFFIX=${ROCM_VERSION}
#                        (byte-identical to prior behavior)
#   * AFAR family:       ROCM_RC_PREFIX='afar' + ROCM_RC_COMPILER non-empty
#                        -> ROCMPLUS_SUFFIX=afar-${COMPILER}-${ROCM_VERSION}
#                        (compiler-AND-rocm-keyed; two AFAR drops with the
#                        same SDK numeric but different compiler releases
#                        can't collide on the rocmplus side)
#   * Other RC trees:    ROCM_RC_PREFIX non-empty + ROCM_RC_COMPILER=''
#                        (e.g. ROCM_RC_PREFIX='therock')
#                        -> ROCMPLUS_SUFFIX=${PREFIX}-${ROCM_VERSION}
# In all three cases the family-prefix in the suffix guarantees that a
# release-candidate install can't collide with a future official rocm
# release of the same numeric version (no upstream release has a
# 'therock-' or 'afar-' family prefix).
if [ "${ROCM_RC_PREFIX}" = "afar" ] && [ -n "${ROCM_RC_COMPILER}" ]; then
   ROCMPLUS_SUFFIX="afar-${ROCM_RC_COMPILER}-${ROCM_VERSION}"
else
   ROCMPLUS_SUFFIX="${ROCM_RC_PREFIX:+${ROCM_RC_PREFIX}-}${ROCM_VERSION}"
fi
# PrgEnv-cray-new ecosystem: prepend "cray-" so the install + module
# category dirs become rocmplus-cray-<suffix>, matching the tree
# emit_cray_prgenv_ecosystem() (leaf_modulefile_helpers.sh) points the
# PrgEnv-cray-new MODULEPATH at. Default flavor "amd" leaves the suffix
# untouched (byte-identical legacy behavior).
if [ "${ROCMPLUS_FLAVOR}" = "cray" ]; then
   ROCMPLUS_SUFFIX="cray-${ROCMPLUS_SUFFIX}"
fi
ROCMPLUS="${TOP_INSTALL_PATH}/rocmplus-${ROCMPLUS_SUFFIX}"

# ── Bring the destination rocmplus-<v> modulefile dir to the front of ─
# MODULEPATH so freshly-built modules win over any pre-existing copies
# of the same package elsewhere on MODULEPATH (e.g. a legacy
# /shared/apps/.../rocmplus-${ROCM_VERSION} tree that the rocm/<v>
# system modulefile added). Without this, an unversioned
# `module load hdf5` inside a leaf script (netcdf_setup.sh, petsc_setup.sh,
# etc.) can resolve to an older hdf5 from a different tree and link
# the downstream package against it -- exact failure mode: job 9712,
# netcdf-c v4.10.0 unintentionally linked against
# /shared/apps/.../hdf5-v1.14.6 because the system rocm/7.2.3
# modulefile added that tree before /nfsapps/.../rocmplus-7.2.3 was
# anywhere on MODULEPATH.
#
# Direct env-var prepend (not `module use`) for portability: this script
# is re-exec'd via `/bin/bash` at the top-of-file self-copy guard, which
# can drop the `module` shell function. Lmod reads MODULEPATH from the
# environment, so prepending here is equivalent to `module use` and
# survives the re-exec. Each leaf script source's lmod.sh again
# (see hdf5_setup.sh / netcdf_setup.sh preflight blocks) so the
# `module` function is re-created at use-time downstream.
# Inline USE_CUSTOM_PATHS check: same condition computed below at line
# ~1221, but evaluated here because we must prepend MODULEPATH BEFORE
# any leaf script (rocm-patches, openmpi, etc.) does `module load`. The
# canonical USE_CUSTOM_PATHS assignment below stays unchanged so all
# downstream sites that read it work as before.
if [[ "${TOP_INSTALL_PATH}" != "/opt" || "${TOP_MODULE_PATH}" != "/etc/lmod/modules" ]]; then
   _rocmplus_moddir="${TOP_MODULE_PATH}/rocmplus-${ROCMPLUS_SUFFIX}"
   if [ ! -d "${_rocmplus_moddir}" ]; then
      # Pre-create so the first leaf script that writes a modulefile
      # under it lands in a dir that's already on MODULEPATH. Otherwise
      # subsequent leaf scripts in the same job would still miss the
      # freshly-built modules (Lmod only walks MODULEPATH entries that
      # exist as directories at startup time of each `module` call).
      PKG_SUDO=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
      ${PKG_SUDO} install -d -m 0755 "${_rocmplus_moddir}" 2>/dev/null || true
   fi
   if [ -d "${_rocmplus_moddir}" ]; then
      # Only prepend if not already at the front (idempotent across
      # nested sources / re-runs).
      case ":${MODULEPATH:-}:" in
         ":${_rocmplus_moddir}:"*) ;;
         *) export MODULEPATH="${_rocmplus_moddir}${MODULEPATH:+:${MODULEPATH}}" ;;
      esac
      echo "main_setup: MODULEPATH prepend -> ${_rocmplus_moddir}"
      echo "main_setup: MODULEPATH=${MODULEPATH}"
   else
      echo "WARNING: could not create ${_rocmplus_moddir}; freshly-built modules may not be visible to subsequent leaf scripts" >&2
   fi
   unset _rocmplus_moddir
fi

# ── --replace-existing + --keep-failed-installs ──────────────────────
#
# These flags used to be implemented here in main_setup.sh via two
# helpers:
#   replace_pkg <flag_var> <dirs...> -- <mods...>   (pre-install)
#   cleanup_pkg <label>                             (fail-cleanup)
# both backed by the PKG_CLEAN_DIRS / PKG_CLEAN_MODS lookup tables
# that mirrored each package's install layout. The duplication caused
# drift: when packages gained version-suffixed install dirs
# (mpi4py-v${VERSION}, scorep-v${VERSION}, …) the lookup tables had
# to be hand-edited, and any miss resulted in stale artifacts on disk.
#
# That logic now lives inside each per-package setup script, behind a
# uniform CLI:
#   --replace 0|1                 (default 0; pre-install rm)
#   --keep-failed-installs 0|1    (default 0; fail-cleanup gate)
# Multi-component scripts (openmpi, jax, magma, netcdf, scorep, tau)
# additionally expose --replace-<component> sub-flags. main_setup.sh
# threads the global REPLACE_OPTS = `--replace ${REPLACE_EXISTING}
# --keep-failed-installs ${KEEP_FAILED_INSTALLS}` into every
# migrated run_and_log call below. miniconda3/miniforge3 do NOT get
# REPLACE_OPTS because their installs are shared across ROCm
# versions; the operator removes them by hand to force a rebuild.
#
# Canonical template: extras/scripts/hypre_setup.sh.

USE_CUSTOM_PATHS=0
if [[ "${TOP_INSTALL_PATH}" != "/opt" || "${TOP_MODULE_PATH}" != "/etc/lmod/modules" ]]; then
   USE_CUSTOM_PATHS=1
fi

COMMON_OPTIONS="--rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL}"

# REPLACE_OPTS: passed to every per-package setup script that has
# migrated to the self-contained --replace + --keep-failed-installs
# pattern (template established in extras/scripts/hypre_setup.sh).
# Each script knows its own install dir + modulefile, so replacing
# the prior install + cleaning a partial-fail install is now done
# inside the script itself rather than by replace_pkg/cleanup_pkg
# tables in this file (which had drifted out of sync with the actual
# install paths during the per-package versioning pass).
# miniconda3/miniforge3 are intentionally NOT given REPLACE_OPTS:
# their installs are shared across ROCm versions, see the comment
# block above their run_and_log calls.
REPLACE_OPTS="--replace ${REPLACE_EXISTING} --keep-failed-installs ${KEEP_FAILED_INSTALLS}"

# Helper: returns --install-path + --module-path flags for a given package.
# Usage: $(path_args <install_subpath> <module_category/package>)
# Used by the legacy scripts that have NOT been migrated to the
# version-agnostic --install-path-as-parent pattern (flang-new, openmpi,
# mvapich, rocprof-sys, rocprof-compute, hip-python, hipifly,
# tensorflow, ftorch). For these, --install-path is treated as a full
# leaf dir (no version appended by the leaf script) -- effectively the
# legacy semantic predating the new --install-path / --install-path-no-
# version convention. main_setup.sh still constructs the full path
# here, including any subpath under ROCMPLUS.
path_args()
{
   if [ "${USE_CUSTOM_PATHS}" == 1 ]; then
      echo "--install-path ${ROCMPLUS}/${1} --module-path ${TOP_MODULE_PATH}/${2}"
   fi
}

# Helper: returns --install-path + --module-path flags for a MIGRATED
# package. Migrated = leaf script accepts --install-path as a PARENT
# directory and appends its own pkg-v${PKG_VERSION} subdir, so
# main_setup.sh stays version-agnostic. Used by the 14 leaf scripts
# that own their versions: fftw, hdf5, hypre, kokkos, petsc, pytorch,
# cupy, hpctoolkit, jax, magma, netcdf, scorep, miniconda3 / miniforge3
# (those last two get --install-path inline since their install lives
# outside ROCMPLUS, under TOP_INSTALL_PATH).
# Usage: $(rocmplus_args <module_category/package>)
rocmplus_args()
{
   if [ "${USE_CUSTOM_PATHS}" == 1 ]; then
      echo "--install-path ${ROCMPLUS} --module-path ${TOP_MODULE_PATH}/${1}"
   fi
}

# ── ROCm base install ────────────────────────────────────────────────
SKIP_ROCM_INSTALL=0
if [ -n "${ROCM_MODULE_VERSION}" ] && [ "${ROCM_MODULE_VERSION}" == "${ROCM_VERSION}" ]; then
   echo "ROCm ${ROCM_VERSION} already loaded from module — skipping ROCm base installation"
   SKIP_ROCM_INSTALL=1
elif [ -n "${ROCM_MODULE_VERSION}" ] && [ "${ROCM_MODULE_VERSION}" != "${ROCM_VERSION}" ]; then
   echo "ERROR: Loaded ROCm module (${ROCM_MODULE_VERSION}) does not match requested version (${ROCM_VERSION})."
   echo "       Please unload the current module or use --rocm-version ${ROCM_MODULE_VERSION}"
   exit 1
fi

# ── Guard: amdgpu-install path cannot produce therock/afar trees ──────
# rocm/scripts/rocm_setup.sh installs via amdgpu-install, which only
# knows about official upstream ROCm releases (rocm-X.Y.Z). Trying to
# materialize a release-candidate flavor (rocm-therock-X.Y.Z, rocm-
# afar-X.Y.Z) through it cannot work; the operator must load the
# corresponding pre-installed module first so SKIP_ROCM_INSTALL=1
# above. If we got here with a non-empty ROCM_RC_PREFIX it means no
# matching module was loaded -- abort cleanly with an actionable
# message rather than letting amdgpu-install run and fail confusingly.
if [ "${SKIP_ROCM_INSTALL}" == 0 ] && [ -n "${ROCM_RC_PREFIX}" ]; then
   echo "ERROR: ROCM_RC_PREFIX='${ROCM_RC_PREFIX}' set but no matching rocm module is loaded." >&2
   echo "       The amdgpu-install path cannot produce a ${ROCM_RC_PREFIX}-* tree;" >&2
   echo "       load the appropriate rocm module first (e.g. module load rocm/${ROCM_RC_PREFIX}-<tag>)" >&2
   echo "       so the SDK is provided externally and main_setup.sh proceeds with the rocmplus stack." >&2
   exit 1
fi

if [ "${SKIP_ROCM_INSTALL}" == 0 ]; then
   run_and_log baseospackages rocm/scripts/baseospackages_setup.sh

   run_and_log lmod rocm/scripts/lmod_setup.sh

   source ~/.bashrc

   ROCM_DELTA_OPTS=""
   [ -n "${BASE_ROCM_VERSION}" ] && ROCM_DELTA_OPTS="${ROCM_DELTA_OPTS} --base-rocm-version ${BASE_ROCM_VERSION}"
   [ -n "${SUPERSEDES_VERSION}" ] && ROCM_DELTA_OPTS="${ROCM_DELTA_OPTS} --supersedes ${SUPERSEDES_VERSION}"
   run_and_log rocm rocm/scripts/rocm_setup.sh --rocm-version ${ROCM_VERSION} ${ROCM_DELTA_OPTS}

   run_and_log rocm-rocprof-sys rocm/scripts/rocm_rocprof-sys_setup.sh --rocm-version ${ROCM_VERSION}

   run_and_log rocm-rocprof-compute rocm/scripts/rocm_rocprof-compute_setup.sh --rocm-version ${ROCM_VERSION}

   # Vendored cherry-picks layered on top of the SDK we just installed.
   # The script is selective by ROCM_VERSION (currently only 7.2.0 / 7.2.1
   # need a fix; everything else exits NOOP_RC=43 → SKIPPED(no-op) in the
   # per-package summary). See rocm/scripts/rocm_patches.sh and
   # rocm/sources/rocm-patches/README.md.
   #
   # --skip-patches 1 (operator opt-out) bypasses the call entirely and
   # records 'rocm-patches(--skip-patches)' in the DESELECTED bucket so
   # the per-package summary makes the choice visible. Use this when the
   # patches overlay would mismatch the runtime (e.g. 7.2.0 / 7.2.1
   # patches binaries built for a newer GLIBC than the target nodes).
   if [ "${SKIP_PATCHES}" == "1" ]; then
      DESELECTED_PKGS+=("rocm-patches(--skip-patches)")
      DESELECTED_PKGS+=("hipblaslt-patch(--skip-patches)")
      echo ""
      echo "### deselected: rocm-patches (--skip-patches)"
      echo "### deselected: hipblaslt-patch (--skip-patches)"
      echo ""
   else
      run_and_log rocm-patches rocm/scripts/rocm_patches.sh --rocm-version ${ROCM_VERSION}

      # hipBLASLt heuristic-catalogue overlay (lightweight msgpack edit of
      # the shipped Tensile .dat libraries). Version-gated: NOOP_RC=43 for
      # any ROCm without a vendored fix, so it self-selects. Default
      # --module-path/--rocm-path match rocm_setup.sh's install layout
      # (/etc/lmod/modules/ROCm/rocm, /opt/rocm-${V}), so no threading here.
      run_and_log hipblaslt-patch rocm/scripts/hipblaslt_patch_setup.sh --rocm-version ${ROCM_VERSION}
   fi
else
   source ~/.bashrc

   # RC trees (rocm-therock-*, rocm-afar-*) reach this branch because
   # SKIP_ROCM_INSTALL=1 is forced: amdgpu-install cannot materialise an
   # RC flavour, and the operator must have pre-loaded the matching
   # rocm/${ROCM_VERSION} module so the SDK is on disk already.
   # rocm_patches.sh still has work to do on these trees:
   #   * rocprof-compute overlay for any RC version whose
   #     ${ROCM_PATH}/libexec/rocprofiler-compute/VERSION.sha is
   #     populated (afar-22.{1,2}.0, therock-23.2.0 today). build.sh
   #     soft-no-ops via exit 43 on RC trees without a pin.
   #   * --module-file-only modulefile backfill is also useful here
   #     when a rocprof-sys overlay was built out-of-tree (afar-22.x).
   # ROCM_PATH is exported by the pre-loaded module, so pass it
   # through so the prerequisite check in rocm_patches.sh resolves to
   # the cluster-specific SDK install path rather than the default
   # /opt/rocm-${ROCM_VERSION}.
   #
   # --skip-patches 1 (operator opt-out): mirror the regular-SDK branch
   # above. Same DESELECTED summary bucket so a sweep with --skip-patches
   # 1 reports it uniformly across all token shapes (numeric and RC).
   if [ "${SKIP_PATCHES}" == "1" ]; then
      DESELECTED_PKGS+=("rocm-patches(--skip-patches)")
      DESELECTED_PKGS+=("hipblaslt-patch(--skip-patches)")
      echo ""
      echo "### deselected: rocm-patches (--skip-patches)"
      echo "### deselected: hipblaslt-patch (--skip-patches)"
      echo ""
   else
      run_and_log rocm-patches rocm/scripts/rocm_patches.sh \
         --rocm-version ${ROCM_VERSION} \
         --rocm-path "${ROCM_PATH}"

      # hipBLASLt overlay on the pre-loaded RC/module SDK. --rocm-path is
      # threaded (mirrors rocm-patches) since the SDK is not at the default
      # /opt/rocm-${V}; version gate NOOPs unsupported trees.
      run_and_log hipblaslt-patch rocm/scripts/hipblaslt_patch_setup.sh \
         --rocm-version ${ROCM_VERSION} \
         --rocm-path "${ROCM_PATH}"
   fi
fi

# ── Package installation ─────────────────────────────────────────────
# Each block invokes the per-package setup script unconditionally,
# threading --build-<x> ${BUILD_<X>} so the script itself decides
# whether to do work, no-op (SKIPPED), or fail. Two checks that used
# to live here as `if [[ "${BUILD_<X>}" == "1" ]] && [[ ! -d <path> ]]`
# wrappers have been moved INTO each setup script:
#
#   * the BUILD_<X>=0 opt-out gate (operator selected --packages w/o
#     this one) -- now an early `exit ${NOOP_RC}` at the top of each
#     script, just after arg parsing and before --replace. Runs
#     cleanly so run_and_log records it as SKIPPED(no-op) in the
#     per-package summary, replacing the prior silent omission that
#     made it hard to grep "what was actually built".
#
#   * the existence-check `[[ ! -d <pkg-v${VER}> ]]` guard -- now an
#     in-script check after --replace and before the EXIT-trap install
#     (also `exit ${NOOP_RC}`). Keeps the install-path knowledge in
#     exactly one place per package; multi-component scripts can
#     correctly check ALL of their installs (not just the leaf
#     main_setup.sh happened to know about).
#
# Pattern established in extras/scripts/hypre_setup.sh (search
# "BUILD_HYPRE=0 short-circuit" and "Existence guard").
#
# The one guard that REMAINS here is the intentional exception
# called out in the existence-check evaluation:
#   * mvapich -- partially migrated; both gates remain here for now.
#
# miniconda3 / miniforge3 have ALSO migrated to the in-script BUILD=0
# + existence-on-disk pattern (see the comment block above their
# run_and_log calls). They are the second exception class: they keep
# the in-script guards but do NOT get the --replace mechanism, since
# their installs are SHARED across ROCm versions and a multi-version
# sweep should never silently nuke a working conda/mamba env. To
# force a rebuild of those, the operator does `rm -rf
# ${TOP_INSTALL_PATH}/miniconda3-v<version>` (or miniforge3 equivalent)
# by hand. The version is owned by the leaf script (MINICONDA3_VERSION
# / MINIFORGE3_VERSION default at the top of each *_setup.sh).

run_and_log flang-new rocm/scripts/flang-new_setup.sh ${COMMON_OPTIONS} --build-flang-new ${BUILD_FLANGNEW} ${REPLACE_OPTS} \
   $(path_args " " rocmplus-${ROCMPLUS_SUFFIX}/amdflang-new)

# openmpi block also produces xpmem-*, ucx-*, ucc-* under ROCMPLUS.
# BUILD_OPENMPI=0 opt-out and existence check both live in
# openmpi_setup.sh; we just thread --build-openmpi through.
run_and_log_versioned openmpi comm/scripts/openmpi_setup.sh ${COMMON_OPTIONS} --build-openmpi ${BUILD_OPENMPI} --build-xpmem 1 ${REPLACE_OPTS} \
   $(path_args " " rocmplus-${ROCMPLUS_SUFFIX}/openmpi)

# mpi4py owns its own version (see comment block at the version pins
# above). main_setup.sh passes only --install-path (the parent dir);
# mpi4py_setup.sh appends mpi4py-v${MPI4PY_VERSION} itself.
#
# MPI selection: on a Cray PE system (PrgEnv-*), build mpi4py against the
# loaded cray-mpich rather than the leaf-script default (openmpi). The
# Cray MPICH install dir is exported as $MPICH_DIR by the cray-mpich
# module (e.g. /opt/cray/pe/mpich/<ver>/ofi/amd/<x>); when present we
# thread --mpi-module cray-mpich + --mpi-path $MPICH_DIR so the wheel
# links the PrgEnv's MPI and the generated modulefile load()s cray-mpich.
# Non-Cray systems fall through to the leaf default unchanged.
MPI4PY_MPI_OPTS=""
if [ -n "${MPICH_DIR:-}" ] && [ -d "${MPICH_DIR}/bin" ]; then
   MPI4PY_MPI_OPTS="--mpi-module cray-mpich --mpi-path ${MPICH_DIR}"
   echo "mpi4py: Cray MPICH detected (MPICH_DIR=${MPICH_DIR}); building against cray-mpich"
fi
run_and_log_versioned mpi4py comm/scripts/mpi4py_setup.sh ${COMMON_OPTIONS} --build-mpi4py ${BUILD_MPI4PY} ${REPLACE_OPTS} ${MPI4PY_MPI_OPTS} \
   $([ "${USE_CUSTOM_PATHS}" == 1 ] && echo "--install-path ${ROCMPLUS} --module-path ${TOP_MODULE_PATH}/rocmplus-${ROCMPLUS_SUFFIX}/mpi4py")

# NOTE: the Cray-only mpich-wrappers (standalone MPICH built with FC=amdflang
# so PrgEnv-amd-new/* consumers get an amdflang-format mpi.mod) are no longer
# built here. They are provisioned WITH the rocm-<ver> SDK tree by the
# run_rocm_build*/craywrap/therock scripts (rocm/scripts/mpich_wrappers_setup.sh),
# so PrgEnv-amd-new has them at creation. The consumer blocks below still PROBE
# for the resulting module under rocmplus-<ver>/mpich-wrappers/<ver>.

# rocshmem's RO backend needs an MPI for cmake's find_package(MPI). On a
# non-Cray system that is the openmpi module built earlier; on a Cray PE
# there is no openmpi, so thread the PrgEnv MPI instead (same rationale as
# hdf5/netcdf/fftw/petsc). Prefer the from-source mpich-wrappers (ships
# mpicc/mpicxx that find_package(MPI) can locate); fall back to cray-mpich.
# Placed AFTER the mpich-wrappers build above so its modulefile exists for
# the existence probe. BUILD_ROCSHMEM=0 opt-out + existence check live in
# rocshmem_setup.sh; we thread --build-rocshmem and --mpi-module.
ROCSHMEM_MPI_MODULE="openmpi"
if [ -n "${MPICH_DIR:-}" ] && [ -d "${MPICH_DIR}/bin" ]; then
   if [ -e "${TOP_MODULE_PATH}/rocmplus-${ROCMPLUS_SUFFIX}/mpich-wrappers/${ROCM_VERSION}" ] \
      || [ -e "${TOP_MODULE_PATH}/rocmplus-${ROCMPLUS_SUFFIX}/mpich-wrappers/${ROCM_VERSION}.lua" ]; then
      ROCSHMEM_MPI_MODULE="mpich-wrappers"
      echo "rocshmem: mpich-wrappers detected; building rocSHMEM RO backend against mpich-wrappers (PrgEnv MPI)"
   else
      ROCSHMEM_MPI_MODULE="cray-mpich"
      echo "rocshmem: Cray MPICH detected (MPICH_DIR=${MPICH_DIR}); building rocSHMEM RO backend against cray-mpich"
   fi
fi
run_and_log_versioned rocshmem comm/scripts/rocshmem_setup.sh ${COMMON_OPTIONS} --build-rocshmem ${BUILD_ROCSHMEM} --mpi-module ${ROCSHMEM_MPI_MODULE} ${REPLACE_OPTS} \
   $(path_args " " rocmplus-${ROCMPLUS_SUFFIX}/rocshmem)

if [[ "${BUILD_MVAPICH}" == "1" ]] && [[ ! -d ${ROCMPLUS}/mvapich ]]; then
   run_and_log mvapich comm/scripts/mvapich_setup.sh ${COMMON_OPTIONS} ${REPLACE_OPTS} \
      $(path_args mvapich rocmplus-${ROCMPLUS_SUFFIX}/mvapich)
fi

run_and_log rocprof-sys tools/scripts/rocprof-sys_setup.sh ${COMMON_OPTIONS} --build-rocprof-sys ${BUILD_ROCPROF_SYS} --install-rocprof-sys-from-source ${INSTALL_ROCPROF_SYS_FROM_SOURCE} --python-version ${PYTHON_VERSION} ${REPLACE_OPTS} \
   $(path_args rocprofiler-system rocmplus-${ROCMPLUS_SUFFIX}/rocprofiler-system)

run_and_log rocprof-compute tools/scripts/rocprof-compute_setup.sh ${COMMON_OPTIONS} --build-rocprof-compute ${BUILD_ROCPROF_COMPUTE} --install-rocprof-compute-from-source ${INSTALL_ROCPROF_COMPUTE_FROM_SOURCE} --python-version ${PYTHON_VERSION} ${REPLACE_OPTS} \
   $(path_args rocprofiler-compute rocmplus-${ROCMPLUS_SUFFIX}/rocprofiler-compute)

#if [[ ! -d ${ROCMPLUS}/rocprofiler-sdk ]]; then
#   run_and_log rocprofiler-sdk tools/scripts/rocprofiler-sdk_setup.sh ${COMMON_OPTIONS} --build-rocprofiler-sdk ${BUILD_ROCPROFILER_SDK} --python-version ${PYTHON_VERSION} \
#      $(path_args rocprofiler-sdk rocmplus-${ROCMPLUS_SUFFIX}/rocprofiler-sdk)
#fi

run_and_log_versioned likwid tools/scripts/likwid_setup.sh ${COMMON_OPTIONS} --build-likwid ${BUILD_LIKWID} ${REPLACE_OPTS} \
   $(rocmplus_args rocmplus-${ROCMPLUS_SUFFIX}/likwid)

run_and_log_versioned mdb tools/scripts/mdb_setup.sh ${COMMON_OPTIONS} --build-mdb ${BUILD_MDB} ${REPLACE_OPTS} \
   $(rocmplus_args rocmplus-${ROCMPLUS_SUFFIX}/mdb)

# intellikit installs the AMDResearch IntelliKit Python monorepo (accordo,
# kerncap, linex, metrix, nexus, rocm_mcp, uprof_mcp) into a venv-backed
# --target tree and writes one VERSION.lua module. --python-version drives
# the venv interpreter (IntelliKit needs Python 3.10+). Like mdb/likwid it
# is an explicit always-skip under --quick-installs (see QUICK_INSTALLS_PKGS).
run_and_log_versioned intellikit tools/scripts/intellikit_setup.sh ${COMMON_OPTIONS} --build-intellikit ${BUILD_INTELLIKIT} --python-version ${PYTHON_VERSION} ${REPLACE_OPTS} \
   $(rocmplus_args rocmplus-${ROCMPLUS_SUFFIX}/intellikit)

# hpctoolkit builds hpcprof-mpi when meson's dependency('MPI') finds mpicc/
# mpicxx. The leaf default MPI module is "openmpi", which does not exist on a
# Cray system. When cray-mpich is loaded ($MPICH_DIR exported) prefer the
# mpich-wrappers leaf (standalone MPICH, MPICH-ABI compatible with cray-mpich,
# ships mpicc/mpicxx) if its modulefile exists; otherwise fall back to
# cray-mpich. Non-Cray systems fall through to the leaf default unchanged.
HPCTOOLKIT_MPI_OPTS=""
if [ -n "${MPICH_DIR:-}" ] && [ -d "${MPICH_DIR}/bin" ]; then
   if [ -e "${TOP_MODULE_PATH}/rocmplus-${ROCMPLUS_SUFFIX}/mpich-wrappers/${ROCM_VERSION}" ]; then
      HPCTOOLKIT_MPI_OPTS="--mpi-module mpich-wrappers"
      echo "hpctoolkit: mpich-wrappers detected; building hpcprof-mpi against mpich-wrappers (PrgEnv MPI)"
   else
      HPCTOOLKIT_MPI_OPTS="--mpi-module cray-mpich"
      echo "hpctoolkit: Cray MPICH detected (MPICH_DIR=${MPICH_DIR}); building hpcprof-mpi against cray-mpich"
   fi
fi
run_and_log_versioned hpctoolkit tools/scripts/hpctoolkit_setup.sh ${COMMON_OPTIONS} --build-hpctoolkit ${BUILD_HPCTOOLKIT} ${REPLACE_OPTS} ${HPCTOOLKIT_MPI_OPTS} \
   $(rocmplus_args rocmplus-${ROCMPLUS_SUFFIX}/hpctoolkit)

# scorep + tau share ${ROCMPLUS}/pdt. Their setup scripts default to
# leaving pdt in place across re-installs (it's a shared dep); only
# when BOTH are being rebuilt do we ask each script to also wipe pdt
# via --replace-pdt 1, matching the prior `replace_pkg always pdt`
# guard. When not threaded, the per-script EXIT trap also preserves
# pdt on a partial-install failure.
SCOREP_REPLACE_PDT=""
TAU_REPLACE_PDT=""
if [[ "${REPLACE_EXISTING}" == "1" && "${BUILD_SCOREP}" == "1" && "${BUILD_TAU}" == "1" ]]; then
   SCOREP_REPLACE_PDT="--replace-pdt 1"
   TAU_REPLACE_PDT="--replace-pdt 1"
fi
run_and_log_versioned scorep tools/scripts/scorep_setup.sh ${COMMON_OPTIONS} --build-scorep ${BUILD_SCOREP} ${REPLACE_OPTS} ${SCOREP_REPLACE_PDT} \
   $(rocmplus_args rocmplus-${ROCMPLUS_SUFFIX}/scorep)

#run_and_log grafana tools/scripts/grafana_setup.sh

# MPI selection for tau: same Cray-PE rationale as hypre/hdf5/netcdf/petsc.
# TAU's -mpi support needs mpicc/mpif90 on PATH, and its Fortran MPI wrappers
# must match the new-flang mpi.mod users compile with. On a Cray that is the
# from-source mpich-wrappers (mpif90 -> amdflang); else cray-mpich. The leaf
# default MPI module is "openmpi" (absent on Cray -> preflight SKIP), so
# thread the right one. Non-Cray systems fall through to the leaf default.
TAU_MPI_OPTS=""
if [ -n "${MPICH_DIR:-}" ] && [ -d "${MPICH_DIR}/bin" ]; then
   if [ -e "${TOP_MODULE_PATH}/rocmplus-${ROCMPLUS_SUFFIX}/mpich-wrappers/${ROCM_VERSION}" ]; then
      TAU_MPI_OPTS="--mpi-module mpich-wrappers"
      echo "tau: mpich-wrappers detected; building TAU against mpich-wrappers (PrgEnv MPI, new-flang mpif90/amdflang)"
   else
      TAU_MPI_OPTS="--mpi-module cray-mpich"
      echo "tau: Cray MPICH detected (MPICH_DIR=${MPICH_DIR}); building TAU against cray-mpich"
   fi
fi
run_and_log tau tools/scripts/tau_setup.sh ${COMMON_OPTIONS} --build-tau ${BUILD_TAU} ${REPLACE_OPTS} ${TAU_REPLACE_PDT} ${TAU_MPI_OPTS} \
   $([ "${USE_CUSTOM_PATHS}" == 1 ] && echo "--tau-install-path ${ROCMPLUS}/tau --pdt-install-path ${ROCMPLUS}/pdt --module-path ${TOP_MODULE_PATH}/rocmplus-${ROCMPLUS_SUFFIX}/tau")

#run_and_log compiler extras/scripts/compiler_setup.sh

run_and_log_versioned cupy extras/scripts/cupy_setup.sh ${COMMON_OPTIONS} --build-cupy ${BUILD_CUPY} ${REPLACE_OPTS} \
   $(rocmplus_args rocmplus-${ROCMPLUS_SUFFIX}/cupy)

run_and_log_versioned hip-python extras/scripts/hip-python_setup.sh ${COMMON_OPTIONS} --build-hip-python ${BUILD_HIP_PYTHON} ${REPLACE_OPTS} \
   $(path_args hip-python rocmplus-${ROCMPLUS_SUFFIX}/hip-python)

# tensorflow / jax / pytorch / ftorch are the long-pole builds (each
# 30-90 min on a cold workspace) and have been moved to the END of the
# sweep so the short builds (magma, kokkos, hipifly, hdf5,
# netcdf, fftw, petsc, hypre) finish first and surface fast in the
# logs. See the block after `hypre` below for the reordered ML group.

run_and_log_versioned magma extras/scripts/magma_setup.sh ${COMMON_OPTIONS} --build-magma ${BUILD_MAGMA} ${REPLACE_OPTS} \
   $(rocmplus_args rocmplus-${ROCMPLUS_SUFFIX})

# apps_setup.sh is intentionally disabled. It is not gated by --packages
# (no BUILD_APPS flag), runs unconditionally on every sweep pass, and
# has been the source of 0-byte-log noise in failed runs (job 7974
# logs_05_01_2026/rocm-7.2.0_7974/log_apps_05_01_2026.txt). Re-enable
# only when its output is actually needed; in that case prefer adding a
# BUILD_APPS gate first so it can be selected by --packages.
#run_and_log apps extras/scripts/apps_setup.sh

run_and_log_versioned kokkos extras/scripts/kokkos_setup.sh ${COMMON_OPTIONS} --build-kokkos ${BUILD_KOKKOS} ${REPLACE_OPTS} \
   $(rocmplus_args rocmplus-${ROCMPLUS_SUFFIX}/kokkos)

# miniconda3 / miniforge3 are intentionally exempt from --replace-existing.
# Their install paths (${TOP_INSTALL_PATH}/miniconda3-v<version>,
# ${TOP_INSTALL_PATH}/miniforge3-v<version>) and module dirs
# (${TOP_MODULE_PATH}/base/...) are SHARED across ROCm versions --
#
# NOTE on the module dir: we write directly to ${TOP_MODULE_PATH}/base/<pkg>
# (NOT .../LinuxPlus/<pkg>). Only ${TOP_MODULE_PATH}/base is on MODULEPATH on
# the deployed systems; LinuxPlus is a CONTAINER-side staging category that
# the Docker->package->deploy path folds into base/ (deploy_module_package.sh
# maps the LinuxPlus category to slot base/<pkg>). This direct-install branch
# bypasses that remap, so writing to LinuxPlus here left the modulefile off
# MODULEPATH and `module load miniconda3` / miniforge3 could not find it.
# The leaf scripts keep their LinuxPlus default (required for the container
# categorization); we override to base only here.
# they don't depend on which ROCm release the orchestrator is currently
# iterating. With multi-version sweeps invoked under --replace-existing
# 1, calling replace_pkg here would delete the install at the start of
# every ROCm-version pass and force a full rebuild of conda/forge per
# version, which is pure waste (the result is identical).
#
# Architecture (matches the rest of the migrated packages, with two
# deliberate exceptions):
#   * BUILD_<X>=0 opt-out + existence-on-disk skip: handled INSIDE
#     miniconda3_setup.sh / miniforge3_setup.sh (both exit NOOP_RC=43
#     so run_and_log records a SKIPPED(no-op) line in the per-package
#     summary). main_setup.sh therefore invokes the script
#     unconditionally on every sweep -- the script decides its own fate.
#   * --replace is INTENTIONALLY NOT THREADED (the two exceptions): no
#     ${REPLACE_OPTS} on these calls and no --replace argument parsing
#     in either setup script. Forcing a rebuild is a manual operator
#     action: `rm -rf ${TOP_INSTALL_PATH}/miniconda3-v<version>` (or
#     the miniforge3 equivalent) followed by re-running main_setup.sh.
#     This matches the SHARED-across-ROCm-versions intent: a multi-
#     version sweep should never silently nuke a working conda/mamba
#     env that other ROCm passes also depend on.
# Multi-version coexistence works because the install path and the
# .lua modulefile are both keyed on the leaf script's MINICONDA3_VERSION
# / MINIFORGE3_VERSION default; bumping the version inside the leaf
# script leaves the prior version's install + module in place;
# `module load miniconda3` continues to load the default version per
# Lmod's usual rules. main_setup.sh threads only --install-path (the
# parent dir, here ${TOP_INSTALL_PATH} since miniconda3 / miniforge3
# live OUTSIDE the rocmplus tree) and the leaf scripts append the
# versioned subdir themselves, matching the --install-path = parent +
# version-append convention used by the migrated leaf scripts.
run_and_log_versioned miniconda3 extras/scripts/miniconda3_setup.sh --rocm-version ${ROCM_VERSION} --build-miniconda3 ${BUILD_MINICONDA3} --python-version ${PYTHON_VERSION} \
   $([ "${USE_CUSTOM_PATHS}" == 1 ] && echo "--install-path ${TOP_INSTALL_PATH} --module-path ${TOP_MODULE_PATH}/base/miniconda3")

run_and_log_versioned miniforge3 extras/scripts/miniforge3_setup.sh --rocm-version ${ROCM_VERSION} --build-miniforge3 ${BUILD_MINIFORGE3} \
   $([ "${USE_CUSTOM_PATHS}" == 1 ] && echo "--install-path ${TOP_INSTALL_PATH} --module-path ${TOP_MODULE_PATH}/base/miniforge3")

# emacs: ROCm-agnostic editor module. Like miniconda3/miniforge3 it installs
# under TOP_INSTALL_PATH (shared across ROCm versions) and is intentionally
# NOT given ${REPLACE_OPTS} -- the leaf's existence guard skips the rebuild on
# every subsequent sweep version, and a shared tool should not be wiped per
# ROCm version. The emacs leaf does not accept --rocm-version/--amdgpu-gfxmodel,
# so COMMON_OPTIONS is deliberately NOT threaded here. --native-comp 0 keeps
# gcc-14 off the image/nodes (see emacs_setup.sh header). --install-path is a
# PARENT dir; the leaf appends emacs-v${EMACS_VERSION}.
run_and_log_versioned emacs extras/scripts/emacs_setup.sh --build-emacs ${BUILD_EMACS} --native-comp 0 \
   $([ "${USE_CUSTOM_PATHS}" == 1 ] && echo "--install-path ${TOP_INSTALL_PATH} --module-path ${TOP_MODULE_PATH}/base/emacs")

# hipfort: build-from-source intentionally removed. ROCm 6.3+ ships
# hipfort natively (see <pkg>.BUNDLED markers / rocm/<v> module). The
# legacy run_and_log call previously invoked extras/scripts/hipfort_setup.sh
# under rocmplus-<v>/hipfort_from_source which is no longer needed and
# was producing no-op skip lines on every sweep. The setup script and
# the BUNDLED-marker writer remain in extras/scripts/hipfort_setup.sh
# for any operator who wants to invoke it manually for an older SDK.

run_and_log hipifly extras/scripts/hipifly_setup.sh --rocm-version ${ROCM_VERSION} --build-hipifly ${BUILD_HIPIFLY} --hipifly-module ${HIPIFLY_MODULE} ${REPLACE_OPTS} \
   $(path_args hipifly rocmplus-${ROCMPLUS_SUFFIX}/hipifly)

# MPI selection for HDF5 (same Cray-PE rationale as mpi4py above): the leaf
# default MPI module is "openmpi", which does not exist on a Cray system and
# would make hdf5's preflight SKIP. When cray-mpich is loaded ($MPICH_DIR is
# exported by the cray-mpich module) thread --mpi-module cray-mpich so the
# parallel HDF5 builds with the PrgEnv's cc/CC/ftn wrappers (cray-mpich +
# new LLVM Flang), producing hdf5.mod files that match user code -- cray-hdf5
# itself ships classic-Flang .mod that new flang rejects. Non-Cray systems
# fall through to the leaf default (openmpi) unchanged.
HDF5_MPI_OPTS=""
if [ -n "${MPICH_DIR:-}" ] && [ -d "${MPICH_DIR}/bin" ]; then
   # On a Cray with the new LLVM Flang (amdflang / ftn on ROCm 7.x),
   # cray-mpich's amd/rocm-compiler mpi.mod is CLASSIC-Flang V34, which new
   # flang cannot read -- so a parallel-Fortran `use mpi` HDF5 build with
   # cc/CC/ftn fails. If the mpich-wrappers leaf built a standalone MPICH
   # with FC=amdflang (new-flang mpi.mod, MPICH-ABI compatible with
   # cray-mpich), prefer it: thread --mpi-module mpich-wrappers so the leaf
   # loads that module and builds parallel HDF5 with its mpicc/mpicxx/
   # mpifort. Fall back to cray-mpich when the wrapper was not built.
   if [ -e "${TOP_MODULE_PATH}/rocmplus-${ROCMPLUS_SUFFIX}/mpich-wrappers/${ROCM_VERSION}" ]; then
      HDF5_MPI_OPTS="--mpi-module mpich-wrappers"
      echo "hdf5: mpich-wrappers detected; building parallel HDF5 against mpich-wrappers (new-flang mpi.mod)"
   else
      HDF5_MPI_OPTS="--mpi-module cray-mpich"
      echo "hdf5: Cray MPICH detected (MPICH_DIR=${MPICH_DIR}); building parallel HDF5 against cray-mpich"
   fi
fi
run_and_log_versioned hdf5 extras/scripts/hdf5_setup.sh ${COMMON_OPTIONS} --build-hdf5 ${BUILD_HDF5} ${REPLACE_OPTS} ${HDF5_MPI_OPTS} \
   $(rocmplus_args rocmplus-${ROCMPLUS_SUFFIX}/hdf5)

# MPI selection for netcdf: same Cray-PE rationale as hdf5 above. netcdf
# links the parallel HDF5 we just built and builds netcdf-fortran + PnetCDF
# with a Fortran MPI, so it must use the SAME MPI as hdf5 -- the from-source
# mpich-wrappers (new-flang mpi.mod) when present, else cray-mpich. The leaf
# default MPI module is "openmpi" (absent on Cray -> preflight SKIP), so
# thread the right one. Non-Cray systems fall through to the leaf default.
NETCDF_MPI_OPTS=""
if [ -n "${MPICH_DIR:-}" ] && [ -d "${MPICH_DIR}/bin" ]; then
   if [ -e "${TOP_MODULE_PATH}/rocmplus-${ROCMPLUS_SUFFIX}/mpich-wrappers/${ROCM_VERSION}" ]; then
      NETCDF_MPI_OPTS="--mpi-module mpich-wrappers"
      echo "netcdf: mpich-wrappers detected; building netcdf/pnetcdf against mpich-wrappers (new-flang mpi.mod)"
   else
      NETCDF_MPI_OPTS="--mpi-module cray-mpich"
      echo "netcdf: Cray MPICH detected (MPICH_DIR=${MPICH_DIR}); building netcdf/pnetcdf against cray-mpich"
   fi
fi
# PnetCDF tarball staging: the official tarball (with a pre-generated
# `configure`) is only on parallel-netcdf.github.io, unreachable from some
# Cray compute nodes (proxy blocks github.io; the git-clone fallback then
# needs autoconf 2.70+/libtool 2.5.4+ which RHEL 9 lacks). If the operator
# has not pinned NETCDF_PNETCDF_TARBALL, auto-detect a staged tarball under
# NETCDF_SRC_STAGE_DIR and export it for netcdf_setup.sh. Prefer the
# version-matched name when PNETCDF_VERSION is known, else newest glob match.
if [[ "${BUILD_NETCDF}" == "1" ]] && [ -z "${NETCDF_PNETCDF_TARBALL:-}" ] && [ -d "${NETCDF_SRC_STAGE_DIR}" ]; then
   _staged_pnetcdf=""
   if [ -n "${PNETCDF_VERSION}" ] && [ -f "${NETCDF_SRC_STAGE_DIR}/pnetcdf-${PNETCDF_VERSION}.tar.gz" ]; then
      _staged_pnetcdf="${NETCDF_SRC_STAGE_DIR}/pnetcdf-${PNETCDF_VERSION}.tar.gz"
   else
      # newest matching tarball (sorted; tail = highest version / mtime-agnostic)
      _staged_pnetcdf=$(ls -1 "${NETCDF_SRC_STAGE_DIR}"/pnetcdf-*.tar.gz 2>/dev/null | sort -V | tail -n1)
   fi
   if [ -n "${_staged_pnetcdf}" ] && [ -f "${_staged_pnetcdf}" ]; then
      export NETCDF_PNETCDF_TARBALL="${_staged_pnetcdf}"
      echo "netcdf: using operator-staged PnetCDF tarball ${NETCDF_PNETCDF_TARBALL} (no github.io download)"
   fi
   unset _staged_pnetcdf
elif [ -n "${NETCDF_PNETCDF_TARBALL:-}" ]; then
   export NETCDF_PNETCDF_TARBALL
   echo "netcdf: NETCDF_PNETCDF_TARBALL pinned to ${NETCDF_PNETCDF_TARBALL}"
fi

run_and_log_versioned netcdf extras/scripts/netcdf_setup.sh ${COMMON_OPTIONS} --build-netcdf ${BUILD_NETCDF} ${REPLACE_OPTS} ${NETCDF_MPI_OPTS} \
   $([ -n "${PNETCDF_VERSION}" ] && echo "--pnetcdf-version ${PNETCDF_VERSION}") \
   $([ "${USE_CUSTOM_PATHS}" == 1 ] && echo "--install-path ${ROCMPLUS} --netcdf-c-module-path ${TOP_MODULE_PATH}/rocmplus-${ROCMPLUS_SUFFIX}/netcdf-c --netcdf-f-module-path ${TOP_MODULE_PATH}/rocmplus-${ROCMPLUS_SUFFIX}/netcdf-fortran --pnetcdf-module-path ${TOP_MODULE_PATH}/rocmplus-${ROCMPLUS_SUFFIX}/pnetcdf")

# MPI selection for fftw: same Cray-PE rationale as hdf5/netcdf above. FFTW's
# --enable-mpi builds libfftw3*_mpi against an MPI C wrapper, so it should use
# the SAME MPI as the rest of the PrgEnv stack -- the from-source
# mpich-wrappers when present, else cray-mpich. The leaf default MPI module is
# "openmpi" (absent on Cray -> preflight SKIP), so thread the right one.
# Non-Cray systems fall through to the leaf default (openmpi / mpicc).
FFTW_MPI_OPTS=""
if [ -n "${MPICH_DIR:-}" ] && [ -d "${MPICH_DIR}/bin" ]; then
   if [ -e "${TOP_MODULE_PATH}/rocmplus-${ROCMPLUS_SUFFIX}/mpich-wrappers/${ROCM_VERSION}" ]; then
      FFTW_MPI_OPTS="--mpi-module mpich-wrappers"
      echo "fftw: mpich-wrappers detected; building FFTW MPI against mpich-wrappers (PrgEnv MPI)"
   else
      FFTW_MPI_OPTS="--mpi-module cray-mpich"
      echo "fftw: Cray MPICH detected (MPICH_DIR=${MPICH_DIR}); building FFTW MPI against cray-mpich"
   fi
fi
run_and_log_versioned fftw extras/scripts/fftw_setup.sh ${COMMON_OPTIONS} --build-fftw ${BUILD_FFTW} ${REPLACE_OPTS} ${FFTW_MPI_OPTS} \
   $(rocmplus_args rocmplus-${ROCMPLUS_SUFFIX}/fftw)

#run_and_log x11vnc extras/scripts/x11vnc_setup.sh --build-x11vnc ${BUILD_X11VNC}

# MPI selection for petsc: same Cray-PE rationale as hdf5/netcdf/fftw above.
# PETSc builds with MPI (--with-mpi-dir) and, when Fortran bindings are on,
# needs an mpif90 whose .mod format matches what users compile with. On a
# Cray that is the from-source mpich-wrappers (new LLVM Flang mpif90); else
# cray-mpich. The leaf default MPI module is "openmpi" (absent on Cray ->
# preflight SKIP), so thread the right one. Non-Cray systems fall through to
# the leaf default (openmpi).
PETSC_MPI_OPTS=""
if [ -n "${MPICH_DIR:-}" ] && [ -d "${MPICH_DIR}/bin" ]; then
   if [ -e "${TOP_MODULE_PATH}/rocmplus-${ROCMPLUS_SUFFIX}/mpich-wrappers/${ROCM_VERSION}" ]; then
      PETSC_MPI_OPTS="--mpi-module mpich-wrappers"
      echo "petsc: mpich-wrappers detected; building PETSc against mpich-wrappers (new-flang mpif90)"
   else
      PETSC_MPI_OPTS="--mpi-module cray-mpich"
      echo "petsc: Cray MPICH detected (MPICH_DIR=${MPICH_DIR}); building PETSc against cray-mpich"
   fi
fi
# PETSc external-package staging: fblaslapack/metis/parmetis are bitbucket-
# only and the ANL fallback mirror is also blocked on some Cray proxies, so
# configure cannot --download them. If the operator hasn't pinned
# PETSC_PACKAGES_DOWNLOAD_DIR, auto-detect a pre-staged package dir under
# NETCDF_SRC_STAGE_DIR (default /shareddata/src/petsc-pkgs) and export it so
# petsc_setup.sh passes --with-packages-download-dir. Same air-gap pattern as
# NETCDF_PNETCDF_TARBALL above.
if [[ "${BUILD_PETSC}" == "1" ]] && [ -z "${PETSC_PACKAGES_DOWNLOAD_DIR:-}" ] \
     && [ -d "${NETCDF_SRC_STAGE_DIR}/petsc-pkgs" ]; then
   export PETSC_PACKAGES_DOWNLOAD_DIR="${NETCDF_SRC_STAGE_DIR}/petsc-pkgs"
   echo "petsc: using operator-staged package dir ${PETSC_PACKAGES_DOWNLOAD_DIR} (no bitbucket/ANL download)"
elif [ -n "${PETSC_PACKAGES_DOWNLOAD_DIR:-}" ]; then
   export PETSC_PACKAGES_DOWNLOAD_DIR
   echo "petsc: PETSC_PACKAGES_DOWNLOAD_DIR pinned to ${PETSC_PACKAGES_DOWNLOAD_DIR}"
fi
run_and_log_versioned petsc extras/scripts/petsc_setup.sh ${COMMON_OPTIONS} --build-petsc ${BUILD_PETSC} ${REPLACE_OPTS} ${PETSC_MPI_OPTS} \
   $(rocmplus_args rocmplus-${ROCMPLUS_SUFFIX}/petsc)

# MPI selection for elpa: same Cray-PE rationale as hdf5/netcdf/fftw/petsc/
# hypre above. ELPA links MPI (and PETSc, which itself was built against this
# same MPI), so it must use the SAME MPI -- the from-source mpich-wrappers
# (new-flang mpi.mod) when present, else cray-mpich. The leaf default MPI module
# is "openmpi" (absent on Cray -> preflight abort: "MPI module openmpi is not
# setting the MPI_PATH env variable"), so thread the right one. Non-Cray systems
# fall through to the leaf default (openmpi).
ELPA_MPI_OPTS=""
if [ -n "${MPICH_DIR:-}" ] && [ -d "${MPICH_DIR}/bin" ]; then
   if [ -e "${TOP_MODULE_PATH}/rocmplus-${ROCMPLUS_SUFFIX}/mpich-wrappers/${ROCM_VERSION}" ]; then
      ELPA_MPI_OPTS="--mpi-module mpich-wrappers"
      echo "elpa: mpich-wrappers detected; building ELPA against mpich-wrappers (PrgEnv MPI)"
   else
      ELPA_MPI_OPTS="--mpi-module cray-mpich"
      echo "elpa: Cray MPICH detected (MPICH_DIR=${MPICH_DIR}); building ELPA against cray-mpich"
   fi
fi
run_and_log_versioned elpa extras/scripts/elpa_setup.sh  ${COMMON_OPTIONS} --build-elpa ${BUILD_ELPA} ${REPLACE_OPTS} ${ELPA_MPI_OPTS} \
   $(rocmplus_args rocmplus-${ROCMPLUS_SUFFIX}/elpa)

# MPI selection for hypre: same Cray-PE rationale as hdf5/netcdf/fftw/petsc
# above. hypre builds with MPI (find_package(MPI)) and, with Fortran drivers
# enabled, needs an mpifort whose .mod format matches what users compile with.
# On a Cray that is the from-source mpich-wrappers (new LLVM Flang mpifort ->
# amdflang); else cray-mpich. The leaf default MPI module is "openmpi" (absent
# on Cray -> preflight SKIP), so thread the right one. Non-Cray systems fall
# through to the leaf default (openmpi).
HYPRE_MPI_OPTS=""
if [ -n "${MPICH_DIR:-}" ] && [ -d "${MPICH_DIR}/bin" ]; then
   if [ -e "${TOP_MODULE_PATH}/rocmplus-${ROCMPLUS_SUFFIX}/mpich-wrappers/${ROCM_VERSION}" ]; then
      HYPRE_MPI_OPTS="--mpi-module mpich-wrappers"
      echo "hypre: mpich-wrappers detected; building HYPRE against mpich-wrappers (PrgEnv MPI, new-flang mpifort/amdflang)"
   else
      HYPRE_MPI_OPTS="--mpi-module cray-mpich"
      echo "hypre: Cray MPICH detected (MPICH_DIR=${MPICH_DIR}); building HYPRE against cray-mpich"
   fi
fi
run_and_log_versioned hypre extras/scripts/hypre_setup.sh ${COMMON_OPTIONS} --build-hypre ${BUILD_HYPRE} ${REPLACE_OPTS} ${HYPRE_MPI_OPTS} \
   $(rocmplus_args rocmplus-${ROCMPLUS_SUFFIX}/hypre)

# ─── Long-pole ML builds (jax, tensorflow, pytorch, ftorch) ───────────
#
# Placed here so that the long bazel/cmake builds are done last. This
# is so that there is rapid progress and most package problems are hit early.
#
#   jax BEFORE tensorflow -- jax is the shorter of the two bazel builds,
#   pytorch BEFORE ftorch -- ftorch_setup.sh has a preflight that

run_and_log_versioned jax extras/scripts/jax_setup.sh ${COMMON_OPTIONS} --build-jax ${BUILD_JAX} ${REPLACE_OPTS} \
   $(rocmplus_args rocmplus-${ROCMPLUS_SUFFIX}/jax)

run_and_log_versioned tensorflow extras/scripts/tensorflow_setup.sh ${COMMON_OPTIONS} --build-tensorflow ${BUILD_TENSORFLOW} ${REPLACE_OPTS} \
   $(path_args tensorflow rocmplus-${ROCMPLUS_SUFFIX}/tensorflow)

run_and_log_versioned pytorch extras/scripts/pytorch_setup.sh ${COMMON_OPTIONS} --build-pytorch ${BUILD_PYTORCH} --python-version ${PYTHON_VERSION} ${REPLACE_OPTS} \
   $(rocmplus_args rocmplus-${ROCMPLUS_SUFFIX}/pytorch)

# FTorch: dispatched along TWO orthogonal axes:
#
#   1. Fortran toolchain (FTORCH_FC_COMPILER): gfortran | amdflang | both.
#      Each toolchain goes to a different install dir / Lmod module
#      (ftorch-v* vs ftorch_amdflang-v* -- the leaf script appends
#      _amdflang to the basename internally) so they coexist.
#
#   2. Bound PyTorch version (PKG_VERSIONS_REQ[pytorch]): one ftorch
#      build per pytorch version. FTorch's .so + .mod artifacts embed
#      libtorch's C++ ABI, so a single ftorch install can only serve
#      ONE pytorch version. When the operator asks for multi-pytorch
#      (e.g. --packages "pytorch=2.7.1 pytorch=2.9.1"), each pytorch
#      version gets its own ftorch install at
#         ${ROCMPLUS}/ftorch-v${PYTV}/             (gfortran)
#         ${ROCMPLUS}/ftorch_amdflang-v${PYTV}/    (amdflang)
#      with modulefile ${MODULE_PATH}/${PYTV}.lua so consumers say
#      `module load ftorch/${PYTV}` instead of the legacy
#      `module load ftorch/dev`.
#
# When no --packages tokens for pytorch are present, the loop runs
# once with NO --pytorch-version flag; the leaf script's auto-derive
# resolves the bound pytorch version from the loaded pytorch module
# (see ftorch_setup.sh's PYTORCH_VERSION resolution block). This
# preserves byte-identical behavior for the common single-pytorch
# operator workflow.
#
# Why an inline loop here (rather than run_and_log_versioned ftorch):
# run_and_log_versioned iterates over PKG_VERSIONS_REQ[<pkg_name>],
# which for `ftorch` would be FTorch's OWN upstream version axis
# (--ftorch-version <ref>, the git checkout). The "version the
# install dir by pytorch version" axis is keyed on a DIFFERENT
# package's version (pytorch's), so we drive that axis here.
#
# The FTorch upstream axis is collapsed: if --packages contains a
# `ftorch=<REF>` token, we pick the first entry from
# PKG_VERSIONS_REQ[ftorch] and pass --ftorch-version <REF> uniformly
# across every pytorch iteration. Multiple ftorch upstream tokens
# (e.g. `ftorch=0.7 ftorch=main`) are not supported as separate
# concurrent installs in this orchestrator -- the install dir is
# version-keyed by pytorch only, so two FTorch refs against the
# same pytorch would collide. If you need that, switch the dir
# naming scheme to ftorch-vpyt<PYTV>-vft<FTV>/ and re-introduce
# a nested loop here.
_ftorch_upstream_ref=""
if [[ -n "${PKG_VERSIONS_REQ[ftorch]:-}" ]]; then
   # Take the first non-empty entry. mapfile -t preserves the empty
   # entry that the parser uses for "bare ftorch token, repo HEAD";
   # we want to skip past those to the first concrete ref.
   while IFS= read -r _line; do
      if [[ -n "${_line}" ]]; then
         _ftorch_upstream_ref="${_line}"
         break
      fi
   done <<< "${PKG_VERSIONS_REQ[ftorch]}"
   unset _line
   # Count concrete entries; warn if there's more than one (we only
   # use the first per the design note above).
   _ftorch_ref_count=0
   while IFS= read -r _line; do
      [[ -n "${_line}" ]] && _ftorch_ref_count=$((_ftorch_ref_count + 1))
   done <<< "${PKG_VERSIONS_REQ[ftorch]}"
   unset _line
   if (( _ftorch_ref_count > 1 )); then
      echo "WARNING: --packages contains ${_ftorch_ref_count} ftorch=<REF> tokens; only the first ('${_ftorch_upstream_ref}') will be used."
      echo "         The ftorch install dir is version-keyed by pytorch (not by FTorch upstream ref), so multiple FTorch refs against the same pytorch would collide."
      echo "         To build multiple FTorch refs against the same pytorch, run separate sweeps with different --packages selections."
   fi
   unset _ftorch_ref_count
fi
_ftorch_upstream_args=()
[[ -n "${_ftorch_upstream_ref}" ]] && _ftorch_upstream_args=( --ftorch-version "${_ftorch_upstream_ref}" )

_ftorch_pyt_versions=()
if [[ -z "${PKG_VERSIONS_REQ[pytorch]+SET}" ]]; then
   # No --packages whitelist (or it didn't include pytorch): single
   # iteration, no version flag, leaf auto-derive picks up whichever
   # pytorch module is the Lmod default at build time.
   _ftorch_pyt_versions=("")
else
   # mapfile -t preserves the empty-entry semantics that the parser
   # uses for "bare pytorch token, leaf default". An empty entry here
   # drives the same auto-derive path as the no-PKG_VERSIONS_REQ case.
   mapfile -t _ftorch_pyt_versions <<< "${PKG_VERSIONS_REQ[pytorch]}"
fi

case "${FTORCH_FC_COMPILER}" in
   gfortran|amdflang|both) ;;
   *)
      echo "ERROR: unrecognized FTORCH_FC_COMPILER='${FTORCH_FC_COMPILER}' (expected: gfortran|amdflang|both)" >&2
      exit 1
      ;;
esac

for _pyt_ver in "${_ftorch_pyt_versions[@]}"; do
   if [[ -z "${_pyt_ver}" ]]; then
      _pyt_args=()
      _label_suffix=""
   else
      # Pin BOTH:
      #   --pytorch-version: tells the leaf script what to encode in
      #     the install dir / modulefile name (and what to put in the
      #     whatis() lines).
      #   --pytorch-module:  tells the leaf's preflight which exact
      #     pytorch modulefile to load (so cmake links against the
      #     matching libtorch). The bare `pytorch` default would let
      #     Lmod pick its current default, which silently mismatches
      #     in a multi-pytorch tree.
      _pyt_args=( --pytorch-version "${_pyt_ver}" --pytorch-module "pytorch/${_pyt_ver}" )
      # Per-iteration label so the per-package log file +
      # SUCCESS/FAILED/DESELECTED summary surface this iteration
      # distinctly. Mirrors run_and_log_versioned's "_v<VER>" label
      # convention (we use _v<VER> here too -- it's the install-dir
      # version by definition, just keyed on pytorch).
      _label_suffix="_v${_pyt_ver}"
   fi

   case "${FTORCH_FC_COMPILER}" in
      gfortran|both)
         _label="ftorch${_label_suffix}"
         # Mirror DESELECTED_BY so a deselected ftorch (BUILD_FTORCH=0
         # via --quick-installs or --packages-whitelist-excluded)
         # produces the concise one-line marker for this versioned
         # iteration instead of the verbose 3-line "SKIP" banner.
         if [[ -n "${DESELECTED_BY[ftorch]:-}" ]]; then
            DESELECTED_BY[${_label}]="${DESELECTED_BY[ftorch]}"
         fi
         run_and_log "${_label}" extras/scripts/ftorch_setup.sh ${COMMON_OPTIONS} \
            --build-ftorch ${BUILD_FTORCH} --fc-compiler gfortran ${REPLACE_OPTS} \
            "${_pyt_args[@]}" \
            "${_ftorch_upstream_args[@]}" \
            $(path_args ftorch rocmplus-${ROCMPLUS_SUFFIX}/ftorch)
         ;;
   esac
   case "${FTORCH_FC_COMPILER}" in
      amdflang|both)
         _label="ftorch_amdflang${_label_suffix}"
         if [[ -n "${DESELECTED_BY[ftorch_amdflang]:-}" ]]; then
            DESELECTED_BY[${_label}]="${DESELECTED_BY[ftorch_amdflang]}"
         fi
         run_and_log "${_label}" extras/scripts/ftorch_setup.sh ${COMMON_OPTIONS} \
            --build-ftorch ${BUILD_FTORCH} --fc-compiler amdflang ${REPLACE_OPTS} \
            "${_pyt_args[@]}" \
            "${_ftorch_upstream_args[@]}" \
            $(path_args ftorch rocmplus-${ROCMPLUS_SUFFIX}/ftorch)
         ;;
   esac
done
unset _ftorch_pyt_versions _pyt_ver _pyt_args _label _label_suffix _ftorch_upstream_ref _ftorch_upstream_args

#If ROCm should be installed in a different location
#if [ "${ROCM_INSTALLPATH}" != "/opt/" ]; then
#   ${SUDO} mv /opt/rocm-${ROCM_VERSION} ${ROCM_INSTALLPATH}
#   ${SUDO} mv /opt/rocmplus-${ROCMPLUS_SUFFIX} ${ROCM_INSTALLPATH}
#   ${SUDO} ln -sfn ${ROCM_INSTALLPATH}/rocm-${ROCM_VERSION} /etc/alternatives/rocm
#   ${SUDO} sed -i "s|\/opt\/|${ROCM_INSTALLPATH}|" /etc/lmod/modules/ROCm/*/*.lua
#fi

#run_and_log hpctrainingexamples git clone https://github.com/AMD/HPCTrainingExamples.git
