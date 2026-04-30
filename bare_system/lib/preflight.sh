#!/bin/bash
# bare_system/lib/preflight.sh -- shared module-prerequisite checker.
#
# Sourced by every rocmplus-relevant setup script. Exposes:
#
#   MISSING_PREREQ_RC          Sentinel exit code (42). main_setup.sh's
#                              run_and_log treats this rc as SKIPPED
#                              instead of FAILED (no cleanup, package
#                              listed under SKIPPED in final summary,
#                              not counted toward the non-zero exit).
#
#   preflight_modules MOD...   Loads each module in order. On the first
#                              module that fails to load, prints the
#                              underlying Lmod error and returns
#                              ${MISSING_PREREQ_RC} so the calling
#                              setup script can `|| exit $?` and bail.
#                              Side-effect: successful modules remain
#                              loaded, so the caller does NOT need to
#                              re-`module load` them afterwards. Order
#                              matters: e.g. rocm/<v> generally has to
#                              come first because its modulefile extends
#                              MODULEPATH with the rocmplus-<v> tree
#                              from which the rest of the modules are
#                              found.
#
# Why a sourceable helper rather than a central PKG_DEPS table:
#   - Each setup script becomes the single source of truth for what it
#     needs to compile/link/test against.
#   - Adding or changing a dep edge is one edit, in the script that
#     actually has the dep.
#   - Catches missing system modules and typoed module names (the
#     central table only tracked deps that were also built here).
#   - The "module load X" lines that already lived inside each script
#     are subsumed: preflight_modules loads them as it verifies them.

# Sentinel exit code. 42 was chosen to avoid collision with rc=1
# (generic error), rc=2 ("misuse of shell builtin"), and rc=126/127
# (command-not-found family). Anything else with `set -eo pipefail` in
# place is a real build failure that should be treated as FAILED, not
# SKIPPED.
MISSING_PREREQ_RC=42

# Defensively initialize Lmod if the caller is running outside the
# usual sbatch / docker entrypoint that pre-sources it. Without this,
# `module` is not a function and `module load` would fail with
# "command not found" -- which would still surface as rc=42 (because
# we treat that as a missing prereq), but with a less helpful message.
if ! type module >/dev/null 2>&1; then
   if [ -r /etc/profile.d/lmod.sh ]; then
      # shellcheck disable=SC1091
      . /etc/profile.d/lmod.sh
   elif [ -r /usr/share/lmod/lmod/init/bash ]; then
      # shellcheck disable=SC1091
      . /usr/share/lmod/lmod/init/bash
   fi
fi

# preflight_modules MOD ...  -- order-sensitive prerequisite check.
preflight_modules()
{
   if [ "$#" -eq 0 ]; then
      return 0
   fi

   if ! type module >/dev/null 2>&1; then
      echo "ERROR: Lmod 'module' command is not a shell function." >&2
      echo "       Cannot preflight required modules:$(printf ' %s' "$@")" >&2
      echo "       Aborting with rc=${MISSING_PREREQ_RC} (missing prereq)." >&2
      return ${MISSING_PREREQ_RC}
   fi

   echo ""
   echo "preflight: required modules:$(printf ' %s' "$@")"

   local m err
   err="$(mktemp -t preflight.XXXXXX.err 2>/dev/null || echo /tmp/preflight.$$.err)"

   for m in "$@"; do
      # `module load` writes diagnostics to stderr. Capture them so we
      # can quote the underlying Lmod error on failure; on success we
      # discard the noise (Lmod is chatty about every module load).
      if ! module load "${m}" 2>"${err}"; then
         echo "ERROR: required module '${m}' could not be loaded." >&2
         if [ -s "${err}" ]; then
            sed 's/^/  module> /' "${err}" >&2
         fi
         echo "       The full required-module list for this script was:" >&2
         echo "         $*" >&2
         echo "       Aborting with rc=${MISSING_PREREQ_RC} (missing prereq)." >&2
         echo "       main_setup.sh will report this as SKIPPED, not FAILED." >&2
         rm -f "${err}"
         return ${MISSING_PREREQ_RC}
      fi
   done

   rm -f "${err}"
   echo "preflight: all required modules loaded."
   echo ""
}
