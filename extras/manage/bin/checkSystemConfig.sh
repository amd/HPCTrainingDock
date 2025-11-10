#!/bin/bash

MI300A_COUNT=`rocminfo | grep MI300A | wc -l`
MI300X_COUNT=`rocminfo | grep MI300X | wc -l`
MI250X_COUNT=`rocminfo | grep MI250X | wc -l`
MI210_COUNT=`rocminfo | grep MI210 | wc -l`

GRUB_UPDATE_NEEDED=0

if [[ "${MI300A_COUNT}" -gt 0 ]]; then
   echo "====================================="
   echo "This system has MI300A APUs"
   echo "System Settings Check for MI300A APUs"
   echo "====================================="
   echo ""

   echo "======================"
   echo "Checking Grub settings"
   echo "======================"
   echo "GRUB_CMDLINE_LINUX should have pci=realloc=off"
   if [[ -f /etc/default/grub ]]; then
      if [[ `grep GRUB_CMDLINE_LINUX /etc/default/grub | grep "pci=realloc=off" | wc -l` != 1 ]]; then
         echo "WARNING: pci realloc setting is missing"
         echo "   RECOMMENDATION: it is recommended that pci realloc be set to off"
         echo "   FIX: Add pci=realloc=off to GRUB_CMDLINE_LINUX"
         GRUB_UPDATE_NEEDED=1
      fi
      if [[ "${GRUB_UPDATE_NEEDED}" == 1 ]]; then
         echo "        sudo grub2-mkconfig -o /boot/grub2/grub.cfg, or"
         echo "        sudo grub-mkconfig -o /boot/grub/grub.cfg"
         echo "        check for version with grub-mkconfig -version"
      fi
      echo "Current setting for GRUB_COMMAND_LINE is"
      grep GRUB_CMDLINE_LINUX /etc/default/grub
   else
      echo "/etc/default/grub not found. Check with your system provider"
   fi
   echo "======================"
   echo ""

   echo "==========================="
   echo "Checking huge pages setting"
   echo "==========================="
   if [[ `grep '\[always\]' /sys/kernel/mm/transparent_hugepage/enabled | wc -l` != 1 ]]; then
      echo "WARNING: huge pages setting is missing"
      grep transparent_hugepage /sys/kernel/mm/transparent_hugepage/enabled
      echo "   The setting for huge pages is done with"
      echo "   echo always > /sys/kernel/mm/transparent_hugepage/enabled"
   else
      echo "Current huge pages settings are set to always which is the recommended setting"
   fi
   echo "Current huge pages settings are"
   cat /sys/kernel/mm/transparent_hugepage/enabled
elif [[ "${MI300X_COUNT}" -gt 0 ]]; then
   echo "============================"
   echo "This system has MI300X GPUs"
   echo "System Settings Check for MI300X GPUs"
   echo "============================"

   echo "======================"
   echo "Checking Grub settings"
   echo "======================"
   echo "GRUB_CMDLINE_LINUX should have pci=realloc=off"
   if [[ -f /etc/default/grub ]]; then
      if [[ `grep GRUB_CMDLINE_LINUX /etc/default/grub | grep "pci=realloc=off" | wc -l` != 1 ]]; then
         echo "WARNING: pci realloc setting is missing"
         echo "   RECOMMENDATION: it is recommended that pci realloc be set to off"
         echo "   FIX: Add pci=realloc=off to GRUB_CMDLINE_LINUX"
         GRUB_UPDATE_NEEDED=1
      fi
   fi
   echo "GRUB_CMDLINE_LINUX should have iommu=on"
   if [[ -f /etc/default/grub ]]; then
      if [[ `grep GRUB_CMDLINE_LINUX /etc/default/grub | grep "iommu=on" | wc -l` != 1 ]]; then
         echo "WARNING: iommu=on setting is missing"
         echo "   RECOMMENDATION: it is recommended that iommu be set to on"
         echo "   FIX: Add amd_iommu=on iommu=pt to GRUB_CMDLINE_LINUX, or"
         echo "            intel_iommu=on iommu=pt to GRUB_CMDLINE_LINUX"
         GRUB_UPDATE_NEEDED=1
      fi
   else
      echo "/etc/default/grub not found. Check with your system provider"
   fi
   if [[ "${GRUB_UPDATE_NEEDED}" == 1 ]]; then
      echo "        sudo grub2-mkconfig -o /boot/grub2/grub.cfg, or"
      echo "        sudo grub-mkconfig -o /boot/grub/grub.cfg"
      echo "        check for version with grub-mkconfig -version"
   fi
   echo "Current setting for GRUB_COMMAND_LINE is"
   grep GRUB_CMDLINE_LINUX /etc/default/grub
   echo "======================"
   echo ""
   echo "======================"
   echo "Checking NUMA settings"
   echo "======================"
   echo "NOTE: Disabling NUMA balancing should be done cautiously and for"
   echo "specific reasons, such as performance optimization or addressing"
   echo "particular issues. Always test the impact of disabling NUMA balancing"
   echo "in a controlled environment before applying changes to a production system."
   echo ""
   echo "The NUMA balancing feature allows the OS to scan memory and attempt"
   echo "to migrate to a DIMM that is logically closer to the cores accessing"
   echo "it. This causes an overhead because the OS is second-guessing your"
   echo "NUMA allocations. But may be useful if the NUMA locality access is"
   echo "very poor. Applications can therefore, in general, benefit from"
   echo "disabling NUMA balancing; however, there are workloads where this"
   echo "is detrimental to performance. Test this setting by toggling the"
   echo "numa_balancing value and running the application; compare the"
   echo "performance of one run with this set to 0 and another run with this to 1."
   NUMA_SETTINGS=`cat /proc/sys/kernel/numa_balancing`
   if [[ "${NUMA_SETTINGS}" != 0 ]]; then
      echo "WARNING: NUMA auto-balancing is turned on"
      echo "   RECOMMENDATION: it is recommended to turn NUMA auto-balancing off"
      echo "   FIX: sudo sh -c \\'echo 0 > /proc/sys/kernel/numa_balancing"
   fi
elif [[ "${MI250X_COUNT}" -gt 0 ]]; then
   echo "============================"
   echo "This system has MI250X GPUs"
   echo "============================"
elif [[ "${MI210_COUNT}" -gt 0 ]]; then
   echo "============================"
   echo "This system has MI210 GPUs"
   echo "============================"
else
   echo "==============================="
   echo "No AMD Instinct GPUs detected"
   echo "(MI210, MI250X, MI300A, MI300X)"
   echo "==============================="
fi

# Need to add for memory check
#Check and correct amdgpu driver memory size
#
#Check the memory pool size
#cat /sys/module/amdttm/parameters/page_pool_size
#
#Make sure that you get 134217728. If this is not the case, configure the amd driver to use all available GPU memory by creating or updating the file /etc/modprobe.d/amdttm.conf with the following settings:
#options amdttm pages_limit=134217728
#options amdttm page_pool_size=134217728
#
#Restart the driver and check the pool size again.
#Reboot the node if the size is still 96GBs.
#
#If this does not help update grub again and reboot the node (use the correct kernel version bellow):
#$ sudo grubby --default-kernel
#/boot/vmlinuz-5.14.0-427.24.1.el9_4.x86_64
#$ sudo grubby --update-kernel=/boot/vmlinuz-5.14.0-427.24.1.el9_4.x86_64 --arg="amdttm.pages_limit=134217728 amdttm.page_pool_size=134217728"
#$ sudo reboot
