# Clone

Perl XS module for recursively deep-copying data structures. The core logic is in C (Clone.xs) with a thin Perl wrapper (Clone.pm).

## Build & Test

```bash
perl Makefile.PL && make && make test
```

Threads tests (`t/16-threads-shared.t`, `t/17-threads-classdbi.t`) require a Perl built with threads support. On macOS, system Perl (`/usr/bin/perl`) has threads; perlbrew installs typically do not.

Some tests need optional deps: `Math::BigInt::GMP`, `DBI`, `DBD::SQLite`, `Class::DBI`. These are listed as recommends in `.github/cpanfile.test`.

## Architecture

```
Clone.xs          # C implementation (~580 lines) — all cloning logic
Clone.pm          # Perl wrapper, exports clone(), loads XS via XSLoader
ppport.h          # Perl portability header (v3.68)
Makefile.PL       # ExtUtils::MakeMaker build config (-O3 optimization)
t/                # 20 test files (00-cow.t through 19-dualvar.t)
.github/workflows/test.yml  # CI: multi-version, multi-OS matrix
```

### Clone.xs internals

- **`sv_clone()`** — main entry point, dispatches by SV type (HV, AV, RV, PVMG, etc.)
- **`hv_clone()` / `av_clone()`** — recursive hash/array cloning
- **`rv_clone()`** — reference cloning with circular-ref detection via `hseen` HV
- **Circular refs** — tracked in a seen-hash (`hseen`); already-cloned SVs return cached copy
- **Deep recursion** — switches to iterative mode (`av_clone_iterative`) after `MAX_DEPTH` (32000)
- **Weakrefs** — deferred weakening: builds full clone graph first, then weakens at the end

### Magic handling (key gotchas)

- **PERL_MAGIC_ext (`'~'`)**: dual behavior — skip for DBI handles (no `svt_dup`), clone for GMP objects (has `svt_dup`)
- **threads::shared**: strip tie magic (`'P'`) and shared_scalar magic (`'n'`/`'N'`) during clone
- **PVLV (defelem)**: non-cloneable, just `SvREFCNT_inc` — except for shared tiedelem proxies which need special handling

## Conventions

- **MANIFEST**: always add new test files to `MANIFEST`
- **Test naming**: `t/NN-descriptive-name.t` with sequential numbering
- **C style**: C89 compatible (no `//` comments, no C99 declarations after statements)
- **Compilation**: builds with `-O3`; must compile cleanly with no warnings

## Git Workflow

- **Fork**: `atoomic/Clone` (origin), **upstream**: `garu/Clone`
- **Main branch**: `master`
- **Feature branches**: `koan.atoomic/*` — push freely, create draft PRs
- **CI**: GitHub Actions — tests on Perl 5.8 through latest + devel, Linux/Windows/distro matrix
