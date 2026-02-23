# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-02-22

### Added

- Initial public release of `bint`, an arbitrary-precision signed integer library for Luau using signed base-`2^24` limbs.
- High-level `bint` API with constructors (`from_int`, `from_string`, `from_limbs`, `zero`, `one`, `new`, and callable `bint(v)`), string/byte conversions (`tostring`, `tonumber`, `tole`, `tobe`, `fromle`, `frombe`), and non-mutating instance method aliases for ergonomic Luau / `roblox-ts` use.
- Low-level `core` API for canonical `Bint` values, including comparison, sign helpers, arithmetic, floor and truncated division, exponentiation, integer square root, and limb/bit shift operations (with arithmetic right-shift semantics).
- Operator/metamethod support for integer arithmetic and comparisons (`+`, `-`, `*`, `//`, `%`, `^`, unary `-`, `==`, `<`, `<=`), plus `__tostring` and `__len` (decimal digit count).
- Size-based algorithm selection for multiplication (schoolbook, Karatsuba, Toom-3), division (Knuth, Burnikel-Ziegler), and integer square root (Newton/Karatsuba paths).
- TypeScript declarations in `src/index.d.ts`.
- Comprehensive automated test coverage in `tests/init.spec.luau` using the local `lune` spec runner.
