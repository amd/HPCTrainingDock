#!/bin/bash
set -u

# System configuration checker for AMD Instinct GPUs.
#
# Each check is sourced from the official AMD system optimization guides:
#   MI300A: instinct.docs.amd.com/projects/amdgpu-docs/en/latest/system-optimization/mi300a.html
#   MI300X: instinct.docs.amd.com/projects/amdgpu-docs/en/latest/system-optimization/mi300x.html
#   MI200:  instinct.docs.amd.com/projects/amdgpu-docs/en/latest/system-optimization/mi200.html

# Try to load the ROCm module so rocminfo/rocm-smi are available
if command -v module &>/dev/null; then
   module load rocm 2>/dev/null || true
fi

GRUB_UPDATE_NEEDED=0
WARN_COUNT=0

# ─── Helper functions ───────────────────────────────────────────────────────────

banner() {
   local msg="$1"
   local len=${#msg}
   local border
   border=$(printf '=%.0s' $(seq 1 "$len"))
   echo ""
   echo "$border"
   echo "$msg"
   echo "$border"
}

warn() {
   echo "WARNING: $1"
   WARN_COUNT=$((WARN_COUNT + 1))
}

info() {
   echo "  INFO: $1"
}

ok() {
   echo "  OK: $1"
}

recommendation() {
   echo "  RECOMMENDATION: $1"
}

fix() {
   echo "  FIX: $1"
}

# ─── GPU detection (multiple fallback methods) ──────────────────────────────────

detect_gpu() {
   local gpu=""

   if command -v rocminfo &>/dev/null; then
      local rocm_output
      rocm_output=$(rocminfo 2>/dev/null)
      if echo "$rocm_output" | grep -q "MI300A"; then gpu="MI300A";
      elif echo "$rocm_output" | grep -q "MI300X"; then gpu="MI300X";
      elif echo "$rocm_output" | grep -q "MI250X"; then gpu="MI250X";
      elif echo "$rocm_output" | grep -q "MI210";  then gpu="MI210";
      fi
   fi

   if [[ -z "$gpu" ]] && [[ -f /proc/cpuinfo ]]; then
      if grep -q "MI300A" /proc/cpuinfo 2>/dev/null; then gpu="MI300A"; fi
   fi

   if [[ -z "$gpu" ]]; then
      local lspci_output
      lspci_output=$(lspci 2>/dev/null)
      if echo "$lspci_output" | grep -qi "MI300X"; then gpu="MI300X";
      elif echo "$lspci_output" | grep -qi "MI300A"; then gpu="MI300A";
      elif echo "$lspci_output" | grep -qi "MI250X"; then gpu="MI250X";
      elif echo "$lspci_output" | grep -qi "MI210";  then gpu="MI210";
      fi
   fi

   # Fallback: check PCI device IDs via sysfs
   if [[ -z "$gpu" ]]; then
      for d in /sys/class/drm/card*/device; do
         if [[ -f "$d/vendor" ]] && [[ "$(cat "$d/vendor" 2>/dev/null)" == "0x1002" ]]; then
            local devid
            devid=$(cat "$d/device" 2>/dev/null)
            case "$devid" in
               0x74a0) gpu="MI300A"; break ;;
               0x74a1) gpu="MI300X"; break ;;
               0x740f|0x7408) gpu="MI250X"; break ;;
               0x740c) gpu="MI210"; break ;;
            esac
         fi
      done
   fi

   echo "$gpu"
}

# ─── amdgpu driver check ────────────────────────────────────────────────────────

check_amdgpu_driver() {
   banner "Checking amdgpu kernel module"
   if lsmod | grep -q "^amdgpu"; then
      ok "amdgpu kernel module is loaded"
   else
      warn "amdgpu kernel module is NOT loaded"
      fix "Check driver installation; the amdgpu module must be loaded for GPU access"
   fi
}

# ─── GRUB parameter checks ──────────────────────────────────────────────────────

check_grub_param() {
   local param="$1"
   local description="$2"

   echo ""
   echo "Checking for $param ..."
   if [[ -f /etc/default/grub ]]; then
      if ! grep -E "^GRUB_CMDLINE_LINUX" /etc/default/grub | grep -q "$param"; then
         warn "$description setting ($param) is missing from GRUB config"
         fix "Add $param to GRUB_CMDLINE_LINUX or GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub"
         GRUB_UPDATE_NEEDED=1
      else
         ok "$param is set in GRUB config"
      fi

      if [[ -f /proc/cmdline ]]; then
         if grep -q "$param" /proc/cmdline; then
            ok "$param is active in the running kernel (/proc/cmdline)"
         else
            warn "$param is NOT active in the running kernel"
            info "The GRUB config may have been updated but the system has not been rebooted"
            recommendation "Reboot the system for GRUB changes to take effect"
         fi
      fi
   else
      warn "/etc/default/grub not found -- check with your system provider"
   fi
}

show_grub_update_instructions() {
   if [[ "${GRUB_UPDATE_NEEDED}" == 1 ]]; then
      echo ""
      echo "  After updating /etc/default/grub, regenerate the GRUB config:"
      echo "    sudo grub2-mkconfig -o /boot/grub2/grub.cfg   (RHEL/CentOS)"
      echo "    sudo grub-mkconfig  -o /boot/grub/grub.cfg    (Ubuntu/Debian)"
      echo "    sudo update-grub                               (Ubuntu shorthand)"
      echo "  Then reboot for changes to take effect."
   fi
   echo ""
   echo "  Current GRUB_CMDLINE_LINUX settings:"
   grep -E "^GRUB_CMDLINE_LINUX" /etc/default/grub 2>/dev/null || echo "  (not available)"
   echo ""
   echo "  Current running kernel command line:"
   cat /proc/cmdline 2>/dev/null || echo "  (not available)"
}

# ─── Transparent Huge Pages check (MI300A only per AMD docs) ────────────────────

check_hugepages() {
   banner "Checking Transparent Huge Pages (THP)"
   local thp_file="/sys/kernel/mm/transparent_hugepage/enabled"
   if [[ ! -f "$thp_file" ]]; then
      warn "THP sysfs file not found ($thp_file) -- THP may not be supported on this kernel"
      return
   fi

   local thp_setting
   thp_setting=$(cat "$thp_file")
   if echo "$thp_setting" | grep -q '\[always\]'; then
      ok "Transparent Huge Pages are set to 'always' (recommended)"
   else
      warn "Transparent Huge Pages are NOT set to 'always'"
      recommendation "Set THP to 'always' for best HPC performance"
      fix "echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled"
      fix "For persistence, add 'transparent_hugepage=always' to GRUB_CMDLINE_LINUX"
   fi
   echo "  Current setting: $thp_setting"
}

# ─── NUMA balancing check (MI300A, MI300X per AMD docs) ─────────────────────────

check_numa_balancing() {
   banner "Checking NUMA balancing"
   echo "  NOTE: Disabling NUMA balancing should be done cautiously. The NUMA"
   echo "  balancing feature lets the OS migrate memory closer to the cores"
   echo "  accessing it. This causes overhead for well-optimized HPC workloads"
   echo "  but may help poorly-localized access patterns. Test both settings"
   echo "  with your specific workload."

   local numa_file="/proc/sys/kernel/numa_balancing"
   if [[ ! -f "$numa_file" ]]; then
      info "NUMA balancing sysfs file not found -- skipping"
      return
   fi

   local numa_setting
   numa_setting=$(< "$numa_file")
   if [[ "$numa_setting" == "0" ]]; then
      ok "NUMA auto-balancing is OFF"
   else
      warn "NUMA auto-balancing is ON (value=$numa_setting)"
      recommendation "Consider turning NUMA auto-balancing off for HPC workloads"
      fix "sudo sh -c 'echo 0 > /proc/sys/kernel/numa_balancing'"
   fi
}

# ─── IOMMU checks ───────────────────────────────────────────────────────────────

# MI300A: IOMMU should be OFF at BIOS level (per MI300A system optimization guide)
check_iommu_off() {
   banner "Checking IOMMU settings (should be OFF)"
   info "Optimal config: IOMMU disabled at BIOS level"
   if command -v acpidump &>/dev/null; then
      if sudo acpidump 2>/dev/null | grep -q "IVRS\|DMAR"; then
         warn "IOMMU tables (IVRS/DMAR) found -- IOMMU may be enabled"
         recommendation "Disable IOMMU in the system BIOS"
      else
         ok "No IOMMU tables (IVRS/DMAR) found -- IOMMU appears disabled"
      fi
   else
      info "acpidump not available (install acpica-tools to verify IOMMU state)"
   fi
   if [[ -f /proc/cmdline ]]; then
      if grep -q "iommu=pt" /proc/cmdline; then
         info "iommu=pt found in kernel cmdline (pass-through is acceptable but OFF is preferred)"
      fi
   fi
}

# MI300X: IOMMU enabled + pass-through (per MI300X system optimization guide)
check_iommu_pt() {
   banner "Checking IOMMU settings (pass-through mode)"
   check_grub_param "iommu=pt" "IOMMU pass-through"
   echo ""
   info "For AMD host CPUs use: iommu=pt"
   info "For Intel host CPUs use: intel_iommu=on iommu=pt"
}

# MI200: IOMMU disabled by default; only iommu=pt if >=256 threads with SMT
# (per MI200 system optimization guide, "Systems with 256 CPU threads" section)
check_iommu_mi200() {
   banner "Checking IOMMU settings (MI200)"
   info "MI200 default: IOMMU disabled in BIOS"

   local nproc
   nproc=$(nproc 2>/dev/null || echo 0)
   if [[ "$nproc" -ge 256 ]]; then
      info "System has $nproc logical CPUs (>= 256)"
      info "With SMT enabled + 256+ threads, IOMMU must be enabled with iommu=pt"
      info "Otherwise Linux falls back to APIC which only enumerates 255 cores"
      check_grub_param "iommu=pt" "IOMMU pass-through (required for 256+ threads)"
   else
      info "System has $nproc logical CPUs (< 256)"
      ok "IOMMU disabled in BIOS is the correct default for this configuration"
   fi
}

# ─── CPU C-states check (MI300X, MI200 per AMD docs; MI300A handled by BIOS) ───

check_cstates() {
   banner "Checking CPU C-states"
   info "Disabling deep C-states (C2) reduces latency for HPC workloads"
   if ! command -v cpupower &>/dev/null; then
      info "cpupower not installed -- cannot check C-state settings"
      info "Install with: sudo apt install linux-tools-common (Ubuntu)"
      info "              sudo yum install cpupowerutils      (RHEL)"
      info "              sudo zypper install cpupower        (SLES)"
      return
   fi

   local cstate_output
   cstate_output=$(cpupower idle-info 2>/dev/null) || true
   if echo "$cstate_output" | grep -qi "C2"; then
      local c2_disabled
      c2_disabled=$(cpupower idle-info 2>/dev/null | grep -A1 "C2" | grep -ci "DISABLED") || true
      if [[ "$c2_disabled" -ge 1 ]]; then
         ok "C2 (deep idle) state appears disabled"
      else
         warn "C2 (deep idle) state may be enabled"
         recommendation "Disable C2 for lower latency: sudo cpupower idle-set -d 2"
      fi
   else
      ok "No C2 state found in idle-info"
   fi
}

# ─── Compaction check (MI300A only per AMD docs) ────────────────────────────────

check_compaction() {
   banner "Checking memory compaction (required for MI300A)"
   info "The APU dynamically shares memory between CPU and GPU."
   info "Without compaction, performance degrades as fragmentation increases."

   local proactive_file="/proc/sys/vm/compaction_proactiveness"
   local unevictable_file="/proc/sys/vm/compact_unevictable_allowed"

   if [[ -f "$proactive_file" ]]; then
      local proactive_val
      proactive_val=$(< "$proactive_file")
      if [[ "$proactive_val" -ge 20 ]]; then
         ok "compaction_proactiveness = $proactive_val (>= 20)"
      else
         warn "compaction_proactiveness = $proactive_val (recommended >= 20)"
         fix "echo 20 | sudo tee /proc/sys/vm/compaction_proactiveness"
      fi
   else
      info "$proactive_file not found -- skipping"
   fi

   if [[ -f "$unevictable_file" ]]; then
      local unevictable_val
      unevictable_val=$(< "$unevictable_file")
      if [[ "$unevictable_val" == "1" ]]; then
         ok "compact_unevictable_allowed = 1"
      else
         warn "compact_unevictable_allowed = $unevictable_val (should be 1)"
         fix "echo 1 | sudo tee /proc/sys/vm/compact_unevictable_allowed"
      fi
   else
      info "$unevictable_file not found -- skipping"
   fi
}

# ─── amdttm memory pool check (MI300A, MI300X per AMD docs) ─────────────────────

check_amdttm_memory() {
   banner "Checking amdttm GPU memory pool"
   local pool_file="/sys/module/amdttm/parameters/page_pool_size"
   local limit_file="/sys/module/amdttm/parameters/pages_limit"

   if [[ ! -f "$pool_file" ]]; then
      info "amdttm page_pool_size file not found -- skipping (module may not be loaded)"
      return
   fi

   local pool_size
   pool_size=$(< "$pool_file")
   echo "  page_pool_size: $pool_size"

   if [[ -f "$limit_file" ]]; then
      local pages_limit
      pages_limit=$(< "$limit_file")
      echo "  pages_limit:    $pages_limit"
   fi

   local pool_gb=$(( pool_size * 4096 / 1073741824 ))
   info "page_pool_size = $pool_size ($pool_gb GB assuming 4K pages)"
   info "This should match total GPU/HBM memory available on the system"
   info "  MI300A = 128 GB per APU, MI300X = 192 GB per GPU (verify with hardware docs)"
   info "To adjust, create/update /etc/modprobe.d/amdttm.conf:"
   info "  options amdttm pages_limit=<VALUE>"
   info "  options amdttm page_pool_size=<VALUE>"
   info "Or set via GRUB: amdttm.pages_limit=NNN amdttm.page_pool_size=NNN"
}

# ─── ulimits check ──────────────────────────────────────────────────────────────

check_ulimits() {
   banner "Checking ulimits"

   local memlock
   memlock=$(ulimit -l 2>/dev/null)
   local nofile
   nofile=$(ulimit -n 2>/dev/null)

   echo "  memlock (max locked memory, KB): ${memlock:-unknown}"
   echo "  nofile  (max open files):        ${nofile:-unknown}"

   if [[ "$memlock" == "unlimited" ]] || [[ "${memlock:-0}" -ge 65536 ]] 2>/dev/null; then
      ok "memlock limit looks sufficient ($memlock)"
   else
      warn "memlock limit may be too low ($memlock KB)"
      recommendation "Set memlock to 'unlimited' in /etc/security/limits.conf"
      fix "Add:  * soft memlock unlimited"
      fix "       * hard memlock unlimited"
   fi

   if [[ "${nofile:-0}" -ge 65536 ]] 2>/dev/null; then
      ok "nofile limit looks sufficient ($nofile)"
   else
      warn "nofile limit may be too low ($nofile)"
      recommendation "Increase to at least 65536 in /etc/security/limits.conf"
      fix "Add:  * soft nofile 131072"
      fix "       * hard nofile 131072"
   fi
}

# ─── rocm-smi health check ──────────────────────────────────────────────────────

find_rocm_smi() {
   if command -v rocm-smi &>/dev/null; then
      echo "rocm-smi"
      return
   fi
   for dir in /opt/rocm/bin /opt/rocm-*/bin; do
      if [[ -x "$dir/rocm-smi" ]]; then
         echo "$dir/rocm-smi"
         return
      fi
   done
   echo ""
}

check_rocm_smi_health() {
   banner "Checking GPU health via rocm-smi"
   local smi
   smi=$(find_rocm_smi)
   if [[ -z "$smi" ]]; then
      info "rocm-smi not found -- skipping GPU health checks"
      info "Install ROCm or add /opt/rocm/bin to PATH for GPU health monitoring"
      return
   fi

   echo "  Using: $smi"
   echo ""

   local smi_output
   smi_output=$("$smi" 2>&1) || true

   if echo "$smi_output" | grep -q "low-power state"; then
      info "GPU device(s) are in a low-power state -- rocm-smi cannot query details"
      info "This can be normal when no GPU workload is active (especially on ${GPU_TYPE})"
   elif echo "$smi_output" | grep -q "No AMD GPUs"; then
      info "rocm-smi reports no AMD GPUs visible"
      info "The driver may need ROCm userspace libraries or KFD/HSA configuration"
   else
      echo "--- GPU Summary ---"
      echo "$smi_output"
      echo ""
      if "$smi" --showtopo &>/dev/null; then
         echo "--- GPU Topology ---"
         "$smi" --showtopo 2>&1 || true
      fi
   fi
}

# ─── Summary ─────────────────────────────────────────────────────────────────────

print_summary() {
   echo ""
   echo "============================================="
   if [[ "$WARN_COUNT" -eq 0 ]]; then
      echo "All checks passed -- no warnings."
   else
      echo "$WARN_COUNT warning(s) found. Review items above."
   fi
   echo "============================================="
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Main
# ═══════════════════════════════════════════════════════════════════════════════

GPU_TYPE=$(detect_gpu)

if [[ -z "$GPU_TYPE" ]]; then
   banner "No AMD Instinct GPUs detected (MI210, MI250X, MI300A, MI300X)"
   echo "  Detection methods tried: rocminfo, /proc/cpuinfo, lspci, sysfs"
   echo "  If GPUs are present, verify the amdgpu driver is loaded."
   exit 0
fi

banner "System Settings Check for $GPU_TYPE"

# ─── Checks common to all GPU types ─────────────────────────────────────────

check_amdgpu_driver

# ─── GPU-specific checks (strictly per official AMD system optimization guides)
#
# MI300A: instinct.docs.amd.com/.../system-optimization/mi300a.html
#   - pci=realloc=off, THP=always, IOMMU off, NUMA balancing off,
#     compaction, amdttm pool. C-states handled by BIOS.
#
# MI300X: instinct.docs.amd.com/.../system-optimization/mi300x.html
#   - pci=realloc=off, iommu=pt, C-states (cpupower), NUMA balancing off,
#     amdttm pool. THP not mentioned.
#
# MI200:  instinct.docs.amd.com/.../system-optimization/mi200.html
#   - C-states (cpupower), IOMMU disabled by default (iommu=pt only
#     for >=256 threads with SMT). THP/NUMA balancing not mentioned
#     (defers to EPYC 7003 HPC tuning guide).

case "$GPU_TYPE" in
   MI300A)
      banner "Checking GRUB settings"
      check_grub_param "pci=realloc=off" "PCI realloc"
      check_hugepages
      check_iommu_off
      check_numa_balancing
      check_compaction
      check_amdttm_memory
      ;;
   MI300X)
      banner "Checking GRUB settings"
      check_grub_param "pci=realloc=off" "PCI realloc"
      check_grub_param "iommu=pt" "IOMMU pass-through"
      check_numa_balancing
      check_amdttm_memory
      check_cstates
      ;;
   MI250X)
      check_iommu_mi200
      check_cstates
      ;;
   MI210)
      check_iommu_mi200
      check_cstates
      ;;
esac

# ─── Checks common to all GPU types ─────────────────────────────────────────

show_grub_update_instructions
check_ulimits
check_rocm_smi_health

print_summary
