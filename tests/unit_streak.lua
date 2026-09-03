-- Spec: BEHAVIOR_SPEC.md section 1.5 (Streak logic)
local T = require("runner")
local H = require("harness")
local GW, Mock = H.GW, H.Mock

-- Sets the streak table directly; every case here is about the transition
-- from a specific known prior state, so building it explicitly is clearer
-- than playing games to arrive at it.
local function setStreak(current, best, lastDate)
    GuildWordleDB.streak = {current = current, best = best, lastDate = lastDate}
end

local function s()
    return GuildWordleDB.streak
end

T.suite("1.5 Streak logic", function()

    -- The streak measures participation, not success: finishing today's game
    -- extends it win or lose, and only a skipped day breaks it. That's why
    -- RecordStreakResult takes no argument.

    T.test("UNIT-STREAK-01: first-ever play => current 1, best 1, lastDate today", function()
        H.freshDB()
        H.setDate(2026, 3, 15)
        setStreak(0, 0, nil)
        GW.RecordStreakResult()
        T.assertEquals(s().current, 1)
        T.assertEquals(s().best, 1)
        T.assertEquals(s().lastDate, H.dateStr())
    end)

    T.test("UNIT-STREAK-02: win with lastDate == yesterday extends the streak", function()
        H.freshDB()
        H.setDate(2026, 3, 14)
        local yesterday = H.dateStr()
        H.setDate(2026, 3, 15)
        setStreak(3, 5, yesterday)
        GW.RecordStreakResult()
        T.assertEquals(s().current, 4, "should extend to 4")
        T.assertEquals(s().best, 5, "best stays at the higher existing value")
    end)

    T.test("UNIT-STREAK-02b: extending past the old best raises best", function()
        H.freshDB()
        H.setDate(2026, 3, 14)
        local yesterday = H.dateStr()
        H.setDate(2026, 3, 15)
        setStreak(5, 5, yesterday)
        GW.RecordStreakResult()
        T.assertEquals(s().current, 6)
        T.assertEquals(s().best, 6)
    end)

    T.test("UNIT-STREAK-03: play with lastDate == yesterday but current 0 starts fresh at 1", function()
        H.freshDB()
        H.setDate(2026, 3, 14)
        local yesterday = H.dateStr()
        H.setDate(2026, 3, 15)
        -- current == 0 with a yesterday lastDate is only reachable from
        -- legacy data written under the old lose-resets-streak rule; the
        -- restart-at-1 path still has to handle it cleanly.
        setStreak(0, 4, yesterday)
        GW.RecordStreakResult()
        T.assertEquals(s().current, 1, "not extended from 0")
        T.assertEquals(s().best, 4)
    end)

    T.test("UNIT-STREAK-04: play after a skipped day restarts at 1", function()
        H.freshDB()
        H.setDate(2026, 3, 10)
        local longAgo = H.dateStr()
        H.setDate(2026, 3, 15)
        setStreak(9, 9, longAgo)
        GW.RecordStreakResult()
        T.assertEquals(s().current, 1, "a gap breaks the streak regardless of how high it was")
        T.assertEquals(s().best, 9, "best is unaffected")
    end)

    T.test("UNIT-STREAK-05: a LOSS extends the streak just like a win (participation, not skill)", function()
        H.freshDB()
        H.setDate(2026, 3, 14)
        local yesterday = H.dateStr()
        H.setDate(2026, 3, 15)
        setStreak(7, 7, yesterday)
        GW.RecordStreakResult()   -- the caller lost today; must not matter
        T.assertEquals(s().current, 8, "losing must not break the streak")
        T.assertEquals(s().best, 8, "and it still counts toward best")
        T.assertEquals(s().lastDate, H.dateStr())
    end)

    T.test("UNIT-STREAK-06: same-day second call is a no-op", function()
        H.freshDB()
        H.setDate(2026, 3, 15)
        setStreak(0, 0, nil)
        GW.RecordStreakResult()
        T.assertEquals(s().current, 1)
        -- A second character finishing the same day must not double-count.
        GW.RecordStreakResult()
        T.assertEquals(s().current, 1, "second same-day call must not increment again")
        T.assertEquals(s().best, 1)
    end)

    T.test("UNIT-STREAK-07: consecutive days always accumulate, regardless of win/loss", function()
        H.freshDB()
        setStreak(0, 0, nil)
        local prevBest = 0
        for i = 1, 9 do
            H.setDate(2026, 3, i)          -- consecutive days, no gaps
            GW.RecordStreakResult()
            T.assertTrue(s().best >= prevBest,
                "best decreased at step " .. i .. " (" .. prevBest .. " -> " .. s().best .. ")")
            T.assertEquals(s().current, i, "day " .. i .. " should be a streak of " .. i)
            prevBest = s().best
        end
        T.assertEquals(prevBest, 9, "9 consecutive days played => best of 9")
    end)

    T.test("UNIT-STREAK-07b: a gap mid-sequence is the only thing that resets", function()
        H.freshDB()
        setStreak(0, 0, nil)
        for i = 1, 4 do
            H.setDate(2026, 3, i)
            GW.RecordStreakResult()
        end
        T.assertEquals(s().current, 4)

        H.setDate(2026, 3, 7)     -- skipped the 5th and 6th
        GW.RecordStreakResult()
        T.assertEquals(s().current, 1, "the gap resets current")
        T.assertEquals(s().best, 4, "but best remembers the earlier run")

        H.setDate(2026, 3, 8)
        GW.RecordStreakResult()
        T.assertEquals(s().current, 2, "and it builds again from there")
        T.assertEquals(s().best, 4)
    end)

    T.test("UNIT-STREAK-08: CurrentStreak zeroes a stale streak at read time and persists it", function()
        H.freshDB()
        H.setDate(2026, 3, 10)
        local longAgo = H.dateStr()
        H.setDate(2026, 3, 15)
        setStreak(6, 6, longAgo)
        local read = GW.CurrentStreak()
        T.assertEquals(read.current, 0, "stale streak should read as broken")
        T.assertEquals(GuildWordleDB.streak.current, 0, "and the zeroing must be persisted, not just returned")
        T.assertEquals(GuildWordleDB.streak.best, 6, "best untouched")
    end)

    T.test("UNIT-STREAK-09: lastDate == today reads as still active", function()
        H.freshDB()
        H.setDate(2026, 3, 15)
        setStreak(4, 4, H.dateStr())
        T.assertEquals(GW.CurrentStreak().current, 4)
    end)

    T.test("UNIT-STREAK-10: lastDate == yesterday reads as still active (grace period)", function()
        H.freshDB()
        H.setDate(2026, 3, 14)
        local yesterday = H.dateStr()
        H.setDate(2026, 3, 15)
        setStreak(4, 4, yesterday)
        T.assertEquals(GW.CurrentStreak().current, 4, "yesterday is still within the window to extend today")
    end)

    T.test("UNIT-STREAK-11: current == 0 => CurrentStreak leaves lastDate alone", function()
        H.freshDB()
        H.setDate(2026, 3, 10)
        local longAgo = H.dateStr()
        H.setDate(2026, 3, 15)
        setStreak(0, 3, longAgo)
        GW.CurrentStreak()
        T.assertEquals(GuildWordleDB.streak.lastDate, longAgo, "lastDate must not be rewritten by a read")
        T.assertEquals(GuildWordleDB.streak.best, 3)
    end)

end)

T.run()
