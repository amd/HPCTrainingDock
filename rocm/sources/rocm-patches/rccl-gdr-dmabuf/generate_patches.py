#!/usr/bin/env python3
"""Regenerate the rccl-gdr-dmabuf patches from the pinned upstream sources.

Backport of ROCm/rocm-systems PR #9692 ("restore HSA DMA-BUF export fallback when cuMem
gate is on", merge 9b68f262826a08a2da44e9317f30f030672904e9, JIRA AICOMRCCL-1695) to the
release lines that carry the defect but not the fix.

The defect: in net.cc and coll_net.cc the cuMem DMA-BUF export path and the older
hsa_amd_portable_export_dmabuf path are mutually exclusive at COMPILE time, selected by
`#if CUDA_VERSION >= 11070 || HIP_VERSION >= 71260540`. Any ROCm whose HIP_VERSION clears
that gate therefore compiles only the cuMem arm, which additionally requires
ncclCuMemEnable() -- hard-defaulted false on ROCm. With no reachable export path, GPU
buffer registration falls through to a plain regMr() that fails on any NIC without a real
peer-memory client (bnxt_re reports "Invalid argument" / "Bad address").

The fix, as upstream: keep both arms compiled and chain them at RUNTIME -- try cuMem only
when useDmaBuf && ncclCuMemEnable(), otherwise fall through to the HSA export, otherwise
regMr. CUDA builds are unaffected because ncclCuMemEnable() auto-detects true there.

Each edit is anchored on a string verified unique in the pinned source, so a drifted
baseline fails loudly here instead of silently producing a no-op patch.
"""

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent

# The HSA arm of a sendProxyConnect/recvProxyConnect staging-buffer registration, as it
# appears in the (now dead) #else branch. Captured so the patch reuses the baseline's own
# text rather than a transcription of it.
# Emitted on every path this patch makes reachable. Two jobs: it is the runtime evidence
# that the fallback (rather than the bare regMr that fails on bnxt_re) was taken, and it is
# the string build_rccl_gdr_dmabuf() greps for to refuse shipping an unpatched artifact.
# INFO and not TRACE: TRACE compiles to nothing unless ENABLE_TRACE is set, so its literal
# never reaches .rodata in a release build and cannot serve as a marker.
MARKER = "rccl-gdr-dmabuf: registering GPU buffer via HSA dma-buf export"
INFO_LINE = f'        INFO(NCCL_INIT|NCCL_NET, "{MARKER}");\n'
INFO_LINE_2SP = f'    INFO(NCCL_INIT|NCCL_NET, "{MARKER}");\n'

CONNECT_RE = re.compile(
    r"(?P<head>      \} else // FALL-THROUGH to nv_peermem GDR path\n"
    r"#else\n"
    r"      /\* DMA-BUF support \*/\n"
    r"      int type = NCCL_NET_MAP_DEV_MEM\(map, buffs\[p\]\) \? NCCL_PTR_CUDA : NCCL_PTR_HOST;\n)"
    r"      if \(type == NCCL_PTR_CUDA && proxyState->dmaBufSupport && pfn_hsa_amd_portable_export_dmabuf\) \{\n"
    r"(?P<body>.*?)"
    r"      \} else // FALL-THROUGH to nv_peermem GDR path\n"
    r"#endif\n",
    re.DOTALL,
)

# The HSA arm of a sendProxyRegBuffer/recvProxyRegBuffer user-buffer registration.
REGBUF_RE = re.compile(
    r"(?P<head>peermem:\n#else\n)"
    r"  if \(resources->useDmaBuf && pfn_hsa_amd_portable_export_dmabuf\) \{\n"
    r"(?P<body>.*?)"
    r"    needReg = false;\n  \}\npeermem:\n#endif\n",
    re.DOTALL,
)


def patch_net_cc(text: str) -> tuple[str, int]:
    """Chain the HSA export after the cuMem arm instead of excluding it at compile time."""
    edits = 0

    def connect(m: re.Match) -> str:
        nonlocal edits
        edits += 1
        # Reachable on ROCm whenever the cuMem arm declined: same condition and same body
        # the #else branch would have used, now evaluated at runtime.
        return (
            "      } else if (type == NCCL_PTR_CUDA && proxyState->dmaBufSupport\n"
            "                 && pfn_hsa_amd_portable_export_dmabuf) {\n"
            + INFO_LINE
            + m.group("body")
            + m.group("head")
            + "      if (type == NCCL_PTR_CUDA && proxyState->dmaBufSupport && pfn_hsa_amd_portable_export_dmabuf) {\n"
            + m.group("body")
            + "      } else // FALL-THROUGH to nv_peermem GDR path\n#endif\n"
        )

    def regbuf(m: re.Match) -> str:
        nonlocal edits
        edits += 1
        return (
            "  if (needReg && resources->useDmaBuf && pfn_hsa_amd_portable_export_dmabuf) {\n"
            + INFO_LINE_2SP
            + m.group("body")
            + "    needReg = false;\n  }\n"
            + m.group("head")
            + "  if (resources->useDmaBuf && pfn_hsa_amd_portable_export_dmabuf) {\n"
            + m.group("body")
            + "    needReg = false;\n  }\npeermem:\n#endif\n"
        )

    text = CONNECT_RE.sub(connect, text)
    text = REGBUF_RE.sub(regbuf, text)
    return text, edits


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--baselines", default=str(HERE / "baselines.conf"))
    ap.add_argument("--only", help="only regenerate this ROCm version")
    args = ap.parse_args()

    rows = []
    for line in Path(args.baselines).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        rows.append(line.split("|"))

    rc = 0
    for version, url, ref, patch_file, subdir in rows:
        if args.only and args.only != version:
            continue
        with tempfile.TemporaryDirectory() as td:
            tree = Path(td) / "src"
            print(f"[{version}] cloning {ref}", flush=True)
            subprocess.run(
                ["git", "clone", "-q", "--depth", "1", "--branch", ref, url, str(tree)],
                check=True,
            )
            root = tree / subdir if subdir != "." else tree
            target = root / "src/transport/net.cc"
            original = target.read_text()
            patched, edits = patch_net_cc(original)
            if edits != 4:
                print(f"[{version}] ERROR: expected 4 anchored edits, made {edits}", file=sys.stderr)
                rc = 1
                continue
            target.write_text(patched)
            # Cut relative to the rccl tree root, as the rccl-sb6033 bundle does, so the
            # same patch serves both the standalone repo and the monorepo (where
            # build_rccl_gdr_dmabuf applies it with `git apply --directory=projects/rccl`).
            # --relative is resolved against -C, so it must run from inside the subdir.
            out = subprocess.run(
                ["git", "-C", str(root), "diff", "--relative"],
                capture_output=True, text=True, check=True,
            )
            dest = HERE / patch_file
            dest.write_text(out.stdout)
            print(f"[{version}] wrote {dest.name} ({edits} edits, {len(out.stdout.splitlines())} lines)")
    return rc


if __name__ == "__main__":
    sys.exit(main())
