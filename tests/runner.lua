-- Minimal, dependency-free test runner. No external framework (busted, etc.)
-- deliberately -- this session already hit real friction from a broken
-- local toolchain (git, Xcode CLT), so the test suite avoids adding new
-- external dependencies that could break the same way.
--
-- Usage in a test file:
--   local T = require("runner")     -- MUST be required before wow_mock,
--   local Mock = require("wow_mock") -- since wow_mock overrides _G.print to
--                                     -- capture the addon's own output, and
--                                     -- this runner needs the REAL print for
--                                     -- its own summary/failure reporting.
--   T.test("UNIT-WORD-01: same date => same word", function()
--       T.assertEquals(a, b, "optional message")
--   end)
--   ... (repeat)
--   T.run()   -- prints a summary and os.exit(1) if anything failed

local realPrint = print  -- captured now, before wow_mock can override _G.print

local M = {}

local tests = {}       -- {name=, fn=}
local currentSuite = nil

function M.test(name, fn)
    tests[#tests + 1] = {name = currentSuite and (currentSuite .. ": " .. name) or name, fn = fn}
end

-- Optional grouping: T.suite("Streak logic", function() T.test(...) ... end)
function M.suite(name, fn)
    local prev = currentSuite
    currentSuite = prev and (prev .. " > " .. name) or name
    fn()
    currentSuite = prev
end

local function fmt(v)
    if type(v) == "string" then return string.format("%q", v) end
    if type(v) == "table" then
        local parts = {}
        for k, val in pairs(v) do
            parts[#parts + 1] = tostring(k) .. "=" .. fmt(val)
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(v)
end

function M.assertTrue(v, msg)
    if not v then
        error((msg or "expected truthy value") .. " (got " .. fmt(v) .. ")", 2)
    end
end

function M.assertFalse(v, msg)
    if v then
        error((msg or "expected falsy value") .. " (got " .. fmt(v) .. ")", 2)
    end
end

function M.assertNil(v, msg)
    if v ~= nil then
        error((msg or "expected nil") .. " (got " .. fmt(v) .. ")", 2)
    end
end

function M.assertEquals(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s",
            msg or "values not equal", fmt(expected), fmt(actual)), 2)
    end
end

function M.assertNotEquals(actual, expected, msg)
    if actual == expected then
        error(string.format("%s: expected values to differ, both were %s",
            msg or "values unexpectedly equal", fmt(expected)), 2)
    end
end

-- Same-object identity, not just equal value (Lua == on tables already means
-- this, but assertSame makes the intent explicit at call sites that care).
function M.assertSame(actual, expected, msg)
    M.assertEquals(actual, expected, msg or "expected same object/value")
end

function M.assertThrows(fn, msg)
    local ok, err = pcall(fn)
    if ok then
        error((msg or "expected function to throw") .. ", but it did not", 2)
    end
    return err
end

function M.assertNoThrow(fn, msg)
    local ok, err = pcall(fn)
    if not ok then
        error((msg or "expected function not to throw") .. ", but got: " .. tostring(err), 2)
    end
end

function M.assertContains(haystack, needle, msg)
    if type(haystack) == "string" then
        if not haystack:find(needle, 1, true) then
            error(string.format("%s: %s does not contain %s",
                msg or "string does not contain substring", fmt(haystack), fmt(needle)), 2)
        end
        return
    end
    for _, v in pairs(haystack) do
        if v == needle then return end
    end
    error(string.format("%s: table does not contain %s", msg or "missing element", fmt(needle)), 2)
end

function M.run()
    local passed, failed = 0, {}
    for _, t in ipairs(tests) do
        local ok, err = pcall(t.fn)
        if ok then
            passed = passed + 1
        else
            failed[#failed + 1] = {name = t.name, err = err}
        end
    end

    realPrint(string.format("\n%d passed, %d failed (of %d)", passed, #failed, #tests))
    if #failed > 0 then
        realPrint("\nFailures:")
        for _, f in ipairs(failed) do
            realPrint(string.format("  \226\156\151 %s\n      %s", f.name, tostring(f.err)))
        end
        os.exit(1)
    else
        os.exit(0)
    end
end

return M
