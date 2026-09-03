local GW = GuildWordle

local TILE_SZ  = 52
local TILE_GAP = 6
local CELL     = TILE_SZ + 2 + TILE_GAP  -- 60px stride

local GRID_W   = 5 * (TILE_SZ + 2) + 4 * TILE_GAP  -- 294px
local GAME_W   = GRID_W + 26                         -- 320px  (game section)
local LB_W     = 170                                 -- leaderboard section width
local FRAME_W  = GAME_W + LB_W                       -- 490px total
local FRAME_H  = 626

local GRID_X   = 13   -- (GAME_W - GRID_W) / 2
local GRID_Y   = -64  -- pushed down 14px from the base offset to fit the streak line above it

-- ── Tile factory ─────────────────────────────────────────────────────────────

local function CreateTile(parent, x, y)
    local border = CreateFrame("Frame", nil, parent)
    border:SetSize(TILE_SZ + 2, TILE_SZ + 2)
    border:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    border.tex = border:CreateTexture(nil, "BACKGROUND")
    border.tex:SetAllPoints()
    border.tex:SetColorTexture(0.38, 0.38, 0.38, 1)

    local tile = CreateFrame("Frame", nil, border)
    tile:SetSize(TILE_SZ, TILE_SZ)
    tile:SetPoint("CENTER")
    tile.bg = tile:CreateTexture(nil, "BACKGROUND")
    tile.bg:SetAllPoints()
    tile.bg:SetColorTexture(0.12, 0.12, 0.12, 1)

    tile.letter = tile:CreateFontString(nil, "OVERLAY")
    tile.letter:SetFont("Fonts\\FRIZQT__.TTF", 22, "OUTLINE")
    tile.letter:SetPoint("CENTER")
    tile.letter:SetText("")

    tile.border = border
    return tile
end

local function SetTileState(tile, letter, state)
    local c = GW.TILE_COLORS[state] or GW.TILE_COLORS.empty
    tile.bg:SetColorTexture(c.r, c.g, c.b, 1)
    tile.letter:SetText(letter or "")
    if state == "empty" then
        tile.border.tex:SetColorTexture(0.28, 0.28, 0.28, 1)
    elseif state == "filled" then
        tile.border.tex:SetColorTexture(0.60, 0.60, 0.60, 1)
    else
        tile.border.tex:SetColorTexture(0.08, 0.08, 0.08, 1)
    end
end

-- ── Main frame ────────────────────────────────────────────────────────────────

local frame = CreateFrame("Frame", "GuildWordleFrame", UIParent, "BasicFrameTemplate")
frame:SetSize(FRAME_W, FRAME_H)
frame:SetPoint("CENTER")
frame:Hide()
frame:SetMovable(true)
-- Needed so the frame's own body/background can receive mouse events at all —
-- RegisterForDrag only picks which button starts a drag once mouse events are
-- actually reaching the frame; without this, clicks on blank background areas
-- (not covered by a more specific mouse-enabled child) fall straight through
-- to the 3D world instead of registering as a drag on this frame.
frame:EnableMouse(true)
frame:SetClampedToScreen(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
if frame.TitleText then frame.TitleText:SetText("GuildWordle") end

-- Full dark background
local bg = frame:CreateTexture(nil, "BACKGROUND", nil, -1)
bg:SetPoint("TOPLEFT",     frame, "TOPLEFT",  0, -22)
bg:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
bg:SetColorTexture(0.07, 0.07, 0.07, 0.96)

-- Leaderboard section gets a slightly distinct shade
local lbBg = frame:CreateTexture(nil, "BACKGROUND", nil, -2)
lbBg:SetPoint("TOPLEFT",     frame, "TOPLEFT",  GAME_W, -22)
lbBg:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
lbBg:SetColorTexture(0.09, 0.09, 0.12, 0.96)

-- Vertical separator between game and leaderboard sections
local sep = frame:CreateTexture(nil, "ARTWORK")
sep:SetSize(1, FRAME_H - 28)
sep:SetPoint("TOPLEFT", frame, "TOPLEFT", GAME_W, -24)
sep:SetColorTexture(0.32, 0.32, 0.32, 1)

-- ── Resize grip ──────────────────────────────────────────────────────────────
-- The layout is fixed-pixel (not a reflowing grid), so "resizing" scales the
-- whole frame uniformly via SetScale rather than actually changing its
-- Width/Height. Drag distance maps to scale change; the chosen scale is
-- saved account-wide and restored on next open.

local MIN_SCALE, MAX_SCALE = 0.6, 1.3

local resizeGrip = CreateFrame("Button", nil, frame)
resizeGrip:SetSize(16, 16)
resizeGrip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 4)
resizeGrip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
resizeGrip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
resizeGrip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")

resizeGrip:SetScript("OnMouseDown", function(self)
    self.dragging = true
    self.startX = select(1, GetCursorPosition())
    self.startScale = frame:GetScale()
end)
resizeGrip:SetScript("OnMouseUp", function(self)
    self.dragging = false
    GuildWordleDB.settings.scale = frame:GetScale()
end)
resizeGrip:SetScript("OnUpdate", function(self)
    if not self.dragging then return end
    local x = select(1, GetCursorPosition())
    local dx = (x - self.startX) / UIParent:GetEffectiveScale()
    local newScale = self.startScale + dx / FRAME_W
    if newScale < MIN_SCALE then newScale = MIN_SCALE end
    if newScale > MAX_SCALE then newScale = MAX_SCALE end
    frame:SetScale(newScale)
end)

-- ── Game section ─────────────────────────────────────────────────────────────

-- Date label centred within game section
local dateLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
dateLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -26)
dateLabel:SetWidth(GAME_W)
dateLabel:SetJustifyH("CENTER")
dateLabel:SetTextColor(0.55, 0.55, 0.55)

-- Streak label — account-wide (see GW.RecordStreakResult), so this keeps
-- counting up regardless of which character plays each day.
local streakLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
streakLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -42)
streakLabel:SetWidth(GAME_W)
streakLabel:SetJustifyH("CENTER")

local function RefreshStreakLabel()
    local s = GW.CurrentStreak()
    if not s or (s.current == 0 and s.best == 0) then
        streakLabel:SetText("")
    elseif s.current > 0 then
        streakLabel:SetText(string.format("|cffE8B84B%d-day streak|r  (best %d)", s.current, s.best))
    else
        streakLabel:SetText(string.format("|cff888888Streak broken|r  (best %d)", s.best))
    end
end

-- Tile grid
local tiles = {}
for row = 1, 6 do
    tiles[row] = {}
    for col = 1, 5 do
        local x = GRID_X + (col-1) * CELL
        local y = GRID_Y - (row-1) * CELL
        tiles[row][col] = CreateTile(frame, x, y)
    end
end

-- Grid bottom y-coordinate (frame-local, negative = below top)
local GRID_BOTTOM_Y = GRID_Y - (6 * (TILE_SZ + 2) + 5 * TILE_GAP)

-- Status text centred within game section
local STATUS_Y = GRID_BOTTOM_Y - 14

local statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
statusText:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, STATUS_Y)
statusText:SetWidth(GAME_W)
statusText:SetJustifyH("CENTER")

-- Input row — TOPLEFT-anchored so right edge is predictable
-- Layout: [14px][~45 label][3gap][162 box][6gap][72 btn] = right edge 303 < 320 ✓
local ROW_Y = STATUS_Y - 36

local inputLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
inputLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, ROW_Y)
inputLabel:SetText("Guess:")
inputLabel:SetTextColor(0.8, 0.8, 0.8)

local inputBox = CreateFrame("EditBox", "GuildWordleInput", frame, "InputBoxTemplate")
inputBox:SetSize(162, 26)
inputBox:SetPoint("TOPLEFT", frame, "TOPLEFT", 62, ROW_Y - 3)
inputBox:SetMaxLetters(5)
inputBox:SetAutoFocus(false)

local submitBtn = CreateFrame("Button", nil, frame, "GameMenuButtonTemplate")
submitBtn:SetSize(72, 24)
submitBtn:SetPoint("TOPLEFT", frame, "TOPLEFT", 230, ROW_Y - 2)
submitBtn:SetText("Enter")

-- ── On-screen keyboard (letters used so far, color-coded) ─────────────────────
-- Sits directly under the input row now that sharing controls live in the
-- right column instead of stacking underneath this one.

local KB_ROWS = {"QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM"}
local KEY_W, KEY_H, KEY_GAP = 26, 26, 3
local KEY_STRIDE = KEY_H + KEY_GAP
local KB_Y = ROW_Y - 34

local keyTiles = {}
for rowIdx, letters in ipairs(KB_ROWS) do
    local n = #letters
    local rowWidth = n * KEY_W + (n - 1) * KEY_GAP
    local xStart = (GAME_W - rowWidth) / 2
    local y = KB_Y - (rowIdx - 1) * KEY_STRIDE
    for i = 1, n do
        local letter = letters:sub(i, i)
        local x = xStart + (i - 1) * (KEY_W + KEY_GAP)

        local key = CreateFrame("Frame", nil, frame)
        key:SetSize(KEY_W, KEY_H)
        key:SetPoint("TOPLEFT", frame, "TOPLEFT", x, y)

        -- Fixed border, always visible, so unused keys still show the
        -- keyboard's shape instead of looking like blank gaps once dimmed.
        key.border = key:CreateTexture(nil, "BACKGROUND")
        key.border:SetAllPoints()
        key.border:SetColorTexture(0.20, 0.20, 0.20, 1)

        key.bg = key:CreateTexture(nil, "BACKGROUND", nil, 1)
        key.bg:SetPoint("TOPLEFT", key, "TOPLEFT", 1, -1)
        key.bg:SetPoint("BOTTOMRIGHT", key, "BOTTOMRIGHT", -1, 1)

        key.text = key:CreateFontString(nil, "OVERLAY")
        key.text:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
        key.text:SetPoint("CENTER")
        key.text:SetText(letter)

        keyTiles[letter] = key
    end
end

-- Best state seen for each letter across all guesses so far (green beats
-- yellow beats grey, matching standard Wordle keyboard behavior).
local function RefreshKeyboard()
    local game = GW.CurrentGame()
    local best = {}
    for i, guess in ipairs(game.guesses) do
        local res = game.results[i]
        for col = 1, 5 do
            local letter, state = guess:sub(col, col), res[col]
            if not best[letter] or state > best[letter] then
                best[letter] = state
            end
        end
    end

    -- Unused letters are still-viable candidates, so they stay bright/normal
    -- (matches how NYT's own keyboard treats them). Green/yellow (present or
    -- correct) stay bright too — that's useful information. Only absent
    -- (guessed, confirmed not in the word) gets dimmed, since those letters
    -- are eliminated and shouldn't visually compete with ones still in play.
    for letter, key in pairs(keyTiles) do
        local state = best[letter]
        if state == 2 or state == 1 then
            local c = state == 2 and GW.TILE_COLORS.green or GW.TILE_COLORS.yellow
            key.bg:SetColorTexture(c.r, c.g, c.b, 1)
            key.text:SetTextColor(1, 1, 1)
        elseif state == 0 then
            local c = GW.TILE_COLORS.grey
            key.bg:SetColorTexture(c.r, c.g, c.b, 0.35)
            key.text:SetTextColor(0.45, 0.45, 0.45)
        else
            local c = GW.TILE_COLORS.filled
            key.bg:SetColorTexture(c.r, c.g, c.b, 1)
            key.text:SetTextColor(1, 1, 1)
        end
    end
end

-- ── Leaderboard panel (top half of right column, scrollable, tabbed) ─────────
-- Three tabs sharing one row-pool/scroll-viewport: today's results, the
-- guild's active streaks, and the guild's all-time-best streaks. Only
-- VISIBLE_ROWS are shown at once — a mouse-wheel-scrollable viewport rather
-- than reserving fixed space for a large row count, so the window doesn't
-- grow with guild size. ROW_POOL_SIZE widgets are pre-created and recycled;
-- entries beyond that soft cap simply don't render.

local LB_PAD = GAME_W + 10   -- content starts 10px past divider

-- Tab row
local TAB_Y = -26
local TAB_H = 20
local TAB_DEFS = {
    {key = "results", label = "Today"},
    {key = "current", label = "Streak"},
    {key = "longest", label = "Best"},
}

local activeTab = "results"
local tabButtons = {}
local UpdateLBPanel  -- forward-declared: tab buttons below need to call it on click

local function RefreshTabVisuals()
    for _, def in ipairs(TAB_DEFS) do
        local btn = tabButtons[def.key]
        if def.key == activeTab then
            btn.bg:SetColorTexture(0.20, 0.20, 0.26, 1)
            btn.text:SetTextColor(1, 1, 1)
        else
            btn.bg:SetColorTexture(0, 0, 0, 0)
            btn.text:SetTextColor(0.55, 0.55, 0.55)
        end
    end
end

do
    local tabW = math.floor((LB_W - 16) / #TAB_DEFS)
    for i, def in ipairs(TAB_DEFS) do
        local btn = CreateFrame("Button", nil, frame)
        btn:SetSize(tabW - 2, TAB_H)
        btn:SetPoint("TOPLEFT", frame, "TOPLEFT", LB_PAD + (i-1) * tabW, TAB_Y)
        btn.bg = btn:CreateTexture(nil, "BACKGROUND")
        btn.bg:SetAllPoints()
        btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        btn.text:SetPoint("CENTER")
        btn.text:SetText(def.label)
        btn:SetScript("OnClick", function()
            activeTab = def.key
            RefreshTabVisuals()
            UpdateLBPanel()
        end)
        tabButtons[def.key] = btn
    end
end

local lbTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
lbTitle:SetPoint("TOPLEFT", frame, "TOPLEFT", LB_PAD, TAB_Y - TAB_H - 6)

local lbSubtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
lbSubtitle:SetPoint("TOPLEFT", frame, "TOPLEFT", LB_PAD, TAB_Y - TAB_H - 24)
lbSubtitle:SetWidth(LB_W - 12)
lbSubtitle:SetTextColor(0.5, 0.5, 0.5)

local VISIBLE_ROWS   = 14
local LB_ROW_H       = 20
local LB_ROW_Y0      = TAB_Y - TAB_H - 42   -- y of the scroll viewport's top edge
local ROW_POOL_SIZE  = 30
local SCROLLBAR_RESERVE = 24 -- room for UIPanelScrollFrameTemplate's up/down buttons + track
local LB_SCROLL_W    = (LB_W - 12) - SCROLLBAR_RESERVE

-- Tile colors for the results-tab hover tooltip (0=grey, 1=yellow, 2=green);
-- reuses the same filled square glyph for all three since color does the
-- differentiating here (unlike the plain-text glyphs used in chat messages,
-- which can't rely on color since chat channels strip |cff codes).
local TOOLTIP_TILE_HEX = {[0] = "888888", [1] = "b59e3d", [2] = "538d4e"}

local function AddPatternToTooltip(pattern)
    for _, row in ipairs(GW.UnpackResults(pattern)) do
        local line = ""
        for _, v in ipairs(row) do
            line = line .. "|cff" .. TOOLTIP_TILE_HEX[v] .. GW.SYM_GREEN .. "|r "
        end
        GameTooltip:AddLine(line)
    end
end

local lbScroll = CreateFrame("ScrollFrame", "GuildWordleLBScroll", frame, "UIPanelScrollFrameTemplate")
lbScroll:SetPoint("TOPLEFT", frame, "TOPLEFT", LB_PAD, LB_ROW_Y0)
lbScroll:SetSize(LB_SCROLL_W, VISIBLE_ROWS * LB_ROW_H)
lbScroll:EnableMouseWheel(true)

local lbScrollChild = CreateFrame("Frame", nil, lbScroll)
lbScrollChild:SetSize(LB_SCROLL_W, VISIBLE_ROWS * LB_ROW_H)
lbScroll:SetScrollChild(lbScrollChild)

lbScroll:SetScript("OnMouseWheel", function(self, delta)
    local newOffset = self:GetVerticalScroll() - delta * LB_ROW_H
    local maxOffset = math.max(0, lbScrollChild:GetHeight() - self:GetHeight())
    if newOffset < 0 then newOffset = 0 end
    if newOffset > maxOffset then newOffset = maxOffset end
    self:SetVerticalScroll(newOffset)
end)

local lbRows, lbHovers = {}, {}
for i = 1, ROW_POOL_SIZE do
    local row = lbScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row:SetPoint("TOPLEFT", lbScrollChild, "TOPLEFT", 0, -(i-1)*LB_ROW_H)
    row:SetWidth(LB_SCROLL_W)
    row:SetJustifyH("LEFT")
    row:SetText("")
    lbRows[i] = row

    local hover = CreateFrame("Frame", nil, lbScrollChild)
    hover:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    hover:SetSize(LB_SCROLL_W, LB_ROW_H)
    hover:EnableMouse(true)
    -- EnableMouse is needed for the tooltip, but that also swallows drag
    -- gestures before they reach the parent frame — forward them explicitly
    -- so the window stays draggable even when starting on a leaderboard row.
    hover:RegisterForDrag("LeftButton")
    hover:SetScript("OnDragStart", function() frame:StartMoving() end)
    hover:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
    hover:SetScript("OnEnter", function(self)
        local e = self.entryData
        if not e then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(e.name, 1, 0.82, 0)
        if e.pattern then
            GameTooltip:AddLine(e.solved and (e.guesses .. "/6 · Solved") or "X/6 · Not solved", 1, 1, 1)
            AddPatternToTooltip(e.pattern)
        elseif e.streakValue then
            GameTooltip:AddLine(e.streakValue .. "-day streak", 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    hover:SetScript("OnLeave", function() GameTooltip:Hide() end)
    lbHovers[i] = hover
end

-- Shared by all three tabs: fills the row pool from a sorted {name=, ...}
-- array, clears the rest, and sizes the scroll child to match.
local function RenderRows(sorted, rowTextFn, entryFn)
    for i = 1, ROW_POOL_SIZE do
        local e = sorted[i]
        if e then
            lbRows[i]:SetText(rowTextFn(i, e))
            lbHovers[i].entryData = entryFn(e)
        else
            lbRows[i]:SetText("")
            lbHovers[i].entryData = nil
        end
    end
    lbScrollChild:SetHeight(math.max(VISIBLE_ROWS, math.min(#sorted, ROW_POOL_SIZE)) * LB_ROW_H)
end

local function TruncName(name)
    return #name > 9 and (name:sub(1,8) .. ".") or name
end

local function RenderResultsTab()
    local today = date("%Y%m%d")
    local guildName = GetGuildInfo("player")
    lbTitle:SetText(guildName and ("|cffFFD700" .. guildName .. " Today|r") or "|cffFFD700No Guild|r")

    local byGuild = GuildWordleDB.leaderboard and GuildWordleDB.leaderboard[GW.CurrentGuildKey()]
    local lb = byGuild and byGuild[today]

    if not lb or not next(lb) then
        lbSubtitle:SetText("No results yet")
        RenderRows({}, function() return "" end, function() return nil end)
        return
    end

    local sorted = {}
    for name, data in pairs(lb) do
        sorted[#sorted+1] = {name=name, guesses=data.guesses, solved=data.solved, pattern=data.pattern}
    end
    table.sort(sorted, function(a, b)
        if a.solved ~= b.solved then return a.solved end
        if a.solved then return a.guesses < b.guesses end
        return a.name < b.name
    end)

    lbSubtitle:SetText(#sorted .. " result" .. (#sorted ~= 1 and "s" or "") .. " today")
    RenderRows(sorted,
        function(i, e)
            local score = e.solved and (e.guesses .. "/6") or "X/6"
            local color = e.solved and "|cff538d4e" or "|cffcc4444"
            return string.format("|cff888888%d.|r %-9s %s%s|r", i, TruncName(e.name), color, score)
        end,
        function(e) return e end)
end

-- mode: "current" (active streaks only, i.e. still-frozen ones excluded) or
-- "longest" (all-time best, regardless of whether it's still active).
local function RenderStreakTab(mode)
    GW.RecordOwnStreakEntry()
    local guildName = GetGuildInfo("player")
    lbTitle:SetText(guildName and ("|cffFFD700" .. guildName .. " Streaks|r") or "|cffFFD700No Guild|r")

    local board = GuildWordleDB.streakBoard and GuildWordleDB.streakBoard[GW.CurrentGuildKey()]
    local sorted = {}
    if board then
        for nick, d in pairs(board) do
            if mode == "current" and d.current and d.current > 0 then
                sorted[#sorted+1] = {name = nick, value = d.current}
            elseif mode == "longest" and d.best and d.best > 0 then
                sorted[#sorted+1] = {name = nick, value = d.best}
            end
        end
    end
    table.sort(sorted, function(a, b)
        if a.value ~= b.value then return a.value > b.value end
        return a.name < b.name
    end)

    if mode == "current" then
        lbSubtitle:SetText(#sorted .. " active streak" .. (#sorted ~= 1 and "s" or ""))
    else
        lbSubtitle:SetText("All-time best")
    end

    RenderRows(sorted,
        function(i, e)
            return string.format("|cff888888%d.|r %-9s |cffE8B84B%d-day|r", i, TruncName(e.name), e.value)
        end,
        function(e) return {name = e.name, streakValue = e.value} end)
end

UpdateLBPanel = function()
    if not GuildWordleDB then return end
    if activeTab == "results" then
        RenderResultsTab()
    else
        RenderStreakTab(activeTab)
    end
end

RefreshTabVisuals()
GW.OnLeaderboardUpdate = UpdateLBPanel
GW.OnStreakBoardUpdate = UpdateLBPanel

-- ── Announcements panel (bottom half of right column) ─────────────────────────
-- Auto-share checkboxes + manual "Share results now" button live here rather
-- than in the game column, so sharing controls don't compete with the game
-- itself for vertical space.

local ANNOUNCE_Y0 = LB_ROW_Y0 - VISIBLE_ROWS * LB_ROW_H - 16

-- Divider between the leaderboard and announcements panels, mirroring the
-- vertical separator between the game and leaderboard columns.
local rightDivider = frame:CreateTexture(nil, "ARTWORK")
rightDivider:SetSize(LB_W - 16, 1)
rightDivider:SetPoint("TOPLEFT", frame, "TOPLEFT", LB_PAD - 6, ANNOUNCE_Y0 + 8)
rightDivider:SetColorTexture(0.32, 0.32, 0.32, 1)

local announceLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
announceLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", LB_PAD, ANNOUNCE_Y0)
announceLabel:SetText("|cffFFD700Announcements|r")

-- Nickname row — shown on the guild streak leaderboard since streaks are
-- account-wide but the character name changes per alt. Mirrors /wordle nick
-- <name> (both paths funnel through GW.SetNickname, so either stays in sync
-- with the other).
local NICK_ROW_H = 24
local NICK_Y = ANNOUNCE_Y0 - 20

local nickLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
nickLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", LB_PAD, NICK_Y)
nickLabel:SetText("Nick:")
nickLabel:SetTextColor(0.8, 0.8, 0.8)

local nickBox = CreateFrame("EditBox", "GuildWordleNickInput", frame, "InputBoxTemplate")
nickBox:SetPoint("LEFT", nickLabel, "RIGHT", 6, -1)
nickBox:SetSize(LB_W - 12 - (nickLabel:GetStringWidth() + 6) - 6, 20)
nickBox:SetMaxLetters(16)
nickBox:SetAutoFocus(false)
nickBox:SetScript("OnEnterPressed", function(self)
    GW.SetNickname(self:GetText())
    self:ClearFocus()
end)
nickBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
nickBox:SetScript("OnEditFocusLost", function(self)
    -- Also save on click-away, not just Enter, so a typed change isn't lost
    -- if the player just clicks elsewhere. An emptied box is left alone
    -- (reverts to the existing nickname on next refresh) rather than clearing
    -- the nickname outright.
    local typed = strtrim(self:GetText())
    if typed ~= "" and typed ~= (GuildWordleDB.settings.nickname or "") then
        GW.SetNickname(typed)
    end
end)

local function RefreshNickBox()
    if nickBox:HasFocus() then return end
    nickBox:SetText(GuildWordleDB.settings.nickname or "")
end
GW.OnNicknameChanged = RefreshNickBox

local SHARE_CHANNELS = {"GUILD", "PARTY", "RAID"}
local SHARE_LABELS = {GUILD = "Guild", PARTY = "Party", RAID = "Raid"}
local CHECK_ROW_H = 24

local autoShareChecks = {}
for i, chan in ipairs(SHARE_CHANNELS) do
    local y = ANNOUNCE_Y0 - 20 - NICK_ROW_H - (i-1) * CHECK_ROW_H

    local check = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    check:SetSize(20, 20)
    check:SetPoint("TOPLEFT", frame, "TOPLEFT", LB_PAD, y)
    check:SetScript("OnClick", function(self)
        GuildWordleDB.settings.autoShare[chan] = self:GetChecked() and true or false
    end)

    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("LEFT", check, "RIGHT", 2, 1)
    label:SetText(SHARE_LABELS[chan])

    autoShareChecks[chan] = check
end

local function RefreshAutoShareChecks()
    local autoShare = GuildWordleDB.settings and GuildWordleDB.settings.autoShare
    if not autoShare then return end
    for _, chan in ipairs(SHARE_CHANNELS) do
        autoShareChecks[chan]:SetChecked(autoShare[chan] and true or false)
    end
end

local SHARE_NOW_Y = ANNOUNCE_Y0 - 20 - NICK_ROW_H - (#SHARE_CHANNELS * CHECK_ROW_H) - 10

-- Always visible (not just once the game ends): shows live progress while
-- playing, and becomes the actual share action once the game is done.
local shareNowBtn = CreateFrame("Button", nil, frame, "GameMenuButtonTemplate")
shareNowBtn:SetSize(LB_W - 24, 22)
shareNowBtn:SetPoint("TOPLEFT", frame, "TOPLEFT", LB_PAD, SHARE_NOW_Y)
shareNowBtn:SetScript("OnClick", function() GW.ShareNow() end)

local function RefreshShareNowButton()
    local game = GW.CurrentGame()
    if game.state == "playing" then
        shareNowBtn:SetText(string.format("Wordle in progress (%d/6)", #game.guesses))
        shareNowBtn:Disable()
    else
        shareNowBtn:SetText("Share results now")
        shareNowBtn:Enable()
    end
end

-- ── Grid helpers ─────────────────────────────────────────────────────────────

local STATE_MAP = {[0]="grey", [1]="yellow", [2]="green"}

local function RefreshGrid()
    local game = GW.CurrentGame()
    for row = 1, 6 do
        for col = 1, 5 do SetTileState(tiles[row][col], "", "empty") end
    end
    for i, guess in ipairs(game.guesses) do
        local res = game.results[i]
        for col = 1, 5 do
            SetTileState(tiles[i][col], guess:sub(col,col), STATE_MAP[res[col]])
        end
    end
end

local function UpdatePreview(text)
    local game = GW.CurrentGame()
    if game.state ~= "playing" then return end
    local row = #game.guesses + 1
    if row > 6 then return end
    text = text:upper()
    for col = 1, 5 do
        local ch = text:sub(col,col)
        SetTileState(tiles[row][col], ch ~= "" and ch or "", ch ~= "" and "filled" or "empty")
    end
end

-- ── Game-state display ────────────────────────────────────────────────────────

local WIN_MSGS = {"Genius!", "Magnificent!", "Impressive!", "Splendid!", "Great!", "Phew!"}

local function HideInputRow()
    inputBox:Hide(); inputBox:ClearFocus()
    submitBtn:Hide(); inputLabel:Hide()
end

local function ShowGameResult(won)
    HideInputRow()
    local game = GW.CurrentGame()
    if won then
        local msg = WIN_MSGS[#game.guesses] or "Got it!"
        statusText:SetText("|cff538d4e" .. msg .. "|r")
    else
        statusText:SetText("|cffcc4444The word was: |r|cffFFFFFF" .. GW.todaysWord .. "|r")
    end
end

local function RefreshUI()
    frame:SetScale((GuildWordleDB.settings and GuildWordleDB.settings.scale) or 1)

    RefreshGrid()
    RefreshKeyboard()
    UpdateLBPanel()
    RefreshAutoShareChecks()
    RefreshShareNowButton()
    RefreshStreakLabel()
    RefreshNickBox()

    local game = GW.CurrentGame()
    dateLabel:SetText("Puzzle · " .. date("%b %d, %Y"))

    if game.state == "playing" then
        inputBox:Show(); submitBtn:Show(); inputLabel:Show()
        inputBox:SetText("")
        inputBox:SetFocus()
        local rem = 6 - #game.guesses
        statusText:SetText("|cff888888" .. rem .. " guess" .. (rem ~= 1 and "es" or "") .. " remaining|r")
    else
        ShowGameResult(game.state == "won")
    end
end

-- ── Submit ────────────────────────────────────────────────────────────────────

local function DoSubmit()
    local text = strtrim(inputBox:GetText())
    if #text == 0 then return end

    local ok, result, done, won = GW.SubmitGuess(text)
    if not ok then
        local msgs = {
            already_done = "|cff888888Already played today!|r",
            wrong_length = "|cffcc4444Word must be 5 letters.|r",
            not_a_word   = "|cffcc4444Not in word list!|r",
        }
        statusText:SetText(msgs[result] or "|cffcc4444Invalid guess.|r")
        return
    end

    local game   = GW.CurrentGame()
    local rowIdx = #game.guesses
    local res    = game.results[rowIdx]
    local guess  = game.guesses[rowIdx]
    for col = 1, 5 do
        SetTileState(tiles[rowIdx][col], guess:sub(col,col), STATE_MAP[res[col]])
    end

    inputBox:SetText("")
    RefreshKeyboard()
    UpdateLBPanel()
    RefreshShareNowButton()
    RefreshStreakLabel()

    if done then
        ShowGameResult(won)
    else
        local rem = 6 - rowIdx
        statusText:SetText("|cff888888" .. rem .. " guess" .. (rem ~= 1 and "es" or "") .. " remaining|r")
        inputBox:SetFocus()
    end
end

submitBtn:SetScript("OnClick",        DoSubmit)
inputBox:SetScript("OnEnterPressed",  DoSubmit)
inputBox:SetScript("OnTextChanged",   function(self) UpdatePreview(self:GetText()) end)
inputBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

frame:SetScript("OnShow", RefreshUI)
