-- Spec: BEHAVIOR_SPEC.md sections 1.7 (serialization) and 1.8 (parsing)
local T = require("runner")
local H = require("harness")
local GW, Mock = H.GW, H.Mock

local GUILD = "Testguild"

local function inGuild()
    Mock.guildName = GUILD
end

-- All addon messages sent since the last reset, as plain text strings.
local function sent()
    local out = {}
    for _, m in ipairs(Mock.sentAddon) do out[#out + 1] = m.text end
    return out
end

local function clearSent()
    Mock.sentAddon = {}
end

-- Feeds a message into the addon exactly as CHAT_MSG_ADDON would.
local function deliver(text, sender)
    GW._test.HandleAddonMessage("GUILDWORDLE", text, "GUILD", sender or "Someoneelse-Testrealm")
end

local function seedResult(name, guesses, solved, pattern, dateStr)
    local d = dateStr or H.dateStr()
    GuildWordleDB.leaderboard[GUILD] = GuildWordleDB.leaderboard[GUILD] or {}
    GuildWordleDB.leaderboard[GUILD][d] = GuildWordleDB.leaderboard[GUILD][d] or {}
    GuildWordleDB.leaderboard[GUILD][d][name] = {guesses = guesses, solved = solved, pattern = pattern}
end

T.suite("1.7 Wire serialization", function()

    T.test("UNIT-WIRE-01: RESULTS: exact format (4 comma fields, no nickname)", function()
        H.freshDB(); inGuild()
        H.setDate(2026, 3, 15)
        seedResult("Bonnie", 3, true, "02100 21010 22222")
        clearSent()
        GW.BroadcastKnownResults()
        local msgs = sent()
        T.assertEquals(#msgs, 1, "expected exactly one message")
        T.assertEquals(msgs[1], "RESULTS:" .. H.dateStr() .. ":Bonnie,3,1,02100 21010 22222")
    end)

    T.test("UNIT-WIRE-01b: unsolved result serializes solved as 0", function()
        H.freshDB(); inGuild()
        H.setDate(2026, 3, 15)
        seedResult("Bonnie", 6, false, "00000")
        clearSent()
        GW.BroadcastKnownResults()
        T.assertEquals(sent()[1], "RESULTS:" .. H.dateStr() .. ":Bonnie,6,0,00000")
    end)

    T.test("UNIT-WIRE-02: nothing to share => no message at all", function()
        H.freshDB(); inGuild()
        clearSent()
        GW.BroadcastKnownResults()
        T.assertEquals(#sent(), 0, "must not send an empty message")
    end)

    T.test("UNIT-WIRE-03: not in a guild => sends nothing even with data present", function()
        H.freshDB()
        H.setDate(2026, 3, 15)
        Mock.guildName = nil
        seedResult("Bonnie", 3, true, "22222")
        clearSent()
        GW.BroadcastKnownResults()
        T.assertEquals(#sent(), 0)
    end)

    T.test("UNIT-WIRE-04: oversized leaderboard is batched, every entry present exactly once", function()
        H.freshDB(); inGuild()
        H.setDate(2026, 3, 15)
        local names = {}
        for i = 1, 30 do
            local n = string.format("Player%02d", i)
            names[#names + 1] = n
            seedResult(n, 4, true, "01200 22222")
        end
        clearSent()
        GW.BroadcastKnownResults()
        local msgs = sent()
        T.assertTrue(#msgs > 1, "30 entries should not fit in one message")
        for _, m in ipairs(msgs) do
            T.assertTrue(#m <= 255, "message exceeds WoW's addon-message cap: " .. #m)
        end
        local joined = table.concat(msgs, "\n")
        for _, n in ipairs(names) do
            local count = select(2, joined:gsub(n .. ",", ""))
            T.assertEquals(count, 1, n .. " should appear exactly once across the batch")
        end
    end)

    T.test("UNIT-WIRE-05: NICKS: format, and empty table sends nothing", function()
        H.freshDB(); inGuild()
        clearSent()
        GuildWordleDB.charNicknames[GUILD] = {}
        GuildWordleDB.settings.nickname = "Bonnie"
        Mock.unitName = "Byamba"
        GW.BroadcastCharNicknames()
        local msgs = sent()
        T.assertEquals(#msgs, 1)
        T.assertEquals(msgs[1], "NICKS:Byamba,Bonnie")
    end)

    T.test("UNIT-WIRE-06: STREAKS: format includes the sender's own live entry", function()
        H.freshDB(); inGuild()
        H.setDate(2026, 3, 15)
        GuildWordleDB.settings.nickname = "Bonnie"
        GuildWordleDB.accountId = "Byamba-Testrealm"
        GuildWordleDB.streak = {current = 3, best = 5, lastDate = H.dateStr()}
        clearSent()
        GW.BroadcastStreak()
        local msgs = sent()
        T.assertEquals(#msgs, 1)
        T.assertEquals(msgs[1], "STREAKS:Byamba-Testrealm,Bonnie,3,5," .. H.dateStr())
    end)

    T.test("UNIT-WIRE-07: nickname/streak broadcasts also no-op outside a guild", function()
        H.freshDB()
        Mock.guildName = nil
        clearSent()
        GW.BroadcastCharNicknames()
        GW.BroadcastStreak()
        T.assertEquals(#sent(), 0)
    end)

end)

T.suite("1.8 Wire parsing", function()

    T.test("UNIT-PARSE-01: wrong prefix is ignored entirely", function()
        H.freshDB(); inGuild()
        H.setDate(2026, 3, 15)
        GW._test.HandleAddonMessage("SOMEOTHERADDON",
            "RESULTS:" .. H.dateStr() .. ":Bonnie,3,1,22222", "GUILD", "Other-Testrealm")
        T.assertNil(GuildWordleDB.leaderboard[GUILD], "no state should be touched")
    end)

    T.test("UNIT-PARSE-02: SYNC_REQ from another player triggers all three broadcasts", function()
        H.freshDB(); inGuild()
        local calls = {r = 0, s = 0, n = 0}
        local rr, rs, rn = GW.BroadcastKnownResults, GW.BroadcastStreak, GW.BroadcastCharNicknames
        GW.BroadcastKnownResults  = function() calls.r = calls.r + 1 end
        GW.BroadcastStreak        = function() calls.s = calls.s + 1 end
        GW.BroadcastCharNicknames = function() calls.n = calls.n + 1 end
        deliver("SYNC_REQ", "Someoneelse-Testrealm")
        GW.BroadcastKnownResults, GW.BroadcastStreak, GW.BroadcastCharNicknames = rr, rs, rn
        T.assertEquals(calls.r, 1)
        T.assertEquals(calls.s, 1)
        T.assertEquals(calls.n, 1)
    end)

    T.test("UNIT-PARSE-03: SYNC_REQ from yourself is ignored (no echo storm)", function()
        H.freshDB(); inGuild()
        Mock.unitName = "Testchar"
        local fired = 0
        local rr = GW.BroadcastKnownResults
        GW.BroadcastKnownResults = function() fired = fired + 1 end
        deliver("SYNC_REQ", "Testchar-Testrealm")
        GW.BroadcastKnownResults = rr
        T.assertEquals(fired, 0, "must not respond to your own SYNC_REQ")
    end)

    T.test("UNIT-PARSE-04: RESULTS: for today is stored and fires the update callback", function()
        H.freshDB(); inGuild()
        H.setDate(2026, 3, 15)
        local fired = 0
        GW.OnLeaderboardUpdate = function() fired = fired + 1 end
        deliver("RESULTS:" .. H.dateStr() .. ":Bonnie,3,1,02100 21010 22222")
        GW.OnLeaderboardUpdate = nil
        local e = GuildWordleDB.leaderboard[GUILD][H.dateStr()]["Bonnie"]
        T.assertTrue(e ~= nil, "entry should exist")
        T.assertEquals(e.guesses, 3)
        T.assertEquals(e.solved, true)
        T.assertEquals(e.pattern, "02100 21010 22222")
        T.assertEquals(fired, 1)
    end)

    T.test("UNIT-PARSE-05: RESULTS: for a different date is ignored", function()
        H.freshDB(); inGuild()
        H.setDate(2026, 3, 15)
        local fired = 0
        GW.OnLeaderboardUpdate = function() fired = fired + 1 end
        deliver("RESULTS:20260101:Bonnie,3,1,22222")
        GW.OnLeaderboardUpdate = nil
        local byGuild = GuildWordleDB.leaderboard[GUILD]
        T.assertTrue(byGuild == nil or byGuild["20260101"] == nil, "stale-date data must not be stored")
        T.assertEquals(fired, 0)
    end)

    T.test("UNIT-PARSE-06: a malformed entry is skipped but valid siblings still land", function()
        H.freshDB(); inGuild()
        H.setDate(2026, 3, 15)
        deliver("RESULTS:" .. H.dateStr() .. ":GARBAGE;Bonnie,3,1,22222;alsobad,x,y")
        local today = GuildWordleDB.leaderboard[GUILD][H.dateStr()]
        T.assertTrue(today["Bonnie"] ~= nil, "the well-formed entry should still be stored")
        T.assertNil(today["GARBAGE"])
        T.assertNil(today["alsobad"])
    end)

    T.test("UNIT-PARSE-07: multiple valid entries in one message all land", function()
        H.freshDB(); inGuild()
        H.setDate(2026, 3, 15)
        deliver("RESULTS:" .. H.dateStr() .. ":A,1,1,22222;B,4,0,00000;C,2,1,01222")
        local today = GuildWordleDB.leaderboard[GUILD][H.dateStr()]
        T.assertTrue(today["A"] ~= nil)
        T.assertTrue(today["B"] ~= nil)
        T.assertTrue(today["C"] ~= nil)
        T.assertEquals(today["B"].solved, false)
    end)

    T.test("UNIT-PARSE-08: NICKS: stores every mapping", function()
        H.freshDB(); inGuild()
        deliver("NICKS:CharA,Bonnie;CharB,Byamba")
        local names = GuildWordleDB.charNicknames[GUILD]
        T.assertEquals(names["CharA"], "Bonnie")
        T.assertEquals(names["CharB"], "Byamba")
    end)

    T.test("UNIT-PARSE-09: NICKS: with an empty nickname never overwrites with blank", function()
        H.freshDB(); inGuild()
        GuildWordleDB.charNicknames[GUILD] = {CharA = "Bonnie"}
        deliver("NICKS:CharA,")
        T.assertEquals(GuildWordleDB.charNicknames[GUILD]["CharA"], "Bonnie", "blank must not clobber")
    end)

    T.test("UNIT-PARSE-10: NICKS: with an unchanged value does not fire the update callback", function()
        H.freshDB(); inGuild()
        GuildWordleDB.charNicknames[GUILD] = {CharA = "Bonnie"}
        local fired = 0
        GW.OnLeaderboardUpdate = function() fired = fired + 1 end
        deliver("NICKS:CharA,Bonnie")
        GW.OnLeaderboardUpdate = nil
        T.assertEquals(fired, 0, "a no-change message should not trigger a re-render")
    end)

    T.test("UNIT-PARSE-11: STREAKS: first entry for an accountId is stored verbatim", function()
        H.freshDB(); inGuild()
        deliver("STREAKS:AcctX,Bonnie,3,7,20260315")
        local e = GuildWordleDB.streakBoard[GUILD]["AcctX"]
        T.assertEquals(e.nickname, "Bonnie")
        T.assertEquals(e.current, 3)
        T.assertEquals(e.best, 7)
        T.assertEquals(e.lastDate, "20260315")
    end)

    T.test("UNIT-PARSE-12: STREAKS: best never decreases even on a fresher message", function()
        H.freshDB(); inGuild()
        GuildWordleDB.streakBoard[GUILD] = {
            AcctX = {nickname = "Bonnie", current = 2, best = 5, lastDate = "20260314"},
        }
        deliver("STREAKS:AcctX,Bonnie,4,3,20260315")   -- fresher, but lower best
        local e = GuildWordleDB.streakBoard[GUILD]["AcctX"]
        T.assertEquals(e.current, 4, "fresher current is accepted")
        T.assertEquals(e.lastDate, "20260315")
        T.assertEquals(e.best, 5, "best must not regress")
    end)

    T.test("UNIT-PARSE-13 (regression): a stale echo cannot revive a broken streak", function()
        H.freshDB(); inGuild()
        GuildWordleDB.streakBoard[GUILD] = {
            AcctX = {nickname = "Bonnie", current = 0, best = 5, lastDate = "20260315"},
        }
        deliver("STREAKS:AcctX,Bonnie,5,5,20260314")   -- older message claiming an active streak
        local e = GuildWordleDB.streakBoard[GUILD]["AcctX"]
        T.assertEquals(e.current, 0, "stale echo must not resurrect the streak")
        T.assertEquals(e.lastDate, "20260315", "lastDate must not roll backwards")
    end)

    T.test("UNIT-PARSE-14: a stale message can still raise best", function()
        H.freshDB(); inGuild()
        GuildWordleDB.streakBoard[GUILD] = {
            AcctX = {nickname = "Bonnie", current = 0, best = 3, lastDate = "20260315"},
        }
        deliver("STREAKS:AcctX,Bonnie,9,8,20260314")   -- older, but a higher best
        local e = GuildWordleDB.streakBoard[GUILD]["AcctX"]
        T.assertEquals(e.best, 8, "best-only-increases applies regardless of freshness")
        T.assertEquals(e.current, 0, "but current is still rejected as stale")
    end)

    T.test("UNIT-PARSE-15: equal lastDate counts as fresh enough (>=, not >)", function()
        H.freshDB(); inGuild()
        GuildWordleDB.streakBoard[GUILD] = {
            AcctX = {nickname = "Old", current = 1, best = 3, lastDate = "20260315"},
        }
        deliver("STREAKS:AcctX,New,2,3,20260315")
        local e = GuildWordleDB.streakBoard[GUILD]["AcctX"]
        T.assertEquals(e.nickname, "New", "same-date message should be accepted")
        T.assertEquals(e.current, 2)
    end)

    T.test("UNIT-PARSE-16: an unrecognized message type is ignored without error", function()
        H.freshDB(); inGuild()
        H.setDate(2026, 3, 15)
        local before = GuildWordleDB.leaderboard[GUILD]
        T.assertNoThrow(function()
            deliver("FUTUREFEATURE:some,new,payload;more,data")
            deliver("")
            deliver("RANDOMGARBAGE")
        end)
        T.assertEquals(GuildWordleDB.leaderboard[GUILD], before, "no state change")
    end)

end)

T.run()
