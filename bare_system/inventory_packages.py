#!/usr/bin/env python3
"""inventory_packages.py - generate a presence matrix for rocmplus-* trees.

Surveys every rocmplus-${VERSION} install root under one or more
top-level paths and emits a Markdown (or text) table per ROCm bucket.
There are THREE buckets, emitted in this order:

  1. `ROCm 7.x.x`                  -- numeric 7.x releases (7.0.x, 7.1.x,
                                      7.2.x, ...). With 7.2.2 + 7.2.3 in
                                      flight this is the widest bucket
                                      -- splitting the RC trees out
                                      keeps it manageable.
  2. `ROCm RC trees (therock + afar)`
                                   -- release-candidate flavours
                                      (`therock-*`, `afar-*`).
                                      As of 2026-05-26 AFAR columns
                                      carry both the compiler/AFAR
                                      release tag AND the SDK numeric:
                                      `afar-22.2.0-7.2.0`,
                                      `afar-23.2.1-7.13.0` (the second
                                      replaces the legacy
                                      `therock-afar-7.13.0`). therock
                                      columns stay single-numeric
                                      (`therock-7.13.0`).
  3. `ROCm 6.x.x`                  -- numeric 6.x releases.

For each canonical package family it reports:

  Y   installed (a single directory matching the package's regex exists)
  <n> installed in multiple distinct directories on the SAME rocmplus
      tree, e.g. `pytorch-v2.7.1/` next to `pytorch-v2.9.1/` -> cell
      shows '2'. Replaces 'Y' whenever the install count is >= 2 so
      the brief table surfaces multi-install columns at a glance;
      `--versions` mode shows the actual version strings instead
      (split across continuation rows in --text output, slash-joined
      in markdown).
  N = NOT POSSIBLE to build on this SDK or a hard prereq is missing
      (`<pkg>.SKIPPED`): incomplete AFAR SDK (see other packages), or
      for ftorch a missing `pytorch` Lmod module on the rocmplus tree.
      (Historically jax on Ubuntu 22.04 + ROCm 7+ was N-marked because
      the default JAX 8.0 dropped Python 3.10; the policy gate in
      `jax_setup.sh` now auto-downshifts to JAX 6.0 — the transition
      release that ships cp310 wheels with the jax_rocm7_* plugin — so
      that combo builds normally rather than producing a SKIPPED marker.)
  B   BUNDLED in the ROCm SDK itself (a <pkg>.BUNDLED marker exists).
      No separate install needed; users get the package via the rocm/<v>
      module. (Historically hipfort was the canonical example, bundled
      from ROCm 6.3+; it's no longer tracked as a separate row here.)
  -   absent / missing: no install dir AND no marker. Distinct from N.
      Could mean (a) the package was never attempted on this SDK
      (operator-skipped via PACKAGES_LIST or QUICK_INSTALLS), (b) the
      build failed and was cleaned up by the EXIT trap, or (c) the
      package is awaiting a future sweep. Inspect the setup logs to
      tell these apart.

In addition to the per-package presence rows, two metadata rows are
emitted below the table:

  amdclang     -- AMD-clang / LLVM version shipped with each ROCm SDK
                  column (probed by running `clang --version` under
                  `<rocm>/lib/llvm/bin` or `<rocm>/llvm/bin`). Useful
                  for spotting toolchain-generation jumps that often
                  correlate with build breakage (e.g. clang 18 -> 19
                  between rocm-6.3.x and rocm-6.4.x; clang 22 on
                  rocm-7.x). '-' means the SDK or the clang binary was
                  not found.

  rocm_patches -- presence of the rocm_patches.sh overlay tree at
                  `<root>/rocm-patches-<version>/`. 'Y' iff the overlay
                  has a populated artefact on disk -- either a
                  `lib/librocprof-sys.so.*` (rocprof-sys overlay) or a
                  `rocprof-compute/lib/rocprof-compute.bin` (rocprof-
                  compute overlay). '-' otherwise (no overlay produced,
                  or only a soft-noop stub for an RC tree whose
                  VERSION.sha was unresolvable). Under
                  `--install-provenance`, this row also pulls the
                  `Built by: rocm_patches.sh@<hash> (<dirty>)` whatis
                  line out of the SDK metamodule
                  `<module_path>/base/rocm/<version>.lua` (rocm_patches
                  edits that file in-place; the line co-exists with
                  rocm_setup.sh's own Built-by line in the same .lua
                  and is disambiguated by writer-script name).

Markers are dropped by the per-package setup scripts at the moment
they take a no-op path (afar-skip / rocm-bundled / ftorch missing
Lmod prereq / jax blocked on Python vs ROCm). See:

  extras/scripts/{pytorch,magma,kokkos,hypre,hipfort,ftorch,jax}_setup.sh
  tools/scripts/tau_setup.sh

The marker file lives as a sibling of the install dir (i.e. directly
under rocmplus-${VERSION}/), is named ${pkg}.SKIPPED or ${pkg}.BUNDLED,
and contains a short human-readable explanation.

With `--versions`, every cell that would have been `Y` (or a multi-
install count like `2`) is replaced by the installed version string
parsed out of the install dir basename (e.g. `magma-v2.10.0` ->
`2.10.0`, `openmpi-5.0.10-ucc-...` -> `5.0.10`). The `N` / `B` / `-`
glyphs and the `amdclang` / `count Y` rows are unaffected. A handful
of packages that install to a versionless dir (hipifly, tau, pdt,
hip-python, tensorflow) keep `Y` even under `--versions`. ftorch
installs were versionless historically (single `${ROCMPLUS}/ftorch/`
dir bound to the highest pytorch's libtorch ABI by chance) but are
now versioned by the bound pytorch release: `ftorch-v<PYTORCH_VER>/`,
mirroring `pytorch-v<PYTORCH_VER>/`. The ftorch cell shows the bound
pytorch version under `--versions`.

When two versions of the same package coexist in one rocmplus tree
(e.g. `pytorch-v2.7.1/` next to `pytorch-v2.9.1/`), the rendering
depends on the output mode:

  - --text (both --versions and --install-provenance): the row spills
    onto a continuation line right below the package row. The package
    label is repeated, the multi-install column shows the next entry
    (e.g. `2.9.1`), and every other column on that continuation line
    is blank. Columns with a single install render unchanged.
  - markdown (default): the cell stays a single table cell and joins
    the entries with ` / ` in semver-ascending order, e.g.
    `2.7.1 / 2.9.1`. Markdown rendering with `--versions` auto-
    defaults to `--per-table 5` if the operator did not pass one
    explicitly, since version cells are wider than glyph cells.

Usage:
  python3 bare_system/inventory_packages.py
  python3 bare_system/inventory_packages.py --roots /shared/apps/ubuntu/opt
  python3 bare_system/inventory_packages.py --reasons   # also print reasons
  python3 bare_system/inventory_packages.py --versions  # version strings, not Y
  python3 bare_system/inventory_packages.py --install-provenance  # script@hash dirty/clean
  python3 bare_system/inventory_packages.py --install-provenance --with-dates
                                                                  # date instead of hash
  python3 bare_system/inventory_packages.py --install-provenance --with-dates \\
                                            --provenance-time      # date + HH:MM
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
    ("hip-python", r"^hip-python$",                       None),
    # ftorch install dirs are versioned by the BOUND pytorch version
    # (NOT by FTorch's own upstream ref): each pytorch version gets its
    # own ftorch-v<PYTV>/ and ftorch_amdflang-v<PYTV>/ install. The
    # version_capture regex extracts <PYTV> for --versions mode so the
    # cell shows e.g. "2.7.1 / 2.9.1" when both are present (rather than
    # just "Y" / "2"). Mirrors pytorch's PKG_LIST entry below. The
    # legacy ${ROCMPLUS}/ftorch (no -v suffix) layout has been retired
    # by the leaf script; the alternation `(?:|-v.*)` keeps the brief
    # presence check tolerant if a stale legacy dir is still on disk.
    ("ftorch",     r"^ftorch(?:|-v.*)$",                  r"^ftorch-v(.+)$"),
    ("kokkos",     r"^kokkos(-v.*)?$",                    r"^kokkos-v(.+)$"),
    ("magma",      r"^magma(-v.*)?$",                     r"^magma-v(.+)$"),
    ("hypre",      r"^hypre(-v.*)?$",                     r"^hypre-v(.+)$"),
    ("petsc",      r"^petsc(-v.*)?$",                     r"^petsc-v(.+)$"),
    ("scorep",     r"^scorep(-v.*)?$",                    r"^scorep-v(.+)$"),
    ("tau",        r"^tau$",                              None),
    ("pdt",        r"^pdt$",                              None),
    ("likwid",     r"^likwid(-v.*)?$",                    r"^likwid-v(.+)$"),
    ("mdb",        r"^mdb(-v.*)?$",                       r"^mdb-v(.+)$"),
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
    """Union of:
      (a) rocmplus-<v> trees discovered under `roots` (on-top packages exist), and
      (b) ROCm SDK installs discovered by _rocm_sdk_map() (SDK exists, no on-top
          packages yet -- e.g. just after the rocm-build sweep, before
          run_rocmplus_install_sweep.sh has run).
    Without (b), versions whose SDK was just deployed (7.2.2 / 7.2.3 today) are
    invisible to the inventory until a rocmplus tree is built.  Both sources
    return suffixes in the canonical rocmplus-style form (numeric for regular
    releases; `<family>-<numeric>` for RC trees), so the union is well-defined.
    `.back` backup dirs and empty-suffix dirs are skipped explicitly.
    """
    versions = set()
    for r in roots:
        try:
            for d in os.listdir(r):
                if d.startswith("rocmplus-") and os.path.isdir(os.path.join(r, d)):
                    suffix = d[len("rocmplus-"):]
                    if not suffix or suffix.endswith(".back"):
                        continue
                    versions.add(suffix)
        except FileNotFoundError:
            pass
    # Merge in SDK-only versions.  _rocm_sdk_map handles the RC suffix
    # translation (rocm-therock-23.2.0 -> therock-7.13.0) so its keys are
    # directly compatible with the rocmplus-* keys above.
    try:
        versions.update(_rocm_sdk_map(roots).keys())
    except Exception:
        pass
    return versions


def _split_version_body(body):
    """Tokenize a version body for sort-key purposes.

    Splits on both '.' and '-' so multi-component AFAR suffixes
    (`22.2.0-7.2.0`) sort coherently: each numeric chunk becomes its
    own token. Returns a list of (sort_class, value) tuples where
    sort_class=0 for integers (compared numerically) and sort_class=1
    for non-numeric tokens (lexicographic). Without the '-' split the
    middle chunk would land in a token like '0-7' that falls into the
    string-compare branch and ruins ordering on the AFAR column set.
    """
    out = []
    for p in re.split(r"[.-]", body):
        try:
            out.append((0, int(p)))
        except ValueError:
            out.append((1, p))
    return out


def version_sort_key(v):
    """Numeric first, then therock, then afar; semantic within each bucket."""
    if v.startswith("therock-"): bucket, body = 1, v[len("therock-"):]
    elif v.startswith("afar-"):  bucket, body = 2, v[len("afar-"):]
    else:                         bucket, body = 0, v
    return (bucket, _split_version_body(body))


def rc_version_sort_key(v):
    """Sort RC trees (therock-*, afar-*) by their numeric body only,
    ignoring the family prefix, so columns in the RC table read
    lowest-to-highest left-to-right regardless of family:
      afar-22.2.0-7.2.0 < afar-23.2.1-7.13.0 < therock-7.13.0.
    """
    if v.startswith("therock-"): body = v[len("therock-"):]
    elif v.startswith("afar-"):  body = v[len("afar-"):]
    else:                        body = v
    return _split_version_body(body)


def list_pkgs(root, version):
    full = os.path.join(root, "rocmplus-" + version)
    try: return os.listdir(full)
    except OSError: return []


# ── AMD clang / LLVM version probe (metadata row) ──────────────────────
# For each rocmplus-<suffix> column we display the AMD-clang version that
# ships with the corresponding rocm SDK. Mapping rocmplus-<suffix> back to
# the SDK path is non-trivial for RC trees:
#   rocmplus-7.2.1                  <- rocm-7.2.1            (1:1)
#   rocmplus-therock-7.13.0         <- rocm-therock-7.13.0   (numeric from .info/version)
#   rocmplus-afar-22.2.0-7.2.0      <- rocm-afar-22.2.0      (compiler tag from basename,
#                                                             numeric from .info/version)
#   rocmplus-afar-23.2.1-7.13.0     <- rocm-afar-23.2.1      (ditto; this is the
#                                                             ex-therock-afar drop, now
#                                                             unified under the afar
#                                                             namespace)
# So we scan rocm-* siblings of each root, and for non-numeric basenames
# read .info/version to get the numeric -- mirroring main_setup.sh's
# ROCM_NUMERIC / ROCM_RC_PREFIX / ROCM_RC_COMPILER derivation.
_CLANG_RE = re.compile(r"clang version (\d+(?:\.\d+){0,2})")
_NUMERIC_SUFFIX_RE = re.compile(r"^\d+(?:\.\d+){1,2}$")
_ROCM_SDK_MAP_CACHE = {}  # tuple(roots) -> {suffix: rocm-path}


def _rocm_sdk_map(roots):
    """Return {ROCMPLUS_SUFFIX: /path/to/rocm-<basename>} discovered under roots.

    Suffix is what `main_setup.sh` would name the rocmplus tree:
      * numeric                       (regular release; SDK basename =
                                       rocm-<numeric>)
      * '<family>-<numeric>'          (non-afar RC tree; SDK basename =
                                       rocm-<family>-<numeric>, e.g.
                                       rocm-therock-7.13.0)
      * 'afar-<compiler>-<numeric>'   (AFAR family; SDK basename =
                                       rocm-afar-<compiler>, e.g.
                                       rocm-afar-22.2.0; the numeric
                                       still comes from .info/version
                                       since the compiler tag in the
                                       basename is the AFAR/clang
                                       release number, NOT the ROCm
                                       SDK numeric)

    The afar branch matches main_setup.sh's ROCMPLUS_SUFFIX construction:
    two AFAR drops with the same SDK numeric but different compiler
    release tags live in distinct rocmplus trees, so the inventory has
    to surface them as distinct columns.
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
                if family == "afar":
                    # rocm-afar-<compiler> -- the chunk after "afar-"
                    # is the compiler/AFAR release number; SDK numeric
                    # comes from .info/version. Skip shapes that don't
                    # match the expected `afar-X.Y[.Z]` form (e.g. a
                    # legacy `rocm-afar-22.2.0-rc1/` with a non-numeric
                    # tail) -- they'd produce an ambiguous suffix.
                    compiler = sx[len("afar-"):]
                    if not _NUMERIC_SUFFIX_RE.match(compiler):
                        continue
                    suffix = f"afar-{compiler}-{numeric}"
                else:
                    suffix = f"{family}-{numeric}"
            # First occurrence wins; later roots are fallbacks.
            sdk_map.setdefault(suffix, full)
    _ROCM_SDK_MAP_CACHE[key] = sdk_map
    return sdk_map


_CLANG_SYMLINK_MAJOR_RE = re.compile(r"^(?:amd)?clang-(\d+)$")


@lru_cache(maxsize=None)
def _probe_clang(rocm_path):
    """Resolve the AMD clang version for an SDK install. Returns 'X.Y.Z'
    (or 'X.Y' / 'X' / 'X.0.0' if only the major is recoverable) or '-'
    if no signal is available.

    therock SDKs put clang under lib/llvm/bin; regular and afar trees
    put it under llvm/bin -- probe lib/llvm first so therock parses
    cleanly even if a stale /llvm symlink exists on the same tree.

    Resolution order per candidate path:
      1. Execute `<clang> --version` and parse the AMD clang version
         line (the precise signal -- yields e.g. '22.0.0').
      2. If exec fails (missing GLIBC on this host -- common when the
         SDK was built for a newer Ubuntu than the inventory runs on,
         e.g. 24.04-built clang on a 22.04 admin node; or any other
         exec error / timeout), fall back to reading the symlink
         target `clang -> clang-<MAJOR>` (or `amdclang -> amdclang-<MAJOR>`).
         Yields a less-precise 'X.0.0' but lets the row render.
    """
    candidates = [
        os.path.join(rocm_path, "lib", "llvm", "bin", "clang"),
        os.path.join(rocm_path, "llvm", "bin", "clang"),
    ]
    for cl in candidates:
        if not (os.path.isfile(cl) or os.path.islink(cl)):
            continue
        # 1. exec path
        try:
            out = subprocess.run([cl, "--version"], capture_output=True,
                                 text=True, timeout=5)
            m = _CLANG_RE.search((out.stdout or "") + (out.stderr or ""))
            if m:
                return m.group(1)
        except (OSError, subprocess.TimeoutExpired):
            pass  # fall through to symlink fallback
        # 2. symlink-target fallback (works without exec; survives glibc skew)
        try:
            tgt = os.readlink(cl) if os.path.islink(cl) else None
        except OSError:
            tgt = None
        if tgt:
            tail = os.path.basename(tgt)
            mm = _CLANG_SYMLINK_MAJOR_RE.match(tail)
            if mm:
                return f"{mm.group(1)}.0.0"
    return "-"


def clang_version(roots, version):
    """Public lookup used by the renderers. '-' on any miss."""
    sdk = _rocm_sdk_map(roots).get(version)
    return _probe_clang(sdk) if sdk else "-"


# ── rocm_patches overlay presence (metadata row, brief mode) ──────────
# The rocm_patches overlay tree lives next to the matching SDK as
# <root>/rocm-patches-<sdk-suffix>/ (a sibling of the SDK install at
# <root>/rocm-<sdk-suffix>/, NOT inside rocmplus-<version>/).
#
# For numeric releases the rocmplus column suffix matches the SDK
# suffix (rocmplus-7.0.0 <-> rocm-patches-7.0.0). For RC trees they
# can differ:
#   * therock:   rocmplus suffix = SDK basename suffix (1:1 today --
#                rocm-therock-7.13.0 -> rocmplus-therock-7.13.0 ->
#                rocm-patches-therock-7.13.0).
#   * afar:      rocmplus suffix carries the SDK numeric as a third
#                segment (afar-22.2.0-7.2.0); the SDK basename keeps
#                only the compiler tag (afar-22.2.0), so the overlay
#                dir is rocm-patches-afar-22.2.0.
# The amdclang row resolves the same mapping via _rocm_sdk_map; reuse
# that here so RC columns line up correctly.
#
# rocm_patches.sh creates the overlay dir only when it has work to do
# for the version, but soft no-op runs (build.sh exit 43 for an RC tree
# without a resolvable VERSION.sha) can leave the dir present-but-empty
# of artefacts, so we additionally require a populated lib/ or
# rocprof-compute/ sub-tree before claiming 'Y'.
def rocm_patches_presence(roots, version):
    """Y if a populated rocm-patches overlay exists for `version`.

    'Populated' means at least one of:
      - lib/ contains a librocprof-sys.so.* (rocprof-sys overlay), or
      - rocprof-compute/lib/rocprof-compute.bin exists (rocprof-compute
        overlay; can be a real file or a symlink).
    Returns '-' otherwise (no overlay produced, or only a soft-noop
    stub on disk).
    """
    sdk = _rocm_sdk_map(roots).get(version)
    if sdk is None:
        return "-"
    overlay = os.path.join(os.path.dirname(sdk),
                           os.path.basename(sdk).replace(
                               "rocm-", "rocm-patches-", 1))
    if not os.path.isdir(overlay):
        return "-"
    lib = os.path.join(overlay, "lib")
    try:
        if os.path.isdir(lib) and any(
                n.startswith("librocprof-sys.so")
                for n in os.listdir(lib)):
            return "Y"
    except OSError:
        pass
    rpc_bin = os.path.join(overlay, "rocprof-compute", "lib",
                           "rocprof-compute.bin")
    if os.path.exists(rpc_bin) or os.path.islink(rpc_bin):
        return "Y"
    return "-"


# rocm_patches provenance also needs the rocmplus-suffix → SDK-suffix
# mapping: the modulefile the script edits is
# `<module_path>/base/rocm/<sdk-suffix>.lua`, and on RC trees that's
# `<module_path>/base/rocm/therock-23.2.0.lua` (NOT `therock-7.13.0.lua`).
def _sdk_suffix_for_rocmplus(roots, version):
    """Return the rocm SDK basename suffix that corresponds to a given
    rocmplus column suffix (matches what `rocm_setup.sh`'s modulefile
    would be named).  None if no SDK was discovered for this version.
    """
    sdk = _rocm_sdk_map(roots).get(version)
    if sdk is None:
        return None
    return os.path.basename(sdk)[len("rocm-"):]


def presence(roots, version, pkg, regex):
    """Return one of 'Y', '<count>', 'N', 'B', '-' for the (version, pkg) cell.

    Order: install dir wins (Y / count), then SKIPPED marker (N = Not
    possible to build), then BUNDLED marker (B), then absent (-). If
    both an install dir AND a marker are present (transition state
    during a re-run), the install wins because that is what actually
    loads.

    When MORE THAN ONE matching install dir is present for the same
    (version, pkg) -- e.g. `pytorch-v2.7.1/` next to `pytorch-v2.9.1/`
    in the same rocmplus tree -- the cell returns the distinct-install
    count as a decimal string (e.g. '2', '3') so the brief presence
    table surfaces multi-install columns at a glance without widening
    to version strings. A single install still returns 'Y' for byte-
    compatibility with prior brief output.

    The on-disk marker file is named <pkg>.SKIPPED (kept for filename
    consistency with the setup-script writers); the displayed glyph is
    'N' to make it visually distinct from '-' (truly absent / unknown).
    """
    rgx = re.compile(regex)
    matched = set()
    has_notbuildable = False
    has_bundled = False
    for r in roots:
        entries = list_pkgs(r, version)
        for b in entries:
            if rgx.match(b):
                matched.add(b)
        # markers are flat files at the rocmplus root
        if (pkg + ".SKIPPED") in entries:
            has_notbuildable = True
        if (pkg + ".BUNDLED") in entries:
            has_bundled = True
    if matched:
        return "Y" if len(matched) == 1 else str(len(matched))
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
    """Like presence(), but on a Y hit returns the installed version string(s).

    Always returns a non-empty `list[str]`; renderers decide whether to
    slash-join (markdown) or render one entry per line (text):

      - ['X.Y.Z']                 -- single matching install, version_regex captured
      - ['X.Y.Z', 'X.Y.W']        -- two or more matching installs (e.g.
                                     pytorch-v2.7.1 AND pytorch-v2.9.1 coexisting);
                                     semver-ascending order via _pkg_version_sort_key
      - ['Y']                     -- install present but version_regex is None
                                     (versionless dirs: hipifly, tau, pdt, hip-python,
                                     ftorch, tensorflow) OR version_regex didn't
                                     capture against any matching basename
      - ['N'] / ['B'] / ['-']     -- same semantics as presence(): SKIPPED marker /
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
            return ["Y"]
        captured = []
        for b in matched_basenames:
            m = ver_rgx.match(b)
            if m:
                captured.append(m.group(1))
        if not captured:
            # Install dir matched the presence regex but no version was
            # extractable -- treat like the versionless case so the cell
            # still says "installed".
            return ["Y"]
        # Deduplicate while preserving sort order.
        return sorted(set(captured), key=_pkg_version_sort_key)
    if has_notbuildable: return ["N"]
    if has_bundled: return ["B"]
    return ["-"]


def _cell_is_installed(cell):
    """True iff `cell` represents a successful install.

    Accepts either a scalar (brief-mode `presence()` result -- 'Y',
    a numeric count string like '2', or one of '-'/'N'/'B'), or a
    `list[str]` (versions-mode `presence_with_version()` result and
    provenance scan_cache values, where any non-{'-','N','B'} first
    entry counts as installed). Used by `count Y` to count both glyph
    and version cells uniformly.
    """
    if isinstance(cell, list):
        if not cell:
            return False
        return cell[0] not in {"-", "N", "B"}
    return cell not in {"-", "N", "B"}


def _join_cell(cell):
    """Slash-join a list cell for renderers that emit one line per cell
    (markdown tables, brief text rendering). Scalar cells pass through
    unchanged so brief-mode call sites can keep using the same code path.
    """
    if isinstance(cell, list):
        return " / ".join(cell)
    return cell


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
        # Cells from _cell_for() under versions_mode are lists (one entry
        # per matched install); markdown collapses them back to a single
        # cell with the historical ' / ' join so the table stays one row
        # per package. Brief-mode scalar cells pass through unchanged.
        joined = [_join_cell(c) for c in cells]
        print("| " + " | ".join([pkg] + joined) + " |")
    # AMD clang / LLVM version row -- metadata, not a package presence cell.
    # Placed below the package rows and above 'count Y' so it sits with
    # the other column-summary content.
    clang_row = ["**amdclang**"] + [clang_version(roots, v) for v in versions]
    print("| " + " | ".join(clang_row) + " |")
    # rocm_patches overlay presence row -- metadata; tracks whether
    # rocm_patches.sh's overlay tree at <root>/rocm-patches-<v>/ has
    # any populated artefacts. Sibling of amdclang.
    rp_row = ["**rocm_patches**"] + [rocm_patches_presence(roots, v)
                                     for v in versions]
    print("| " + " | ".join(rp_row) + " |")
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
    widest cell in that column (single version string, never a slash
    join). Multi-install cells -- e.g. pytorch-v2.7.1 and pytorch-v2.9.1
    in the same rocmplus tree -- spill onto a continuation row right
    below the package row: the package label is repeated, the multi-
    install column shows the next install, and every other column is
    blank on that line. The number of continuation rows for a package
    row is `max(len(cell_list)) - 1` over its columns; rows with no
    multi-install columns emit exactly one line as before.
    """
    pkg_col = max(len("package"), max(len(p) for p, _, _ in PKG_LIST),
                  len("count Y"), len("amdclang"), len("rocm_patches"))

    # Pre-compute every cell so we can both size columns AND emit rows
    # without walking the filesystem twice.  In versions_mode, cells are
    # `list[str]` (one entry per matched install); in brief mode they
    # are scalar strings from presence().  We normalize to lists below
    # so column-width and row-emit logic is uniform.
    package_rows = []
    for pkg, pres_regex, ver_regex in PKG_LIST:
        cells = [_cell_for(roots, v, pkg, pres_regex, ver_regex, versions_mode)
                 for v in versions]
        package_rows.append((pkg, cells))
    clang_cells = [clang_version(roots, v) for v in versions]
    rp_cells = [rocm_patches_presence(roots, v) for v in versions]
    count_cells = [str(sum(1 for _, cells in package_rows
                           if _cell_is_installed(cells[ci])))
                   for ci in range(len(versions))]

    def _as_list(c):
        return c if isinstance(c, list) else [c]

    # Per-column width: max(header, every install entry across all
    # package cells, metadata cells, count cell).  Unconditional lower
    # bound of 6 (matches the pre-versions behavior) so brief-mode
    # output stays byte-identical -- brief cells are 1 char and short
    # headers like '7.0.0' (5 chars) would otherwise shrink the column
    # below 6 and change alignment vs prior runs.  versions_mode can
    # still grow columns above 6 freely to fit the widest install
    # string per column (e.g. '13.6.0', '2.10.0').
    col_widths = []
    for ci, v in enumerate(versions):
        w = max(len(v), 6)
        for _, cells in package_rows:
            for entry in _as_list(cells[ci]):
                w = max(w, len(entry))
        w = max(w, len(clang_cells[ci]), len(rp_cells[ci]),
                len(count_cells[ci]))
        col_widths.append(w)
    sep = "  "  # two-space gutter between columns

    def emit_row(left, cells):
        parts = [left.ljust(pkg_col)]
        for c, w in zip(cells, col_widths):
            parts.append(str(c).ljust(w))
        print(sep.join(parts).rstrip())

    def emit_pkg_row(label, cells):
        """Emit a package row, spilling multi-install cells across
        continuation rows. The label is repeated on every continuation
        row; columns whose install list is shorter than max_rows render
        as blank on the continuation rows."""
        as_lists = [_as_list(c) for c in cells]
        max_rows = max(len(c) for c in as_lists) if as_lists else 1
        for r in range(max_rows):
            row_cells = [(cl[r] if r < len(cl) else "") for cl in as_lists]
            emit_row(label, row_cells)

    print(f"=== {title} ===")
    emit_row("package", versions)
    # underline row matching the column widths
    emit_row("-" * pkg_col, ["-" * w for w in col_widths])
    for pkg, cells in package_rows:
        emit_pkg_row(pkg, cells)
    # Metadata rows (not Y/N package cells): clang ships with the SDK;
    # rocm_patches is the vendored overlay tree applied on top of the SDK.
    emit_row("amdclang", clang_cells)
    emit_row("rocm_patches", rp_cells)
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


def _discover_git_repo():
    """Walk up from this file to the first ancestor containing `.git`.

    Returns an absolute path or None. Used as the default for
    `--git-repo` so commit-date lookups work when the script is run
    from a checkout (the common case in this project).
    """
    here = os.path.dirname(os.path.realpath(__file__))
    cur = here
    while True:
        if os.path.isdir(os.path.join(cur, ".git")):
            return cur
        parent = os.path.dirname(cur)
        if parent == cur:
            return None
        cur = parent


@lru_cache(maxsize=None)
def _commit_date(repo, h, fmt):
    """Return the commit date string for hash `h` in `repo`, formatted
    by git's `--format=%<fmt>` (e.g. 'cs' -> 'YYYY-MM-DD'; 'ci' ->
    'YYYY-MM-DD HH:MM:SS +TZ'). '?' on any failure (no repo, missing
    hash, no git binary, timeout). Cached per (repo, hash, fmt).

    Note: returns the raw git output trimmed to one line; the caller
    is responsible for slicing 'ci' down to 'YYYY-MM-DD HH:MM' if it
    wants minute-precision.
    """
    if not h or h == "unknown" or not repo:
        return "?"
    try:
        out = subprocess.run(
            ["git", "-C", repo, "show", "-s", f"--format=%{fmt}", h],
            capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return "?"
    if out.returncode != 0:
        return "?"
    line = (out.stdout or "").strip().splitlines()[0:1]
    return line[0] if line else "?"


def _commit_date_cell(repo, h, with_dates, time_too):
    """Format the date payload that replaces the hash in a provenance cell.

    Returns:
      - h[:6] when with_dates=False (current behavior).
      - 'YYYY-MM-DD' when with_dates=True, time_too=False.
      - 'YYYY-MM-DD HH:MM' when with_dates=True, time_too=True.
      - '?' if the hash is empty / 'unknown' / not found in `repo`.
    """
    if not with_dates:
        return (h[:6] if h else "?")
    if not h or h == "unknown":
        return "?"
    if time_too:
        raw = _commit_date(repo, h, "ci")  # "YYYY-MM-DD HH:MM:SS +TZ"
        if raw == "?":
            return "?"
        return raw[:16]  # "YYYY-MM-DD HH:MM"
    return _commit_date(repo, h, "cs")  # "YYYY-MM-DD"


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


def _format_provenance_cell(entries, pkg, repo=None,
                            with_dates=False, time_too=False):
    """Render scan output for one cell. Empty list -> ['unknown'].

    Always returns a non-empty `list[str]`; renderers decide whether to
    slash-join (markdown) or render one entry per line (text).

    Each (script, hash, dirty) entry renders as `<payload> <C|D|?>` where
    `<payload>` is `<hash6>` by default, or `YYYY-MM-DD` (resp.
    `YYYY-MM-DD HH:MM`) when --with-dates is on (resp. plus
    --provenance-time). The writer-script prefix `<short-script>@` is
    shown only when the script's short name (after stripping a trailing
    `_setup.sh`) differs from the row's `pkg` (e.g. magma_setup.sh
    writes openblas's modulefile -> 'magma@<payload> C'). Multiple
    distinct entries become multiple list elements, mirroring the
    multi-version cell format under --versions in the main matrix.
    """
    if not entries:
        return ["unknown"]
    parts = []
    for script, h, dirty in entries:
        s = script
        # Longer suffix first so "rocm_setup.sh" -> "rocm" wins over the
        # bare "_setup" / ".sh" trims; "rocm_patches.sh" -> "rocm_patches"
        # via the bare-".sh" branch.
        if s.endswith("_setup.sh"):
            s = s[:-len("_setup.sh")]
        elif s.endswith(".sh"):
            s = s[:-len(".sh")]
        payload = _commit_date_cell(repo, h, with_dates, time_too)
        d_short = _DIRTY_GLYPH.get(dirty, dirty)
        if s == pkg:
            parts.append(f"{payload} {d_short}")
        else:
            parts.append(f"{s}@{payload} {d_short}")
    return parts


def collect_provenance(module_path, versions, repo=None,
                       with_dates=False, time_too=False,
                       roots=None):
    """Return {(version, pkg): cell_string} for every (version, pkg) where
    the module-category dir exists. Cells with no category dir are
    omitted; the renderer fills those with '-'.

    The synthetic pkg name 'rocm_patches' is also populated for every
    version whose base/rocm/<sdk-suffix>.lua modulefile carries a
    `Built by: rocm_patches.sh@...` whatis line. That .lua is the SDK
    metamodule (shared with `rocm_setup.sh`'s own Built-by line); we
    scan ALL whatis matches in the file and filter for the
    rocm_patches writer.

    For RC trees the rocmplus column suffix (e.g. `therock-7.13.0`)
    differs from the SDK basename suffix the modulefile is named with
    (e.g. `therock-23.2.0.lua`). `roots` is consulted via
    `_sdk_suffix_for_rocmplus` to bridge that gap; passing roots=None
    falls back to assuming the column suffix is also the SDK suffix
    (correct for numeric releases).

    `repo`, `with_dates`, `time_too` are threaded into the cell
    formatter; see _format_provenance_cell.
    """
    out = {}
    for v in versions:
        for pkg, _pres, _ver in PKG_LIST:
            cat = _category_dir_for(module_path, v, pkg)
            if cat is None:
                continue
            entries = _scan_built_by(cat)
            out[(v, pkg)] = _format_provenance_cell(
                entries, pkg, repo=repo,
                with_dates=with_dates, time_too=time_too)
        # rocm_patches: not a category dir; read the single SDK .lua
        # (base/rocm/<sdk-suffix>.lua) and pick out only
        # `rocm_patches.sh`-authored Built-by lines, so we don't
        # conflate them with rocm_setup.sh's own line that sits in
        # the same file.
        sdk_suffix = (_sdk_suffix_for_rocmplus(roots, v)
                      if roots else v)
        if sdk_suffix is None:
            continue
        entries = _scan_built_by_in_file(
            os.path.join(module_path, "base", "rocm",
                         sdk_suffix + ".lua"),
            script_filter=("rocm_patches.sh", "rocm_patches"))
        if entries:
            out[(v, "rocm_patches")] = _format_provenance_cell(
                entries, "rocm_patches", repo=repo,
                with_dates=with_dates, time_too=time_too)
    return out


def _scan_built_by_in_file(lua_path, script_filter=None):
    """Like _scan_built_by but for a single .lua path, returning EVERY
    matching Built-by line (uses re.finditer, not re.search).

    A file can legitimately carry several Built-by lines when more than
    one setup script edits it (rocm_setup.sh writes the canonical one
    near the top; rocm_patches.sh appends its own at the end after
    applying an overlay). `script_filter`, when provided, is an
    iterable of acceptable script-name strings; only matching lines
    are returned. Entries are deduped on (script, hash, dirty).
    """
    seen = []
    seen_keys = set()
    if not os.path.isfile(lua_path):
        return seen
    try:
        with open(lua_path, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return seen
    for m in _BUILT_BY_LINE_RE.finditer(text):
        script = m.group("script").strip()
        if script_filter is not None and script not in script_filter:
            continue
        h = m.group("hash") or ""
        dirty = m.group("dirty")
        key = (script, h, dirty)
        if key not in seen_keys:
            seen_keys.add(key)
            seen.append(key)
    return seen


def _provenance_cell(module_path, version, pkg, scan_cache):
    """Look up a (version, pkg) entry in scan_cache. Missing entries fall
    back to ['-'] (list shape mirrors what `_format_provenance_cell`
    returns), so callers can uniformly treat the result as `list[str]`.
    """
    key = (version, pkg)
    if key in scan_cache:
        return scan_cache[key]
    return ["-"]


def render_provenance_text(title, versions, module_path, scan_cache):
    """Fixed-width plain-text rendering of the provenance matrix.

    Cells in scan_cache are `list[str]` (one entry per matching
    `Built by:` writer in the modulefile). Multi-install cells spill
    onto continuation rows below the package row: the package label is
    repeated, the multi-install column shows the next entry, and every
    other column is blank on that line. Column widths fit the widest
    install entry per column.
    """
    print(f"=== {title} ===")
    pkg_col = max(len("package"), max(len(p) for p, _, _ in PKG_LIST),
                  len("rocm_patches"))
    cell_rows = []
    for pkg, _pres, _ver in PKG_LIST:
        cells = [_provenance_cell(module_path, v, pkg, scan_cache)
                 for v in versions]
        cell_rows.append((pkg, cells))
    rp_cells = [_provenance_cell(module_path, v, "rocm_patches", scan_cache)
                for v in versions]

    def _as_list(c):
        return c if isinstance(c, list) else [c]

    col_widths = []
    for ci, v in enumerate(versions):
        w = max(len(v), 6)
        for _, cells in cell_rows:
            for entry in _as_list(cells[ci]):
                w = max(w, len(entry))
        for entry in _as_list(rp_cells[ci]):
            w = max(w, len(entry))
        col_widths.append(w)
    sep = "  "

    def emit(left, cells):
        parts = [left.ljust(pkg_col)]
        for c, w in zip(cells, col_widths):
            parts.append(str(c).ljust(w))
        print(sep.join(parts).rstrip())

    def emit_pkg_row(label, cells):
        as_lists = [_as_list(c) for c in cells]
        max_rows = max(len(c) for c in as_lists) if as_lists else 1
        for r in range(max_rows):
            row_cells = [(cl[r] if r < len(cl) else "") for cl in as_lists]
            emit(label, row_cells)

    emit("package", list(versions))
    emit("-" * pkg_col, ["-" * w for w in col_widths])
    for pkg, cells in cell_rows:
        emit_pkg_row(pkg, cells)
    emit_pkg_row("rocm_patches", rp_cells)
    print()


def _render_provenance_md_one(title, versions, module_path, scan_cache):
    print(f"## {title}\n")
    header = ["package"] + list(versions)
    print("| " + " | ".join(header) + " |")
    print("|" + "|".join(["---"] * len(header)) + "|")
    # scan_cache values are list[str] (one entry per matching Built-by
    # writer); markdown collapses them back to a single cell with the
    # historical ' / ' join so the table stays one row per package.
    for pkg, _pres, _ver in PKG_LIST:
        cells = [_join_cell(_provenance_cell(module_path, v, pkg, scan_cache))
                 for v in versions]
        print("| " + " | ".join([pkg] + cells) + " |")
    # rocm_patches metadata row: same cache as the PKG_LIST rows; the
    # cache is populated from base/rocm/<v>.lua's `Built by:
    # rocm_patches.sh@...` whatis line (see collect_provenance).
    rp_cells = [_join_cell(_provenance_cell(module_path, v, "rocm_patches",
                                            scan_cache))
                for v in versions]
    print("| " + " | ".join(["**rocm_patches**"] + rp_cells) + " |")
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
        help="replace 'Y' (or a multi-install count like '2') cells with "
             "the installed version string parsed out of the install dir "
             "basename (e.g. magma -> '2.10.0', openmpi -> '5.0.10'). "
             "Versionless dirs (hipifly, tau, pdt, hip-python, "
             "tensorflow) keep 'Y'. ftorch is versioned by the bound "
             "pytorch release (ftorch-v<PYTV>) so its cell shows the "
             "bound pytorch version too. When two or more versions of one "
             "package coexist in the same rocmplus tree, --text spills "
             "the row onto continuation lines (label repeated, blanks "
             "in other columns), while markdown joins them with ' / ' "
             "in semver-ascending order ('2.7.1 / 2.9.1'). 'N'/'B'/'-' "
             "glyphs and the amdclang / count Y rows are unchanged.")
    ap.add_argument("--install-provenance", action="store_true",
        help="emit ONLY the install-script provenance matrix (no Y/N/B/-, "
             "no amdclang, no count Y, no reasons). Cells contain "
             "'<hash6> <C|D>' (hash + clean/dirty) parsed from "
             "whatis(\"Built by: ...\") in each category modulefile; "
             "the writer-script prefix is shown only when it differs "
             "from the row's package name (e.g. magma_setup writes the "
             "openblas modulefile -> 'magma@<hash6> C'). 'unknown' = "
             "installed but no Built-by line; '-' = no modulefile "
             "category dir for that (version, pkg). Combine with "
             "--with-dates to swap <hash6> for YYYY-MM-DD.")
    ap.add_argument("--module-path", default=None, metavar="PATH",
        help="filesystem root containing rocmplus-<version>/<category>/ "
             "modulefiles (same role as main_setup.sh --top-module-path). "
             "Used by --install-provenance. Default: auto-detected from "
             "`module --terse avail` (sibling of the 'base' module tree); "
             "fallbacks: $MODULEPATH, then "
             "/shared/apps/modules/ubuntu/lmodfiles.")
    ap.add_argument("--with-dates", action="store_true",
        help="under --install-provenance, REPLACE the 6-char hash in each "
             "cell with the commit date (YYYY-MM-DD) from the git repo, "
             "e.g. '2026-04-19 C' instead of '838906 C'. Empty / unknown "
             "hashes and lookup failures render as '?'.")
    ap.add_argument("--provenance-time", action="store_true",
        help="implies --with-dates; show 'YYYY-MM-DD HH:MM' instead of "
             "just the date (useful when several rebuilds happened on the "
             "same day).")
    ap.add_argument("--git-repo", default=None, metavar="PATH",
        help="git checkout to query for commit dates (used by "
             "--with-dates). Default: walk up from this script's path to "
             "the first ancestor containing .git.")
    args = ap.parse_args()

    # --provenance-time implies --with-dates.
    if args.provenance_time:
        args.with_dates = True
    # --with-dates / --provenance-time / --git-repo only meaningful with
    # --install-provenance; flag mismatch early so the operator sees the
    # error before any output is produced.
    if (args.with_dates or args.git_repo) and not args.install_provenance:
        print("ERROR: --with-dates / --provenance-time / --git-repo "
              "require --install-provenance.", file=sys.stderr)
        return 1

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
    v7 = [v for v in all_versions if v.startswith("7.")]
    vrc = sorted([v for v in all_versions
                  if v.startswith("therock-") or v.startswith("afar-")],
                 key=rc_version_sort_key)

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
        # Resolve git repo for date lookups (only required if --with-dates).
        git_repo = args.git_repo or _discover_git_repo()
        if args.with_dates and (not git_repo or not os.path.isdir(
                os.path.join(git_repo, ".git"))):
            print("ERROR: --with-dates needs a git checkout to look up "
                  "commit dates. Pass --git-repo PATH explicitly. Tried: "
                  f"{git_repo or '<none>'}", file=sys.stderr)
            return 1
        scan_cache = collect_provenance(
            module_path, all_versions,
            repo=git_repo if args.with_dates else None,
            with_dates=args.with_dates,
            time_too=args.provenance_time,
            roots=args.roots)
        # Auto-chunk markdown. Cells widen with date+time, so step
        # --per-table down by one when --provenance-time is on.
        if args.per_table:
            prov_per_table = args.per_table
        elif args.provenance_time:
            prov_per_table = 4
        else:
            prov_per_table = 5
        # Build a one-line description of the cell payload so the legend
        # matches the actual output mode.
        if args.provenance_time:
            payload_desc = "YYYY-MM-DD HH:MM"
        elif args.with_dates:
            payload_desc = "YYYY-MM-DD"
        else:
            payload_desc = "<hash6>"
        if args.text:
            print(f"Module path: {module_path}")
            print(f"Install roots (column source): {', '.join(args.roots)}")
            if args.with_dates:
                print(f"Git repo (commit dates): {git_repo}")
            print(f"Generated: "
                  f"{datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')}")
            print("Provenance: parsed from whatis(\"Built by: "
                  "<script>@<hash> (<dirty>)\") lines in modulefiles.")
            print(f"Cells:  '{payload_desc} <C|D>'  (writer-script prefix "
                  "shown only when it differs from the row package, e.g. "
                  f"'magma@{payload_desc} C' on the openblas row).  "
                  "'unknown' = no Built-by line  "
                  "'-' = no module category dir"
                  + ("  '?' = empty / unresolved hash" if args.with_dates
                     else ""))
            print()
            if v7:
                render_provenance_text("ROCm 7.x.x", v7,
                                       module_path, scan_cache)
            if vrc:
                render_provenance_text("ROCm RC trees (therock + afar)",
                                       vrc, module_path, scan_cache)
            if v6:
                render_provenance_text("ROCm 6.x.x", v6,
                                       module_path, scan_cache)
        else:
            print(f"Module path: `{module_path}`  ")
            print("Install roots (column source): "
                  f"{', '.join('`' + r + '`' for r in args.roots)}  ")
            if args.with_dates:
                print(f"Git repo (commit dates): `{git_repo}`  ")
            print(f"Generated: "
                  f"{datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')}\n")
            unresolved_hint = (
                " **`?`** = empty / unresolved hash (no commit date "
                "available in this checkout)." if args.with_dates else "")
            print("Provenance is parsed from `whatis(\"Built by: "
                  "<script>@<hash> (<dirty>)\")` lines in each category's "
                  f"modulefile. Cells show **`{payload_desc} <C|D>`**; "
                  "the writer-script prefix is shown only when it differs "
                  f"from the row package (e.g. `magma@{payload_desc} C` "
                  "on the openblas row). **`unknown`** = modulefile lacks "
                  "a `Built by:` line; **`-`** = no module category dir "
                  "for that (version, pkg)." + unresolved_hint + "\n")
            if v7:
                render_provenance_md("ROCm 7.x.x", v7,
                                     module_path, scan_cache,
                                     per_table=prov_per_table)
            if vrc:
                render_provenance_md("ROCm RC trees (therock + afar)", vrc,
                                     module_path, scan_cache,
                                     per_table=prov_per_table)
            if v6:
                render_provenance_md("ROCm 6.x.x", v6, module_path,
                                     scan_cache,
                                     per_table=prov_per_table)
        return 0

    versions_note_text = (
        "  Y cells replaced by version string under --versions (versionless "
        "pkgs stay Y; multi-install cells spill onto continuation lines "
        "with the label repeated and other columns blank)." if args.versions
        else "  Multi-install cells show the install count (e.g. '2') "
        "instead of 'Y'.")
    versions_note_md = (
        " With `--versions`, **Y** cells are replaced by the installed version "
        "string (versionless pkgs stay **Y**; multi-install cells slash-joined "
        "in semver order)." if args.versions
        else " Multi-install cells show the install count (e.g. **`2`**) "
        "instead of **Y**.")

    if args.text:
        print(f"Sources: {', '.join(args.roots)}")
        print(f"Generated: {datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')}")
        print("Legend: Y = installed,  "
              "N = NOT POSSIBLE to build on this SDK (see <pkg>.SKIPPED marker),  "
              "B = BUNDLED in the ROCm SDK (see <pkg>.BUNDLED marker),  "
              "- = absent / missing (no install, no marker)." + versions_note_text)
        print()
        if v7:  render_text_table("ROCm 7.x.x", v7, args.roots,
                                  versions_mode=args.versions)
        if vrc: render_text_table("ROCm RC trees (therock + afar)", vrc,
                                  args.roots, versions_mode=args.versions)
        if v6:  render_text_table("ROCm 6.x.x", v6, args.roots,
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
        if v7:  render_table("ROCm 7.x.x", v7,
                             args.roots, per_table=md_per_table,
                             versions_mode=args.versions)
        if vrc: render_table("ROCm RC trees (therock + afar)", vrc,
                             args.roots, per_table=md_per_table,
                             versions_mode=args.versions)
        if v6:  render_table("ROCm 6.x.x", v6,
                             args.roots, per_table=md_per_table,
                             versions_mode=args.versions)

    if args.reasons:
        reasons = collect_marker_reasons(args.roots, all_versions)
        render_reasons(reasons, text=args.text)

    return 0


if __name__ == "__main__":
    sys.exit(main())
