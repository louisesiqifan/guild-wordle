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

    T.test("UNIT-STREAK-01: first-ever win => current 1, best 1, lastDate today", function()
        H.freshDB()
        H.setDate(2026, 3, 15)
        setStreak(0, 0, nil)
        GW.RecordStreakResult(true)
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
        GW.RecordStreakResult(true)
        T.assertEquals(s().current, 4, "should extend to 4")
        T.assertEquals(s().best, 5, "best stays at the higher existing value")
    end)

    T.test("UNIT-STREAK-02b: extending past the old best raises best", function()
        H.freshDB()
        H.setDate(2026, 3, 14)
        local yesterday = H.dateStr()
        H.setDate(2026, 3, 15)
        setStreak(5, 5, yesterday)
        GW.RecordStreakResult(true)
        T.assertEquals(s().current, 6)
        T.assertEquals(s().best, 6)
    end)

    T.test("UNIT-STREAK-03: win with lastDate == yesterday but current 0 starts fresh at 1", function()
        H.freshDB()
        H.setDate(2026, 3, 14)
        local yesterday = H.dateStr()
        H.setDate(2026, 3, 15)
        setStreak(0, 4, yesterday)   -- lost yesterday: current was zeroed
        GW.RecordStreakResult(true)
        T.assertEquals(s().current, 1, "not extended from 0")
        T.assertEquals(s().best, 4)
    end)

    T.test("UNIT-STREAK-04: win after a skipped day restarts at 1", function()
        H.freshDB()
        H.setDate(2026, 3, 10)
        local longAgo = H.dateStr()
        H.setDate(2026, 3, 15)
        setStreak(9, 9, longAgo)
        GW.RecordStreakResult(true)
        T.assertEquals(s().current, 1, "a gap breaks the streak regardless of how high it was")
        T.assertEquals(s().best, 9, "best is unaffected")
    end)

    T.test("UNIT-STREAK-05: loss zeroes current, keeps best, stamps today", function()
        H.freshDB()
        H.setDate(2026, 3, 14)
        local yesterday = H.dateStr()
        H.setDate(2026, 3, 15)
        setStreak(7, 7, yesterday)
        GW.RecordStreakResult(false)
        T.assertEquals(s().current, 0)
        T.assertEquals(s().best, 7)
        T.assertEquals(s().lastDate, H.dateStr())
    end)

    T.test("UNIT-STREAK-06: same-day second call is a no-op, even a losing one after a win", function()
        H.freshDB()
        H.setDate(2026, 3, 15)
        setStreak(0, 0, nil)
        GW.RecordStreakResult(true)
        T.assertEquals(s().current, 1)
        -- An alt finishing (and losing) the same day must not wipe the win.
        GW.RecordStreakResult(false)
        T.assertEquals(s().current, 1, "second same-day call must not zero the streak")
        T.assertEquals(s().best, 1)
    end)

    T.test("UNIT-STREAK-07: best never decreases across a long mixed sequence", function()
        H.freshDB()
        setStreak(0, 0, nil)
        local seq = {true, true, true, false, true, false, false, true, true}
        local prevBest = 0
        for i, won in ipairs(seq) do
            H.setDate(2026, 3, i)          -- consecutive days, no gaps
            GW.RecordStreakResult(won)
            T.assertTrue(s().best >= prevBest,
                "best decreased at step " .. i .. " (" .. prevBest .. " -> " .. s().best .. ")")
            prevBest = s().best
        end
        T.assertEquals(prevBest, 3, "longest run in the sequence is 3")
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
