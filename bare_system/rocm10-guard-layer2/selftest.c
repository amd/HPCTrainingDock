/* Self-test harness for librocprof_guard.so -- exercises the guard logic with
 * NO GPU / NO real profiling. It dlopen()s the tool and calls its
 * rocprofiler_configure exactly as rocprofiler-sdk would, then reports whether
 * the beta env was scrubbed, the node-lock fd is held, and the guarded marker
 * was set. Use ROCPROF_GUARD_FORCE_MI300A=1 to run on a GPU-less host. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <dirent.h>

typedef void *(*cfg_t)(unsigned, const char *, unsigned, void *);

static int holds_lock(void)
{
    DIR *d = opendir("/proc/self/fd");
    if (!d) return 0;
    struct dirent *e; char p[300], t[600]; int held = 0;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        snprintf(p, sizeof p, "/proc/self/fd/%s", e->d_name);
        ssize_t n = readlink(p, t, sizeof t - 1);
        if (n > 0) { t[n] = 0; if (strstr(t, "pmc.node.lock")) held = 1; }
    }
    closedir(d);
    return held;
}

int main(int argc, char **argv)
{
    const char *so = (argc > 1) ? argv[1] : "./librocprof_guard.so";
    int sleep_s = (argc > 2) ? atoi(argv[2]) : 0;

    /* pretend a profiler enabled the fatal beta modes */
    setenv("ROCPROFILER_PC_SAMPLING_BETA_ENABLED", "1", 1);
    setenv("ROCPROFILER_SPM_BETA_ENABLED", "1", 1);

    void *h = dlopen(so, RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 2; }
    cfg_t cfg = (cfg_t)dlsym(h, "rocprofiler_configure");
    if (!cfg) { fprintf(stderr, "no rocprofiler_configure symbol\n"); return 2; }

    void *r = cfg(100000, "selftest", 0, NULL);

    const char *sess = getenv("SLURM_JOB_ID"); if (!sess) sess = "(sid)";
    printf("pid=%d session=%s configure_ret=%p\n", getpid(), sess, r);
    printf("  pc_sampling_beta after = %s\n", getenv("ROCPROFILER_PC_SAMPLING_BETA_ENABLED") ? "SET (BAD)" : "unset (OK)");
    printf("  spm_beta after         = %s\n", getenv("ROCPROFILER_SPM_BETA_ENABLED")         ? "SET (BAD)" : "unset (OK)");
    printf("  guarded_marker         = %s\n", getenv("ROCPROFV3_GUARDED") ? "1 (OK)" : "unset (BAD)");
    printf("  holds node-lock fd     = %s\n", holds_lock() ? "yes (OK)" : "no (BAD)");
    if (sleep_s > 0) { printf("  holding session for %ds ...\n", sleep_s); fflush(stdout); sleep(sleep_s); }
    return 0;
}
