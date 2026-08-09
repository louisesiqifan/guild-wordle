GuildWordle = GuildWordle or {}
local GW = GuildWordle

local ADDON_PREFIX = "GUILDWORDLE"
local MAX_GUESSES  = 6
local WORD_LEN     = 5

-- Symbols used in guild chat announce (plain text, safe for WoW chat)
GW.SYM_GREEN  = "\226\150\160"  -- ■  U+25A0
GW.SYM_YELLOW = "\226\150\161"  -- □  U+25A1
GW.SYM_GREY   = "X"

-- Tile background colors for UI
GW.TILE_COLORS = {
    empty  = {r=0.12, g=0.12, b=0.12},
    filled = {r=0.30, g=0.30, b=0.30},
    green  = {r=0.33, g=0.55, b=0.30},
    yellow = {r=0.71, g=0.62, b=0.24},
    grey   = {r=0.23, g=0.23, b=0.24},
}

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function GetDateString()
    return date("%Y%m%d")
end

-- Deterministic word selection; same date = same word on all clients.
-- Uses a simple LCG so it never touches math.randomseed (which would break
-- other addons sharing the random state).
local function GetTodaysWord()
    if not GuildWordle_Answers or #GuildWordle_Answers == 0 then return "ERROR" end
    local t = date("*t")
    local seed = t.year * 10000 + t.month * 100 + t.day
    local x = seed
    for _ = 1, 7 do
        x = (x * 1664525 + 1013904223) % 4294967296
    end
    return GuildWordle_Answers[(x % #GuildWordle_Answers) + 1]:upper()
end

-- Hash set for O(1) guess validation against the ~14,800-word NYT dictionary.
local ValidWordSet = {}
for _, w in ipairs(GuildWordle_ValidWords or {}) do
    ValidWordSet[w] = true
end

-- Standard Wordle evaluation: 2=green, 1=yellow, 0=grey
local function EvaluateGuess(guess, answer)
    local result = {0, 0, 0, 0, 0}
    local pool = {}
    for i = 1, WORD_LEN do
        if guess:sub(i,i) == answer:sub(i,i) then
            result[i] = 2
        else
            local c = answer:sub(i,i)
            pool[c] = (pool[c] or 0) + 1
        end
    end
    for i = 1, WORD_LEN do
        if result[i] == 0 then
            local c = guess:sub(i,i)
            if pool[c] and pool[c] > 0 then
                result[i] = 1
                pool[c] = pool[c] - 1
            end
        end
    end
    return result
end

local function ResultRowsToSymbols(rows)
    local parts = {}
    for _, row in ipairs(rows) do
        local s = ""
        for _, v in ipairs(row) do
            if     v == 2 then s = s .. GW.SYM_GREEN
            elseif v == 1 then s = s .. GW.SYM_YELLOW
            else            s = s .. GW.SYM_GREY
            end
        end
        parts[#parts+1] = s
    end
    return table.concat(parts, " ")
end

-- Pack result rows into a compact string for SavedVariables / addon messages.
-- Format: "02100 21010 22222" (one 5-digit string per row, space-separated)
local function PackResults(rows)
    local parts = {}
    for _, row in ipairs(rows) do
        local s = ""
        for _, v in ipairs(row) do s = s .. v end
        parts[#parts+1] = s
    end
    return table.concat(parts, " ")
end

function GW.UnpackResults(str)
    local rows = {}
    for chunk in str:gmatch("%S+") do
        local row = {}
        for c in chunk:gmatch(".") do row[#row+1] = tonumber(c) or 0 end
        rows[#rows+1] = row
    end
    return rows
end

local function StripRealm(fullName)
    return (fullName:match("^([^%-]+)")) or fullName
end

local function SafeDelay(secs, fn)
    if C_Timer and C_Timer.After then
        C_Timer.After(secs, fn)
    else
        local f, elapsed = CreateFrame("Frame"), 0
        f:SetScript("OnUpdate", function(self, dt)
            elapsed = elapsed + dt
            if elapsed >= secs then self:SetScript("OnUpdate", nil); fn() end
        end)
    end
end

local function SendAddonMsg(msg)
    if not IsInGuild() then return end
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(ADDON_PREFIX, msg, "GUILD")
    elseif SendAddonMessage then
        SendAddonMessage(ADDON_PREFIX, msg, "GUILD")
    end
end

-- ── SavedVariables init ───────────────────────────────────────────────────────────

local function InitDB()
    GuildWordleDB = GuildWordleDB or {}
    GuildWordleDB.leaderboard = GuildWordleDB.leaderboard or {}
    GuildWordleDB.game = GuildWordleDB.game or {}
    GuildWordleDB.settings = GuildWordleDB.settings or {}
    GuildWordleDB.settings.autoShare = GuildWordleDB.settings.autoShare
        or {GUILD = false, PARTY = false, RAID = false}

    local today = GetDateString()
    if GuildWordleDB.game.date ~= today then
        GuildWordleDB.game = { date=today, guesses={}, results={}, state="playing" }
    end

    -- Repair corrupted states (e.g. from a crashed previous session)
    local g = GuildWordleDB.game
    if type(g.guesses) ~= "table" then g.guesses = {} end
    if type(g.results) ~= "table" then g.results = {} end
    if #g.guesses ~= #g.results then
        g.guesses, g.results, g.state = {}, {}, "playing"
    end
    if g.state == "playing" and #g.guesses >= MAX_GUESSES then
        g.state = "lost"
    end

    GuildWordleDB.leaderboard[today] = GuildWordleDB.leaderboard[today] or {}

    -- Prune entries older than 7 days
    local cutoff = tonumber(date("%Y%m%d", time() - 7*86400))
    for k in pairs(GuildWordleDB.leaderboard) do
        if tonumber(k) < cutoff then GuildWordleDB.leaderboard[k] = nil end
    end
end

function GW.ResetGame()
    local today = GetDateString()
    GuildWordleDB.game = { date=today, guesses={}, results={}, state="playing" }
    if GuildWordleFrame and GuildWordleFrame:IsShown() then
        GuildWordleFrame:Hide()
        GuildWordleFrame:Show()
    end
    print("|cffFFD700[GuildWordle]|r Today's game has been reset.")
end

-- ── Game logic ────────────────────────────────────────────────────────────

-- Returns ok, reason|result, done, won
function GW.SubmitGuess(raw)
    local guess = raw:upper()
    local game  = GuildWordleDB.game

    if game.state ~= "playing"  then return false, "already_done"  end
    if #guess ~= WORD_LEN       then return false, "wrong_length"  end

    local lower = guess:lower()
    if not ValidWordSet[lower] then return false, "not_a_word" end

    local result = EvaluateGuess(guess, GW.todaysWord)
    game.guesses[#game.guesses+1] = guess
    game.results[#game.results+1] = result

    local won = true
    for _, v in ipairs(result) do if v ~= 2 then won = false; break end end

    local done = won or (#game.guesses >= MAX_GUESSES)
    if done then
        game.state = won and "won" or "lost"
        GW.OnGameEnd(won)
    end

    return true, result, done, won
end

function GW.OnGameEnd(won)
    local game     = GuildWordleDB.game
    local today    = GetDateString()
    local me       = UnitName("player")
    local numGuess = #game.guesses
    local packed   = PackResults(game.results)

    -- Save locally first
    GuildWordleDB.leaderboard[today][me] = {
        guesses = numGuess, solved = won, pattern = packed,
    }

    if IsInGuild() then
        GW.BroadcastKnownResults()
    end

    GW.AutoShareResult()
end

-- ── Auto-share ───────────────────────────────────────────────────────────────
-- Whether a completed result is posted to visible chat is controlled by the
-- Guild/Party/Raid checkboxes in the UI (GuildWordleDB.settings.autoShare) —
-- checked here automatically rather than requiring a manual action each time.

local function BuildShareMessage()
    local game     = GuildWordleDB.game
    local me       = UnitName("player")
    local won      = game.state == "won"
    local numGuess = #game.guesses

    if won then
        local triesWord = (numGuess == 1) and "try" or "tries"
        return string.format("[GuildWordle] %s completed today's Wordle in %d %s!", me, numGuess, triesWord)
    else
        return string.format("[GuildWordle] %s gave today's Wordle their best shot but couldn't crack it.", me)
    end
end

-- Party and Raid are mutually exclusive since being in a raid always
-- satisfies IsInGroup() too.
local function ChannelIsActive(channel)
    if channel == "GUILD" then return IsInGuild() end
    if channel == "PARTY" then return IsInGroup() and not IsInRaid() end
    if channel == "RAID"  then return IsInRaid() end
    return false
end

function GW.AutoShareResult()
    local autoShare = GuildWordleDB.settings and GuildWordleDB.settings.autoShare
    if not autoShare then return end

    local msg
    for _, channel in ipairs({"GUILD", "PARTY", "RAID"}) do
        if autoShare[channel] and ChannelIsActive(channel) then
            msg = msg or BuildShareMessage()
            SendChatMessage(msg, channel)
        end
    end
end

-- ── Addon-message sync ──────────────────────────────────────────────────────────
-- Gossip protocol: every broadcast carries *everything the sender currently
-- knows* for today (not just its own result), so a result can reach a client
-- secondhand through anyone who was online with both parties at different
-- times, instead of requiring the original player to be online at that exact
-- moment. Entries are packed as "name,guesses,solved,pattern" joined by ";";
-- WoW addon messages are capped at ~255 chars, so a large leaderboard is split
-- across multiple messages rather than assumed to fit in one.

local MAX_MSG_LEN = 200  -- payload budget per message, safely under the ~255-char cap

function GW.BroadcastKnownResults()
    if not IsInGuild() then return end
    local today = GetDateString()
    local lb = GuildWordleDB.leaderboard[today]
    if not lb or not next(lb) then return end

    local header = "RESULTS:" .. today .. ":"
    local batch, batchLen = {}, #header

    local function flush()
        if #batch > 0 then
            SendAddonMsg(header .. table.concat(batch, ";"))
            batch, batchLen = {}, #header
        end
    end

    for name, d in pairs(lb) do
        local entry = string.format("%s,%d,%s,%s", name, d.guesses, d.solved and "1" or "0", d.pattern)
        if batchLen + #entry + 1 > MAX_MSG_LEN and #batch > 0 then
            flush()
        end
        batch[#batch+1] = entry
        batchLen = batchLen + #entry + 1
    end
    flush()
end

local function HandleAddonMessage(prefix, text, channel, sender)
    if prefix ~= ADDON_PREFIX then return end
    local today = GetDateString()
    local name  = StripRealm(sender)
    local me    = UnitName("player")

    if text == "SYNC_REQ" and name ~= me then
        GW.BroadcastKnownResults()

    elseif text:sub(1,8) == "RESULTS:" then
        local _, _, rDate, rest = text:find("^RESULTS:([^:]+):(.+)$")
        if rDate == today and rest then
            local changed = false
            for entry in rest:gmatch("[^;]+") do
                local rName, rGuess, rSolved, rPat = entry:match("^([^,]+),(%d+),([01]),(.+)$")
                if rName then
                    GuildWordleDB.leaderboard[today][rName] = {
                        guesses = tonumber(rGuess),
                        solved  = rSolved == "1",
                        pattern = rPat,
                    }
                    changed = true
                end
            end
            if changed and GW.OnLeaderboardUpdate then GW.OnLeaderboardUpdate() end
        end
    end
end

-- ── Leaderboard (printed to chat) ────────────────────────────────────────────

function GW.PrintLeaderboard()
    local today    = GetDateString()
    local lb       = GuildWordleDB.leaderboard[today]
    local game     = GuildWordleDB.game
    local hasPlayed = game.date == today and game.state ~= "playing"

    if not lb or not next(lb) then
        print("|cffFFD700[GuildWordle]|r No results yet today.  |cffFFFFFF/wordle|r to play!")
        return
    end

    print("|cffFFD700===== GuildWordle · " .. date("%B %d, %Y") .. " =====|r")
    if hasPlayed then
        print("|cff888888Today's word: " .. GW.todaysWord .. "|r")
    end

    local entries = {}
    for n, d in pairs(lb) do
        entries[#entries+1] = {name=n, guesses=d.guesses, solved=d.solved, pattern=d.pattern}
    end
    table.sort(entries, function(a, b)
        if a.solved ~= b.solved then return a.solved end
        if a.solved then return a.guesses < b.guesses end
        return a.name < b.name
    end)

    for i, e in ipairs(entries) do
        local score = e.solved and (e.guesses.."/6") or "X/6"
        local sym   = ResultRowsToSymbols(GW.UnpackResults(e.pattern))
        print(string.format("|cffFFD700%d.|r %-15s %s   %s", i, e.name, score, sym))
    end
end

-- ── Events & slash ────────────────────────────────────────────────────────

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if (...) == "GuildWordle" then
            InitDB()
            GW.todaysWord = GetTodaysWord()
            if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
                C_ChatInfo.RegisterAddonMessagePrefix(ADDON_PREFIX)
            elseif RegisterAddonMessagePrefix then
                RegisterAddonMessagePrefix(ADDON_PREFIX)
            end

            -- Periodic gossip: re-share everything we know every 5 minutes, so
            -- results keep propagating across a session instead of only at login.
            if C_Timer and C_Timer.NewTicker then
                C_Timer.NewTicker(300, function()
                    if IsInGuild() then GW.BroadcastKnownResults() end
                end)
            end
        end

    elseif event == "PLAYER_LOGIN" then
        SafeDelay(6, function()
            if not IsInGuild() then return end
            SendAddonMsg("SYNC_REQ")
            GW.BroadcastKnownResults()
        end)

    elseif event == "CHAT_MSG_ADDON" then
        HandleAddonMessage(...)
    end
end)

SLASH_GUILDWORDLE1 = "/wordle"
SlashCmdList["GUILDWORDLE"] = function(msg)
    msg = strtrim(msg):lower()
    if msg == "lb" or msg == "leaderboard" then
        GW.PrintLeaderboard()
    elseif msg == "reset" then
        GW.ResetGame()
    else
        if GuildWordleFrame then
            if GuildWordleFrame:IsShown() then
                GuildWordleFrame:Hide()
            else
                GuildWordleFrame:Show()
            end
        end
    end
end
