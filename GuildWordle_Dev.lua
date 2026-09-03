-- ── Dev panel ────────────────────────────────────────────────────────────────
-- In-game testing harness for the things a single client can't otherwise
-- exercise: what the UI does when OTHER clients talk to it. Everything here
-- drives the real code paths -- fake guildmates are injected by handing
-- genuine addon-message strings to the real HandleAddonMessage, not by
-- writing to the DB directly -- so what you see is what a real guildmate's
-- broadcast would actually produce, parsing included.
--
-- Tied to the same /wordle dev switch as error visibility: dev mode on means
-- the panel is up, dev mode off means it's gone. One toggle for "I am
-- debugging right now" rather than two independent ones to keep in sync.
-- Because devMode is persisted, the panel also reappears automatically after
-- a /reload -- which matters, since reload-time bugs are exactly the ones
-- worth having it open for.
--
-- SAFETY: injected fake data lands in your real SavedVariables, which the
-- normal 5-minute gossip ticker would then broadcast to your real guild --
-- fake players would show up on real guildmates' leaderboards. The "Isolate"
-- toggle (ON by default whenever the panel opens) no-ops the three outgoing
-- broadcast functions so nothing leaks while testing. Turn it off only when
-- you deliberately want to test real two-client traffic.

local GW = GuildWordle
if not GW then return end

local ADDON_PREFIX = "GUILDWORDLE"

-- Fake characters are prefixed so cleanup can find them unambiguously and so
-- they're obvious as fakes if any ever do escape to a real guild.
local FAKE_PREFIX = "Zzt"

local function today()
    return date("%Y%m%d")
end

local function daysAgo(n)
    return date("%Y%m%d", time() - n * 86400)
end

local function say(msg)
    print("|cff88ccff[GW Dev]|r " .. msg)
end

-- Feeds a message through the real receive path, exactly as if it had
-- arrived over the guild addon channel from `sender`.
local function inject(text, sender)
    if not (GW._test and GW._test.HandleAddonMessage) then
        say("|cffff4444GW._test.HandleAddonMessage missing -- addon file out of date?|r")
        return
    end
    GW._test.HandleAddonMessage(ADDON_PREFIX, text, "GUILD",
        (sender or (FAKE_PREFIX .. "alpha")) .. "-" .. (GetRealmName() or "Testrealm"))
end

-- ── Isolation ────────────────────────────────────────────────────────────────

local isolated = false
local savedBroadcasts = nil

local function setIsolated(on)
    if on and not savedBroadcasts then
        savedBroadcasts = {
            results = GW.BroadcastKnownResults,
            streak  = GW.BroadcastStreak,
            nicks   = GW.BroadcastCharNicknames,
        }
        GW.BroadcastKnownResults  = function() end
        GW.BroadcastStreak        = function() end
        GW.BroadcastCharNicknames = function() end
        isolated = true
    elseif (not on) and savedBroadcasts then
        GW.BroadcastKnownResults  = savedBroadcasts.results
        GW.BroadcastStreak        = savedBroadcasts.streak
        GW.BroadcastCharNicknames = savedBroadcasts.nicks
        savedBroadcasts = nil
        isolated = false
    end
end

-- ── Fake data sets ───────────────────────────────────────────────────────────
-- Deterministic, never random: this addon deliberately avoids math.random so
-- it can't disturb the shared PRNG state other addons rely on, and the same
-- rule applies to test data (also makes repeated runs comparable).

local FAKES = {
    {char = "alpha",   nick = "Alphanick",  guesses = 2, solved = true,
     pattern = "01200 22222"},
    {char = "bravo",   nick = "Bravonick",  guesses = 4, solved = true,
     pattern = "00100 01020 21200 22222"},
    {char = "charlie", nick = "Charlienick", guesses = 6, solved = false,
     pattern = "00000 01000 10000 00100 02000 20100"},
    {char = "delta",   nick = "Deltanick",  guesses = 1, solved = true,
     pattern = "22222"},
    {char = "echo",    nick = "Echonick",   guesses = 3, solved = true,
     pattern = "10000 02120 22222"},
    {char = "foxtrot", nick = "Foxtrotnick", guesses = 5, solved = true,
     pattern = "00010 01100 20010 21220 22222"},
    {char = "golf",    nick = "Golfnick",   guesses = 6, solved = true,
     pattern = "00000 10000 01000 00100 02220 22222"},
    {char = "hotel",   nick = "Hotelnick",  guesses = 4, solved = false,
     pattern = "00000 01000 00100 02000"},
}

-- Display edge cases: over-length (truncation), accented and Cyrillic
-- (UTF-8 handling), and a name at exactly the 15-char limit.
local EDGE_FAKES = {
    {char = "longname", nick = "Averyverylongnicknameindeed", guesses = 3, solved = true,
     pattern = "01000 02220 22222"},
    {char = "exact",    nick = "Exactlyfifteen", guesses = 2, solved = true,
     pattern = "01200 22222"},
    {char = "accent",   nick = "Bonni\195\169Ren\195\169e", guesses = 4, solved = true,
     pattern = "00100 01020 21200 22222"},
    {char = "cyrillic", nick = "\208\145\208\190\208\189\208\189\208\184", guesses = 5, solved = false,
     pattern = "00000 01000 00100 02000 20100"},
}

local function resultEntry(f)
    return string.format("%s%s,%d,%s,%s",
        FAKE_PREFIX, f.char, f.guesses, f.solved and "1" or "0", f.pattern)
end

-- Sends results in small batches, mirroring how the real broadcaster splits
-- payloads under the addon-message size cap.
local function injectResults(list)
    local batch = {}
    for _, f in ipairs(list) do
        batch[#batch + 1] = resultEntry(f)
        if #batch >= 3 then
            inject("RESULTS:" .. today() .. ":" .. table.concat(batch, ";"))
            batch = {}
        end
    end
    if #batch > 0 then
        inject("RESULTS:" .. today() .. ":" .. table.concat(batch, ";"))
    end
end

local function injectNicks(list)
    local batch = {}
    for _, f in ipairs(list) do
        batch[#batch + 1] = FAKE_PREFIX .. f.char .. "," .. f.nick
        if #batch >= 3 then
            inject("NICKS:" .. table.concat(batch, ";"))
            batch = {}
        end
    end
    if #batch > 0 then
        inject("NICKS:" .. table.concat(batch, ";"))
    end
end

-- ── Actions ──────────────────────────────────────────────────────────────────

-- Exposed on GW (not kept file-local) so the automated suite can drive the
-- same actions the buttons do. Worth testing: if an action builds a
-- malformed message string, manual UAT would quietly show nothing rather
-- than the state being tested, which is exactly the sort of misleading
-- silence this panel exists to eliminate.
local Actions = {}
GW.DevActions = Actions

function Actions.addOne()
    local f = FAKES[1]
    injectResults({f})
    injectNicks({f})
    say("Injected 1 guildmate result (" .. f.nick .. ").")
end

function Actions.addEight()
    injectResults(FAKES)
    injectNicks(FAKES)
    say("Injected " .. #FAKES .. " guildmate results -- check sort order: solved first, "
        .. "then fewest guesses, then alphabetical.")
end

function Actions.addEdgeNames()
    injectResults(EDGE_FAKES)
    injectNicks(EDGE_FAKES)
    say("Injected long / exactly-15 / accented / Cyrillic nicknames -- check truncation "
        .. "and that no character is cut in half.")
end

function Actions.addManyForScroll()
    local list = {}
    for i = 1, 30 do
        local base = FAKES[((i - 1) % #FAKES) + 1]
        list[#list + 1] = {
            char    = string.format("scroll%02d", i),
            nick    = string.format("Scrollnick%02d", i),
            guesses = base.guesses,
            solved  = base.solved,
            pattern = base.pattern,
        }
    end
    injectResults(list)
    injectNicks(list)
    say("Injected 30 results -- check scrolling, and that the row pool caps cleanly.")
end

function Actions.addStreaks()
    -- Varied current/best so both streak tabs have distinguishable content:
    -- some active, some broken-but-with-a-best (should appear only on "Best").
    local entries = {
        {id = "acctAlpha",   nick = "Alphanick",   current = 12, best = 12},
        {id = "acctBravo",   nick = "Bravonick",   current = 5,  best = 9},
        {id = "acctCharlie", nick = "Charlienick", current = 0,  best = 7},
        {id = "acctDelta",   nick = "Deltanick",   current = 3,  best = 3},
        {id = "acctEcho",    nick = "Echonick",    current = 0,  best = 1},
    }
    local batch = {}
    for _, e in ipairs(entries) do
        batch[#batch + 1] = string.format("%s%s,%s,%d,%d,%s",
            FAKE_PREFIX, e.id, e.nick, e.current, e.best, today())
        if #batch >= 3 then
            inject("STREAKS:" .. table.concat(batch, ";"))
            batch = {}
        end
    end
    if #batch > 0 then inject("STREAKS:" .. table.concat(batch, ";")) end
    say("Injected 5 streak entries. 'Streak' tab should show 3 (the active ones); "
        .. "'Best' should show all 5.")
end

function Actions.simulateRename()
    -- The interaction that caused a real bug: a guildmate renames, and every
    -- client that already had their old nickname must update in place rather
    -- than growing a duplicate row.
    local f = FAKES[1]
    injectNicks({{char = f.char, nick = "RenamedAlpha"}})
    say("Simulated rename of " .. f.nick .. " -> RenamedAlpha. The existing row should "
        .. "change name in place, NOT duplicate.")
end

function Actions.simulateStaleEcho()
    -- The freshness gate: an old message must not resurrect a broken streak,
    -- but must still be able to raise 'best'.
    inject("STREAKS:" .. FAKE_PREFIX .. "acctCharlie,Charlienick,99,99," .. daysAgo(3))
    say("Sent a STALE streak echo (3 days old) claiming Charlienick has a 99 streak. "
        .. "'Streak' tab must NOT show it as active; 'Best' MAY rise to 99.")
end

function Actions.simulateSyncReq()
    if not IsInGuild() then
        say("|cffff4444Not in a guild -- SYNC_REQ handling is a no-op here.|r")
        return
    end
    if isolated then
        say("|cffff4444Isolate is ON, so the response won't actually send. "
            .. "Turn it off to test real outgoing traffic.|r")
    end
    inject("SYNC_REQ", FAKE_PREFIX .. "requester")
    say("Simulated an incoming SYNC_REQ -- your client should rebroadcast everything it knows.")
end

function Actions.winToday()
    local g = GW.CurrentGame()
    -- guesses and results must stay the same length or CurrentGame()'s
    -- corruption repair will wipe this right back out.
    g.guesses = {"ADIEU", "CRANE"}
    g.results = {{1,0,0,1,0}, {2,2,2,2,2}}
    g.state   = "won"
    GW.OnGameEnd(true)
    say("Forced a WIN for today. Reopen the window to see the end-of-game state.")
end

function Actions.loseToday()
    local g = GW.CurrentGame()
    g.guesses = {"ADIEU", "ROBOT", "SHEEP", "LLAMA", "SASSY", "ABBEY"}
    g.results = {}
    for i = 1, 6 do g.results[i] = {0,0,0,0,0} end
    g.state = "lost"
    GW.OnGameEnd(false)
    say("Forced a LOSS for today. The word reveal should show the real answer.")
end

function Actions.setStreak()
    GuildWordleDB.streak = {current = 5, best = 10, lastDate = today()}
    if GW.OnStreakBoardUpdate then GW.OnStreakBoardUpdate() end
    say("Set your streak to 5 (best 10). Check the label above the grid and both streak tabs.")
end

function Actions.breakStreak()
    -- lastDate older than yesterday: CurrentStreak() should zero it at read
    -- time, without needing another game to be played.
    GuildWordleDB.streak = {current = 6, best = 10, lastDate = daysAgo(3)}
    if GW.OnStreakBoardUpdate then GW.OnStreakBoardUpdate() end
    say("Set a STALE streak (last played 3 days ago). It should read as broken immediately.")
end

function Actions.resetGame()
    GW.ResetGame()
end

function Actions.clearFakes()
    local removed = 0
    local function sweep(tbl)
        if type(tbl) ~= "table" then return end
        for k in pairs(tbl) do
            if type(k) == "string" and k:sub(1, #FAKE_PREFIX) == FAKE_PREFIX then
                tbl[k] = nil
                removed = removed + 1
            end
        end
    end
    for _, byDate in pairs(GuildWordleDB.leaderboard or {}) do
        for _, entries in pairs(byDate) do sweep(entries) end
    end
    for _, board in pairs(GuildWordleDB.streakBoard or {}) do sweep(board) end
    for _, names in pairs(GuildWordleDB.charNicknames or {}) do sweep(names) end

    if GW.OnLeaderboardUpdate then GW.OnLeaderboardUpdate() end
    say("Removed " .. removed .. " fake entr" .. (removed == 1 and "y" or "ies")
        .. " (everything prefixed '" .. FAKE_PREFIX .. "'). Real data untouched.")
end

function Actions.clearAll()
    GW.ResetLeaderboard()
end

-- ── Panel UI ─────────────────────────────────────────────────────────────────

local PANEL_W, ROW_H, PAD = 300, 24, 12

local SECTIONS = {
    {title = "Simulated guildmates (incoming messages)", buttons = {
        {text = "Add 1 result",              fn = Actions.addOne},
        {text = "Add 8 results (sorting)",    fn = Actions.addEight},
        {text = "Add 30 results (scrolling)", fn = Actions.addManyForScroll},
        {text = "Add long/accented names",    fn = Actions.addEdgeNames},
        {text = "Add streak entries",         fn = Actions.addStreaks},
        {text = "Simulate a rename",          fn = Actions.simulateRename},
        {text = "Simulate stale echo",        fn = Actions.simulateStaleEcho},
        {text = "Simulate SYNC_REQ",          fn = Actions.simulateSyncReq},
    }},
    {title = "Your own state", buttons = {
        {text = "Force win today",     fn = Actions.winToday},
        {text = "Force loss today",    fn = Actions.loseToday},
        {text = "Set streak 5/10",     fn = Actions.setStreak},
        {text = "Break streak (stale)", fn = Actions.breakStreak},
        {text = "Reset today's game",  fn = Actions.resetGame},
    }},
    {title = "Cleanup", buttons = {
        {text = "Clear fake data only", fn = Actions.clearFakes},
        {text = "Clear ALL data",       fn = Actions.clearAll},
    }},
}

local panel

local function BuildPanel()
    -- Height is derived rather than hardcoded so adding a button to any
    -- section above doesn't silently overflow the frame.
    local rows, headers = 0, 0
    for _, s in ipairs(SECTIONS) do
        headers = headers + 1
        rows = rows + #s.buttons
    end
    local height = 78 + headers * 22 + rows * ROW_H + PAD * 2

    local f = CreateFrame("Frame", "GuildWordleDevPanel", UIParent, "BasicFrameTemplate")
    f:SetSize(PANEL_W, height)
    f:SetPoint("CENTER", UIParent, "CENTER", 420, 0)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    if f.TitleText then f.TitleText:SetText("GuildWordle Dev") end

    local bg = f:CreateTexture(nil, "BACKGROUND", nil, -1)
    bg:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -22)
    bg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    bg:SetColorTexture(0.07, 0.07, 0.09, 0.96)

    local y = -30

    -- Isolation toggle, first and prominent: it's what keeps fake data from
    -- reaching a real guild.
    local iso = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    iso:SetSize(22, 22)
    iso:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y)
    iso:SetChecked(true)
    iso:SetScript("OnClick", function(self)
        setIsolated(self:GetChecked() and true or false)
        if isolated then
            say("Isolate |cff00ff00ON|r -- outgoing broadcasts blocked; fake data stays local.")
        else
            say("Isolate |cffff4444OFF|r -- your client will now broadcast to the real guild, "
                .. "including any fake data still present. Clear fakes first.")
        end
    end)

    local isoLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    isoLabel:SetPoint("LEFT", iso, "RIGHT", 2, 0)
    isoLabel:SetText("Isolate (block outgoing)")
    isoLabel:SetTextColor(1, 0.82, 0)

    y = y - 26

    local note = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    note:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y)
    note:SetWidth(PANEL_W - PAD * 2)
    note:SetJustifyH("LEFT")
    note:SetText("|cff888888Fake players are prefixed '" .. FAKE_PREFIX
        .. "'. Keep Isolate on unless testing real traffic.|r")
    y = y - 28

    for _, section in ipairs(SECTIONS) do
        local header = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        header:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y)
        header:SetText("|cffFFD700" .. section.title .. "|r")
        y = y - 20

        for _, b in ipairs(section.buttons) do
            local btn = CreateFrame("Button", nil, f, "GameMenuButtonTemplate")
            btn:SetSize(PANEL_W - PAD * 2, ROW_H - 3)
            btn:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y)
            btn:SetText(b.text)
            btn:SetScript("OnClick", function()
                -- Same containment rule as the rest of the addon: a broken
                -- dev action reports itself instead of failing silently.
                local ok, err = pcall(b.fn)
                if not ok then
                    print("|cffff4444[GW Dev]|r Action error: " .. tostring(err))
                end
            end)
            y = y - ROW_H
        end
        y = y - 4
    end

    -- Closing via the X must leave dev mode too, otherwise devMode and panel
    -- visibility drift apart and "dev mode == panel is up" stops being true.
    f:SetScript("OnHide", function()
        if isolated then
            setIsolated(false)
            say("Panel closed -- Isolate off, normal broadcasting resumed.")
        end
        if GuildWordleDB and GuildWordleDB.settings and GuildWordleDB.settings.devMode then
            GuildWordleDB.settings.devMode = false
            say("Dev mode |cffff4444OFF|r.")
        end
    end)

    return f
end

-- Driven by /wordle dev (see GuildWordle.lua's slash handler) and by the
-- persisted devMode flag at login, so the panel's visibility always matches
-- "am I in dev mode" rather than being a second thing to toggle.
function GW.SetDevPanelShown(show)
    if show then
        if not panel then panel = BuildPanel() end
        if not panel:IsShown() then
            setIsolated(true)
            panel:Show()
            say("Dev panel open. Isolate is ON -- fake data will not reach your guild.")
        end
    elseif panel and panel:IsShown() then
        panel:Hide()   -- the OnHide handler lifts isolation
    end
end

-- Restores the panel on login/reload when dev mode was left on. Deferred a
-- few seconds for the same reason the addon's own login sync is: guild info
-- isn't populated immediately, and several panel actions read it.
local devInit = CreateFrame("Frame")
devInit:RegisterEvent("PLAYER_LOGIN")
devInit:SetScript("OnEvent", function()
    if C_Timer and C_Timer.After then
        C_Timer.After(6, function()
            if GuildWordleDB and GuildWordleDB.settings and GuildWordleDB.settings.devMode then
                GW.SetDevPanelShown(true)
            end
        end)
    end
end)
