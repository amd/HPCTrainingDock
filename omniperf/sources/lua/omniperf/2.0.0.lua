local help_message = [[

Omniperf is an open-source performance analysis tool for profiling
machine learning/HPC workloads running on AMD MI GPUs.

Version 2.0.0
]]

help(help_message,"\n")

whatis("Name: omniperf")
whatis("Version: 2.0.0")
whatis("Keywords: Profiling, Performance, GPU")
whatis("Description: tool for GPU performance profiling")
whatis("URL: https://github.com/AMDResearch/omniperf")

-- Export environmental variables
local topDir="/opt/rocmplus-ROCM_VERSION/omniperf-2.0.0"
local binDir="/opt/rocmplus-ROCM_VERSION/omniperf-2.0.0/bin"
local shareDir="/opt/rocmplus-ROCM_VERSION/omniperf-2.0.0/share"
local pythonDeps="/opt/rocmplus-ROCM_VERSION/omniperf-2.0.0/python-libs"
local roofline="/opt/rocmplus-ROCM_VERSION/omniperf-2.0.0/bin/utils/rooflines/roofline-ubuntu20_04-mi200-rocm5"

setenv("OMNIPERF_DIR",topDir)
setenv("OMNIPERF_BIN",binDir)
setenv("OMNIPERF_SHARE",shareDir)
setenv("ROOFLINE_BIN",roofline)

-- Update relevant PATH variables
prepend_path("PATH",binDir)
if ( pythonDeps  ~= "" ) then
   prepend_path("PYTHONPATH",pythonDeps)
end

-- Site-specific additions
-- depends_on "python"
-- depends_on "rocm"
prereq(atleast("rocm","ROCM_VERSION"))
--  prereq("mongodb-tools")
local home = os.getenv("HOME")
setenv("MPLCONFIGDIR",pathJoin(home,".matplotlib"))
