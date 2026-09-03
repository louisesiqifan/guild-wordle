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

-- Identifies the current character (not the account), since the account can
-- have multiple characters — each must get its own daily game, not a shared
-- one. Includes realm since character names can collide across realms.
local function CharKey()
    return UnitName("player") .. "-" .. GetRealmName()
end

-- Identifies the current character's guild, since the account can have
-- characters in different guilds — leaderboard/gossip data must stay scoped
-- to the guild it came from, never bleed into an unrelated guild's board.
function GW.CurrentGuildKey()
    local guildName = GetGuildInfo("player")
    return guildName or "NOGUILD"
end

-- ── SavedVariables init ───────────────────────────────────────────────────────

local function InitDB()
    GuildWordleDB = GuildWordleDB or {}
    GuildWordleDB.leaderboard = GuildWordleDB.leaderboard or {}
    GuildWordleDB.games = GuildWordleDB.games or {}
    GuildWordleDB.settings = GuildWordleDB.settings or {}
    GuildWordleDB.settings.autoShare = GuildWordleDB.settings.autoShare
        or {GUILD = true, PARTY = true, RAID = true}
    GuildWordleDB.settings.scale = GuildWordleDB.settings.scale or 1
    -- Account-wide (not per-character, unlike the game itself): playing on
    -- whichever character on a given day keeps the streak going, since it's
    -- tracking "did this account solve today", not any one character's run.
    GuildWordleDB.streak = GuildWordleDB.streak or { current = 0, best = 0, lastDate = nil }
    -- Account-wide nickname shown on the guild streak leaderboard (streaks
    -- are account-wide but the character name changes per alt) — defaults to
    -- the current character's name the first time any character on this
    -- account opens the addon after this update.
    GuildWordleDB.settings.nickname = GuildWordleDB.settings.nickname or UnitName("player")
    -- Stable, hidden per-account identity key for the streak leaderboard —
    -- frozen the first time any character on this account ever loads the
    -- addon, and never re-evaluated after that (this `or` only actually
    -- calls CharKey() once, ever; every later login on any alt/realm just
    -- reuses the stored value). It happens to be shaped like a character's
    -- CharKey purely because that's a convenient, Blizzard-guaranteed-unique
    -- string to grab at that first moment — it is NOT treated as "the
    -- current character" anywhere after this line, and stays correct even
    -- if that original character is later renamed, transferred, or deleted.
    -- This exists so the streak leaderboard can key entries by something
    -- that never changes, while the player-facing nickname (which CAN
    -- change) is just a display field riding along inside each entry — see
    -- GW.RecordOwnStreakEntry / streakBoard below.
    GuildWordleDB.accountId = GuildWordleDB.accountId or CharKey()
    -- Per-guild streak leaderboard: streakBoard[guildKey][accountId] =
    -- {nickname, current, best, lastDate}, synced via the same gossip
    -- pattern as the daily results leaderboard below.
    GuildWordleDB.streakBoard = GuildWordleDB.streakBoard or {}
    -- Per-guild charName -> nickname lookup, gossiped separately (see
    -- GW.BroadcastCharNicknames) so the RESULTS: wire format itself never has
    -- to change — old and new clients keep sending/parsing the exact same
    -- 4-field results message either way, and nickname is purely a
    -- display-time lookup layered on top for clients that understand it.
    GuildWordleDB.charNicknames = GuildWordleDB.charNicknames or {}

    local cutoff = tonumber(date("%Y%m%d", time() - 7*86400))

    -- Prune leaderboard entries (per guild bucket) older than 7 days
    for _, byDate in pairs(GuildWordleDB.leaderboard) do
        for d in pairs(byDate) do
            local dNum = tonumber(d)
            if not dNum or dNum < cutoff then byDate[d] = nil end
        end
    end

    -- Prune stale per-character game state older than 7 days
    for key, g in pairs(GuildWordleDB.games) do
        local dNum = g and tonumber(g.date)
        if not dNum or dNum < cutoff then GuildWordleDB.games[key] = nil end
    end
end

-- Returns today's game state for the *current character*, creating/resetting
-- it if this is the first access today or the saved state is corrupted.
function GW.CurrentGame()
    local key   = CharKey()
    local today = GetDateString()
    local g     = GuildWordleDB.games[key]

    if not g or g.date ~= today then
        g = { date = today, guesses = {}, results = {}, state = "playing" }
        GuildWordleDB.games[key] = g
    end

    -- Repair corrupted state (e.g. from a crashed previous session)
    if type(g.guesses) ~= "table" then g.guesses = {} end
    if type(g.results) ~= "table" then g.results = {} end
    if #g.guesses ~= #g.results then
        g.guesses, g.results, g.state = {}, {}, "playing"
    end
    if g.state == "playing" and #g.guesses >= MAX_GUESSES then
        g.state = "lost"
    end

    return g
end

-- Updates the account-wide streak the first time *any* character finishes
-- today's game; later completions by other characters the same day are
-- no-ops (the day is already accounted for). A win extends the streak only
-- if the previous recorded day was literally yesterday — a skipped day, not
-- just a loss, also breaks it. Losing resets the streak to 0 immediately.
function GW.RecordStreakResult(won)
    local s     = GuildWordleDB.streak
    local today = GetDateString()
    if s.lastDate == today then return end

    if won then
        local yesterday = date("%Y%m%d", time() - 86400)
        if s.current > 0 and s.lastDate == yesterday then
            s.current = s.current + 1
        else
            s.current = 1
        end
        if s.current > s.best then s.best = s.current end
    else
        s.current = 0
    end
    s.lastDate = today
end

-- Returns the account-wide streak table, first zeroing out `current` if the
-- last recorded day is older than yesterday — i.e. the player skipped at
-- least one full day without playing at all. RecordStreakResult() already
-- gets this right at the moment of the *next* completed game (a stale
-- lastDate fails the "extend" check and falls through to a reset), but
-- without this, anything that just *reads* the streak (the UI label,
-- /wordle streak, or a broadcast to the guild streak board) would keep
-- showing the old count until the player next plays. Call this instead of
-- reading GuildWordleDB.streak directly anywhere outside RecordStreakResult.
function GW.CurrentStreak()
    local s = GuildWordleDB.streak
    if s.current > 0 then
        local today     = GetDateString()
        local yesterday = date("%Y%m%d", time() - 86400)
        if s.lastDate ~= today and s.lastDate ~= yesterday then
            s.current = 0
        end
    end
    return s
end

-- ── Nickname ─────────────────────────────────────────────────────────────────
-- Account-wide (like the streak itself), since the streak leaderboard needs
-- one stable label per account regardless of which alt is currently logged
-- in. It's purely a *display* field inside each streakBoard entry — entries
-- are actually keyed by GuildWordleDB.accountId (see InitDB), so renaming is
-- just an in-place field update, the same as current/best/lastDate already
-- are; no delete-and-recreate dance, no separate rename message needed.
-- Letters only (A-Z/a-z) — everything else (digits, spaces, punctuation,
-- commas/semicolons) is stripped, since nicknames travel over the same
-- delimited addon-message formats as everything else and a stray digit or
-- delimiter character could otherwise be misread as part of a different
-- field by a client parsing an older/simpler wire format.

local MAX_NICK_LEN = 16

function GW.SetNickname(raw)
    local trimmed = strtrim(raw or "")
    if trimmed == "" then
        print("|cffFFD700[GuildWordle]|r Current nickname: \"" ..
            (GuildWordleDB.settings.nickname or "") .. "\"  (use /wordle nick <name> to change it)")
        return
    end

    local name = trimmed:gsub("[^%a]", "")
    if name == "" then
        print("|cffFFD700[GuildWordle]|r Nicknames can only contain letters (A-Z).")
        return
    end
    if #name > MAX_NICK_LEN then name = name:sub(1, MAX_NICK_LEN) end

    if GuildWordleDB.settings.nickname == name then
        print("|cffFFD700[GuildWordle]|r Nickname is already \"" .. name .. "\".")
        return
    end

    GuildWordleDB.settings.nickname = name

    print("|cffFFD700[GuildWordle]|r Nickname set to \"" .. name .. "\".")
    if GW.OnNicknameChanged then GW.OnNicknameChanged() end
    GW.BroadcastStreak()
    GW.BroadcastCharNicknames()
end

function GW.ResetGame()
    local today = GetDateString()
    GuildWordleDB.games[CharKey()] = { date=today, guesses={}, results={}, state="playing" }
    if GuildWordleFrame and GuildWordleFrame:IsShown() then
        GuildWordleFrame:Hide()
        GuildWordleFrame:Show()
    end
    print("|cffFFD700[GuildWordle]|r Today's game has been reset.")
end

-- Dev/testing aid: wipes every guild's daily-results leaderboard and streak
-- leaderboard, and resets this account's own streak back to zero, so the
-- whole leaderboard feature can be tested from a clean slate repeatedly.
-- Unlike GW.ResetGame, this does NOT touch today's in-progress puzzle.
function GW.ResetLeaderboard()
    GuildWordleDB.leaderboard   = {}
    GuildWordleDB.streakBoard   = {}
    GuildWordleDB.charNicknames = {}
    GuildWordleDB.streak        = { current = 0, best = 0, lastDate = nil }
    if GuildWordleFrame and GuildWordleFrame:IsShown() then
        GuildWordleFrame:Hide()
        GuildWordleFrame:Show()
    end
    print("|cffFFD700[GuildWordle]|r Leaderboard and streak data reset (dev/testing).")
end

-- ── Game logic ────────────────────────────────────────────────────────────────

-- Returns ok, reason|result, done, won
function GW.SubmitGuess(raw)
    local guess = raw:upper()
    local game  = GW.CurrentGame()

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
    local game     = GW.CurrentGame()
    local today    = GetDateString()
    local me       = UnitName("player")
    local numGuess = #game.guesses
    local packed   = PackResults(game.results)
    local guildKey = GW.CurrentGuildKey()

    -- Save locally first, scoped to the guild this character is actually in.
    -- Still keyed by character name — alts each keep their own row on
    -- today's leaderboard, same as always. Nickname is NOT stored here; it's
    -- resolved at display time from GuildWordleDB.charNicknames instead, so
    -- this entry's shape (and the RESULTS: wire format below) stays exactly
    -- what pre-nickname clients already understand.
    GuildWordleDB.leaderboard[guildKey] = GuildWordleDB.leaderboard[guildKey] or {}
    GuildWordleDB.leaderboard[guildKey][today] = GuildWordleDB.leaderboard[guildKey][today] or {}
    GuildWordleDB.leaderboard[guildKey][today][me] = {
        guesses = numGuess, solved = won, pattern = packed,
    }

    GW.RecordStreakResult(won)

    if IsInGuild() then
        GW.BroadcastKnownResults()
        GW.BroadcastStreak()
        GW.BroadcastCharNicknames()
    end

    GW.AutoShareResult()
end

-- ── Auto-share ───────────────────────────────────────────────────────────────
-- Whether a completed result is posted to visible chat is controlled by the
-- Guild/Party/Raid checkboxes in the UI (GuildWordleDB.settings.autoShare) —
-- checked here automatically rather than requiring a manual action each time.

local function BuildShareMessage()
    local game     = GW.CurrentGame()
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

local CHANNEL_NAMES = {GUILD = "Guild", PARTY = "Party", RAID = "Raid"}

-- Posts to every checked channel the player is currently actually in.
-- Returns the list of friendly channel names it posted to (possibly empty).
local function ShareToCheckedChannels()
    local autoShare = GuildWordleDB.settings and GuildWordleDB.settings.autoShare
    if not autoShare then return {} end

    local shared = {}
    local msg
    for _, channel in ipairs({"GUILD", "PARTY", "RAID"}) do
        if autoShare[channel] and ChannelIsActive(channel) then
            msg = msg or BuildShareMessage()
            SendChatMessage(msg, channel)
            shared[#shared + 1] = CHANNEL_NAMES[channel]
        end
    end
    return shared
end

function GW.AutoShareResult()
    ShareToCheckedChannels()
end

-- Ad-hoc re-broadcast for when the checkboxes were toggled on after the game
-- already ended (e.g. someone forgot to check them beforehand).
function GW.ShareNow()
    if GW.CurrentGame().state == "playing" then return end

    local shared = ShareToCheckedChannels()
    if #shared == 0 then
        print("|cffFFD700[GuildWordle]|r No channels to share to right now (check the boxes above and make sure you're in that channel).")
    else
        print("|cffFFD700[GuildWordle]|r Shared to " .. table.concat(shared, ", ") .. "!")
    end
end

-- ── Addon-message sync ────────────────────────────────────────────────────────
-- Gossip protocol: every broadcast carries *everything the sender currently
-- knows* for today (not just its own result), so a result can reach a client
-- secondhand through anyone who was online with both parties at different
-- times, instead of requiring the original player to be online at that exact
-- moment. Entries are packed as "name,guesses,solved,pattern" joined by ";"
-- — this wire format is unchanged from before nicknames existed, on purpose
-- (see GW.BroadcastCharNicknames below for how nicknames are layered on top
-- without touching this). WoW addon messages are capped at ~255 chars, so a
-- large leaderboard is split across multiple messages rather than assumed to
-- fit in one.

local MAX_MSG_LEN = 200  -- payload budget per message, safely under the ~255-char cap

function GW.BroadcastKnownResults()
    if not IsInGuild() then return end
    local today = GetDateString()
    -- Only ever gossip the entries scoped to *this* character's current guild —
    -- never leak another guild's data an alt on this account happens to know.
    local lb = GuildWordleDB.leaderboard[GW.CurrentGuildKey()]
    lb = lb and lb[today]
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

-- ── Character nicknames (gossip) ──────────────────────────────────────────────
-- A separate, purely-additive broadcast that maps this guild's known
-- charName -> nickname pairs, kept entirely independent of
-- GW.BroadcastKnownResults so the RESULTS: wire format never has to change.
-- Old clients don't recognize the "NICKS:" prefix and silently ignore it,
-- exactly like they already ignore "STREAKS:" — nothing breaks for them, they
-- just never learn any nicknames (and never send any either, so a New client
-- looking at an Old client's results just falls back to showing their
-- character name, which is the same thing Old clients show anyway).
-- Not date-scoped (a nickname isn't "today" data) and — unlike the streak
-- board — doesn't need freshness/rollback merge logic: this is a display-only
-- label, so a stale echo momentarily showing an old nickname isn't a
-- correctness problem the way a stale streak count would be, and it
-- self-corrects on the next periodic broadcast.

-- Writes this character's own name -> current nickname pairing into the
-- local per-guild map, so it shows up correctly even before any gossip
-- round-trip.
function GW.RecordOwnCharNickname()
    local guildKey = GW.CurrentGuildKey()
    GuildWordleDB.charNicknames[guildKey] = GuildWordleDB.charNicknames[guildKey] or {}
    GuildWordleDB.charNicknames[guildKey][UnitName("player")] = GuildWordleDB.settings.nickname
end

function GW.BroadcastCharNicknames()
    if not IsInGuild() then return end
    GW.RecordOwnCharNickname()
    local names = GuildWordleDB.charNicknames[GW.CurrentGuildKey()]
    if not names or not next(names) then return end

    local header = "NICKS:"
    local batch, batchLen = {}, #header

    local function flush()
        if #batch > 0 then
            SendAddonMsg(header .. table.concat(batch, ";"))
            batch, batchLen = {}, #header
        end
    end

    for charName, nick in pairs(names) do
        local entry = string.format("%s,%s", charName, nick)
        if batchLen + #entry + 1 > MAX_MSG_LEN and #batch > 0 then
            flush()
        end
        batch[#batch+1] = entry
        batchLen = batchLen + #entry + 1
    end
    flush()
end

-- ── Streak leaderboard (gossip) ───────────────────────────────────────────────
-- Same gossip shape as GW.BroadcastKnownResults above, but keyed by the
-- stable per-account accountId (see InitDB) rather than character name,
-- since the streak itself is account-wide — and not date-scoped, since a
-- streak isn't "today's" data the way a guess result is. The player-facing
-- nickname rides along as a plain field inside each entry, so renaming is
-- just an ordinary field update on the existing key, not a new entry.

-- Writes this account's own live streak into the local per-guild streak
-- board under its accountId, so it shows up in its own ranking immediately —
-- not just after a round-trip through guild chat.
function GW.RecordOwnStreakEntry()
    local guildKey = GW.CurrentGuildKey()
    local s        = GW.CurrentStreak()
    GuildWordleDB.streakBoard[guildKey] = GuildWordleDB.streakBoard[guildKey] or {}
    GuildWordleDB.streakBoard[guildKey][GuildWordleDB.accountId] = {
        nickname = GuildWordleDB.settings.nickname,
        current = s.current, best = s.best, lastDate = s.lastDate or "0",
    }
end

function GW.BroadcastStreak()
    if not IsInGuild() then return end
    GW.RecordOwnStreakEntry()
    local board = GuildWordleDB.streakBoard[GW.CurrentGuildKey()]
    if not board or not next(board) then return end

    local header = "STREAKS:"
    local batch, batchLen = {}, #header

    local function flush()
        if #batch > 0 then
            SendAddonMsg(header .. table.concat(batch, ";"))
            batch, batchLen = {}, #header
        end
    end

    for id, d in pairs(board) do
        local entry = string.format("%s,%s,%d,%d,%s", id, d.nickname or "", d.current, d.best, d.lastDate or "0")
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
        GW.BroadcastStreak()
        GW.BroadcastCharNicknames()

    elseif text:sub(1,8) == "RESULTS:" then
        local _, _, rDate, rest = text:find("^RESULTS:([^:]+):(.+)$")
        if rDate == today and rest then
            local changed = false
            -- Addon messages only ever arrive over the guild channel this
            -- character is currently in, so it's always safe to store the
            -- incoming data under that same guild's bucket.
            local guildKey = GW.CurrentGuildKey()
            GuildWordleDB.leaderboard[guildKey] = GuildWordleDB.leaderboard[guildKey] or {}
            GuildWordleDB.leaderboard[guildKey][today] = GuildWordleDB.leaderboard[guildKey][today] or {}
            for entry in rest:gmatch("[^;]+") do
                local rName, rGuess, rSolved, rPat = entry:match("^([^,]+),(%d+),([01]),(.+)$")
                if rName then
                    GuildWordleDB.leaderboard[guildKey][today][rName] = {
                        guesses = tonumber(rGuess),
                        solved  = rSolved == "1",
                        pattern = rPat,
                    }
                    changed = true
                end
            end
            if changed and GW.OnLeaderboardUpdate then GW.OnLeaderboardUpdate() end
        end

    elseif text:sub(1,6) == "NICKS:" then
        local rest = text:sub(7)
        if rest and rest ~= "" then
            local changed   = false
            local guildKey  = GW.CurrentGuildKey()
            GuildWordleDB.charNicknames[guildKey] = GuildWordleDB.charNicknames[guildKey] or {}
            local names = GuildWordleDB.charNicknames[guildKey]
            for entry in rest:gmatch("[^;]+") do
                local rChar, rNick = entry:match("^([^,]+),([^,]*)$")
                if rChar and rNick and rNick ~= "" and names[rChar] ~= rNick then
                    names[rChar] = rNick
                    changed = true
                end
            end
            if changed and GW.OnLeaderboardUpdate then GW.OnLeaderboardUpdate() end
        end

    elseif text:sub(1,8) == "STREAKS:" then
        local rest = text:sub(9)
        if rest and rest ~= "" then
            local changed  = false
            local guildKey = GW.CurrentGuildKey()
            GuildWordleDB.streakBoard[guildKey] = GuildWordleDB.streakBoard[guildKey] or {}
            local board = GuildWordleDB.streakBoard[guildKey]
            for entry in rest:gmatch("[^;]+") do
                local rId, rNick, rCur, rBest, rDate = entry:match("^([^,]+),([^,]*),(%d+),(%d+),(%d+)$")
                if rId then
                    local existing = board[rId]
                    -- "best" only ever moves up, regardless of message freshness.
                    local newBest = tonumber(rBest)
                    if existing and existing.best and existing.best > newBest then
                        newBest = existing.best
                    end
                    -- Only accept the incoming "current"/"nickname" if it's at
                    -- least as fresh (same-or-later lastDate) as what we
                    -- already have — otherwise a delayed/stale gossip echo
                    -- could make an already-broken streak appear active again,
                    -- or roll a rename back to the old name. Dates are
                    -- YYYYMMDD strings, so lexical >= is numerically correct.
                    if not existing or rDate >= (existing.lastDate or "0") then
                        board[rId] = { nickname = rNick, current = tonumber(rCur), best = newBest, lastDate = rDate }
                        changed = true
                    elseif newBest > (existing.best or 0) then
                        existing.best = newBest
                        changed = true
                    end
                end
            end
            if changed and GW.OnStreakBoardUpdate then GW.OnStreakBoardUpdate() end
        end
    end
end

-- ── Leaderboard (printed to chat) ────────────────────────────────────────────

function GW.PrintLeaderboard()
    local today     = GetDateString()
    local guildKey  = GW.CurrentGuildKey()
    local lb        = GuildWordleDB.leaderboard[guildKey] and GuildWordleDB.leaderboard[guildKey][today]
    local game      = GW.CurrentGame()
    local hasPlayed = game.date == today and game.state ~= "playing"

    if not lb or not next(lb) then
        print("|cffFFD700[GuildWordle]|r No results yet today.  |cffFFFFFF/wordle|r to play!")
        return
    end

    print("|cffFFD700===== GuildWordle · " .. date("%B %d, %Y") .. " =====|r")
    if hasPlayed then
        print("|cff888888Today's word: " .. GW.todaysWord .. "|r")
    end

    local names = GuildWordleDB.charNicknames[guildKey]
    local entries = {}
    for n, d in pairs(lb) do
        entries[#entries+1] = {name = (names and names[n]) or n, guesses=d.guesses, solved=d.solved, pattern=d.pattern}
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

-- ── Events & slash ───────────────────────────────────────────────────────────

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
                    if IsInGuild() then
                        GW.BroadcastKnownResults()
                        GW.BroadcastStreak()
                        GW.BroadcastCharNicknames()
                    end
                end)
            end
        end

    elseif event == "PLAYER_LOGIN" then
        SafeDelay(6, function()
            if not IsInGuild() then return end
            SendAddonMsg("SYNC_REQ")
            GW.BroadcastKnownResults()
            GW.BroadcastStreak()
            GW.BroadcastCharNicknames()
        end)

    elseif event == "CHAT_MSG_ADDON" then
        HandleAddonMessage(...)
    end
end)

SLASH_GUILDWORDLE1 = "/wordle"
SlashCmdList["GUILDWORDLE"] = function(msg)
    -- Nicknames need their original casing preserved, so keep a raw copy
    -- alongside the lowercased one used for command matching.
    local raw   = strtrim(msg)
    local lower = raw:lower()

    if lower == "lb" or lower == "leaderboard" then
        GW.PrintLeaderboard()
    elseif lower == "streak" then
        local s = GW.CurrentStreak()
        if s.current > 0 then
            print(string.format("|cffFFD700[GuildWordle]|r Current streak: %d day%s (best: %d)",
                s.current, s.current == 1 and "" or "s", s.best))
        else
            print(string.format("|cffFFD700[GuildWordle]|r No active streak (best: %d)", s.best))
        end
    elseif lower == "nick" then
        GW.SetNickname("")
    elseif lower:sub(1,5) == "nick " then
        GW.SetNickname(raw:sub(6))
    elseif lower == "reset" then
        GW.ResetGame()
    elseif lower == "reset-leaderboard" then
        GW.ResetLeaderboard()
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
