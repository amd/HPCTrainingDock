// Minimal HIP program for SAFE Layer-2 integration testing: it only initializes
// the HIP/HSA runtime via hipGetDeviceCount (NO kernel dispatch, so the MI300A
// per-dispatch-interception crash vector is never exercised) and lives ~10s so
// the 5s rocprof-watch scanner can observe it. Run under `rocprofv3 --hip-trace`
// (host-API trace only) with ROCP_TOOL_LIBRARIES pointing at librocprof_guard.so.
#include <hip/hip_runtime.h>
#include <cstdio>
#include <unistd.h>
int main() {
    int n = 0;
    for (int i = 0; i < 10; ++i) { hipGetDeviceCount(&n); sleep(1); }
    printf("device_count=%d\n", n);
    return 0;
}
