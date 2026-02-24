# bint

Arbitrary-precision signed integer library for Luau.

`bint` stores integers as little-endian base-`2^24` limbs, so values can grow without fixed-width overflow. It supports idiomatic operators (`+`, `-`, `*`, `//`, `%`, `^`, comparisons), plus a lower-level `core` API with mutating and non-mutating functions.

Latest release: `0.2.0`.

## Features

- Arbitrary-precision signed integers.
- Constructors from Lua numbers, strings (base 2-36), and raw limb arrays.
- Conversion to/from strings and byte strings (little/big endian).
- Floor and truncated division APIs.
- Integer exponentiation and integer square root.
- Multiple multiplication/division algorithms chosen by operand size.
- Luau + TypeScript declaration file support (`src/index.d.ts`).

## Usage

```luau
local mod = require(path.to.bint)
local bint = mod.bint
local core = mod.core

local a = bint("123456789012345678901234567890")
local b = bint.from_int(42)

local sum = a + b
local prod = a * b
local q, r = core.divmod(a, b) -- floor division

print(sum:tostring()) -- method form
print(bint.tostring(prod)) -- function form
print(q, r)
```

`bint(v)` is an alias for `bint.new(v)`.

For `roblox-ts` / TypeScript users, the standard non-mutating arithmetic/comparison operations are also available as instance methods (for example `a:add(b)`, `a:mul(b)`, `a:divmod(b)`), which avoids relying on Luau operator metamethod syntax in typed code. Mutating operations remain on `core`.

## API summary

### Constructors

- `bint.from_int(n: number): Bint` (converts the current Luau `number` value)
- `bint.from_string(s: string, base?: number): Bint`
- `bint.from_limbs(limbs: {number}, signum?: -1 | 0 | 1): Bint`
- `bint.zero(): Bint`
- `bint.one(): Bint`
- `bint.new(v: Bint | number | string): Bint`
- `bint(v)` (callable module alias)

### Conversion helpers

- `bint.tostring(a: Bint, base?: number): string`
- `bint.tonumber(a: Bint): number`
- `bint.tole(a: Bint, trim?: boolean): string`
- `bint.tobe(a: Bint, trim?: boolean): string`
- `bint.fromle(s: string): Bint`
- `bint.frombe(s: string): Bint`

### `core` operations

`core` provides low-level signed arithmetic on canonical `Bint` values. No input coercion or validation is performed — arguments must already be `Bint` instances. Reach for `core` when you need mutating operations (`_mut` variants) or want to avoid repeated allocation; use the `bint` class for everyday ergonomic use.

- Comparison: `cmp`, `eq`, `lt`, `le`
- Sign: `abs`, `abs_mut`, `neg`, `neg_mut`
- Arithmetic: `add`, `add_mut`, `sub`, `sub_mut`, `mul`, `mul_mut`
- Division (floor): `divmod`, `idiv`, `mod`
- Division (truncated): `tdivmod`, `tdiv`, `tmod`
- Other: `pow`, `sqrt`, `lshift`, `rshift`, `lshift_words`, `rshift_words`

### `algorithms` entry points

Direct algorithm entry points that bypass automatic threshold dispatch. Each function has the same contract as its `core` counterpart but always routes to the named algorithm regardless of operand size. Useful for benchmarking threshold crossover points and testing algorithm correctness independently.

- Multiplication: `algorithms.mul_basecase`, `algorithms.mul_karatsuba`, `algorithms.mul_toom3`
- Division: `algorithms.div_knuth`, `algorithms.div_burnikel`
- Square root: `algorithms.sqrt_newton`, `algorithms.sqrt_karatsuba`

## Operator behavior

Supported metamethods:

- `+`, `-`, `*`, `//`, `%`, `^`, unary `-`
- `==`, `<`, `<=`
- `tostring(x)` and `x:tostring()`
- `#x` returns decimal digit count of magnitude

`/` is intentionally unsupported and throws an error. Use `//` for integer division.

## Semantics and caveats

- `bint.from_int(n)` converts the already-represented Luau `number` exactly; Luau numbers are IEEE-754 doubles, so integer literals above `2^53` may already be rounded. Use `bint.from_string(...)` for exact large integer literals.
- `bint.from_string` / `bint.tostring` support bases `2..36`.
- `core.divmod` and `//` use floor division semantics.
- `core.tdivmod` uses truncated (toward zero) semantics.
- `core.rshift(a, n)` uses arithmetic (sign-preserving) semantics, equivalent to `floor(a / 2^n)`.
- `core.lshift_words` / `core.rshift_words` are limb-count shifts (base-`2^24` words), not bit shifts.
- `core.sqrt(a)` returns `0` for `a <= 0`.
- `bint.tole`/`bint.tobe` serialize magnitude only (sign is not encoded).
- `bint.tonumber` is exact only up to magnitude `2^53`.

## Running tests

```bash
lune run libs/specs                       # full suite (all tags)
lune run libs/specs --tag fast            # quick local validation
lune run libs/specs --tag full            # CI-style: fast + full tests
lune run libs/specs --tag stress          # everything including slow/deep checks
lune run libs/specs --list-tags           # show available tags and counts
```

## Changelog format

This repository uses the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) structure.
