-- Spec: BEHAVIOR_SPEC.md sections 1.9 (self-healing guards) and
-- 1.10 (error-handling wrappers). Every case here maps to a bug that
-- actually shipped and was reported in-game during development.
local T = require("runner")
local H = require("harness")
local GW, Mock = H.GW, H.Mock

local GUILD = "Testguild"

local function inGuild()
    Mock.guildName = GUILD
end

local function deliver(text, sender)
    GW._test.HandleAddonMessage("GUILDWORDLE", text, "GUILD", sender or "Other-Testrealm")
end

local function printedContains(needle)
    for _, line in ipairs(Mock.printed) do
        if line:find(needle, 1, true) then return true end
    end
    return false
end

T.suite("1.9 Self-healing guards", function()

    T.test("UNIT-HEAL-01 (regression): RecordOwnCharNickname survives a nil charNicknames", function()
        H.freshDB(); inGuild()
        Mock.unitName = "Byamba"
        GuildWordleDB.settings.nickname = "Bonnie"
        GuildWordleDB.charNicknames = nil     -- as if InitDB aborted before this line
        T.assertNoThrow(function() GW.RecordOwnCharNickname() end)
        T.assertEquals(type(GuildWordleDB.charNicknames), "table")
        T.assertEquals(GuildWordleDB.charNicknames[GUILD]["Byamba"], "Bonnie")
    end)

    T.test("UNIT-HEAL-02 (regression): RecordOwnStreakEntry survives a nil streakBoard", function()
        H.freshDB(); inGuild()
        H.setDate(2026, 3, 15)
        GuildWordleDB.accountId = "AcctX"
        GuildWordleDB.streakBoard = nil
        T.assertNoThrow(function() GW.RecordOwnStreakEntry() end)
        T.assertEquals(type(GuildWordleDB.streakBoard), "table")
        T.assertTrue(GuildWordleDB.streakBoard[GUILD]["AcctX"] ~= nil)
    end)

    T.test("UNIT-HEAL-03: an inbound NICKS: message survives a nil charNicknames", function()
        H.freshDB(); inGuild()
        GuildWordleDB.charNicknames = nil
        T.assertNoThrow(function() deliver("NICKS:CharA,Bonnie") end)
        T.assertEquals(GuildWordleDB.charNicknames[GUILD]["CharA"], "Bonnie")
    end)

    T.test("UNIT-HEAL-04: an inbound STREAKS: message survives a nil streakBoard", function()
        H.freshDB(); inGuild()
        GuildWordleDB.streakBoard = nil
        T.assertNoThrow(function() deliver("STREAKS:AcctX,Bonnie,1,2,20260315") end)
        T.assertTrue(GuildWordleDB.streakBoard[GUILD]["AcctX"] ~= nil)
    end)

    T.test("UNIT-INIT-01 (regression): nil UnitName/GetRealmName never make CharKey throw", function()
        H.freshDB()
        Mock.unitName  = nil
        Mock.realmName = nil
        T.assertNoThrow(function() GW._test.CharKey() end)
        T.assertEquals(type(GW._test.CharKey()), "string")
        -- And the game accessor that depends on it still works.
        T.assertNoThrow(function() GW.CurrentGame() end)
    end)

end)

T.suite("1.10 Error visibility", function()

    -- GuildWordle installs its handler at load time, wrapping whatever was
    -- there before. geterrorhandler() now returns GuildWordle's wrapper.
    local function handler()
        return _G.geterrorhandler()
    end

    T.test("UNIT-ERR-02: an error from this addon's own file always prints, no dev mode needed", function()
        H.freshDB()
        GuildWordleDB.settings.devMode = false
        Mock.printed = {}
        handler()("Interface/AddOns/GuildWordle/GuildWordle.lua:123: something broke")
        T.assertTrue(printedContains("[GuildWordle]"), "own-file errors must always surface")
        T.assertTrue(printedContains("something broke"))
    end)

    T.test("UNIT-ERR-02b: own-file errors from the UI file also always print", function()
        H.freshDB()
        GuildWordleDB.settings.devMode = false
        Mock.printed = {}
        handler()("Interface/AddOns/GuildWordle/GuildWordle_UI.lua:456: ui broke")
        T.assertTrue(printedContains("ui broke"), "the folder-based match should cover both files")
    end)

    T.test("UNIT-ERR-03: another addon's error stays quiet while dev mode is off", function()
        H.freshDB()
        GuildWordleDB.settings.devMode = false
        Mock.printed = {}
        handler()("Interface/AddOns/SomeOtherAddon/Thing.lua:9: not our problem")
        T.assertFalse(printedContains("not our problem"), "other addons' errors must not be noisy by default")
    end)

    T.test("UNIT-ERR-04: another addon's error prints while dev mode is on", function()
        H.freshDB()
        GuildWordleDB.settings.devMode = true
        Mock.printed = {}
        handler()("Interface/AddOns/SomeOtherAddon/Thing.lua:9: other addon boom")
        T.assertTrue(printedContains("[GuildWordle DEV]"), "dev mode should surface foreign errors")
        T.assertTrue(printedContains("other addon boom"))
    end)

    T.test("UNIT-ERR-05: the previously-installed handler is always called through to", function()
        H.freshDB()
        Mock.errorHandlerCalls = {}
        GuildWordleDB.settings.devMode = false
        handler()("Interface/AddOns/GuildWordle/GuildWordle.lua:1: own error")
        T.assertEquals(#Mock.errorHandlerCalls, 1, "own-file branch must still chain")

        Mock.errorHandlerCalls = {}
        handler()("Interface/AddOns/Other/X.lua:1: foreign error")
        T.assertEquals(#Mock.errorHandlerCalls, 1, "quiet branch must still chain")

        Mock.errorHandlerCalls = {}
        GuildWordleDB.settings.devMode = true
        handler()("Interface/AddOns/Other/X.lua:1: foreign error")
        T.assertEquals(#Mock.errorHandlerCalls, 1, "dev-mode branch must still chain")
    end)

    T.test("slash dispatch contains errors instead of propagating them", function()
        H.freshDB()
        Mock.printed = {}
        local realPrint = GW.PrintLeaderboard
        GW.PrintLeaderboard = function() error("leaderboard exploded") end
        local ok = pcall(_G.SlashCmdList["GUILDWORDLE"], "lb")
        GW.PrintLeaderboard = realPrint
        T.assertTrue(ok, "the slash handler must not propagate a subcommand error")
        T.assertTrue(printedContains("Command error"), "and must report it")
    end)

    T.test("CHAT_MSG_ADDON dispatch is wrapped (a malformed message can't kill the session)", function()
        H.freshDB(); inGuild()
        Mock.printed = {}
        local realUpdate = GW.OnLeaderboardUpdate
        GW.OnLeaderboardUpdate = function() error("render exploded") end
        -- Drive the real event frame the way WoW would.
        local ok = pcall(H.fireEvent, "CHAT_MSG_ADDON",
            "GUILDWORDLE", "RESULTS:" .. H.dateStr() .. ":Bonnie,3,1,22222", "GUILD", "Other-Testrealm")
        GW.OnLeaderboardUpdate = realUpdate
        T.assertTrue(ok, "event dispatch must not propagate")
        T.assertTrue(printedContains("Addon message handling error"))
    end)

end)

T.run()
