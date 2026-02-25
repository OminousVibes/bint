--!nocheck
--!nolint IntegerParsing

return function(t)
	local describe, it, expect = t.describe, t.it, t.expect
	local mod = require("../src")
	local bint = mod.bint
	local core = mod.core
	local algorithms = mod.algorithms
	local BASE = 2 ^ 24
	local TAG_FAST = {"fast", "full", "stress"}
	local TAG_FULL = {"full", "stress"}
	local TAG_STRESS = {"stress"}

	local function S(x)
		return bint.tostring(x)
	end

	local function _B(v)
		return bint.new(v)
	end

	local function N(n)
		if n == 0 then
			return "0"
		end
		return tostring(n)
	end

	local function floor_div(a, b)
		return math.floor(a / b)
	end

	local function floor_mod(a, b)
		return a - b * floor_div(a, b)
	end

	local function trunc_div(a, b)
		local q = a / b
		if q >= 0 then
			return math.floor(q)
		end
		return math.ceil(q)
	end

	local function trunc_mod(a, b)
		return a - b * trunc_div(a, b)
	end

	local function expect_shift_matches_safe_number(a, n)
		local p2 = 2 ^ n
		local l_expected = a * p2
		local r_expected = math.floor(a / p2)
		local x = bint.from_int(a)

		expect(S(core.lshift(x, n))).to.equal(N(l_expected))
		expect(S(core.rshift(x, n))).to.equal(N(r_expected))
		expect(S(x:lshift(n))).to.equal(N(l_expected))
		expect(S(x:rshift(n))).to.equal(N(r_expected))
	end

	local seed = 0x13579BDF
	local function rnd()
		seed = (1103515245 * seed + 12345) % 2147483648
		return seed
	end

	local function randint(lo, hi)
		return lo + (rnd() % (hi - lo + 1))
	end

	local function rand_decimal(max_digits)
		if randint(0, 9) == 0 then
			return "0"
		end

		local digits = randint(1, max_digits)
		local chars = table.create(digits)
		chars[1] = tostring(randint(1, 9))
		for i = 2, digits do
			chars[i] = tostring(randint(0, 9))
		end

		local s = table.concat(chars)
		if randint(0, 1) == 1 then
			s = "-" .. s
		end
		return s
	end

	local function make_limbs(len, seed_value)
		local limbs = table.create(len)
		local x = seed_value % BASE
		if x == 0 then
			x = 1
		end

		for i = 1, len do
			x = (x * 48271 + i * 97 + 13) % BASE
			limbs[i] = x
		end

		if len > 0 and limbs[len] == 0 then
			limbs[len] = 1
		end
		return limbs
	end

	local function make_big(len, seed_value, sign)
		return bint.from_limbs(make_limbs(len, seed_value), sign or 1)
	end

	local function expect_floor_remainder_range(r, b)
		if b.signum == 1 then
			expect(core.le(bint.zero(), r)).to.equal(true)
			expect(core.lt(r, b)).to.equal(true)
		else
			expect(core.lt(b, r)).to.equal(true)
			expect(core.le(r, bint.zero())).to.equal(true)
		end
	end

	local function expect_trunc_remainder_range(r, a, b)
		if r.signum ~= 0 then
			expect(r.signum).to.equal(a.signum)
		end
		expect(core.lt(core.abs(r), core.abs(b))).to.equal(true)
	end

	local function expect_floor_divmod_invariants(a, b)
		local q, r = core.divmod(a, b)
		expect(S(core.add(core.mul(q, b), r))).to.equal(S(a))
		expect_floor_remainder_range(r, b)
		return q, r
	end

	local function expect_trunc_divmod_invariants(a, b)
		local q, r = core.tdivmod(a, b)
		expect(S(core.add(core.mul(q, b), r))).to.equal(S(a))
		expect_trunc_remainder_range(r, a, b)
		return q, r
	end

	local function naive_mul(a, b)
		if a.signum == 0 or b.signum == 0 then
			return bint.zero()
		end

		local al, bl = a.limbs, b.limbs
		local out = table.create(#al + #bl + 1, 0)

		for i = 1, #al do
			local carry = 0
			local ai = al[i]
			for j = 1, #bl do
				local idx = i + j - 1
				local p = out[idx] + ai * bl[j] + carry
				out[idx] = p % BASE
				carry = math.floor(p / BASE)
			end

			local k = i + #bl
			while carry > 0 do
				local p = out[k] + carry
				out[k] = p % BASE
				carry = math.floor(p / BASE)
				k += 1
			end
		end

		while #out > 0 and out[#out] == 0 do
			out[#out] = nil
		end

		local sign = a.signum * b.signum
		return bint.from_limbs(out, sign)
	end

	describe("bint comprehensive", function()
		--## Constructors and validation
		describe.tags(TAG_FAST, "constructors and validation", function()
			it("from_int should handle regular signed values", function()
				expect(S(bint.from_int(0))).to.equal("0")
				expect(S(bint.from_int(1))).to.equal("1")
				expect(S(bint.from_int(-1))).to.equal("-1")
				expect(S(bint.from_int(16777216))).to.equal("16777216")
				
				local n = -123456789
				expect(S(bint.from_int(n))).to.equal(N(n))
			end)

			it("from_int should reject non-integers and infinities", function()
				expect(function()
					bint.from_int(1.5)
				end).to.throw()
				expect(function()
					bint.from_int(0 / 0)
				end).to.throw()
				expect(function()
					bint.from_int(math.huge)
				end).to.throw()
				expect(function()
					bint.from_int(-math.huge)
				end).to.throw()
			end)

			it("from_string should canonicalize leading zeros and signed zero", function()
				expect(S(bint.from_string("0000"))).to.equal("0")
				expect(S(bint.from_string("-0"))).to.equal("0")
				expect(S(bint.from_string("000123"))).to.equal("123")
				expect(S(bint.from_string("-000123"))).to.equal("-123")
			end)

			it("from_string should parse multiple bases and cases", function()
				expect(S(bint.from_string("101010", 2))).to.equal("42")
				expect(S(bint.from_string("-101010", 2))).to.equal("-42")
				expect(S(bint.from_string("ff", 16))).to.equal("255")
				expect(S(bint.from_string("FF", 16))).to.equal("255")
				expect(S(bint.from_string("z", 36))).to.equal("35")
				expect(S(bint.from_string("Z", 36))).to.equal("35")
			end)

			it("from_string should reject malformed and out-of-range inputs", function()
				expect(function()
					bint.from_string("")
				end).to.throw()
				expect(function()
					bint.from_string("-")
				end).to.throw()
				expect(function()
					bint.from_string("12x", 10)
				end).to.throw()
				expect(function()
					bint.from_string("2", 2)
				end).to.throw()
				expect(function()
					bint.from_string("10", 1)
				end).to.throw()
				expect(function()
					bint.from_string("10", 37)
				end).to.throw()
			end)

			it("from_limbs should normalize trailing zeros and enforce bounds", function()
				expect(S(bint.from_limbs({ 1, 0, 0 }))).to.equal("1")
				expect(S(bint.from_limbs({ 0, 0, 0 }))).to.equal("0")
				expect(S(bint.from_limbs({ 1 }, -1))).to.equal("-1")

				expect(function()
					bint.from_limbs({ 1 }, 0)
				end).to.throw()
				expect(function()
					bint.from_limbs({ -1 }, 1)
				end).to.throw()
				expect(function()
					bint.from_limbs({ 1.25 }, 1)
				end).to.throw()
				expect(function()
					bint.from_limbs({ 16777216 }, 1)
				end).to.throw()
				expect(function()
					bint.from_limbs({ 1 }, 2)
				end).to.throw()
			end)

			it("from_limbs should copy caller input and normalize signed zero", function()
				local limbs = { 1, 2, 3 }
				local x = bint.from_limbs(limbs, 1)
				limbs[1] = 99
				limbs[4] = 4

				expect(x.limbs[1]).to.equal(1)
				expect(#x.limbs).to.equal(3)

				local z = bint.from_limbs({ 0, 0 }, -1)
				expect(S(z)).to.equal("0")
				expect(z.signum).to.equal(0)
			end)

			it("new/call should convert and clone bint inputs", function()
				local a = bint("99")
				local cloned = bint.new(a)
				core.add_mut(a, bint.one())

				expect(S(a)).to.equal("100")
				expect(S(cloned)).to.equal("99")
				expect(S(bint("42"))).to.equal("42")
				expect(function()
					bint.new(true)
				end).to.throw()
			end)
		end)

		--## Comparison and sign helpers
		describe.tags(TAG_FAST, "comparison and sign helpers", function()
			it("cmp/eq/lt/le should match native integer ordering on a dense grid", function()
				for a = -40, 40 do
					for b = -40, 40 do
						local A, Bv = bint.from_int(a), bint.from_int(b)
						local cmp = 0
						if a < b then
							cmp = -1
						elseif a > b then
							cmp = 1
						end

						expect(core.cmp(A, Bv)).to.equal(cmp)
						expect(core.eq(A, Bv)).to.equal(a == b)
						expect(core.lt(A, Bv)).to.equal(a < b)
						expect(core.le(A, Bv)).to.equal(a <= b)
					end
				end
			end)

			it("abs/neg and mutating variants should produce expected signs", function()
				local a = bint("-123")
				expect(S(core.abs(a))).to.equal("123")
				expect(S(core.neg(a))).to.equal("123")
				expect(S(a)).to.equal("-123")

				local b = bint("-7")
				core.abs_mut(b)
				expect(S(b)).to.equal("7")
				core.neg_mut(b)
				expect(S(b)).to.equal("-7")
			end)

			it("metamethod arithmetic should coerce strings and numbers", function()
				expect(S(bint("2") + 3)).to.equal("5")
				expect(S(bint("10") - "7")).to.equal("3")
				expect(S(bint("6") * "7")).to.equal("42")
				expect(S(bint("20") // "3")).to.equal("6")
				expect(S(bint("20") % "3")).to.equal("2")
				expect(S(-bint("5"))).to.equal("-5")
			end)

				it("instance methods should support divmod/tdivmod/pow coercion and chaining", function()
					local a = bint("20")
					local q, r = a:divmod("6")
					expect(S(q)).to.equal("3")
					expect(S(r)).to.equal("2")

				local tq, tr = bint("-20"):tdivmod(6)
				expect(S(tq)).to.equal("-3")
				expect(S(tr)).to.equal("-2")

				expect(S(bint("5"):pow("3"))).to.equal("125")

				local m = bint("-10"):abs():add("5"):mul(2):neg()
				expect(S(m)).to.equal("-30")
				expect(S(m:lshift_words(1):rshift_words(1))).to.equal("-30")
			end)

			it("instance methods should be non-mutating and not expose mut variants", function()
				local a = bint("-10")
				local original = S(a)

				expect(S(a:abs())).to.equal("10")
				expect(S(a:add(5))).to.equal("-5")
				expect(S(a:sub("2"))).to.equal("-12")
				expect(S(a:mul(-3))).to.equal("30")
				expect(S(a)).to.equal(original)

				expect(a.abs_mut).to.equal(nil)
				expect(a.neg_mut).to.equal(nil)
				expect(a.add_mut).to.equal(nil)
				expect(a.sub_mut).to.equal(nil)
				expect(a.mul_mut).to.equal(nil)
			end)

			it("__len should return decimal digit count of magnitude", function()
				expect(#bint("0")).to.equal(0)
				expect(#bint("9")).to.equal(1)
				expect(#bint("10")).to.equal(2)
				expect(#bint("999")).to.equal(3)
				expect(#bint("-1000")).to.equal(4)
				expect(#bint("12345678901234567890")).to.equal(20)
			end)
		end)

		--## Core arithmetic
		describe.tags(TAG_FULL, "core arithmetic", function()
			it("add/sub/mul should match native math on dense small integers", function()
				for a = -60, 60 do
					for b = -60, 60 do
						local A, Bv = bint.from_int(a), bint.from_int(b)
						expect(S(A + Bv)).to.equal(N(a + b))
						expect(S(A - Bv)).to.equal(N(a - b))
						expect(S(A * Bv)).to.equal(N(a * b))
					end
				end
			end)

			it("add_mut/sub_mut/mul_mut should match non-mutating forms and not touch rhs", function()
				local cases = {
					{ "1", "16777216" },
					{ "-999999", "123456" },
					{ "123456789012345", "-987654321" },
					{ "0", "42" },
				}

				for _, c in ipairs(cases) do
					local sa, sb = c[1], c[2]

					local a1, b1 = bint(sa), bint(sb)
					local expectedAdd = core.add(bint(sa), bint(sb))
					local bBefore = S(b1)
					local gotAdd = core.add_mut(a1, b1)
					expect(S(gotAdd)).to.equal(S(expectedAdd))
					expect(S(a1)).to.equal(S(expectedAdd))
					expect(S(b1)).to.equal(bBefore)

					local a2, b2 = bint(sa), bint(sb)
					local expectedSub = core.sub(bint(sa), bint(sb))
					bBefore = S(b2)
					local gotSub = core.sub_mut(a2, b2)
					expect(S(gotSub)).to.equal(S(expectedSub))
					expect(S(a2)).to.equal(S(expectedSub))
					expect(S(b2)).to.equal(bBefore)

					local a3, b3 = bint(sa), bint(sb)
					local expectedMul = core.mul(bint(sa), bint(sb))
					bBefore = S(b3)
					local gotMul = core.mul_mut(a3, b3)
					expect(S(gotMul)).to.equal(S(expectedMul))
					expect(S(a3)).to.equal(S(expectedMul))
					expect(S(b3)).to.equal(bBefore)
				end
			end)
		end)

		--## Division semantics
		-- Dense grids for floor and truncated division; error handling for /0 and bare /.
		describe.tags(TAG_FULL, "division semantics", function()
			it("floor and truncated division should match integer formulas on dense grids", function()
				for a = -90, 90 do
					for b = -25, 25 do
						if b ~= 0 then
							local A, Bv = bint.from_int(a), bint.from_int(b)

							local qf, rf = core.divmod(A, Bv)
							expect(S(qf)).to.equal(N(floor_div(a, b)))
							expect(S(rf)).to.equal(N(floor_mod(a, b)))
							expect(S(qf * Bv + rf)).to.equal(N(a))
							expect(S(core.idiv(A, Bv))).to.equal(S(qf))
							expect(S(core.mod(A, Bv))).to.equal(S(rf))
							expect(S(A // Bv)).to.equal(S(qf))
							expect(S(A % Bv)).to.equal(S(rf))

							local qt, rt = core.tdivmod(A, Bv)
							expect(S(qt)).to.equal(N(trunc_div(a, b)))
							expect(S(rt)).to.equal(N(trunc_mod(a, b)))
							expect(S(qt * Bv + rt)).to.equal(N(a))
							expect(S(core.tdiv(A, Bv))).to.equal(S(qt))
							expect(S(core.tmod(A, Bv))).to.equal(S(rt))
						end
					end
				end
			end)

			it("division by zero should throw", function()
				expect(function()
					core.divmod(bint("1"), bint.zero())
				end).to.throw("division by zero")
				expect(function()
					core.tdivmod(bint("1"), bint.zero())
				end).to.throw("division by zero")
				expect(function()
					local _ = bint("1") // bint.zero()
				end).to.throw("division by zero")
			end)

			it("'/' should error and direct users to '//'", function()
				expect(function()
					local _ = bint("20") / bint("3")
				end).to.throw("use '//' for floor division")
			end)
		end)

		--## Pow and sqrt
		describe.tags(TAG_FAST, "pow and sqrt", function()
			it("pow should handle zero exponent and reject negative exponent", function()
				expect(S(core.pow(bint("-123"), bint.zero()))).to.equal("1")
				expect(function()
					core.pow(bint("5"), bint("-1"))
				end).to.throw("negative exponent")
			end)

			it("pow should match native results on safe small ranges", function()
				for a = -12, 12 do
					for e = 0, 8 do
						local got = core.pow(bint.from_int(a), bint.from_int(e))
						expect(S(got)).to.equal(N(a ^ e))
					end
				end
			end)

			it("sqrt should match floor(sqrt(n)) for non-negative small integers", function()
				for n = 0, 2000 do
					local root = core.sqrt(bint.from_int(n))
					expect(S(root)).to.equal(N(math.floor(math.sqrt(n))))
				end
			end)

			it("sqrt should return zero for non-positive inputs and handle large perfect squares", function()
				expect(S(core.sqrt(bint.zero()))).to.equal("0")
				expect(S(core.sqrt(bint("-1")))).to.equal("0")

				local x = bint("123456789012345678901234567890")
				local sq = x * x
				local nonSquare = sq + bint("12345")

				expect(S(core.sqrt(sq))).to.equal(S(x))
				expect(S(core.sqrt(nonSquare))).to.equal(S(x))
			end)
		end)

		--## String and base conversion
		describe.tags(TAG_FULL, "string/base conversion", function()
			it("tostring/from_string should round-trip across bases for many values", function()
				local bases = { 2, 3, 8, 10, 16, 36 }
				local samples = {
					"0",
					"1",
					"-1",
					"123456789",
					"-123456789",
					"16777216",
					"-16777216",
					"1234567890123456789012345678901234567890",
					"-1234567890123456789012345678901234567890",
				}

				for _, s in ipairs(samples) do
					local x = bint(s)
					for _, base in ipairs(bases) do
						local encoded = bint.tostring(x, base)
						local decoded = bint.from_string(encoded, base)
						expect(S(decoded)).to.equal(S(x))
					end
				end
			end)

			it("random base conversion round-trips should hold", function()
				local bases = { 2, 8, 10, 16, 36 }
				for _ = 1, 60 do
					local x = bint(rand_decimal(80))
					for _, base in ipairs(bases) do
						local encoded = bint.tostring(x, base)
						local decoded = bint.from_string(encoded, base)
						expect(S(decoded)).to.equal(S(x))
					end
				end
			end)

			it("base parameter bounds should be enforced", function()
				expect(function()
					bint.tostring(bint.one(), 1)
				end).to.throw()
				expect(function()
					bint.tostring(bint.one(), 37)
				end).to.throw()
				expect(function()
					bint.from_string("10", 1)
				end).to.throw()
				expect(function()
					bint.from_string("10", 37)
				end).to.throw()
			end)

			it("base parameter should reject fractional values", function()
				expect(function()
					bint.from_string("10", 2.5)
				end).to.throw()
				expect(function()
					bint.from_string("ff", 16.9)
				end).to.throw()
				expect(function()
					bint.tostring(bint("255"), 16.5)
				end).to.throw()
				expect(function()
					bint.tostring(bint("42"), 2.1)
				end).to.throw()
			end)

			it("tostring should use canonical lowercase digits and preserve sign", function()
				expect(bint.tostring(bint("42"), 2)).to.equal("101010")
				expect(bint.tostring(bint("-255"), 16)).to.equal("-ff")
				expect(bint.tostring(bint("35"), 36)).to.equal("z")
				expect(bint.tostring(bint("-35"), 36)).to.equal("-z")
			end)
		end)

		--## Byte conversion
		-- Magnitude-only little/big-endian serialisation and deserialisation.
		describe.tags(TAG_FULL, "byte conversion", function()
			it("tole/fromle and tobe/frombe should round-trip magnitudes", function()
				local samples = {
					bint("0"),
					bint("1"),
					bint("255"),
					bint("16777216"),
					bint("123456789012345678901234567890"),
					bint("-123456789012345678901234567890"),
				}

				for _, x in ipairs(samples) do
					local absX = core.abs(x)
					local le = bint.tole(x)
					local be = bint.tobe(x)
					expect(S(bint.fromle(le))).to.equal(S(absX))
					expect(S(bint.frombe(be))).to.equal(S(absX))
				end
			end)

			it("trim should remove highest zero bytes in little-endian output", function()
				local one = bint.one()
				expect(string.len(bint.tole(one, false))).to.equal(3)
				expect(string.len(bint.tole(one, true))).to.equal(1)
				expect(bint.tole(bint.zero(), true)).to.equal("")
			end)

			it("tole/fromle should round-trip a number with >2700 limbs (exceeds vararg limit)", function()
				-- 3 000 limbs × 3 bytes = 9 000 bytes; far above Lua's ~8 000-arg vararg limit
				local limbs = table.create(3000, 1)
				local big = bint.from_limbs(limbs, 1)
				local le = bint.tole(big)
				expect(#le).to.equal(3000 * 3)
				expect(S(bint.fromle(le))).to.equal(S(big))
				local le_trim = bint.tole(big, true)
				expect(S(bint.fromle(le_trim))).to.equal(S(big))
			end)

			it("fromle/frombe should require string input", function()
				expect(function()
					bint.fromle(123)
				end).to.throw()
				expect(function()
					bint.frombe(123)
				end).to.throw()
			end)

			it("byte conversion should preserve exact endianness and omit sign", function()
				local x = bint.from_limbs({ 0x112233, 0x445566 })
				local le = bint.tole(x)
				local be = bint.tobe(x)

				expect({ string.byte(le, 1, #le) }).to.equal({ 0x33, 0x22, 0x11, 0x66, 0x55, 0x44 })
				expect({ string.byte(be, 1, #be) }).to.equal({ 0x44, 0x55, 0x66, 0x11, 0x22, 0x33 })
				expect(S(bint.fromle(""))).to.equal("0")
				expect(S(bint.frombe(""))).to.equal("0")

				local neg = bint("-255")
				local pos = bint("255")
				expect(bint.tole(neg, true)).to.equal(bint.tole(pos, true))
				expect(S(bint.fromle(bint.tole(neg, true)))).to.equal("255")
			end)
		end)

			--## Tonumber and bit/word shifts
			describe.tags(TAG_FULL, "tonumber and shifts", function()
			it("tonumber should be exact up to 2^53 and return number type for bigger values", function()
				expect(bint.tonumber(bint("9007199254740991"))).to.equal(9007199254740991)
				expect(bint.tonumber(bint("9007199254740992"))).to.equal(9007199254740992)

				local huge = bint("1234567890123456789012345678901234567890")
				expect(type(bint.tonumber(huge))).to.equal("number")
			end)

				it("word shifts should preserve sign and be inverse for exact shifted values", function()
					expect(S(core.lshift_words(bint.one(), 1))).to.equal("16777216")
					expect(S(core.rshift_words(bint("16777216"), 1))).to.equal("1")
				expect(S(core.rshift_words(bint("-16777216"), 1))).to.equal("-1")
				expect(S(core.rshift_words(bint.one(), 1))).to.equal("0")
				expect(S(core.lshift_words(bint.zero(), 5))).to.equal("0")

				local values = {
					bint("1"),
					bint("-1"),
					bint("12345678901234567890"),
					bint("-12345678901234567890"),
				}
				for _, x in ipairs(values) do
					for n = 0, 4 do
						local y = core.lshift_words(x, n)
						local z = core.rshift_words(y, n)
						expect(S(z)).to.equal(S(x))
						end
					end
				end)

				it("bit shifts should match exact arithmetic on safe integers (dense oracle)", function()
					for a = -4096, 4096 do
						for n = 0, 12 do
							expect_shift_matches_safe_number(a, n)
						end
					end

					for _, a in ipairs({ -1, 0, 1, -3, 3, -127, 127, -1024, 1024 }) do
						for _, n in ipairs({ 13, 17, 23, 24, 25, 31 }) do
							-- Chosen so a * 2^n remains exact under the 2^53 safe-integer bound.
							if math.abs(a) <= 2 ^ (53 - n) then
								expect_shift_matches_safe_number(a, n)
							end
						end
					end
				end)

				it("rshift should use arithmetic semantics for negatives and large shift counts", function()
					expect(S(core.rshift(bint("-1"), 1))).to.equal("-1")
					expect(S(core.rshift(bint("-1"), 200))).to.equal("-1")
					expect(S(core.rshift(bint("-2"), 1))).to.equal("-1")
					expect(S(core.rshift(bint("-3"), 1))).to.equal("-2")
					expect(S(core.rshift(bint("-5"), 2))).to.equal("-2")
					expect(S(core.rshift(bint("-16777217"), 24))).to.equal("-2")
					expect(S(core.rshift(bint("1"), 200))).to.equal("0")
				end)

				it("bit shifts should match multiply/divide by powers of two across limb boundaries", function()
					local values = {
						bint("1"),
						bint("-1"),
						bint("12345678901234567890"),
						bint("-12345678901234567890"),
						make_big(8, 101, 1),
						make_big(8, 103, -1),
						make_big(65, 107, 1),
						make_big(65, 109, -1),
					}
					local shifts = { 0, 1, 7, 23, 24, 25, 31, 47, 48, 49, 72, 96 }

					for _, x in ipairs(values) do
						for _, n in ipairs(shifts) do
							local p2 = core.pow(bint.from_int(2), bint.from_int(n))
							expect(S(core.lshift(x, n))).to.equal(S(core.mul(x, p2)))
							expect(S(core.rshift(x, n))).to.equal(S(core.idiv(x, p2)))
						end
					end
				end)

				it("bit shifts should compose and round-trip exactly for large values and unusual counts", function()
					local values = {
						make_big(16, 211, 1),
						make_big(16, 223, -1),
						make_big(130, 227, 1),
						make_big(130, 229, -1),
					}
					local counts = { 0, 1, 5, 23, 24, 25, 47, 48, 49, 255, 256, 257, 1023, 1024, 1025 }
					local pairs = {
						{ 0, 0 },
						{ 1, 23 },
						{ 23, 1 },
						{ 24, 25 },
						{ 255, 257 },
						{ 1023, 25 },
					}

					for _, x in ipairs(values) do
						for _, n in ipairs(counts) do
							expect(S(core.rshift(core.lshift(x, n), n))).to.equal(S(x))
						end

						for _, pair in ipairs(pairs) do
							local a, b = pair[1], pair[2]
							expect(S(core.lshift(core.lshift(x, a), b))).to.equal(S(core.lshift(x, a + b)))
							expect(S(core.rshift(core.rshift(x, a), b))).to.equal(S(core.rshift(x, a + b)))
						end
					end
				end)

				it("bit shifts should handle extreme counts and saturate arithmetic right shift", function()
					local pos = make_big(150, 251, 1)
					local neg = make_big(150, 257, -1)
					local huge_counts = {
						#pos.limbs * 24 + 1,
						#pos.limbs * 24 + 17,
						4096,
						4097,
						10000,
					}

					for _, n in ipairs(huge_counts) do
						expect(S(core.rshift(pos, n))).to.equal("0")
						expect(S(core.rshift(neg, n))).to.equal("-1")
						expect(S(core.rshift(bint.one(), n))).to.equal("0")
						expect(S(core.rshift(bint("-1"), n))).to.equal("-1")
					end
				end)

				it("bit shifts should match word shifts at exact 24-bit multiples and preserve arithmetic semantics", function()
					local positives = {
						bint("1"),
						bint("16777217"),
						bint("12345678901234567890"),
						make_big(10, 263, 1),
					}
					for _, x in ipairs(positives) do
						for k = 0, 6 do
							expect(S(core.lshift(x, 24 * k))).to.equal(S(core.lshift_words(x, k)))
							expect(S(core.rshift(x, 24 * k))).to.equal(S(core.rshift_words(x, k)))
						end
					end

					-- Negative values use arithmetic bit-shift semantics, which intentionally differ
					-- from sign-magnitude word shifts when discarded bits are non-zero.
					expect(S(core.rshift(bint("-1"), 24))).to.equal("-1")
					expect(S(core.rshift_words(bint("-1"), 1))).to.equal("0")
					expect(S(core.rshift(bint("-33554431"), 24))).to.equal("-2")
					expect(S(core.rshift_words(bint("-33554431"), 1))).to.equal("-1")

					-- When divisibility is exact, arithmetic bit shifts agree with word shifts even for negatives.
					local exact_neg = core.lshift_words(make_big(8, 269, -1), 3)
					for k = 0, 3 do
						expect(S(core.rshift(exact_neg, 24 * k))).to.equal(S(core.rshift_words(exact_neg, k)))
					end
				end)
			end)

			--## Algorithm path coverage
			-- Exercises basecase/Karatsuba/Toom-3 mul and Knuth/Burnikel-Ziegler div paths directly.
			describe.tags(TAG_FAST, "algorithm path coverage", function()
				it("division path: knuth-sized operands should satisfy floor/trunc invariants", function()
					local a = make_big(300, 97, -1)
					local b = make_big(300, 131, 1)

				local qf, rf = core.divmod(a, b)
				expect(S(qf * b + rf)).to.equal(S(a))
				expect_floor_remainder_range(rf, b)

				local qt, rt = core.tdivmod(a, b)
				expect(S(qt * b + rt)).to.equal(S(a))
				expect_trunc_remainder_range(rt, a, b)
			end)

			it("division path: burnikel-sized operands should satisfy floor/trunc invariants", function()
				local a = make_big(350, 151, -1)
				local b = make_big(300, 173, 1)

				local qf, rf = core.divmod(a, b)
				expect(S(qf * b + rf)).to.equal(S(a))
				expect_floor_remainder_range(rf, b)

				local qt, rt = core.tdivmod(a, b)
				expect(S(qt * b + rt)).to.equal(S(a))
				expect_trunc_remainder_range(rt, a, b)
			end)

			it("division boundary: diff=40 and diff=41 should both be correct", function()
				local b = make_big(300, 191, 1)
				local a_knuth = make_big(340, 211, -1)   -- diff=40
				local a_burnikel = make_big(341, 223, -1) -- diff=41

				local qk, rk = core.divmod(a_knuth, b)
				expect(S(qk * b + rk)).to.equal(S(a_knuth))
				expect_floor_remainder_range(rk, b)

				local qb, rb = core.divmod(a_burnikel, b)
				expect(S(qb * b + rb)).to.equal(S(a_burnikel))
				expect_floor_remainder_range(rb, b)
			end)

			it("burnikel outer loop should handle top chunk >= divisor without invalid 2n/1n call", function()
				-- Construct a Burnikel-sized divisor with sigma=1 and shift=0 (top limb BASE-1, length=512),
				-- then make the dividend's top n-limb chunk exactly equal to the divisor. The first outer
				-- loop step would violate div_bz_2n1n's precondition (z < BASE^n * B) without a fallback.
				local n = 512
				local b_limbs = make_limbs(n, 401)
				b_limbs[n] = BASE - 1
				local low_limbs = make_limbs(n, 433)
				local a_limbs = table.create(n * 2)
				for i = 1, n do
					a_limbs[i] = low_limbs[i]
					a_limbs[n + i] = b_limbs[i]
				end

				local a = bint.from_limbs(a_limbs, 1)
				local b = bint.from_limbs(b_limbs, 1)
				local qbz, rbz = algorithms.div_burnikel(a, b)
				local qk, rk = algorithms.div_knuth(a, b)

				expect(S(qbz)).to.equal(S(qk))
				expect(S(rbz)).to.equal(S(rk))
				expect(S(core.add(core.mul(qbz, b), rbz))).to.equal(S(a))
				expect_floor_remainder_range(rbz, b)
			end)

			it("sqrt path: newton-sized values should satisfy isqrt inequalities", function()
				local n = make_big(31, 239, 1)
				local s = core.sqrt(n)
				local one = bint.one()
				expect(core.le(s * s, n)).to.equal(true)
				expect(core.lt(n, (s + one) * (s + one))).to.equal(true)
			end)

			it("sqrt path: karatsuba-sized values should satisfy isqrt inequalities", function()
				local n = make_big(40, 257, 1)
				local s = core.sqrt(n)
				local one = bint.one()
				expect(core.le(s * s, n)).to.equal(true)
				expect(core.lt(n, (s + one) * (s + one))).to.equal(true)
			end)
		end)

		--## Large-number invariants
		-- Randomised arithmetic, division, and algebraic identities at ~12-limb and ~100-limb scale.
		describe.tags(TAG_FULL, "large-number invariants", function()
			it("randomized invariants should hold for large values (~12-limb)", function()
				for _ = 1, 90 do
					local sa = rand_decimal(90)
					local sb = rand_decimal(90)
					local sc = rand_decimal(90)
					if sb == "0" or sb == "-0" then
						sb = "1"
					end

					local a = bint(sa)
					local b = bint(sb)
					local c = bint(sc)

					expect(S((a + b) - b)).to.equal(S(a))
					expect(S((a - b) + b)).to.equal(S(a))
					expect(S(a + b)).to.equal(S(b + a))
					expect(S(a * b)).to.equal(S(b * a))
					expect(S(a * (b + c))).to.equal(S(a * b + a * c))

					local qf, rf = core.divmod(a, b)
					expect(S(qf * b + rf)).to.equal(S(a))

					if b.signum == 1 then
						expect(core.le(bint.zero(), rf)).to.equal(true)
						expect(core.lt(rf, b)).to.equal(true)
					else
						expect(core.lt(b, rf)).to.equal(true)
						expect(core.le(rf, bint.zero())).to.equal(true)
					end

					local qt, rt = core.tdivmod(a, b)
					expect(S(qt * b + rt)).to.equal(S(a))
					if rt.signum ~= 0 then
						expect(rt.signum).to.equal(a.signum)
					end
					expect(core.lt(core.abs(rt), core.abs(b))).to.equal(true)
				end
			end)

			it("randomized invariants should hold for toom3-scale values (~100 limbs)", function()
				for i = 1, 40 do
					local signA = (i % 2 == 0) and 1 or -1
					local signB = (i % 3 == 0) and -1 or 1
					local signC = (i % 5 == 0) and -1 or 1
					local a = make_big(95 + i % 30, i * 233 + 1, signA)
					local b = make_big(90 + i % 30, i * 239 + 3, signB)
					local c = make_big(92 + i % 30, i * 241 + 7, signC)

					expect(S(core.sub(core.add(a, b), b))).to.equal(S(a))
					expect(S(core.add(core.sub(a, b), b))).to.equal(S(a))
					expect(S(core.add(a, b))).to.equal(S(core.add(b, a)))
					expect(S(core.mul(a, b))).to.equal(S(core.mul(b, a)))
					expect(S(core.mul(a, core.add(b, c)))).to.equal(S(core.add(core.mul(a, b), core.mul(a, c))))

					local qf, rf = core.divmod(a, b)
					expect(S(core.add(core.mul(qf, b), rf))).to.equal(S(a))
					expect_floor_remainder_range(rf, b)

					local qt, rt = core.tdivmod(a, b)
					expect(S(core.add(core.mul(qt, b), rt))).to.equal(S(a))
					expect_trunc_remainder_range(rt, a, b)
				end
			end)
		end)

		--## Multiplication coverage
		-- Every algorithm tier and sign combo; Toom-3 bugs only surface at 90+ limbs with mixed signs.
		describe.tags(TAG_FULL, "mul coverage: all tiers and sign combos", function()
			it("basecase: all sizes 1–44 with sign variation match naive", function()
				for len = 1, 44 do
					local signA = (len % 2 == 0) and -1 or 1
					local signB = (len % 3 == 0) and -1 or 1
					local a = make_big(len, len * 31 + 1, signA)
					local b = make_big(len, len * 37 + 5, signB)
					expect(S(core.mul(a, b))).to.equal(S(naive_mul(a, b)))
				end
			end)

			it("karatsuba: representative sizes 45–89, all four sign combos, match naive", function()
				local signs = {{1,1},{1,-1},{-1,1},{-1,-1}}
				for _, len in ipairs({45, 53, 63, 75, 89}) do
					for si, sg in ipairs(signs) do
						local a = make_big(len, si * 53 + len, sg[1])
						local b = make_big(len, si * 59 + len + 3, sg[2])
						expect(S(core.mul(a, b))).to.equal(S(naive_mul(a, b)))
					end
				end
			end)

			it("toom3: representative sizes 90–150, all four sign combos, match naive", function()
				local signs = {{1,1},{1,-1},{-1,1},{-1,-1}}
				for _, len in ipairs({90, 97, 110, 130, 150}) do
					for si, sg in ipairs(signs) do
						local a = make_big(len, si * 61 + len, sg[1])
						local b = make_big(len, si * 67 + len + 5, sg[2])
						expect(S(core.mul(a, b))).to.equal(S(naive_mul(a, b)))
					end
				end
			end)

			it("cross-tier: asymmetric size pairs spanning boundaries, all sign combos, match naive", function()
				local pairs_list = {{44, 90}, {45, 90}, {46, 91}, {89, 90}, {60, 120}, {44, 130}}
				local signs = {{1,1},{1,-1},{-1,1},{-1,-1}}
				for i, pr in ipairs(pairs_list) do
					for _, sg in ipairs(signs) do
						local a = make_big(pr[1], i * 71 + pr[1], sg[1])
						local b = make_big(pr[2], i * 73 + pr[2], sg[2])
						expect(S(core.mul(a, b))).to.equal(S(naive_mul(a, b)))
					end
				end
			end)

			it("toom3: 50 random size and sign combinations match naive", function()
				for i = 1, 50 do
					local lenA = 90 + i % 61
					local lenB = 90 + (i * 7) % 61
					local signA = (i % 2 == 0) and 1 or -1
					local signB = (i % 3 == 0) and 1 or -1
					local a = make_big(lenA, i * 79 + 1, signA)
					local b = make_big(lenB, i * 83 + 3, signB)
					expect(S(core.mul(a, b))).to.equal(S(naive_mul(a, b)))
				end
			end)

			it("exact threshold boundaries (44/45 and 89/90 limbs), all sign combos, match naive", function()
				local signs = {{1,1},{1,-1},{-1,1},{-1,-1}}
				for _, len in ipairs({44, 45, 46, 89, 90, 91}) do
					for si, sg in ipairs(signs) do
						local a = make_big(len, si * 197 + len, sg[1])
						local b = make_big(len, si * 199 + len + 7, sg[2])
						expect(S(core.mul(a, b))).to.equal(S(naive_mul(a, b)))
					end
				end
			end)
		end)

		--## Algebraic laws at scale
		describe.tags(TAG_FULL, "algebraic laws at scale", function()
			it("commutativity a*b = b*a at karatsuba, toom3, and mixed sizes", function()
				for _, len in ipairs({45, 70, 90, 120}) do
					for _, sign in ipairs({1, -1}) do
						local a = make_big(len, len * 97 + 1, sign)
						local b = make_big(len, len * 101 + 3, -sign)
						expect(S(core.mul(a, b))).to.equal(S(core.mul(b, a)))
					end
				end
			end)

			it("associativity (a*b)*c = a*(b*c) at karatsuba size", function()
				for i = 1, 8 do
					local a = make_big(45 + i, i * 103 + 1, (i % 2 == 0) and -1 or 1)
					local b = make_big(45 + i, i * 107 + 3, 1)
					local c = make_big(45 + i, i * 109 + 7, (i % 3 == 0) and -1 or 1)
					expect(S(core.mul(core.mul(a, b), c))).to.equal(S(core.mul(a, core.mul(b, c))))
				end
			end)

			it("distributivity a*(b+c) = a*b + a*c at toom3 size", function()
				for i = 1, 10 do
					local a = make_big(90 + i, i * 113, (i % 2 == 0) and -1 or 1)
					local b = make_big(90 + i, i * 127, 1)
					local c = make_big(90 + i, i * 131, -1)
					local lhs = core.mul(a, core.add(b, c))
					local rhs = core.add(core.mul(a, b), core.mul(a, c))
					expect(S(lhs)).to.equal(S(rhs))
				end
			end)

			it("add-sub inverse (a+b)-b = a at toom3 size with mixed signs", function()
				for i = 1, 12 do
					local signA = (i % 2 == 0) and -1 or 1
					local signB = (i % 3 == 0) and -1 or 1
					local a = make_big(90 + i, i * 137, signA)
					local b = make_big(95 + i, i * 139, signB)
					expect(S(core.sub(core.add(a, b), b))).to.equal(S(a))
					expect(S(core.add(core.sub(a, b), b))).to.equal(S(a))
				end
			end)

			it("a*a = a^2 for large values at each algorithm tier", function()
				for _, len in ipairs({44, 45, 89, 90, 120}) do
					for _, sign in ipairs({1, -1}) do
						local a = make_big(len, len * 149 + 1, sign)
						local via_mul = core.mul(a, a)
						local via_pow = core.pow(core.abs(a), bint("2"))
						expect(S(via_mul)).to.equal(S(via_pow))
					end
				end
			end)
		end)

		--## Exponentiation identities
		describe.tags(TAG_FAST, "exponentiation laws", function()
			it("a^m * a^n = a^(m+n) for several bases and exponent pairs", function()
				local bases = {bint("2"), bint("-3"), bint("100"), bint("16777217"), bint("-16777215")}
				for _, base in ipairs(bases) do
					for m = 0, 6 do
						for n = 0, 6 do
							local lhs = core.mul(core.pow(base, bint.from_int(m)), core.pow(base, bint.from_int(n)))
							local rhs = core.pow(base, bint.from_int(m + n))
							expect(S(lhs)).to.equal(S(rhs))
						end
					end
				end
			end)

			it("(a^m)^n = a^(m*n) for small values", function()
				local bases = {bint("2"), bint("-3"), bint("7")}
				for _, base in ipairs(bases) do
					for m = 0, 4 do
						for n = 0, 4 do
							local lhs = core.pow(core.pow(base, bint.from_int(m)), bint.from_int(n))
							local rhs = core.pow(base, bint.from_int(m * n))
							expect(S(lhs)).to.equal(S(rhs))
						end
					end
				end
			end)

			it("(a*b)^n = a^n * b^n for n = 0..5", function()
				local pairs_list = {{bint("7"), bint("3")}, {bint("-5"), bint("-11")}, {bint("100"), bint("50")}}
				for _, pr in ipairs(pairs_list) do
					local a, b = pr[1], pr[2]
					for n = 0, 5 do
						local bn = bint.from_int(n)
						local lhs = core.pow(core.mul(a, b), bn)
						local rhs = core.mul(core.pow(a, bn), core.pow(b, bn))
						expect(S(lhs)).to.equal(S(rhs))
					end
				end
			end)

			it("large base pow: 2^96 = (2^48)^2 = 2^32 * 2^64", function()
				local two = bint("2")
				local p96 = core.pow(two, bint("96"))
				local p48 = core.pow(two, bint("48"))
				local p32 = core.pow(two, bint("32"))
				local p64 = core.pow(two, bint("64"))
				expect(S(p96)).to.equal(S(core.mul(p48, p48)))
				expect(S(p96)).to.equal(S(core.mul(p32, p64)))
			end)
		end)

		--## Division coverage: signed and large
		-- Large inputs, all sign combos, floor and truncated semantics.
		describe.tags(TAG_FULL, "division coverage: signed and large", function()
			it("floor div: all 4 sign combos at toom3 sizes satisfy q*b+r=a and range", function()
				local signs = {{1,1},{1,-1},{-1,1},{-1,-1}}
				for i, sg in ipairs(signs) do
					for j = 1, 6 do
						local a = make_big(90 + j * 8, i * 151 + j, sg[1])
						local b = make_big(90 + j * 4, i * 157 + j + 3, sg[2])
						local q, r = core.divmod(a, b)
						expect(S(core.add(core.mul(q, b), r))).to.equal(S(a))
						expect_floor_remainder_range(r, b)
					end
				end
			end)

			it("trunc div: all 4 sign combos at toom3 sizes satisfy q*b+r=a and range", function()
				local signs = {{1,1},{1,-1},{-1,1},{-1,-1}}
				for i, sg in ipairs(signs) do
					for j = 1, 6 do
						local a = make_big(90 + j * 8, i * 163 + j, sg[1])
						local b = make_big(90 + j * 4, i * 167 + j + 3, sg[2])
						local q, r = core.tdivmod(a, b)
						expect(S(core.add(core.mul(q, b), r))).to.equal(S(a))
						expect_trunc_remainder_range(r, a, b)
					end
				end
			end)

			it("floor div: quotient-0 and quotient-±1 edge cases for all sign combos", function()
				local cases = {
					{"5", "10"}, {"-5", "10"}, {"5", "-10"}, {"-5", "-10"},
					{"7", "7"}, {"-7", "7"}, {"7", "-7"}, {"-7", "-7"},
					{"999", "1000"}, {"-999", "1000"}, {"999", "-1000"}, {"-999", "-1000"},
				}
				for _, c in ipairs(cases) do
					local a, b = bint(c[1]), bint(c[2])
					local q, r = core.divmod(a, b)
					expect(S(core.add(core.mul(q, b), r))).to.equal(S(a))
					expect_floor_remainder_range(r, b)
				end
			end)

			it("single-limb divisor: large numerator divided by small values, all sign combos", function()
				for _, dv in ipairs({1, 2, 3, 7, 100, 16777215}) do
					for _, signA in ipairs({1, -1}) do
						for _, signB in ipairs({1, -1}) do
							local a = make_big(100, dv * 7 + 1, signA)
							local b = bint.from_int(dv * signB)
							local q, r = core.divmod(a, b)
							expect(S(core.add(core.mul(q, b), r))).to.equal(S(a))
							expect_floor_remainder_range(r, b)
						end
					end
				end
			end)

			it("burnikel-sized: 15 random large inputs (300+ limbs) satisfy floor and trunc", function()
				for i = 1, 15 do
					local signA = (i % 2 == 0) and 1 or -1
					local signB = (i % 3 == 0) and -1 or 1
					local a = make_big(300 + i * 3, i * 173 + 1, signA)
					local b = make_big(300, i * 179 + 3, signB)
					local qf, rf = core.divmod(a, b)
					expect(S(core.add(core.mul(qf, b), rf))).to.equal(S(a))
					expect_floor_remainder_range(rf, b)
					local qt, rt = core.tdivmod(a, b)
					expect(S(core.add(core.mul(qt, b), rt))).to.equal(S(a))
					expect_trunc_remainder_range(rt, a, b)
				end
			end)
		end)

		--## Edge-case regressions
		-- Carry/borrow ripple, tiny-vs-massive operands, and perfect-square sqrt boundaries.
		describe.tags(TAG_FAST, "edge-case regressions", function()
			it("preserves tiny deltas when adding to or subtracting from massive values", function()
				local huge = make_big(220, 314159, 1)
				local one = bint.one()
				local two = bint.from_int(2)

				local huge_plus_one = core.add(huge, one)
				local huge_plus_two = core.add(huge, two)

				expect(core.lt(huge, huge_plus_one)).to.equal(true)
				expect(core.lt(huge_plus_one, huge_plus_two)).to.equal(true)
				expect(S(core.sub(huge_plus_one, huge))).to.equal("1")
				expect(S(core.sub(huge_plus_two, huge))).to.equal("2")
				expect(S(core.add(core.neg(huge), huge_plus_one))).to.equal("1")

				local neg_huge = core.neg(huge)
				local neg_huge_plus_one = core.add(neg_huge, one)
				expect(S(core.sub(neg_huge_plus_one, neg_huge))).to.equal("1")
				expect(S(core.add(huge, neg_huge))).to.equal("0")
			end)

			it("ripples carry and borrow across long runs of limb-edge values", function()
				local span = 96
				local one = bint.one()
				local all_max = bint.from_limbs(table.create(span, BASE - 1), 1)

				local next_pow_limbs = table.create(span + 1, 0)
				next_pow_limbs[span + 1] = 1
				local next_pow = bint.from_limbs(next_pow_limbs, 1)

				expect(S(core.add(all_max, one))).to.equal(S(next_pow))
				expect(S(core.sub(next_pow, one))).to.equal(S(all_max))

				local neg_all_max = core.neg(all_max)
				local neg_next_pow = core.neg(next_pow)
				expect(S(core.add(neg_all_max, bint("-1")))).to.equal(S(neg_next_pow))
				expect(S(core.add(neg_next_pow, one))).to.equal(S(neg_all_max))
			end)

			it("floor and trunc division handle tiny dividends against massive divisors", function()
				local huge = make_big(180, 424242, 1)
				for _, mag in ipairs({1, BASE - 1}) do
					for _, signA in ipairs({1, -1}) do
						for _, signB in ipairs({1, -1}) do
							local a = bint.from_int(signA * mag)
							local b = signB == 1 and huge or core.neg(huge)

							local qf, rf = expect_floor_divmod_invariants(a, b)
							local qt, rt = expect_trunc_divmod_invariants(a, b)

							expect(S(qt)).to.equal("0")
							expect(S(rt)).to.equal(S(a))

							if signA == signB then
								expect(S(qf)).to.equal("0")
								expect(S(rf)).to.equal(S(a))
							else
								expect(S(qf)).to.equal("-1")
								expect(S(rf)).to.equal(S(core.add(a, b)))
							end
						end
					end
				end
			end)

			it("sqrt is exact at large perfect-square boundaries and immediate neighbors", function()
				local one = bint.one()
				local a = make_big(70, 515151, 1)
				local a2 = core.mul(a, a)
				local ap1 = core.add(a, one)
				local ap1sq = core.mul(ap1, ap1)

				expect(S(core.sqrt(core.sub(a2, one)))).to.equal(S(core.sub(a, one)))
				expect(S(core.sqrt(a2))).to.equal(S(a))
				expect(S(core.sqrt(core.sub(ap1sq, one)))).to.equal(S(a))
				expect(S(core.sqrt(ap1sq))).to.equal(S(ap1))
			end)
		end)

		--## Sqrt coverage: large inputs and algorithm-boundary sweep
		describe.tags(TAG_FULL, "sqrt coverage: large and boundary", function()
			it("isqrt(n)^2 <= n < (isqrt(n)+1)^2 for 50 large random inputs", function()
				local one = bint.one()
				for i = 1, 50 do
					local n = make_big(20 + i, i * 181 + 7, 1)
					local s = core.sqrt(n)
					expect(core.le(core.mul(s, s), n)).to.equal(true)
					local s1 = core.add(s, one)
					expect(core.lt(n, core.mul(s1, s1))).to.equal(true)
				end
			end)

			it("sqrt(a^2) = a for 30 large random values", function()
				for i = 1, 30 do
					local a = make_big(20 + i, i * 191 + 3, 1)
					local a2 = core.mul(a, a)
					expect(S(core.sqrt(a2))).to.equal(S(a))
				end
			end)

			it("isqrt inequalities hold across newton/karatsuba sqrt threshold (limb counts 28–40)", function()
				local one = bint.one()
				for len = 28, 40 do
					local n = make_big(len, len * 193 + 11, 1)
					local s = core.sqrt(n)
					expect(core.le(core.mul(s, s), n)).to.equal(true)
					expect(core.lt(n, core.mul(core.add(s, one), core.add(s, one)))).to.equal(true)
				end
			end)

			it("sqrt of large perfect squares exercises karatsuba-sqrt path", function()
				for i = 1, 10 do
					local a = make_big(40 + i * 2, i * 197 + 9, 1)
					local a2 = core.mul(a, a)
					expect(S(core.sqrt(a2))).to.equal(S(a))
				end
			end)
		end)

		--## Identity and zero laws at large scale
		describe.tags(TAG_FAST, "identity and zero laws", function()
			it("a * 0 = 0 and 0 * a = 0 for large a at each tier", function()
				local zero = bint.zero()
				for _, len in ipairs({44, 45, 90, 150}) do
					local a = make_big(len, 999, (len % 2 == 0) and -1 or 1)
					expect(S(core.mul(a, zero))).to.equal("0")
					expect(S(core.mul(zero, a))).to.equal("0")
				end
			end)

			it("a * 1 = a and a * -1 = -a for large a at each tier", function()
				local one = bint.one()
				local neg_one = bint("-1")
				for _, len in ipairs({44, 45, 90, 150}) do
					local a = make_big(len, 1111, (len % 2 == 0) and -1 or 1)
					expect(S(core.mul(a, one))).to.equal(S(a))
					expect(S(core.mul(one, a))).to.equal(S(a))
					expect(S(core.mul(a, neg_one))).to.equal(S(core.neg(a)))
				end
			end)

			it("a + 0 = a, a - 0 = a, a - a = 0 for large a", function()
				local zero = bint.zero()
				for _, len in ipairs({44, 90, 150}) do
					local a = make_big(len, 2222, (len % 2 == 0) and -1 or 1)
					expect(S(core.add(a, zero))).to.equal(S(a))
					expect(S(core.add(zero, a))).to.equal(S(a))
					expect(S(core.sub(a, zero))).to.equal(S(a))
					expect(S(core.sub(a, a))).to.equal("0")
				end
			end)

			it("BASE boundaries: addition, multiplication, and pow are exact at limb edges", function()
				local base    = bint("16777216")  -- 2^24 = BASE
				local base_m1 = bint("16777215")  -- BASE - 1
				local base_p1 = bint("16777217")  -- BASE + 1
				-- BASE-1 + 1 = BASE
				expect(S(core.add(base_m1, bint.one()))).to.equal(S(base))
				-- BASE - 1 = BASE-1
				expect(S(core.sub(base, bint.one()))).to.equal(S(base_m1))
				-- BASE * BASE = 2^48
				expect(S(core.mul(base, base))).to.equal(S(core.pow(bint("2"), bint("48"))))
				-- (BASE-1)^2 = BASE^2 - 2*BASE + 1
				local bm1sq    = core.mul(base_m1, base_m1)
				local expected = core.add(core.sub(core.mul(base, base), core.mul(bint("2"), base)), bint.one())
				expect(S(bm1sq)).to.equal(S(expected))
				-- (BASE+1)^2 = BASE^2 + 2*BASE + 1
				local bp1sq     = core.mul(base_p1, base_p1)
				local expected2 = core.add(core.add(core.mul(base, base), core.mul(bint("2"), base)), bint.one())
				expect(S(bp1sq)).to.equal(S(expected2))
			end)

			it("a / a = 1 with remainder 0 for large a, all sign combos", function()
				for _, len in ipairs({45, 90, 150}) do
					for _, sign in ipairs({1, -1}) do
						local a = make_big(len, len * 251 + sign, sign)
						local q, r = core.divmod(a, a)
						expect(S(q)).to.equal("1")
						expect(S(r)).to.equal("0")
						local qt, rt = core.tdivmod(a, a)
						expect(S(qt)).to.equal("1")
						expect(S(rt)).to.equal("0")
					end
				end
			end)
		end)

		--## Operator metamethods
		-- Tests <, <=, ==, ^ as operators rather than via core.*.
		describe.tags(TAG_FAST, "operator metamethods", function()
			it("'<' should compare correctly across all sign combinations", function()
				-- Positive vs positive
				expect(bint("3") < bint("5")).to.equal(true)
				expect(bint("5") < bint("5")).to.equal(false)
				expect(bint("7") < bint("5")).to.equal(false)
				-- Negative vs positive / zero
				expect(bint("-1") < bint("0")).to.equal(true)
				expect(bint("0") < bint("-1")).to.equal(false)
				-- Both negative
				expect(bint("-5") < bint("-4")).to.equal(true)
				expect(bint("-4") < bint("-5")).to.equal(false)
				-- Zero edge
				expect(bint("0") < bint("0")).to.equal(false)
				expect(bint("-1") < bint("1")).to.equal(true)
				-- Note: Luau comparison metamethods require matching types,
				-- so bint < number is not supported; use instance method :lt() for coercion.
			end)

			it("'<=' should compare correctly across all sign combinations", function()
				expect(bint("5") <= bint("5")).to.equal(true)
				expect(bint("3") <= bint("5")).to.equal(true)
				expect(bint("7") <= bint("5")).to.equal(false)
				expect(bint("-5") <= bint("5")).to.equal(true)
				expect(bint("-5") <= bint("-5")).to.equal(true)
				expect(bint("0") <= bint("0")).to.equal(true)
				expect(bint("-1") <= bint("0")).to.equal(true)
				expect(bint("1") <= bint("0")).to.equal(false)
			end)

			it("'==' should compare correctly and use __eq for bint-bint pairs", function()
				expect(bint("42") == bint("42")).to.equal(true)
				expect(bint("42") == bint("43")).to.equal(false)
				expect(bint("0") == bint.zero()).to.equal(true)
				expect(bint("-1") == bint("-1")).to.equal(true)
				expect(bint("-1") == bint("1")).to.equal(false)
				expect(bint.zero() == bint.zero()).to.equal(true)
				-- Note: Luau == between different types (table vs number/string)
				-- always returns false without calling __eq; use :eq() for coercion.
			end)

			it("'^' should compute exponentiation, coerce rhs, and reject negative exponents", function()
				expect(S(bint("2") ^ 10)).to.equal("1024")
				expect(S(bint("-2") ^ 3)).to.equal("-8")
				expect(S(bint("-2") ^ 4)).to.equal("16")
				expect(S(bint("0") ^ 5)).to.equal("0")
				expect(S(bint("7") ^ 0)).to.equal("1")
				expect(S(bint("3") ^ bint("4"))).to.equal("81")
				expect(S(bint("5") ^ "3")).to.equal("125")
				expect(function()
					local _ = bint("2") ^ bint("-1")
				end).to.throw("negative exponent")
			end)
		end)

		--## __tostring and tonumber edge cases
		describe.tags(TAG_FAST, "__tostring and tonumber edge cases", function()
			it("tostring() metamethod should return the decimal representation", function()
				expect(tostring(bint("42"))).to.equal("42")
				expect(tostring(bint.zero())).to.equal("0")
				expect(tostring(bint("-999"))).to.equal("-999")
				expect(tostring(bint("1234567890123456789012345678901234567890")))
					.to.equal("1234567890123456789012345678901234567890")
			end)

			it("tonumber should be correct at zero and the negative 2^53 boundary", function()
				expect(bint.tonumber(bint.zero())).to.equal(0)
				expect(bint.tonumber(bint("-9007199254740991"))).to.equal(-9007199254740991)
				expect(bint.tonumber(bint("-9007199254740992"))).to.equal(-9007199254740992)
				local huge_neg = bint("-1234567890123456789012345678901234567890")
				expect(type(bint.tonumber(huge_neg))).to.equal("number")
			end)

			it("from_int should round-trip exactly at the 2^53-1 boundary", function()
				local max_safe = 9007199254740991
				expect(S(bint.from_int(max_safe))).to.equal("9007199254740991")
				expect(S(bint.from_int(-max_safe))).to.equal("-9007199254740991")
				expect(bint.tonumber(bint.from_int(max_safe))).to.equal(max_safe)
				expect(bint.tonumber(bint.from_int(-max_safe))).to.equal(-max_safe)
			end)

			it("from_int should convert the current Lua number value (use from_string for exact >2^53 literals)", function()
				local rounded = 9007199254740993
				expect(rounded).to.equal(9007199254740992)
				expect(S(bint.from_int(rounded))).to.equal("9007199254740992")
				expect(S(bint.from_string("9007199254740993"))).to.equal("9007199254740993")
			end)
		end)

		--## Constructor edge cases
		-- Covers from_limbs({}) / ({0}), non-decimal leading zeros, and factory freshness.
		describe.tags(TAG_FAST, "constructor edge cases", function()
			it("from_limbs({}) should produce a zero Bint", function()
				local z = bint.from_limbs({})
				expect(S(z)).to.equal("0")
				expect(z.signum).to.equal(0)
				expect(#z.limbs).to.equal(0)
			end)

			it("from_limbs({0}) should normalize trailing zeros to zero", function()
				local z = bint.from_limbs({0})
				expect(S(z)).to.equal("0")
				expect(z.signum).to.equal(0)
			end)

			it("from_string should strip leading zeros in non-decimal bases", function()
				expect(S(bint.from_string("00ff", 16))).to.equal("255")
				expect(S(bint.from_string("000", 2))).to.equal("0")
				expect(S(bint.from_string("0010", 8))).to.equal("8")
				expect(S(bint.from_string("-00ff", 16))).to.equal("-255")
			end)

			it("bint.zero() and bint.one() should return independent values on each call", function()
				local z1 = bint.zero()
				local z2 = bint.zero()
				core.add_mut(z1, bint.one())
				expect(S(z1)).to.equal("1")
				expect(S(z2)).to.equal("0")

				local one1 = bint.one()
				local one2 = bint.one()
				core.neg_mut(one1)
				expect(S(one1)).to.equal("-1")
				expect(S(one2)).to.equal("1")
			end)
		end)

		--## bint / core contract
		-- Three focused tests that verify the two-tier API design rather than numeric correctness:
		--   1. _mut variants return the exact same object.
		--   2. Non-mutating core ops leave both operands unchanged.
		--   3. bint instance methods are faithful proxies: a:op(x) === core.op(a, bint.new(x)).
		describe.tags(TAG_FAST, "bint/core contract", function()
			it("_mut variants should return the same Bint object, not a copy", function()
				local a = bint("100")
				local r = core.abs_mut(a)
				expect(rawequal(r, a)).to.equal(true)

				a = bint("-42")
				r = core.neg_mut(a)
				expect(rawequal(r, a)).to.equal(true)

				a = bint("10")
				r = core.add_mut(a, bint("5"))
				expect(rawequal(r, a)).to.equal(true)

				a = bint("20")
				r = core.sub_mut(a, bint("5"))
				expect(rawequal(r, a)).to.equal(true)

				a = bint("10")
				r = core.mul_mut(a, bint("3"))
				expect(rawequal(r, a)).to.equal(true)
			end)

			it("non-mutating core ops should leave both operands unchanged", function()
				local a = bint("100")
				local b = bint("7")

				local _ = core.add(a, b)
				expect(S(a)).to.equal("100"); expect(S(b)).to.equal("7")
				_ = core.sub(a, b)
				expect(S(a)).to.equal("100"); expect(S(b)).to.equal("7")
				_ = core.mul(a, b)
				expect(S(a)).to.equal("100"); expect(S(b)).to.equal("7")
				_ = core.idiv(a, b)
				expect(S(a)).to.equal("100"); expect(S(b)).to.equal("7")
				_ = core.mod(a, b)
				expect(S(a)).to.equal("100"); expect(S(b)).to.equal("7")

				local neg = bint("-42")
				_ = core.abs(neg)
				expect(S(neg)).to.equal("-42")

				local pos = bint("42")
				_ = core.neg(pos)
				expect(S(pos)).to.equal("42")
			end)

			it("bint instance methods should match core.op(a, bint.new(x)) for all BintArg forms", function()
				-- Verifies the coercion layer: regardless of whether x is a Bint, number, or string,
				-- a:op(x) must equal core.op(a, bint.new(x)).
				local a = bint("100")
				local args: {any} = {bint("7"), 7, "7"}
				for _, x in ipairs(args) do
					local bv = bint.new(x)
					expect(S(a:add(x))).to.equal(S(core.add(a, bv)))
					expect(S(a:sub(x))).to.equal(S(core.sub(a, bv)))
					expect(S(a:mul(x))).to.equal(S(core.mul(a, bv)))
					expect(S(a:idiv(x))).to.equal(S(core.idiv(a, bv)))
					expect(S(a:mod(x))).to.equal(S(core.mod(a, bv)))
					expect(a:cmp(x)).to.equal(core.cmp(a, bv))
					expect(a:eq(x)).to.equal(core.eq(a, bv))
					expect(a:lt(x)).to.equal(core.lt(a, bv))
					expect(a:le(x)).to.equal(core.le(a, bv))
				end
			end)
		end)

		--## Instance methods, __len, tobe trim, and Toom-3 boundary
		-- Covers :le(), :clone(), :tostring(base), :tdiv()/:tmod(), __len at BASE edges, tobe trim, and the 123/124/125-limb mul boundary.
		describe.tags(TAG_FULL, "instance methods, __len, tobe trim, and toom3 boundary", function()
			it("a:le(b) should return correct comparisons with coercion", function()
				local a = bint("10")
				expect(a:le(10)).to.equal(true)
				expect(a:le("11")).to.equal(true)
				expect(a:le(bint("9"))).to.equal(false)
				expect(bint.zero():le(bint.zero())).to.equal(true)
				expect(bint("-5"):le(bint("-5"))).to.equal(true)
				expect(bint("-6"):le(bint("-5"))).to.equal(true)
				expect(bint("-4"):le(bint("-5"))).to.equal(false)
			end)

			it("a:clone() should produce an independent deep copy", function()
				local a = bint("12345678901234567890")
				local c = a:clone()
				core.add_mut(a, bint.one())
				expect(S(c)).to.equal("12345678901234567890")
				expect(S(a)).to.equal("12345678901234567891")
			end)

			it("a:tostring(base) should produce non-decimal representations", function()
				expect(bint("255"):tostring(16)).to.equal("ff")
				expect(bint("-255"):tostring(16)).to.equal("-ff")
				expect(bint("8"):tostring(2)).to.equal("1000")
				expect(bint("35"):tostring(36)).to.equal("z")
				expect(bint.zero():tostring(16)).to.equal("0")
			end)

			it("a:tdiv(b) and a:tmod(b) should return the correct single value", function()
				expect(S(bint("-20"):tdiv(6))).to.equal("-3")
				expect(S(bint("-20"):tmod(6))).to.equal("-2")
				expect(S(bint("20"):tdiv("-6"))).to.equal("-3")
				expect(S(bint("20"):tmod("-6"))).to.equal("2")
				expect(S(bint("-20"):tdiv("-6"))).to.equal("3")
				expect(S(bint("-20"):tmod("-6"))).to.equal("-2")
			end)

			it("__len should be accurate at the BASE-1/BASE boundary and digit-count transitions", function()
				expect(#bint("16777215")).to.equal(8)
				expect(#bint("16777216")).to.equal(8)
				expect(#bint("16777217")).to.equal(8)
				expect(#bint("-16777216")).to.equal(8)
				expect(#bint("99999999")).to.equal(8)
				expect(#bint("100000000")).to.equal(9)
			end)

			it("tobe trim should parallel tole trim behavior", function()
				local one = bint.one()
				expect(string.len(bint.tobe(one, false))).to.equal(3)
				expect(string.len(bint.tobe(one, true))).to.equal(1)
				expect(bint.tobe(bint.zero(), true)).to.equal("")
				expect(S(bint.frombe(bint.tobe(bint("255"), true)))).to.equal("255")
			end)

			it("mul: karatsuba/toom3 threshold at 123/124/125 limbs, all 4 sign combos, match naive", function()
				local signs = {{1,1},{1,-1},{-1,1},{-1,-1}}
				for _, len in ipairs({123, 124, 125}) do
					for si, sg in ipairs(signs) do
						local a = make_big(len, si * 307 + len, sg[1])
						local b = make_big(len, si * 311 + len + 9, sg[2])
						expect(S(core.mul(a, b))).to.equal(S(naive_mul(a, b)))
					end
				end
			end)
		end)

		--## Algorithm-direct: correctness at arbitrary sizes
		-- Each algorithm is tested at sizes on both sides of the dispatch threshold,
		-- exercising correctness that cannot be reached through core.* dispatch alone.
			describe.tags(TAG_FULL, "algorithm-direct: correctness at arbitrary sizes", function()
			local signs = {{1,1},{1,-1},{-1,1},{-1,-1}}

			--## Multiplication

			it("mul_basecase matches naive_mul at sizes within the safe precision range", function()
				-- mul_limbs_basecase accumulates n products of up to (2^24)^2 ≈ 2^48 each.
				-- For the sum to stay below the 2^53 IEEE-754 integer-exact boundary, n must be
				-- small.  KARATSUBA_THR=44 is the dispatch ceiling; testing beyond it is not
				-- meaningful because the algorithm is not designed for larger inputs.
				for _, len in ipairs({1, 10, 20, 43}) do
					for si, sg in ipairs(signs) do
						local a = make_big(len, si * 31 + len, sg[1])
						local b = make_big(len, si * 37 + len + 5, sg[2])
						expect(S(algorithms.mul_basecase(a, b))).to.equal(S(naive_mul(a, b)))
					end
				end
			end)

			it("mul_karatsuba matches naive_mul at all sizes including below KARATSUBA_THR=44", function()
				-- Sizes 1–43 are the key blind spot: dispatch never routes here, so bugs would go undetected.
				for _, len in ipairs({1, 10, 44, 45, 89, 124}) do
					for si, sg in ipairs(signs) do
						local a = make_big(len, si * 41 + len, sg[1])
						local b = make_big(len, si * 43 + len + 3, sg[2])
						expect(S(algorithms.mul_karatsuba(a, b))).to.equal(S(naive_mul(a, b)))
					end
				end
			end)

			it("mul_toom3 matches naive_mul at all sizes including below TOOM3_THR=124 and size 1", function()
				-- Size 1 is a degenerate k=0 case; valid regression target.
				for _, len in ipairs({1, 44, 89, 123, 124, 150}) do
					for si, sg in ipairs(signs) do
						local a = make_big(len, si * 47 + len, sg[1])
						local b = make_big(len, si * 53 + len + 7, sg[2])
						expect(S(algorithms.mul_toom3(a, b))).to.equal(S(naive_mul(a, b)))
					end
				end
			end)

			it("mul_karatsuba and mul_toom3 match core.mul at their in-range sizes", function()
				-- Karatsuba range: both >= 44 and both < 124
				for _, len in ipairs({45, 63, 89}) do
					for si, sg in ipairs(signs) do
						local a = make_big(len, si * 59 + len, sg[1])
						local b = make_big(len, si * 61 + len + 1, sg[2])
						expect(S(algorithms.mul_karatsuba(a, b))).to.equal(S(core.mul(a, b)))
					end
				end
				-- Toom-3 range: both >= 124
				for _, len in ipairs({124, 140, 160}) do
					for si, sg in ipairs(signs) do
						local a = make_big(len, si * 67 + len, sg[1])
						local b = make_big(len, si * 71 + len + 3, sg[2])
						expect(S(algorithms.mul_toom3(a, b))).to.equal(S(core.mul(a, b)))
					end
				end
			end)

			it("mul_basecase: (BASE^n - 1)^2 precision regression for Comba-style accumulator", function()
				-- (BASE^n - 1) is represented as n limbs all equal to BASE-1.
				-- Its self-product hits the maximum column weight at the center column.
				-- With the old single-accumulator code, at n=35 the center-column sum reaches
				-- 35*(BASE-1)^2 ~ 35*2^48 > 2^53, losing exact integer precision.
				-- Tested via algorithms.mul_basecase (direct) and via the full dispatch chain.
				for _, n in ipairs({1, 10, 35}) do
					local limbs = table.create(n, BASE - 1)
					local a = bint.from_limbs(limbs, 1)
					expect(S(algorithms.mul_basecase(a, a))).to.equal(S(naive_mul(a, a)))
				end
			end)

			it("mul: (BASE^n - 1)^2 precision regression across Karatsuba and Toom-3 dispatch", function()
				-- Same worst-case all-(BASE-1) pattern exercised through the full dispatch chain.
				-- Karatsuba and Toom-3 recurse into mul_limbs_basecase, so the fix must propagate.
				for _, n in ipairs({35, 70, 100, 140}) do
					local limbs = table.create(n, BASE - 1)
					local a = bint.from_limbs(limbs, 1)
					local expected = S(naive_mul(a, a))
					expect(S(core.mul(a, a))).to.equal(expected)
					if n <= 123 then
						expect(S(algorithms.mul_karatsuba(a, a))).to.equal(expected)
					else
						expect(S(algorithms.mul_toom3(a, a))).to.equal(expected)
					end
				end
			end)

			--## Division

			it("div_knuth and div_burnikel throw on division by zero", function()
				expect(function()
					algorithms.div_knuth(bint("1"), bint.zero())
				end).to.throw("division by zero")
				expect(function()
					algorithms.div_burnikel(bint("1"), bint.zero())
				end).to.throw("division by zero")
			end)

			it("div_knuth and div_burnikel handle zero dividend", function()
				local b = make_big(5, 999, 1)
				local q, r = algorithms.div_knuth(bint.zero(), b)
				expect(S(q)).to.equal("0"); expect(S(r)).to.equal("0")
				q, r = algorithms.div_burnikel(bint.zero(), b)
				expect(S(q)).to.equal("0"); expect(S(r)).to.equal("0")
			end)

			it("div_knuth and div_burnikel match core.divmod on floor-division edge cases", function()
				-- |a| < |b|, |a| == |b|, all four sign combos
				local cases = {
					{"5", "10"}, {"-5", "10"}, {"5", "-10"}, {"-5", "-10"},
					{"7", "7"}, {"-7", "7"}, {"7", "-7"}, {"-7", "-7"},
				}
				for _, c in ipairs(cases) do
					local a, b = bint(c[1]), bint(c[2])
					local qref, rref = core.divmod(a, b)
					local qk, rk = algorithms.div_knuth(a, b)
					local qbz, rbz = algorithms.div_burnikel(a, b)
					expect(S(qk)).to.equal(S(qref)); expect(S(rk)).to.equal(S(rref))
					expect(S(qbz)).to.equal(S(qref)); expect(S(rbz)).to.equal(S(rref))
				end
			end)

			it("div_knuth matches core.divmod at small/medium/large sizes with all sign combos", function()
				-- Large case forces Knuth on inputs normally handled by Burnikel-Ziegler.
				for _, pair in ipairs({{5, 3}, {100, 60}, {350, 300}}) do
					for si, sg in ipairs(signs) do
						local a = make_big(pair[1], si * 73 + pair[1], sg[1])
						local b = make_big(pair[2], si * 79 + pair[2], sg[2])
						local q, r = algorithms.div_knuth(a, b)
						local qref, rref = core.divmod(a, b)
						expect(S(q)).to.equal(S(qref)); expect(S(r)).to.equal(S(rref))
						expect(S(core.add(core.mul(q, b), r))).to.equal(S(a))
						expect_floor_remainder_range(r, b)
					end
				end
			end)

			it("div_knuth: D3 qhat-saturation edge-shaped vectors remain correct", function()
				-- These vectors are motivated by Knuth D3 qhat-saturation/equality-path edge shapes.
				-- Using divisors with leading limb BASE-1 keeps D=1 (no normalization scaling), so
				-- Vnn = BASE-1 and the quotient estimate is biased toward the qhat=BASE boundary.
				-- This test validates correctness (identity, remainder bounds, core.divmod agreement);
				-- it does not assert that the equality-path branch executes for every case.
				local cases = {
					-- 1-limb divisor
					{{0, BASE - 1, BASE - 1}, {BASE - 1}},
					{{BASE - 1, BASE - 1, BASE - 1}, {BASE - 1}},
					{{BASE - 1, 0, BASE - 1}, {BASE - 1}},
					-- 2-limb divisor with leading limb BASE-1
					{{0, 0, BASE - 1, BASE - 1}, {0, BASE - 1}},
					{{0, BASE - 1, BASE - 1, BASE - 1}, {0, BASE - 1}},
					{{BASE - 1, BASE - 1, BASE - 1, BASE - 1}, {0, BASE - 1}},
				}
				for _, c in ipairs(cases) do
					local a = bint.from_limbs(c[1], 1)
					local b = bint.from_limbs(c[2], 1)
					local q, r = algorithms.div_knuth(a, b)
					-- Identity: a = q*b + r
					expect(S(core.add(core.mul(q, b), r))).to.equal(S(a))
					-- Remainder bounds: 0 <= r < b
					expect_floor_remainder_range(r, b)
					-- Must agree with core.divmod
					local qref, rref = core.divmod(a, b)
					expect(S(q)).to.equal(S(qref)); expect(S(r)).to.equal(S(rref))
				end
			end)

			it("div_burnikel matches core.divmod at small/medium/large sizes with all sign combos", function()
				-- Small/medium operands (< BURNIKEL_THR=232): outer BZ driver + internal Knuth fallback.
				-- Large operands (both > 232, diff > 40): real BZ path.
				for _, pair in ipairs({{5, 3}, {100, 60}, {350, 300}}) do
					for si, sg in ipairs(signs) do
						local a = make_big(pair[1], si * 83 + pair[1], sg[1])
						local b = make_big(pair[2], si * 89 + pair[2], sg[2])
						local q, r = algorithms.div_burnikel(a, b)
						local qref, rref = core.divmod(a, b)
						expect(S(q)).to.equal(S(qref)); expect(S(r)).to.equal(S(rref))
						expect(S(core.add(core.mul(q, b), r))).to.equal(S(a))
						expect_floor_remainder_range(r, b)
					end
				end
			end)

			--## Sqrt

			it("sqrt wrappers return zero for non-positive inputs", function()
				expect(S(algorithms.sqrt_newton(bint.zero()))).to.equal("0")
				expect(S(algorithms.sqrt_newton(bint("-5")))).to.equal("0")
				expect(S(algorithms.sqrt_karatsuba(bint.zero()))).to.equal("0")
				expect(S(algorithms.sqrt_karatsuba(bint("-5")))).to.equal("0")
			end)

			it("sqrt_newton satisfies isqrt inequalities for limb counts 1–20", function()
				local one = bint.one()
				for i = 1, 20 do
					local n = make_big(i, i * 181 + 7, 1)
					local s = algorithms.sqrt_newton(n)
					expect(core.le(core.mul(s, s), n)).to.equal(true)
					expect(core.lt(n, core.mul(core.add(s, one), core.add(s, one)))).to.equal(true)
				end
			end)

			it("sqrt_karatsuba satisfies isqrt inequalities for limb counts 1–70 including below SQRT_KAR_THR=4", function()
				local one = bint.one()
				for i = 1, 70 do
					local n = make_big(i, i * 191 + 11, 1)
					local s = algorithms.sqrt_karatsuba(n)
					expect(core.le(core.mul(s, s), n)).to.equal(true)
					expect(core.lt(n, core.mul(core.add(s, one), core.add(s, one)))).to.equal(true)
				end
			end)

			it("sqrt_newton and sqrt_karatsuba match core.sqrt at their natural sizes", function()
				-- sqrt_newton matches at small sizes (below SQRT_KAR_THR=4)
				for i = 1, 3 do
					local n = make_big(i, i * 197 + 5, 1)
					expect(S(algorithms.sqrt_newton(n))).to.equal(S(core.sqrt(n)))
				end
				-- sqrt_karatsuba matches at sizes on and above SQRT_KAR_THR=4
				for i = 4, 30 do
					local n = make_big(i, i * 199 + 7, 1)
					expect(S(algorithms.sqrt_karatsuba(n))).to.equal(S(core.sqrt(n)))
				end
			end)

			--## Immutability

			it("algorithm wrappers do not mutate their operands", function()
				local a = make_big(50, 313, 1)
				local b = make_big(50, 317, -1)
				local sa, sb = S(a), S(b)

				local _ = algorithms.mul_basecase(a, b)
				expect(S(a)).to.equal(sa); expect(S(b)).to.equal(sb)
				_ = algorithms.mul_karatsuba(a, b)
				expect(S(a)).to.equal(sa); expect(S(b)).to.equal(sb)
				_ = algorithms.mul_toom3(a, b)
				expect(S(a)).to.equal(sa); expect(S(b)).to.equal(sb)

				local a2 = make_big(50, 331, 1)
				local b2 = make_big(30, 337, -1)
				local sa2, sb2 = S(a2), S(b2)
				_ = algorithms.div_knuth(a2, b2)
				expect(S(a2)).to.equal(sa2); expect(S(b2)).to.equal(sb2)
				_ = algorithms.div_burnikel(a2, b2)
				expect(S(a2)).to.equal(sa2); expect(S(b2)).to.equal(sb2)

				local n = make_big(20, 347, 1)
				local sn = S(n)
				_ = algorithms.sqrt_newton(n)
				expect(S(n)).to.equal(sn)
				_ = algorithms.sqrt_karatsuba(n)
				expect(S(n)).to.equal(sn)
			end)
		end)

		--## Stress: exact safe-range oracles + large-limb differential checks
		-- These are intentionally expensive and are tagged stress-only.
		describe.tags(TAG_STRESS, "stress: exactness and deep differential checks", function()
			local function make_int_cache(lo, hi)
				local out = {}
				for n = lo, hi do
					out[n] = bint.from_int(n)
				end
				return out
			end

			local function expect_exact_int(x, n)
				expect(bint.tonumber(x)).to.equal(n)
			end

			local function expect_bint_eq(a, b)
				expect(core.eq(a, b)).to.equal(true)
			end

			it("core arithmetic, floor/trunc division, and sqrt are exactly correct on dense safe ranges", function()
				local lo, hi = -128, 128
				local ints = make_int_cache(lo, hi)

				for a = lo, hi do
					local A = ints[a]

					for b = lo, hi do
						local B = ints[b]
						expect_exact_int(core.add(A, B), a + b)
						expect_exact_int(core.sub(A, B), a - b)
						expect_exact_int(core.mul(A, B), a * b)

						if b ~= 0 then
							local qf, rf = core.divmod(A, B)
							expect_exact_int(qf, floor_div(a, b))
							expect_exact_int(rf, floor_mod(a, b))

							local qt, rt = core.tdivmod(A, B)
							expect_exact_int(qt, trunc_div(a, b))
							expect_exact_int(rt, trunc_mod(a, b))
						end
					end
				end

				for n = -256, 65535 do
					local expected = n > 0 and math.floor(math.sqrt(n)) or 0
					expect_exact_int(core.sqrt(bint.from_int(n)), expected)
				end
			end)

			it("all public algorithm wrappers are exactly correct on dense safe ranges", function()
				local lo, hi = -96, 96
				local ints = make_int_cache(lo, hi)

				for a = lo, hi do
					local A = ints[a]
					for b = lo, hi do
						local B = ints[b]
						local expectedMul = a * b

						expect_exact_int(algorithms.mul_basecase(A, B), expectedMul)
						expect_exact_int(algorithms.mul_karatsuba(A, B), expectedMul)
						expect_exact_int(algorithms.mul_toom3(A, B), expectedMul)

						if b ~= 0 then
							local qk, rk = algorithms.div_knuth(A, B)
							expect_exact_int(qk, floor_div(a, b))
							expect_exact_int(rk, floor_mod(a, b))

							local qb, rb = algorithms.div_burnikel(A, B)
							expect_exact_int(qb, floor_div(a, b))
							expect_exact_int(rb, floor_mod(a, b))
						end
					end
				end

				for n = -128, 32768 do
					local expected = n > 0 and math.floor(math.sqrt(n)) or 0
					local x = bint.from_int(n)
					expect_exact_int(algorithms.sqrt_newton(x), expected)
					expect_exact_int(algorithms.sqrt_karatsuba(x), expected)
				end
			end)

			it("large-limb multiplication corpus: algorithms and core agree with naive/differential oracles", function()
				local signs = {{1,1},{1,-1},{-1,1},{-1,-1}}

				-- Threshold-heavy exact anchors against independent schoolbook oracle.
				for _, len in ipairs({44, 45, 89, 90, 123, 124, 150}) do
					for si, sg in ipairs(signs) do
						local a = make_big(len, 401 + len * 3 + si, sg[1])
						local b = make_big(len, 457 + len * 5 + si, sg[2])
						local oracle = naive_mul(a, b)

						expect_bint_eq(core.mul(a, b), oracle)
						expect_bint_eq(algorithms.mul_karatsuba(a, b), oracle)
						expect_bint_eq(algorithms.mul_toom3(a, b), oracle)
					end
				end

				-- Larger Toom-3-scale differential corpus (exact via Karatsuba oracle + core dispatch cross-check).
				for i = 1, 24 do
					local lenA = 124 + (i * 13) % 220
					local lenB = 124 + (i * 17) % 220
					local signA = (i % 2 == 0) and 1 or -1
					local signB = (i % 3 == 0) and -1 or 1
					local a = make_big(lenA, 503 + i * 23, signA)
					local b = make_big(lenB, 601 + i * 29, signB)

					local kt = algorithms.mul_karatsuba(a, b)
					local tt = algorithms.mul_toom3(a, b)
					expect_bint_eq(tt, kt)
					expect_bint_eq(core.mul(a, b), tt)
				end
			end)

			it("div_knuth D3 qhat-saturation-biased stress remains correct", function()
				-- Divisors with leading limb BASE-1 are already normalized (D=1), so Vnn = BASE-1.
				-- Dividends are also generated with leading limb BASE-1 to increase the chance of
				-- equality-path opportunities in some iterations.
				-- This verifies correctness under the bias; branch execution is not asserted here.
				for trial = 1, 50 do
					local vlen = 2 + (rnd() % 4)
					local vlimbs = make_limbs(vlen - 1, trial * 1009 + 7)
					vlimbs[vlen] = BASE - 1
					local bv = bint.from_limbs(vlimbs, 1)

					local ulen = vlen + 1 + (rnd() % 5)
					local ulimbs = make_limbs(ulen - 1, trial * 2003 + 13)
					ulimbs[ulen] = BASE - 1
					local av = bint.from_limbs(ulimbs, 1)

					local q, r = algorithms.div_knuth(av, bv)
					expect(S(core.add(core.mul(q, bv), r))).to.equal(S(av))
					expect_floor_remainder_range(r, bv)
					local qref, rref = core.divmod(av, bv)
					expect(S(q)).to.equal(S(qref)); expect(S(r)).to.equal(S(rref))
				end
			end)

			it("large-limb division corpus: Knuth, Burnikel, and core.divmod all agree", function()
				local signs = {{1,1},{1,-1},{-1,1},{-1,-1}}

				for _, pr in ipairs({
					{273, 232}, -- BZ threshold boundary with diff > 40
					{320, 233}, -- regression: BZ didn't unshift remainder by `shift` words (shift=1 for 233-limb divisor)
					{420, 280},
					{540, 300},
					{700, 360},
				}) do
					for si, sg in ipairs(signs) do
						local a = make_big(pr[1], 701 + pr[1] * 3 + si, sg[1])
						local b = make_big(pr[2], 809 + pr[2] * 5 + si, sg[2])

						local qCore, rCore = core.divmod(a, b)
						local qK, rK = algorithms.div_knuth(a, b)
						local qB, rB = algorithms.div_burnikel(a, b)

						expect_bint_eq(qK, qCore); expect_bint_eq(rK, rCore)
						expect_bint_eq(qB, qCore); expect_bint_eq(rB, rCore)

						expect_bint_eq(core.add(core.mul(qK, b), rK), a)
						expect_bint_eq(core.add(core.mul(qB, b), rB), a)
						expect_floor_remainder_range(rK, b)
						expect_floor_remainder_range(rB, b)
					end
				end
			end)

			it("BZ deep recursion: strip trailing zero from quotient (non-canonical Q regression)", function()
				-- Regression for non-canonical quotient arrays reaching mul_limbs via BZ internals.
				-- Two paths produce trailing-zero quotients:
				--   (a) div_knuths pre-allocates quotient with tcreate(m+1, 0) and doesn't strip;
				--       when div_bz_2n1n falls back to Knuth (odd bLen or bLen < BURNIKEL_THR),
				--       the unstripped quotient returns directly to div_bz_3n2n.
				--   (b) div_bz_2n1n builds Q = lshift(q1,k)+q2; if q1 from the correction loop
				--       had its top limb decremented to 0, Q inherits the trailing zero.
				-- In both cases, mul_limbs(q, b2) in div_bz_3n2n receives an inflated array,
				-- mis-dispatches to Toom-3, and lt_abs (length-first) corrupts the vm1 sign.

				-- Case 1: deep BZ recursion (divisor >= 2×BURNIKEL_THR = 464 limbs).
				-- Exercises path (b): recursive div_bz_2n1n → div_bz_3n2n → div_bz_2n1n.
				for i = 1, 8 do
					local signA = (i % 2 == 0) and 1 or -1
					local signB = (i % 3 == 0) and -1 or 1
					local a = make_big(960 + i, i * 211 + 7, signA)
					local b = make_big(480, i * 223 + 11, signB)
					local q, r = core.divmod(a, b)
					expect(S(core.add(core.mul(q, b), r))).to.equal(S(a))
					expect_floor_remainder_range(r, b)
					local qt, rt = core.tdivmod(a, b)
					expect(S(core.add(core.mul(qt, b), rt))).to.equal(S(a))
					expect_trunc_remainder_range(rt, a, b)
				end

				-- Case 2: BZ with Knuth fallback producing unstripped quotient.
				-- Exercises path (a): div_bz_2n1n falls to div_knuths (odd or small b1),
				-- returning a non-canonical q to div_bz_3n2n → mul_limbs(q, b2).
				-- Divisor sized so the recursive b1 = upper(B, k) has odd length or < BURNIKEL_THR.
				for _, pr in ipairs({{500, 233}, {600, 279}, {750, 351}}) do
					for i = 1, 4 do
						local signA = (i % 2 == 0) and 1 or -1
						local signB = (i % 3 == 0) and -1 or 1
						local a = make_big(pr[1], i * 311 + pr[1], signA)
						local b = make_big(pr[2], i * 317 + pr[2], signB)
						local q, r = core.divmod(a, b)
						expect(S(core.add(core.mul(q, b), r))).to.equal(S(a))
						expect_floor_remainder_range(r, b)
						local qt, rt = core.tdivmod(a, b)
						expect(S(core.add(core.mul(qt, b), rt))).to.equal(S(a))
						expect_trunc_remainder_range(rt, a, b)
					end
				end
			end)

			it("large-limb sqrt corpus: Newton, Karatsuba, and core.sqrt agree exactly", function()
				local one = bint.one()

				-- Perfect squares and neighbors across and far above the Karatsuba threshold.
				for i = 1, 24 do
					local a = make_big(4 + i * 8, 911 + i * 31, 1)
					local a2 = core.mul(a, a)
					local ap1 = core.add(a, one)
					local am1 = core.sub(a2, one)
					local ap1sq = core.mul(ap1, ap1)

					expect_bint_eq(algorithms.sqrt_newton(a2), a)
					expect_bint_eq(algorithms.sqrt_karatsuba(a2), a)
					expect_bint_eq(core.sqrt(a2), a)

					expect_bint_eq(algorithms.sqrt_karatsuba(am1), core.sub(a, one))
					expect_bint_eq(core.sqrt(am1), core.sub(a, one))

					expect_bint_eq(algorithms.sqrt_karatsuba(core.sub(ap1sq, one)), a)
					expect_bint_eq(core.sqrt(core.sub(ap1sq, one)), a)
					expect_bint_eq(algorithms.sqrt_karatsuba(ap1sq), ap1)
					expect_bint_eq(core.sqrt(ap1sq), ap1)
				end

				-- Random-looking non-squares: exact differential + inequalities.
				for len = 4, 180, 7 do
					local n = make_big(len, 1201 + len * 19, 1)
					local sN = algorithms.sqrt_newton(n)
					local sK = algorithms.sqrt_karatsuba(n)
					local sC = core.sqrt(n)
					expect_bint_eq(sN, sC)
					expect_bint_eq(sK, sC)
					expect(core.le(core.mul(sC, sC), n)).to.equal(true)
					local s1 = core.add(sC, one)
					expect(core.lt(n, core.mul(s1, s1))).to.equal(true)
				end
			end)
		end)
	end)
end
