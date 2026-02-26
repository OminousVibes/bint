--!optimize 2
--!native
--!strict

--[[--
bint - arbitrary-precision integer library for Luau
authored by OminousVibes (https://github.com/OminousVibes)

Small, self-contained library for computing with arbitrarily large signed
integers in Luau. Unlike fixed-width integer types, Bints carry their own
magnitude and grow as needed.

Integers are represented as `{ limbs: {number}, signum: number }` where limbs
is a little-endian array of base-2^24 words and signum is -1, 0, or 1.
The 24-bit limb width ensures that limb*limb never exceeds 2^53, remaining
exact under Luau's double-precision arithmetic.

Multiplication uses schoolbook, Karatsuba, and Toom-Cook 3-way algorithms
selected by operand size. Division uses Knuth Algorithm D and Burnikel-Ziegler.
Integer square root uses a Karatsuba-recursive algorithm with Newton-Heron
correction.

## Usage

Create a Bint with one of the constructor functions:

* `bint.from_int(n)`       — from a Lua number
* `bint.from_string(s, b)` — from a string in any base 2–36
* `bint.from_limbs(t)`     — from a raw limb table
* `bint.zero()` / `bint.one()`
* `bint.new(v)`            — from any BintArg; clones existing Bints
* `bint(v)`                — alias for `bint.new`

Retrieve results with:

* `bint.to_string(a, base?)` — decimal or any base-2..36 string
* `bint.to_number(a)`        — lua number (exact for |a| ≤ 2^53)
* `bint.to_le(a, trim?)` / `bint.to_be(a, trim?)` — byte strings
* `bint.from_le(s)` / `bint.from_be(s)`           — from byte strings

All arithmetic metamethods (+, -, *, //, %, ^, unary -) and comparison
metamethods (==, <, <=) are implemented. Low-level typed operations are
available through the `core` module export; `core` requires canonical Bint
values and performs no coercion or input validation.
]]

--# CONSTANTS

local BASE          = 2^24                  -- 16777216; limb*limb < 2^53 (safe in doubles)
local BASE_MASK     = 0xFFFFFF              -- BASE - 1
local BASE_POW      = 24
local RADIX_CHUNK   = 1e8                   -- 10^8; for decimal I/O chunking
local KARATSUBA_THR = 44                    -- switch to Karatsuba (limbs)
local TOOM3_THR     = 124                   -- switch to Toom-3 (limbs)
local SQRT_KAR_THR  = 4                     -- Karatsuba sqrt threshold (limbs)
local BURNIKEL_THR  = 232                   -- switch to Burnikel-Ziegler (limbs)
local BURNIKEL_OFF  = 40                    -- minimum BZ numerator-denominator offset

--# UPVALUE ALIASES

local floor  = math.floor
local ceil   = math.ceil
local log10  = math.log10
local mabs   = math.abs
local msign  = math.sign
local mmax   = math.max
local mmin   = math.min
local mlog   = math.log

local tcreate = table.create
local tinsert = table.insert
local tclone  = table.clone
local tmove   = table.move
local tclear  = table.clear
local tconcat = table.concat

local sformat = string.format
local sbyte   = string.byte
local schar   = string.char
local ssub    = string.sub
local slen    = string.len
local sfind   = string.find
local sreverse = string.reverse

local RADIX_LEN_K   = BASE_POW * log10(2)   -- for __len

--# TYPES

export type Bint = {
	limbs: {number},
	signum: number,
}
export type BintArg = Bint | number | string

--# LIMB HELPERS
-- Private, unsigned. Operate on raw {number} arrays.

-- Remove trailing zero limbs (leading zeros in big-endian view).
local function strip_zeros(limbs: {number})
	while true do
		local n = #limbs
		if n == 0 or limbs[n] ~= 0 then break end
		limbs[n] = nil
	end
end

-- Multiply every limb by a single integer d; returns a new array.
local function mul_by_int(limbs: {number}, d: number): {number}
	local result = tclone(limbs)
	local carry = 0
	for i, limb in result do
		local p = limb * d + carry
		carry = floor(p / BASE)
		result[i] = p % BASE
	end
	if carry > 0 then tinsert(result, carry) end
	return result
end

-- Single-limb division; returns (quotient_limbs, remainder_limbs).
-- in_place=true writes the quotient back into limbs; the result is always stripped.
local function div_by_int(limbs: {number}, d: number, in_place: boolean?): ({number}, {number})
	local q: {number} = in_place and limbs or tclone(limbs)
	local carry = 0
	for i = #limbs, 1, -1 do
		local x = limbs[i] + carry * BASE
		local qd = floor(x / d)
		carry = x - qd * d
		q[i] = qd
	end
	strip_zeros(q)
	if carry == 0 then
		return q, {}
	end
	return q, {carry}
end

-- Exact single-limb division: errors if the remainder is nonzero and returns only the quotient.
-- Use this wherever the division must be exact (e.g. Toom-3 interpolation, pow10 cursor).
local function div_by_int_exact(limbs: {number}, d: number, in_place: boolean?, ctx: string?): {number}
	local q, rem = div_by_int(limbs, d, in_place)
	if #rem ~= 0 then
		error(ctx or "internal error: exact division left a remainder", 2)
	end
	return q
end

-- Mutable exact power-of-ten cursor used to correct __len estimates.
-- This keeps __len exact without paying decimal conversion cost on every call.
local POW10_CURSOR_EXP = 0
local POW10_CURSOR_LIMBS = {1} :: {number} -- 10^0

local function seek_pow10_limbs(exp: number): {number}
	while POW10_CURSOR_EXP < exp do
		POW10_CURSOR_LIMBS = mul_by_int(POW10_CURSOR_LIMBS, 10)
		POW10_CURSOR_EXP += 1
	end
	while POW10_CURSOR_EXP > exp do
		POW10_CURSOR_LIMBS = div_by_int_exact(POW10_CURSOR_LIMBS, 10, true, "internal error: pow10 cursor division left a remainder")
		POW10_CURSOR_EXP -= 1
	end
	return POW10_CURSOR_LIMBS
end

-- Word-aligned left shift: prepend n zero limbs.
local function lshift_limbs(limbs: {number}, n: number): {number}
	return tmove(limbs, 1, #limbs, n + 1, tcreate(n, 0))
end

-- Extract the first n limbs.
local function get_lower(limbs: {number}, n: number): {number}
	return tmove(limbs, 1, n, 1, {})
end

-- Extract limbs from index n+1 to the end.
local function get_upper(limbs: {number}, n: number): {number}
	return tmove(limbs, n + 1, #limbs, 1, {})
end

-- Extract limbs[s..e].
local function get_slice(limbs: {number}, s: number, e: number): {number}
	return tmove(limbs, s, e, 1, {})
end

-- Join disjoint blocks as hi * BASE^n + lo, where lo occupies at most n limbs.
local function join_hi_lo(hi: {number}, lo: {number}, n: number): {number}
	local z = lshift_limbs(hi, n)
	if #lo > 0 then
		tmove(lo, 1, #lo, 1, z)
	end
	return z
end

-- Exact bit length of an unsigned limb array.
local function bitlen_limbs(limbs: {number}): number
	local n = #limbs
	if n == 0 then
		return 0
	end

	local top = limbs[n]
	local bits = 0
	while top > 0 do
		bits += 1
		top = floor(top / 2)
	end
	return (n - 1) * BASE_POW + bits
end

-- Unsigned magnitude comparison. Returns -1, 0, or 1.
local function cmp_abs(a: {number}, b: {number}): number
	local an, bn = #a, #b
	if an < bn then return -1
	elseif an > bn then return 1
	end
	for i = an, 1, -1 do
		local ai, bi = a[i], b[i]
		if ai ~= bi then return ai > bi and 1 or -1 end
	end
	return 0
end

-- Unsigned less-than.
local function lt_abs(a: {number}, b: {number}): boolean
	local an, bn = #a, #b
	if an ~= bn then return an < bn end
	for i = an, 1, -1 do
		local ai, bi = a[i], b[i]
		if ai ~= bi then return ai < bi end
	end
	return false
end

-- Unsigned less-than-or-equal.
local function le_abs(a: {number}, b: {number}): boolean
	local an, bn = #a, #b
	if an ~= bn then return an < bn end
	for i = an, 1, -1 do
		local ai, bi = a[i], b[i]
		if ai ~= bi then return ai < bi end
	end
	return true
end

-- Unsigned equality.
local function eq_abs(a: {number}, b: {number}): boolean
	if #a ~= #b then return false end
	for i, v in a do
		if v ~= b[i] then return false end
	end
	return true
end

-- Add unsigned limb arrays: a += b (mutates a).
local function add_limbs_mut(a: {number}, b: {number}): {number}
	local an, bn = #a, #b
	if bn == 0 then return a end

	local carry = 0
	local n = mmin(an, bn)

	-- Process the shared prefix first, then only the remaining tail.
	for i = 1, n do
		local s = a[i] + b[i] + carry
		if s >= BASE then
			a[i] = s - BASE
			carry = 1
		else
			a[i] = s
			carry = 0
		end
	end

	if an >= bn then
		if carry ~= 0 then
			for i = bn + 1, an do
				local s = a[i] + 1
				if s >= BASE then
					a[i] = s - BASE
				else
					a[i] = s
					return a
				end
			end
			a[an + 1] = 1
		end
		return a
	end

	-- b has a longer tail; append/copy it into a and propagate any carry.
	for i = an + 1, bn do
		local s = b[i] + carry
		if s >= BASE then
			a[i] = s - BASE
			carry = 1
		else
			a[i] = s
			if i < bn then
				tmove(b, i + 1, bn, i + 1, a)
			end
			return a
		end
	end
	if carry ~= 0 then
		a[bn + 1] = 1
	end
	return a
end

-- Add two unsigned limb arrays (pure); clones the longer operand, then mutates the clone.
local function add_limbs(a: {number}, b: {number}): {number}
	if #b > #a then
		return add_limbs_mut(tclone(b), a)
	end
	return add_limbs_mut(tclone(a), b)
end

-- Subtract unsigned: a -= b, requires |a| >= |b| (mutates a).
local function sub_limbs_mut(a: {number}, b: {number}): {number}
	local an, bn = #a, #b
	local borrow = 0
	for i = 1, bn do
		local d = a[i] - b[i] + borrow
		if d < 0 then
			a[i] = d + BASE
			borrow = -1
		else
			a[i] = d
			borrow = 0
		end
	end
	if borrow ~= 0 then
		for i = bn + 1, an do
			local d = a[i] - 1
			if d < 0 then
				a[i] = d + BASE
			else
				a[i] = d
				break
			end
		end
	end
	strip_zeros(a)
	return a
end

-- Subtract unsigned: a - b, requires |a| >= |b| (pure).
local function sub_limbs(a: {number}, b: {number}): {number}
	return sub_limbs_mut(tclone(a), b)
end

--## Multiplication (Karatsuba + Toom-Cook)

-- Schoolbook O(n²) multiplication.
-- Uses a Comba-style split-accumulator inner loop: each product a[j]*b[k] is split into
-- its low limb (prod % BASE) and high limb (floor(prod / BASE)) before accumulation, keeping
-- both running totals (c0, c1) well below 2^53 regardless of column weight.
local function mul_limbs_basecase(a: {number}, b: {number}): {number}
	local an, bn = #a, #b
	local len = an + bn
	local result = tcreate(len, 0)
	local bnm1 = bn - 1
	local carry = 0
	for i = 1, len do
		local c0 = carry
		local c1 = 0
		local ip1 = i + 1
		for j = mmax(i - bnm1, 1), mmin(i, an) do
			local prod = a[j] * b[ip1 - j]
			c0 += prod % BASE
			c1 += floor(prod / BASE)
		end
		c1 += floor(c0 / BASE)
		result[i] = c0 % BASE
		carry = c1
	end
	return result
end

-- Forward declarations needed for mutual recursion inside mul/div/sqrt.
local mul_limbs: ({number}, {number}) -> {number}
local div_limbs: ({number}, {number}) -> ({number}, {number})
local div_bz_2n1n: ({number}, {number}) -> ({number}, {number})

-- Karatsuba O(n^1.585) multiplication.
local function mul_limbs_karatsuba(x: {number}, y: {number}): {number}
	local m2 = (mmax(#x, #y) + 1) // 2

	local low1, low2 = get_lower(x, m2), get_lower(y, m2)
	local high1, high2 = get_upper(x, m2), get_upper(y, m2)

	local z0 = mul_limbs(low1, low2)
	local z1 = mul_limbs(add_limbs_mut(low1, high1), add_limbs_mut(low2, high2))
	local z2 = mul_limbs(high1, high2)

	-- result = z0 + ((z1 - z2 - z0) << m2) + (z2 << 2*m2)
	-- factored: (z2 << m2 + (z1 - (z2 + z0))) << m2 + z0
	local result = lshift_limbs(z2, m2)
	sub_limbs_mut(z1, add_limbs_mut(z2, z0))
	result = add_limbs_mut(result, z1)
	result = lshift_limbs(result, m2)
	add_limbs_mut(result, z0)
	return result
end

-- Toom-Cook 3-way O(n^1.465) multiplication.
local function mul_limbs_toom3(x: {number}, y: {number}): {number}
	local largest = mmax(#x, #y)
	local k  = largest // 3

	local x0, x1 = get_slice(x, 1, k), get_slice(x, k + 1, 2 * k)
	local x2       = get_upper(x, 2 * k)
	local y0, y1 = get_slice(y, 1, k), get_slice(y, k + 1, 2 * k)
	local y2       = get_upper(y, 2 * k)

	local v0   = mul_limbs(x0, y0)
	local vinf = mul_limbs(x2, y2)

	local da1 = add_limbs(x2, x0)
	local db1 = add_limbs(y2, y0)

	-- p(-1) factors can be negative; track sign explicitly
	local ex_neg = lt_abs(da1, x1)
	local ex_limbs = ex_neg and sub_limbs(x1, da1) or sub_limbs(da1, x1)
	local ey_neg = lt_abs(db1, y1)
	local ey_limbs = ey_neg and sub_limbs(y1, db1) or sub_limbs(db1, y1)
	local vm1 = mul_limbs(ex_limbs, ey_limbs)
	local vm1_neg = ex_neg ~= ey_neg

	da1 = add_limbs_mut(da1, x1)
	db1 = add_limbs_mut(db1, y1)

	local v1 = mul_limbs(da1, db1)
	da1 = add_limbs_mut(da1, x2)
	db1 = add_limbs_mut(db1, y2)

	local v2 = sub_limbs_mut(add_limbs_mut(da1, da1), x0)
	v2 = mul_limbs(v2, sub_limbs_mut(add_limbs_mut(db1, db1), y0))

	-- interpolation (all divisions here are single-limb, i.e. linear)
	-- step 1: v2 = (v2 - vm1) / 3
	if vm1_neg then
		v2 = add_limbs(v2, vm1)
	else
		sub_limbs_mut(v2, vm1)
	end
	div_by_int_exact(v2, 3, true, "internal error: Toom-3 interpolation exact /3 failed")
	-- step 2: tm1 = (v1 - vm1) / 2
	local tm1 = div_by_int_exact(vm1_neg and add_limbs(v1, vm1) or sub_limbs(v1, vm1), 2, true, "internal error: Toom-3 interpolation exact /2 (tm1) failed")
	v1 = sub_limbs_mut(v1, v0)

	div_by_int_exact(sub_limbs_mut(v2, v1), 2, true, "internal error: Toom-3 interpolation exact /2 (v2) failed")
	v1 = sub_limbs_mut(sub_limbs_mut(v1, tm1), vinf)
	v2 = sub_limbs_mut(v2, add_limbs(vinf, vinf))
	tm1 = sub_limbs_mut(tm1, v2)

	-- recombine
	local result = lshift_limbs(vinf, k)
	result = add_limbs_mut(result, v2);  result = lshift_limbs(result, k)
	result = add_limbs_mut(result, v1);  result = lshift_limbs(result, k)
	result = add_limbs_mut(result, tm1); result = lshift_limbs(result, k)
	result = add_limbs_mut(result, v0)
	return result
end

-- Dispatch multiplication by operand size.
mul_limbs = function(a: {number}, b: {number}): {number}
	local an, bn = #a, #b
	local result: {number}
	if an < KARATSUBA_THR or bn < KARATSUBA_THR then
		result = mul_limbs_basecase(a, b)
	elseif an < TOOM3_THR or bn < TOOM3_THR then
		result = mul_limbs_karatsuba(a, b)
	else
		result = mul_limbs_toom3(a, b)
	end
	strip_zeros(result)
	return result
end

--## Division (Knuth + Burnikel-Ziegler)

-- Knuth Algorithm D (multi-precision long division).
local function div_knuths(U: {number}, V: {number}): ({number}, {number})
	local n = #V
	local m = #U - n

	-- normalize
	local D = floor(BASE / (V[n] + 1))
	local Un = mul_by_int(U, D)
	local Vn = mul_by_int(V, D)

	local Vnn = Vn[n]
	local penVn = Vn[n - 1] or 0

	local quotient = tcreate(m + 1, 0)

	for j = m, 0, -1 do
		local nj1 = n + j + 1
		local top = (Un[nj1] or 0) * BASE + (Un[nj1 - 1] or 0)
		local qhat, rhat
		if (Un[nj1] or 0) >= Vnn then
			-- Knuth D3 equality path: quotient estimate saturates to BASE-1 to keep it
			-- in range [0, BASE-1]. rhat is recomputed from the saturated estimate.
			qhat = BASE - 1
			rhat = top - (BASE - 1) * Vnn
		else
			qhat = floor(top / Vnn)
			rhat = top % Vnn
		end

		if qhat == 0 then continue end

		-- first correction
		if qhat * penVn > rhat * BASE + (Un[nj1 - 2] or 0) then
			qhat -= 1
			rhat += Vnn
			-- second correction
			if rhat < BASE and qhat * penVn > rhat * BASE + (Un[nj1 - 2] or 0) then
				qhat -= 1
			end
		end

		-- multiply & subtract
		local carry = 0
		local borrow = 0
		for i = 1, n do
			local p = qhat * Vn[i] + carry
			carry = floor(p / BASE)
			local pDigit = p % BASE
			local diff = Un[i + j] - pDigit - borrow
			if diff < 0 then
				borrow = 1
				Un[i + j] = diff + BASE
			else
				borrow = 0
				Un[i + j] = diff
			end
		end
		local lastSub = (Un[nj1] or 0) - carry - borrow
		Un[nj1] = lastSub

		-- add back if needed
		if lastSub >= 0 then
			quotient[j + 1] = qhat
		else
			quotient[j + 1] = qhat - 1
			local c2 = 0
			for i = 1, n do
				local s = Un[i + j] + Vn[i] + c2
				if s >= BASE then
					c2 = 1
					Un[i + j] = s - BASE
				else
					c2 = 0
					Un[i + j] = s
				end
			end
			Un[nj1] = (Un[nj1] + c2) % BASE
		end
	end

	-- unnormalize remainder
	local c3 = 0
	for i = #Un, 1, -1 do
		local x = c3 * BASE + Un[i]
		c3 = x % D
		Un[i] = floor(x / D)
	end
	strip_zeros(Un)
	return quotient, Un
end

-- Burnikel-Ziegler 3n/2n sub-step.
local function div_bz_3n2n(
	a1: {number}, a2: {number}, a3: {number},
	b1: {number}, b2: {number}
): ({number}, {number})
	local n = #b2
	local B = add_limbs_mut(lshift_limbs(b1, n), b2)

	local q: {number}, R: {number}, D: {number}
	if lt_abs(a1, b1) then
		local a1a2 = add_limbs_mut(lshift_limbs(a1, n), a2)
		q, R = div_bz_2n1n(a1a2, b1)
		strip_zeros(q)
		D = mul_limbs(q, b2)
	else
		q = tcreate(n, BASE_MASK)
		R = lshift_limbs(sub_limbs_mut(a1, b1), n)
		-- R1 = A1A2 - (BASE^n - 1) * B1 = (A1 - B1) * BASE^n + A2 + B1
		R = add_limbs_mut(add_limbs_mut(R, b1), a2)
		D = sub_limbs_mut(lshift_limbs(b2, n), b2)
	end

	R = add_limbs_mut(lshift_limbs(R, n), a3)

	while lt_abs(R, D) do
		sub_limbs_mut(q, {1})
		add_limbs_mut(R, B)
	end

	sub_limbs_mut(R, D)
	return q, R
end

-- Burnikel-Ziegler 2n/1n sub-step.
div_bz_2n1n = function(A: {number}, B: {number}): ({number}, {number})
	local bLen = #B
	local aLen = #A

	-- The outer driver can feed a short top chunk (<= n limbs) when the conceptual
	-- block split introduces leading zero blocks. Handle those directly to avoid
	-- paying recursive 2n/1n overhead on effectively n/1n inputs.
	if aLen < bLen then
		return {}, tclone(A)
	end
	if aLen == bLen then
		local cmp = cmp_abs(A, B)
		if cmp < 0 then
			return {}, tclone(A)
		elseif cmp == 0 then
			return {1}, {}
		end
		local q, r = div_knuths(A, B)
		strip_zeros(q)
		return q, r
	end

	if bLen % 2 == 1 or bLen < BURNIKEL_THR then
		return div_knuths(A, B)
	end

	local k = bLen // 2
	local a1, a2 = get_slice(A, 3 * k + 1, 4 * k), get_slice(A, 2 * k + 1, 3 * k)
	local a3, a4 = get_slice(A, k + 1, 2 * k),     get_slice(A, 1, k)
	local b1, b2 = get_upper(B, k),                 get_lower(B, k)

	local q1, r = div_bz_3n2n(a1, a2, a3, b1, b2)
	local r1, r2 = get_upper(r, k), get_lower(r, k)
	local q2, S = div_bz_3n2n(r1, r2, a4, b1, b2)

	local Q = add_limbs_mut(lshift_limbs(q1, k), q2)
	strip_zeros(Q)
	return Q, S
end

-- Outer Burnikel-Ziegler driver.
local function div_burnikel(A: {number}, B: {number}): ({number}, {number})
	local s = #B

	local m = 2 ^ floor(mlog(s / BURNIKEL_THR, 2) + 1)
	local j = ceil(s / m)
	local n = j * m

	local sigma = floor(BASE / (B[s] + 1))
	local shift = n - s

	local bShifted = mul_by_int(B, sigma)
	local aShifted = mul_by_int(A, sigma)
	if shift > 0 then
		bShifted = lshift_limbs(bShifted, shift)
		aShifted = lshift_limbs(aShifted, shift)
	end

	local nBits = n * BASE_POW
	local t = mmax(floor((bitlen_limbs(aShifted) + nBits) / nBits), 2)

	local aTop = get_slice(aShifted, (t - 1) * n + 1, t * n)
	local zLow = get_slice(aShifted, (t - 2) * n + 1, (t - 1) * n)
	local z = join_hi_lo(aTop, zLow, n)

	local quotient: {number} = {}
	for i = t - 2, 1, -1 do
		local qi, ri = div_bz_2n1n(z, bShifted)
		quotient = add_limbs_mut(quotient, lshift_limbs(qi, i * n))
		local ai1 = get_slice(aShifted, (i - 1) * n + 1, i * n)
		z = join_hi_lo(ri, ai1, n)
	end

	local qi, ri = div_bz_2n1n(z, bShifted)
	quotient = add_limbs_mut(quotient, qi)
	z = ri

	div_by_int(z, sigma, true)
	-- The word-shift applied to both operands to align B to a block boundary
	-- must be undone on the remainder; the quotient is unaffected.
	if shift > 0 then
		local len = #z
		if len > shift then
			tmove(z, shift + 1, len, 1, z)
			for i = len - shift + 1, len do
				z[i] = nil
			end
		elseif len > 0 then
			tclear(z)
		end
	end
	return quotient, z
end

-- Dispatch division by operand size.
div_limbs = function(a: {number}, b: {number}): ({number}, {number})
	local diff = #a - #b
	local q, r: {number}
	if #a > BURNIKEL_THR and #b > BURNIKEL_THR and diff > BURNIKEL_OFF then
		q, r = div_burnikel(a, b)
	else
		q, r = div_knuths(a, b)
	end
	strip_zeros(q)
	return q, r
end

--## Square Root (Newton-Heron + Karatsuba)

-- Newton-Heron iteration.
local function sqrt_newton(n: {number}): {number}
	local prev2: {number} = {1}
	-- Keep the seed as a valid dense 1-based limb array even for 1-limb inputs.
	local guessLen = mmax(#n // 2, 1)
	local prev1 = tcreate(guessLen, 0)
	prev1[guessLen] = 1 -- initial guess: BASE^(floor(limbs/2))

	while true do
		local q, _ = div_limbs(n, prev1)
		local x1, _ = div_by_int(add_limbs(prev1, q), 2, true)

		if eq_abs(x1, prev1) then
			return x1
		end
		if eq_abs(x1, prev2) then
			return lt_abs(x1, prev1) and x1 or prev1
		end
		prev2, prev1 = prev1, x1
	end
end

-- Karatsuba square root; returns (s, r) where s² + r = n.
local function sqrt_karatsuba(n: {number}): ({number}, {number})
	local limbLen = #n
	if limbLen < SQRT_KAR_THR then
		local sq = sqrt_newton(n)
		return sq, sub_limbs(n, mul_limbs(sq, sq))
	end

	local m  = limbLen // 4
	local m2 = m * 2

	local a3a2 = get_upper(n, m2)
	local a1   = get_slice(n, m + 1, m2)
	local a0   = get_slice(n, 1, m)

	local s1, r1 = sqrt_karatsuba(a3a2)

	local r1b = add_limbs_mut(lshift_limbs(r1, m), a1)
	local ds1 = add_limbs(s1, s1)
	local q, u = div_limbs(r1b, ds1)

	local s = add_limbs_mut(lshift_limbs(s1, m), q)

	local qSq = mul_limbs(q, q)
	local r2 = add_limbs_mut(lshift_limbs(u, m), a0)

	-- q can overshoot by more than 1; keep correcting until r2 - qSq is non-negative.
	-- Lazy: only allocate ds1 = 2s-1 if correction is actually needed (~50% of inputs).
	if lt_abs(r2, qSq) then
		local one = {1}
		local two = {2}
		local cor = add_limbs(s, s)
		sub_limbs_mut(cor, one)        -- cor = 2s - 1
		repeat
			add_limbs_mut(r2, cor)     -- r2 += 2s - 1  (fused add + subtract)
			sub_limbs_mut(s, one)      -- s -= 1
			sub_limbs_mut(cor, two)    -- cor = 2*(s_new) - 1
		until not lt_abs(r2, qSq)
	end
	r2 = sub_limbs_mut(r2, qSq)

	return s, r2
end

-- Dispatch sqrt; returns the root only.
local function sqrt_limbs(n: {number}): {number}
	if #n >= SQRT_KAR_THR then
		local s, _ = sqrt_karatsuba(n)
		return s
	end
	return sqrt_newton(n)
end

--## Power

-- Exponentiation by squaring, single-limb exponent.
local function pow_by_int(limbs: {number}, exp: number): {number}
	local result: {number} = {1}
	while exp > 0 do
		if exp % 2 == 1 then
			result = mul_limbs(limbs, result)
		end
		limbs = mul_limbs(limbs, limbs)
		exp = floor(exp / 2)
	end
	return result
end

-- Exponentiation by squaring for big-integer exponents.
-- Mutates exp_limbs in-place; pass a clone if needed.
local function pow_limbs(limbs: {number}, exp_limbs: {number}): {number}
	local result: {number} = {1}
	while #exp_limbs > 0 do
		if exp_limbs[1] % 2 == 1 then
			result = mul_limbs(result, limbs)
		end
		limbs = mul_limbs(limbs, limbs)
		div_by_int(exp_limbs, 2, true)
	end
	return result
end

--# BINT HELPERS
-- Private. Operate on Bint structs.

-- Forward declaration for the metatable (needed in from_raw etc.)
local Bint: any = {}
Bint.__index = Bint

local function make_zero(): Bint
	return setmetatable({ limbs = {}, signum = 0 }, Bint) :: Bint
end

-- Build a Bint from already-computed limbs + sign; normalizes zero.
local function from_raw(limbs: {number}, sign: number): Bint
	strip_zeros(limbs)
	if #limbs == 0 then sign = 0 end
	return setmetatable({ limbs = limbs, signum = sign }, Bint) :: Bint
end

local function clone_bint(b: Bint): Bint
	return setmetatable({ limbs = tclone(b.limbs), signum = b.signum }, Bint) :: Bint
end

--# CONSTRUCTORS

local bint = {}

--- Create a new Bint from a Lua integer.
--- Converts the current Lua number value as represented (IEEE-754 double).
--- For exact large integer literals beyond 2^53, prefer `bint.from_string`.
--- @param n A finite integer lua number.
--- @return A new Bint.
--- @raise An error if n is not a finite integer.
function bint.from_int(n: number): Bint
	if n == 0 then return make_zero() end
	if n ~= floor(n) or n ~= n or mabs(n) == math.huge then
		error("bint.from_int: expected an integer, got " .. tostring(n), 2)
	end
	if n == -1 then return setmetatable({ limbs = {1}, signum = -1 }, Bint) :: Bint end

	local sign = msign(n)
	n = mabs(n)
	local limbs: {number} = {}
	while n > 0 do
		tinsert(limbs, n % BASE)
		n = floor(n / BASE)
	end
	return setmetatable({ limbs = limbs, signum = sign }, Bint) :: Bint
end

-- Decimal string to Bint via chunked 10^8 conversion.
local function from_string_dec(str: string, negative: boolean): Bint
	if sfind(str, "[^0-9]") ~= nil then
		error("bint.from_string: invalid character in decimal string", 2)
	end
	local firstNonZero = sfind(str, "[^0]")
	if firstNonZero == nil then return make_zero() end
	if firstNonZero ~= 1 then str = ssub(str, firstNonZero) end

	local chunks: {number} = {}
	for i = #str, 1, -8 do
		local s = mmax(i - 7, 1)
		tinsert(chunks, tonumber(ssub(str, s, i)) or 0)
	end

	local out: {number} = {}
	while #chunks > 0 do
		local carry = 0
		for i = #chunks, 1, -1 do
			local val = chunks[i] + carry * RADIX_CHUNK
			chunks[i] = floor(val / BASE)
			carry = val % BASE
		end
		tinsert(out, carry)
		while true do
			local len = #chunks
			if len == 0 or chunks[len] ~= 0 then break end
			chunks[len] = nil
		end
	end

	return from_raw(out, negative and -1 or 1)
end

-- Digit table for base-N string parsing.
local DIGIT_VALUES: {[string]: number} = {}
do
	for i = 0, 9  do DIGIT_VALUES[tostring(i)] = i end
	for i = 0, 25 do
		DIGIT_VALUES[schar(97 + i)]  = 10 + i  -- a-z
		DIGIT_VALUES[schar(65 + i)]  = 10 + i  -- A-Z
	end
end

-- Base 2–36 string to Bint via multiply-and-add.
local function from_string_base(str: string, base: number, negative: boolean): Bint
	local acc: {number} = {}  -- starts as 0
	for i = 1, #str do
		local ch = ssub(str, i, i)
		local dv = DIGIT_VALUES[ch]
		if dv == nil or dv >= base then
			error(sformat("bint.from_string: invalid character '%s' for base %d", ch, base), 2)
		end
		-- acc = acc * base + dv
		if #acc > 0 then
			acc = mul_by_int(acc, base)
			strip_zeros(acc)
		end
		if dv > 0 then
			acc = add_limbs_mut(acc, {dv})
		end
	end
	return from_raw(acc, negative and -1 or 1)
end

--- Create a new Bint from a string.
--- Supports an optional leading '-' sign and any base from 2 to 36.
--- @param s The string to parse.
--- @param[opt] base The numeric base (2–36). Defaults to 10.
--- @return A new Bint.
--- @raise An error if s is empty, contains invalid characters, or base is out of range.
function bint.from_string(s: string, base: number?): Bint
	if type(s) ~= "string" then
		error("bint.from_string: expected string", 2)
	end
	local b = base or 10
	if b < 2 or b > 36 or floor(b) ~= b then
		error("bint.from_string: base must be an integer in 2–36", 2)
	end

	local negative = ssub(s, 1, 1) == "-"
	if negative then s = ssub(s, 2) end

	if #s == 0 then error("bint.from_string: empty string", 2) end

	if b == 10 then
		return from_string_dec(s, negative)
	else
		return from_string_base(s, b, negative)
	end
end

--- Create a new Bint from a raw limb array.
--- Each limb must be a non-negative integer in [0, BASE).
--- @param limbs A table of base-2^24 words, least-significant first.
--- @param[opt] signum The sign (-1, 0, or 1). Inferred from limbs when omitted.
--- @return A new Bint.
--- @raise An error if any limb is out of range or signum is invalid.
function bint.from_limbs(limbs: {number}, signum: number?): Bint
	local out: {number} = {}
	for i, v in limbs do
		if type(v) ~= "number" or v ~= floor(v) or v < 0 or v >= BASE then
			error(sformat("bint.from_limbs: limb[%d]=%s out of range [0, BASE)", i, tostring(v)), 2)
		end
		tinsert(out, v)
	end
	local sign: number
	if signum ~= nil then
		if signum ~= -1 and signum ~= 0 and signum ~= 1 then
			error("bint.from_limbs: signum must be -1, 0, or 1", 2)
		end
		if signum == 0 and #out ~= 0 then
			error("bint.from_limbs: signum=0 requires empty limbs (use nil for auto)", 2)
		end
		sign = signum
	else
		sign = #out > 0 and 1 or 0
	end
	return from_raw(out, sign)
end

--- Create a new Bint with value zero.
--- @return A new Bint.
function bint.zero(): Bint
	return make_zero()
end

--- Create a new Bint with value one.
--- @return A new Bint.
function bint.one(): Bint
	return setmetatable({ limbs = {1}, signum = 1 }, Bint) :: Bint
end

--- Create a new Bint from any supported value.
--- Clones an existing Bint; converts numbers and strings.
--- @param v A Bint, number, or string.
--- @return A new Bint.
--- @raise An error if v cannot be converted.
--- @see bint.from_int
--- @see bint.from_string
function bint.new(v: BintArg): Bint
	local t = typeof(v)
	if t == "table" and getmetatable(v :: any) == Bint then
		return clone_bint(v :: Bint)
	elseif t == "number" then
		return bint.from_int(v :: number)
	elseif t == "string" then
		return bint.from_string(v :: string)
	else
		error(sformat("bint.new: cannot convert %s to Bint", t), 2)
	end
end

local function coerce(v: BintArg): Bint
	if typeof(v) == "table" and getmetatable(v :: any) == Bint then
		return v :: Bint
	end
	return bint.new(v)
end

--# CORE
-- Signed arithmetic on canonical Bint values.
-- Requires valid Bint arguments; no input coercion or validation is performed.
-- Use the bint class for safe, BintArg-accepting wrappers.

local core = {}

--## Comparison

--- Compare two Bints.
--- @param a Left operand.
--- @param b Right operand.
--- @return -1 if a < b, 0 if a == b, 1 if a > b.
function core.cmp(a: Bint, b: Bint): number
	local as, bs = a.signum, b.signum
	if as ~= bs then return as < bs and -1 or 1 end
	if as == 0 then return 0 end
	local r = cmp_abs(a.limbs, b.limbs)
	return as == -1 and -r or r  -- flip for negative
end

--- Test two Bints for equality.
--- @param a Left operand.
--- @param b Right operand.
--- @return True if a == b.
function core.eq(a: Bint, b: Bint): boolean
	return a.signum == b.signum and eq_abs(a.limbs, b.limbs)
end

--- Test if a is strictly less than b.
--- @param a Left operand.
--- @param b Right operand.
--- @return True if a < b.
function core.lt(a: Bint, b: Bint): boolean
	local as, bs = a.signum, b.signum
	if as < bs then return true
	elseif as > bs then return false
	end
	if as == -1 then return lt_abs(b.limbs, a.limbs) end
	return lt_abs(a.limbs, b.limbs)
end

--- Test if a is less than or equal to b.
--- @param a Left operand.
--- @param b Right operand.
--- @return True if a <= b.
function core.le(a: Bint, b: Bint): boolean
	local as, bs = a.signum, b.signum
	if as < bs then return true
	elseif as > bs then return false
	end
	if as == -1 then return le_abs(b.limbs, a.limbs) end
	return le_abs(a.limbs, b.limbs)
end

--## Sign

--- Return the absolute value of a.
--- @param a The Bint.
--- @return A new Bint equal to |a|.
function core.abs(a: Bint): Bint
	local r = clone_bint(a)
	r.signum = mabs(a.signum)
	return r
end

--- Set a's sign to positive in-place and return it.
--- @param a The Bint to mutate.
--- @return a after the operation.
function core.abs_mut(a: Bint): Bint
	a.signum = mabs(a.signum)
	return a
end

--- Return the negation of a.
--- @param a The Bint.
--- @return A new Bint equal to -a.
function core.neg(a: Bint): Bint
	local r = clone_bint(a)
	r.signum = -a.signum
	return r
end

--- Negate a in-place and return it.
--- @param a The Bint to mutate.
--- @return a after negation.
function core.neg_mut(a: Bint): Bint
	a.signum = -a.signum
	return a
end

--## Add / Sub

-- Signed addition primitive. Takes raw limbs + signs; returns (result_limbs, result_sign).
-- sub(a, b) is equivalent to add_signed(al, as, bl, -bs).
local function add_signed(al: {number}, as: number, bl: {number}, bs: number): ({number}, number)
	if bs == 0 then return tclone(al), as end
	if as == 0 then return tclone(bl), bs end

	if as == bs then
		-- same effective sign: magnitudes add, sign preserved
		return add_limbs(al, bl), as
	end

	-- opposite signs: subtract the smaller magnitude from the larger
	local cmp = cmp_abs(al, bl)
	if cmp == 0 then return {}, 0 end
	if cmp > 0 then
		return sub_limbs(al, bl), as  -- |a| > |b|: result takes a's sign
	else
		return sub_limbs(bl, al), bs  -- |a| < |b|: result takes b's sign
	end
end

--- Add two Bints.
--- @param a Left operand.
--- @param b Right operand.
--- @return A new Bint equal to a + b.
function core.add(a: Bint, b: Bint): Bint
	local l, s = add_signed(a.limbs, a.signum, b.limbs, b.signum)
	return from_raw(l, s)
end

--- Subtract b from a.
--- @param a Left operand.
--- @param b Right operand.
--- @return A new Bint equal to a - b.
function core.sub(a: Bint, b: Bint): Bint
	local l, s = add_signed(a.limbs, a.signum, b.limbs, -b.signum)
	return from_raw(l, s)
end

--- Add b to a in-place.
--- Reuses a.limbs in-place for sign-matched adds and dominant-magnitude subtraction.
--- @param a The Bint to mutate.
--- @param b The value to add.
--- @return a after addition.
function core.add_mut(a: Bint, b: Bint): Bint
	local as, bs = a.signum, b.signum
	if bs == 0 then return a end
	if as == 0 then
		a.limbs = tclone(b.limbs); a.signum = bs
		return a
	end
	if as == bs then
		a.limbs = add_limbs_mut(a.limbs, b.limbs)  -- extends a.limbs in-place, no new array
		return a
	end
	local cmp = cmp_abs(a.limbs, b.limbs)
	if cmp == 0 then
		a.limbs = {}; a.signum = 0; return a
	end
	if cmp > 0 then
		sub_limbs_mut(a.limbs, b.limbs)  -- shrinks a.limbs in-place, no new array
		if #a.limbs == 0 then a.signum = 0 end
		return a
	end
	-- |a| < |b|: result comes from b's side; must allocate
	a.limbs = sub_limbs(b.limbs, a.limbs); a.signum = bs
	return a
end

--- Subtract b from a in-place.
--- @param a The Bint to mutate.
--- @param b The value to subtract.
--- @return a after subtraction.
function core.sub_mut(a: Bint, b: Bint): Bint
	local as = a.signum
	local bs = -b.signum  -- treat b as negated; b is not touched
	if bs == 0 then return a end
	if as == 0 then
		a.limbs = tclone(b.limbs); a.signum = bs
		return a
	end
	if as == bs then
		a.limbs = add_limbs_mut(a.limbs, b.limbs)
		return a
	end
	local cmp = cmp_abs(a.limbs, b.limbs)
	if cmp == 0 then
		a.limbs = {}; a.signum = 0; return a
	end
	if cmp > 0 then
		sub_limbs_mut(a.limbs, b.limbs)
		if #a.limbs == 0 then a.signum = 0 end
		return a
	end
	a.limbs = sub_limbs(b.limbs, a.limbs); a.signum = bs
	return a
end

--## Multiplication

--- Multiply two Bints.
--- @param a Left operand.
--- @param b Right operand.
--- @return A new Bint equal to a * b.
function core.mul(a: Bint, b: Bint): Bint
	local as, bs = a.signum, b.signum
	if as == 0 or bs == 0 then return make_zero() end
	local bl = b.limbs
	local res: {number}
	if #bl == 1 then
		res = mul_by_int(a.limbs, bl[1]); strip_zeros(res)
	else
		res = mul_limbs(a.limbs, bl)
	end
	return from_raw(res, as * bs)
end

--- Multiply a by b in-place.
--- The Bint table itself is reused; only the limb array is replaced.
--- @param a The Bint to mutate.
--- @param b The multiplier.
--- @return a after multiplication.
function core.mul_mut(a: Bint, b: Bint): Bint
	local as, bs = a.signum, b.signum
	if as == 0 or bs == 0 then
		a.limbs = {}; a.signum = 0; return a
	end
	local bl = b.limbs
	if #bl == 1 then
		a.limbs = mul_by_int(a.limbs, bl[1]); strip_zeros(a.limbs)
	else
		a.limbs = mul_limbs(a.limbs, bl)
	end
	a.signum = as * bs
	return a
end

-- Adjust a truncated remainder to a floor remainder.
local function correct_remainder(self_sign: number, div_sign: number, r: Bint, divisor: Bint): Bint
	if r.signum == 0 then return r end
	local same = self_sign == div_sign
	if same and div_sign == -1 then
		r.signum = -1
		return r
	elseif self_sign == 1 and div_sign == -1 then
		-- r = divisor + r
		local l, s = add_signed(divisor.limbs, divisor.signum, r.limbs, r.signum)
		r.limbs = l; r.signum = s
		return r
	elseif not same then  -- self=-1, div=+1, r_floor = r_trunc + divisor
		local l, s = add_signed(divisor.limbs, divisor.signum, r.limbs, r.signum)
		r.limbs = l; r.signum = s
		return r
	end
	return r
end

--## Floor Div

--- Compute the floor-division quotient and remainder.
--- @param a The dividend.
--- @param b The divisor.
--- @return The quotient and remainder as new Bints.
--- @raise An error on division by zero.
function core.divmod(a: Bint, b: Bint): (Bint, Bint)
	local as, bs = a.signum, b.signum
	if bs == 0 then
		error("bint: division by zero", 2)
	end

	if as == 0 then return make_zero(), make_zero() end

	local U, V = a.limbs, b.limbs
	local cmp = cmp_abs(U, V)

	if cmp == -1 then
		-- |a| < |b|: quotient is 0 or ±1 with floor correction
		-- both mixed-sign cases reduce to remainder = b + a
		if as == 1 and bs == -1 or as == -1 and bs == 1 then
			local rl, rs = add_signed(b.limbs, b.signum, a.limbs, a.signum)
			return from_raw({1}, -1), from_raw(rl, rs)
		end
		-- same sign: quotient=0, remainder=a
		return make_zero(), clone_bint(a)
	elseif cmp == 0 then
		-- |a| == |b|
		local q = from_raw({1}, floor(as / bs))
		return q, make_zero()
	end

	-- general case: |a| > |b|
	local q_limbs, r_limbs: {number}
	if #V == 1 then
		q_limbs, r_limbs = div_by_int(U, V[1])
	else
		q_limbs, r_limbs = div_limbs(U, V)
	end

	local q = from_raw(q_limbs, as * bs > 0 and 1 or -1)
	local r = from_raw(r_limbs, as)  -- initial sign of remainder = sign of dividend

	-- floor correction
	r = correct_remainder(as, bs, r, b)
	if as ~= bs and r.signum ~= 0 then
		-- floor: push quotient one further toward −∞
		q.limbs = add_limbs_mut(q.limbs, {1})
		strip_zeros(q.limbs)
	end
	q.signum = as * bs > 0 and 1 or -1

	return q, r
end

--- Compute the floor-division quotient.
--- @param a The dividend.
--- @param b The divisor.
--- @return The quotient, a new Bint.
function core.idiv(a: Bint, b: Bint): Bint
	local q, _ = core.divmod(a, b)
	return q
end

--- Compute the floor-division remainder.
--- @param a The dividend.
--- @param b The divisor.
--- @return The remainder, a new Bint.
function core.mod(a: Bint, b: Bint): Bint
	local _, r = core.divmod(a, b)
	return r
end

--- Compute the truncated-division quotient.
--- @param a The dividend.
--- @param b The divisor.
--- @return The quotient, a new Bint.
function core.tdiv(a: Bint, b: Bint): Bint
	local q, _ = core.tdivmod(a, b)
	return q
end

--- Compute the truncated-division remainder.
--- @param a The dividend.
--- @param b The divisor.
--- @return The remainder, a new Bint.
function core.tmod(a: Bint, b: Bint): Bint
	local _, r = core.tdivmod(a, b)
	return r
end

--## Trunc Div

--- Compute the truncated-division quotient and remainder.
--- The quotient rounds toward zero.
--- @param a The dividend.
--- @param b The divisor.
--- @return The quotient and remainder as new Bints.
--- @raise An error on division by zero.
function core.tdivmod(a: Bint, b: Bint): (Bint, Bint)
	local as, bs = a.signum, b.signum
	if bs == 0 then
		error("bint: division by zero", 2)
	end

	if as == 0 then return make_zero(), make_zero() end

	local U, V = a.limbs, b.limbs
	local cmp = cmp_abs(U, V)

	if cmp == -1 then
		return make_zero(), clone_bint(a)
	elseif cmp == 0 then
		return from_raw({1}, as * bs > 0 and 1 or -1), make_zero()
	end

	local q_limbs, r_limbs: {number}
	if #V == 1 then
		q_limbs, r_limbs = div_by_int(U, V[1])
	else
		q_limbs, r_limbs = div_limbs(U, V)
	end

	-- truncated: quotient sign = sign(a)*sign(b), remainder sign = sign(a)
	local q_sign = as * bs > 0 and 1 or -1
	return from_raw(q_limbs, q_sign), from_raw(r_limbs, as)
end

--- Raise a to the power b.
--- @param a The base.
--- @param b The exponent, must be a non-negative Bint.
--- @return A new Bint equal to a ^ b.
--- @raise An error if b is negative.
function core.pow(a: Bint, b: Bint): Bint
	local as, bs = a.signum, b.signum
	local bl = b.limbs

	if bs == 0 then return from_raw({1}, 1) end -- x^0 = 1
	if bs < 0 then
		error("bint.pow: negative exponent is not supported for integers", 2)
	end
	if as == 0 then return make_zero() end

	local odd_exp = #bl > 0 and bl[1] % 2 == 1

	-- base = ±1 fast path
	if #a.limbs == 1 and a.limbs[1] == 1 then
		local unit = from_raw({1}, 1)
		if as == -1 and odd_exp then unit.signum = -1 end
		return unit
	end

	local res_limbs: {number}
	if #bl == 1 then
		res_limbs = pow_by_int(a.limbs, bl[1])
	else
		res_limbs = pow_limbs(a.limbs, tclone(bl))  -- clone: pow_limbs mutates
	end

	local res = from_raw(res_limbs, 1)
	if as == -1 and odd_exp then res.signum = -1 end
	return res
end

--- Compute the integer square root of a.
--- @param a The Bint.
--- @return A new Bint equal to floor(sqrt(a)), or zero for non-positive inputs.
function core.sqrt(a: Bint): Bint
	if a.signum ~= 1 then return make_zero() end
	return from_raw(sqrt_limbs(a.limbs), 1)
end

--## Bit / Word Shifts

-- Shift an unsigned magnitude right by n bits.
-- Returns (quotient_limbs, had_remainder) where had_remainder indicates any dropped 1 bits.
local function rshift_limbs_with_remainder(limbs: {number}, n: number): ({number}, boolean)
	if n == 0 then
		return tclone(limbs), false
	end

	local len = #limbs
	local word_shift = n // BASE_POW
	if word_shift >= len then
		return {}, len > 0
	end

	local bit_shift = n % BASE_POW
	local out_len = len - word_shift
	local out = tcreate(out_len, 0)
	local had_remainder = false

	for i = 1, word_shift do
		if limbs[i] ~= 0 then
			had_remainder = true
			break
		end
	end

	local start = word_shift + 1
	if bit_shift == 0 then
		out = tmove(limbs, start, len, 1, out)
		strip_zeros(out)
		return out, had_remainder
	end

	local divisor = 2 ^ bit_shift
	local carry_scale = 2 ^ (BASE_POW - bit_shift)
	local carry = 0
	for src = len, start, -1 do
		local x = limbs[src]
		out[src - word_shift] = floor(x / divisor) + carry * carry_scale
		carry = x % divisor
	end
	if carry ~= 0 then
		had_remainder = true
	end

	strip_zeros(out)
	return out, had_remainder
end

--- Shift a left by n bits.
--- Equivalent to multiplication by `2^n`.
--- @param a The Bint to shift.
--- @param n Number of bits to shift left (unsafe core contract: caller provides an integer >= 0).
--- @return A new Bint.
function core.lshift(a: Bint, n: number): Bint
	if n == 0 then return clone_bint(a) end
	if a.signum == 0 then return make_zero() end

	local word_shift = n // BASE_POW
	local bit_shift = n % BASE_POW
	if bit_shift == 0 then
		return core.lshift_words(a, word_shift)
	end

	local factor = 2 ^ bit_shift
	local limbs = a.limbs
	local out = tcreate(#limbs + word_shift + 1, 0)
	local carry = 0
	for i, limb in limbs do
		local x = limb * factor + carry
		out[i + word_shift] = x % BASE
		carry = floor(x / BASE)
	end
	if carry ~= 0 then
		out[#limbs + word_shift + 1] = carry
	end
	return from_raw(out, a.signum)
end

--- Shift a right by n bits using arithmetic (sign-preserving) semantics.
--- Equivalent to floor division by `2^n`.
--- @param a The Bint to shift.
--- @param n Number of bits to shift right (unsafe core contract: caller provides an integer >= 0).
--- @return A new Bint.
function core.rshift(a: Bint, n: number): Bint
	if n == 0 then return clone_bint(a) end
	if a.signum == 0 then return make_zero() end

	local q_limbs, had_remainder = rshift_limbs_with_remainder(a.limbs, n)
	if a.signum == 1 then
		return from_raw(q_limbs, 1)
	end

	-- For negative numbers, arithmetic right shift is floor(a / 2^n) = -ceil(|a| / 2^n).
	if had_remainder then
		q_limbs = add_limbs_mut(q_limbs, {1})
	end
	return from_raw(q_limbs, -1)
end

--- Shift a left by n words.
--- @param a The Bint to shift.
--- @param n Number of limbs to shift left.
--- @return A new Bint.
function core.lshift_words(a: Bint, n: number): Bint
	if a.signum == 0 then return make_zero() end
	return from_raw(lshift_limbs(a.limbs, n), a.signum)
end

--- Shift a right by n words.
--- @param a The Bint to shift.
--- @param n Number of limbs to shift right.
--- @return A new Bint.
function core.rshift_words(a: Bint, n: number): Bint
	if a.signum == 0 or n >= #a.limbs then return make_zero() end
	return from_raw(tmove(a.limbs, n + 1, #a.limbs, 1, {}), a.signum)
end

--# BASE CONVERSION

local BASE_LETTERS = {}
do
	for i = 0,  9 do BASE_LETTERS[i] = tostring(i) end
	for i = 0, 25 do BASE_LETTERS[10 + i] = schar(97 + i) end
end

--- Convert a Bint to a string.
--- @param a The Bint to convert.
--- @param[opt] base The numeric base (2–36). Defaults to 10.
--- @return A string representation.
--- @raise An error if base is out of range.
function bint.to_string(a: Bint, base: number?): string
	local b = base or 10
	if b < 2 or b > 36 or floor(b) ~= b then
		error("bint.to_string: base must be an integer in 2–36", 2)
	end

	if a.signum == 0 then return "0" end

	local prefix = a.signum == -1 and "-" or ""
	local limbs = a.limbs

	if b == 10 then
		-- Chunked base-2^24 → 10^8 conversion.
		local clone = tclone(limbs)
		local chunk_count = ceil(#clone * log10(BASE) / floor(log10(RADIX_CHUNK)))
		local chunks: {string} = tcreate(chunk_count, "") :: {string}
		local idx = chunk_count
		while #clone > 0 do
			local carry = 0
			for i = #clone, 1, -1 do
				local val = clone[i] + carry * BASE
				carry = val % RADIX_CHUNK
				clone[i] = floor(val / RADIX_CHUNK)
			end
			chunks[idx] = sformat("%08d", carry)
			idx -= 1
			while true do
				local n = #clone
				if n == 0 or clone[n] ~= 0 then break end
				clone[n] = nil
			end
		end
		-- remove leading zeros from the first chunk
		local str = tconcat(chunks):gsub("^0+", "")
		return prefix .. str
	else
		-- Digit-at-a-time extraction.
		local clone = tclone(limbs)
		local digits: {string} = {}
		while #clone > 0 do
			local _, rem = div_by_int(clone, b, true)
			local d = #rem > 0 and rem[1] or 0
			tinsert(digits, 1, BASE_LETTERS[d])
		end
		if #digits == 0 then digits = {"0"} end
		return prefix .. tconcat(digits)
	end
end

--# BYTES
-- Magnitude-only (sign not encoded). 24-bit limbs → 3 bytes each.

--- Serialize a Bint to a little-endian byte string.
--- Encodes magnitude only; the sign is not stored.
--- @param a The Bint to serialize.
--- @param[opt] trim If true, trailing zero bytes are stripped.
--- @return A string of bytes.
--- @see bint.from_le
function bint.to_le(a: Bint, trim: boolean?): string
	local limbs = a.limbs
	local parts: {string} = tcreate(#limbs, "") :: {string}
	for i, limb in limbs do
		parts[i] = schar(limb % 256, floor(limb / 256) % 256, floor(limb / 65536) % 256)
	end
	local result = tconcat(parts)
	if trim then
		local i = #result
		while i > 0 and sbyte(result, i) == 0 do
			i -= 1
		end
		result = ssub(result, 1, i)
	end
	return result
end

--- Serialize a Bint to a big-endian byte string.
--- Encodes magnitude only; the sign is not stored.
--- @param a The Bint to serialize.
--- @param[opt] trim If true, leading zero bytes are stripped.
--- @return A string of bytes.
--- @see bint.from_be
function bint.to_be(a: Bint, trim: boolean?): string
	return sreverse(bint.to_le(a, trim))
end

-- Shared implementation for from_le/from_be (caller reverses if needed).
local function fromle_bytes(s: string): Bint
	local n = slen(s)
	local limbs: {number} = {}
	for i = 1, n, 3 do
		local b0 = sbyte(s, i)     or 0
		local b1 = sbyte(s, i + 1) or 0
		local b2 = sbyte(s, i + 2) or 0
		tinsert(limbs, b0 + b1 * 256 + b2 * 65536)
	end
	strip_zeros(limbs)
	local sign = #limbs > 0 and 1 or 0
	return setmetatable({ limbs = limbs, signum = sign }, Bint) :: Bint
end

--- Create a new Bint from a little-endian byte string.
--- @param s A string of bytes representing the magnitude.
--- @return A new Bint.
--- @raise An error if s is not a string.
--- @see bint.to_le
function bint.from_le(s: string): Bint
	if type(s) ~= "string" then
		error("bint.from_le: expected string", 2)
	end
	return fromle_bytes(s)
end

--- Create a new Bint from a big-endian byte string.
--- @param s A string of bytes representing the magnitude.
--- @return A new Bint.
--- @raise An error if s is not a string.
--- @see bint.to_be
function bint.from_be(s: string): Bint
	if type(s) ~= "string" then
		error("bint.from_be: expected string", 2)
	end
	return fromle_bytes(sreverse(s))
end

--- Convert a Bint to a lua number.
--- Exact for magnitudes up to 2^53; larger values lose precision.
--- @param a The Bint to convert.
--- @return A lua number.
function bint.to_number(a: Bint): number
	if a.signum == 0 then return 0 end
	local limbs = a.limbs
	local n = #limbs
	-- 1-2 limbs: max = 2^48-1 < 2^53, always exact
	if n <= 2 then
		return a.signum * ((limbs[2] or 0) * BASE + limbs[1])
	end
	-- 3 limbs: check precision boundary before committing to direct computation
	if n == 3 then
		local val = limbs[3] * (BASE * BASE) + limbs[2] * BASE + limbs[1]
		if val <= 9007199254740992 then  -- 2^53
			return a.signum * val
		end
	end
	-- 4+ limbs or 3-limb overflow: fall back to string (precision loss)
	return tonumber(bint.to_string(a)) :: number
end

--- Decompose a Bint into lossy scientific notation: coefficient × 10^exponent.
--- O(1), no allocation. 1 ≤ |coefficient| < 10 (0 for zero).
--- @param a The Bint to decompose.
--- @return coefficient A lua number in (-10, -1] ∪ {0} ∪ [1, 10).
--- @return exponent A non-negative integer.
function bint.to_sci(a: Bint): (number, number)
	if a.signum == 0 then return 0, 0 end
	local limbs = a.limbs
	local n = #limbs
	local approx = limbs[n]
	if n >= 2 then approx = approx * BASE + limbs[n - 1] end
	if n >= 3 then approx = approx * BASE + limbs[n - 2] end
	local log10_val = log10(approx) + (n - math.min(n, 3)) * RADIX_LEN_K
	local exp = floor(log10_val)
	local coeff = 10 ^ (log10_val - exp)
	return a.signum * coeff, exp
end

--# METATABLE
-- Thin wrappers over core; coerces both sides of each operator.

--- Add two values.
--- @param a A BintArg.
--- @param b A BintArg.
--- @return A new Bint equal to a + b.
Bint.__add = function(a: BintArg, b: BintArg): Bint
	return core.add(coerce(a), coerce(b))
end

--- Subtract b from a.
--- @param a A BintArg.
--- @param b A BintArg.
--- @return A new Bint equal to a - b.
Bint.__sub = function(a: BintArg, b: BintArg): Bint
	return core.sub(coerce(a), coerce(b))
end

--- Multiply two values.
--- @param a A BintArg.
--- @param b A BintArg.
--- @return A new Bint equal to a * b.
Bint.__mul = function(a: BintArg, b: BintArg): Bint
	return core.mul(coerce(a), coerce(b))
end

--- Perform floor integer division.
--- @param a A BintArg.
--- @param b A BintArg.
--- @return A new Bint equal to a // b.
Bint.__idiv = function(a: BintArg, b: BintArg): Bint
	return core.idiv(coerce(a), coerce(b))
end

-- Bint is integer-only; '/' has no meaningful fractional behaviour.
-- Error explicitly so callers are forced to use '//' intentionally.
Bint.__div = function(): never
	error("bint: '/' is not supported for integers; use '//' for floor division", 2)
end

--- Compute the floor-division remainder.
--- @param a A BintArg.
--- @param b A BintArg.
--- @return A new Bint equal to a % b.
Bint.__mod = function(a: BintArg, b: BintArg): Bint
	return core.mod(coerce(a), coerce(b))
end

--- Raise a to the power b.
--- @param a A BintArg.
--- @param b A BintArg.
--- @return A new Bint equal to a ^ b.
Bint.__pow = function(a: BintArg, b: BintArg): Bint
	return core.pow(coerce(a), coerce(b))
end

--- Negate a.
--- @param a A BintArg.
--- @return A new Bint equal to -a.
Bint.__unm = function(a: BintArg): Bint
	return core.neg(coerce(a))
end

--- Test two values for equality.
--- @param a A BintArg.
--- @param b A BintArg.
--- @return True if a == b.
Bint.__eq = function(a: BintArg, b: BintArg): boolean
	return core.eq(coerce(a), coerce(b))
end

--- Test if a is strictly less than b.
--- @param a A BintArg.
--- @param b A BintArg.
--- @return True if a < b.
Bint.__lt = function(a: BintArg, b: BintArg): boolean
	return core.lt(coerce(a), coerce(b))
end

--- Test if a is less than or equal to b.
--- @param a A BintArg.
--- @param b A BintArg.
--- @return True if a <= b.
Bint.__le = function(a: BintArg, b: BintArg): boolean
	return core.le(coerce(a), coerce(b))
end

--- Convert to a decimal string.
--- @see bint.to_string
Bint.__tostring = function(a: Bint): string
	return bint.to_string(a)
end

--- Return the number of decimal digits (metamethod for #).
--- @param a The Bint.
--- @return The number of decimal digits, or 0 for zero.
Bint.__len = function(a: Bint): number
	if a.signum == 0 then return 0 end
	local limbs = a.limbs
	local digits = floor(log10(limbs[#limbs]) + (#limbs - 1) * RADIX_LEN_K) + 1
	if digits < 1 then digits = 1 end

	-- Exact correction: the estimate can be off by one near decimal boundaries
	-- (and due to floating-point rounding). Compare against 10^(digits-1) / 10^digits.
	while digits > 1 and cmp_abs(limbs, seek_pow10_limbs(digits - 1)) < 0 do
		digits -= 1
	end
	while cmp_abs(limbs, seek_pow10_limbs(digits)) >= 0 do
		digits += 1
	end
	return digits
end

-- Convenience methods callable on Bint instances.
Bint.clone    = clone_bint
Bint.abs      = core.abs
Bint.neg      = core.neg
Bint.cmp = function(self: Bint, other: BintArg): number
	return core.cmp(self, coerce(other))
end
Bint.eq = function(self: Bint, other: BintArg): boolean
	return core.eq(self, coerce(other))
end
Bint.lt = function(self: Bint, other: BintArg): boolean
	return core.lt(self, coerce(other))
end
Bint.le = function(self: Bint, other: BintArg): boolean
	return core.le(self, coerce(other))
end
Bint.add = function(self: Bint, other: BintArg): Bint
	return core.add(self, coerce(other))
end
Bint.sub = function(self: Bint, other: BintArg): Bint
	return core.sub(self, coerce(other))
end
Bint.mul = function(self: Bint, other: BintArg): Bint
	return core.mul(self, coerce(other))
end
Bint.divmod = function(self: Bint, other: BintArg): (Bint, Bint)
	return core.divmod(self, coerce(other))
end
Bint.idiv = function(self: Bint, other: BintArg): Bint
	return core.idiv(self, coerce(other))
end
Bint.mod = function(self: Bint, other: BintArg): Bint
	return core.mod(self, coerce(other))
end
Bint.tdivmod = function(self: Bint, other: BintArg): (Bint, Bint)
	return core.tdivmod(self, coerce(other))
end
Bint.tdiv = function(self: Bint, other: BintArg): Bint
	return core.tdiv(self, coerce(other))
end
Bint.tmod = function(self: Bint, other: BintArg): Bint
	return core.tmod(self, coerce(other))
end
Bint.pow = function(self: Bint, other: BintArg): Bint
	return core.pow(self, coerce(other))
end
Bint.sqrt			= core.sqrt
Bint.lshift			= core.lshift
Bint.rshift			= core.rshift
Bint.lshift_words	= core.lshift_words
Bint.rshift_words	= core.rshift_words
Bint.to_string		= bint.to_string
Bint.to_number		= bint.to_number
Bint.to_sci			= bint.to_sci
Bint.to_le			= bint.to_le
Bint.to_be			= bint.to_be

--# ALGORITHMS
-- Direct algorithm entry points. Each function has the same contract as its core.* counterpart
-- (same sign handling, error conditions, and floor/isqrt semantics) but bypasses the automatic
-- threshold dispatch at the top-level entry point.
-- Use these for benchmarking threshold crossover points and for validating the named
-- top-level algorithm entry path. Recursive subproblems may still dispatch/fallback
-- internally based on thresholds (see per-wrapper notes).

-- Shared floor-division preamble used by div_knuth and div_burnikel.
-- Mirrors core.divmod exactly; raw_div replaces the div_limbs dispatch call.
local function divmod_with(a: Bint, b: Bint, raw_div: ({number}, {number}) -> ({number}, {number})): (Bint, Bint)
	local as, bs = a.signum, b.signum
	if bs == 0 then
		error("bint: division by zero", 2)
	end
	if as == 0 then return make_zero(), make_zero() end
	local U, V = a.limbs, b.limbs
	local cmp = cmp_abs(U, V)
	if cmp == -1 then
		if as == 1 and bs == -1 or as == -1 and bs == 1 then
			local rl, rs = add_signed(b.limbs, b.signum, a.limbs, a.signum)
			return from_raw({1}, -1), from_raw(rl, rs)
		end
		return make_zero(), clone_bint(a)
	elseif cmp == 0 then
		return from_raw({1}, floor(as / bs)), make_zero()
	end
	local q_limbs, r_limbs = raw_div(U, V)
	local q = from_raw(q_limbs, as * bs > 0 and 1 or -1)
	local r = from_raw(r_limbs, as)
	r = correct_remainder(as, bs, r, b)
	if as ~= bs and r.signum ~= 0 then
		q.limbs = add_limbs_mut(q.limbs, {1})
		strip_zeros(q.limbs)
	end
	q.signum = as * bs > 0 and 1 or -1
	return q, r
end

-- Shared sign wrapper for multiplication algorithms.
local function mul_wrap(a: Bint, b: Bint, limb_fn: ({number}, {number}) -> {number}): Bint
	local as, bs = a.signum, b.signum
	if as == 0 or bs == 0 then return make_zero() end
	return from_raw(limb_fn(a.limbs, b.limbs), as * bs > 0 and 1 or -1)
end

local algorithms = {}

--- Multiply using schoolbook O(n²) algorithm, regardless of operand size.
function algorithms.mul_basecase(a: Bint, b: Bint): Bint
	return mul_wrap(a, b, mul_limbs_basecase)
end

--- Multiply using Karatsuba O(n^1.585) algorithm at the top level, regardless of operand size.
--- Recursive sub-problems are dispatched through mul_limbs and may use basecase internally.
function algorithms.mul_karatsuba(a: Bint, b: Bint): Bint
	return mul_wrap(a, b, mul_limbs_karatsuba)
end

--- Multiply using Toom-Cook 3-way O(n^1.465) algorithm at the top level, regardless of operand size.
--- Recursive sub-problems are dispatched through mul_limbs and may use basecase or Karatsuba internally.
function algorithms.mul_toom3(a: Bint, b: Bint): Bint
	return mul_wrap(a, b, mul_limbs_toom3)
end

--- Floor-divide using Knuth Algorithm D, regardless of operand size.
function algorithms.div_knuth(a: Bint, b: Bint): (Bint, Bint)
	return divmod_with(a, b, div_knuths)
end

--- Floor-divide using the Burnikel-Ziegler outer driver, regardless of operand size.
--- Note: div_burnikel falls back to Knuth when the divisor is below BURNIKEL_THR limbs.
function algorithms.div_burnikel(a: Bint, b: Bint): (Bint, Bint)
	return divmod_with(a, b, div_burnikel)
end

--- Compute the integer square root using Newton-Heron iteration, regardless of operand size.
function algorithms.sqrt_newton(a: Bint): Bint
	if a.signum ~= 1 then return make_zero() end
	return from_raw(sqrt_newton(a.limbs), 1)
end

--- Compute the integer square root using the Karatsuba-recursive algorithm, regardless of size.
--- Note: sqrt_karatsuba falls back to Newton for inputs below SQRT_KAR_THR limbs.
function algorithms.sqrt_karatsuba(a: Bint): Bint
	if a.signum ~= 1 then return make_zero() end
	local s, _ = sqrt_karatsuba(a.limbs)
	return from_raw(s, 1)
end

--# API

-- Make `bint(v)` an alias for `bint.new(v)`.
setmetatable(bint, { __call = function(_, v: BintArg): Bint
	return bint.new(v)
end })

return {
	bint = bint,
	core = core,
	algorithms = algorithms,
}
