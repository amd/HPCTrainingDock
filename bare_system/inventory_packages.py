#!/usr/bin/env python3
"""inventory_packages.py - generate a presence matrix for rocmplus-* trees.

Surveys every rocmplus-${VERSION} install root under one or more
top-level paths and emits a Markdown table grouped by ROCm major (6.x
vs 7.x/therock/afar). For each canonical package family it reports:

  Y   installed (a directory matching the package's regex exists)
  N = NOT POSSIBLE to build on this SDK or a hard prereq is missing
      (`<pkg>.SKIPPED`): incomplete AFAR SDK (see other packages), or
      for ftorch a missing `pytorch` Lmod module on the rocmplus tree;
      for jax on Ubuntu 22.04 + ROCm 7+, Python 3.11+ is required (`jax_setup.sh`
      policy gate — see `jax.SKIPPED` / `jaxlib.SKIPPED`).
  B   BUNDLED in the ROCm SDK itself (a <pkg>.BUNDLED marker exists);
      typical case is hipfort, which 6.3+ ships natively. No separate
      install needed; users get the package via the rocm/<v> module.
  -   absent / missing: no install dir AND no marker. Distinct from N.
      Could mean (a) the package was never attempted on this SDK
      (operator-skipped via PACKAGES_LIST or QUICK_INSTALLS), (b) the
      build failed and was cleaned up by the EXIT trap, or (c) the
      package is awaiting a future sweep. Inspect the setup logs to
      tell these apart.

In addition to the per-package presence rows, an `amdclang` metadata
row is emitted below the table reporting the AMD-clang / LLVM version
shipped with each ROCm SDK column (probed by running `clang --version`
under `<rocm>/lib/llvm/bin` or `<rocm>/llvm/bin`). Useful for spotting
toolchain-generation jumps that often correlate with build breakage
(e.g. clang 18 -> 19 between rocm-6.3.x and rocm-6.4.x; clang 22 on
rocm-7.x). '-' means the SDK or the clang binary was not found.

Markers are dropped by the per-package setup scripts at the moment
they take a no-op path (afar-skip / rocm-bundled / ftorch missing
Lmod prereq / jax blocked on Python vs ROCm). See:

  extras/scripts/{pytorch,magma,kokkos,hypre,hipfort,ftorch,jax}_setup.sh
  tools/scripts/tau_setup.sh

The marker file lives as a sibling of the install dir (i.e. directly
under rocmplus-${VERSION}/), is named ${pkg}.SKIPPED or ${pkg}.BUNDLED,
and contains a short human-readable explanation.

With `--versions`, every cell that would have been `Y` is replaced by
the installed version string parsed out of the install dir basename
(e.g. `magma-v2.10.0` -> `2.10.0`, `openmpi-5.0.10-ucc-...` -> `5.0.10`).
The `N` / `B` / `-` glyphs and the `amdclang` / `count Y` rows are
unaffected. A handful of packages that install to a versionless dir
(hipifly, tau, pdt, hip-python, ftorch, tensorflow) keep `Y` even
under `--versions`. When two versions of the same package coexist in
one rocmplus tree (e.g. `pytorch-v2.7.1/` next to `pytorch-v2.9.1/`),
the cell becomes a slash-joined list in semver-ascending order:
`2.7.1 / 2.9.1`. Markdown rendering with `--versions` auto-defaults to
`--per-table 5` if the operator did not pass one explicitly, since
version cells are wider than glyph cells.

Usage:
  python3 bare_system/inventory_packages.py
  python3 bare_system/inventory_packages.py --roots /shared/apps/ubuntu/opt
  python3 bare_system/inventory_packages.py --reasons   # also print reasons
  python3 bare_system/inventory_packages.py --versions  # version strings, not Y
  python3 bare_system/inventory_packages.py --install-provenance  # script@hash dirty/clean
"""
import argparse
import os
import re
import subprocess
import sys
from datetime import datetime
from functools import lru_cache

DEFAULT_ROOTS = ["/shared/apps/ubuntu/opt"]

# (canonical_name,
#  presence_regex,                  -- matches install dir basename for Y/N/B/-
#  version_capture_regex_or_None)   -- single capture group extracting the
#                                      version string from the matched
#                                      basename for `--versions` mode.
#
# version_capture conventions:
#   - For `<pkg>-v<X.Y.Z>` dirs, capture is `^<pkg>-v(.+)$`.
#   - For compound dirs that bake several tools' versions into one path
#     (openmpi/ucx/ucc/xpmem), capture is `^<pkg>-(\d[^-]*)` -- the
#     leading numeric token after the package name. This intentionally
#     ignores the trailing `-ucc-... -ucx-... -xpmem-...` slop so the
#     openmpi cell shows just the openmpi version and the ucx cell
#     shows just the ucx version.
#   - For multi-component packages whose presence_regex matches several
#     dirs (netcdf -> netcdf-c-v* AND netcdf-fortran-v*), capture is
#     scoped to the canonical component (here netcdf-c) so the cell
#     reflects one definite version, not a slash-join of c+fortran.
#   - None means "no version embedded in the dirname"; in --versions
#     mode these packages still render as `Y` (versionless).
PKG_LIST = [
    ("openblas",   r"^openblas(-v.*)?$",                  r"^openblas-v?(.+)$"),
    ("openmpi",    r"^openmpi-.*",                        r"^openmpi-(\d[^-]*)"),
    ("ucx",        r"^ucx-.*",                            r"^ucx-(\d[^-]*)"),
    ("ucc",        r"^ucc-.*",                            r"^ucc-(\d[^-]*)"),
    ("xpmem",      r"^xpmem-.*",                          r"^xpmem-(\d[^-]*)"),
    ("fftw",       r"^fftw(-v.*)?$",                      r"^fftw-v(.+)$"),
    ("hdf5",       r"^hdf5(-v.*)?$",                      r"^hdf5-v(.+)$"),
    ("pnetcdf",    r"^pnetcdf(-v.*)?$",                   r"^pnetcdf-v(.+)$"),
    ("netcdf",     r"^netcdf(?:|-c-v.*|-fortran-v.*)$",   r"^netcdf-c-v(.+)$"),
    ("hipifly",    r"^hipifly$",                          None),
    ("hipfort",    r"^hipfort(-v.*)?$",                   r"^hipfort-v(.+)$"),
    ("hip-python", r"^hip-python$",                       None),
    ("ftorch",     r"^ftorch$",                           None),
    ("kokkos",     r"^kokkos(-v.*)?$",                    r"^kokkos-v(.+)$"),
    ("magma",      r"^magma(-v.*)?$",                     r"^magma-v(.+)$"),
    ("hypre",      r"^hypre(-v.*)?$",                     r"^hypre-v(.+)$"),
    ("petsc",      r"^petsc(-v.*)?$",                     r"^petsc-v(.+)$"),
    ("scorep",     r"^scorep(-v.*)?$",                    r"^scorep-v(.+)$"),
    ("tau",        r"^tau$",                              None),
    ("pdt",        r"^pdt$",                              None),
    ("hpctoolkit", r"^hpctoolkit(-v.*)?$",                r"^hpctoolkit-v(.+)$"),
    ("hpcviewer",  r"^hpcviewer(-v.*)?$",                 r"^hpcviewer-v(.+)$"),
    ("mpi4py",     r"^mpi4py(-v.*)?$",                    r"^mpi4py-v(.+)$"),
    ("cupy",       r"^cupy(-v.*)?$",                      r"^cupy-v(.+)$"),
    ("pytorch",    r"^pytorch-v.*$",                      r"^pytorch-v(.+)$"),
    ("jax",        r"^jax(-v.*)?$",                       r"^jax-v(.+)$"),
    ("jaxlib",     r"^jaxlib(-v.*)?$",                    r"^jaxlib-v(.+)$"),
    ("tensorflow", r"^tensorflow$",                       None),
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


# ── AMD clang / LLVM version probe (metadata row) ──────────────────────
# For each rocmplus-<suffix> column we display the AMD-clang version that
# ships with the corresponding rocm SDK. Mapping rocmplus-<suffix> back to
# the SDK path is non-trivial for RC trees:
#   rocmplus-7.2.1            <- rocm-7.2.1                (1:1)
#   rocmplus-therock-7.13.0   <- rocm-therock-23.2.0       (numeric from .info/version)
#   rocmplus-afar-7.2.0       <- rocm-afar-22.2.0          (ditto)
# So we scan rocm-* siblings of each root, and for non-numeric basenames
# read .info/version to get the numeric -- mirroring main_setup.sh's
# ROCM_NUMERIC / ROCM_RC_PREFIX derivation.
_CLANG_RE = re.compile(r"clang version (\d+(?:\.\d+){0,2})")
_NUMERIC_SUFFIX_RE = re.compile(r"^\d+(?:\.\d+){1,2}$")
_ROCM_SDK_MAP_CACHE = {}  # tuple(roots) -> {suffix: rocm-path}


def _rocm_sdk_map(roots):
    """Return {ROCMPLUS_SUFFIX: /path/to/rocm-<basename>} discovered under roots.

    Suffix is what `main_setup.sh` would name the rocmplus tree (numeric
    for regular releases; '<family>-<numeric>' for RC trees, where
    numeric comes from .info/version).
    """
    key = tuple(roots)
    cached = _ROCM_SDK_MAP_CACHE.get(key)
    if cached is not None:
        return cached
    sdk_map = {}
    for r in roots:
        try:
            entries = os.listdir(r)
        except OSError:
            continue
        for d in entries:
            if not d.startswith("rocm-") or d.startswith("rocmplus-"):
                continue
            full = os.path.join(r, d)
            if not os.path.isdir(full):
                continue
            sx = d[len("rocm-"):]
            if _NUMERIC_SUFFIX_RE.match(sx):
                suffix = sx
            else:
                family = sx.split("-", 1)[0]
                numeric = ""
                vfile = os.path.join(full, ".info", "version")
                try:
                    with open(vfile) as fh:
                        numeric = fh.read().strip().split("-", 1)[0]
                except OSError:
                    pass
                if not numeric:
                    continue
                suffix = f"{family}-{numeric}"
            # First occurrence wins; later roots are fallbacks.
            sdk_map.setdefault(suffix, full)
    _ROCM_SDK_MAP_CACHE[key] = sdk_map
    return sdk_map


@lru_cache(maxsize=None)
def _probe_clang(rocm_path):
    """Run `<rocm>/{lib/llvm,llvm}/bin/clang --version` and parse the
    version. Returns 'X.Y.Z' (or 'X.Y' / 'X' if upstream omits trailing
    components) or '-' if the binary is missing / errors / times out.

    therock SDKs put clang under lib/llvm/bin; regular and afar trees
    put it under llvm/bin -- probe lib/llvm first so therock parses
    cleanly even if a stale /llvm symlink exists on the same tree.
    """
    candidates = [
        os.path.join(rocm_path, "lib", "llvm", "bin", "clang"),
        os.path.join(rocm_path, "llvm", "bin", "clang"),
    ]
    for cl in candidates:
        if not os.path.isfile(cl):
            continue
        try:
            out = subprocess.run([cl, "--version"], capture_output=True,
                                 text=True, timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            return "-"
        m = _CLANG_RE.search((out.stdout or "") + (out.stderr or ""))
        if m:
            return m.group(1)
    return "-"


def clang_version(roots, version):
    """Public lookup used by the renderers. '-' on any miss."""
    sdk = _rocm_sdk_map(roots).get(version)
    return _probe_clang(sdk) if sdk else "-"


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


def _pkg_version_sort_key(s):
    """Tuple key for a package version string, semver-style.

    '2.10.0' sorts AFTER '2.9.1' (numeric comparison per dotted token);
    non-numeric tokens fall back to string compare so e.g. '0.11.2b'
    or '4.7.04' don't crash the sort.
    """
    out = []
    for tok in re.split(r"\.", s):
        try:
            out.append((0, int(tok)))
        except ValueError:
            out.append((1, tok))
    return out


def presence_with_version(roots, version, pkg, presence_regex, version_regex):
    """Like presence(), but on a Y hit returns the installed version string.

    Returns:
      - 'X.Y.Z'                 -- single matching install, version_regex captured
      - 'X.Y.Z / X.Y.W'         -- two or more matching installs (e.g. pytorch-v2.7.1
                                   AND pytorch-v2.9.1 coexisting); slash-joined in
                                   semver-ascending order via _pkg_version_sort_key
      - 'Y'                     -- install present but version_regex is None
                                   (versionless dirs: hipifly, tau, pdt, hip-python,
                                   ftorch, tensorflow) OR version_regex didn't
                                   capture against any matching basename
      - 'N' / 'B' / '-'         -- same semantics as presence(): SKIPPED marker /
                                   BUNDLED marker / absent. Cells unaffected by
                                   --versions mode.
    """
    pres_rgx = re.compile(presence_regex)
    ver_rgx = re.compile(version_regex) if version_regex else None
    matched_basenames = []
    has_notbuildable = False
    has_bundled = False
    for r in roots:
        entries = list_pkgs(r, version)
        for b in entries:
            if pres_rgx.match(b):
                matched_basenames.append(b)
        if (pkg + ".SKIPPED") in entries:
            has_notbuildable = True
        if (pkg + ".BUNDLED") in entries:
            has_bundled = True
    if matched_basenames:
        if ver_rgx is None:
            return "Y"
        captured = []
        for b in matched_basenames:
            m = ver_rgx.match(b)
            if m:
                captured.append(m.group(1))
        if not captured:
            # Install dir matched the presence regex but no version was
            # extractable -- treat like the versionless case so the cell
            # still says "installed".
            return "Y"
        # Deduplicate while preserving sort order.
        unique_sorted = sorted(set(captured), key=_pkg_version_sort_key)
        return " / ".join(unique_sorted)
    if has_notbuildable: return "N"
    if has_bundled: return "B"
    return "-"


def _cell_is_installed(cell):
    """True iff `cell` represents a successful install (Y or any version
    string under --versions mode). Used by `count Y` to count both glyph
    and version cells uniformly."""
    return cell not in {"-", "N", "B"}


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


def _cell_for(roots, version, pkg, pres_regex, ver_regex, versions_mode):
    """Single dispatch point for all renderers: returns the per-cell
    string given the rendering mode. Brief mode delegates to presence();
    versions mode delegates to presence_with_version().
    """
    if versions_mode:
        return presence_with_version(roots, version, pkg, pres_regex, ver_regex)
    return presence(roots, version, pkg, pres_regex)


def _render_one_md_table(title, versions, roots, versions_mode=False):
    """Emit a single Markdown table for the given versions. Caller is
    responsible for chunking when len(versions) is too wide for the
    intended renderer (glow auto-shrinks columns past ~7-8 entries on a
    standard 100-col terminal, mangling header text). With
    versions_mode=True, every cell that would have been 'Y' is replaced
    by the installed version string."""
    print(f"## {title}\n")
    header = ["package"] + versions
    print("| " + " | ".join(header) + " |")
    print("|" + "|".join(["---"] * len(header)) + "|")
    # Pre-compute one full pass of cell values so we can also derive
    # `count Y` without re-walking the filesystem.
    rows = []
    for pkg, pres_regex, ver_regex in PKG_LIST:
        cells = [_cell_for(roots, v, pkg, pres_regex, ver_regex, versions_mode)
                 for v in versions]
        rows.append((pkg, cells))
    for pkg, cells in rows:
        print("| " + " | ".join([pkg] + cells) + " |")
    # AMD clang / LLVM version row -- metadata, not a package presence cell.
    # Placed below the package rows and above 'count Y' so it sits with
    # the other column-summary content.
    clang_row = ["**amdclang**"] + [clang_version(roots, v) for v in versions]
    print("| " + " | ".join(clang_row) + " |")
    # `count Y` counts presence-positive cells (Y under brief mode, OR a
    # version string under --versions mode); -, N, B do not count.
    counts = ["**count Y**"]
    for ci in range(len(versions)):
        counts.append(str(sum(1 for _, cells in rows
                              if _cell_is_installed(cells[ci]))))
    print("| " + " | ".join(counts) + " |")
    print()


def render_table(title, versions, roots, per_table=None, versions_mode=False):
    """Markdown rendering. With per_table=N, chunk wide tables into
    sub-tables of at most N versions each (good for glow which auto-
    shrinks any table wider than the terminal). versions_mode is
    threaded through to _render_one_md_table.
    """
    if per_table and per_table > 0 and len(versions) > per_table:
        for i in range(0, len(versions), per_table):
            chunk = versions[i:i + per_table]
            sub_title = f"{title}  (part {i // per_table + 1} of " \
                        f"{(len(versions) + per_table - 1) // per_table}: " \
                        f"{chunk[0]} … {chunk[-1]})"
            _render_one_md_table(sub_title, chunk, roots,
                                 versions_mode=versions_mode)
    else:
        _render_one_md_table(title, versions, roots,
                             versions_mode=versions_mode)


def render_text_table(title, versions, roots, versions_mode=False):
    """Fixed-width plain-text rendering (no markdown, no glow needed).
    Each cell column is exactly as wide as its header. The single-char
    presence symbols (Y/N/B/-) are right-padded so columns stay aligned
    no matter the version-name length. Renders cleanly in any terminal
    that's at least sum(col_widths) chars wide; otherwise lines wrap
    cleanly at the terminal edge instead of being squashed.

    Under versions_mode=True the per-column width grows to fit the
    widest cell in that column (version strings can run 6-16 chars,
    e.g. '13.6.0' single, '13.6.0 / 14.0.0' multi), so the table stays
    aligned without truncation.
    """
    pkg_col = max(len("package"), max(len(p) for p, _, _ in PKG_LIST),
                  len("count Y"), len("amdclang"))

    # Pre-compute every cell so we can both size columns AND emit rows
    # without walking the filesystem twice.
    package_rows = []
    for pkg, pres_regex, ver_regex in PKG_LIST:
        cells = [_cell_for(roots, v, pkg, pres_regex, ver_regex, versions_mode)
                 for v in versions]
        package_rows.append((pkg, cells))
    clang_cells = [clang_version(roots, v) for v in versions]
    count_cells = [str(sum(1 for _, cells in package_rows
                           if _cell_is_installed(cells[ci])))
                   for ci in range(len(versions))]

    # Per-column width: max(header, all package cells, clang cell, count cell).
    # Unconditional lower bound of 6 (matches the pre-versions behavior) so
    # brief-mode output stays byte-identical -- brief cells are 1 char and
    # short headers like '7.0.0' (5 chars) would otherwise shrink the column
    # below 6 and change alignment vs prior runs. versions_mode can still
    # grow columns above 6 freely to fit '13.6.0 / 14.0.0'-class strings.
    col_widths = []
    for ci, v in enumerate(versions):
        w = max(len(v), 6)
        for _, cells in package_rows:
            w = max(w, len(cells[ci]))
        w = max(w, len(clang_cells[ci]), len(count_cells[ci]))
        col_widths.append(w)
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
    for pkg, cells in package_rows:
        emit_row(pkg, cells)
    # AMD clang / LLVM version row (metadata, not Y/N).
    emit_row("amdclang", clang_cells)
    emit_row("-" * pkg_col, ["-" * w for w in col_widths])
    emit_row("count Y", count_cells)
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


# ── Install-script provenance (--install-provenance) ────────────────
#
# Parses `whatis("Built by: <script>_setup.sh@<hash> (clean|dirty|unknown)")`
# lines that the per-package setup scripts embed in generated modulefiles.
# Reads the .lua text directly off disk -- no Lmod / `module show` needed --
# so this also works in CI / containers that have the files but not a
# fully initialized Lmod environment.

# Inventory pkg name -> module-category dir name under
# {module_path}/rocmplus-{version}/. Most packages match 1:1; the
# exceptions below mirror main_setup.sh's `path_args` / `rocmplus_args`
# wiring. Tuples are tried in order: first dir that actually exists wins
# for the cell.
PKG_TO_MODULE_CAT = {
    "hipfort":  ("hipfort_from_source", "hipfort"),
    "netcdf":   ("netcdf-c", "netcdf-fortran"),
    "ftorch":   ("ftorch", "ftorch_amdflang"),
}

# whatis("Built by: <script>@<hash> (<dirty>)")
# Hash may be empty when the writer ran in a stripped-of-.git context.
_BUILT_BY_LINE_RE = re.compile(
    r'whatis\s*\(\s*"Built by:\s*'
    r'(?P<script>[^@"]+?)@(?P<hash>[0-9a-fA-F]*|unknown)\s+'
    r'\((?P<dirty>clean|dirty|unknown)\)\s*"\s*\)'
)


def _discover_default_module_path():
    """Best-effort resolution of the Lmod tree containing rocmplus-* dirs.

    Returns a path or None. Tried in order:
      1. `module --terse avail` (works under Lmod): take any banner line
         ending in 'base:' and return its dirname.
      2. $MODULEPATH: first component ending in '/base' -> dirname; else
         first component whose parent contains rocmplus-*.
      3. Site default `/shared/apps/modules/ubuntu/lmodfiles` if it exists.
    """
    try:
        out = subprocess.run(
            ["bash", "-lc",
             "source /etc/profile.d/lmod.sh 2>/dev/null; module --terse avail 2>&1"],
            capture_output=True, text=True, timeout=10)
        for line in (out.stdout or "").splitlines():
            line = line.strip()
            if line.endswith("/base:"):
                return os.path.dirname(line[:-1])
    except (OSError, subprocess.TimeoutExpired):
        pass

    mp = os.environ.get("MODULEPATH", "")
    parts = [p for p in mp.split(":") if p]
    for p in parts:
        if p.rstrip("/").endswith("/base") and os.path.isdir(p):
            return os.path.dirname(p.rstrip("/"))
    for p in parts:
        parent = os.path.dirname(p.rstrip("/"))
        if parent and os.path.isdir(parent):
            try:
                if any(d.startswith("rocmplus-")
                       for d in os.listdir(parent)):
                    return parent
            except OSError:
                pass

    fallback = "/shared/apps/modules/ubuntu/lmodfiles"
    return fallback if os.path.isdir(fallback) else None


def _category_dir_for(module_path, version, pkg):
    """Return existing category dir under {module_path}/rocmplus-{version}/
    for `pkg`, or None."""
    base = os.path.join(module_path, f"rocmplus-{version}")
    candidates = PKG_TO_MODULE_CAT.get(pkg, (pkg,))
    for cat in candidates:
        d = os.path.join(base, cat)
        if os.path.isdir(d):
            return d
    return None


def _scan_built_by(category_dir):
    """Return a list of unique (script, hash, dirty) tuples parsed from
    every non-backup .lua under category_dir. Empty if none captured.

    Selection rule: skip files whose name contains '.bak' (the cluster
    keeps timestamped backup copies alongside live modulefiles). Beyond
    that, every modulefile contributes its `Built by:` payload; results
    are deduped (a category can have e.g. <ver>.lua and
    <ver>_tunableop_enabled.lua written by the same setup script with
    the same hash, which then collapses into one cell entry).
    """
    seen = []
    seen_keys = set()
    try:
        names = sorted(os.listdir(category_dir))
    except OSError:
        return seen
    for name in names:
        if not name.endswith(".lua"):
            continue
        if ".bak" in name:
            continue
        path = os.path.join(category_dir, name)
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        m = _BUILT_BY_LINE_RE.search(text)
        if not m:
            continue
        script = m.group("script").strip()
        h = m.group("hash") or ""
        dirty = m.group("dirty")
        key = (script, h, dirty)
        if key not in seen_keys:
            seen_keys.add(key)
            seen.append(key)
    return seen


_DIRTY_GLYPH = {"clean": "C", "dirty": "D", "unknown": "?"}


def _format_provenance_cell(entries, pkg):
    """Render scan output for one cell. Empty list -> 'unknown'.

    Each (script, hash, dirty) entry renders as `<hash6> <C|D|?>` when
    the script's short name (after stripping a trailing `_setup.sh`)
    matches the row's `pkg` (the common case), or `<short-script>@<hash6>
    <C|D|?>` when a different script wrote the modulefile (e.g.
    openblas's modulefile written by magma_setup.sh). Hash is truncated
    to 6 chars (or '?' if empty). Multiple distinct entries are
    slash-joined, mirroring the multi-version cell format under
    --versions in the main matrix.
    """
    if not entries:
        return "unknown"
    parts = []
    for script, h, dirty in entries:
        s = script
        if s.endswith("_setup.sh"):
            s = s[:-len("_setup.sh")]
        h_short = (h[:6] if h else "?")
        d_short = _DIRTY_GLYPH.get(dirty, dirty)
        if s == pkg:
            parts.append(f"{h_short} {d_short}")
        else:
            parts.append(f"{s}@{h_short} {d_short}")
    return " / ".join(parts)


def collect_provenance(module_path, versions):
    """Return {(version, pkg): cell_string} for every (version, pkg) where
    the module-category dir exists. Cells with no category dir are
    omitted; the renderer fills those with '-'."""
    out = {}
    for v in versions:
        for pkg, _pres, _ver in PKG_LIST:
            cat = _category_dir_for(module_path, v, pkg)
            if cat is None:
                continue
            entries = _scan_built_by(cat)
            out[(v, pkg)] = _format_provenance_cell(entries, pkg)
    return out


def _provenance_cell(module_path, version, pkg, scan_cache):
    key = (version, pkg)
    if key in scan_cache:
        return scan_cache[key]
    return "-"


def render_provenance_text(title, versions, module_path, scan_cache):
    print(f"=== {title} ===")
    pkg_col = max(len("package"), max(len(p) for p, _, _ in PKG_LIST))
    cell_rows = []
    for pkg, _pres, _ver in PKG_LIST:
        cells = [_provenance_cell(module_path, v, pkg, scan_cache)
                 for v in versions]
        cell_rows.append((pkg, cells))
    col_widths = []
    for ci, v in enumerate(versions):
        w = max(len(v), 6)
        for _, cells in cell_rows:
            w = max(w, len(cells[ci]))
        col_widths.append(w)
    sep = "  "

    def emit(left, cells):
        parts = [left.ljust(pkg_col)]
        for c, w in zip(cells, col_widths):
            parts.append(str(c).ljust(w))
        print(sep.join(parts).rstrip())

    emit("package", list(versions))
    emit("-" * pkg_col, ["-" * w for w in col_widths])
    for pkg, cells in cell_rows:
        emit(pkg, cells)
    print()


def _render_provenance_md_one(title, versions, module_path, scan_cache):
    print(f"## {title}\n")
    header = ["package"] + list(versions)
    print("| " + " | ".join(header) + " |")
    print("|" + "|".join(["---"] * len(header)) + "|")
    for pkg, _pres, _ver in PKG_LIST:
        cells = [_provenance_cell(module_path, v, pkg, scan_cache)
                 for v in versions]
        print("| " + " | ".join([pkg] + cells) + " |")
    print()


def render_provenance_md(title, versions, module_path, scan_cache,
                         per_table=None):
    if per_table and per_table > 0 and len(versions) > per_table:
        for i in range(0, len(versions), per_table):
            chunk = versions[i:i + per_table]
            sub_title = (f"{title}  (part {i // per_table + 1} of "
                         f"{(len(versions) + per_table - 1) // per_table}: "
                         f"{chunk[0]} … {chunk[-1]})")
            _render_provenance_md_one(sub_title, chunk, module_path,
                                      scan_cache)
    else:
        _render_provenance_md_one(title, versions, module_path, scan_cache)


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
             "for glow on a standard 100-col terminal. Ignored with --text. "
             "If --versions is on and --per-table is left at 0, defaults "
             "to 5 since version cells are wider than glyph cells.")
    ap.add_argument("--versions", action="store_true",
        help="replace 'Y' cells with the installed version string parsed "
             "out of the install dir basename (e.g. magma -> '2.10.0', "
             "openmpi -> '5.0.10'). Versionless dirs (hipifly, tau, pdt, "
             "hip-python, ftorch, tensorflow) keep 'Y'. When two versions "
             "of one package coexist in the same rocmplus tree, cells "
             "render slash-joined in semver-ascending order, e.g. "
             "'2.7.1 / 2.9.1'. 'N'/'B'/'-' glyphs and the amdclang / "
             "count Y rows are unchanged.")
    ap.add_argument("--install-provenance", action="store_true",
        help="emit ONLY the install-script provenance matrix (no Y/N/B/-, "
             "no amdclang, no count Y, no reasons). Cells contain "
             "'<hash6> <C|D>' (hash + clean/dirty) parsed from "
             "whatis(\"Built by: ...\") in each category modulefile; "
             "the writer-script prefix is shown only when it differs "
             "from the row's package name (e.g. magma_setup writes the "
             "openblas modulefile -> 'magma@<hash6> C'). 'unknown' = "
             "installed but no Built-by line; '-' = no modulefile "
             "category dir for that (version, pkg).")
    ap.add_argument("--module-path", default=None, metavar="PATH",
        help="filesystem root containing rocmplus-<version>/<category>/ "
             "modulefiles (same role as main_setup.sh --top-module-path). "
             "Used by --install-provenance. Default: auto-detected from "
             "`module --terse avail` (sibling of the 'base' module tree); "
             "fallbacks: $MODULEPATH, then "
             "/shared/apps/modules/ubuntu/lmodfiles.")
    args = ap.parse_args()

    # Markdown auto-chunk when versions are on (cells get wider, so the
    # full 11-version 7.x table no longer fits glow's default width).
    md_per_table = args.per_table
    if args.versions and not args.text and md_per_table == 0:
        md_per_table = 5

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

    # ── --install-provenance: provenance-only output (exclusive) ────
    if args.install_provenance:
        module_path = args.module_path or _discover_default_module_path()
        if not module_path or not os.path.isdir(module_path):
            print("ERROR: --install-provenance needs a module-path root "
                  "containing rocmplus-<version>/ category dirs.",
                  file=sys.stderr)
            print("       Pass --module-path PATH explicitly. Tried: "
                  f"{module_path or '<none>'}", file=sys.stderr)
            return 1
        scan_cache = collect_provenance(module_path, all_versions)
        # Auto-chunk markdown like the main matrix when per_table is unset.
        prov_per_table = args.per_table if args.per_table else 5
        if args.text:
            print(f"Module path: {module_path}")
            print(f"Install roots (column source): {', '.join(args.roots)}")
            print(f"Generated: "
                  f"{datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')}")
            print("Provenance: parsed from whatis(\"Built by: "
                  "<script>@<hash> (<dirty>)\") lines in modulefiles.")
            print("Cells:  '<hash6> <C|D>'  (writer-script prefix shown "
                  "only when it differs from the row package, e.g. "
                  "'magma@<hash6> C' on the openblas row).  "
                  "'unknown' = no Built-by line  "
                  "'-' = no module category dir")
            print()
            if v7:
                render_provenance_text("ROCm 7.x.x + therock + afar",
                                       v7, module_path, scan_cache)
            if v6:
                render_provenance_text("ROCm 6.x.x", v6,
                                       module_path, scan_cache)
        else:
            print(f"Module path: `{module_path}`  ")
            print("Install roots (column source): "
                  f"{', '.join('`' + r + '`' for r in args.roots)}  ")
            print(f"Generated: "
                  f"{datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')}\n")
            print("Provenance is parsed from `whatis(\"Built by: "
                  "<script>@<hash> (<dirty>)\")` lines in each category's "
                  "modulefile. Cells show **`<hash6> <C|D>`**; the "
                  "writer-script prefix is shown only when it differs "
                  "from the row package (e.g. `magma@<hash6> C` on the "
                  "openblas row). **`unknown`** = modulefile lacks a "
                  "`Built by:` line; **`-`** = no module category dir for "
                  "that (version, pkg).\n")
            if v7:
                render_provenance_md("ROCm 7.x.x + therock + afar", v7,
                                     module_path, scan_cache,
                                     per_table=prov_per_table)
            if v6:
                render_provenance_md("ROCm 6.x.x", v6, module_path,
                                     scan_cache,
                                     per_table=prov_per_table)
        return 0

    versions_note_text = (
        "  Y cells replaced by version string under --versions (versionless "
        "pkgs stay Y; multi-install slash-joined ascending)." if args.versions else "")
    versions_note_md = (
        " With `--versions`, **Y** cells are replaced by the installed version "
        "string (versionless pkgs stay **Y**; multi-install cells slash-joined "
        "in semver order)." if args.versions else "")

    if args.text:
        print(f"Sources: {', '.join(args.roots)}")
        print(f"Generated: {datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')}")
        print("Legend: Y = installed,  "
              "N = NOT POSSIBLE to build on this SDK (see <pkg>.SKIPPED marker),  "
              "B = BUNDLED in the ROCm SDK (see <pkg>.BUNDLED marker),  "
              "- = absent / missing (no install, no marker)" + versions_note_text)
        print()
        if v7: render_text_table("ROCm 7.x.x + therock + afar", v7, args.roots,
                                 versions_mode=args.versions)
        if v6: render_text_table("ROCm 6.x.x", v6, args.roots,
                                 versions_mode=args.versions)
    else:
        print(f"Sources: {', '.join('`' + r + '`' for r in args.roots)}")
        print(f"Generated: "
              f"{datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')}\n")
        print("Legend: **Y** = installed, "
              "**N** = NOT POSSIBLE to build on this SDK "
              "(see `<pkg>.SKIPPED` marker), "
              "**B** = BUNDLED in the ROCm SDK "
              "(see `<pkg>.BUNDLED` marker), "
              "**-** = absent / missing (no install, no marker)."
              + versions_note_md + "\n")
        if v7: render_table("ROCm 7.x.x + therock + afar", v7,
                            args.roots, per_table=md_per_table,
                            versions_mode=args.versions)
        if v6: render_table("ROCm 6.x.x", v6,
                            args.roots, per_table=md_per_table,
                            versions_mode=args.versions)

    if args.reasons:
        reasons = collect_marker_reasons(args.roots, all_versions)
        render_reasons(reasons, text=args.text)

    return 0


if __name__ == "__main__":
    sys.exit(main())
