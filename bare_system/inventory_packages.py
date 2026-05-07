#!/usr/bin/env python3
"""inventory_packages.py - generate a presence matrix for rocmplus-* trees.

Surveys every rocmplus-${VERSION} install root under one or more
top-level paths and emits a Markdown table grouped by ROCm major (6.x
vs 7.x/therock/afar). For each canonical package family it reports:

  Y   installed (a directory matching the package's regex exists)
  N   NOT POSSIBLE to build on this SDK (a <pkg>.SKIPPED marker exists);
      see the marker file for the reason -- typically an incomplete AFAR
      SDK that's missing a hard dependency (libMIOpen, hipblas-config,
      clang dev tree, etc.). The setup script took its no-op path
      intentionally; this is NOT a failure.
  B   BUNDLED in the ROCm SDK itself (a <pkg>.BUNDLED marker exists);
      typical case is hipfort, which 6.3+ ships natively. No separate
      install needed; users get the package via the rocm/<v> module.
  -   absent / missing: no install dir AND no marker. Distinct from N.
      Could mean (a) the package was never attempted on this SDK
      (operator-skipped via PACKAGES_LIST or QUICK_INSTALLS), (b) the
      build failed and was cleaned up by the EXIT trap, or (c) the
      package is awaiting a future sweep. Inspect the setup logs to
      tell these apart.

Markers are dropped by the per-package setup scripts at the moment
they take a no-op path (afar-skip / rocm-bundled). See:

  extras/scripts/{pytorch,magma,kokkos,hypre,hipfort}_setup.sh
  tools/scripts/tau_setup.sh

The marker file lives as a sibling of the install dir (i.e. directly
under rocmplus-${VERSION}/), is named ${pkg}.SKIPPED or ${pkg}.BUNDLED,
and contains a short human-readable explanation.

Usage:
  python3 bare_system/inventory_packages.py
  python3 bare_system/inventory_packages.py --roots /shared/apps/ubuntu/opt
  python3 bare_system/inventory_packages.py --reasons   # also print reasons
"""
import argparse
import os
import re
import sys
from datetime import datetime

DEFAULT_ROOTS = ["/shared/apps/ubuntu/opt"]

# (canonical_name, regex matching install dir basename)
PKG_LIST = [
    ("openblas",   r"^openblas(-v.*)?$"),
    ("openmpi",    r"^openmpi-.*"),
    ("ucx",        r"^ucx-.*"),
    ("ucc",        r"^ucc-.*"),
    ("xpmem",      r"^xpmem-.*"),
    ("fftw",       r"^fftw(-v.*)?$"),
    ("hdf5",       r"^hdf5(-v.*)?$"),
    ("pnetcdf",    r"^pnetcdf(-v.*)?$"),
    ("netcdf",     r"^netcdf(?:|-c-v.*|-fortran-v.*)$"),
    ("hipifly",    r"^hipifly$"),
    ("hipfort",    r"^hipfort(-v.*)?$"),
    ("hip-python", r"^hip-python$"),
    ("ftorch",     r"^ftorch$"),
    ("kokkos",     r"^kokkos(-v.*)?$"),
    ("magma",      r"^magma(-v.*)?$"),
    ("hypre",      r"^hypre(-v.*)?$"),
    ("petsc",      r"^petsc(-v.*)?$"),
    ("scorep",     r"^scorep(-v.*)?$"),
    ("tau",        r"^tau$"),
    ("pdt",        r"^pdt$"),
    ("hpctoolkit", r"^hpctoolkit(-v.*)?$"),
    ("hpcviewer",  r"^hpcviewer(-v.*)?$"),
    ("mpi4py",     r"^mpi4py(-v.*)?$"),
    ("cupy",       r"^cupy(-v.*)?$"),
    ("pytorch",    r"^pytorch-v.*$"),
    ("jax",        r"^jax(-v.*)?$"),
    ("jaxlib",     r"^jaxlib(-v.*)?$"),
    ("tensorflow", r"^tensorflow$"),
]


def discover_versions(roots):
    versions = set()
    for r in roots:
        try:
            for d in os.listdir(r):
                if d.startswith("rocmplus-") and os.path.isdir(os.path.join(r, d)):
                    versions.add(d[len("rocmplus-"):])
        except FileNotFoundError:
            pass
    return versions


def version_sort_key(v):
    """Numeric first, then therock, then afar; semantic within each bucket."""
    if v.startswith("therock-"): bucket, body = 1, v[len("therock-"):]
    elif v.startswith("afar-"):  bucket, body = 2, v[len("afar-"):]
    else:                         bucket, body = 0, v
    parts = re.split(r"\.", body)
    key = []
    for p in parts:
        try: key.append((0, int(p)))
        except ValueError: key.append((1, p))
    return (bucket, key)


def list_pkgs(root, version):
    full = os.path.join(root, "rocmplus-" + version)
    try: return os.listdir(full)
    except OSError: return []


def presence(roots, version, pkg, regex):
    """Return one of 'Y', 'N', 'B', '-' for the (version, pkg) cell.

    Order: install dir wins (Y), then SKIPPED marker (N = Not possible
    to build), then BUNDLED marker (B), then absent (-). If both an
    install dir AND a marker are present (transition state during a
    re-run), Y wins because the install is what actually loads.

    The on-disk marker file is named <pkg>.SKIPPED (kept for filename
    consistency with the setup-script writers); the displayed glyph is
    'N' to make it visually distinct from '-' (truly absent / unknown).
    """
    rgx = re.compile(regex)
    has_install = False
    has_notbuildable = False
    has_bundled = False
    for r in roots:
        entries = list_pkgs(r, version)
        if any(rgx.match(b) for b in entries):
            has_install = True
        # markers are flat files at the rocmplus root
        if (pkg + ".SKIPPED") in entries:
            has_notbuildable = True
        if (pkg + ".BUNDLED") in entries:
            has_bundled = True
    if has_install: return "Y"
    if has_notbuildable: return "N"
    if has_bundled: return "B"
    return "-"


def collect_marker_reasons(roots, versions):
    """Return [(version, pkg, kind, first_reason_line, marker_path), ...] sorted.

    `kind` matches the in-table glyph ('N' for .SKIPPED markers, 'B'
    for .BUNDLED markers) so the reasons table reads as a key to the
    main matrix.
    """
    reasons = []
    for v in versions:
        for r in roots:
            tree = os.path.join(r, "rocmplus-" + v)
            if not os.path.isdir(tree):
                continue
            try:
                entries = sorted(os.listdir(tree))
            except OSError:
                continue
            for entry in entries:
                if entry.endswith(".SKIPPED"):
                    kind = "N (not buildable)"
                    pkg = entry[:-len(".SKIPPED")]
                elif entry.endswith(".BUNDLED"):
                    kind = "B (bundled)"
                    pkg = entry[:-len(".BUNDLED")]
                else:
                    continue
                marker_path = os.path.join(tree, entry)
                reason_line = ""
                try:
                    with open(marker_path) as fh:
                        for line in fh:
                            if line.startswith("Reason:"):
                                reason_line = line.split(":", 1)[1].strip()
                                break
                except OSError:
                    pass
                reasons.append((v, pkg, kind, reason_line, marker_path))
    return reasons


def _render_one_md_table(title, versions, roots):
    """Emit a single Markdown table for the given versions. Caller is
    responsible for chunking when len(versions) is too wide for the
    intended renderer (glow auto-shrinks columns past ~7-8 entries on a
    standard 100-col terminal, mangling header text)."""
    print(f"## {title}\n")
    header = ["package"] + versions
    print("| " + " | ".join(header) + " |")
    print("|" + "|".join(["---"] * len(header)) + "|")
    for pkg, regex in PKG_LIST:
        row = [pkg] + [presence(roots, v, pkg, regex) for v in versions]
        print("| " + " | ".join(row) + " |")
    counts = ["**count Y**"] + [
        str(sum(1 for pkg, regex in PKG_LIST
                if presence(roots, v, pkg, regex) == "Y"))
        for v in versions
    ]
    print("| " + " | ".join(counts) + " |")
    print()


def render_table(title, versions, roots, per_table=None):
    """Markdown rendering. With per_table=N, chunk wide tables into
    sub-tables of at most N versions each (good for glow which auto-
    shrinks any table wider than the terminal).
    """
    if per_table and per_table > 0 and len(versions) > per_table:
        for i in range(0, len(versions), per_table):
            chunk = versions[i:i + per_table]
            sub_title = f"{title}  (part {i // per_table + 1} of " \
                        f"{(len(versions) + per_table - 1) // per_table}: " \
                        f"{chunk[0]} … {chunk[-1]})"
            _render_one_md_table(sub_title, chunk, roots)
    else:
        _render_one_md_table(title, versions, roots)


def render_text_table(title, versions, roots):
    """Fixed-width plain-text rendering (no markdown, no glow needed).
    Each cell column is exactly as wide as its header. The single-char
    presence symbols (Y/S/B/-) are right-padded so columns stay aligned
    no matter the version-name length. Renders cleanly in any terminal
    that's at least sum(col_widths) chars wide; otherwise lines wrap
    cleanly at the terminal edge instead of being squashed.
    """
    pkg_col = max(len("package"), max(len(p) for p, _ in PKG_LIST),
                  len("count Y"))
    col_widths = [max(len(v), 3) for v in versions]  # 3 covers 'B'/'S'/'Y'/'-'
    sep = "  "  # two-space gutter between columns

    def emit_row(left, cells):
        parts = [left.ljust(pkg_col)]
        for c, w in zip(cells, col_widths):
            parts.append(str(c).ljust(w))
        print(sep.join(parts).rstrip())

    print(f"=== {title} ===")
    emit_row("package", versions)
    # underline row matching the column widths
    emit_row("-" * pkg_col, ["-" * w for w in col_widths])
    for pkg, regex in PKG_LIST:
        cells = [presence(roots, v, pkg, regex) for v in versions]
        emit_row(pkg, cells)
    counts = [str(sum(1 for pkg, regex in PKG_LIST
                      if presence(roots, v, pkg, regex) == "Y"))
              for v in versions]
    emit_row("-" * pkg_col, ["-" * w for w in col_widths])
    emit_row("count Y", counts)
    print()


def render_reasons(reasons, text=False):
    if not reasons:
        return
    if text:
        print("=== Skip / Bundled reasons (from on-disk markers) ===")
        v_w = max(7, max(len(v) for v, _, _, _, _ in reasons))
        p_w = max(7, max(len(p) for _, p, _, _, _ in reasons))
        k_w = max(4, max(len(k) for _, _, k, _, _ in reasons))
        print(f"{'version'.ljust(v_w)}  {'package'.ljust(p_w)}  "
              f"{'kind'.ljust(k_w)}  reason")
        print(f"{'-' * v_w}  {'-' * p_w}  {'-' * k_w}  ------")
        for v, p, k, r, _ in reasons:
            short = (r[:80] + "...") if len(r) > 80 else r
            print(f"{v.ljust(v_w)}  {p.ljust(p_w)}  {k.ljust(k_w)}  {short}")
        print()
        return
    print("## Skip / Bundled reasons (from on-disk markers)\n")
    print("| version | package | kind | reason (first line) |")
    print("|---|---|---|---|")
    for v, pkg, kind, reason, _path in reasons:
        # truncate long reasons for table readability
        short = (reason[:120] + "...") if len(reason) > 120 else reason
        print(f"| {v} | {pkg} | {kind} | {short} |")
    print()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--roots", nargs="+", default=DEFAULT_ROOTS,
        help=f"top-level install paths to survey "
             f"(default: {DEFAULT_ROOTS[0]})")
    ap.add_argument("--reasons", action="store_true",
        help="also emit a table of marker reasons")
    ap.add_argument("--text", action="store_true",
        help="emit fixed-width plain-text tables (no markdown). "
             "Use this when piping through 'less' or viewing directly "
             "in a terminal -- avoids glow's auto-shrink that mangles "
             "wide-table headers.")
    ap.add_argument("--per-table", type=int, default=0, metavar="N",
        help="when emitting markdown, split the per-bucket table into "
             "sub-tables of at most N versions each. Recommended N=5 "
             "for glow on a standard 100-col terminal. Ignored with --text.")
    args = ap.parse_args()

    all_versions = sorted(discover_versions(args.roots), key=version_sort_key)
    if not all_versions:
        print(f"No rocmplus-* trees found under: {' '.join(args.roots)}",
              file=sys.stderr)
        return 1

    v6 = [v for v in all_versions if v.startswith("6.")]
    v7 = [v for v in all_versions
          if v.startswith("7.")
          or v.startswith("therock-")
          or v.startswith("afar-")]

    if args.text:
        print(f"Sources: {', '.join(args.roots)}")
        print(f"Generated: {datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')}")
        print("Legend: Y = installed,  "
              "N = NOT POSSIBLE to build on this SDK (see <pkg>.SKIPPED marker),  "
              "B = BUNDLED in the ROCm SDK (see <pkg>.BUNDLED marker),  "
              "- = absent / missing (no install, no marker)")
        print()
        if v7: render_text_table("ROCm 7.x.x + therock + afar", v7, args.roots)
        if v6: render_text_table("ROCm 6.x.x", v6, args.roots)
    else:
        print(f"Sources: {', '.join('`' + r + '`' for r in args.roots)}")
        print(f"Generated: "
              f"{datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')}\n")
        print("Legend: **Y** = installed, "
              "**N** = NOT POSSIBLE to build on this SDK "
              "(see `<pkg>.SKIPPED` marker), "
              "**B** = BUNDLED in the ROCm SDK "
              "(see `<pkg>.BUNDLED` marker), "
              "**-** = absent / missing (no install, no marker)\n")
        if v7: render_table("ROCm 7.x.x + therock + afar", v7,
                            args.roots, per_table=args.per_table)
        if v6: render_table("ROCm 6.x.x", v6,
                            args.roots, per_table=args.per_table)

    if args.reasons:
        reasons = collect_marker_reasons(args.roots, all_versions)
        render_reasons(reasons, text=args.text)

    return 0


if __name__ == "__main__":
    sys.exit(main())
