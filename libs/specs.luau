--!nocheck
--draft 2

--[[--
specs - minimal spec runner for Lune
authored by OminousVibes (https://github.com/OminousVibes)

Small, self-contained spec runner used by this repository. It supports
recursive `*.spec.luau` discovery, a BDD-style DSL (`describe` / `it` /
`expect`), `.only` / `.skip` variants, hooks, and tag-based filtering.

## Spec module contract

Preferred form:

    return function(t)
        local describe, it, expect = t.describe, t.it, t.expect
        ...
    end

Also supported (via environment injection):

    return function()
        describe(...)
    end
]]

--# IMPORTS

local fs = require("@lune/fs")
local process = require("@lune/process")

--# TYPES

type Hook = () -> ()

type TagList = { string }

type TagMode = "any" | "all"

type NodeOpts = {
	only: boolean?,
	skip: boolean?,
	tags: TagList?,
}

type SuiteContext = {
	name: string,
	only: boolean,
	skip: boolean,
	tags: TagList,
	beforeEach: { Hook },
	afterEach: { Hook },
}

type TestCase = {
	name: string,
	fn: () -> (),
	only: boolean,
	skip: boolean,
	beforeHooks: { Hook },
	afterHooks: { Hook },
	file: string,
	tags: TagList,
}

type Options = {
	testsRoot: string,
	includeTags: TagList,
	excludeTags: TagList,
	tagMode: TagMode,
	listTags: boolean,
	failFast: boolean,
	quiet: boolean,
}

type Summary = {
	passed: number,
	failed: number,
	skipped: number,
	filtered: number,
	loadFailed: number,
	total: number,
}

--# VALUE / EQUALITY
-- Private formatting helpers used by expect() failure messages.

-- Prefix check helper used for CLI parsing and path normalization.
local function startsWith(s: string, prefix: string): boolean
	return string.sub(s, 1, #prefix) == prefix
end

-- Parse and validate a tag name, normalizing to lowercase for stable matching.
local function normalizeTag(raw: any, source: string): string
	assert(type(raw) == "string", source .. ": tag must be a string")
	assert(#raw > 0, source .. ": tag must be non-empty")
	local tag = string.lower(raw)
	assert(string.match(tag, "^[%w:_%-]+$") ~= nil, source .. ": invalid tag '" .. raw .. "'")
	return tag
end

-- Normalize a tag list and remove duplicates while preserving order.
local function normalizeTags(rawTags: any, source: string): TagList
	assert(type(rawTags) == "table", source .. ": tags must be an array of strings")
	local out: TagList = {}
	local seen: {[string]: boolean} = {}
	for i, raw in ipairs(rawTags) do
		local tag = normalizeTag(raw, source .. (" tag[%d]"):format(i))
		if not seen[tag] then
			seen[tag] = true
			table.insert(out, tag)
		end
	end
	return out
end

-- Merge two tag lists with deduplication while preserving left-to-right order.
local function mergeTags(a: TagList?, b: TagList?): TagList
	if a == nil and b == nil then
		return {}
	end
	local out: TagList = {}
	local seen: {[string]: boolean} = {}
	local function append(tags: TagList?)
		if tags == nil then return end
		for _, tag in ipairs(tags) do
			if not seen[tag] then
				seen[tag] = true
				table.insert(out, tag)
			end
		end
	end
	append(a)
	append(b)
	return out
end

-- Parse comma-separated tags (used by CLI `--tags` / `--exclude-tags`).
local function parseCsvTags(csv: string, source: string): TagList
	local out: TagList = {}
	for part in string.gmatch(csv, "[^,]+") do
		local trimmed = string.gsub(part, "^%s+", "")
		trimmed = string.gsub(trimmed, "%s+$", "")
		if #trimmed > 0 then
			table.insert(out, normalizeTag(trimmed, source))
		end
	end
	return out
end

-- Produce a stable, bounded representation for assertion messages.
local function repr(value: any, depth: number?, seen: {[any]: boolean}?): string
	local d = depth or 0
	local kind = type(value)
	if kind == "string" then
		return string.format("%q", value)
	end
	if kind ~= "table" then
		local ok, out = pcall(tostring, value)
		return ok and out or ("<" .. kind .. ">")
	end

	seen = seen or {}
	-- Prevent infinite recursion on cyclic tables.
	if seen[value] then
		return "<cycle>"
	end
	-- Keep assertion output short and readable.
	if d >= 2 then
		return "{...}"
	end

	seen[value] = true
	local keys = {}
	for k in pairs(value) do
		table.insert(keys, k)
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)

	local parts = {}
	for _, k in ipairs(keys) do
		table.insert(parts, "[" .. repr(k, d + 1, seen) .. "]=" .. repr(value[k], d + 1, seen))
	end
	seen[value] = nil
	return "{" .. table.concat(parts, ", ") .. "}"
end

-- Deep equality for plain values/tables with cycle tracking.
local function deepEqual(a: any, b: any, seen: {[any]: any}?): boolean
	if a == b then
		return true
	end

	local ta, tb = type(a), type(b)
	if ta ~= tb then
		return false
	end
	if ta ~= "table" then
		return false
	end

	seen = seen or {}
	-- Remember paired tables so recursive structures can be compared safely.
	if seen[a] ~= nil then
		return seen[a] == b
	end
	seen[a] = b

	local countA = 0
	for k, v in pairs(a) do
		countA += 1
		if not deepEqual(v, b[k], seen) then
			return false
		end
	end

	local countB = 0
	for _ in pairs(b) do
		countB += 1
	end

	return countA == countB
end

--# EXPECT

--- Create an `expect(actual)` assertion object.
--- @param actual The subject under test.
--- @return A table exposing `.to` and `.not_to` matchers.
local function createExpect(actual: any)
	-- Raise matcher failures at the matcher callsite (not inside helper frames).
	local function fail(msg: string)
		error(msg, 0)
	end

	local to = {}
	local not_to = {}

	function to.equal(expected: any, message: string?)
		if not deepEqual(actual, expected) then
			fail(message or ("expected " .. repr(expected) .. ", got " .. repr(actual)))
		end
	end

	function to.be_true(message: string?)
		if actual ~= true then
			fail(message or ("expected true, got " .. repr(actual)))
		end
	end

	function to.be_false(message: string?)
		if actual ~= false then
			fail(message or ("expected false, got " .. repr(actual)))
		end
	end

	function to.be_nil(message: string?)
		if actual ~= nil then
			fail(message or ("expected nil, got " .. repr(actual)))
		end
	end

	function to.be_type(expectedType: string, message: string?)
		local got = type(actual)
		if got ~= expectedType then
			fail(message or ("expected type " .. expectedType .. ", got " .. got))
		end
	end

	function to.match(pattern: string, message: string?)
		if type(actual) ~= "string" then
			fail("expect(...).to.match(pattern) requires a string subject")
		end
		if string.find(actual, pattern) == nil then
			fail(message or ("expected " .. repr(actual) .. " to match pattern " .. repr(pattern)))
		end
	end

	function to.throw(expectedErrorLike: string?, message: string?)
		if type(actual) ~= "function" then
			fail("expect(...).to.throw() requires a function subject")
		end
		local ok, err = pcall(actual)
		if ok then
			fail(message or "expected function to throw")
		end
		if expectedErrorLike ~= nil then
			local errStr = tostring(err)
			-- Accept either plain substring matching or Luau pattern matching.
			local plainFound = string.find(errStr, expectedErrorLike, 1, true) ~= nil
			local patternFound = string.find(errStr, expectedErrorLike) ~= nil
			if not plainFound and not patternFound then
				fail(
					message
						or ("expected thrown error to include/match "
							.. repr(expectedErrorLike)
							.. ", got "
							.. repr(errStr))
				)
			end
		end
	end

	function not_to.equal(expected: any, message: string?)
		if deepEqual(actual, expected) then
			fail(message or ("expected value not to equal " .. repr(expected)))
		end
	end

	function not_to.throw(message: string?)
		if type(actual) ~= "function" then
			fail("expect(...).not_to.throw() requires a function subject")
		end
		local ok, err = pcall(actual)
		if not ok then
			fail(message or ("expected function not to throw, got " .. repr(err)))
		end
	end

	return {
		to = to,
		not_to = not_to,
	}
end

--# CLI OPTIONS

local options: Options = {
	testsRoot = "tests",
	includeTags = {},
	excludeTags = {},
	tagMode = "any",
	listTags = false,
	failFast = false,
	quiet = false,
}

-- Parse a small flag set directly from process.args.
local function requireFlagValue(flag: string, idx: number): string
	local value = process.args[idx]
	if value == nil or startsWith(value, "--") then
		print(("Missing value for %s"):format(flag))
		process.exit(1)
	end
	return value
end

local i = 1
while i <= #process.args do
	local arg = process.args[i]
	if arg == "--tests" or arg == "--dir" then
		i += 1
		options.testsRoot = requireFlagValue(arg, i)
	elseif arg == "--tag" then
		i += 1
		local tag = normalizeTag(requireFlagValue(arg, i), arg)
		options.includeTags = mergeTags(options.includeTags, { tag })
	elseif arg == "--exclude-tag" then
		i += 1
		local tag = normalizeTag(requireFlagValue(arg, i), arg)
		options.excludeTags = mergeTags(options.excludeTags, { tag })
	elseif arg == "--tags" then
		i += 1
		options.includeTags = mergeTags(options.includeTags, parseCsvTags(requireFlagValue(arg, i), arg))
	elseif arg == "--exclude-tags" then
		i += 1
		options.excludeTags = mergeTags(options.excludeTags, parseCsvTags(requireFlagValue(arg, i), arg))
	elseif arg == "--tag-mode" then
		i += 1
		local mode = string.lower(requireFlagValue(arg, i))
		if mode ~= "any" and mode ~= "all" then
			print(("Invalid --tag-mode %q (expected 'any' or 'all')"):format(mode))
			process.exit(1)
		end
		options.tagMode = mode :: TagMode
	elseif arg == "--list-tags" then
		options.listTags = true
	elseif arg == "--fail-fast" then
		options.failFast = true
	elseif arg == "--quiet" then
		options.quiet = true
	elseif arg == "--help" then
		print(
			"Usage: lune run libs/specs.luau [--tests <path>] [--tag <name>] [--exclude-tag <name>] [--tags <a,b>] [--exclude-tags <a,b>] [--tag-mode <any|all>] [--list-tags] [--fail-fast] [--quiet]"
		)
		process.exit(0)
	elseif not startsWith(arg, "--") then
		options.testsRoot = arg
	end
	i += 1
end

--# REGISTRY

local tests: { TestCase } = {}
local loadFailures: { string } = {}
local hasOnly = false
local currentSpecPath = "<unknown>"

-- Collect load/definition failures and print them with test failures later.
local function addLoadFailure(msg: string)
	table.insert(loadFailures, msg)
end

local suiteStack: { SuiteContext } = {}

-- Reset the suite stack for a new spec file; the file path becomes the root suite.
local function pushFileSuite(filePath: string)
	suiteStack = {
		{
			name = filePath,
			only = false,
			skip = false,
			tags = {},
			beforeEach = {},
			afterEach = {},
		},
	}
end

-- Current suite is always the top of the stack during registration.
local function currentSuite(): SuiteContext
	return suiteStack[#suiteStack]
end

-- Join nested suite names into a single display name.
local function currentTestName(testName: string): string
	local parts = {}
	for _, suite in ipairs(suiteStack) do
		table.insert(parts, suite.name)
	end
	table.insert(parts, testName)
	return table.concat(parts, " > ")
end

-- True when any ancestor suite is marked `.only`.
local function anySuiteOnly(): boolean
	for _, suite in ipairs(suiteStack) do
		if suite.only then
			return true
		end
	end
	return false
end

-- True when any ancestor suite is marked `.skip`.
local function anySuiteSkip(): boolean
	for _, suite in ipairs(suiteStack) do
		if suite.skip then
			return true
		end
	end
	return false
end

-- before_each hooks run outermost-to-innermost.
local function collectBeforeHooks(): { Hook }
	local hooks = {}
	for _, suite in ipairs(suiteStack) do
		for _, hook in ipairs(suite.beforeEach) do
			table.insert(hooks, hook)
		end
	end
	return hooks
end

-- after_each hooks run innermost-to-outermost.
local function collectAfterHooks(): { Hook }
	local hooks = {}
	for idx = #suiteStack, 1, -1 do
		local suite = suiteStack[idx]
		for _, hook in ipairs(suite.afterEach) do
			table.insert(hooks, hook)
		end
	end
	return hooks
end

--# DSL

-- Register a suite and execute its definition body immediately.
-- Supports optional metadata via `opts`, including inherited tags.
local function registerDescribe(name: string, body: () -> (), opts: NodeOpts?)
	assert(type(name) == "string", "describe(name, body): name must be a string")
	assert(type(body) == "function", "describe(name, body): body must be a function")

	local parent = currentSuite()
	local ownTags = if opts ~= nil and opts.tags ~= nil then normalizeTags(opts.tags, "describe(name, body, opts)") else {}
	local suite: SuiteContext = {
		name = name,
		only = opts and opts.only == true or false,
		skip = opts and opts.skip == true or false,
		tags = mergeTags(parent.tags, ownTags),
		beforeEach = {},
		afterEach = {},
	}

	if suite.only then
		hasOnly = true
	end

	table.insert(suiteStack, suite)
	local ok, err = pcall(body)
	table.remove(suiteStack)
	if not ok then
		error(("describe '%s' failed during definition: %s"):format(name, tostring(err)), 0)
	end
end

-- Register a test case using the current suite stack snapshot, optionally with tags.
local function registerIt(name: string, body: (() -> ())?, opts: NodeOpts?)
	assert(type(name) == "string", "it(name, body): name must be a string")
	local fn = body
	if fn == nil then
		fn = function() end
	end
	assert(type(fn) == "function", "it(name, body): body must be a function")

	-- Test-level flags inherit `.only` / `.skip` from any enclosing suite.
	local only = (opts and opts.only == true or false) or anySuiteOnly()
	local skip = (opts and opts.skip == true or false) or anySuiteSkip()
	local ownTags = if opts ~= nil and opts.tags ~= nil then normalizeTags(opts.tags, "it(name, body, opts)") else {}

	if only then
		hasOnly = true
	end

	table.insert(tests, {
		name = currentTestName(name),
		fn = fn,
		only = only,
		skip = skip,
		beforeHooks = collectBeforeHooks(),
		afterHooks = collectAfterHooks(),
		file = currentSpecPath,
		tags = mergeTags(currentSuite().tags, ownTags),
	})
end

--- Register a `before_each` hook on the current suite.
--- @param hook Hook callback.
local function beforeEach(hook: Hook)
	assert(type(hook) == "function", "before_each(hook): hook must be a function")
	table.insert(currentSuite().beforeEach, hook)
end

--- Register an `after_each` hook on the current suite.
--- @param hook Hook callback.
local function afterEach(hook: Hook)
	assert(type(hook) == "function", "after_each(hook): hook must be a function")
	table.insert(currentSuite().afterEach, hook)
end

local api = {}

-- Build an opts table with merged tags for `.tags(...)` sugar.
local function optsWithTags(tags: TagList, opts: NodeOpts?): NodeOpts
	assert(type(tags) == "table", "tags(...): tags must be an array of strings")
	local merged = if opts ~= nil and opts.tags ~= nil then mergeTags(tags, opts.tags) else tags
	local out: NodeOpts = {
		only = opts and opts.only or nil,
		skip = opts and opts.skip or nil,
		tags = merged,
	}
	return out
end

-- Callable `describe` table with `.only` / `.skip` variants.
local describeApi = {}
setmetatable(describeApi, {
	__call = function(_, name: string, body: () -> (), opts: NodeOpts?)
		registerDescribe(name, body, opts)
	end,
})
describeApi.only = function(name: string, body: () -> (), opts: NodeOpts?)
	registerDescribe(name, body, {
		only = true,
		skip = opts and opts.skip or nil,
		tags = opts and opts.tags or nil,
	})
end
describeApi.skip = function(name: string, body: () -> (), opts: NodeOpts?)
	registerDescribe(name, body, {
		only = opts and opts.only or nil,
		skip = true,
		tags = opts and opts.tags or nil,
	})
end
describeApi.tags = function(tags: TagList, name: string, body: () -> (), opts: NodeOpts?)
	registerDescribe(name, body, optsWithTags(tags, opts))
end

-- Callable `it` table with `.only` / `.skip` variants.
local itApi = {}
setmetatable(itApi, {
	__call = function(_, name: string, body: (() -> ())?, opts: NodeOpts?)
		registerIt(name, body, opts)
	end,
})
itApi.only = function(name: string, body: (() -> ())?, opts: NodeOpts?)
	registerIt(name, body, {
		only = true,
		skip = opts and opts.skip or nil,
		tags = opts and opts.tags or nil,
	})
end
itApi.skip = function(name: string, body: (() -> ())?, opts: NodeOpts?)
	registerIt(name, body, {
		only = opts and opts.only or nil,
		skip = true,
		tags = opts and opts.tags or nil,
	})
end
itApi.tags = function(tags: TagList, name: string, body: (() -> ())?, opts: NodeOpts?)
	registerIt(name, body, optsWithTags(tags, opts))
end

api.describe = describeApi
api.it = itApi
api.fit = itApi.only
api.xit = itApi.skip

api.before_each = beforeEach
api.after_each = afterEach
api.beforeEach = beforeEach
api.afterEach = afterEach

api.expect = createExpect

--# DISCOVERY

--- Recursively collect `*.spec.luau` files from a directory or single file path.
--- @param path Directory or file path to scan.
--- @param out Destination array for discovered spec file paths.
local function collectSpecFiles(path: string, out: { string })
	if fs.isFile(path) then
		if string.match(path, "%.spec%.luau$") ~= nil then
			table.insert(out, path)
		end
		return
	end

	if not fs.isDir(path) then
		addLoadFailure(("tests path does not exist: %s"):format(path))
		return
	end

	local ok, entries = pcall(fs.readDir, path)
	if not ok then
		addLoadFailure(("failed to read directory %s: %s"):format(path, tostring(entries)))
		return
	end

	for _, entry in ipairs(entries) do
		local child = path .. "/" .. entry
		if fs.isDir(child) then
			collectSpecFiles(child, out)
		elseif fs.isFile(child) and string.match(entry, "%.spec%.luau$") ~= nil then
			table.insert(out, child)
		end
	end
end

-- Convert an absolute/relative file path into a require() path from libs/.
local function toRequirePath(path: string): string
	local cwdPrefix = process.cwd .. "/"
	local p = path
	if startsWith(p, cwdPrefix) then
		p = string.sub(p, #cwdPrefix + 1)
	end
	p = string.gsub(p, "%.luau$", "")
	if startsWith(p, "./") then
		p = string.sub(p, 3)
	end
	if startsWith(p, "../") then
		return p
	end
	return "../" .. p
end

-- Inject the testing DSL into zero-argument spec modules for convenience.
local function injectTestGlobals(specFn: (...any) -> ...any)
	local parentEnv = getfenv(specFn)
	local childEnv = setmetatable({
		describe = api.describe,
		it = api.it,
		expect = api.expect,
		before_each = api.before_each,
		after_each = api.after_each,
		beforeEach = api.beforeEach,
		afterEach = api.afterEach,
		fit = api.fit,
		xit = api.xit,
	}, {
		__index = parentEnv,
	})

	-- Some runtimes may reject setfenv; treat that as a load warning.
	local ok, err = pcall(setfenv, specFn, childEnv)
	if not ok then
		addLoadFailure(("warning: could not inject spec globals: %s"):format(tostring(err)))
	end
end

--- Load and execute a spec module's definition function.
--- @param specPath Filesystem path to a `*.spec.luau` module.
local function loadSpec(specPath: string)
	currentSpecPath = specPath
	pushFileSuite(specPath)

	local requirePath = toRequirePath(specPath)
	local okRequire, mod = pcall(require, requirePath)
	if not okRequire then
		addLoadFailure(("load failed for %s: %s"):format(specPath, tostring(mod)))
		return
	end

	if type(mod) ~= "function" then
		addLoadFailure(("spec must return a function for %s, got %s"):format(specPath, type(mod)))
		return
	end

	injectTestGlobals(mod)
	local okRun, errRun = pcall(mod, api)
	if not okRun then
		addLoadFailure(("definition failed for %s: %s"):format(specPath, tostring(errRun)))
	end
end

--# FILTER / RUN

-- True when a test case has a specific tag.
local function hasTag(test: TestCase, tag: string): boolean
	for _, t in ipairs(test.tags) do
		if t == tag then
			return true
		end
	end
	return false
end

-- Match include/exclude tag filters against one test.
local function passesTagFilters(test: TestCase): boolean
	for _, tag in ipairs(options.excludeTags) do
		if hasTag(test, tag) then
			return false -- exclude wins
		end
	end

	if #options.includeTags == 0 then
		return true
	end

	if options.tagMode == "all" then
		for _, tag in ipairs(options.includeTags) do
			if not hasTag(test, tag) then
				return false
			end
		end
		return true
	end

	for _, tag in ipairs(options.includeTags) do
		if hasTag(test, tag) then
			return true
		end
	end
	return false
end

-- Apply `.only` and tag filters to a discovered test.
local function shouldSelect(test: TestCase): boolean
	if hasOnly and not test.only then
		return false
	end
	if not passesTagFilters(test) then
		return false
	end
	return true
end

--- Run one test case, including hooks, and update the running summary.
--- @param test The test case to execute.
--- @param summary Mutable aggregate counters.
--- @return True when the test execution failed (used by fail-fast).
local function runOne(test: TestCase, summary: Summary): boolean
	if not shouldSelect(test) then
		summary.filtered += 1
		return false
	end

	if test.skip then
		summary.skipped += 1
		print("SKIP | " .. test.name)
		return false
	end

	summary.total += 1
	local startTime = os.clock()

	local failure: string? = nil

	for _, hook in ipairs(test.beforeHooks) do
		local ok, err = pcall(hook)
		if not ok then
			failure = "before_each failed: " .. tostring(err)
			break
		end
	end

	if failure == nil then
		local ok, err = pcall(test.fn)
		if not ok then
			failure = tostring(err)
		end
	end

	for _, hook in ipairs(test.afterHooks) do
		local ok, err = pcall(hook)
		if not ok then
			local hookErr = "after_each failed: " .. tostring(err)
			if failure == nil then
				failure = hookErr
			else
				failure = failure .. "\n" .. hookErr
			end
		end
	end

	local elapsedMs = (os.clock() - startTime) * 1000

	if failure ~= nil then
		summary.failed += 1
		print(("FAIL | %s (%.2fms)"):format(test.name, elapsedMs))
		print("  " .. failure)
		return true
	else
		summary.passed += 1
		if not options.quiet then
			print(("PASS | %s (%.2fms)"):format(test.name, elapsedMs))
		end
		return false
	end
end

--# MAIN

-- Print all discovered tags with usage counts across registered tests.
local function listDiscoveredTags()
	local counts: {[string]: number} = {}
	for _, test in ipairs(tests) do
		for _, tag in ipairs(test.tags) do
			counts[tag] = (counts[tag] or 0) + 1
		end
	end

	local names: TagList = {}
	for tag in pairs(counts) do
		table.insert(names, tag)
	end
	table.sort(names)

	if #names == 0 then
		print("No tags discovered.")
		return
	end

	print("Discovered tags:")
	for _, tag in ipairs(names) do
		print(("  %s (%d)"):format(tag, counts[tag]))
	end
end

local specFiles: { string } = {}
collectSpecFiles(options.testsRoot, specFiles)
table.sort(specFiles)

if #specFiles == 0 and #loadFailures == 0 then
	print(("No .spec.luau files found under %s"):format(options.testsRoot))
	process.exit(0)
end

for _, specPath in ipairs(specFiles) do
	loadSpec(specPath)
end

-- Print load/definition failures before execution summary output.
for _, msg in ipairs(loadFailures) do
	print("FAIL | " .. msg)
end

if options.listTags then
	listDiscoveredTags()
	if #loadFailures > 0 then
		process.exit(1)
	end
	process.exit(0)
end

local summary: Summary = {
	passed = 0,
	failed = 0,
	skipped = 0,
	filtered = 0,
	loadFailed = #loadFailures,
	total = 0,
}

for _, test in ipairs(tests) do
	local failedNow = runOne(test, summary)
	if failedNow and options.failFast then
		break
	end
end

local effectiveFailures = summary.failed + summary.loadFailed
local discovered = #tests
local considered = summary.total + summary.skipped + summary.filtered

print(
	("\nSpecs: %d passed, %d failed, %d skipped, %d filtered, %d load-failed, %d discovered, %d considered"):format(
		summary.passed,
		summary.failed,
		summary.skipped,
		summary.filtered,
		summary.loadFailed,
		discovered,
		considered
	)
)

if effectiveFailures > 0 then
	process.exit(1)
end
