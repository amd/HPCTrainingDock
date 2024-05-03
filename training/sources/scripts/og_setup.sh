#!/bin/bash

if [ "BUILD_OG_LATEST" = "1" ] ; then
   if [ -f /opt/rocmplus-SCRIPT_ROCM_VERSION/og13.tgz ]; then
      #install the cached version
      cd /opt/rocmplus-SCRIPT_ROCM_VERSION
      tar -xzf og13.tgz 
      chown -R root:root /opt/rocmplus-SCRIPT_ROCM_VERSION/og13-*
      rm /opt/rocmplus-SCRIPT_ROCM_VERSION/og13.tgz

      cd /etc/lmod/modules/ROCmPlus-LatestCompilers
      tar -xzf /opt/rocmplus-SCRIPT_ROCM_VERSION/og13module.tgz
      chown -R root:root /etc/lmod/modules/ROCmPlus-LatestCompilers/og*
      rm /opt/rocmplus-SCRIPT_ROCM_VERSION/og13module.tgz
   else

      # Install the OpenMP GCC compiler latest drop
      export OG_INSTALL_DIR=/opt/rocmplus-SCRIPT_ROCM_VERSION/og13-SCRIPT_OG_BUILD_DATE
      export OGDIR=/opt/rocmplus-SCRIPT_ROCM_VERSION/og_build
      cd /opt/rocmplus-SCRIPT_ROCM_VERSION
      git clone --depth 1 https://github.com/ROCm-Developer-Tools/og
      cd og
      bin/build_og13.sh
      cd /opt/rocmplus-SCRIPT_ROCM_VERSION
      rm -rf og og_build

      # Only install module when building OG gcc development compiler
      #  For cached version, use a cached module file
      export MODULE_PATH=/etc/lmod/modules/ROCmPlus-LatestCompilers/og

      mkdir -p ${MODULE_PATH}

      # The - option suppresses tabs
      cat > ${MODULE_PATH}/gcc-develop-SCRIPT_OG_BUILD_DATE.lua <<-EOF
	whatis("GCC Development Version SCRIPT_OG_BUILD_DATE compiler")

	local base = "/opt/rocmplus-SCRIPT_ROCM_VERSION/og13-SCRIPT_OG_BUILD_DATE"

	setenv("CC", pathJoin(base, "bin/gcc"))
	setenv("CXX", pathJoin(base, "bin/g++"))
	setenv("F77", pathJoin(base, "bin/gfortran"))
	setenv("F90", pathJoin(base, "bin/gfortran"))
	setenv("FC", pathJoin(base,"bin/gfortran"))
	append_path("INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib64"))
	load("rocm/SCRIPT_ROCM_VERSION")
	family("compiler")
EOF

   fi
fi
