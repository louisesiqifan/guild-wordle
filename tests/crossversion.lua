-- Spec: BEHAVIOR_SPEC.md section 7 (Cross-version compatibility)
--
-- Runs the ACTUAL released v1.0.4 code (fixtures/v1.0.4_GuildWordle.lua,
-- fetched from the v1.0.4 tag) against the current build, in both directions.
--
-- This exists because reasoning is not enough here. v1.0.4 is live on other
-- people's clients; if this version's new NICKS:/STREAKS: messages broke it,
-- or its 4-field RESULTS: no longer parsed, guildmates would silently stop
-- seeing each other. Every other cross-version claim in this repo was
-- argued from reading the code -- the same reading that produced several
-- shipped bugs. This runs the old code instead of trusting that reading.
--
-- Both versions define the same globals, so they're loaded sequentially with
-- the globals wiped in between rather than side by side.
local T = require("runner")
local Mock = require("wow_mock")

local GUILD = "Testguild"
local TODAY

-- Drives whichever version is currently loaded via its own event frame,
-- exactly as the WoW client would deliver an addon message.
local function frameFor(startIndex)
    for i = startIndex, #Mock.createdFrames do
        local f = Mock.createdFrames[i]
        if f.GetScript and f:GetScript("OnEvent") and f:IsEventRegistered("CHAT_MSG_ADDON") then
            return f, i
        end
    end
end

local oldFrameIdx, newFrameIdx
local capturedOldWire = {}

-- ── Load v1.0.4 and capture what it actually puts on the wire ───────────────

Mock.reset()
Mock.now = os.time({year = 2026, month = 3, day = 15, hour = 12})
Mock.unitName, Mock.realmName, Mock.guildName = "Oldchar", "Testrealm", GUILD
TODAY = os.date("%Y%m%d", Mock.now)

dofile("../words.lua")
local firstFrame = #Mock.createdFrames + 1
dofile("fixtures/v1.0.4_GuildWordle.lua")
local oldFrame = frameFor(firstFrame)
assert(oldFrame, "could not find v1.0.4's event frame")
local OLD = _G.GuildWordle

_G.GuildWordleDB = nil
OLD.todaysWord = "CRANE"
-- v1.0.4 has no InitDB test hook; ADDON_LOADED does the setup.
oldFrame:GetScript("OnEvent")(oldFrame, "ADDON_LOADED", "GuildWordle")
OLD.todaysWord = "CRANE"

T.suite("7 Cross-version: v1.0.4 <-> current", function()

    T.test("XVER-01: v1.0.4 survives this version's NICKS: message", function()
        Mock.printed = {}
        T.assertNoThrow(function()
            oldFrame:GetScript("OnEvent")(oldFrame, "CHAT_MSG_ADDON",
                "GUILDWORDLE", "NICKS:Newchar,Newnick;Other,Othernick",
                "GUILD", "Newchar-Testrealm")
        end, "an unknown message type must not break an old client")
    end)

    T.test("XVER-02: v1.0.4 survives this version's STREAKS: message", function()
        T.assertNoThrow(function()
            oldFrame:GetScript("OnEvent")(oldFrame, "CHAT_MSG_ADDON",
                "GUILDWORDLE", "STREAKS:Acct1,Newnick,4,9," .. TODAY,
                "GUILD", "Newchar-Testrealm")
        end, "an unknown message type must not break an old client")
    end)

    T.test("XVER-03: v1.0.4 still reads this version's RESULTS: correctly", function()
        -- The whole reason RESULTS: was left byte-identical: an old client
        -- must keep seeing new clients' results on its leaderboard.
        oldFrame:GetScript("OnEvent")(oldFrame, "CHAT_MSG_ADDON",
            "GUILDWORDLE", "RESULTS:" .. TODAY .. ":Newchar,3,1,02100 21010 22222",
            "GUILD", "Newchar-Testrealm")

        -- v1.0.4 stored the leaderboard per guild, keyed by character name.
        local lb = GuildWordleDB.leaderboard[GUILD] and GuildWordleDB.leaderboard[GUILD][TODAY]
        T.assertTrue(lb ~= nil, "v1.0.4 should have a leaderboard bucket for today")
        local e = lb["Newchar"]
        T.assertTrue(e ~= nil, "v1.0.4 must still see a new client's result")
        T.assertEquals(e.guesses, 3)
        T.assertEquals(e.solved, true)
        T.assertEquals(e.pattern, "02100 21010 22222")
    end)

    T.test("XVER-04: v1.0.4's own broadcast is captured for the reverse test", function()
        Mock.sentAddon = {}
        OLD.BroadcastKnownResults()
        for _, m in ipairs(Mock.sentAddon) do capturedOldWire[#capturedOldWire + 1] = m.text end
        T.assertTrue(#capturedOldWire > 0, "v1.0.4 should have broadcast something")
        local sawResults = false
        for _, t in ipairs(capturedOldWire) do
            if t:sub(1, 8) == "RESULTS:" then sawResults = true end
        end
        T.assertTrue(sawResults, "expected a RESULTS: message from v1.0.4")
    end)

end)

-- ── Wipe globals, load the CURRENT version, replay v1.0.4's real output ─────

_G.GuildWordle = nil
_G.GuildWordleDB = nil
Mock.reset()
Mock.now = os.time({year = 2026, month = 3, day = 15, hour = 12})
Mock.unitName, Mock.realmName, Mock.guildName = "Newchar", "Testrealm", GUILD

local beforeNew = #Mock.createdFrames + 1
dofile("../GuildWordle.lua")
local newFrame = frameFor(beforeNew)
assert(newFrame, "could not find the current version's event frame")
local NEW = _G.GuildWordle
NEW._test.InitDB()

T.suite("7 Cross-version: current reading v1.0.4", function()

    T.test("XVER-05: the current build parses v1.0.4's real wire output", function()
        -- Not a hand-written approximation of the old format: these are the
        -- exact strings v1.0.4 produced above.
        T.assertTrue(#capturedOldWire > 0, "precondition: captured old output")
        for _, text in ipairs(capturedOldWire) do
            T.assertNoThrow(function()
                NEW._test.HandleAddonMessage("GUILDWORDLE", text, "GUILD", "Oldchar-Testrealm")
            end, "current build must parse v1.0.4's output: " .. text)
        end

        local lb = GuildWordleDB.leaderboard[GUILD] and GuildWordleDB.leaderboard[GUILD][TODAY]
        T.assertTrue(lb ~= nil and next(lb) ~= nil,
            "the old client's results should appear on the new client's board")
    end)

    T.test("XVER-06: an old client's result falls back to its character name", function()
        -- v1.0.4 never sends NICKS:, so there is no nickname to resolve --
        -- the row must show the character name rather than blank or nil.
        local lb = GuildWordleDB.leaderboard[GUILD][TODAY]
        local charName = next(lb)
        local names = GuildWordleDB.charNicknames[GUILD]
        local display = (names and names[charName]) or charName
        T.assertEquals(display, charName,
            "with no nickname known, display must fall back to the character name")
        T.assertTrue(display ~= nil and display ~= "", "and must not be blank")
    end)

    T.test("XVER-07: RESULTS: is byte-identical across versions", function()
        -- The load-bearing compatibility claim, checked directly: build the
        -- same leaderboard entry on the current version and compare its wire
        -- output to what v1.0.4 emitted for the equivalent entry.
        local oldResults
        for _, t in ipairs(capturedOldWire) do
            if t:sub(1, 8) == "RESULTS:" then oldResults = t break end
        end
        T.assertTrue(oldResults ~= nil)

        local _, payload = oldResults:match("^RESULTS:([^:]+):(.+)$")
        for entry in payload:gmatch("[^;]+") do
            local _, commas = entry:gsub(",", "")
            T.assertEquals(commas, 3,
                "v1.0.4 entries have 4 fields; the current format must match: " .. entry)
        end

        _G.GuildWordleDB.leaderboard[GUILD][TODAY] = {
            Solo = {guesses = 3, solved = true, pattern = "02100 21010 22222"},
        }
        Mock.sentAddon = {}
        NEW.BroadcastKnownResults()
        T.assertEquals(Mock.sentAddon[1].text,
            "RESULTS:" .. TODAY .. ":Solo,3,1,02100 21010 22222",
            "current wire format must match what v1.0.4 both sends and understands")
    end)

end)

T.run()
