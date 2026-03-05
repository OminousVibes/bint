--!nocheck
--!nolint

--[[
  benchmark.luau — compare bint, helloGMP, and AptInt

  Usage:
    lune run benchmark
]]

local mod = require("../src")
local hello_mpz = require("./base/helloGMP")
local aptint = require("./base/aptint/AptInt")
local stdio = require("@lune/stdio")

local bint = mod.bint
local core = mod.core
local safe_mul_schoolbook_split = mod.internals.algorithms.mul_schoolbook_split

local BENCH_ROUNDS = 9
local TOP_PERCENT = 0.25
local LABEL_WIDTH = 25
local TIME_WIDTH = 10
local WINNER_WIDTH = 8
local SPEEDUP_WIDTH = 12
local WIN_RATE_WIDTH = 6
local GAP_BEFORE_WINNER = "    "
local blackhole
local ASCII256_ALPHABET = (function()
	local chars = table.create(256)
	for i = 0, 255 do
		chars[i + 1] = string.char(i)
	end
	return table.concat(chars)
end)()

local function make_decimal(digits, seed)
	seed = seed or 0xCAFEBABE
	local chars = table.create(digits)

	seed = (1103515245 * seed + 12345) % 2147483648
	chars[1] = tostring((seed % 9) + 1)

	for i = 2, digits do
		seed = (1103515245 * seed + 12345) % 2147483648
		chars[i] = tostring(seed % 10)
	end

	return table.concat(chars)
end

local function warmup(n, fn)
	local count = math.max(1, math.floor(n / 5))

	for _ = 1, count do
		blackhole = fn()
	end
end

local function score_rounds(rounds)
	local sorted = table.clone(rounds)
	table.sort(sorted)
	local keep = math.max(1, math.ceil(#sorted * TOP_PERCENT))
	local sum = 0

	for i = 1, keep do
		sum += sorted[i]
	end

	return {
		best = sorted[1],
		score = sum / keep,
		keep = keep,
		sorted = sorted,
		count = #sorted,
	}
end

local function format_duration(seconds)
	local function format_sig(value, unit_scale, unit)
		local scaled = value * unit_scale
		local abs_scaled = math.abs(scaled)

		if abs_scaled == 0 then
			return "0" .. unit
		end

		local digits = math.floor(math.log10(abs_scaled)) + 1
		local decimals = math.max(0, 4 - digits)

		return string.format("%." .. tostring(decimals) .. "f%s", scaled, unit)
	end

	local abs_seconds = math.abs(seconds)
	if abs_seconds < 1e-6 then
		return format_sig(seconds, 1e9, "ns")
	end
	if abs_seconds < 1e-3 then
		return format_sig(seconds, 1e6, "us")
	end
	if abs_seconds < 1 then
		return format_sig(seconds, 1e3, "ms")
	end
	return format_sig(seconds, 1, "s")
end

local function winner_result(results)
	local ranked = {}

	if results.b then
		table.insert(ranked, { key = "b", label = "bint", score = results.b.score })
	end
	if results.g then
		table.insert(ranked, { key = "g", label = "hello", score = results.g.score })
	end
	if results.a then
		table.insert(ranked, { key = "a", label = "apt", score = results.a.score })
	end

	table.sort(ranked, function(left, right)
		return left.score < right.score
	end)

	return ranked[1], ranked[2]
end

local function speedup_text(winner, runner_up)
	if not runner_up then
		return "N/A"
	end

	return string.format("×%.2f", runner_up.score / winner.score)
end

local function format_win_rate(results, benches, winner)
	local wins = 0

	for round = 1, BENCH_ROUNDS do
		local best_key = benches[1].key
		local best_time = results[best_key].samples[round]

		for i = 2, #benches do
			local key = benches[i].key
			local time = results[key].samples[round]
			if time < best_time then
				best_key = key
				best_time = time
			end
		end

		if best_key == winner.key then
			wins += 1
		end
	end

	return string.format("%d/%d", wins, BENCH_ROUNDS)
end

local function score_cell(results, key)
	local result = results[key]
	if not result then
		return "N/A"
	end

	return format_duration(result.score)
end

local function show_progress(label, round_index)
	stdio.write(string.format("\rRunning %s (%d/%d)...", label, round_index, BENCH_ROUNDS))
end

local function clear_progress()
	stdio.write("\r" .. string.rep(" ", 120) .. "\r")
end

local function size_short_label(spec)
	local labels = {
		tiny = "XS",
		small = "S",
		medium = "M",
		large = "L",
		xlarge = "XL",
		xxlarge = "XXL",
	}

	return labels[spec.key] or spec.label
end

local function row(label, n_iter, bfn, gfn, afn)
	local benches = {}
	if bfn then
		table.insert(benches, { key = "b", fn = bfn })
	end
	if gfn then
		table.insert(benches, { key = "g", fn = gfn })
	end
	if afn then
		table.insert(benches, { key = "a", fn = afn })
	end

	local results = {}
	for _, bench_def in ipairs(benches) do
		results[bench_def.key] = { score = math.huge, best = math.huge }
		warmup(n_iter, bench_def.fn)
	end

	for round = 1, BENCH_ROUNDS do
		show_progress(label, round)
		local offset = (round - 1) % #benches
		for i = 1, #benches do
			local bench_def = benches[((i + offset - 1) % #benches) + 1]
			local t0 = os.clock()
			for _ = 1, n_iter do
				blackhole = bench_def.fn()
			end
			local per_iter = (os.clock() - t0) / n_iter
			local result = results[bench_def.key]
			result.samples = result.samples or table.create(BENCH_ROUNDS)
			result.samples[round] = per_iter
		end
	end

	for _, bench_def in ipairs(benches) do
		local summary = score_rounds(results[bench_def.key].samples)
		summary.samples = results[bench_def.key].samples
		results[bench_def.key] = summary
	end

	local winner, runner_up = winner_result(results)

	clear_progress()
	print(string.format(
		"%-" .. LABEL_WIDTH .. "s  %" .. TIME_WIDTH .. "s  %" .. TIME_WIDTH .. "s  %" .. TIME_WIDTH .. "s" .. GAP_BEFORE_WINNER .. "%-" .. WINNER_WIDTH .. "s  %-" .. SPEEDUP_WIDTH .. "s  %-" .. WIN_RATE_WIDTH .. "s",
		label,
		score_cell(results, "b"),
		score_cell(results, "g"),
		score_cell(results, "a"),
		winner.label,
		speedup_text(winner, runner_up),
		format_win_rate(results, benches, winner)
	))
end

local sizes = {
	{
		key = "tiny",
		label = "tiny",
		display_digits = "9",
		lhs = "123456789",
		rhs = "987654321",
		iters = { add = 10000, sub = 10000, mul = 10000, parse = 5000, format = 10000, scientific = 10000, isqrt = 5000 },
	},
	{
		key = "small",
		label = "small",
		display_digits = "18",
		lhs = "123456789012345678",
		rhs = "987654321098765432",
		iters = { add = 5000, sub = 5000, mul = 5000, parse = 2000, format = 5000, scientific = 5000, isqrt = 1000 },
	},
	{
		key = "medium",
		label = "medium",
		display_digits = "200",
		lhs = make_decimal(200, 0x11111111),
		rhs = make_decimal(200, 0x22222222),
		iters = { add = 2000, sub = 2000, mul = 200, parse = 500, format = 2000, scientific = 2000, isqrt = 8, endian_parse = 500, endian_format = 1000 },
	},
	{
		key = "large",
		label = "large",
		display_digits = "2000",
		lhs = make_decimal(2000, 0x33333333),
		rhs = make_decimal(2000, 0x44444444),
		iters = { add = 500, sub = 500, mul = 10, parse = 50, format = 200, scientific = 200, isqrt = 1, endian_parse = 50, endian_format = 50 },
	},
	{
		key = "xlarge",
		label = "xlarge",
		display_digits = "10k",
		lhs = make_decimal(10000, 0x55555555),
		rhs = make_decimal(10000, 0x66666666),
		iters = { parse = 10, format = 20, scientific = 20, endian_parse = 2, endian_format = 1 },
	},
	{
		key = "xxlarge",
		label = "xxlarge",
		display_digits = "50k",
		lhs = make_decimal(50000, 0x77777777),
		rhs = make_decimal(50000, 0x88888888),
		iters = { add = 10, sub = 10, mul = 1, parse = 2, format = 2, scientific = 5, endian_parse = 1, endian_format = 1 },
	},
}

local size_by_key = {}
local values = {}
for _, spec in ipairs(sizes) do
	size_by_key[spec.key] = spec
	values[spec.key] = {
		dec1 = spec.lhs,
		dec2 = spec.rhs,
		b = { a = bint(spec.lhs), c = bint(spec.rhs) },
		g = { a = hello_mpz(spec.lhs), c = hello_mpz(spec.rhs) },
		a = { a = aptint.new(spec.lhs), c = aptint.new(spec.rhs) },
	}
end

for _, key in ipairs({ "medium", "large", "xlarge", "xxlarge" }) do
	local entry = values[key]
	entry.be = {
		b = bint.to_be(entry.b.a, true),
		g = entry.g.a:toBase(256, ASCII256_ALPHABET),
	}
end

local function size_label(prefix, spec)
	return string.format("%-5s %-2s (~%s)", prefix, size_short_label(spec), spec.display_digits)
end

local function run_size_rows(title, prefix, keys, iter_key, bfn, gfn, afn)
	print("\n-- " .. title)

	for _, key in ipairs(keys) do
		local spec = size_by_key[key]
		local entry = values[key]

		row(
			size_label(prefix, spec),
			spec.iters[iter_key],
			bfn and function()
				return bfn(entry)
			end or nil,
			gfn and function()
				return gfn(entry)
			end or nil,
			afn and function()
				return afn(entry)
			end or nil
		)
	end
end

print(string.format(
	"Scoring: %d rounds, %d%% fastest rounds averaged; execution order rotates each round.\n",
	BENCH_ROUNDS,
	math.floor(TOP_PERCENT * 100 + 0.5)
))
print(stdio.style("bold") .. string.format(
	"%-" .. LABEL_WIDTH .. "s  %" .. TIME_WIDTH .. "s  %" .. TIME_WIDTH .. "s  %" .. TIME_WIDTH .. "s" .. GAP_BEFORE_WINNER .. "%-" .. WINNER_WIDTH .. "s  %-" .. SPEEDUP_WIDTH .. "s  %-" .. WIN_RATE_WIDTH .. "s",
	"Operation",
	"bint",
	"hello",
	"Apt",
	"winner",
	"speedup",
	"win%"
) .. stdio.style("reset"))
print(string.rep("─", LABEL_WIDTH + TIME_WIDTH * 3 + WINNER_WIDTH + SPEEDUP_WIDTH + WIN_RATE_WIDTH + #GAP_BEFORE_WINNER + 10))

run_size_rows(
	"Addition",
	"add",
	{ "tiny", "small", "medium", "large", "xxlarge" },
	"add",
	function(v)
		return v.b.a + v.b.c
	end,
	function(v)
		return v.g.a + v.g.c
	end,
	function(v)
		return v.a.a + v.a.c
	end
)

run_size_rows(
	"Subtraction",
	"sub",
	{ "tiny", "small", "medium", "large", "xxlarge" },
	"sub",
	function(v)
		return v.b.a - v.b.c
	end,
	function(v)
		return v.g.a - v.g.c
	end,
	function(v)
		return v.a.a - v.a.c
	end
)

-- bint dispatch: schoolbook / Karatsuba / Toom-3 based on the current internals.tuning thresholds
-- helloGMP dispatch: small -> schoolbook, <=10 -> comba, <=40 -> comba, >40 -> Karatsuba
run_size_rows(
	"Multiplication",
	"mul",
	{ "tiny", "small", "medium", "large", "xxlarge" },
	"mul",
	function(v)
		return v.b.a * v.b.c
	end,
	function(v)
		return v.g.a * v.g.c
	end,
	function(v)
		return v.a.a * v.a.c
	end
)

print("\n-- Division")
row(
	"div   XXL/XL (~50k/~10k)",
	2,
	function()
		return core.idiv(values.xxlarge.b.a, values.xlarge.b.a)
	end,
	function()
		local q, _ = hello_mpz.divmod(values.xxlarge.g.a, values.xlarge.g.a)
		return q
	end,
	function()
		return values.xxlarge.a.a / values.xlarge.a.a
	end
)
row(
	"div   XL/L (~10k/~2k)",
	25,
	function()
		return core.idiv(values.xlarge.b.a, values.large.b.a)
	end,
	function()
		local q, _ = hello_mpz.divmod(values.xlarge.g.a, values.large.g.a)
		return q
	end,
	function()
		return values.xlarge.a.a / values.large.a.a
	end
)
row(
	"div   L/M (~2k/~200)",
	200,
	function()
		return core.idiv(values.large.b.a, values.medium.b.a)
	end,
	function()
		local q, _ = hello_mpz.divmod(values.large.g.a, values.medium.g.a)
		return q
	end,
	function()
		return values.large.a.a / values.medium.a.a
	end
)
row(
	"div   L/S (~2k/~18)",
	500,
	function()
		return core.idiv(values.large.b.a, values.small.b.a)
	end,
	function()
		local q, _ = hello_mpz.divmod(values.large.g.a, values.small.g.a)
		return q
	end,
	function()
		return values.large.a.a / values.small.a.a
	end
)
row(
	"div   M/XS (~200/~9)",
	1500,
	function()
		return core.idiv(values.medium.b.a, values.tiny.b.a)
	end,
	function()
		local q, _ = hello_mpz.divmod(values.medium.g.a, values.tiny.g.a)
		return q
	end,
	function()
		return values.medium.a.a / values.tiny.a.a
	end
)

print("\n-- Exponentiation (a^n)")
local pow_exponents = { 5, 10, 30, 60 }
local pow_iters = { [5] = 1000, [10] = 500, [30] = 50, [60] = 10 }
local pow_labels = { [5] = "~90 dig", [10] = "~180 dig", [30] = "~540 dig", [60] = "~1080 dig" }
local pow_base = {
	b = values.small.b.a,
	g = values.small.g.a,
	a = values.small.a.a,
}
local pow_exp = { b = {}, g = {}, a = {} }

for _, exp in ipairs(pow_exponents) do
	pow_exp.b[exp] = bint(tostring(exp))
	pow_exp.g[exp] = hello_mpz(tostring(exp))
	pow_exp.a[exp] = aptint.new(tostring(exp))
end

for _, exp in ipairs(pow_exponents) do
	row(
		string.format("pow   a^%-2d   (%s)", exp, pow_labels[exp]),
		pow_iters[exp],
		function()
			return core.pow(pow_base.b, pow_exp.b[exp])
		end,
		function()
			return pow_base.g:pow(pow_exp.g[exp])
		end,
		function()
			return pow_base.a ^ pow_exp.a[exp]
		end
	)
end

print("\n-- Integer square root")
for _, key in ipairs({ "tiny", "small", "medium", "large" }) do
	local spec = size_by_key[key]
	local entry = values[key]
	local bsq = entry.b.a * entry.b.a
	local gsq = entry.g.a * entry.g.a
	local asq = entry.a.a * entry.a.a

	row(
		string.format("isqrt %-2s^2 (~%s)", size_short_label(spec), spec.display_digits),
		spec.iters.isqrt,
		function()
			return core.sqrt(bsq)
		end,
		function()
			return gsq:isqrt()
		end,
		function()
			return asq:sqrt()
		end
	)
end

run_size_rows(
	"String -> bigint  (from_string)",
	"parse",
	{ "tiny", "small", "medium", "large", "xlarge", "xxlarge" },
	"parse",
	function(v)
		return bint(v.dec1)
	end,
	function(v)
		return hello_mpz(v.dec1)
	end,
	function(v)
		return aptint.new(v.dec1)
	end
)

run_size_rows(
	"bigint -> string  (base 10)",
	"format",
	{ "tiny", "small", "medium", "large", "xlarge", "xxlarge" },
	"format",
	function(v)
		return bint.to_string(v.b.a)
	end,
	function(v)
		return v.g.a:toString()
	end,
	function(v)
		return v.a.a:ToString()
	end
)

run_size_rows(
	"bigint -> bytes  (big-endian)",
	"to_be",
	{ "medium", "large", "xlarge" },
	"endian_format",
	function(v)
		return bint.to_be(v.b.a, true)
	end,
	function(v)
		return v.g.a:toBase(256, ASCII256_ALPHABET)
	end,
	nil
)

run_size_rows(
	"bytes -> bigint  (big-endian)",
	"from_be",
	{ "medium", "large", "xlarge" },
	"endian_parse",
	function(v)
		return bint.from_be(v.be.b)
	end,
	function(v)
		return hello_mpz.fromBase(v.be.g, 256, ASCII256_ALPHABET)
	end,
	nil
)

run_size_rows(
	"to sci (lossy)",
	"sci",
	{ "tiny", "small", "medium", "large", "xlarge", "xxlarge" },
	"scientific",
	function(v)
		return bint.to_sci(v.b.a)
	end,
	function(v)
		return v.g.a:toScientific()
	end,
	nil
)

print("\n-- Correctness quick-check")
do
	local checks = 0
	local failures = {}

	local function record_failure(lib, key, msg)
		table.insert(failures, string.format("%s %-7s %s", lib, key, msg))
	end

	local function check_isqrt(lib, key, n, root, root_plus_one, root_sq, root_plus_one_sq, expected)
		checks += 1
		if root_sq > n or root_plus_one_sq <= n then
			record_failure(lib, key, "violates isqrt inequality (r^2 <= n < (r+1)^2)")
			return
		end
		if expected and root ~= expected then
			record_failure(lib, key, "failed exact square check")
		end
	end

	local function run_isqrt_case(case)
		local one_b = bint.one()
		local one_g = hello_mpz("1")
		local one_a = aptint.new("1")

		local a_b = bint(case.a)
		local a_g = hello_mpz(case.a)
		local a_a = aptint.new(case.a)

		local n_b = a_b * a_b
		local n_g = a_g * a_g
		local n_a = a_a * a_a
		if case.minus_one then
			n_b -= one_b
			n_g -= one_g
			n_a -= one_a
		end

		local r_b = core.sqrt(n_b)
		local r_g = n_g:isqrt()
		local r_a = n_a:sqrt()
		check_isqrt("bint ", case.label, n_b, r_b, r_b + one_b, r_b * r_b, (r_b + one_b) * (r_b + one_b), case.expected and a_b or nil)
		check_isqrt("hello", case.label, n_g, r_g, r_g + one_g, r_g * r_g, (r_g + one_g) * (r_g + one_g), case.expected and a_g or nil)
		check_isqrt("apt  ", case.label, n_a, r_a, r_a + one_a, r_a * r_a, (r_a + one_a) * (r_a + one_a), case.expected and a_a or nil)
	end

	local function check_match(lib, key, got, expected, what)
		checks += 1
		if got ~= expected then
			record_failure(lib, key, string.format("%s mismatch against schoolbook-split oracle", what))
		end
	end

	local function max_limb_decimal(limb_count)
		local max_limb = 2 ^ 24 - 1
		local limbs = table.create(limb_count, max_limb)
		return bint.to_string(bint.from_limbs(limbs, 1))
	end

	local function oracle_pow_simple(base_b, exp)
		local acc = bint.one()
		for _ = 1, exp do
			acc = safe_mul_schoolbook_split(acc, base_b)
		end
		return acc
	end

	local function run_pow_case(case)
		local base_dec = max_limb_decimal(case.limb_count)
		local exp_dec = tostring(case.exp)
		local base_b = bint(base_dec)
		local expected = bint.to_string(oracle_pow_simple(base_b, case.exp))

		local got_b = bint.to_string(core.pow(base_b, bint.from_int(case.exp)))
		local got_g = hello_mpz(base_dec):pow(hello_mpz(exp_dec)):toString()
		local got_a = (aptint.new(base_dec) ^ aptint.new(case.exp)):ToString()

		check_match("bint ", case.label, got_b, expected, "pow")
		check_match("hello", case.label, got_g, expected, "pow")
		check_match("apt  ", case.label, got_a, expected, "pow")
	end

	local function run_mul_case(case)
		local base_dec = max_limb_decimal(case.limb_count)
		local base_b = bint(base_dec)
		local lhs_b = safe_mul_schoolbook_split(base_b, base_b)
		local rhs_b = base_b
		local expected = bint.to_string(safe_mul_schoolbook_split(lhs_b, rhs_b))

		local lhs_dec = bint.to_string(lhs_b)
		local rhs_dec = bint.to_string(rhs_b)
		local got_b = bint.to_string(core.mul(lhs_b, rhs_b))
		local got_g = (hello_mpz(lhs_dec) * hello_mpz(rhs_dec)):toString()
		local got_a = (aptint.new(lhs_dec) * aptint.new(rhs_dec)):ToString()

		check_match("bint ", case.label, got_b, expected, "mul")
		check_match("hello", case.label, got_g, expected, "mul")
		check_match("apt  ", case.label, got_a, expected, "mul")
	end

	-- Only keep the currently failing isqrt checks.
	local isqrt_cases = {
		{ label = "med-200d", a = make_decimal(200, 0x11111111), expected = true },
		{ label = "med-200d-neighbor", a = make_decimal(200, 0x11111111), minus_one = true },
		{ label = "large-2k", a = make_decimal(2000, 0x33333333), expected = true },
		{ label = "large-2k-neighbor", a = make_decimal(2000, 0x33333333), minus_one = true },
	}
	for _, case in ipairs(isqrt_cases) do
		run_isqrt_case(case)
	end

	local pow_cases = {
		{ label = "pow-base^34-1", limb_count = 34, exp = 3 },
	}
	for _, case in ipairs(pow_cases) do
		run_pow_case(case)
	end

	local mul_cases = {
		{ label = "mul-base^68x34", limb_count = 34 },
	}
	for _, case in ipairs(mul_cases) do
		run_mul_case(case)
	end

	print(string.format("Checks: %d, Failures: %d", checks, #failures))
	if #failures > 0 then
		for _, line in ipairs(failures) do
			print("  - " .. line)
		end
	end
end

print()
print("Done.")
