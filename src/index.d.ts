export type Signum = -1 | 0 | 1;
export type BintArg = Bint | number | string;
export type LimbArray = number[];

/** Runtime crossover points for dispatching multiplication, division, and sqrt algorithms.
 *  Positive infinity (`Infinity` / Luau `math.huge`) is accepted for
 *  `karatsuba_thr`, `toom3_thr`, `sqrt_kar_thr`, `burnikel_dispatch_thr`, and
 *  `burnikel_off` to disable that tier or gate. `mul_split_thr` must stay finite
 *  and <= 33 for exactness with BASE=2^24. `burnikel_leaf_thr` must be finite
 *  and >= 1. */
export interface BintThresholds {
	mul_split_thr: number;
	karatsuba_thr: number;
	toom3_thr: number;
	sqrt_kar_thr: number;
	burnikel_dispatch_thr: number;
	burnikel_leaf_thr: number;
	burnikel_off: number;
}

export interface Bint {
	limbs: number[];
	signum: Signum;

	clone(): Bint;
	cmp(other: BintArg): -1 | 0 | 1;
	eq(other: BintArg): boolean;
	lt(other: BintArg): boolean;
	le(other: BintArg): boolean;

	abs(): Bint;
	neg(): Bint;

	add(other: BintArg): Bint;
	sub(other: BintArg): Bint;
	mul(other: BintArg): Bint;

	divmod(other: BintArg): LuaTuple<[Bint, Bint]>;
	idiv(other: BintArg): Bint;
	mod(other: BintArg): Bint;

	tdivmod(other: BintArg): LuaTuple<[Bint, Bint]>;
	tdiv(other: BintArg): Bint;
	tmod(other: BintArg): Bint;

	pow(other: BintArg): Bint;
	sqrt(): Bint;
	lshift(n: number): Bint;
	rshift(n: number): Bint;
	lshift_words(n: number): Bint;
	rshift_words(n: number): Bint;
	to_string(base?: number): string;
	to_number(): number;
	to_sci(): LuaTuple<[number, number]>;
	to_le(trim?: boolean): string;
	to_be(trim?: boolean): string;
}

interface BintModule {
	(value: BintArg): Bint;

	from_int(n: number): Bint;
	from_string(s: string, base?: number): Bint;
	from_limbs(limbs: ReadonlyArray<number>, signum?: Signum): Bint;

	zero(): Bint;
	one(): Bint;
	new: (v: BintArg) => Bint;

	to_string(a: Bint, base?: number): string;
	to_le(a: Bint, trim?: boolean): string;
	to_be(a: Bint, trim?: boolean): string;
	from_le(s: string): Bint;
	from_be(s: string): Bint;
	to_number(a: Bint): number;
	to_sci(a: Bint): LuaTuple<[number, number]>;
}

interface BintCore {
	cmp(a: Bint, b: Bint): -1 | 0 | 1;
	eq(a: Bint, b: Bint): boolean;
	lt(a: Bint, b: Bint): boolean;
	le(a: Bint, b: Bint): boolean;

	abs(a: Bint): Bint;
	abs_mut(a: Bint): Bint;
	neg(a: Bint): Bint;
	neg_mut(a: Bint): Bint;

	add(a: Bint, b: Bint): Bint;
	add_mut(a: Bint, b: Bint): Bint;
	sub(a: Bint, b: Bint): Bint;
	sub_mut(a: Bint, b: Bint): Bint;
	mul(a: Bint, b: Bint): Bint;
	mul_mut(a: Bint, b: Bint): Bint;

	divmod(a: Bint, b: Bint): LuaTuple<[Bint, Bint]>;
	idiv(a: Bint, b: Bint): Bint;
	mod(a: Bint, b: Bint): Bint;

	tdivmod(a: Bint, b: Bint): LuaTuple<[Bint, Bint]>;
	tdiv(a: Bint, b: Bint): Bint;
	tmod(a: Bint, b: Bint): Bint;

	pow(a: Bint, b: Bint): Bint;
	sqrt(a: Bint): Bint;

	lshift(a: Bint, n: number): Bint;
	rshift(a: Bint, n: number): Bint;
	lshift_words(a: Bint, n: number): Bint;
	rshift_words(a: Bint, n: number): Bint;
}

interface BintTuning {
	/** Returns the current runtime dispatch configuration. */
	get_thresholds(): BintThresholds;
	/** Updates all thresholds atomically. Missing keys, NaN, and invalid values throw. */
	set_thresholds(config: BintThresholds): void;
	/** Restores the built-in default thresholds. */
	reset_thresholds(): void;
}

/** @internal */
interface BintHelpers {
	/** Mutates `limbs` in place by removing trailing zero limbs. */
	strip_zeros(limbs: LimbArray): void;
	mul_by_int(limbs: LimbArray, d: number): LimbArray;
	div_by_int(limbs: LimbArray, d: number, in_place?: boolean): LuaTuple<[LimbArray, LimbArray]>;
	div_by_int_exact(limbs: LimbArray, d: number, in_place?: boolean, ctx?: string): LimbArray;
	lshift_limbs(limbs: LimbArray, n: number): LimbArray;
	get_lower(limbs: LimbArray, n: number): LimbArray;
	get_upper(limbs: LimbArray, n: number): LimbArray;
	get_slice(limbs: LimbArray, s: number, e: number): LimbArray;
	join_hi_lo(hi: LimbArray, lo: LimbArray, n: number): LimbArray;
	bitlen_limbs(limbs: LimbArray): number;
	cmp_abs(a: LimbArray, b: LimbArray): -1 | 0 | 1;
	lt_abs(a: LimbArray, b: LimbArray): boolean;
	le_abs(a: LimbArray, b: LimbArray): boolean;
	eq_abs(a: LimbArray, b: LimbArray): boolean;
	add_limbs(a: LimbArray, b: LimbArray): LimbArray;
	/** Mutates `a` in place. */
	add_limbs_mut(a: LimbArray, b: LimbArray): LimbArray;
	sub_limbs(a: LimbArray, b: LimbArray): LimbArray;
	/** Mutates `a` in place; requires |a| >= |b|. */
	sub_limbs_mut(a: LimbArray, b: LimbArray): LimbArray;
	add_signed(al: LimbArray, as: Signum, bl: LimbArray, bs: Signum): LuaTuple<[LimbArray, Signum]>;
}

/** @internal */
interface BintAlgorithms {
	mul_schoolbook(a: Bint, b: Bint): Bint;
	mul_schoolbook_split(a: Bint, b: Bint): Bint;
	mul_schoolbook_unsplit(a: Bint, b: Bint): Bint;
	mul_karatsuba(a: Bint, b: Bint): Bint;
	mul_toom3(a: Bint, b: Bint): Bint;
	div_knuth(a: Bint, b: Bint): LuaTuple<[Bint, Bint]>;
	div_burnikel(a: Bint, b: Bint): LuaTuple<[Bint, Bint]>;
	sqrt_newton(n: Bint): Bint;
	sqrt_karatsuba(n: Bint): Bint;
}

/** @internal */
interface BintInternals {
	algorithms: BintAlgorithms;
	helpers: BintHelpers;
}

/** Safe, ergonomic big-integer API. Accepts {@link BintArg} (Bint, number,
 *  or string) wherever a value is expected; inputs are validated at
 *  construction time. Arithmetic/comparison instance methods coerce their
 *  argument before delegating to `core`. */
export const bint: BintModule;

/** Low-level signed arithmetic on canonical {@link Bint} values.
 *  All functions require valid `Bint` arguments — no coercion or input
 *  validation is performed. Use {@link bint} for the safe API that
 *  accepts `BintArg` (Bint, number, or string). */
export const core: BintCore;

/**
 * Advanced, unstable internals for low-level algorithm and limb-helper access.
 * @internal
 */
export const internals: BintInternals;

/** Runtime tuning for algorithm dispatch crossover points and Burnikel-Ziegler leaf sizing. */
export const tuning: BintTuning;
