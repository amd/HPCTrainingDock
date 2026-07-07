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
  F   build was ATTEMPTED but FAILED (`<pkg>.FAILED`): the setup script
      exited non-zero and its EXIT trap wiped the partial install +
      modulefile but dropped a persistent .FAILED marker so the failure
      is not confused with "-" (never attempted). The marker is cleared
      automatically on the next successful build of that package.
  -   absent / missing: no install dir AND no marker. Distinct from N/F.
      Could mean (a) the package was never attempted on this SDK
      (operator-skipped via PACKAGES_LIST or QUICK_INSTALLS), or (b) the
      package is awaiting a future sweep. (A build that failed now drops
      an F marker rather than leaving a bare '-'.) Inspect the setup
      logs to tell these apart.

With `--slurm`, the in-flight state of the install queues is overlaid on
top of the on-disk matrix. Two additional glyphs appear, and ONLY in
cells that are otherwise `-` (a real install / N / B marker is never
masked):

  R   install IN PROCESS -- a Slurm job for this (version, package) is
      RUNNING right now. The package is either building or queued to
      build inside that job.
  Q   install QUEUED -- a Slurm job for this (version, package) is
      PENDING (waiting on a node / dependency).

Both glyphs are informational only: they are excluded from the `count Y`
tally the same way `-` is. Discovery scans every `rocmplus_*` job (all
users) via `squeue`; the exact per-package intent + target tree are
recovered from each job's submit command via
`sacct --format=SubmitLine` (which carries the sbatch `--export` list --
PACKAGES_LIST, TOP_INSTALL_PATH / SITE, QUICK_INSTALLS), so PENDING jobs
resolve to individual package cells too, not just whole columns. Jobs
whose target tree does not match `--roots` are ignored, and the overlay
is a silent no-op on hosts without `squeue` / `sacct`.

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
under rocmplus-${VERSION}/), is named ${pkg}.SKIPPED, ${pkg}.BUNDLED,
or ${pkg}.FAILED, and contains a short human-readable explanation. The
.FAILED marker is written by each setup script's EXIT trap on a
non-zero exit (and removed again on the next successful build); it
survives the trap's rm -rf of the partial install because it is a
separate sibling file, not part of the install dir.

With `--versions`, every cell that would have been `Y` (or a multi-
install count like `2`) is replaced by the installed version string
parsed out of the install dir basename (e.g. `magma-v2.10.0` ->
`2.10.0`, `openmpi-5.0.10-ucc-...` -> `5.0.10`). The `N` / `B` / `-`
glyphs and the `amdclang` / `count Y` rows are unaffected. A handful
of packages that install to a versionless dir (hipifly, tau, pdt,
hip-python) keep `Y` even under `--versions`. ftorch installs were
versionless historically (single `${ROCMPLUS}/ftorch/` dir bound to
the highest pytorch's libtorch ABI by chance) but are now versioned
by the bound pytorch release: `ftorch-v<PYTORCH_VER>/`, mirroring
`pytorch-v<PYTORCH_VER>/`. The ftorch cell shows the bound pytorch
version under `--versions`. tensorflow was likewise migrated from a
versionless `${ROCMPLUS}/tensorflow/` dir to `tensorflow-v<TF_VER>/`,
keyed on the TensorFlow release the leaf script just built (per the
ROCm install-on-linux docs supported-versions table); legacy
unversioned installs still render as `Y` so an in-flight migration
shows up cleanly in the matrix.

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

With `--per-version-rows` (opt-in; text, markdown, and
`--install-provenance`), any package that exhibits two or more distinct
versions anywhere in a table is instead rendered VERSION-ALIGNED: one
row per distinct version, labelled `<pkg>=<ver>`, where each column
shows that version only in the row for that exact version (blank
otherwise). This turns the positional continuation rows above into a
matrix that reads down each version:

  pytorch=2.8.0    2.8.0   2.8.0   Q       Q       Q
  pytorch=2.9.1                                                    2.9.1   2.9.1
  pytorch=2.11.0                   Q       Q       Q       2.11.0  2.11.0  2.11.0

Non-version glyphs (`N`/`B`/`F`) and any generic (version-less /
full-sweep) Slurm `Q`/`R` appear on a leading base `<pkg>` row (emitted
only when non-empty); with `--slurm`, a `Q`/`R` whose job targets a
specific version (`PACKAGES_LIST` token `pytorch=2.8.0`) lands on that
exact `<pkg>=<ver>` row. Single-version and versionless packages are
unaffected. In `--install-provenance` the version key is the modulefile
basename (`<ver>.lua`); modulefiles with no parseable version stay on
the base row.

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
  python3 bare_system/inventory_packages.py --slurm     # overlay in-flight
                                                         # (RUNNING/PENDING) installs
  python3 bare_system/inventory_packages.py --versions --per-version-rows
                                                         # one pkg=<ver> row per version
"""
import argparse
import os
import re
import subprocess
import sys
from datetime import datetime
from functools import lru_cache

DEFAULT_ROOTS = ["/nfsapps/ubuntu-24.04/opt"]

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
    # tensorflow installs are now versioned by the built TF release
    # (`tensorflow-v<VER>/`), mirroring pytorch's PKG_LIST entry. The
    # alternation `(?:|-v.*)` keeps the brief presence check tolerant
    # of the legacy unversioned `tensorflow/` install dir if a stale
    # one is still on disk; the version_capture only matches the new
    # versioned form, so a legacy dir renders as 'Y' (versionless)
    # under --versions and the version cell switches to the parsed
    # version string the moment a -v<VER> install lands. Multiple TF
    # versions on one rocmplus tree slash-join in markdown / spill
    # onto continuation rows in --text, the same as pytorch.
    ("tensorflow", r"^tensorflow(?:|-v.*)$",               r"^tensorflow-v(.+)$"),
]

# Packages disabled by --quick-installs (QUICK_INSTALLS=1). Mirrors the
# QUICK_INSTALLS_PKGS array in bare_system/main_setup.sh (search for
# "QUICK_INSTALLS_PKGS="): the long-pole builds (>= 20 min wall) plus the
# explicit always-skip set (julia, intellikit). Only the names that also
# appear as PKG_LIST rows (pytorch/tensorflow/jax/ftorch) actually affect
# the queue overlay; julia/intellikit are not tracked rows. Used by
# collect_slurm_queue() to subtract these when a queued job set
# QUICK_INSTALLS=1 with an empty PACKAGES_LIST (= "all packages except
# the quick-installs gate").
QUICK_INSTALLS_PKGS = {
    "pytorch", "tensorflow", "jax", "ftorch", "julia", "intellikit",
}


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
#   rocmplus-7.13.0                 <- rocm-7.13.0           (1:1; TheRock numeric
#                                                             release >= 7.10.0 now
#                                                             uses plain numeric
#                                                             naming, no therock- prefix)
#   rocmplus-therock-7.13.0         <- rocm-therock-7.13.0   (LEGACY pre-refactor RC
#                                                             tree; still rendered if
#                                                             present on disk)
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
      * numeric                       (regular release OR a TheRock numeric
                                       release >= 7.10.0, both SDK basename =
                                       rocm-<numeric>, e.g. rocm-7.13.0)
      * '<family>-<numeric>'          (non-afar RC tree; SDK basename =
                                       rocm-<family>-<numeric>, e.g. a LEGACY
                                       pre-refactor rocm-therock-7.13.0 tree)
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
    """Return one of 'Y', '<count>', 'N', 'B', 'F', '-' for the (version, pkg) cell.

    Order: install dir wins (Y / count), then SKIPPED marker (N = Not
    possible to build), then BUNDLED marker (B), then FAILED marker
    (F = build was attempted but failed and its partial install was
    auto-removed), then absent (-). If both an install dir AND a marker
    are present (transition state during a re-run), the install wins
    because that is what actually loads.

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
    has_failed = False
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
        if (pkg + ".FAILED") in entries:
            has_failed = True
    if matched:
        return "Y" if len(matched) == 1 else str(len(matched))
    if has_notbuildable: return "N"
    if has_bundled: return "B"
    if has_failed: return "F"
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
                                     (versionless dirs: hipifly, tau, pdt, hip-python)
                                     OR version_regex didn't capture against any
                                     matching basename (e.g. a legacy unversioned
                                     ftorch / tensorflow dir still on disk after the
                                     versioning migration)
      - ['N'] / ['B'] / ['F'] / ['-']
                                  -- same semantics as presence(): SKIPPED marker /
                                     BUNDLED marker / FAILED marker (attempted but
                                     failed) / absent. Cells unaffected by
                                     --versions mode.
    """
    pres_rgx = re.compile(presence_regex)
    ver_rgx = re.compile(version_regex) if version_regex else None
    matched_basenames = []
    has_notbuildable = False
    has_bundled = False
    has_failed = False
    for r in roots:
        entries = list_pkgs(r, version)
        for b in entries:
            if pres_rgx.match(b):
                matched_basenames.append(b)
        if (pkg + ".SKIPPED") in entries:
            has_notbuildable = True
        if (pkg + ".BUNDLED") in entries:
            has_bundled = True
        if (pkg + ".FAILED") in entries:
            has_failed = True
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
    if has_failed: return ["F"]
    return ["-"]


# Non-install glyphs that must NOT be counted by `count Y`: the truly-
# absent '-', the NOT-buildable 'N', the BUNDLED 'B', the FAILED 'F'
# (attempted but failed; partial install auto-removed), and the two
# Slurm queue-overlay glyphs 'R' (install in process) / 'Q' (install
# queued). Queue glyphs sit only in cells that were '-' on disk (see
# _apply_queue_overlay), so they represent work not-yet-on-disk and are
# excluded from the installed count for the same reason '-' is.
_NON_INSTALL_GLYPHS = {"-", "N", "B", "F", "R", "Q"}

# Slurm queue-overlay glyphs. RUNNING wins over PENDING when a version is
# represented by jobs in both states (see collect_slurm_queue).
QUEUE_GLYPH = {"R": "R", "PD": "Q"}

# Precedence for queue states: RUNNING ('R') outranks PENDING ('PD') so a
# running job is never masked by a pending one when both are present for
# the same (suffix, pkg[, version]).
_QUEUE_RANK = {"R": 2, "PD": 1}


def _queue_collapse(state_by_ver):
    """Collapse a {version_or_None: state} dict to a single state.

    Used by the default (non --per-version-rows) overlay path, which does
    not care WHICH version is in flight -- only whether the (suffix, pkg)
    has any RUNNING / PENDING job. 'R' outranks 'PD'. Returns None for an
    empty / falsy mapping.
    """
    best = None
    for st in (state_by_ver or {}).values():
        if best is None or _QUEUE_RANK.get(st, 0) > _QUEUE_RANK.get(best, 0):
            best = st
    return best


def _is_version_entry(s):
    """True iff `s` is an actual version string rather than a status glyph.

    Filters out the presence/queue glyphs ('-', 'N', 'B', 'F', 'R', 'Q'),
    the versionless-install marker 'Y', and the provenance 'unknown'
    sentinel. Everything else (e.g. '2.9.1', but also a brief-mode
    multi-install count like '2') is treated as a version token, so
    callers that use this for split decisions must only do so in
    --versions / provenance context, never in brief mode.
    """
    return s not in _NON_INSTALL_GLYPHS and s not in ("Y", "unknown")


def _pkg_version_union(cells):
    """Sorted (semver-ascending) list of distinct version strings across
    all `cells` for one package row. `cells` entries are the list[str]
    produced by presence_with_version() (a scalar is tolerated and
    wrapped). Non-version glyphs are excluded via _is_version_entry.
    """
    vs = set()
    for c in cells:
        for e in (c if isinstance(c, list) else [c]):
            if _is_version_entry(e):
                vs.add(e)
    return sorted(vs, key=_pkg_version_sort_key)


def _should_split(cells):
    """A package row is rendered as one line per version (label
    `pkg=<ver>`) iff it exhibits >= 2 distinct version strings anywhere
    across its columns. Single-version and versionless packages keep the
    normal single-row rendering.
    """
    return len(_pkg_version_union(cells)) >= 2


def _versioned_rows(pkg, raw_cells, versions, queue_map):
    """Build the version-aligned emit rows for a split package.

    Returns a list of (label, [str_cell_per_column]) tuples:

      - An optional leading base row labelled `pkg` carrying the
        non-version glyphs ('N'/'B'/'F') and any GENERIC (version-less /
        full-sweep) queue glyph for columns that have no installed
        version. Emitted only when at least one such glyph exists.
      - One row per distinct version, labelled `pkg=<ver>`; a column
        shows `<ver>` where that exact version is installed, the
        version-specific queue glyph ('Q'/'R') where a Slurm job for
        that (suffix, pkg, ver) is pending/running, else blank.

    `raw_cells[ci]` is the pre-overlay list[str] cell for column
    `versions[ci]`. `queue_map` is the nested
    {(suffix, pkg): {ver_or_None: state}} dict from collect_slurm_queue().
    """
    union = _pkg_version_union(raw_cells)
    rows = []

    base_cells = []
    any_base = False
    for ci, suffix in enumerate(versions):
        cell = raw_cells[ci]
        entries = cell if isinstance(cell, list) else [cell]
        glyph = ""
        if entries and entries[0] in ("N", "B", "F"):
            glyph = entries[0]
        elif not any(_is_version_entry(e) for e in entries):
            # No installed version in this column -> a full-sweep /
            # version-less queued job (the None bucket) is the only thing
            # we can attribute here, and it belongs on the base row.
            state_by_ver = queue_map.get((suffix, pkg)) if queue_map else None
            if state_by_ver and None in state_by_ver:
                st = state_by_ver[None]
                glyph = QUEUE_GLYPH.get(st, st)
        if glyph:
            any_base = True
        base_cells.append(glyph)
    if any_base:
        rows.append((pkg, base_cells))

    for pv in union:
        vcells = []
        for ci, suffix in enumerate(versions):
            cell = raw_cells[ci]
            entries = cell if isinstance(cell, list) else [cell]
            if pv in entries:
                vcells.append(pv)
                continue
            glyph = ""
            if queue_map:
                state_by_ver = queue_map.get((suffix, pkg))
                if state_by_ver and pv in state_by_ver:
                    st = state_by_ver[pv]
                    glyph = QUEUE_GLYPH.get(st, st)
            vcells.append(glyph)
        rows.append((f"{pkg}={pv}", vcells))
    return rows


def _cell_is_installed(cell):
    """True iff `cell` represents a successful install.

    Accepts either a scalar (brief-mode `presence()` result -- 'Y',
    a numeric count string like '2', or one of '-'/'N'/'B'/'R'/'Q'), or
    a `list[str]` (versions-mode `presence_with_version()` result and
    provenance scan_cache values, where any non-{non-install-glyph} first
    entry counts as installed). Used by `count Y` to count both glyph
    and version cells uniformly. The Slurm queue glyphs 'R'/'Q' never
    count (they mark work not yet on disk).
    """
    if isinstance(cell, list):
        if not cell:
            return False
        return cell[0] not in _NON_INSTALL_GLYPHS
    return cell not in _NON_INSTALL_GLYPHS


def _apply_queue_overlay(cell, suffix, pkg, queue_map):
    """Overlay Slurm queue state onto an absent cell.

    If the on-disk `cell` is absent (scalar '-' or the list ['-']) AND a
    Slurm job for (suffix, pkg) is RUNNING / PENDING, replace it with the
    queue glyph ('R' = in process, 'Q' = queued). Any cell that already
    reflects a real on-disk state (Y / version string / count / N / B) is
    returned UNCHANGED -- the overlay never masks reality, it only fills
    holes. The list shape used by --versions mode is preserved so the
    fixed-width / markdown renderers keep working uniformly.

    `queue_map` is the {(suffix, pkg): {ver_or_None: 'R'|'PD'}} nested
    dict from collect_slurm_queue(); a None / empty map is a no-op.
    """
    if not queue_map:
        return cell
    is_absent = (cell == "-") or (isinstance(cell, list) and cell == ["-"])
    if not is_absent:
        return cell
    # queue_map value is now a {version_or_None: state} dict (see
    # collect_slurm_queue); collapse it to a single state for the
    # default (non --per-version-rows) overlay.
    state = _queue_collapse(queue_map.get((suffix, pkg)))
    if state is None:
        return cell
    glyph = QUEUE_GLYPH.get(state, state)
    return [glyph] if isinstance(cell, list) else glyph


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
    for .BUNDLED markers, 'F' for .FAILED markers) so the reasons table
    reads as a key to the main matrix.
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
                elif entry.endswith(".FAILED"):
                    kind = "F (build failed)"
                    pkg = entry[:-len(".FAILED")]
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


def _render_one_md_table(title, versions, roots, versions_mode=False,
                         queue_map=None, per_version_rows=False):
    """Emit a single Markdown table for the given versions. Caller is
    responsible for chunking when len(versions) is too wide for the
    intended renderer (glow auto-shrinks columns past ~7-8 entries on a
    standard 100-col terminal, mangling header text). With
    versions_mode=True, every cell that would have been 'Y' is replaced
    by the installed version string. When `queue_map` is provided, absent
    ('-') cells whose (version, pkg) has a RUNNING / PENDING Slurm job are
    filled with the queue glyph (R / Q).

    With per_version_rows=True (only meaningful with versions_mode), a
    package exhibiting >= 2 distinct versions is emitted as one markdown
    row per version (label `pkg=<ver>`), version-aligned across columns,
    instead of a single ' / '-joined row. See _versioned_rows."""
    print(f"## {title}\n")
    header = ["package"] + versions
    print("| " + " | ".join(header) + " |")
    print("|" + "|".join(["---"] * len(header)) + "|")
    # Pre-compute RAW (pre-overlay) cells so we can also derive `count Y`
    # without re-walking the filesystem.
    raw_rows = []
    for pkg, pres_regex, ver_regex in PKG_LIST:
        cells = [_cell_for(roots, v, pkg, pres_regex, ver_regex,
                           versions_mode)
                 for v in versions]
        raw_rows.append((pkg, cells))
    for pkg, cells in raw_rows:
        if per_version_rows and versions_mode and _should_split(cells):
            # Version-aligned rows: one `pkg=<ver>` markdown row per
            # distinct version (plus an optional base row for N/B/F /
            # generic queue), each cell already a plain string.
            for label, row_cells in _versioned_rows(pkg, cells, versions,
                                                     queue_map):
                print("| " + " | ".join([label] + row_cells) + " |")
        else:
            # Cells from _cell_for() under versions_mode are lists (one
            # entry per matched install); markdown collapses them back to
            # a single cell with the historical ' / ' join so the table
            # stays one row per package. Brief-mode scalar cells pass
            # through unchanged.
            overlaid = [_apply_queue_overlay(cells[ci], versions[ci], pkg,
                                             queue_map)
                        for ci in range(len(versions))]
            joined = [_join_cell(c) for c in overlaid]
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
        counts.append(str(sum(1 for _, cells in raw_rows
                              if _cell_is_installed(cells[ci]))))
    print("| " + " | ".join(counts) + " |")
    print()


def render_table(title, versions, roots, per_table=None, versions_mode=False,
                 queue_map=None, per_version_rows=False):
    """Markdown rendering. With per_table=N, chunk wide tables into
    sub-tables of at most N versions each (good for glow which auto-
    shrinks any table wider than the terminal). versions_mode,
    queue_map and per_version_rows are threaded through to
    _render_one_md_table.
    """
    if per_table and per_table > 0 and len(versions) > per_table:
        for i in range(0, len(versions), per_table):
            chunk = versions[i:i + per_table]
            sub_title = f"{title}  (part {i // per_table + 1} of " \
                        f"{(len(versions) + per_table - 1) // per_table}: " \
                        f"{chunk[0]} … {chunk[-1]})"
            _render_one_md_table(sub_title, chunk, roots,
                                 versions_mode=versions_mode,
                                 queue_map=queue_map,
                                 per_version_rows=per_version_rows)
    else:
        _render_one_md_table(title, versions, roots,
                             versions_mode=versions_mode,
                             queue_map=queue_map,
                             per_version_rows=per_version_rows)


def render_text_table(title, versions, roots, versions_mode=False,
                      queue_map=None, per_version_rows=False):
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

    With per_version_rows=True (only meaningful together with
    versions_mode), any package that exhibits >= 2 distinct versions is
    instead rendered version-aligned: one row per distinct version,
    labelled `pkg=<ver>`, each column showing that version only where it
    is installed (and the version-specific Slurm 'Q'/'R' where a job
    targets that exact version). See _versioned_rows.
    """
    # Pre-compute the RAW (pre-overlay) presence cells once, so we can
    # derive both `count Y` (from raw cells) and the emitted rows without
    # re-walking the filesystem. In versions_mode cells are list[str];
    # in brief mode they are scalar strings from presence().
    package_raw = []
    for pkg, pres_regex, ver_regex in PKG_LIST:
        cells = [_cell_for(roots, v, pkg, pres_regex, ver_regex,
                           versions_mode)
                 for v in versions]
        package_raw.append((pkg, cells))
    clang_cells = [clang_version(roots, v) for v in versions]
    rp_cells = [rocm_patches_presence(roots, v) for v in versions]
    count_cells = [str(sum(1 for _, cells in package_raw
                           if _cell_is_installed(cells[ci])))
                   for ci in range(len(versions))]

    def _as_list(c):
        return c if isinstance(c, list) else [c]

    # Flatten every package into concrete (label, [str_cell_per_column])
    # emit rows. Splitting is only applied in versions_mode (brief-mode
    # count cells like '2' are not version strings). Non-split packages
    # get the generic queue overlay + positional continuation rows,
    # byte-identical to the pre-per-version behavior.
    emit_rows = []
    for pkg, cells in package_raw:
        if per_version_rows and versions_mode and _should_split(cells):
            emit_rows.extend(_versioned_rows(pkg, cells, versions, queue_map))
        else:
            overlaid = [_apply_queue_overlay(cells[ci], versions[ci], pkg,
                                             queue_map)
                        for ci in range(len(versions))]
            as_lists = [_as_list(c) for c in overlaid]
            max_rows = max(len(c) for c in as_lists) if as_lists else 1
            for r in range(max_rows):
                emit_rows.append(
                    (pkg, [(cl[r] if r < len(cl) else "") for cl in as_lists]))

    # pkg_col fits the widest emitted label (now includes `pkg=<ver>`),
    # plus the fixed metadata / header labels.
    pkg_col = max([len(lbl) for lbl, _ in emit_rows]
                  + [len("package"), len("count Y"),
                     len("amdclang"), len("rocm_patches")])

    # Per-column width: max(header, every emitted cell in that column,
    # metadata cells, count cell). Unconditional lower bound of 6 matches
    # the pre-versions behavior so brief-mode output stays byte-identical.
    col_widths = []
    for ci, v in enumerate(versions):
        w = max(len(v), 6)
        for _, row_cells in emit_rows:
            w = max(w, len(row_cells[ci]))
        w = max(w, len(clang_cells[ci]), len(rp_cells[ci]),
                len(count_cells[ci]))
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
    for label, row_cells in emit_rows:
        emit_row(label, row_cells)
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


# Leading version token in a modulefile basename. pytorch writes
# `<PYTORCH_VERSION>.lua` and `<PYTORCH_VERSION>_tunableop_enabled.lua`
# (pytorch_setup.sh), and the other versioned leaves follow the same
# `<version>[.-_<variant>].lua` shape, so the leading dotted-numeric run
# is the version key. Basenames with no leading numeric (e.g.
# `default.lua`) yield no match and fall into the None (version-less)
# bucket used by the per-version-rows base row.
_LUA_VERSION_RE = re.compile(r"^(\d+(?:\.\d+)*)")


def _scan_built_by_versioned(category_dir):
    """Like _scan_built_by, but keyed by the modulefile's version.

    Returns {version_or_None: [(script, hash, dirty), ...]}, where the
    version is parsed from the leading dotted-numeric run of each
    non-backup .lua basename (`2.9.1.lua` / `2.9.1_tunableop_enabled.lua`
    -> '2.9.1'). Modulefiles whose basename has no leading numeric map to
    the `None` bucket. Entries are deduped per bucket, mirroring
    _scan_built_by's dedupe within a category.
    """
    out = {}
    try:
        names = sorted(os.listdir(category_dir))
    except OSError:
        return out
    for name in names:
        if not name.endswith(".lua") or ".bak" in name:
            continue
        base = name[:-len(".lua")]
        m = _LUA_VERSION_RE.match(base)
        ver = m.group(1) if m else None
        path = os.path.join(category_dir, name)
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        mm = _BUILT_BY_LINE_RE.search(text)
        if not mm:
            continue
        entry = (mm.group("script").strip(), mm.group("hash") or "",
                 mm.group("dirty"))
        bucket = out.setdefault(ver, [])
        if entry not in bucket:
            bucket.append(entry)
    return out


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


def collect_provenance_versioned(module_path, versions, repo=None,
                                 with_dates=False, time_too=False,
                                 roots=None):
    """Version-aware variant of collect_provenance for --per-version-rows.

    Returns {(version, pkg): {ver_or_None: [formatted_cell_str, ...]}}:
    the outer key is the (rocmplus column, package); the inner dict is
    keyed by the modulefile's own version (from _scan_built_by_versioned),
    so the renderer can emit one `pkg=<ver>` row per modulefile version.
    Modulefiles with no parseable version land in the `None` bucket
    (rendered on the package's base row). rocm_patches is stored under
    its own `None` bucket, same as collect_provenance.
    """
    out = {}
    for v in versions:
        for pkg, _pres, _ver in PKG_LIST:
            cat = _category_dir_for(module_path, v, pkg)
            if cat is None:
                continue
            byver = _scan_built_by_versioned(cat)
            formatted = {}
            for ver, entries in byver.items():
                formatted[ver] = _format_provenance_cell(
                    entries, pkg, repo=repo,
                    with_dates=with_dates, time_too=time_too)
            out[(v, pkg)] = formatted
        sdk_suffix = (_sdk_suffix_for_rocmplus(roots, v)
                      if roots else v)
        if sdk_suffix is None:
            continue
        entries = _scan_built_by_in_file(
            os.path.join(module_path, "base", "rocm",
                         sdk_suffix + ".lua"),
            script_filter=("rocm_patches.sh", "rocm_patches"))
        if entries:
            out[(v, "rocm_patches")] = {None: _format_provenance_cell(
                entries, "rocm_patches", repo=repo,
                with_dates=with_dates, time_too=time_too)}
    return out


def _prov_version_union(pvcache, versions, pkg):
    """Sorted (semver-ascending) list of the distinct non-None version
    keys for `pkg` across all `versions` columns in a versioned
    provenance cache (from collect_provenance_versioned)."""
    vs = set()
    for v in versions:
        d = pvcache.get((v, pkg))
        if d:
            vs.update(k for k in d if k is not None)
    return sorted(vs, key=_pkg_version_sort_key)


def _prov_flat_cell(pvcache, v, pkg):
    """Flatten all version buckets of a versioned provenance cell into a
    single list[str] (dedup, version-sorted with the None bucket last).
    Used for packages that are NOT split (< 2 distinct versions) so they
    render as one row, matching the non-versioned provenance output."""
    d = pvcache.get((v, pkg))
    if not d:
        return ["-"]
    ordered = sorted(d.keys(),
                     key=lambda k: (k is None,
                                    _pkg_version_sort_key(k) if k else []))
    out = []
    for ver in ordered:
        for s in d[ver]:
            if s not in out:
                out.append(s)
    return out or ["-"]


def _prov_versioned_rows(pvcache, versions, pkg):
    """Build version-aligned (label, [str_cell_per_column]) rows for a
    split package in the provenance matrix. Optional leading base row
    `pkg` carries the None-bucket entries (modulefiles with no parseable
    version); then one `pkg=<ver>` row per distinct version, each column
    showing that version's `<payload> <C|D>` provenance or blank."""
    union = _prov_version_union(pvcache, versions, pkg)
    rows = []
    base_cells = []
    any_base = False
    for v in versions:
        d = pvcache.get((v, pkg)) or {}
        cell = _join_cell(d[None]) if d.get(None) else ""
        if cell:
            any_base = True
        base_cells.append(cell)
    if any_base:
        rows.append((pkg, base_cells))
    for pv in union:
        cells = []
        for v in versions:
            d = pvcache.get((v, pkg)) or {}
            cells.append(_join_cell(d[pv]) if d.get(pv) else "")
        rows.append((f"{pkg}={pv}", cells))
    return rows


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


def render_provenance_text(title, versions, module_path, scan_cache,
                           per_version_rows=False, pvcache=None):
    """Fixed-width plain-text rendering of the provenance matrix.

    Cells in scan_cache are `list[str]` (one entry per matching
    `Built by:` writer in the modulefile). Multi-install cells spill
    onto continuation rows below the package row: the package label is
    repeated, the multi-install column shows the next entry, and every
    other column is blank on that line. Column widths fit the widest
    install entry per column.

    With per_version_rows=True (pvcache from collect_provenance_versioned)
    a package with >= 2 distinct modulefile versions is instead rendered
    version-aligned: one `pkg=<ver>` row per version. See
    _prov_versioned_rows.
    """
    print(f"=== {title} ===")

    def _as_list(c):
        return c if isinstance(c, list) else [c]

    # Flatten into concrete (label, [str_cell_per_column]) emit rows.
    emit_rows = []
    for pkg, _pres, _ver in PKG_LIST:
        if per_version_rows and _prov_version_union(pvcache, versions, pkg) \
                and len(_prov_version_union(pvcache, versions, pkg)) >= 2:
            emit_rows.extend(_prov_versioned_rows(pvcache, versions, pkg))
        else:
            if per_version_rows:
                cells = [_prov_flat_cell(pvcache, v, pkg) for v in versions]
            else:
                cells = [_provenance_cell(module_path, v, pkg, scan_cache)
                         for v in versions]
            as_lists = [_as_list(c) for c in cells]
            max_rows = max(len(c) for c in as_lists) if as_lists else 1
            for r in range(max_rows):
                emit_rows.append(
                    (pkg, [(cl[r] if r < len(cl) else "") for cl in as_lists]))
    if per_version_rows:
        rp_lists = [_as_list(_prov_flat_cell(pvcache, v, "rocm_patches"))
                    for v in versions]
    else:
        rp_lists = [_as_list(_provenance_cell(module_path, v, "rocm_patches",
                                              scan_cache))
                    for v in versions]
    rp_max = max((len(c) for c in rp_lists), default=1)
    for r in range(rp_max):
        emit_rows.append(("rocm_patches",
                          [(cl[r] if r < len(cl) else "") for cl in rp_lists]))

    pkg_col = max([len(lbl) for lbl, _ in emit_rows]
                  + [len("package"), len("rocm_patches")])
    col_widths = []
    for ci, v in enumerate(versions):
        w = max(len(v), 6)
        for _, row_cells in emit_rows:
            w = max(w, len(row_cells[ci]))
        col_widths.append(w)
    sep = "  "

    def emit(left, cells):
        parts = [left.ljust(pkg_col)]
        for c, w in zip(cells, col_widths):
            parts.append(str(c).ljust(w))
        print(sep.join(parts).rstrip())

    emit("package", list(versions))
    emit("-" * pkg_col, ["-" * w for w in col_widths])
    for label, row_cells in emit_rows:
        emit(label, row_cells)
    print()


def _render_provenance_md_one(title, versions, module_path, scan_cache,
                              per_version_rows=False, pvcache=None):
    print(f"## {title}\n")
    header = ["package"] + list(versions)
    print("| " + " | ".join(header) + " |")
    print("|" + "|".join(["---"] * len(header)) + "|")
    # scan_cache values are list[str] (one entry per matching Built-by
    # writer); markdown collapses them back to a single cell with the
    # historical ' / ' join so the table stays one row per package.
    # Under per_version_rows a split package emits one `pkg=<ver>` row
    # per distinct modulefile version instead.
    for pkg, _pres, _ver in PKG_LIST:
        if per_version_rows and \
                len(_prov_version_union(pvcache, versions, pkg)) >= 2:
            for label, row_cells in _prov_versioned_rows(pvcache, versions,
                                                         pkg):
                print("| " + " | ".join([label] + row_cells) + " |")
            continue
        if per_version_rows:
            cells = [_join_cell(_prov_flat_cell(pvcache, v, pkg))
                     for v in versions]
        else:
            cells = [_join_cell(_provenance_cell(module_path, v, pkg,
                                                 scan_cache))
                     for v in versions]
        print("| " + " | ".join([pkg] + cells) + " |")
    # rocm_patches metadata row: same cache as the PKG_LIST rows; the
    # cache is populated from base/rocm/<v>.lua's `Built by:
    # rocm_patches.sh@...` whatis line (see collect_provenance).
    if per_version_rows:
        rp_cells = [_join_cell(_prov_flat_cell(pvcache, v, "rocm_patches"))
                    for v in versions]
    else:
        rp_cells = [_join_cell(_provenance_cell(module_path, v, "rocm_patches",
                                                scan_cache))
                    for v in versions]
    print("| " + " | ".join(["**rocm_patches**"] + rp_cells) + " |")
    print()


def render_provenance_md(title, versions, module_path, scan_cache,
                         per_table=None, per_version_rows=False, pvcache=None):
    if per_table and per_table > 0 and len(versions) > per_table:
        for i in range(0, len(versions), per_table):
            chunk = versions[i:i + per_table]
            sub_title = (f"{title}  (part {i // per_table + 1} of "
                         f"{(len(versions) + per_table - 1) // per_table}: "
                         f"{chunk[0]} … {chunk[-1]})")
            _render_provenance_md_one(sub_title, chunk, module_path,
                                      scan_cache,
                                      per_version_rows=per_version_rows,
                                      pvcache=pvcache)
    else:
        _render_provenance_md_one(title, versions, module_path, scan_cache,
                                  per_version_rows=per_version_rows,
                                  pvcache=pvcache)


# ── Slurm queue overlay (--slurm) ────────────────────────────────────
#
# Overlays the rocm-plus installs currently RUNNING ("in process") or
# PENDING ("queued") in the Slurm queues onto the presence matrix. The
# submitter (bare_system/run_rocmplus_install_sweep.sh) names each job
# `rocmplus_<label>`, where <label> is exactly the inventory column
# suffix (7.2.0, afar-23.2.1-7.13.0, cray-7.2.3, ...). The per-job
# package whitelist + target tree live in the sbatch `--export` list,
# which Slurm records verbatim in the job's SubmitLine -- retrievable
# for PENDING jobs too via `sacct --format=SubmitLine`. We parse
# PACKAGES_LIST (exact per-package intent; empty = full sweep),
# TOP_INSTALL_PATH / SITE (to match the inventory --roots), and
# QUICK_INSTALLS (to subtract the long-pole gate when PACKAGES_LIST is
# empty).

# --site preset -> TOP_INSTALL_PATH, mirroring the resolution table in
# run_rocmplus_install_sweep.sh (search "--site preset application").
_SITE_INSTALL_PRESETS = {
    "opt":         "/opt",
    "nfsapps":     "/nfsapps/opt",
    "shared-apps": "/shared/apps/ubuntu/opt",
    "shareddata":  "/shareddata/opt",
}


def _site_to_install_path(site):
    """Resolve a --site value (named preset OR absolute PREFIX path) to
    the TOP_INSTALL_PATH it implies, matching the sweep submitter. Named
    presets map via _SITE_INSTALL_PRESETS; an absolute path PREFIX maps
    to PREFIX/opt. Returns None for anything unrecognized."""
    if not site:
        return None
    if site in _SITE_INSTALL_PRESETS:
        return _SITE_INSTALL_PRESETS[site]
    if site.startswith("/"):
        return site.rstrip("/") + "/opt"
    return None


def _export_var(submitline, key):
    """Extract a single `KEY=VALUE` from an sbatch --export list embedded
    in `submitline`. Values run to the next comma (paths / scalars never
    contain commas here). Returns '' if the key is present but empty,
    None if absent."""
    m = re.search(r"(?:^|[,=])" + re.escape(key) + r"=([^,]*)", submitline)
    return m.group(1) if m else None


def _parse_packages_list(submitline):
    """Extract the PACKAGES_LIST value from a SubmitLine.

    PACKAGES_LIST is always the LAST --export var the sweep appends (see
    run_rocmplus_install_sweep.sh), so its value -- which may contain
    spaces (e.g. `jax tensorflow pytorch`, `pytorch=2.8.0 2.7.1`) -- runs
    from `PACKAGES_LIST=` up to the next sbatch flag (` --dependency` /
    ` --<flag>`) or, when there is no trailing flag, up to the batch
    script path (`.../run_rocmplus_install.sbatch`). Returns the raw
    whitespace-joined value ('' for a full sweep), or None if the token
    is absent entirely.
    """
    if "PACKAGES_LIST=" not in submitline:
        return None
    tail = submitline.split("PACKAGES_LIST=", 1)[1]
    # Stop at the next sbatch flag (handles the --dependency case).
    tail = tail.split(" --", 1)[0]
    # Strip a trailing batch-script path (first-wave jobs have no
    # --dependency, so the script path directly follows the value).
    tail = re.sub(r"\s+\S*run_rocmplus_install\.sbatch\s*$", "", tail)
    return tail.strip()


def _run_cmd(cmd):
    """Run `cmd`, return stdout (str) or None on any failure / missing
    binary / timeout. Mirrors _probe_clang's defensive posture so a host
    without Slurm degrades to "no overlay" instead of crashing."""
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    return out.stdout or ""


def collect_slurm_queue(roots):
    """Return {(suffix, pkg): {ver_or_None: 'R'|'PD'}} for every rocm-plus
    install job that is RUNNING or PENDING in Slurm and targets one of
    `roots`.

    The inner dict is keyed by the TARGET VERSION recovered from the
    PACKAGES_LIST token (`pytorch=2.8.0` -> '2.8.0'); a bare token
    (`pytorch`) or a full-sweep job (empty PACKAGES_LIST) maps to the
    `None` (version-less / generic) bucket. This lets --per-version-rows
    place 'Q'/'R' on the exact `pkg=<ver>` row; the default overlay path
    collapses the inner dict via _queue_collapse().

    - Job discovery: `squeue` for RUNNING+PENDING, filtered to names
      matching `rocmplus_*` (all users). The job label after the
      `rocmplus_` prefix is the inventory column suffix.
    - Per-job detail: batched `sacct -X ... --format=JobIDRaw,SubmitLine`
      gives the exact submitted command; we parse PACKAGES_LIST (package
      intent), TOP_INSTALL_PATH / SITE (tree filter), QUICK_INSTALLS
      (long-pole gate).
    - Tree filter: only jobs whose effective TOP_INSTALL_PATH resolves to
      one of `roots` contribute cells, so the overlay matches the tree
      being surveyed. Jobs with no resolvable install path are skipped.
    - Package expansion: empty PACKAGES_LIST -> all PKG_LIST rows (minus
      QUICK_INSTALLS_PKGS when QUICK_INSTALLS=1); otherwise the leading
      package name of each token (`name`, `name=VER`, `name=VER:ov=...`).
    - State precedence: RUNNING ('R') wins over PENDING ('PD') when a
      version is represented by jobs in both states.

    Returns {} on any Slurm-tooling failure (graceful no-op).
    """
    squeue_out = _run_cmd(["squeue", "-h", "-o", "%i|%j|%t",
                           "--states=PENDING,RUNNING"])
    if squeue_out is None:
        return {}
    # jobid -> (suffix, state) for rocmplus_* jobs.
    jobs = {}
    for line in squeue_out.splitlines():
        parts = line.split("|")
        if len(parts) < 3:
            continue
        jobid, name, state = parts[0].strip(), parts[1].strip(), parts[2].strip()
        if not name.startswith("rocmplus_"):
            continue
        suffix = name[len("rocmplus_"):]
        jobs[jobid] = (suffix, state)
    if not jobs:
        return {}

    # Batched SubmitLine lookup (SubmitLine is last so a stray '|' in the
    # command -- unlikely here -- is preserved by split with maxsplit=1).
    sacct_out = _run_cmd(["sacct", "-X", "-j", ",".join(jobs.keys()),
                          "--noheader", "--parsable2",
                          "--format=JobIDRaw,SubmitLine"])
    submitlines = {}
    if sacct_out:
        for line in sacct_out.splitlines():
            if "|" not in line:
                continue
            jid, sline = line.split("|", 1)
            submitlines[jid.strip()] = sline

    all_pkg_names = [p for p, _, _ in PKG_LIST]
    norm_roots = {os.path.normpath(r) for r in roots}

    overlay = {}
    for jobid, (suffix, state) in jobs.items():
        sline = submitlines.get(jobid)
        if sline is None:
            continue
        # Tree filter: effective install path must be one of `roots`.
        install_path = _export_var(sline, "TOP_INSTALL_PATH")
        if not install_path:
            install_path = _site_to_install_path(_export_var(sline, "SITE"))
        if not install_path or os.path.normpath(install_path) not in norm_roots:
            continue
        # Effective package set as (pkg, version_or_None) pairs. For a
        # full sweep the version is unknown -> None (generic bucket);
        # for explicit tokens `name[=VER[:ov=...]]` we keep VER so the
        # per-version overlay can target the exact `pkg=<ver>` row.
        pkgs_raw = _parse_packages_list(sline)
        if not pkgs_raw:  # None or '' -> full sweep
            names = set(all_pkg_names)
            if _export_var(sline, "QUICK_INSTALLS") == "1":
                names -= QUICK_INSTALLS_PKGS
            pkg_ver_pairs = [(n, None) for n in names]
        else:
            pkg_ver_pairs = []
            for tok in pkgs_raw.split():
                name, _, rest = tok.partition("=")
                ver = rest.split(":", 1)[0] if rest else ""
                pkg_ver_pairs.append((name, ver or None))
        for pkg, ver in pkg_ver_pairs:
            if pkg not in all_pkg_names:
                continue  # bare version tokens / non-tracked names
            bucket = overlay.setdefault((suffix, pkg), {})
            prev = bucket.get(ver)
            if prev is None or _QUEUE_RANK.get(state, 0) > _QUEUE_RANK.get(prev, 0):
                bucket[ver] = state
    return overlay


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
             "Versionless dirs (hipifly, tau, pdt, hip-python) keep 'Y'. "
             "ftorch is versioned by the bound pytorch release "
             "(ftorch-v<PYTV>) so its cell shows the bound pytorch "
             "version too. tensorflow is versioned by the built TF "
             "release (tensorflow-v<TF_VER>); legacy unversioned "
             "tensorflow/ dirs still on disk render as 'Y'. When two "
             "or more versions of one "
             "package coexist in the same rocmplus tree, --text spills "
             "the row onto continuation lines (label repeated, blanks "
             "in other columns), while markdown joins them with ' / ' "
             "in semver-ascending order ('2.7.1 / 2.9.1'). 'N'/'B'/'-' "
             "glyphs and the amdclang / count Y rows are unchanged. See "
             "--per-version-rows for a one-row-per-version layout instead.")
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
    ap.add_argument("--slurm", action="store_true",
        help="overlay in-flight installs from the Slurm queues onto the "
             "matrix. Scans ALL 'rocmplus_*' jobs (every user) via squeue "
             "for RUNNING / PENDING state, then reads each job's exact "
             "submit command (sacct --format=SubmitLine) to recover the "
             "per-package intent (PACKAGES_LIST; empty = full sweep, minus "
             "the --quick-installs long-poles) and the target tree "
             "(TOP_INSTALL_PATH / --site, matched against --roots). Cells "
             "that are absent ('-') on disk are filled with 'R' (install "
             "in process / Slurm RUNNING) or 'Q' (install queued / Slurm "
             "PENDING); real installs and N/B markers are never "
             "overwritten, and R/Q are not counted in 'count Y'. No-op "
             "(no overlay) if squeue/sacct are unavailable. Ignored under "
             "--install-provenance.")
    ap.add_argument("--per-version-rows", action="store_true",
        help="render each package that has >= 2 distinct versions as ONE "
             "ROW PER VERSION (label 'pkg=<ver>'), version-aligned across "
             "columns, instead of the default single row with continuation "
             "lines / ' / '-joins. Each column shows that version only "
             "where it is installed; with --slurm, the 'Q'/'R' queue glyph "
             "is placed on the exact 'pkg=<ver>' row when the job targets "
             "that version (a full-sweep job with no version token, and any "
             "N/B/F marker, appears on a leading base 'pkg' row). Only "
             "meaningful with --versions (presence matrix) or "
             "--install-provenance; single-version and versionless packages "
             "are unaffected.")
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
        # Version-aware cache only needed for the per-version-rows layout.
        pvcache = (collect_provenance_versioned(
                       module_path, all_versions,
                       repo=git_repo if args.with_dates else None,
                       with_dates=args.with_dates,
                       time_too=args.provenance_time,
                       roots=args.roots)
                   if args.per_version_rows else None)
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
                                       module_path, scan_cache,
                                       per_version_rows=args.per_version_rows,
                                       pvcache=pvcache)
            if vrc:
                render_provenance_text("ROCm RC trees (therock + afar)",
                                       vrc, module_path, scan_cache,
                                       per_version_rows=args.per_version_rows,
                                       pvcache=pvcache)
            if v6:
                render_provenance_text("ROCm 6.x.x", v6,
                                       module_path, scan_cache,
                                       per_version_rows=args.per_version_rows,
                                       pvcache=pvcache)
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
                                     per_table=prov_per_table,
                                     per_version_rows=args.per_version_rows,
                                     pvcache=pvcache)
            if vrc:
                render_provenance_md("ROCm RC trees (therock + afar)", vrc,
                                     module_path, scan_cache,
                                     per_table=prov_per_table,
                                     per_version_rows=args.per_version_rows,
                                     pvcache=pvcache)
            if v6:
                render_provenance_md("ROCm 6.x.x", v6, module_path,
                                     scan_cache,
                                     per_table=prov_per_table,
                                     per_version_rows=args.per_version_rows,
                                     pvcache=pvcache)
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
    pvr_note_text = (
        "  --per-version-rows: packages with >= 2 distinct versions are "
        "split into one 'pkg=<ver>' row each, version-aligned across columns."
        if (args.per_version_rows and args.versions) else "")
    pvr_note_md = (
        " With `--per-version-rows`, packages with >= 2 distinct versions are "
        "split into one **`pkg=<ver>`** row each, version-aligned across "
        "columns." if (args.per_version_rows and args.versions) else "")
    versions_note_text += pvr_note_text
    versions_note_md += pvr_note_md

    # Slurm queue overlay: {(suffix, pkg): 'R'|'PD'} for in-flight installs
    # that target one of --roots. Empty (no overlay) unless --slurm was
    # passed AND squeue/sacct produced matching jobs. Legend lines are
    # only emitted when there is something to explain.
    queue_map = collect_slurm_queue(args.roots) if args.slurm else {}
    queue_note_text = (
        "  R = install IN PROCESS (Slurm RUNNING),  "
        "Q = install QUEUED (Slurm PENDING); both fill only '-' cells "
        "and are not counted in 'count Y'." if queue_map else "")
    queue_note_md = (
        " **R** = install IN PROCESS (Slurm RUNNING), **Q** = install "
        "QUEUED (Slurm PENDING); both fill only **-** cells and are not "
        "counted in **count Y**." if queue_map else "")

    if args.text:
        print(f"Sources: {', '.join(args.roots)}")
        print(f"Generated: {datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')}")
        print("Legend: Y = installed,  "
              "N = NOT POSSIBLE to build on this SDK (see <pkg>.SKIPPED marker),  "
              "B = BUNDLED in the ROCm SDK (see <pkg>.BUNDLED marker),  "
              "F = build ATTEMPTED but FAILED (see <pkg>.FAILED marker; "
              "partial install auto-removed),  "
              "- = absent / missing (no install, no marker)."
              + versions_note_text + queue_note_text)
        print()
        if v7:  render_text_table("ROCm 7.x.x", v7, args.roots,
                                  versions_mode=args.versions,
                                  queue_map=queue_map,
                                  per_version_rows=args.per_version_rows)
        if vrc: render_text_table("ROCm RC trees (therock + afar)", vrc,
                                  args.roots, versions_mode=args.versions,
                                  queue_map=queue_map,
                                  per_version_rows=args.per_version_rows)
        if v6:  render_text_table("ROCm 6.x.x", v6, args.roots,
                                  versions_mode=args.versions,
                                  queue_map=queue_map,
                                  per_version_rows=args.per_version_rows)
    else:
        print(f"Sources: {', '.join('`' + r + '`' for r in args.roots)}")
        print(f"Generated: "
              f"{datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')}\n")
        print("Legend: **Y** = installed, "
              "**N** = NOT POSSIBLE to build on this SDK "
              "(see `<pkg>.SKIPPED` marker), "
              "**B** = BUNDLED in the ROCm SDK "
              "(see `<pkg>.BUNDLED` marker), "
              "**F** = build ATTEMPTED but FAILED "
              "(see `<pkg>.FAILED` marker; partial install auto-removed), "
              "**-** = absent / missing (no install, no marker)."
              + versions_note_md + queue_note_md + "\n")
        if v7:  render_table("ROCm 7.x.x", v7,
                             args.roots, per_table=md_per_table,
                             versions_mode=args.versions, queue_map=queue_map,
                             per_version_rows=args.per_version_rows)
        if vrc: render_table("ROCm RC trees (therock + afar)", vrc,
                             args.roots, per_table=md_per_table,
                             versions_mode=args.versions, queue_map=queue_map,
                             per_version_rows=args.per_version_rows)
        if v6:  render_table("ROCm 6.x.x", v6,
                             args.roots, per_table=md_per_table,
                             versions_mode=args.versions, queue_map=queue_map,
                             per_version_rows=args.per_version_rows)

    if args.reasons:
        reasons = collect_marker_reasons(args.roots, all_versions)
        render_reasons(reasons, text=args.text)

    return 0


if __name__ == "__main__":
    sys.exit(main())
