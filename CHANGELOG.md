# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.4.0] - 2026-03-05

### Added

- `tuning` export for runtime algorithm dispatch control:
  - `tuning.get_thresholds()` — returns the current `BintThresholds` configuration table.
  - `tuning.set_thresholds(config)` — atomically updates all thresholds; rejects missing keys, NaN, and out-of-range values.
  - `tuning.reset_thresholds()` — restores built-in defaults.
  - Configurable fields: `mul_split_thr`, `karatsuba_thr`, `toom3_thr`, `sqrt_kar_thr`, `burnikel_dispatch_thr`, `burnikel_leaf_thr`, `burnikel_off`.
- `internals` export (marked `@internal`) exposing `internals.algorithms` and `internals.helpers` for direct low-level access. Replaces the previous top-level `algorithms` export.
- `internals.algorithms.mul_schoolbook_split` and `internals.algorithms.mul_schoolbook_unsplit` — individual schoolbook paths for benchmarking the split/unsplit crossover.
- Comparison benchmark (`bench/cmp.luau`) measuring bint against helloGMP and AptInt across add, sub, mul, div, pow, isqrt, parse, format, endian, and sci operations.

### Changed

- **Breaking (previously unstable):** Top-level `algorithms` export moved to `internals.algorithms`. The `algorithms` table was already documented as unstable/internal; it now lives under `internals.algorithms` alongside `internals.helpers`.
- `algorithms.mul_basecase` renamed to `internals.algorithms.mul_schoolbook` (dispatch-aware schoolbook entry point). The individual split/unsplit variants are exposed alongside it.
- Multiplication schoolbook path split into an exact-safe unsplit variant and an always-safe split variant, dispatched by a new `mul_split_thr` threshold (default: 33 limbs). This avoids unnecessary carry-splitting overhead for small operands while preserving correctness at all sizes.
- Dispatch thresholds retuned relative to v0.3.0 for better practical throughput:
  - `toom3_thr`: 124 → 145 (prefer Karatsuba longer before entering Toom-3)
  - `burnikel_dispatch_thr`: 232 → 98 (enter Burnikel-Ziegler earlier for large divisions)
  - `burnikel_off`: 40 → 59 (tighter numerator-denominator offset gate)
- Docstrings moved from metamethods (`__add`, `__sub`, …) to instance method assignments (`add`, `sub`, …); IDEs and doc generators now surface operator documentation correctly.
- `BintInternals`, `BintHelpers`, and `BintAlgorithms` TypeScript interfaces marked `@internal`.

### Fixed

- `Bint` is now exported as a metatable-backed type (`typeof(setmetatable(…))`), so Luau strict-mode operator overloads (`+`, `-`, `*`, etc.) resolve correctly. Previously, `Bint` was a plain data-table type and expressions like `a + b` failed with "no corresponding overload for `__add`".

## [0.3.0] - 2026-02-25

### Added

- `bint.to_sci(a)` returns a lossy scientific-notation decomposition `(coefficient, exponent)` where `1 ≤ |coefficient| < 10`. O(1), no allocation. Available as both a module function and an instance method.

### Changed

- **Breaking:** Conversion functions renamed to a consistent `to_*`/`from_*` convention:
  - `tostring` → `to_string`
  - `tonumber` → `to_number`
  - `tole` → `to_le`
  - `tobe` → `to_be`
  - `fromle` → `from_le`
  - `frombe` → `from_be`
- `to_number`, `to_le`, and `to_be` are now available as instance methods (previously only `tostring` had an instance alias).
- TypeScript declarations updated to reflect all renames and additions.

### Fixed

- Burnikel-Ziegler 3n/2n else-branch remainder formula used `A1` instead of `B1`, producing incorrect remainders for certain large divisions.
- Burnikel-Ziegler 3n/2n if-branch quotient was not stripped before multiplication, causing spurious leading-zero limbs in the correction product.
- Burnikel-Ziegler 2n/1n now handles short/equal-length inputs that the outer driver can produce when leading blocks are zero, instead of falling through into an invalid recursive split.
- Burnikel-Ziegler outer driver block count now uses exact bit-length rather than limb-count ceiling, preventing off-by-one block splits on certain operand sizes.

## [0.2.2] - 2026-02-24

### Changed

- Internal limb add/sub helpers were refactored to use explicit mutating helpers (`add_limbs_mut` / `sub_limbs_mut`) instead of `in_place` flags, simplifying call sites and making mutation intent clearer.
- Limb addition/subtraction hot paths now use numeric split loops for carry/borrow handling, improving performance without changing public API behavior.

## [0.2.1] - 2026-02-24

### Changed

- Error-path argument checks in `bint` constructors/converters and division wrappers now use explicit `error(..., 2)` guards instead of `assert(...)`, preserving caller-facing stack locations and consistent messages.
- Documentation now clarifies that direct `algorithms.*` wrappers force the named algorithm at the top-level entry point, while recursive subproblems may still dispatch/fallback internally.

### Fixed

- Schoolbook/basecase multiplication now uses a split-accumulator inner loop to avoid Luau double-precision integer loss in worst-case columns (for example `(BASE^n - 1)^2`), which also fixes downstream Karatsuba and Toom-3 paths that recurse into basecase multiplication.
- Knuth division now handles the D3 quotient-estimate saturation/equality-path edge case safely when the tentative estimate reaches the limb base boundary.

## [0.2.0] - 2026-02-23

### Added

- `algorithms` table exposing direct algorithm entry points that bypass automatic threshold dispatch: `mul_basecase`, `mul_karatsuba`, `mul_toom3`, `div_knuth`, `div_burnikel`, `sqrt_newton`, `sqrt_karatsuba`. Useful for benchmarking crossover points and testing algorithm correctness independently.
- Tag-based test filtering in the spec runner (`--tag`, `--exclude-tag`, `--tags`, `--exclude-tags`, `--tag-mode`, `--list-tags`). Tags inherit through nested `describe` blocks.
- `describe.tags()` and `it.tags()` sugar for tagging suites and tests inline.
- Test suites tagged into `fast`, `full`, and `stress` tiers for selective execution.
- New "algorithm-direct" test suite exercising every algorithm wrapper at sizes on both sides of dispatch thresholds.
- New "stress" test suite with dense safe-range oracles and large-limb differential checks.

### Removed

- `--grep` CLI flag from the spec runner. Tag-based filtering supersedes it.

### Fixed

- Burnikel-Ziegler division now correctly unshifts the remainder by the word-alignment shift applied during normalization. Previously the remainder could be returned with extra trailing limbs.

## [0.1.0] - 2026-02-22

### Added

- Initial public release of `bint`, an arbitrary-precision signed integer library for Luau using signed base-`2^24` limbs.
- High-level `bint` API with constructors (`from_int`, `from_string`, `from_limbs`, `zero`, `one`, `new`, and callable `bint(v)`), string/byte conversions (`tostring`, `tonumber`, `tole`, `tobe`, `fromle`, `frombe`), and non-mutating instance method aliases for ergonomic Luau / `roblox-ts` use.
- Low-level `core` API for canonical `Bint` values, including comparison, sign helpers, arithmetic, floor and truncated division, exponentiation, integer square root, and limb/bit shift operations (with arithmetic right-shift semantics).
- Operator/metamethod support for integer arithmetic and comparisons (`+`, `-`, `*`, `//`, `%`, `^`, unary `-`, `==`, `<`, `<=`), plus `__tostring` and `__len` (decimal digit count).
- Size-based algorithm selection for multiplication (schoolbook, Karatsuba, Toom-3), division (Knuth, Burnikel-Ziegler), and integer square root (Newton/Karatsuba paths).
- TypeScript declarations in `src/index.d.ts`.
- Comprehensive automated test coverage in `tests/init.spec.luau` using the local `lune` spec runner.
