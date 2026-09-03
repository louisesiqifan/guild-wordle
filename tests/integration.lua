-- Spec: BEHAVIOR_SPEC.md section 2 (Integration)
--
-- Multi-client note: there's only one copy of GuildWordle.lua loaded in this
-- process, so "two clients" is simulated by swapping the GuildWordleDB
-- global (and the mock's identity fields) between two saved snapshots --
-- a client is exactly its SavedVariables table plus its character identity,
-- so swapping both is a faithful stand-in for two separate installs.
local T = require("runner")
local H = require("harness")
local GW, Mock = H.GW, H.Mock

local GUILD = "Testguild"

-- ── Simulated client plumbing ────────────────────────────────────────────────

local function newClient(charName, realm, nickname, accountId)
    local saved = _G.GuildWordleDB
    _G.GuildWordleDB = nil
    Mock.unitName  = charName
    Mock.realmName = realm or "Testrealm"
    Mock.guildName = GUILD
    GW._test.InitDB()
    if nickname then GuildWordleDB.settings.nickname = nickname end
    if accountId then GuildWordleDB.accountId = accountId end
    local client = {
        db       = _G.GuildWordleDB,
        charName = charName,
        realm    = realm or "Testrealm",
    }
    _G.GuildWordleDB = saved
    return client
end

-- Makes `client` the active one for subsequent addon calls.
local function activate(client)
    _G.GuildWordleDB = client.db
    Mock.unitName    = client.charName
    Mock.realmName   = client.realm
    Mock.guildName   = GUILD
end

-- Runs fn as `client`, returning every addon message it emitted.
local function asClient(client, fn)
    activate(client)
    Mock.sentAddon = {}
    fn()
    local msgs = {}
    for _, m in ipairs(Mock.sentAddon) do msgs[#msgs + 1] = m.text end
    Mock.sentAddon = {}
    return msgs
end

-- Delivers messages to `client` as if they arrived over guild chat.
local function deliverTo(client, msgs, senderChar)
    activate(client)
    for _, text in ipairs(msgs) do
        GW._test.HandleAddonMessage("GUILDWORDLE", text, "GUILD",
            (senderChar or "Other") .. "-Testrealm")
    end
end

local function playAndWin(word)
    GW._test.SetWordForTest(word, H.dateStr())
    GW.SubmitGuess(word)
end

T.suite("2.1 Full play-through", function()

    T.test("INT-PLAY-01: a win records the leaderboard entry, streak, and broadcasts", function()
        H.freshDB()
        Mock.guildName = GUILD
        H.setDate(2026, 3, 15)
        Mock.unitName = "Byamba"
        Mock.sentAddon = {}

        playAndWin("CRANE")

        T.assertEquals(GW.CurrentGame().state, "won")
        local entry = GuildWordleDB.leaderboard[GUILD][H.dateStr()]["Byamba"]
        T.assertTrue(entry ~= nil, "leaderboard entry should exist")
        T.assertEquals(entry.solved, true)
        T.assertEquals(entry.guesses, 1)
        T.assertEquals(GW.CurrentStreak().current, 1)

        local kinds = {}
        for _, m in ipairs(Mock.sentAddon) do
            kinds[m.text:match("^(%u+):")] = true
        end
        T.assertTrue(kinds["RESULTS"], "should broadcast RESULTS")
        T.assertTrue(kinds["STREAKS"], "should broadcast STREAKS")
        T.assertTrue(kinds["NICKS"],   "should broadcast NICKS")
    end)

    T.test("INT-PLAY-02: a loss records solved=false and zeroes the streak", function()
        H.freshDB()
        Mock.guildName = GUILD
        H.setDate(2026, 3, 15)
        Mock.unitName = "Byamba"
        GuildWordleDB.streak = {current = 4, best = 4, lastDate = "20260314"}

        GW._test.SetWordForTest("CRANE", H.dateStr())
        for _, w in ipairs({"ROBOT", "SHEEP", "LLAMA", "ABBEY", "SASSY", "ADDED"}) do
            GW.SubmitGuess(w)
        end

        T.assertEquals(GW.CurrentGame().state, "lost")
        local entry = GuildWordleDB.leaderboard[GUILD][H.dateStr()]["Byamba"]
        T.assertEquals(entry.solved, false)
        T.assertEquals(entry.guesses, 6)
        T.assertEquals(GW.CurrentStreak().current, 0)
        T.assertEquals(GuildWordleDB.streak.best, 4, "best survives a loss")
    end)

    T.test("INT-PLAY-03: replaying the same day is blocked and doesn't overwrite the entry", function()
        H.freshDB()
        Mock.guildName = GUILD
        H.setDate(2026, 3, 15)
        Mock.unitName = "Byamba"
        playAndWin("CRANE")
        local before = GuildWordleDB.leaderboard[GUILD][H.dateStr()]["Byamba"]
        local snapshot = {before.guesses, before.solved, before.pattern}

        Mock.sentAddon = {}
        local ok, reason = GW.SubmitGuess("ROBOT")
        T.assertFalse(ok)
        T.assertEquals(reason, "already_done")
        local after = GuildWordleDB.leaderboard[GUILD][H.dateStr()]["Byamba"]
        T.assertEquals(after.guesses, snapshot[1])
        T.assertEquals(after.solved, snapshot[2])
        T.assertEquals(after.pattern, snapshot[3])
        T.assertEquals(#Mock.sentAddon, 0, "a rejected guess should not broadcast")
    end)

    T.test("INT-PLAY-04: outside a guild, local state still updates but nothing is broadcast", function()
        H.freshDB()
        Mock.guildName = nil
        H.setDate(2026, 3, 15)
        Mock.unitName = "Byamba"
        Mock.sentAddon = {}

        playAndWin("CRANE")

        T.assertEquals(GW.CurrentStreak().current, 1, "streak still counts solo")
        T.assertTrue(GuildWordleDB.leaderboard["NOGUILD"][H.dateStr()]["Byamba"] ~= nil,
            "result stored under the NOGUILD bucket")
        T.assertEquals(#Mock.sentAddon, 0, "no addon messages outside a guild")
    end)

    T.test("INT-PLAY-05: two alts on one account each get a row; the streak counts once", function()
        H.freshDB()
        Mock.guildName = GUILD
        H.setDate(2026, 3, 15)
        GuildWordleDB.settings.nickname = "Bonnie"

        Mock.unitName = "Alpha"
        playAndWin("CRANE")
        T.assertEquals(GW.CurrentStreak().current, 1)

        -- Second alt plays and loses the same day.
        Mock.unitName = "Beta"
        GW._test.SetWordForTest("CRANE", H.dateStr())
        for _, w in ipairs({"ROBOT", "SHEEP", "LLAMA", "ABBEY", "SASSY", "ADDED"}) do
            GW.SubmitGuess(w)
        end

        local today = GuildWordleDB.leaderboard[GUILD][H.dateStr()]
        T.assertTrue(today["Alpha"] ~= nil, "Alpha has its own row")
        T.assertTrue(today["Beta"] ~= nil, "Beta has its own row")
        T.assertEquals(today["Alpha"].solved, true)
        T.assertEquals(today["Beta"].solved, false)
        T.assertEquals(GW.CurrentStreak().current, 1,
            "the alt's loss must not wipe the streak the first character already earned today")

        -- Both rows resolve to the one account-wide nickname.
        GW.RecordOwnCharNickname()
        local names = GuildWordleDB.charNicknames[GUILD]
        T.assertEquals(names["Alpha"], "Bonnie")
        T.assertEquals(names["Beta"],  "Bonnie")
    end)

end)

T.suite("2.2 Nickname propagation", function()

    T.test("INT-NICK-01: a rename updates this character's mapping synchronously", function()
        H.freshDB()
        Mock.guildName = GUILD
        H.setDate(2026, 3, 15)
        Mock.unitName = "Byamba"
        playAndWin("CRANE")

        GW.SetNickname("Newname")
        T.assertEquals(GuildWordleDB.charNicknames[GUILD]["Byamba"], "Newname",
            "must be visible immediately, without a gossip round-trip")
    end)

    T.test("INT-NICK-02: a rename also refreshes an alt already known in this guild", function()
        H.freshDB()
        Mock.guildName = GUILD
        H.setDate(2026, 3, 14)
        -- Alpha played yesterday (still inside the 7-day retention window).
        Mock.unitName = "Alpha"
        playAndWin("CRANE")

        H.setDate(2026, 3, 15)
        Mock.unitName = "Beta"
        playAndWin("ROBOT")

        GW.SetNickname("Renamed")
        local names = GuildWordleDB.charNicknames[GUILD]
        T.assertEquals(names["Beta"],  "Renamed", "the active character updates")
        T.assertEquals(names["Alpha"], "Renamed",
            "the alt already known in this guild updates too, without needing to log in")
    end)

    T.test("INT-NICK-03: a rename never leaks into another guild's bucket", function()
        H.freshDB()
        H.setDate(2026, 3, 14)
        -- Alpha plays in a different guild.
        Mock.guildName = "OtherGuild"
        Mock.unitName  = "Alpha"
        playAndWin("CRANE")

        H.setDate(2026, 3, 15)
        Mock.guildName = GUILD
        Mock.unitName  = "Beta"
        playAndWin("ROBOT")

        -- Alpha legitimately recorded its own mapping in OtherGuild when it
        -- played there; what must NOT happen is a rename performed while in
        -- GUILD reaching across and rewriting that other guild's bucket.
        local otherBefore = GuildWordleDB.charNicknames["OtherGuild"]["Alpha"]
        T.assertTrue(otherBefore ~= nil, "precondition: Alpha recorded itself in OtherGuild")

        GW.SetNickname("Renamed")
        T.assertEquals(GuildWordleDB.charNicknames[GUILD]["Beta"], "Renamed",
            "the active guild's bucket updates")
        T.assertEquals(GuildWordleDB.charNicknames["OtherGuild"]["Alpha"], otherBefore,
            "the other guild's bucket must be untouched by a rename done elsewhere")
        T.assertNotEquals(GuildWordleDB.charNicknames["OtherGuild"]["Alpha"], "Renamed")
    end)

end)

T.suite("2.3 Gossip round-trip (two simulated clients)", function()

    T.test("INT-GOSSIP-01: RESULTS: propagates A -> B", function()
        H.setDate(2026, 3, 15)
        local A = newClient("Aychar", "Testrealm", "Anick", "AcctA")
        local B = newClient("Beechar", "Testrealm", "Bnick", "AcctB")

        local msgs = asClient(A, function() playAndWin("CRANE") end)
        deliverTo(B, msgs, A.charName)

        local entry = B.db.leaderboard[GUILD][H.dateStr()]["Aychar"]
        T.assertTrue(entry ~= nil, "B should have learned A's result")
        T.assertEquals(entry.solved, true)
        T.assertEquals(entry.guesses, 1)
    end)

    T.test("INT-GOSSIP-02: NICKS: propagates A -> B", function()
        H.setDate(2026, 3, 15)
        local A = newClient("Aychar", "Testrealm", "Anick", "AcctA")
        local B = newClient("Beechar", "Testrealm", "Bnick", "AcctB")

        local msgs = asClient(A, function() GW.BroadcastCharNicknames() end)
        deliverTo(B, msgs, A.charName)

        T.assertEquals(B.db.charNicknames[GUILD]["Aychar"], "Anick")
    end)

    T.test("INT-GOSSIP-03: STREAKS: propagates A -> B", function()
        H.setDate(2026, 3, 15)
        local A = newClient("Aychar", "Testrealm", "Anick", "AcctA")
        local B = newClient("Beechar", "Testrealm", "Bnick", "AcctB")

        activate(A)
        A.db.streak = {current = 4, best = 6, lastDate = H.dateStr()}
        local msgs = asClient(A, function() GW.BroadcastStreak() end)
        deliverTo(B, msgs, A.charName)

        local e = B.db.streakBoard[GUILD]["AcctA"]
        T.assertTrue(e ~= nil, "B should know A's streak")
        T.assertEquals(e.current, 4)
        T.assertEquals(e.best, 6)
        T.assertEquals(e.nickname, "Anick")
    end)

    T.test("INT-GOSSIP-04: an out-of-order stale echo can't revive a broken streak", function()
        H.setDate(2026, 3, 14)
        local A = newClient("Aychar", "Testrealm", "Anick", "AcctA")
        local B = newClient("Beechar", "Testrealm", "Bnick", "AcctB")

        -- Day 1: A has an active 5-day streak; B hears about it.
        activate(A)
        A.db.streak = {current = 5, best = 5, lastDate = H.dateStr()}
        local staleMsgs = asClient(A, function() GW.BroadcastStreak() end)

        -- Day 2: A loses, streak breaks; B hears the fresh news first.
        H.setDate(2026, 3, 15)
        activate(A)
        A.db.streak = {current = 0, best = 5, lastDate = H.dateStr()}
        local freshMsgs = asClient(A, function() GW.BroadcastStreak() end)

        deliverTo(B, freshMsgs, A.charName)
        T.assertEquals(B.db.streakBoard[GUILD]["AcctA"].current, 0)

        -- The day-1 echo arrives late.
        deliverTo(B, staleMsgs, A.charName)
        local e = B.db.streakBoard[GUILD]["AcctA"]
        T.assertEquals(e.current, 0, "the stale echo must not resurrect the broken streak")
        T.assertEquals(e.best, 5, "best is still the highest seen")
    end)

    T.test("INT-GOSSIP-05: secondhand propagation A -> C -> B without A and B ever meeting", function()
        H.setDate(2026, 3, 15)
        local A = newClient("Aychar", "Testrealm", "Anick", "AcctA")
        local B = newClient("Beechar", "Testrealm", "Bnick", "AcctB")
        local C = newClient("Ceechar", "Testrealm", "Cnick", "AcctC")

        -- A plays; only C is online to hear it.
        local fromA = asClient(A, function() playAndWin("CRANE") end)
        deliverTo(C, fromA, A.charName)
        T.assertTrue(C.db.leaderboard[GUILD][H.dateStr()]["Aychar"] ~= nil, "C heard A directly")

        -- Later, C re-broadcasts everything it knows; B is online now, A is not.
        local fromC = asClient(C, function()
            GW.BroadcastKnownResults()
            GW.BroadcastStreak()
            GW.BroadcastCharNicknames()
        end)
        deliverTo(B, fromC, C.charName)

        T.assertTrue(B.db.leaderboard[GUILD][H.dateStr()]["Aychar"] ~= nil,
            "B should learn A's result secondhand through C")
        T.assertEquals(B.db.charNicknames[GUILD]["Aychar"], "Anick",
            "and A's nickname too")
        T.assertTrue(B.db.streakBoard[GUILD]["AcctA"] ~= nil,
            "and A's streak entry")
    end)

    T.test("INT-GOSSIP-06: SYNC_REQ makes the receiver resend everything it knows", function()
        H.setDate(2026, 3, 15)
        local A = newClient("Aychar", "Testrealm", "Anick", "AcctA")
        asClient(A, function() playAndWin("CRANE") end)

        activate(A)
        Mock.sentAddon = {}
        GW._test.HandleAddonMessage("GUILDWORDLE", "SYNC_REQ", "GUILD", "Beechar-Testrealm")
        local kinds = {}
        for _, m in ipairs(Mock.sentAddon) do kinds[m.text:match("^(%u+):")] = true end
        T.assertTrue(kinds["RESULTS"], "SYNC_REQ should trigger a RESULTS resend")
        T.assertTrue(kinds["STREAKS"], "and STREAKS")
        T.assertTrue(kinds["NICKS"],   "and NICKS")
    end)

end)

T.suite("2.4 Wire-format stability", function()

    T.test("INT-WIRE-02: RESULTS: shape is unaffected by whatever is in charNicknames", function()
        H.freshDB()
        Mock.guildName = GUILD
        H.setDate(2026, 3, 15)
        Mock.unitName = "Byamba"
        playAndWin("CRANE")

        local function resultsMessage()
            Mock.sentAddon = {}
            GW.BroadcastKnownResults()
            return Mock.sentAddon[1].text
        end

        local baseline = resultsMessage()
        GuildWordleDB.charNicknames[GUILD] = {Byamba = "SomeVeryLongNickname", Other = "Xyz"}
        T.assertEquals(resultsMessage(), baseline,
            "nicknames must never leak into the RESULTS: wire format")
        GuildWordleDB.settings.nickname = "CompletelyDifferent"
        T.assertEquals(resultsMessage(), baseline)
    end)

end)

T.suite("2.5 SavedVariables initialization", function()

    T.test("INT-INIT-01: a fresh DB gets every expected table and default", function()
        Mock.reset()
        Mock.unitName = "Byamba"
        _G.GuildWordleDB = nil
        GW._test.InitDB()

        for _, k in ipairs({"leaderboard", "games", "settings", "streak", "streakBoard", "charNicknames"}) do
            T.assertEquals(type(GuildWordleDB[k]), "table", k .. " should be initialized")
        end
        T.assertEquals(GuildWordleDB.settings.scale, 1)
        T.assertEquals(GuildWordleDB.settings.autoShare.GUILD, true)
        T.assertEquals(GuildWordleDB.settings.autoShare.PARTY, true)
        T.assertEquals(GuildWordleDB.settings.autoShare.RAID, true)
        T.assertEquals(GuildWordleDB.settings.nickname, "Byamba")
        T.assertTrue(GuildWordleDB.accountId ~= nil)
        T.assertTrue(type(GW.CurrentWord()) == "string")
    end)

    T.test("INT-INIT-02: existing values are preserved, only missing ones filled", function()
        Mock.reset()
        _G.GuildWordleDB = {settings = {scale = 0.75}}
        GW._test.InitDB()
        T.assertEquals(GuildWordleDB.settings.scale, 0.75, "existing scale must not be overwritten")
        T.assertEquals(type(GuildWordleDB.charNicknames), "table")
    end)

    T.test("INT-INIT-03: accountId is frozen once set", function()
        Mock.reset()
        Mock.unitName  = "Different"
        Mock.realmName = "Otherrealm"
        _G.GuildWordleDB = {accountId = "Original-Value"}
        GW._test.InitDB()
        T.assertEquals(GuildWordleDB.accountId, "Original-Value",
            "accountId must never be recomputed once set")
    end)

    T.test("INT-INIT-04 (regression): nil UnitName/GetRealmName still yields a usable DB", function()
        Mock.reset()
        Mock.unitName  = nil
        Mock.realmName = nil
        _G.GuildWordleDB = nil
        T.assertNoThrow(function() GW._test.InitDB() end)
        for _, k in ipairs({"leaderboard", "games", "streakBoard", "charNicknames"}) do
            T.assertEquals(type(GuildWordleDB[k]), "table",
                k .. " must be a valid table even when the identity APIs return nil")
        end
    end)

    T.test("INT-INIT-05/06: entries older than 7 days are pruned, recent ones kept byte-identical", function()
        Mock.reset()
        H.setDate(2026, 3, 15)
        local recent = "20260314"
        local old    = "20260101"
        _G.GuildWordleDB = {
            leaderboard = {
                [GUILD] = {
                    [recent] = {Bonnie = {guesses = 3, solved = true, pattern = "22222"}},
                    [old]    = {Bonnie = {guesses = 4, solved = true, pattern = "22222"}},
                },
            },
            games = {
                ["Keep-Realm"] = {date = recent, guesses = {}, results = {}, state = "playing"},
                ["Drop-Realm"] = {date = old,    guesses = {}, results = {}, state = "playing"},
            },
        }
        GW._test.InitDB()
        T.assertTrue(GuildWordleDB.leaderboard[GUILD][recent] ~= nil, "recent leaderboard kept")
        T.assertNil(GuildWordleDB.leaderboard[GUILD][old], "old leaderboard pruned")
        T.assertEquals(GuildWordleDB.leaderboard[GUILD][recent].Bonnie.guesses, 3, "kept data unchanged")
        T.assertTrue(GuildWordleDB.games["Keep-Realm"] ~= nil, "recent game kept")
        T.assertNil(GuildWordleDB.games["Drop-Realm"], "old game pruned")
    end)

    T.test("INT-INIT-07: malformed dates are pruned rather than aborting the loop", function()
        Mock.reset()
        H.setDate(2026, 3, 15)
        _G.GuildWordleDB = {
            leaderboard = {[GUILD] = {["notadate"] = {X = {}}, ["20260314"] = {Y = {}}}},
            games = {["Bad-Realm"] = {date = "garbage"}, ["Good-Realm"] = {date = "20260314"}},
        }
        T.assertNoThrow(function() GW._test.InitDB() end)
        T.assertNil(GuildWordleDB.leaderboard[GUILD]["notadate"])
        T.assertTrue(GuildWordleDB.leaderboard[GUILD]["20260314"] ~= nil, "valid sibling survives")
        T.assertNil(GuildWordleDB.games["Bad-Realm"])
        T.assertTrue(GuildWordleDB.games["Good-Realm"] ~= nil)
    end)

    T.test("INT-INIT-08: a legacy nickname containing digits is cleaned on load", function()
        Mock.reset()
        Mock.unitName = "Byamba"
        _G.GuildWordleDB = {settings = {nickname = "Bonnie1"}}
        GW._test.InitDB()
        T.assertEquals(GuildWordleDB.settings.nickname, "Bonnie",
            "matches what SetNickname would have produced")
    end)

    T.test("INT-INIT-09: running init twice changes nothing the second time", function()
        Mock.reset()
        Mock.unitName = "Byamba"
        H.setDate(2026, 3, 15)
        _G.GuildWordleDB = nil
        GW._test.InitDB()
        local snapshot = {
            nickname  = GuildWordleDB.settings.nickname,
            accountId = GuildWordleDB.accountId,
            scale     = GuildWordleDB.settings.scale,
        }
        GW._test.InitDB()
        T.assertEquals(GuildWordleDB.settings.nickname, snapshot.nickname)
        T.assertEquals(GuildWordleDB.accountId, snapshot.accountId)
        T.assertEquals(GuildWordleDB.settings.scale, snapshot.scale)
    end)

end)

T.suite("2.6 Realistic messy SavedVariables fixture", function()

    -- Modeled on the actual shape found in this account's live
    -- SavedVariables during development: a legacy singular `game` key from an
    -- ancient build, flat un-guild-scoped date keys alongside proper
    -- guild-scoped ones, a nickname with a trailing digit, and no
    -- accountId/charNicknames at all.
    local function messyDB()
        return {
            games = {
                ["Bonnie-Dreamscythe"] = {
                    date = "20260314", state = "won",
                    guesses = {"ADIEU", "CROWS"}, results = {{1,0,0,1,0}, {0,0,0,0,0}},
                },
            },
            game = {   -- legacy singular key, no longer read by any code
                date = "20260809", state = "lost", guesses = {"ADIEU"}, results = {{1,0,1,0,0}},
            },
            settings = {scale = 0.9, nickname = "Bonnie1",
                        autoShare = {GUILD = true, RAID = true, PARTY = true}},
            leaderboard = {
                ["20260808"] = {},          -- flat, pre-guild-scoping legacy keys
                ["20260805"] = {},
                [GUILD] = {
                    ["20260314"] = {Bonnie = {solved = true, guesses = 5, pattern = "22222"}},
                },
            },
            streak = {current = 1, best = 3, lastDate = "20260314"},
        }
    end

    T.test("INT-FIXTURE-01: init survives the messy fixture", function()
        Mock.reset()
        Mock.unitName = "Bonnie"
        H.setDate(2026, 3, 15)
        _G.GuildWordleDB = messyDB()
        T.assertNoThrow(function() GW._test.InitDB() end)
        T.assertEquals(type(GuildWordleDB.charNicknames), "table", "missing tables get created")
        T.assertTrue(GuildWordleDB.accountId ~= nil, "missing accountId gets set")
        T.assertEquals(GuildWordleDB.settings.nickname, "Bonnie", "legacy nickname cleaned")
        T.assertEquals(GuildWordleDB.settings.scale, 0.9, "existing settings preserved")
    end)

    T.test("INT-FIXTURE-02: unknown legacy keys are left inert, not migrated or deleted", function()
        Mock.reset()
        Mock.unitName = "Bonnie"
        H.setDate(2026, 3, 15)
        _G.GuildWordleDB = messyDB()
        GW._test.InitDB()
        T.assertTrue(GuildWordleDB.game ~= nil,
            "the legacy singular `game` key is ignored, not actively removed")
    end)

    T.test("INT-FIXTURE-03: normal operations work afterward", function()
        Mock.reset()
        Mock.unitName  = "Bonnie"
        Mock.guildName = GUILD
        H.setDate(2026, 3, 15)
        _G.GuildWordleDB = messyDB()
        GW._test.InitDB()

        T.assertNoThrow(function() playAndWin("CRANE") end)
        T.assertEquals(GW.CurrentGame().state, "won")
        T.assertNoThrow(function() GW.SetNickname("Newname") end)
        T.assertEquals(GuildWordleDB.settings.nickname, "Newname")
        T.assertNoThrow(function() GW.PrintLeaderboard() end)
    end)

end)

T.suite("2.7 Cross-version compatibility", function()

    T.test("INT-COMPAT-01: an unknown message type is inert (forward/backward safety)", function()
        H.freshDB()
        Mock.guildName = GUILD
        H.setDate(2026, 3, 15)
        T.assertNoThrow(function()
            GW._test.HandleAddonMessage("GUILDWORDLE", "NEWTHING:a,b,c", "GUILD", "Other-Testrealm")
            GW._test.HandleAddonMessage("GUILDWORDLE", "V2RESULTS:x,1,1,2,3", "GUILD", "Other-Testrealm")
        end)
    end)

    T.test("INT-COMPAT-02: RESULTS: entries carry exactly 4 comma-separated fields", function()
        H.freshDB()
        Mock.guildName = GUILD
        H.setDate(2026, 3, 15)
        Mock.unitName = "Byamba"
        playAndWin("CRANE")
        Mock.sentAddon = {}
        GW.BroadcastKnownResults()

        local payload = Mock.sentAddon[1].text:match("^RESULTS:[^:]+:(.+)$")
        for entry in payload:gmatch("[^;]+") do
            local _, commas = entry:gsub(",", "")
            T.assertEquals(commas, 3, "each entry must have exactly 3 commas (4 fields): " .. entry)
        end
    end)

end)

T.run()
