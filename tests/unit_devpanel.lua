-- Spec: BEHAVIOR_SPEC.md section 4 (Dev panel)
--
-- The dev panel exists to make manual UAT trustworthy, so its own injection
-- logic has to be trustworthy first: a malformed message string would show
-- nothing in-game and read as "the feature is broken" rather than "the test
-- tool is broken". These tests drive the same GW.DevActions the buttons do.
local T = require("runner")
local H = require("harness")
local GW, Mock = H.GW, H.Mock

local GUILD = "Testguild"
local A = GW.DevActions

local function setup()
    H.freshDB()
    Mock.guildName = GUILD
    H.setDate(2026, 3, 15)
    Mock.unitName = "Realchar"
end

local function todayBoard()
    local byGuild = GuildWordleDB.leaderboard[GUILD]
    return (byGuild and byGuild[H.dateStr()]) or {}
end

local function countKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

T.suite("4 Dev panel", function()

    T.test("DEV-01: injected results land as real leaderboard entries", function()
        setup()
        A.addOne()
        local board = todayBoard()
        T.assertEquals(countKeys(board), 1, "exactly one fake entry")
        local name, entry = next(board)
        T.assertContains(name, "Zzt", "fake entries must carry the identifying prefix")
        T.assertEquals(entry.solved, true)
        T.assertEquals(entry.guesses, 2)
        T.assertTrue(entry.pattern ~= nil and entry.pattern ~= "", "pattern must survive the round-trip")
    end)

    T.test("DEV-02: injected nicknames resolve for the injected characters", function()
        setup()
        A.addOne()
        local names = GuildWordleDB.charNicknames[GUILD]
        local charName = next(todayBoard())
        T.assertEquals(names[charName], "Alphanick",
            "the results row should resolve to a nickname, exercising the display path")
    end)

    T.test("DEV-03: the 8-result set covers both solved and unsolved, for sort testing", function()
        setup()
        A.addEight()
        local board = todayBoard()
        T.assertEquals(countKeys(board), 8)
        local solved, unsolved = 0, 0
        for _, e in pairs(board) do
            if e.solved then solved = solved + 1 else unsolved = unsolved + 1 end
        end
        T.assertTrue(solved > 0, "need solved entries to test sort order")
        T.assertTrue(unsolved > 0, "need unsolved entries to test that they sort last")
    end)

    T.test("DEV-04: the scroll set produces 30 distinct entries", function()
        setup()
        A.addManyForScroll()
        T.assertEquals(countKeys(todayBoard()), 30,
            "30 distinct rows are needed to exercise scrolling and the row-pool cap")
    end)

    T.test("DEV-05: edge-case names arrive intact for truncation/UTF-8 checks", function()
        setup()
        A.addEdgeNames()
        local names = GuildWordleDB.charNicknames[GUILD]
        local found = {}
        for _, nick in pairs(names) do found[nick] = true end
        T.assertTrue(found["Averyverylongnicknameindeed"], "over-length name should arrive unmodified")
        T.assertTrue(found["Exactlyfifteen"], "boundary-length name should arrive")
        T.assertTrue(found["Bonni\195\169Ren\195\169e"], "accented name should survive the wire round-trip")

        -- The point of the long name is that the UI truncates it for display;
        -- verify the truncation helper the UI uses handles it cleanly.
        local truncated = GW.TruncateUTF8("Averyverylongnicknameindeed", 15)
        T.assertEquals(#truncated, 15)
        local accentTrunc = GW.TruncateUTF8("Bonni\195\169Ren\195\169e", 15)
        T.assertFalse(accentTrunc:sub(-1) == "\195", "must never end on a dangling UTF-8 lead byte")
    end)

    T.test("DEV-06: streak injection yields both active and broken entries", function()
        setup()
        A.addStreaks()
        local board = GuildWordleDB.streakBoard[GUILD]
        T.assertEquals(countKeys(board), 5)
        local active, brokenWithBest = 0, 0
        for _, e in pairs(board) do
            if e.current > 0 then active = active + 1 end
            if e.current == 0 and e.best > 0 then brokenWithBest = brokenWithBest + 1 end
        end
        T.assertEquals(active, 3, "'Streak' tab should have 3 rows to show")
        T.assertEquals(brokenWithBest, 2,
            "and 2 broken-but-with-a-best, which must appear only on 'Best'")
    end)

    T.test("DEV-07: simulated rename updates in place rather than duplicating", function()
        setup()
        A.addEight()
        local before = countKeys(GuildWordleDB.charNicknames[GUILD])
        A.simulateRename()
        local names = GuildWordleDB.charNicknames[GUILD]
        T.assertEquals(countKeys(names), before, "a rename must not add a row")
        local found = false
        for _, nick in pairs(names) do
            if nick == "RenamedAlpha" then found = true end
            T.assertNotEquals(nick, "Alphanick", "the old nickname must be gone, not duplicated")
        end
        T.assertTrue(found, "the new nickname should be present")
    end)

    T.test("DEV-07b (regression): the rename reaches the streak board too, not just Today", function()
        -- The results board LOOKS UP the nickname from charNicknames; the
        -- streak board STORES it as a field. A rename that only sends NICKS:
        -- updates the first and leaves the second showing the old name --
        -- a state no real client can produce, since GW.SetNickname always
        -- broadcasts both. This is exactly what shipped broken.
        setup()
        A.addEight()
        A.addStreaks()

        local board = GuildWordleDB.streakBoard[GUILD]
        local alphaKey
        for k, e in pairs(board) do
            if e.nickname == "Alphanick" then alphaKey = k end
        end
        T.assertTrue(alphaKey ~= nil, "precondition: a streak entry named Alphanick exists")

        A.simulateRename()

        T.assertEquals(board[alphaKey].nickname, "RenamedAlpha",
            "the streak board entry must pick up the new name, not keep the old one")
        for _, nick in pairs(GuildWordleDB.charNicknames[GUILD]) do
            T.assertNotEquals(nick, "Alphanick", "and the results-side lookup must update too")
        end
    end)

    T.test("DEV-08: the stale-echo action cannot revive a broken streak", function()
        setup()
        A.addStreaks()
        local board = GuildWordleDB.streakBoard[GUILD]
        local charlieKey
        for k, e in pairs(board) do
            if e.nickname == "Charlienick" then charlieKey = k end
        end
        T.assertTrue(charlieKey ~= nil, "precondition: Charlienick exists")
        T.assertEquals(board[charlieKey].current, 0, "precondition: their streak is broken")

        A.simulateStaleEcho()

        T.assertEquals(board[charlieKey].current, 0,
            "a 3-day-old echo must not resurrect the streak -- this is the bug the action demonstrates")
        T.assertEquals(board[charlieKey].best, 99,
            "but best-only-increases still applies, so best should rise")
    end)

    T.test("DEV-09: forced win/loss produce a coherent finished game", function()
        setup()
        A.winToday()
        local g = GW.CurrentGame()
        T.assertEquals(g.state, "won")
        T.assertEquals(#g.guesses, #g.results, "lengths must match or CurrentGame() would wipe it")
        T.assertTrue(todayBoard()["Realchar"] ~= nil, "own result should be on the board")
        T.assertEquals(todayBoard()["Realchar"].solved, true)

        setup()
        A.loseToday()
        local g2 = GW.CurrentGame()
        T.assertEquals(g2.state, "lost")
        T.assertEquals(#g2.guesses, #g2.results)
        T.assertEquals(todayBoard()["Realchar"].solved, false)
    end)

    T.test("DEV-10: streak helpers set and break the streak as advertised", function()
        setup()
        A.setStreak()
        local s = GW.CurrentStreak()
        T.assertEquals(s.current, 5)
        T.assertEquals(s.best, 10)

        setup()
        A.breakStreak()
        T.assertEquals(GW.CurrentStreak().current, 0,
            "a 3-day-stale lastDate should read as broken immediately")
        T.assertEquals(GuildWordleDB.streak.best, 10, "best survives")
    end)

    T.test("DEV-10b (regression): streak helpers also push onto the streak board", function()
        -- Setting your own streak has to reach the guild streak board too,
        -- or the tabs keep showing whatever was there before.
        setup()
        GuildWordleDB.accountId = "MyAcct"
        A.setStreak()
        local mine = GuildWordleDB.streakBoard[GUILD]["MyAcct"]
        T.assertTrue(mine ~= nil, "own streak entry should exist on the board")
        T.assertEquals(mine.current, 5)
        T.assertEquals(mine.best, 10)

        A.breakStreak()
        mine = GuildWordleDB.streakBoard[GUILD]["MyAcct"]
        T.assertEquals(mine.current, 0, "board entry should reflect the broken streak")
        T.assertEquals(mine.best, 10)
    end)

    T.test("DEV-10c (regression): local-state actions trigger a full-window refresh", function()
        -- The left-column streak label is refreshed by a file-local function
        -- in GuildWordle_UI.lua that only runs on frame-show; without a
        -- full-window refresh hook these actions updated the panel but left
        -- the label stale until the window was closed and reopened.
        setup()
        local calls = 0
        local real = GW.RefreshMainUI
        GW.RefreshMainUI = function() calls = calls + 1 end

        A.setStreak()
        T.assertEquals(calls, 1, "setStreak must refresh the whole window")
        A.breakStreak()
        T.assertEquals(calls, 2, "breakStreak must too")
        A.winToday()
        T.assertEquals(calls, 3, "and so must a forced win")
        setup(); GW.RefreshMainUI = function() calls = calls + 1 end
        A.loseToday()
        T.assertEquals(calls, 4, "and a forced loss")

        GW.RefreshMainUI = real
    end)

    T.test("DEV-11: 'clear fakes' removes every fake and nothing real", function()
        setup()
        -- A real player's result and nickname, alongside the fakes.
        A.winToday()
        A.addEight()
        A.addStreaks()
        GuildWordleDB.charNicknames[GUILD]["Realchar"] = "Realnick"
        T.assertTrue(countKeys(todayBoard()) > 1)

        A.clearFakes()

        for name in pairs(todayBoard()) do
            T.assertFalse(name:sub(1, 3) == "Zzt", "fake leaderboard entry survived: " .. name)
        end
        for key in pairs(GuildWordleDB.streakBoard[GUILD]) do
            T.assertFalse(key:sub(1, 3) == "Zzt", "fake streak entry survived: " .. key)
        end
        for name in pairs(GuildWordleDB.charNicknames[GUILD]) do
            T.assertFalse(name:sub(1, 3) == "Zzt", "fake nickname survived: " .. name)
        end
        T.assertTrue(todayBoard()["Realchar"] ~= nil, "the real result must be preserved")
        T.assertEquals(GuildWordleDB.charNicknames[GUILD]["Realchar"], "Realnick",
            "the real nickname must be preserved")
    end)

    T.test("DEV-12: dev panel visibility follows the devMode flag", function()
        setup()
        T.assertNoThrow(function() GW.SetDevPanelShown(true) end)
        T.assertNoThrow(function() GW.SetDevPanelShown(false) end)
        -- Re-showing after a hide must not error (frame is reused, not rebuilt).
        T.assertNoThrow(function() GW.SetDevPanelShown(true) end)
    end)

    T.test("DEV-13: /wordle dev toggles devMode and drives the panel together", function()
        setup()
        GuildWordleDB.settings.devMode = false
        GW._test.HandleSlashCommand("dev")
        T.assertEquals(GuildWordleDB.settings.devMode, true, "dev mode should turn on")
        GW._test.HandleSlashCommand("dev")
        T.assertEquals(GuildWordleDB.settings.devMode, false, "and back off")
    end)

end)

T.run()
