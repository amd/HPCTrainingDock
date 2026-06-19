#!/bin/bash
#
# leaf_modulefile_helpers.sh -- shared functions for the install-only leaf
# scripts (run_rocm_afar_install.sh, run_rocm_therock_afar_install.sh,
# run_rocm_therock_install.sh).
#
# Source-only (no top-level side effects); each leaf script calls the
# functions defined here after writing its parent rocm/<v> modulefile.
#
# ----------------------------------------------------------------------------
# emit_per_package_modulefiles -- write amdclang / hipfort / opencl modulefiles
# under ${mod_subdir}/{amdclang,hipfort,opencl}/<ver>.lua, mirroring the shape
# of the modulefiles emitted by the in-container rocm/scripts/rocm_setup.sh
# (and packaged via bare_system/deploy_module_package.sh) for regular numeric
# SDK builds.  The reference layout is:
#
#   ${TOP_MODULE_PATH}/rocm-<v>/amdclang/<AMDCLANG_VER>-<v>.lua
#   ${TOP_MODULE_PATH}/rocm-<v>/hipfort/<v>.lua
#   ${TOP_MODULE_PATH}/rocm-<v>/opencl/<v>.lua
#
# For AFAR / TheRock-AFAR / TheRock-proper installs the install-only leaf
# scripts skip the in-container Makefile path entirely, so this helper exists
# to close that gap.
#
# Each emission is feature-gated on the actual presence of the relevant SDK
# component in ${install_dir}, because AFAR and TheRock-AFAR drops don't
# always carry opencl/ or include/hipfort/ -- writing a modulefile that points
# at non-existent paths would just confuse users.
#
# Args (positional):
#   $1 mod_subdir     destination dir, e.g. ${TOP_MODULE_PATH}/rocm-afar-22.1.0
#                     (matches the rocm-* MODULEPATH prepend in the parent
#                     rocm/<v> modulefile so the secondary modules are
#                     visible once the parent is loaded)
#   $2 version_label  the version suffix used in filenames + whatis(Version),
#                     typically ${ROCM_NUMERIC}
#   $3 parent_module  e.g. rocm/afar-22.1.0-7.1.0 -- used as prereq() in the
#                     amdclang modulefile so lmod refuses to load it on its
#                     own
#   $4 install_dir    SDK install root, e.g. /nfsapps/opt/rocm-afar-22.1.0
#   $5 leaf_name      basename of the caller (for whatis Built-by)
#   $6 leaf_commit    short git sha of the caller (12 chars or "unknown")
#   $7 leaf_dirty     "clean" / "dirty" / "unknown"
#
# Writes (sudo, root:root, 0644):
#   ${mod_subdir}/amdclang/<AMDCLANG_VER>-<version_label>.lua  (if amdclang present)
#   ${mod_subdir}/hipfort/<version_label>.lua                  (if include/hipfort present)
#   ${mod_subdir}/opencl/<version_label>.lua                   (if opencl/bin present)
#
# Prints a one-line per-package status (`+ <path>` for emit, `- <pkg> skipped`
# for the gated-off case) so each leaf script's stdout shows exactly what
# landed.
# ----------------------------------------------------------------------------
emit_per_package_modulefiles() {
   local _mod_subdir="$1"
   local _version_label="$2"
   local _parent_module="$3"
   local _install_dir="$4"
   local _leaf_name="$5"
   local _leaf_commit="$6"
   local _leaf_dirty="$7"

   if [[ -z "${_mod_subdir}"    || -z "${_version_label}" || \
         -z "${_parent_module}" || -z "${_install_dir}"   || \
         -z "${_leaf_name}"     || -z "${_leaf_commit}"   || \
         -z "${_leaf_dirty}" ]]; then
      echo "ERROR: emit_per_package_modulefiles: all 7 args are required" >&2
      return 2
   fi

   # Honor the caller's sudo / Cray decisions (sourced into the same shell, so
   # these globals are visible). Defaults keep the original root-owned .lua
   # behavior for callers that don't set them.
   local _sudo="${SUDO-sudo}"
   local _cray="${CRAY_SYSTEM:-0}"
   local _ext=".lua"; [ "${_cray}" = "1" ] && _ext=""
   # chown to root only when running with sudo; no-op otherwise.
   _chown_root() { [ -z "${_sudo}" ] && return 0; ${_sudo} chown "$@"; }

   echo "[per-package modulefiles] target dir: ${_mod_subdir}"
   echo "[per-package modulefiles] parent module: ${_parent_module}"
   echo "[per-package modulefiles] version label: ${_version_label}  (cray=${_cray}, sudo='${_sudo}')"

   # ---------------- amdclang ----------------------------------------------
   # Unified regex: matches "AMD clang version 22.0.0git ..." (numeric +
   # AFAR-proper trees) AND "AMD AFAR drop #23.X.Y ... clang version
   # 23.0.0git ..." (TheRock-AFAR trees) -- both produce the actual AMD
   # clang major.minor.patch.
   if [[ -x "${_install_dir}/llvm/bin/amdclang" ]]; then
      local _amdclang_ver
      _amdclang_ver=$("${_install_dir}/llvm/bin/amdclang" --version 2>/dev/null | head -1 \
                       | grep -oE 'clang version [^ ]+' \
                       | awk '{print $3}' | tr -d -c '[:digit:]\.')
      [[ -z "${_amdclang_ver}" ]] && _amdclang_ver="unknown"
      # Cray Tcl uses a clean version-only basename (matches the in-container
      # rocm_setup.sh Cray branch); Lmod keeps the <clangver>-<label> form.
      local _amdclang_file
      if [ "${_cray}" = "1" ]; then
         _amdclang_file="${_mod_subdir}/amdclang/${_version_label}"
      else
         _amdclang_file="${_mod_subdir}/amdclang/${_amdclang_ver}-${_version_label}.lua"
      fi
      ${_sudo} mkdir -p "${_mod_subdir}/amdclang"
      if [ "${_cray}" = "1" ]; then
      ${_sudo} tee "${_amdclang_file}" >/dev/null <<EOF
#%Module
# AMDCLANG ${_version_label}  -- Built by: ${_leaf_name}@${_leaf_commit} (${_leaf_dirty})
conflict amdclang
module-whatis "AMDCLANG ${_version_label} (AMD LLVM compiler drivers)"
prereq ${_parent_module}
set base      ${_install_dir}/llvm
set rocm_base ${_install_dir}
setenv CC          \$base/bin/amdclang
setenv CXX         \$base/bin/amdclang++
setenv FC          \$base/bin/amdflang
setenv OMPI_CC     \$base/bin/amdclang
setenv OMPI_CXX    \$base/bin/amdclang++
setenv OMPI_FC     \$base/bin/amdflang
setenv F77         \$base/bin/amdflang
setenv F90         \$base/bin/amdflang
setenv STDPAR_PATH \$rocm_base/include/thrust/system/hip/hipstdpar
setenv STDPAR_CXX  \$base/bin/amdclang++
prepend-path PATH            \$base/bin
prepend-path LD_LIBRARY_PATH \$base/lib
prepend-path LD_RUN_PATH     \$base/lib
prepend-path CPATH           \$base/include
EOF
      else
      ${_sudo} tee "${_amdclang_file}" >/dev/null <<EOF
whatis("Name: AMDCLANG")
whatis("Built by: ${_leaf_name}@${_leaf_commit} (${_leaf_dirty})")
whatis("Version: ${_version_label}")
whatis("Category: AMD")
whatis("AMDCLANG")

local base      = "${_install_dir}/llvm"
local rocm_base = "${_install_dir}"

setenv("CC",       pathJoin(base, "bin/amdclang"))
setenv("CXX",      pathJoin(base, "bin/amdclang++"))
setenv("FC",       pathJoin(base, "bin/amdflang"))
setenv("OMPI_CC",  pathJoin(base, "bin/amdclang"))
setenv("OMPI_CXX", pathJoin(base, "bin/amdclang++"))
setenv("OMPI_FC",  pathJoin(base, "bin/amdflang"))
setenv("F77",      pathJoin(base, "bin/amdflang"))
setenv("F90",      pathJoin(base, "bin/amdflang"))
setenv("STDPAR_PATH", pathJoin(rocm_base, "include/thrust/system/hip/hipstdpar"))
setenv("STDPAR_CXX",  pathJoin(base, "bin/amdclang++"))
prepend_path("PATH",            pathJoin(base, "bin"))
prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
prepend_path("LD_RUN_PATH",     pathJoin(base, "lib"))
prepend_path("CPATH",           pathJoin(base, "include"))
prereq("${_parent_module}")
family("compiler")
EOF
      fi
      _chown_root root:root "${_amdclang_file}"
      ${_sudo} chmod 644 "${_amdclang_file}"
      echo "  + ${_amdclang_file}"
   else
      echo "  - amdclang skipped (no ${_install_dir}/llvm/bin/amdclang)"
   fi

   # ---------------- hipfort ----------------------------------------------
   if [[ -d "${_install_dir}/include/hipfort" ]]; then
      local _hipfort_file="${_mod_subdir}/hipfort/${_version_label}${_ext}"
      ${_sudo} mkdir -p "${_mod_subdir}/hipfort"
      if [ "${_cray}" = "1" ]; then
      ${_sudo} tee "${_hipfort_file}" >/dev/null <<EOF
#%Module
# ROCm HIPFort ${_version_label}  -- Built by: ${_leaf_name}@${_leaf_commit} (${_leaf_dirty})
module-whatis "ROCm HIPFort ${_version_label}"
module load amdclang/${_version_label}
set base ${_install_dir}
append-path  LD_LIBRARY_PATH \$base/lib
setenv LIBS        "-L\$base/lib -lhipfort-amdgcn.a"
setenv HIPFORT_LIB \$base/lib
setenv HIPFORT_INC \$base/include/hipfort
EOF
      else
      ${_sudo} tee "${_hipfort_file}" >/dev/null <<EOF
whatis("Name: ROCm HIPFort")
whatis("Built by: ${_leaf_name}@${_leaf_commit} (${_leaf_dirty})")
whatis("Version: ${_version_label}")
load("amdclang")
local base = "${_install_dir}"
append_path("LD_LIBRARY_PATH", pathJoin(base, "/lib"))
setenv("LIBS", "-L" .. pathJoin(base, "/lib") .. " -lhipfort-amdgcn.a")
setenv("HIPFORT_LIB", pathJoin(base, "/lib"))
setenv("HIPFORT_INC", pathJoin(base, "/include/hipfort"))
EOF
      fi
      _chown_root root:root "${_hipfort_file}"
      ${_sudo} chmod 644 "${_hipfort_file}"
      echo "  + ${_hipfort_file}"
   else
      echo "  - hipfort skipped (no ${_install_dir}/include/hipfort)"
   fi

   # ---------------- opencl ----------------------------------------------
   if [[ -d "${_install_dir}/opencl/bin" ]]; then
      local _opencl_file="${_mod_subdir}/opencl/${_version_label}${_ext}"
      ${_sudo} mkdir -p "${_mod_subdir}/opencl"
      if [ "${_cray}" = "1" ]; then
      ${_sudo} tee "${_opencl_file}" >/dev/null <<EOF
#%Module
# ROCm OpenCL ${_version_label}  -- Built by: ${_leaf_name}@${_leaf_commit} (${_leaf_dirty})
conflict opencl
module-whatis "ROCm OpenCL ${_version_label}"
set base ${_install_dir}/opencl
prepend-path PATH \$base/bin
EOF
      else
      ${_sudo} tee "${_opencl_file}" >/dev/null <<EOF
whatis("Name: ROCm OpenCL")
whatis("Built by: ${_leaf_name}@${_leaf_commit} (${_leaf_dirty})")
whatis("Version: ${_version_label}")
whatis("Category: AMD")
whatis("ROCm OpenCL")

local base = "${_install_dir}/opencl"

prepend_path("PATH", pathJoin(base, "bin"))
family("OpenCL")
EOF
      fi
      _chown_root root:root "${_opencl_file}"
      ${_sudo} chmod 644 "${_opencl_file}"
      echo "  + ${_opencl_file}"
   else
      echo "  - opencl skipped (no ${_install_dir}/opencl/bin)"
   fi
}

# ----------------------------------------------------------------------------
# emit_rocm_pc -- write a versioned pkg-config file into the SDK install tree:
#
#   ${install_dir}/lib/pkgconfig/rocm-<rocm_numeric>.pc
#
# The Cray cc/CC/ftn compiler wrappers resolve build/link flags for the
# `rocm-<ver>` product (registered in PE_PKGCONFIG_LIBS by the rocm-new
# modulefile) through pkg-config. Stock Cray ships these under
# /usr/lib64/pkgconfig via craypkg-gen, but (a) that tree is root-only, (b) it
# diverges between login and compute node images, and (c) it never carries a
# TheRock build's version. Shipping the .pc INSIDE the install tree (on shared
# storage) makes it visible identically on every node. This mirrors the
# craypkg-gen 1.3.37 output (e.g. /usr/lib64/pkgconfig/rocm-7.2.1.pc), but the
# roctracer include/lib dirs are advertised only when present (TheRock proper
# ships roctracer but no rocprofiler tree).
#
# Args (positional):
#   $1 install_dir    SDK install root, e.g. /nfsapps/opt/rocm-therock-7.13.0
#   $2 rocm_numeric   .info/version-derived numeric, e.g. 7.13.0
#
# Writes (honoring ${SUDO}): ${install_dir}/lib/pkgconfig/rocm-${rocm_numeric}.pc
# ----------------------------------------------------------------------------
emit_rocm_pc() {
   local _install_dir="$1"
   local _rocm="$2"
   if [[ -z "${_install_dir}" || -z "${_rocm}" ]]; then
      echo "ERROR: emit_rocm_pc: install_dir and rocm_numeric are required" >&2
      return 2
   fi
   local _sudo="${SUDO-sudo}"
   _chown_root() { [ -z "${_sudo}" ] && return 0; ${_sudo} chown "$@"; }

   local _pcdir="${_install_dir}/lib/pkgconfig"
   local _pcfile="${_pcdir}/rocm-${_rocm}.pc"
   ${_sudo} mkdir -p "${_pcdir}"

   # Feature-gate the roctracer dirs. Note: pkg-config variable refs (e.g.
   # ${includedir}) are escaped as \${...} so they stay literal in the file;
   # only the bash vars ${_install_dir}/${_rocm} expand.
   local _has_tracer=0
   [[ -d "${_install_dir}/include/roctracer" && -d "${_install_dir}/lib/roctracer" ]] && _has_tracer=1

   if [ "${_has_tracer}" = "1" ]; then
   ${_sudo} tee "${_pcfile}" >/dev/null <<EOF
# Generated by leaf_modulefile_helpers.sh:emit_rocm_pc to mirror craypkg-gen
# 1.3.37 output (e.g. /usr/lib64/pkgconfig/rocm-7.2.1.pc) for a TheRock install.
# Lets the Cray cc/CC/ftn wrappers resolve the rocm-${_rocm} product registered
# in PE_PKGCONFIG_LIBS by the rocm-new modulefile.

Name: rocm-${_rocm}
Version: ${_rocm}
Description: ROCm Toolkit (local TheRock build)

rocm_prefix=${_install_dir}
includedir=\${rocm_prefix}/include
libdir=\${rocm_prefix}/lib

tracer_includedir=\${rocm_prefix}/include/roctracer
tracer_libdir=\${rocm_prefix}/lib/roctracer

Cflags: -I\${includedir} -I\${tracer_includedir} -D__HIP_PLATFORM_AMD__
Libs: -L\${libdir} -L\${tracer_libdir} -lamdhip64
EOF
   else
   ${_sudo} tee "${_pcfile}" >/dev/null <<EOF
# Generated by leaf_modulefile_helpers.sh:emit_rocm_pc to mirror craypkg-gen
# 1.3.37 output for a TheRock install. Lets the Cray cc/CC/ftn wrappers resolve
# the rocm-${_rocm} product registered in PE_PKGCONFIG_LIBS by rocm-new.
# (roctracer not present in this dist -> not advertised.)

Name: rocm-${_rocm}
Version: ${_rocm}
Description: ROCm Toolkit (local TheRock build)

rocm_prefix=${_install_dir}
includedir=\${rocm_prefix}/include
libdir=\${rocm_prefix}/lib

Cflags: -I\${includedir} -D__HIP_PLATFORM_AMD__
Libs: -L\${libdir} -lamdhip64
EOF
   fi
   _chown_root root:root "${_pcfile}"
   ${_sudo} chmod 644 "${_pcfile}"
   echo "  + ${_pcfile} (roctracer=${_has_tracer})"
}

# ----------------------------------------------------------------------------
# emit_cray_prgenv_ecosystem -- write the Cray-style classic Tcl modules that
# expose a TheRock install the way stock Cray PrgEnv exposes the system ROCm,
# so it can be loaded with `module swap PrgEnv-cray PrgEnv-amd-new/<pe>-<rocm>`.
#
# Five modulefiles are written under ${cray_dir} (a tree the operator exposes
# with `module use`, e.g. $HOME/modulefiles/cray):
#
#   rocm-new/<rocm>                  ROCm toolkit (mirrors stock rocm/<sys>);
#                                    wires PKG_CONFIG_PATH at the in-tree
#                                    lib/pkgconfig so the .pc from emit_rocm_pc
#                                    is found by the craype wrappers.
#   amd-new/<rocm>                   AMD LLVM compiler (mirrors stock amd/<sys>);
#                                    pulls in the matching rocm-new.
#   PrgEnv-amd-new/<pe>-<rocm>       PrgEnv-amd <pe> equivalent that loads the
#                                    stock PrgEnv-amd/<pe> then the -new modules.
#   amd/<rocm>, rocm/<rocm>          thin wrappers so bare `module load amd` /
#                                    `module load rocm` (incl. the one stock
#                                    PrgEnv-amd issues internally) resolve to
#                                    the -new modules.
#
# CC/CXX/FC are deliberately left UNSET (like stock amd/rocm): the craype
# cc/CC/ftn wrappers remain the compilers, driven by PE_ENV=AMD +
# CRAY_AMD_COMPILER_PREFIX.
#
# Args (positional):
#   $1 cray_dir       module tree root, e.g. ${TOP_MODULE_PATH}/cray
#   $2 rocm_numeric   .info/version-derived numeric, e.g. 7.13.0
#   $3 install_dir    SDK install root, e.g. /nfsapps/opt/rocm-therock-7.13.0
#   $4 pe_version     stock PrgEnv-amd version to wrap, e.g. 8.7.0
#   $5 leaf_name      basename of the caller (for provenance comment)
#   $6 leaf_commit    short git sha of the caller (12 chars or "unknown")
#   $7 leaf_dirty     "clean" / "dirty" / "unknown"
# ----------------------------------------------------------------------------
emit_cray_prgenv_ecosystem() {
   local _cray_dir="$1"
   local _rocm="$2"
   local _install="$3"
   local _pe="$4"
   local _leaf_name="$5"
   local _leaf_commit="$6"
   local _leaf_dirty="$7"

   if [[ -z "${_cray_dir}" || -z "${_rocm}" || -z "${_install}" || \
         -z "${_pe}"       || -z "${_leaf_name}" || -z "${_leaf_commit}" || \
         -z "${_leaf_dirty}" ]]; then
      echo "ERROR: emit_cray_prgenv_ecosystem: all 7 args are required" >&2
      return 2
   fi

   local _sudo="${SUDO-sudo}"
   _chown_root() { [ -z "${_sudo}" ] && return 0; ${_sudo} chown "$@"; }
   local _prov="${_leaf_name}@${_leaf_commit} (${_leaf_dirty})"

   echo "[cray prgenv ecosystem] target dir: ${_cray_dir}"
   echo "[cray prgenv ecosystem] rocm=${_rocm}  pe=${_pe}  (sudo='${_sudo}')"

   ${_sudo} mkdir -p "${_cray_dir}/rocm-new" "${_cray_dir}/amd-new" \
                     "${_cray_dir}/PrgEnv-amd-new" "${_cray_dir}/amd" \
                     "${_cray_dir}/rocm"

   # ---------------- rocm-new/<rocm> ---------------------------------------
   local _f="${_cray_dir}/rocm-new/${_rocm}"
   ${_sudo} tee "${_f}" >/dev/null <<EOF
#%Module
#
# rocm-new/${_rocm}  -- Built by: ${_prov}
#
# Mirrors the stock Cray rocm/<sys> module but points at the local TheRock
# ${_rocm} install. Classic Tcl (Cray PE login nodes ship Environment Modules,
# no Lmod). Paths the TheRock dist does not ship (rocprofiler) are guarded so
# we never advertise a non-existent directory.

# Self-conflict only. We intentionally do NOT \`conflict rocm\`: the sibling
# \`rocm\` modulefile in this tree is a thin wrapper that loads THIS module, and
# \`conflict rocm\` would make that wrapper self-conflict.
conflict rocm-new

proc ModulesHelp {} {
    puts stderr "Local TheRock ROCm ${_rocm} toolkit (mirrors Cray rocm/<sys>)."
}

module-whatis "Local TheRock ROCm ${_rocm} toolkit: system paths + variables."

## template variables ##
set MOD_LEVEL         ${_rocm}
set AMD_CURPATH       ${_install}
# Stock Cray rocm modules point PKG_CONFIG at /usr/lib64/pkgconfig, but that
# tree is root-only, diverges between login and compute node images, and has no
# rocm-${_rocm}.pc. We ship rocm-${_rocm}.pc inside the install tree
# (lib/pkgconfig, via emit_rocm_pc) and point PKG_CONFIG_PATH there so the
# craype cc/CC/ftn wrappers can resolve the \`rocm-${_rocm}\` product.
set PKG_CONFIG_PREFIX \$AMD_CURPATH/lib

# CPE variables
set CPE_PRODUCT_NAME      CRAY_ROCM
set CPE_PKGCONFIG_LIB     rocm-\$MOD_LEVEL
set CPE_PKGCONFIG_PATH    \$PKG_CONFIG_PREFIX/pkgconfig

# AMD paths used below
set AMD_LIB           \$AMD_CURPATH/lib
set AMD_BIN           \$AMD_CURPATH/bin
set AMD_INCLUDE       \$AMD_CURPATH/include
set AMD_MAN           \$AMD_CURPATH/share/man
set AMD_ROCT_LIB      \$AMD_CURPATH/lib/roctracer
set AMD_ROCT_INCLUDE  \$AMD_CURPATH/include/roctracer
set AMD_HIP_CMAKE     \$AMD_CURPATH/lib/cmake/hip
set AMD_HIP_INCLUDE   \$AMD_CURPATH/include/hip

## environment modifications ##

# craype uses CRAY_ROCM_DIR to find the ROCm install
setenv CRAY_ROCM_DIR      \$AMD_CURPATH
setenv CRAY_ROCM_PREFIX   \$AMD_CURPATH
setenv CRAY_ROCM_VERSION  \$MOD_LEVEL
setenv ROCM_PATH          \$AMD_CURPATH
setenv HIP_LIB_PATH       \$AMD_LIB

prepend-path PATH         \$AMD_BIN
if {[file isdirectory \$AMD_MAN]} { prepend-path MANPATH \$AMD_MAN }
if {[file isdirectory \$AMD_HIP_CMAKE]} { prepend-path CMAKE_PREFIX_PATH \$AMD_HIP_CMAKE }

# perftools include opts -- only advertise dirs that exist in the TheRock dist
set inc_opts "-I\$AMD_INCLUDE"
if {[file isdirectory \$AMD_ROCT_INCLUDE]} { append inc_opts " -I\$AMD_ROCT_INCLUDE" }
if {[file isdirectory \$AMD_HIP_INCLUDE]}  { append inc_opts " -I\$AMD_HIP_INCLUDE" }
append inc_opts " -D__HIP_PLATFORM_AMD__"
setenv CRAY_ROCM_INCLUDE_OPTS \$inc_opts

set post_link "-L\$AMD_LIB"
if {[file isdirectory \$AMD_ROCT_LIB]} { append post_link " -L\$AMD_ROCT_LIB" }
append post_link " -lamdhip64"
setenv CRAY_ROCM_POST_LINK_OPTS \$post_link

prepend-path LD_LIBRARY_PATH    \$AMD_LIB
if {[file isdirectory \$AMD_ROCT_LIB]} { prepend-path LD_LIBRARY_PATH \$AMD_ROCT_LIB }

# Add to the current CPE product list
append-path PE_PRODUCT_LIST     \$CPE_PRODUCT_NAME
prepend-path PKG_CONFIG_PATH    \$CPE_PKGCONFIG_PATH
prepend-path PE_PKGCONFIG_LIBS  \$CPE_PKGCONFIG_LIB
EOF
   _chown_root root:root "${_f}"; ${_sudo} chmod 644 "${_f}"; echo "  + ${_f}"

   # ---------------- amd-new/<rocm> ----------------------------------------
   _f="${_cray_dir}/amd-new/${_rocm}"
   ${_sudo} tee "${_f}" >/dev/null <<EOF
#%Module
#
# amd-new/${_rocm}  -- Built by: ${_prov}
#
# AMD LLVM compiler from the local TheRock ${_rocm} install. Mirrors the stock
# Cray amd/<sys> compiler module.
#
# IMPORTANT: like stock amd/<sys>, this module deliberately does NOT set
# CC/CXX/FC. Under PrgEnv-amd the craype wrappers (cc, CC, ftn) are the
# compilers; they locate the AMD LLVM toolchain via PE_ENV=AMD +
# CRAY_AMD_COMPILER_PREFIX (set below). Setting CC/CXX/FC would bypass them.

# Self-conflict only (the sibling \`amd\` wrapper loads THIS module).
conflict amd-new

module-whatis "AMD LLVM Compiler (local TheRock ${_rocm}); mirrors amd/<sys>."

set ROCM_NEW ${_install}

prepend-path PATH                \$ROCM_NEW/bin
prepend-path C_INCLUDE_PATH      \$ROCM_NEW/llvm/include
prepend-path CPLUS_INCLUDE_PATH  \$ROCM_NEW/llvm/include
prepend-path CMAKE_PREFIX_PATH   \$ROCM_NEW
setenv ROCM_COMPILER_PATH        \$ROCM_NEW/llvm
setenv ROCM_COMPILER_VERSION     ${_rocm}
setenv CRAY_AMD_COMPILER_PREFIX  \$ROCM_NEW
setenv CRAY_AMD_COMPILER_VERSION ${_rocm}
# Cray-native: make the ftn/cc/CC wrappers drive the new LLVM amdflang/amdclang
# (unset would fall back to flang-classic and emit an 'Unrecognized' warning).
setenv AMD_COMPILER_TYPE         DEFAULT
prepend-path LD_LIBRARY_PATH     \$ROCM_NEW/llvm/lib
prepend-path LD_LIBRARY_PATH     \$ROCM_NEW/lib

# Bring in the matching ROCm ${_rocm} runtime so loading the compiler also sets
# the ROCm paths. Swap out any already-loaded stock rocm; else load ours.
# Guarded on load/switch2 so it is a no-op in whatis/display modes.
if {[module-info mode load] || [module-info mode switch2]} {
    if {[is-loaded rocm]} {
        module swap rocm rocm-new/${_rocm}
    } elseif {![is-loaded rocm-new/${_rocm}]} {
        module load rocm-new/${_rocm}
    }
}
if {[module-info mode remove] || [module-info mode switch1]} {
    if {[is-loaded rocm-new/${_rocm}]} { module unload rocm-new/${_rocm} }
}
EOF
   _chown_root root:root "${_f}"; ${_sudo} chmod 644 "${_f}"; echo "  + ${_f}"

   # ---------------- PrgEnv-amd-new/<pe>-<rocm> ----------------------------
   _f="${_cray_dir}/PrgEnv-amd-new/${_pe}-${_rocm}"
   ${_sudo} tee "${_f}" >/dev/null <<EOF
#%Module
#
# PrgEnv-amd-new/${_pe}-${_rocm}  -- Built by: ${_prov}
#
# A "PrgEnv-amd/${_pe} equivalent" that brings up the standard Cray AMD
# programming environment (PE_ENV=AMD, the craype cc/CC/ftn wrappers,
# cray-mpich, cray-libsci, ...) and then specializes the compiler + ROCm to
# the local TheRock ${_rocm} install:
#
#     amd  -> amd-new/${_rocm}     (AMD LLVM compiler from TheRock ${_rocm})
#     rocm -> rocm-new/${_rocm}    (ROCm toolkit from TheRock ${_rocm})
#
# It loads the stock PrgEnv-amd/${_pe} (so all the Cray PE wiring is inherited
# verbatim) and then swaps in the two -new modules.
#
# CC/CXX/FC are deliberately left UNSET: the Cray wrappers cc/CC/ftn remain the
# compilers (driven via PE_ENV=AMD + CRAY_AMD_COMPILER_PREFIX).
#
# Use it like any Cray PrgEnv, by swapping out the active one:
#     module use <this tree>
#     module swap PrgEnv-cray PrgEnv-amd-new/${_pe}-${_rocm}

module-whatis "PrgEnv-amd ${_pe} specialized to local TheRock amd-new/${_rocm} + rocm-new/${_rocm}."

# Mutually exclusive with the other programming environments. We intentionally
# do NOT conflict PrgEnv-amd, because we load it internally to inherit its PE
# wiring.
conflict PrgEnv-amd-new
conflict PrgEnv-cray
conflict PrgEnv-aocc
conflict PrgEnv-gnu
conflict PrgEnv-intel
conflict PrgEnv-nvidia

# During \`module swap A PrgEnv-amd-new\`, this file is evaluated in mode
# "switch2" (not "load"); during \`module swap PrgEnv-amd-new B\` it is "switch1"
# (not "remove"). Treat both pairs the same -- this mirrors stock PrgEnv-amd.
set _do_load   [expr {[module-info mode load]   || [module-info mode switch2]}]
set _do_remove [expr {[module-info mode remove] || [module-info mode switch1]}]

if {\$_do_load} {
    # Stock AMD PrgEnv: PE_ENV=AMD + craype wrappers + cray-mpich/libsci. Its
    # internal \`module load amd\` resolves (via the amd/${_rocm} wrapper in this
    # tree) to amd-new/${_rocm}, so the compiler it brings in is the local one.
    if {![is-loaded PrgEnv-amd]} {
        module load PrgEnv-amd/${_pe}
    }
    # Belt-and-suspenders: ensure the local compiler is loaded even if a future
    # PrgEnv-amd stops auto-loading a compiler. amd-new/${_rocm} itself brings
    # in the matching rocm-new/${_rocm} runtime, so rocm is not handled here.
    if {![is-loaded amd-new/${_rocm}]} {
        module load amd-new/${_rocm}
    }
    # Final guard: if something unusual left the stock rocm loaded, swap it.
    if {[is-loaded rocm]} {
        module swap rocm rocm-new/${_rocm}
    } elseif {![is-loaded rocm-new/${_rocm}]} {
        module load rocm-new/${_rocm}
    }
}

if {\$_do_remove} {
    if {[is-loaded rocm-new/${_rocm}]} { module unload rocm-new/${_rocm} }
    if {[is-loaded amd-new/${_rocm}]}  { module unload amd-new/${_rocm} }
    if {[is-loaded amd/${_rocm}]}      { module unload amd/${_rocm} }
    if {[is-loaded PrgEnv-amd]}        { module unload PrgEnv-amd/${_pe} }
}
EOF
   _chown_root root:root "${_f}"; ${_sudo} chmod 644 "${_f}"; echo "  + ${_f}"

   # ---------------- amd/<rocm> (thin wrapper) -----------------------------
   _f="${_cray_dir}/amd/${_rocm}"
   ${_sudo} tee "${_f}" >/dev/null <<EOF
#%Module
#
# amd/${_rocm}  -- Built by: ${_prov}
#
# Thin wrapper so that \`module load amd\` resolves to the local TheRock compiler
# amd-new/${_rocm}. This includes the bare \`module load amd\` that stock
# PrgEnv-amd issues internally. Lives in the prepended cray module tree, so it
# wins over the stock /opt/modulefiles/amd (which has no default version and
# would error).
#
module-whatis "Alias for amd-new/${_rocm} (local TheRock AMD LLVM compiler)."
module load amd-new/${_rocm}
EOF
   _chown_root root:root "${_f}"; ${_sudo} chmod 644 "${_f}"; echo "  + ${_f}"

   # ---------------- rocm/<rocm> (thin wrapper) ----------------------------
   _f="${_cray_dir}/rocm/${_rocm}"
   ${_sudo} tee "${_f}" >/dev/null <<EOF
#%Module
#
# rocm/${_rocm}  -- Built by: ${_prov}
#
# Thin wrapper so that \`module load rocm\` resolves to the local TheRock toolkit
# rocm-new/${_rocm}. Lives in the prepended cray module tree, so it wins over
# the stock /opt/modulefiles/rocm. (To replace an already-loaded stock rocm,
# swap it: \`module swap rocm rocm/${_rocm}\`.)
#
module-whatis "Alias for rocm-new/${_rocm} (local TheRock ROCm ${_rocm} toolkit)."
module load rocm-new/${_rocm}
EOF
   _chown_root root:root "${_f}"; ${_sudo} chmod 644 "${_f}"; echo "  + ${_f}"
}
