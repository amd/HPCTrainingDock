#!/usr/bin/env python3
"""Generate the per-baseline rccl-sb6033 patches.

Backport of ROCm/rocm-systems ccba298bcfb644246e07b1137e948a4cab60eb29,
"[RCCL] Harden proxy RPC setup against malformed peer input (#5870)" (ROCM-24271),
which is the fix AMD shipped in ROCm 7.14 for CVE-2026-43598 / AMD-SB-6033.

The upstream diff is cut against the rocm-systems monorepo layout and does not apply
to the pre-7.12 standalone ROCm/rccl trees: the surrounding context drifted across
release lines, and 6.3/6.4 use NCCLCHECK where 7.0+ use NCCLCHECKGOTO. Rather than
force the diff through with reduced context (which can silently place a hunk in the
wrong location), each edit here is anchored on an exact, verified-unique string and
asserts it applied exactly once. Run against a checked-out ROCm/rccl worktree:

    ./generate_patches.py --rccl-src <worktree> --out 0001-rccl-sb6033-<baseline>.patch

The emitted .patch is what rocm_patches.sh actually applies; this script exists so the
patches are reproducible and reviewable rather than hand-edited diffs.
"""

import argparse
import pathlib
import subprocess
import sys

FAILED = []


def edit(path: pathlib.Path, old: str, new: str, *, count: int = 1, optional: bool = False):
    """Replace `old` with `new`, requiring exactly `count` occurrences."""
    if not path.exists():
        if optional:
            return False
        FAILED.append(f"{path}: file missing")
        return False
    text = path.read_text()
    found = text.count(old)
    if found != count:
        if optional and found == 0:
            return False
        FAILED.append(f"{path}: expected {count} match(es), found {found} for:\n    {old.splitlines()[0][:90]}")
        return False
    path.write_text(text.replace(old, new, count))
    return True


# --- src/include/device.h: carry the server-issued handle on the connector -------------

DEVICE_H_OLD = "  int sameProcess;\n"
DEVICE_H_NEW = (
    "  int sameProcess;\n"
    "  int connId; // Server-issued integer handle, used as the wire identifier on subsequent proxy RPCs.\n"
)

# --- src/include/proxy.h: publish the pool + its bounds-checked accessors --------------

PROXY_H_ANCHOR = "typedef ncclResult_t (*threadFunc_t)(struct ncclProxyArgs*);"
PROXY_H_NEW = """#define NCCL_PROXY_CONN_POOL_SIZE_POW2 7
#define NCCL_PROXY_CONN_POOL_SIZE      (1 << NCCL_PROXY_CONN_POOL_SIZE_POW2)
#define NCCL_PROXY_CONN_POOL_MASK      (NCCL_PROXY_CONN_POOL_SIZE - 1)
struct ncclProxyConnectionPool {
  struct ncclProxyConnection** pools;
  int banks;
  int offset;
};
ncclResult_t ncclProxyGetConnection(struct ncclProxyConnectionPool* pool, int id, struct ncclProxyConnection** conn);
ncclResult_t ncclProxyNewConnection(struct ncclProxyConnectionPool* pool, int* id);

""" + PROXY_H_ANCHOR

# --- src/proxy.cc ----------------------------------------------------------------------

POOL_BLOCK_OLD = """#define NCCL_PROXY_CONN_POOL_SIZE_POW2 7
#define NCCL_PROXY_CONN_POOL_SIZE (1<<(NCCL_PROXY_CONN_POOL_SIZE_POW2))
#define NCCL_PROXY_CONN_POOL_MASK ((NCCL_PROXY_CONN_POOL_SIZE)-1)
struct ncclProxyConnectionPool {
  struct ncclProxyConnection** pools;
  int banks;
  int offset;
};

static ncclResult_t ncclProxyNewConnection(struct ncclProxyConnectionPool* pool, int* id) {"""
POOL_BLOCK_NEW = """ncclResult_t ncclProxyNewConnection(struct ncclProxyConnectionPool* pool, int* id) {"""

GETCONN_OLD = """static ncclResult_t ncclProxyGetConnection(struct ncclProxyConnectionPool* pool, int id, struct ncclProxyConnection** conn) {
  int bank = id>>NCCL_PROXY_CONN_POOL_SIZE_POW2;
  int offset = id&NCCL_PROXY_CONN_POOL_MASK;
  if ((pool->pools == NULL) || (bank > pool->banks) || (pool->pools[bank] == NULL)) return ncclInternalError;"""
GETCONN_NEW = """ncclResult_t ncclProxyGetConnection(struct ncclProxyConnectionPool* pool, int id, struct ncclProxyConnection** conn) {
  if (id < 0) return ncclInvalidArgument;
  int bank = id>>NCCL_PROXY_CONN_POOL_SIZE_POW2;
  int offset = id&NCCL_PROXY_CONN_POOL_MASK;
  if ((pool->pools == NULL) || (bank >= pool->banks) || (pool->pools[bank] == NULL)) return ncclInvalidArgument;
  // Last bank's high-water mark is pool->offset; reject IDs past it so callers can't index uninitialized slots.
  if (bank == pool->banks - 1 && offset >= pool->offset) return ncclInvalidArgument;"""

INITRESP_OLD = """struct ncclProxyInitResp {
  ncclProxyConnection* connection;
"""
INITRESP_NEW = """struct ncclProxyInitResp {
  ncclProxyConnection* connection;
  int connId; // Server-issued integer handle. Sent on subsequent RPCs in place of the raw pointer.
"""

CONNECT_RESET_OLD = """  proxyConn->connection = NULL;
"""
CONNECT_RESET_NEW = """  proxyConn->connection = NULL;
  proxyConn->connId = -1;
"""

INIT_COMMENT_OLD = """  // This usually sends proxyConn->connection to identify which connection this is.
  // However, this is part of the response and therefore is ignored
"""
INIT_COMMENT_NEW = """  // The Init RPC ignores the wire connId field (no connection exists yet); the response carries the
  // server-assigned connId, which we echo back on every subsequent RPC for this connection.
"""

CONNECT_ASSIGN_OLD = """  proxyConn->connection = resp.connection;
"""
CONNECT_ASSIGN_NEW = """  proxyConn->connection = resp.connection;
  proxyConn->connId = resp.connId;
"""

INFO_OLD = (
    '  INFO(NCCL_NET|NCCL_PROXY, "Connected to proxy localRank %d -> connection %p", '
    "proxyConn->tpLocalRank, proxyConn->connection);"
)
INFO_NEW = (
    '  INFO(NCCL_NET|NCCL_PROXY, "Connected to proxy localRank %d -> connection %p (connId %d)", '
    "proxyConn->tpLocalRank, proxyConn->connection, proxyConn->connId);"
)

CONNINIT_OLD = """  int id;
  NCCLCHECK(ncclProxyNewConnection(connectionPool, &id));
  NCCLCHECK(ncclProxyGetConnection(connectionPool, id, connection));
"""
CONNINIT_NEW = """  int id;

  if ((unsigned)req->tpLocalRank >= (unsigned)proxyState->tpLocalnRanks) {
    WARN("proxyConnInit: tpLocalRank %d out of range [0,%d)", req->tpLocalRank, proxyState->tpLocalnRanks);
    return ncclInvalidArgument;
  }

  NCCLCHECK(ncclProxyNewConnection(connectionPool, &id));
  NCCLCHECK(ncclProxyGetConnection(connectionPool, id, connection));
"""

RESPCONN_OLD = """  resp->connection = *connection;
"""
RESPCONN_NEW = """  resp->connection = *connection;
  resp->connId = id;
"""

# The client half of the wire change. 6.3/6.4 and 7.0+ differ only in the error-handling macro.
CALLASYNC_VARIANTS = [
    (
        "  NCCLCHECKGOTO(ncclSocketSend(sock, &proxyConn->connection, sizeof(void*)), ret, error);",
        "  // Send the server-issued integer connId rather than the raw pointer. Server resolves to a\n"
        "  // pool-bounds-checked ncclProxyConnection* via ncclProxyGetConnection at the recv site.\n"
        "  NCCLCHECKGOTO(ncclSocketSend(sock, &proxyConn->connId, sizeof(int)), ret, error);",
    ),
    (
        "  NCCLCHECK(ncclSocketSend(sock, &proxyConn->connection, sizeof(void*)));",
        "  // Send the server-issued integer connId rather than the raw pointer. Server resolves to a\n"
        "  // pool-bounds-checked ncclProxyConnection* via ncclProxyGetConnection at the recv site.\n"
        "  NCCLCHECK(ncclSocketSend(sock, &proxyConn->connId, sizeof(int)));",
    ),
]

# The server half: stop reading a raw pointer off the socket.
RECV_COMMENT = """  // Read the integer connId from the wire and resolve it through the bounds-checked pool accessor.
  // Replaces the prior pattern of reading a raw `void*` off the socket and dereferencing it as `this`,
  // which let any peer that knew the comm magic dispatch an indirect call through an arbitrary pointer.
  // Init is the exception: no connection exists yet, so we accept the wire sentinel and let
  // proxyConnInit allocate one and bind it to asyncOp->connection via its out-param.
"""

INITOP_VARIANTS = [
    (
        "  NCCLCHECKGOTO(ncclSocketRecv(sock, &asyncOp->connection, sizeof(void*)), ret, fail);",
        RECV_COMMENT + """  {
    int connId;
    NCCLCHECKGOTO(ncclSocketRecv(sock, &connId, sizeof(int)), ret, fail);
    if (type == ncclProxyMsgInit) {
      asyncOp->connection = NULL;
    } else {
      NCCLCHECKGOTO(ncclProxyGetConnection(connectionPool, connId, &asyncOp->connection), ret, fail);
    }
  }""",
    ),
    (
        "  NCCLCHECK(ncclSocketRecv(sock, &asyncOp->connection, sizeof(void*)));",
        RECV_COMMENT + """  {
    int connId;
    NCCLCHECK(ncclSocketRecv(sock, &connId, sizeof(int)));
    if (type == ncclProxyMsgInit) {
      asyncOp->connection = NULL;
    } else {
      NCCLCHECK(ncclProxyGetConnection(connectionPool, connId, &asyncOp->connection));
    }
  }""",
    ),
]

# --- src/transport/net.cc: bounds-check every wire-supplied tpLocalRank ----------------


def rank_guard(fn: str, var: str) -> str:
    return (
        f'  if ((unsigned){var} >= (unsigned)proxyState->tpLocalnRanks) {{\n'
        f'    WARN("{fn}: tpLocalRank %d out of range [0,%d)", {var}, proxyState->tpLocalnRanks);\n'
        f'    return ncclInvalidArgument;\n'
        f'  }}\n'
    )


NET_EDITS = [
    # sharedNetBuffersInit: guard goes after the PXN host-buffer rejection, before the progressState deref.
    (
        "      WARN(\"PXN should not use host buffers for data\");\n      return ncclInternalError;\n  }\n",
        "      WARN(\"PXN should not use host buffers for data\");\n      return ncclInternalError;\n  }\n"
        + rank_guard("sharedNetBuffersInit", "tpLocalRank"),
    ),
    (
        "static ncclResult_t sharedNetBuffersDestroy(struct ncclProxyState* proxyState, int tpLocalRank, int type, struct ncclProxyConnection* connection) {\n",
        "static ncclResult_t sharedNetBuffersDestroy(struct ncclProxyState* proxyState, int tpLocalRank, int type, struct ncclProxyConnection* connection) {\n"
        + rank_guard("sharedNetBuffersDestroy", "tpLocalRank"),
    ),
]


def apply_proxy_setup_guards(net: pathlib.Path):
    """sendProxySetup / recvProxySetup: guard req->tpLocalRank after the reqSize check.

    Both functions open with an identical `if (reqSize != sizeof(struct setupReq)) return ...;`
    line, so they are edited by locating each function body rather than by a global replace.
    """
    text = net.read_text()
    for fn in ("sendProxySetup", "recvProxySetup"):
        marker = f"static ncclResult_t {fn}(struct ncclProxyConnection* connection"
        start = text.find(marker)
        if start < 0:
            FAILED.append(f"{net}: {fn} not found")
            continue
        anchor = "if (reqSize != sizeof(struct setupReq)) return ncclInternalError;\n"
        at = text.find(anchor, start)
        if at < 0 or at - start > 400:
            FAILED.append(f"{net}: {fn} reqSize guard not found near function head")
            continue
        at += len(anchor)
        text = text[:at] + rank_guard(fn, "req->tpLocalRank") + text[at:]
    net.write_text(text)


# --- test/ProxyTests.cpp: regression coverage for the pool accessor -------------------

TEST_BODY = """
// Regression tests for proxy connection pool bounds checking.
// Bug 1: before the fix, the wire sent a raw void* that the server dereferenced directly.
// These tests verify that ncclProxyGetConnection rejects every malformed integer ID that an
// attacker could substitute for a legitimate connId received over the proxy socket.
TEST(ProxyTests, ProxyConnectionPoolBoundsCheck)
{
    // Build a minimal pool manually: 1 bank, 2 initialized slots (offset = 2).
    // We bypass ncclProxyNewConnection so the test has no runtime dependencies.
    struct ncclProxyConnection conns[NCCL_PROXY_CONN_POOL_SIZE] = {};
    struct ncclProxyConnection* bank0 = conns;
    struct ncclProxyConnectionPool pool;
    pool.pools  = &bank0;
    pool.banks  = 1;
    pool.offset = 2; // slots 0 and 1 are valid

    struct ncclProxyConnection* out = nullptr;

    // Valid IDs must succeed.
    EXPECT_EQ(ncclProxyGetConnection(&pool, 0, &out), ncclSuccess);
    EXPECT_EQ(out, &conns[0]);
    EXPECT_EQ(ncclProxyGetConnection(&pool, 1, &out), ncclSuccess);
    EXPECT_EQ(out, &conns[1]);

    // Negative ID -- primary regression: wire attacker sends e.g. -1 to force arbitrary deref.
    EXPECT_EQ(ncclProxyGetConnection(&pool, -1, &out), ncclInvalidArgument);
    EXPECT_EQ(ncclProxyGetConnection(&pool, INT_MIN, &out), ncclInvalidArgument);

    // ID at or past high-water mark -- slot was allocated but never initialized.
    EXPECT_EQ(ncclProxyGetConnection(&pool, 2, &out), ncclInvalidArgument);
    EXPECT_EQ(ncclProxyGetConnection(&pool, NCCL_PROXY_CONN_POOL_SIZE - 1, &out), ncclInvalidArgument);

    // ID whose bank index exceeds the number of allocated banks.
    EXPECT_EQ(ncclProxyGetConnection(&pool, NCCL_PROXY_CONN_POOL_SIZE, &out), ncclInvalidArgument);
    EXPECT_EQ(ncclProxyGetConnection(&pool, INT_MAX, &out), ncclInvalidArgument);

    // Null pool (no banks allocated).
    struct ncclProxyConnectionPool emptyPool = {nullptr, 0, 0};
    EXPECT_EQ(ncclProxyGetConnection(&emptyPool, 0, &out), ncclInvalidArgument);
}
"""


def apply_test(src: pathlib.Path):
    """Append the gtest to test/ProxyTests.cpp where that file exists (7.1 and later)."""
    test = src / "test" / "ProxyTests.cpp"
    if not test.exists():
        return
    text = test.read_text()
    close = text.rfind("} // namespace RcclUnitTesting")
    if close < 0:
        FAILED.append(f"{test}: namespace close not found")
        return
    if "#include <climits>" not in text:
        text = "#include <climits>\n" + text
        close = text.rfind("} // namespace RcclUnitTesting")
    test.write_text(text[:close] + TEST_BODY + "\n" + text[close:])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rccl-src", required=True, help="checked-out ROCm/rccl worktree")
    ap.add_argument("--out", required=True, help="patch file to write")
    args = ap.parse_args()

    src = pathlib.Path(args.rccl_src).resolve()
    proxy_cc = src / "src" / "proxy.cc"
    net_cc = src / "src" / "transport" / "net.cc"

    edit(src / "src" / "include" / "device.h", DEVICE_H_OLD, DEVICE_H_NEW)
    edit(src / "src" / "include" / "proxy.h", PROXY_H_ANCHOR, PROXY_H_NEW)

    edit(proxy_cc, POOL_BLOCK_OLD, POOL_BLOCK_NEW)
    edit(proxy_cc, GETCONN_OLD, GETCONN_NEW)
    edit(proxy_cc, INITRESP_OLD, INITRESP_NEW)
    edit(proxy_cc, CONNECT_RESET_OLD, CONNECT_RESET_NEW)
    edit(proxy_cc, INIT_COMMENT_OLD, INIT_COMMENT_NEW)
    edit(proxy_cc, CONNECT_ASSIGN_OLD, CONNECT_ASSIGN_NEW)
    edit(proxy_cc, INFO_OLD, INFO_NEW)
    edit(proxy_cc, CONNINIT_OLD, CONNINIT_NEW)
    edit(proxy_cc, RESPCONN_OLD, RESPCONN_NEW)

    for variants, label in ((CALLASYNC_VARIANTS, "ncclProxyCallAsync send"),
                            (INITOP_VARIANTS, "proxyServiceInitOp recv")):
        if not any(edit(proxy_cc, old, new, optional=True) for old, new in variants):
            FAILED.append(f"{proxy_cc}: no variant matched for {label}")

    for old, new in NET_EDITS:
        edit(net_cc, old, new)
    apply_proxy_setup_guards(net_cc)

    apply_test(src)

    if FAILED:
        print("REFUSING to emit patch; unmatched anchors:", file=sys.stderr)
        for f in FAILED:
            print("  -", f, file=sys.stderr)
        return 1

    # --relative keeps paths rooted at the rccl tree, so one patch shape serves both the standalone
    # ROCm/rccl layout and the rocm-systems monorepo's projects/rccl subdirectory.
    diff = subprocess.run(["git", "-C", str(src), "diff", "--relative"],
                          capture_output=True, text=True, check=True).stdout
    pathlib.Path(args.out).write_text(diff)
    print(f"wrote {args.out} ({len(diff.splitlines())} lines)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
