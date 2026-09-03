-- Spec: BEHAVIOR_SPEC.md section 5 (UI render robustness)
--
-- GuildWordle_UI.lua can be loaded against the mock, but the mock's geometry
-- is meaningless (widths/heights are stubbed to 0), so nothing here tests
-- LAYOUT -- that stays manual UAT (spec section 3). What these DO test is the
-- render paths' robustness against awkward data, which is where every
-- UI-surfacing crash this addon shipped actually lived: the panel blew up on
-- a nil table / missing field and took unrelated code down with it.
--
-- Loaded here rather than in harness.lua so the other suites keep running
-- against core logic only, without UI callbacks installed as side effects.
local T = require("runner")
local H = require("harness")
local GW, Mock = H.GW, H.Mock

dofile("../GuildWordle_UI.lua")
assert(GW.OnLeaderboardUpdate, "GuildWordle_UI.lua did not install its update callback")

local GUILD = "Testguild"
local A = GW.DevActions

-- The UI's own entry point, as wired by the addon: pcall-wrapped, so a throw
-- inside rendering surfaces as a printed message rather than propagating.
local render = GW.OnLeaderboardUpdate

local function setup()
    H.freshDB()
    Mock.guildName = GUILD
    H.setDate(2026, 3, 15)
    Mock.unitName = "Realchar"
end

local function printedContains(needle)
    for _, line in ipairs(Mock.printed) do
        if line:find(needle, 1, true) then return true end
    end
    return false
end

-- Renders and fails the test if the panel reported an internal error. A bare
-- assertNoThrow isn't enough: SafeUpdateLBPanel swallows throws by design, so
-- a broken render would otherwise look like a pass.
local function renderCleanly(msg)
    Mock.printed = {}
    T.assertNoThrow(render, msg or "render threw")
    T.assertFalse(printedContains("Leaderboard panel error"),
        (msg or "render") .. ": panel reported an internal error")
end

T.suite("5 UI render robustness", function()

    T.test("UI-01: renders an empty leaderboard without error", function()
        setup()
        renderCleanly("empty state")
    end)

    T.test("UI-02: renders populated results without error", function()
        setup()
        A.addEight()
        renderCleanly("8 results")
    end)

    T.test("UI-03 (regression): renders with charNicknames nil", function()
        -- The exact shape of the reported crash: InitDB aborted early, leaving
        -- charNicknames nil, and every Today-tab render then threw.
        setup()
        A.addEight()
        GuildWordleDB.charNicknames = nil
        renderCleanly("nil charNicknames")
    end)

    T.test("UI-04 (regression): renders with streakBoard nil", function()
        setup()
        A.addStreaks()
        GuildWordleDB.streakBoard = nil
        renderCleanly("nil streakBoard")
    end)

    T.test("UI-05: renders more entries than the row pool holds", function()
        setup()
        A.addManyForScroll()
        renderCleanly("30 results")
    end)

    T.test("UI-06: renders long, accented and Cyrillic nicknames", function()
        setup()
        A.addEdgeNames()
        renderCleanly("edge-case nicknames")
    end)

    T.test("UI-07: renders a finished game's own result", function()
        setup()
        A.winToday()
        renderCleanly("after a win")
        setup()
        A.loseToday()
        renderCleanly("after a loss")
    end)

    T.test("UI-08: renders with a leaderboard entry missing its pattern field", function()
        -- Defensive: a truncated/garbled gossip message could in principle
        -- leave a partial entry, and one bad row must not blank the panel.
        setup()
        A.addEight()
        local board = GuildWordleDB.leaderboard[GUILD][H.dateStr()]
        local firstKey = next(board)
        board[firstKey].pattern = nil
        renderCleanly("entry with a nil pattern")
    end)

    T.test("UI-09: renders outside a guild", function()
        setup()
        Mock.guildName = nil
        A.winToday()
        renderCleanly("no guild")
    end)

    T.test("UI-10: SafeUpdateLBPanel contains a render error instead of propagating", function()
        setup()
        -- Force a failure deep inside the render path.
        local realTrunc = GW.TruncateUTF8
        A.addEight()
        GW.TruncateUTF8 = function() error("render exploded") end
        Mock.printed = {}
        local ok = pcall(render)
        GW.TruncateUTF8 = realTrunc
        T.assertTrue(ok, "the wrapper must not let a render error escape to its caller")
        T.assertTrue(printedContains("Leaderboard panel error"),
            "and must report it rather than failing silently")
    end)

    T.test("UI-12: the streak label always says something, including on a brand-new account", function()
        -- A fresh account (or one just wiped by the dev panel's "Clear ALL
        -- data") used to render the empty string here, which is
        -- indistinguishable from the label having failed to update.
        T.assertEquals(GW.StreakLabelText({current = 0, best = 0}), "|cff888888No streak yet|r",
            "0/0 must not render as blank")
        T.assertEquals(GW.StreakLabelText(nil), "|cff888888No streak yet|r",
            "and neither must a missing streak table")
    end)

    T.test("UI-13: streak label wording covers active, broken and singular cases", function()
        T.assertContains(GW.StreakLabelText({current = 5, best = 10}), "5-days streak")
        T.assertContains(GW.StreakLabelText({current = 5, best = 10}), "best 10")

        -- Participation-based streaks make a 1-day streak the common
        -- first-play case, so it shouldn't read "1-days".
        T.assertContains(GW.StreakLabelText({current = 1, best = 1}), "1-day streak")
        T.assertFalse(GW.StreakLabelText({current = 1, best = 1}):find("1-days", 1, true),
            "singular day should not be pluralised")

        -- Broken means a skipped day now, since losing no longer resets.
        T.assertContains(GW.StreakLabelText({current = 0, best = 7}), "Streak broken")
        T.assertContains(GW.StreakLabelText({current = 0, best = 7}), "best 7")
    end)

    T.test("UI-14: the Dev button tracks devMode and is the only way into the panel", function()
        setup()
        dofile("../GuildWordle_Dev.lua")   -- provides SetDevPanelShown/IsDevPanelShown

        GuildWordleDB.settings.devMode = false
        T.assertNoThrow(GW.RefreshDevButton, "hiding the button must not error")
        T.assertFalse(GW.IsDevPanelShown(), "panel stays shut while dev mode is off")

        GuildWordleDB.settings.devMode = true
        T.assertNoThrow(GW.RefreshDevButton, "showing the button must not error")
        T.assertFalse(GW.IsDevPanelShown(),
            "turning dev mode on reveals the button but must not open the panel itself")

        -- What the button's OnClick does.
        GW.SetDevPanelShown(true)
        T.assertTrue(GW.IsDevPanelShown(), "the button opens the panel")
        GW.SetDevPanelShown(false)
    end)

    T.test("UI-16: the Dev button stays hidden in a release build, even if devMode is hand-set", function()
        -- Released builds have GuildWordle_Dev.lua stripped by the packager,
        -- so GW.SetDevPanelShown doesn't exist. devMode is just a
        -- SavedVariables flag, though, and anyone can edit that file to set
        -- it true -- which must not surface a button whose only action is a
        -- no-op. Simulated by removing the dev file's entry points.
        setup()
        local realSet, realIs = GW.SetDevPanelShown, GW.IsDevPanelShown
        GW.SetDevPanelShown, GW.IsDevPanelShown = nil, nil
        GuildWordleDB.settings.devMode = true

        T.assertNoThrow(GW.RefreshDevButton,
            "refreshing must not error when the dev file is absent")
        T.assertNoThrow(function()
            if GW.RefreshMainUI then GW.RefreshMainUI() end
        end, "a full refresh must not error either")

        GW.SetDevPanelShown, GW.IsDevPanelShown = realSet, realIs
    end)

    T.test("UI-15: a full window refresh updates the Dev button too", function()
        setup()
        GuildWordleDB.settings.devMode = true
        -- RefreshUI runs on frame show; it must include the dev button, or the
        -- button would only appear after some other event happened to call it.
        renderCleanly("refresh with dev mode on")
        T.assertNoThrow(function()
            if GW.RefreshMainUI then GW.RefreshMainUI() end
        end, "full refresh must not error with dev mode on")
    end)

    T.test("UI-11: a rename mid-session re-renders without error and updates the mapping", function()
        setup()
        A.winToday()
        render()
        T.assertNoThrow(function() GW.SetNickname("Renamedhere") end,
            "SetNickname drives OnNicknameChanged -> render")
        T.assertEquals(GuildWordleDB.charNicknames[GUILD]["Realchar"], "Renamedhere",
            "the Today tab's nickname lookup should be refreshed synchronously")
    end)

end)

T.run()
