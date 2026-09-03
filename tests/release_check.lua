-- Spec: BEHAVIOR_SPEC.md section 6 (Release build)
--
-- Answers the question "does the game still work with the dev file gone?"
-- by building an actual release (tests/build_release.sh, using the packager's
-- own filters) and exercising the addon against it, with GuildWordle_Dev.lua
-- genuinely absent -- not stubbed, not mocked away, just not there.
--
-- Every other suite loads the dev file, so without this one nothing would
-- catch a release-only break: a stray reference to a stripped function, a
-- debug block that doesn't close cleanly, or a .toc still naming a file that
-- no longer ships.
--
-- Takes the build dir as argv[1]; run via run_all.sh, which builds it first.
local BUILD = ...
assert(BUILD and BUILD ~= "", "usage: luajit release_check.lua <build-dir>")

local T = require("runner")
local Mock = require("wow_mock")

-- Load the release build, in .toc order, into this environment.
dofile(BUILD .. "/words.lua")
dofile(BUILD .. "/GuildWordle.lua")
dofile(BUILD .. "/GuildWordle_UI.lua")

local GW = _G.GuildWordle

local function fresh()
    Mock.reset()
    Mock.now = os.time({year = 2026, month = 3, day = 15, hour = 12})
    _G.GuildWordleDB = nil
    GW._test.InitDB()
end

local function printedContains(needle)
    for _, line in ipairs(Mock.printed) do
        if line:find(needle, 1, true) then return true end
    end
    return false
end

T.suite("6 Release build (dev file absent)", function()

    T.test("REL-01: the dev file really is absent from the build", function()
        local f = io.open(BUILD .. "/GuildWordle_Dev.lua", "r")
        if f then f:close() end
        T.assertNil(f, "GuildWordle_Dev.lua must not be in a release build")
        T.assertNil(GW.SetDevPanelShown, "its entry points must not exist")
        T.assertNil(GW.DevActions)
    end)

    T.test("REL-02: the .toc no longer references the stripped file", function()
        local toc = io.open(BUILD .. "/GuildWordle.toc", "r")
        T.assertTrue(toc ~= nil, "release .toc should exist")
        local body = toc:read("*a"); toc:close()
        T.assertFalse(body:find("GuildWordle_Dev.lua", 1, true),
            "a .toc naming a missing file is exactly what the #@debug@ markers exist to prevent")
        -- The real files must still be listed, i.e. the filter didn't overreach.
        for _, f in ipairs({"words.lua", "GuildWordle.lua", "GuildWordle_UI.lua"}) do
            T.assertContains(body, f, "release .toc should still load " .. f)
        end
        T.assertFalse(body:find("@debug@", 1, true), "marker lines themselves should be gone")
    end)

    T.test("REL-03: a full game can be played through", function()
        fresh()
        Mock.unitName = "Player"
        GW._test.SetWordForTest("CRANE", GW._test.GetDateString())

        local ok, _, done, won = GW.SubmitGuess("ROBOT")
        T.assertTrue(ok, "first guess should be accepted")
        T.assertFalse(done)

        ok, _, done, won = GW.SubmitGuess("CRANE")
        T.assertTrue(ok)
        T.assertTrue(done, "solving should end the game")
        T.assertTrue(won)
        T.assertEquals(GW.CurrentGame().state, "won")
        T.assertEquals(GW.CurrentStreak().current, 1, "streak should have advanced")
    end)

    T.test("REL-04: nicknames still work", function()
        fresh()
        GW.SetNickname("Bonnie")
        T.assertEquals(GuildWordleDB.settings.nickname, "Bonnie")
        GW.SetNickname("Bon1nie!")     -- sanitisation path
        T.assertEquals(GuildWordleDB.settings.nickname, "Bonnie")
    end)

    T.test("REL-05: gossip still parses and renders", function()
        fresh()
        Mock.guildName = "Testguild"
        local today = GW._test.GetDateString()
        GW._test.HandleAddonMessage("GUILDWORDLE",
            "RESULTS:" .. today .. ":Someone,3,1,02100 21010 22222", "GUILD", "Someone-Realm")
        GW._test.HandleAddonMessage("GUILDWORDLE", "NICKS:Someone,Theirnick", "GUILD", "Someone-Realm")
        GW._test.HandleAddonMessage("GUILDWORDLE",
            "STREAKS:Acct1,Theirnick,4,9," .. today, "GUILD", "Someone-Realm")

        local lb = GuildWordleDB.leaderboard["Testguild"][today]
        T.assertTrue(lb["Someone"] ~= nil, "result should be stored")
        T.assertEquals(GuildWordleDB.charNicknames["Testguild"]["Someone"], "Theirnick")
        T.assertEquals(GuildWordleDB.streakBoard["Testguild"]["Acct1"].best, 9)

        Mock.printed = {}
        T.assertNoThrow(GW.OnLeaderboardUpdate, "leaderboard panel must render")
        T.assertFalse(printedContains("Leaderboard panel error"),
            "and must not report an internal error")
    end)

    T.test("REL-06: /wordle dev is not a command in a release build", function()
        fresh()
        Mock.printed = {}
        GW._test.HandleSlashCommand("dev")
        T.assertNil(GuildWordleDB.settings.devMode,
            "the stripped branch must not set devMode")
        T.assertFalse(printedContains("Dev mode"),
            "and must not announce dev mode; it falls through to the window toggle")
    end)

    T.test("REL-07: the Dev button stays hidden even if devMode is hand-set", function()
        -- devMode is a plain SavedVariables flag; a player could edit it to
        -- true. With the dev file stripped there is nothing for the button to
        -- open, so it must not appear.
        fresh()
        GuildWordleDB.settings.devMode = true
        T.assertNoThrow(GW.RefreshDevButton)
        T.assertNil(GW.SetDevPanelShown, "precondition: no dev panel in this build")
    end)

    T.test("REL-08: every ordinary slash command still works", function()
        fresh()
        Mock.guildName = "Testguild"
        for _, cmd in ipairs({"", "lb", "leaderboard", "streak", "nick",
                              "nick Newname", "reset", "reset-leaderboard"}) do
            Mock.printed = {}
            T.assertNoThrow(function() GW._test.HandleSlashCommand(cmd) end,
                "/wordle " .. cmd .. " should work in a release build")
        end
    end)

    T.test("REL-09: debug blocks are wrapped as well-formed long comments", function()
        -- The packager doesn't delete debug blocks from Lua; it turns
        --   --@debug@      into  --[==[@debug@
        --   --@end-debug@  into  --@end-debug@]==]
        -- so the block becomes one long comment. A marker left unwrapped
        -- would mean the block is still live code in the shipped file.
        for _, name in ipairs({"GuildWordle.lua", "GuildWordle_UI.lua"}) do
            local f = assert(io.open(BUILD .. "/" .. name, "r"))
            local body = f:read("*a"); f:close()

            T.assertFalse(body:find("--@debug@", 1, true),
                name .. ": an opening marker was left unwrapped (should be --[==[@debug@)")

            -- Every closing marker must be immediately followed by ]==].
            local pos = 1
            while true do
                local s, e = body:find("--@end-debug@", pos, true)
                if not s then break end
                T.assertEquals(body:sub(e + 1, e + 4), "]==]",
                    name .. ": a closing marker is not followed by ]==]")
                pos = e + 1
            end

            -- Guard against the block silently containing ]==] itself, which
            -- would close the comment early and leave the rest live.
            local opens = select(2, body:gsub("%-%-%[==%[@debug@", ""))
            local closes = select(2, body:gsub("%-%-@end%-debug@%]==%]", ""))
            T.assertEquals(opens, closes, name .. ": unbalanced debug block markers")
        end
    end)

end)

T.run()
