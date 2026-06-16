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

   echo "[per-package modulefiles] target dir: ${_mod_subdir}"
   echo "[per-package modulefiles] parent module: ${_parent_module}"
   echo "[per-package modulefiles] version label: ${_version_label}"

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
      local _amdclang_file="${_mod_subdir}/amdclang/${_amdclang_ver}-${_version_label}.lua"
      sudo mkdir -p "${_mod_subdir}/amdclang"
      sudo tee "${_amdclang_file}" >/dev/null <<EOF
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
      sudo chown root:root "${_amdclang_file}"
      sudo chmod 644 "${_amdclang_file}"
      echo "  + ${_amdclang_file}"
   else
      echo "  - amdclang skipped (no ${_install_dir}/llvm/bin/amdclang)"
   fi

   # ---------------- hipfort ----------------------------------------------
   if [[ -d "${_install_dir}/include/hipfort" ]]; then
      local _hipfort_file="${_mod_subdir}/hipfort/${_version_label}.lua"
      sudo mkdir -p "${_mod_subdir}/hipfort"
      sudo tee "${_hipfort_file}" >/dev/null <<EOF
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
      sudo chown root:root "${_hipfort_file}"
      sudo chmod 644 "${_hipfort_file}"
      echo "  + ${_hipfort_file}"
   else
      echo "  - hipfort skipped (no ${_install_dir}/include/hipfort)"
   fi

   # ---------------- opencl ----------------------------------------------
   if [[ -d "${_install_dir}/opencl/bin" ]]; then
      local _opencl_file="${_mod_subdir}/opencl/${_version_label}.lua"
      sudo mkdir -p "${_mod_subdir}/opencl"
      sudo tee "${_opencl_file}" >/dev/null <<EOF
whatis("Name: ROCm OpenCL")
whatis("Built by: ${_leaf_name}@${_leaf_commit} (${_leaf_dirty})")
whatis("Version: ${_version_label}")
whatis("Category: AMD")
whatis("ROCm OpenCL")

local base = "${_install_dir}/opencl"

prepend_path("PATH", pathJoin(base, "bin"))
family("OpenCL")
EOF
      sudo chown root:root "${_opencl_file}"
      sudo chmod 644 "${_opencl_file}"
      echo "  + ${_opencl_file}"
   else
      echo "  - opencl skipped (no ${_install_dir}/opencl/bin)"
   fi
}
