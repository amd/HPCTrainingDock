#!/bin/bash
set -u

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

      # Cross-check: verify the running kernel was actually booted with this param
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

# ─── Transparent Huge Pages check ───────────────────────────────────────────────

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

# ─── NUMA balancing check ───────────────────────────────────────────────────────

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

# ─── IOMMU check ────────────────────────────────────────────────────────────────

check_iommu() {
   banner "Checking IOMMU settings"
   check_grub_param "iommu=" "IOMMU"
   echo ""
   info "For AMD systems use: amd_iommu=on iommu=pt"
   info "For Intel systems use: intel_iommu=on iommu=pt"
}

# ─── amdttm memory pool check ───────────────────────────────────────────────────

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
      info "This is normal when no GPU workload is active on MI300A APUs"
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

banner "Checking GRUB settings"
check_grub_param "pci=realloc=off" "PCI realloc"

# ─── GPU-specific checks ────────────────────────────────────────────────────

case "$GPU_TYPE" in
   MI300A)
      check_hugepages
      check_iommu
      check_numa_balancing
      check_amdttm_memory
      ;;
   MI300X)
      check_iommu
      check_numa_balancing
      check_amdttm_memory
      ;;
   MI250X)
      check_numa_balancing
      ;;
   MI210)
      check_numa_balancing
      ;;
esac

# ─── Checks common to all GPU types ─────────────────────────────────────────

show_grub_update_instructions
check_ulimits
check_rocm_smi_health

print_summary
