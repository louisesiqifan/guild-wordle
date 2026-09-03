-- Spec: BEHAVIOR_SPEC.md section 1.1 (Word selection)
local T = require("runner")
local H = require("harness")
local GW, Mock = H.GW, H.Mock

T.suite("1.1 Word selection", function()

    T.test("UNIT-WORD-01: same date, called twice, returns the identical word", function()
        H.freshDB()
        H.setDate(2026, 3, 15)
        local w1 = GW.CurrentWord()
        local w2 = GW.CurrentWord()
        T.assertEquals(w1, w2)
    end)

    T.test("UNIT-WORD-02: date affects the word (checked over a range, not one hardcoded pair, to avoid flakiness from a coincidental collision)", function()
        H.freshDB()
        local words = {}
        local sawDifferent = false
        for day = 1, 15 do
            H.setDate(2026, 3, day)
            local w = GW.CurrentWord()
            if words[1] and w ~= words[1] then sawDifferent = true end
            words[#words + 1] = w
        end
        T.assertTrue(sawDifferent, "expected at least some variation in word across 15 different days")
    end)

    T.test("UNIT-WORD-03: missing GuildWordle_Answers => returns the ERROR sentinel, does not throw", function()
        H.freshDB()
        local saved = _G.GuildWordle_Answers
        _G.GuildWordle_Answers = nil
        local ok, result = pcall(GW._test.GetTodaysWord)
        _G.GuildWordle_Answers = saved
        T.assertTrue(ok, "GetTodaysWord must not throw when the word list is missing")
        T.assertEquals(result, "ERROR")
    end)

    T.test("UNIT-WORD-03b: empty GuildWordle_Answers => returns the ERROR sentinel", function()
        H.freshDB()
        local saved = _G.GuildWordle_Answers
        _G.GuildWordle_Answers = {}
        local result = GW._test.GetTodaysWord()
        _G.GuildWordle_Answers = saved
        T.assertEquals(result, "ERROR")
    end)

    T.test("UNIT-WORD-04: GW.CurrentWord() caches within the same day (repeated calls don't recompute)", function()
        H.freshDB()
        H.setDate(2026, 3, 15)
        local w1 = GW.CurrentWord()
        -- Sabotage the word list so a recompute would visibly produce
        -- something different/broken; if caching works, this has no effect.
        local saved = _G.GuildWordle_Answers
        _G.GuildWordle_Answers = {"WRONG"}
        local w2 = GW.CurrentWord()
        _G.GuildWordle_Answers = saved
        T.assertEquals(w2, w1, "expected the cached value, not a recompute against the sabotaged word list")
    end)

    T.test("UNIT-WORD-05: date rolling over between calls recomputes rather than staying stale", function()
        H.freshDB()
        H.setDate(2026, 3, 15)
        local w1 = GW.CurrentWord()
        H.setDate(2026, 3, 16)
        local w2 = GW.CurrentWord()
        -- Not asserting w1 ~= w2 here (see UNIT-WORD-02 for why that specific
        -- claim needs a range, not one pair) -- what matters is that the
        -- cache key (cachedWordDate) actually advanced, which we verify via
        -- GetTodaysWord() directly recomputing to the same value CurrentWord
        -- now reports.
        local recomputed = GW._test.GetTodaysWord()
        T.assertEquals(w2, recomputed, "CurrentWord() after a date change should match a fresh computation for the new date")
    end)

    T.test("UNIT-WORD-06 (regression): GW.CurrentWord() self-heals when GW.todaysWord was never set", function()
        H.freshDB()
        H.setDate(2026, 3, 15)
        GW.todaysWord = nil  -- simulate ADDON_LOADED never having primed the cache
        local ok, result = pcall(GW.CurrentWord)
        T.assertTrue(ok, "CurrentWord() must not throw even if todaysWord was never primed")
        T.assertTrue(type(result) == "string" and #result > 0, "expected a real word back")
    end)

    T.test("GW._test.SetWordForTest pins the word for guess-evaluation tests", function()
        H.freshDB()
        H.setDate(2026, 3, 15)
        GW._test.SetWordForTest("CRANE", H.dateStr())
        T.assertEquals(GW.CurrentWord(), "CRANE")
        -- Calling CurrentWord() again the same mocked day must not silently
        -- overwrite the pinned word.
        T.assertEquals(GW.CurrentWord(), "CRANE")
    end)

end)

T.run()
