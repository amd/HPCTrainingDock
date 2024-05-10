local root = "/opt/miniconda3"
setenv("ANACONDA3ROOT", root)
setenv("PYTHONROOT", root)
local python_version = capture(root .. "/bin/python -V | awk '{print $2}'")
local conda_version = capture(root .. "/bin/conda --version | awk '{print $2}'")
function trim(s)
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end
conda_version = trim(conda_version)
help([[ Loads the Miniconda environment supporting Community-Collections. ]])
whatis("Sets the environment to use the Community-Collections Miniconda.")
local myShell = myShellName()
if (myShell == "bash") then
  cmd = "source " .. root .. "/etc/profile.d/conda.sh"
else
  cmd = "source " .. root .. "/etc/profile.d/conda.csh"
end
execute{cmd=cmd, modeA = {"load"}}
prepend_path("PATH", "/opt/miniconda3/bin")

load("rocm/6.1.0")
