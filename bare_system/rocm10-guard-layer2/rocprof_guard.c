/* ===========================================================================
 * librocprof_guard.so  --  Layer 2 of the MI300A profiling guard.
 * ---------------------------------------------------------------------------
 * WHY
 *   The PATH-shim (Layer 1) only serializes the `rocprofv3` *binary*. On MI300A
 *   every modern front-end -- rocprofv3, rocprof-sys (formerly omnitrace),
 *   rocprof-compute, and the PyTorch/roctracer path -- initializes through
 *   rocprofiler-sdk, so the durable hook is the rocprofiler-sdk TOOL interface,
 *   not N separate CLI wrappers. (There is no rocprofv2 / rocprof to wrap; those
 *   are gone -- everything funnels through rocprofiler-sdk.)
 *
 * WHAT
 *   This is a rocprofiler-sdk tool library. rocprofiler-sdk dlopen()s every lib
 *   listed in ROCP_TOOL_LIBRARIES and calls each one's `rocprofiler_configure`
 *   exactly when profiling initializes -- so this code runs only during real
 *   profiling, never for ordinary GPU jobs. On MI300A it:
 *     (1) BLOCKS Vector B  -- unsets the PC-sampling / SPM *beta* HW modes and
 *         ATT thread-trace env before the SDK reads them (these hard-reset the
 *         node even single-session, and even on ROCm 7.2.4).
 *     (2) SERIALIZES Vector A -- one profiling *session* per node via a node
 *         flock, so concurrent per-dispatch interception across GPUs can't pile
 *         up. Leader election keyed on SLURM_JOB_ID keeps all ranks of ONE job
 *         in the same session (followers do NOT re-lock) so MPI collectives
 *         never deadlock; only a DIFFERENT session waits.
 *     (3) MARKS the run GUARDED -- holds an fd on the node lock (the signal the
 *         rocprof-watch detector keys on) and exports ROCPROFV3_GUARDED=1.
 *   It NEVER creates a rocprofiler context (returns NULL), so it cannot corrupt
 *   the real tool's data, and it is fail-open: any error -> proceed + syslog.
 *
 * Pure libc: no rocprofiler-sdk link/headers, so ONE .so works across every
 * ROCm line (we only rely on the stable `rocprofiler_configure` C ABI).
 *
 * Escape hatches (match the Layer-1 shim):
 *   ROCPROFV3_NOLOCK=1     -> do not serialize (still scrubs beta env).
 *   ROCPROFV3_LOCK_WAIT=N  -> max seconds a new session waits (default 3600).
 * =========================================================================== */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>
#include <errno.h>
#include <signal.h>
#include <syslog.h>

#define LOCKDIR  "/tmp/rocprofv3-pmc"
#define LOCKFILE LOCKDIR "/pmc.node.lock"

static int  g_lockfd = -1;             /* held for process life -> "guarded"   */
static int  g_is_leader = 0;
static char g_leaderpath[256];

/* --- MI300A (gfx942 APU) detection, cached ------------------------------- */
static int is_mi300a(void)
{
    static int cached = -1;
    if (cached >= 0) return cached;
    /* test hook: force-enable on a GPU-less host (front-end) for self-tests */
    if (getenv("ROCPROF_GUARD_FORCE_MI300A")) { cached = 1; return cached; }
    cached = 0;
    DIR *d = opendir("/sys/bus/pci/devices");
    if (!d) return cached;
    struct dirent *e;
    char path[600], buf[64];
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        snprintf(path, sizeof path, "/sys/bus/pci/devices/%s/device", e->d_name);
        int fd = open(path, O_RDONLY);
        if (fd < 0) continue;
        ssize_t n = read(fd, buf, sizeof buf - 1);
        close(fd);
        if (n > 0) { buf[n] = 0; if (strncasecmp(buf, "0x74a0", 6) == 0) { cached = 1; break; } }
    }
    closedir(d);
    return cached;
}

/* --- Vector B block: strip the beta HW-sampling opt-ins ------------------- */
static void scrub_beta_env(void)
{
    unsetenv("ROCPROFILER_PC_SAMPLING_BETA_ENABLED");
    unsetenv("ROCPROFILER_SPM_BETA_ENABLED");
    unsetenv("ROCPROF_ATT_LIBRARY_PATH");
}

/* session = one intended profiling job; all its ranks share the node lock. */
static void session_key(char *buf, size_t n)
{
    const char *j = getenv("SLURM_JOB_ID");
    if (!j || !*j) j = getenv("SLURM_JOBID");
    if (j && *j) snprintf(buf, n, "job-%s", j);
    else         snprintf(buf, n, "sid-%ld", (long)getsid(0));
}

static int pid_alive(long pid)
{
    if (pid <= 0) return 0;
    return (kill((pid_t)pid, 0) == 0) || (errno == EPERM);
}

/* Is a real profiling COLLECTOR active in this process?  On ROCm 10.x the
 * rocprofiler-sdk *core* (librocprofiler-sdk.so) is initialized for EVERY HIP
 * app (for tool discovery), which is why our rocprofiler_configure is invoked
 * even by non-profiling apps. We must therefore stand down unless an actual
 * collector -- the rocprofv3/rocprof-sys tool lib, roctracer, or an ATT/SPM/PC
 * beta engine -- is mapped. That is the same signal that distinguishes an
 * active session from bare runtime linkage. */
static int profiling_active(void)
{
    if (getenv("ROCPROF_GUARD_FORCE_ACTIVE")) return 1;   /* self-test hook */
    int hit = 0;
    FILE *f = fopen("/proc/self/maps", "r");
    if (f) {
        char line[1024];
        while (fgets(line, sizeof line, f)) {
            if (strstr(line, "librocprofiler-sdk-tool") ||
                strstr(line, "libroctracer")            ||
                strstr(line, "librocprofiler-sdk-att")  ||
                strstr(line, "librocprofiler-sdk-spm")  ||
                strstr(line, "librocprofiler-sdk-pc")   ||
                strstr(line, "librocprof-compute")      ||
                strstr(line, "librocprofiler-sys")      ||
                strstr(line, "libomnitrace")) { hit = 1; break; }
        }
        fclose(f);
    }
    /* env-based active tool injection / beta engines also count */
    if (!hit && (getenv("HSA_TOOLS_LIB") ||
                 getenv("ROCPROFILER_PC_SAMPLING_BETA_ENABLED") ||
                 getenv("ROCPROFILER_SPM_BETA_ENABLED"))) hit = 1;
    if (getenv("ROCPROF_GUARD_DEBUG"))
        syslog(LOG_INFO, "profiling_active=%d (pid=%d)", hit, (int)getpid());
    return hit;
}

static void leader_cleanup(void)
{
    if (g_is_leader && g_leaderpath[0]) unlink(g_leaderpath);
}

static void acquire_guard(void)
{
    /* ensure the node lock dir + file exist and are usable by any user */
    mkdir(LOCKDIR, 01777);
    chmod(LOCKDIR, 01777);
    int cf = open(LOCKFILE, O_CREAT | O_RDONLY, 0666);
    if (cf >= 0) close(cf);

    /* Hold an fd on the node lock for our whole life -> the rocprof-watch
     * detector walks /proc/<pid>/fd and classifies us GUARDED. We open this
     * FIRST, before any locking decision, so followers are marked guarded too. */
    g_lockfd = open(LOCKFILE, O_RDONLY);
    if (g_lockfd < 0) {
        syslog(LOG_WARNING, "cannot open %s (%s); proceeding UNGUARDED", LOCKFILE, strerror(errno));
        return;                                     /* fail-open */
    }

    /* CRITICAL de-deadlock: if an ancestor is ALREADY holding the guard lock --
     * the Layer-1 rocprofv3 PATH-shim (which exports ROCPROFV3_GUARDED=1 before
     * exec) or a parent profiling process -- we must NOT try to re-acquire the
     * SAME node lock: the ancestor holds LOCK_EX and won't release until we
     * finish, so blocking here would deadlock. Ride their serialization instead;
     * we already hold an fd on the lock, so we stay marked guarded. */
    if (getenv("ROCPROFV3_GUARDED")) {
        syslog(LOG_NOTICE, "inheriting active guard from an ancestor (holding lock fd, not re-locking)");
        return;
    }

    char key[96];
    session_key(key, sizeof key);
    snprintf(g_leaderpath, sizeof g_leaderpath, "%s/%s.leader", LOCKDIR, key);

    /* Leader election: the first process of a session becomes leader and takes
     * the exclusive node lock; same-session peers are followers and must NOT
     * re-lock (that would deadlock MPI collectives). Self-heals a stale leader
     * file left by a crashed leader within the same uptime. */
    for (int attempt = 0; attempt < 3; attempt++) {
        int lf = open(g_leaderpath, O_CREAT | O_EXCL | O_WRONLY, 0666);
        if (lf >= 0) {
            char pb[32];
            int m = snprintf(pb, sizeof pb, "%ld\n", (long)getpid());
            if (write(lf, pb, m) < 0) { /* best effort */ }
            close(lf);
            g_is_leader = 1;
            atexit(leader_cleanup);
            break;
        }
        if (errno != EEXIST) break;                 /* odd error -> treat as follower */
        long opid = 0;
        int rf = open(g_leaderpath, O_RDONLY);
        if (rf >= 0) { char pb[32]; ssize_t n = read(rf, pb, sizeof pb - 1); close(rf);
                       if (n > 0) { pb[n] = 0; opid = atol(pb); } }
        if (!pid_alive(opid)) { unlink(g_leaderpath); continue; }  /* stale -> retry */
        break;                                                     /* live follower  */
    }

    if (getenv("ROCPROFV3_NOLOCK") || getenv("ROCPROFV3_PMC_NOLOCK")) {
        syslog(LOG_WARNING, "ROCPROFV3_NOLOCK set: NOT serializing (concurrent profiling can hard-reset MI300A)");
    } else if (g_is_leader) {
        long to = 3600; const char *w = getenv("ROCPROFV3_LOCK_WAIT");
        if (w && *w) to = atol(w);
        long waited = 0; int got = 0;
        for (;;) {
            if (flock(g_lockfd, LOCK_EX | LOCK_NB) == 0) { got = 1; break; }
            if (errno != EWOULDBLOCK && errno != EINTR) break;
            if (waited >= to) break;
            sleep(1); waited++;
        }
        if (got) syslog(LOG_NOTICE, "serialized GPU profiling session %s (node lock held)", key);
        else     syslog(LOG_WARNING, "node profiling lock busy after %lds; proceeding without exclusivity (session %s)", waited, key);
    } else {
        syslog(LOG_NOTICE, "joined active profiling session %s (follower; not re-locking)", key);
    }

    /* second, inheritable guard signal (survives reparent/daemonize) */
    setenv("ROCPROFV3_GUARDED", "1", 1);
}

/* --- rocprofiler-sdk tool entry point ------------------------------------
 * Signature ABI-matches:
 *   rocprofiler_tool_configure_result_t*
 *   rocprofiler_configure(uint32_t, const char*, uint32_t, rocprofiler_client_id_t*)
 * We take client_id as an opaque pointer and return NULL (decline to create a
 * context) so we need none of the SDK's headers or struct layouts. */
__attribute__((visibility("default")))
void *rocprofiler_configure(unsigned int version, const char *runtime_version,
                            unsigned int priority, void *client_id)
{
    (void)version; (void)runtime_version; (void)priority; (void)client_id;
    if (!is_mi300a()) return NULL;
    scrub_beta_env();                       /* harmless if nothing to scrub */
    static int done = 0;
    if (!done) {
        done = 1;
        /* Only serialize/guard REAL profiling. rocprofiler-sdk calls us for
         * ordinary GPU apps too (core init), so gate on an active collector to
         * avoid serializing all GPU work. */
        if (profiling_active()) acquire_guard();
        else if (getenv("ROCPROF_GUARD_DEBUG"))
            syslog(LOG_INFO, "loaded without an active collector; standing down (pid=%d)", (int)getpid());
    }
    return NULL;
}

/* Runs at dlopen (i.e. only when rocprofiler loads tools = real profiling):
 * scrub the beta env as early as possible, before the SDK reads it. */
__attribute__((constructor))
static void guard_ctor(void)
{
    openlog("rocprof-guard", LOG_PID, LOG_DAEMON);
    if (is_mi300a()) scrub_beta_env();
}
