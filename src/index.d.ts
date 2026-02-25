export type Signum = -1 | 0 | 1;
export type BintArg = Bint | number | string;

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
