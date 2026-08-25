-- rocbudai — rocBudAI GPU-profiling assistant, backed by an AIM Engine model.
--
-- This is the AIM-client variant of rocBudAI: `module load rocbudai` launches
-- the opencode TUI wired to a model already served by AIM Engine (see
-- ../deploy). It does NOT serve a model locally (no ollama), install anything
-- on the cluster, or need Slurm. The airgap, when required, is a property of a
-- trusted, internet-severed cluster, not of this module.
--
-- ADMIN SETUP: copy the rocbudai/ directory to a shared path, edit the SITE
-- CONFIG block below to match your cluster, then put THIS directory
-- (containing rocbudai.lua) on MODULEPATH:
--   module use /shared/apps/aim-engine/rocbudai/modulefiles
--   module load rocbudai

help([[
rocBudAI — AMD GPU profiling/optimisation assistant (AIM-served).

Loading this module launches the opencode TUI against a model served by AIM
Engine. From the seed prompt the agent emits its welcome banner and runs a
seven-question discovery interview, then iteratively builds, profiles, and
optimises your code.

Usage:
  module load rocbudai          # launches the TUI against the site AIM endpoint

Per-user overrides (export before loading):
  export ROCBUDAI_AIM_ARCH=gfx90a        # persona: gfx90a|mi300x|gfx950|mi300a|demo
  export ROCBUDAI_AIM_ENDPOINT=http://host:8088/v1   # bypass port-forward
  export ROCBUDAI_AIM_NAMESPACE=<ns>     # k8s namespace of the AIM predictor
  export KUBECONFIG=/path/to/kubeconfig  # needed when reaching AIM by port-forward

To leave the TUI: /exit (or Ctrl-D). Re-launch with: module load rocbudai
(after `module unload rocbudai`) or run: setup_rocbudai_aim.sh
]])

whatis("Name        : rocbudai")
whatis("Version     : aim")
whatis("Description : AMD GPU profiling assistant (opencode) over an AIM Engine model")
whatis("URL         : https://github.com/AMD-HPC/rocBudAI")

-- =========================== SITE CONFIG (admin edits) ===========================
-- Where the rocbudai/ directory (this file's grandparent) is installed.
local root          = "/shared/apps/aim-engine/rocbudai"
-- k8s namespace serving the AIM predictor (used when no endpoint is given).
local aim_namespace = "default"
-- Full AIM base URL ending in /v1. If set, no port-forward is done.
local aim_endpoint  = ""
-- Explicit predictor Service name; "" => auto-discover by the predictor label.
local aim_service   = ""
-- Default persona arch (profiling target): gfx90a|mi300x|gfx950|mi300a|demo.
local aim_arch      = "gfx950"
-- Local rocBudAI checkout for the persona ("" => clone at aim_ref). Set this on
-- an internet-severed cluster to a pre-vendored checkout.
local aim_src       = ""
local aim_ref       = "main"
-- Does the agent host have a local GPU? "" => autodetect (via rocminfo). Set to
-- "no" on GPU-less login nodes so the agent is told to dispatch all GPU work
-- (rocbudai-bench is disabled); "yes" to force-enable local runs.
local aim_local_gpu = ""
-- Optional site-wide kubeconfig for port-forward auth ("" => rely on user's).
local aim_kubeconfig = ""
-- ================================================================================

prepend_path("PATH", root)
setenv("ROCBUDAI_AIM_DIR", root)

-- opencode phone-home suppression (same set the stock rocBudAI module uses).
setenv("OPENCODE_DISABLE_AUTOUPDATE",      "1")
setenv("OPENCODE_DISABLE_LSP_DOWNLOAD",    "1")
setenv("OPENCODE_DISABLE_MODELS_FETCH",    "1")
setenv("OPENCODE_DISABLE_EXTERNAL_SKILLS", "1")
setenv("OPENCODE_DISABLE_SHARE",           "1")

-- Export site defaults without clobbering a value the user already exported.
local function set_default(name, value)
   if value ~= nil and value ~= "" then
      local cur = os.getenv(name)
      if cur == nil or cur == "" then setenv(name, value) end
   end
end

set_default("ROCBUDAI_AIM_NAMESPACE", aim_namespace)
set_default("ROCBUDAI_AIM_ENDPOINT",  aim_endpoint)
set_default("ROCBUDAI_AIM_SERVICE",   aim_service)
set_default("ROCBUDAI_AIM_ARCH",      aim_arch)
set_default("ROCBUDAI_AIM_SRC",       aim_src)
set_default("ROCBUDAI_AIM_REF",       aim_ref)
set_default("ROCBUDAI_AIM_LOCAL_GPU", aim_local_gpu)
set_default("KUBECONFIG",             aim_kubeconfig)

-- Auto-launch the TUI on load (recursion/TTY guarded inside the hook). The
-- logic lives in a real script because Lmod collapses execute{cmd=...} onto a
-- single eval line, which breaks inline if/then/fi.
if mode() == "load" then
   execute{
      cmd   = "bash " .. pathJoin(root, "rocbudai-aim-load-hook.sh"),
      modeA = {"load"},
   }
end
