#!/bin/bash
#
# fix_python_venv_shebangs.sh - HOT FIX for stale /tmp/<JOBID>/ python
# venv shebangs in installed package trees.
#
# WHY:
#   Three setup scripts (pytorch_setup.sh, cupy_setup.sh,
#   hip-python_setup.sh) share the same anti-pattern: create a venv
#   under /tmp, activate it, then `pip install --target=<install_path>`
#   for various packages. pip emits console_script wrappers (cmake,
#   ninja, ctest, torchrun, transformers-cli, deepspeed, numba, ...)
#   with `#!/tmp/.../<venv>/bin/python3` shebangs. After the EXIT trap
#   wipes /tmp the wrappers all become "bad interpreter".
#
#   Verified failure: slurm 8161 cmake breakage on rocm-7.2.1, plus
#   cluster-wide audit on 2026-05-07 found ~1,300 broken wrappers
#   across pytorch + cupy + numba-hip installs in /shared/apps and
#   /nfsapps trees.
#
# FIX:
#   Replace `#!/tmp/.../bin/python3` with `#!/usr/bin/env python3`.
#   This works because each package's modulefile prepends its own
#   site-packages onto PYTHONPATH and its own bin/ onto PATH, so the
#   relevant python module resolves once `module load <pkg>` is in
#   effect (or simply when PYTHONPATH is set up). End-to-end verified
#   with cmake --version on rocm-7.2.1 pytorch install.
#
# USAGE:
#   ./fix_python_venv_shebangs.sh           # dry-run
#   ./fix_python_venv_shebangs.sh --apply   # patch with sudo + .bak
#
# IDEMPOTENT: re-running on already-fixed installs is a no-op (only
# rewrites lines matching ^#!/tmp/, never any other shebang).
#
# SCOPE: walks all of these patterns under /shared/apps/ubuntu/opt and
# /nfsapps/opt:
#
#   rocmplus-*/pytorch-v*/{pytorch,audio,vision,transformers,
#                          sageattention,flashattention,triton,
#                          deepspeed}/bin
#   rocmplus-*/cupy-v*/bin
#   rocmplus-*/hip-python/{numba-hip,hip-python}/bin
#
# Supersedes the earlier pytorch-only fix_pytorch_shebangs.sh (which
# only touched the .../pytorch/bin/ subset of the above).

set -uo pipefail

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

NEW_SHEBANG='#!/usr/bin/env python3'
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_TAG="pre-shebang-fix-${TIMESTAMP}"
ROOTS=(/shared/apps/ubuntu/opt /nfsapps/opt)

# Glob patterns relative to each ROOT. Order is purely cosmetic.
PATTERNS=(
   "rocmplus-*/pytorch-v*/pytorch/bin"
   "rocmplus-*/pytorch-v*/audio/bin"
   "rocmplus-*/pytorch-v*/vision/bin"
   "rocmplus-*/pytorch-v*/transformers/bin"
   "rocmplus-*/pytorch-v*/sageattention/bin"
   "rocmplus-*/pytorch-v*/flashattention/bin"
   "rocmplus-*/pytorch-v*/triton/bin"
   "rocmplus-*/pytorch-v*/deepspeed/bin"
   "rocmplus-*/cupy-v*/bin"
   "rocmplus-*/hip-python/numba-hip/bin"
   "rocmplus-*/hip-python/hip-python/bin"
)

if [ "$APPLY" = "1" ]; then
   echo "===== fix_python_venv_shebangs.sh: APPLY mode (sudo, with .${BACKUP_TAG} backups) ====="
else
   echo "===== fix_python_venv_shebangs.sh: DRY-RUN (pass --apply to patch) ====="
fi
echo

total_dirs=0
total_files=0
total_skipped_clean=0

for root in "${ROOTS[@]}"; do
   for pat in "${PATTERNS[@]}"; do
      # Use bash globbing; missing matches expand to the literal pattern,
      # which we filter via the -d test inside the loop.
      shopt -s nullglob
      for bindir in "${root}"/${pat}; do
         [ -d "$bindir" ] || continue
         total_dirs=$((total_dirs + 1))
         install_dir=$(dirname "$bindir")

         # Only files that actually need patching: shebang starts with
         # #!/tmp/. Backups (.pre-shebang-fix-*.bak) also start with
         # the same shebang; explicitly filter them out so the count
         # reflects only LIVE files needing rewrite.
         mapfile -t bad_files < <(grep -lE "^#!/tmp/" "$bindir"/* 2>/dev/null \
                                  | grep -vE "\.pre-shebang-fix-[0-9TZ]+\.bak$" \
                                  | sort)
         mapfile -t already < <(grep -lE "^#!/usr/bin/env python3" "$bindir"/* 2>/dev/null \
                                | grep -vE "\.pre-shebang-fix-[0-9TZ]+\.bak$" \
                                | sort)

         printf "  %-78s  bad=%2d  already-patched=%2d\n" "$install_dir" "${#bad_files[@]}" "${#already[@]}"
         total_files=$((total_files + ${#bad_files[@]}))
         total_skipped_clean=$((total_skipped_clean + ${#already[@]}))

         if [ "${#bad_files[@]}" -eq 0 ]; then
            continue
         fi

         for f in "${bad_files[@]}"; do
            old=$(head -n 1 "$f")
            if [ "$APPLY" = "1" ]; then
               sudo cp -p "$f" "${f}.${BACKUP_TAG}.bak"
               sudo sed -i "1s|^.*$|${NEW_SHEBANG}|" "$f"
               new=$(head -n 1 "$f")
               printf "    + %-18s  %s -> %s\n" "$(basename "$f")" "$old" "$new"
            else
               printf "    ~ %-18s  %s -> %s\n" "$(basename "$f")" "$old" "$NEW_SHEBANG"
            fi
         done
      done
      shopt -u nullglob
   done
done

echo
echo "===== SUMMARY ====="
printf "  bin/ dirs scanned       : %d\n" "$total_dirs"
printf "  files needing patch     : %d\n" "$total_files"
printf "  files already patched   : %d\n" "$total_skipped_clean"
if [ "$APPLY" = "1" ]; then
   printf "  backup suffix           : .%s.bak\n" "$BACKUP_TAG"
   echo
   echo "Verify a sample (no module load required for cmake; PYTHONPATH must be set for run):"
   echo "  PYTORCH=/shared/apps/ubuntu/opt/rocmplus-7.2.1/pytorch-v2.9.1/pytorch"
   echo "  PYTHONPATH=\$PYTORCH/lib/python3.10/site-packages \$PYTORCH/bin/cmake --version"
else
   echo
   echo "Re-run with --apply to actually patch."
fi
