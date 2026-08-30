#!/bin/bash
# Exercise the guard logic without any GPU. Forces MI300A behaviour on this host.
set -u
cd "$(dirname "$0")"
export ROCPROF_GUARD_FORCE_MI300A=1     # pretend this GPU-less host is MI300A
export ROCPROF_GUARD_FORCE_ACTIVE=1     # pretend a real collector is loaded
SO=./librocprof_guard.so
D=/tmp/rocprofv3-pmc
clean(){ rm -f "$D"/job-*.leader "$D"/sid-*.leader 2>/dev/null; }

echo "==================================================================="
echo "T1  single session: beta env scrubbed, lock held, marker set"
echo "-------------------------------------------------------------------"
clean; SLURM_JOB_ID=1001 ./selftest "$SO"

echo
echo "==================================================================="
echo "T2  SAME session (MPI ranks): follower must NOT block (no deadlock)"
echo "-------------------------------------------------------------------"
clean
SLURM_JOB_ID=1002 ./selftest "$SO" 3 >/tmp/l2_t2a.log 2>&1 &   # leader, holds 3s
sleep 1
t0=$(date +%s)
SLURM_JOB_ID=1002 ./selftest "$SO" 0 >/tmp/l2_t2b.log 2>&1     # follower
t1=$(date +%s)
echo "leader:";  sed 's/^/   /' /tmp/l2_t2a.log
echo "follower:"; sed 's/^/   /' /tmp/l2_t2b.log
echo "   >>> follower returned in $((t1-t0))s (expect ~0 = no deadlock)"
wait

echo
echo "==================================================================="
echo "T3  DIFFERENT sessions: second must SERIALIZE behind the first"
echo "-------------------------------------------------------------------"
clean
SLURM_JOB_ID=2001 ./selftest "$SO" 3 >/tmp/l2_t3a.log 2>&1 &   # holds lock 3s
sleep 1
t0=$(date +%s)
SLURM_JOB_ID=2002 ROCPROFV3_LOCK_WAIT=30 ./selftest "$SO" 0 >/tmp/l2_t3b.log 2>&1
t1=$(date +%s)
echo "first:";  sed 's/^/   /' /tmp/l2_t3a.log
echo "second:"; sed 's/^/   /' /tmp/l2_t3b.log
echo "   >>> second session returned in $((t1-t0))s (expect ~2 = waited for first to exit)"
wait

echo
echo "==================================================================="
echo "T4  ANCESTOR already guarding (Layer-1 shim): must NOT re-lock/deadlock"
echo "-------------------------------------------------------------------"
clean
SLURM_JOB_ID=3001 ./selftest "$SO" 3 >/tmp/l2_t4a.log 2>&1 &   # holds node lock 3s
sleep 1
t0=$(date +%s)
# different session, but ROCPROFV3_GUARDED already set (as the shim would) ->
# must inherit and return immediately instead of blocking on the held lock
SLURM_JOB_ID=3002 ROCPROFV3_GUARDED=1 ROCPROFV3_LOCK_WAIT=30 ./selftest "$SO" 0 >/tmp/l2_t4b.log 2>&1
t1=$(date +%s)
echo "holder:";   sed 's/^/   /' /tmp/l2_t4a.log
echo "inheritor:"; sed 's/^/   /' /tmp/l2_t4b.log
echo "   >>> inheritor returned in $((t1-t0))s (expect ~0 = rode ancestor guard, no deadlock)"
wait
clean
echo
echo "self-test complete."
