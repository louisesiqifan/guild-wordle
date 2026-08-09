local GW = GuildWordle

local TILE_SZ  = 52
local TILE_GAP = 6
local CELL     = TILE_SZ + 2 + TILE_GAP  -- 60px stride

local GRID_W   = 5 * (TILE_SZ + 2) + 4 * TILE_GAP  -- 294px
local GAME_W   = GRID_W + 26                         -- 320px  (game section)
local LB_W     = 170                                 -- leaderboard section width
local FRAME_W  = GAME_W + LB_W                       -- 490px total
local FRAME_H  = 530

local GRID_X   = 13   -- (GAME_W - GRID_W) / 2
local GRID_Y   = -50

-- ── Tile factory ───────────────────────────────────────────────────────────────

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

-- ── Main frame ───────────────────────────────────────────────────────────────

local frame = CreateFrame("Frame", "GuildWordleFrame", UIParent, "BasicFrameTemplate")
frame:SetSize(FRAME_W, FRAME_H)
frame:SetPoint("CENTER")
frame:Hide()
frame:SetMovable(true)
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

-- ── Game section ─────────────────────────────────────────────────────────────

-- Date label centred within game section
local dateLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
dateLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -26)
dateLabel:SetWidth(GAME_W)
dateLabel:SetJustifyH("CENTER")
dateLabel:SetTextColor(0.55, 0.55, 0.55)

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

-- ── Auto-share checkboxes (persistent setting, always visible) ───────────
-- Unlike a per-completion "Share" button, these reflect a standing preference:
-- whichever channels are checked get an automatic chat post the moment the
-- game is completed (see GW.AutoShareResult in GuildWordle.lua). State is
-- read/written straight to GuildWordleDB.settings.autoShare.

local CHECK_Y = ROW_Y - 34
local SHARE_CHANNELS = {"GUILD", "PARTY", "RAID"}
local SHARE_LABELS = {GUILD = "Guild", PARTY = "Party", RAID = "Raid"}

local autoShareLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
autoShareLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, CHECK_Y)
autoShareLabel:SetText("Auto-share:")
autoShareLabel:SetTextColor(0.8, 0.8, 0.8)

local autoShareChecks = {}
do
    local x = 14 + autoShareLabel:GetStringWidth() + 10
    for _, chan in ipairs(SHARE_CHANNELS) do
        local check = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
        check:SetSize(22, 22)
        check:SetPoint("TOPLEFT", frame, "TOPLEFT", x, CHECK_Y + 4)
        check:SetScript("OnClick", function(self)
            GuildWordleDB.settings.autoShare[chan] = self:GetChecked() and true or false
        end)
        x = x + 22

        local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("LEFT", check, "RIGHT", 2, 1)
        label:SetText(SHARE_LABELS[chan])
        x = x + label:GetStringWidth() + 10

        autoShareChecks[chan] = check
    end
end

local function RefreshAutoShareChecks()
    local autoShare = GuildWordleDB.settings and GuildWordleDB.settings.autoShare
    if not autoShare then return end
    for _, chan in ipairs(SHARE_CHANNELS) do
        autoShareChecks[chan]:SetChecked(autoShare[chan] and true or false)
    end
end

-- ── Leaderboard panel ───────────────────────────────────────────────────────────

local LB_PAD = GAME_W + 10   -- content starts 10px past divider

local lbTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
lbTitle:SetPoint("TOPLEFT", frame, "TOPLEFT", LB_PAD, -32)
lbTitle:SetText("|cffFFD700Guild Today|r")

local lbSubtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
lbSubtitle:SetPoint("TOPLEFT", frame, "TOPLEFT", LB_PAD, -50)
lbSubtitle:SetWidth(LB_W - 12)
lbSubtitle:SetTextColor(0.5, 0.5, 0.5)

local MAX_LB_ROWS = 16
local LB_ROW_H   = 20
local LB_ROW_Y0  = -68   -- y of first entry

-- Tile colors for the hover tooltip (0=grey, 1=yellow, 2=green); reuses the
-- same filled square glyph for all three since color does the differentiating
-- here (unlike the plain-text glyphs used in chat messages, which can't rely
-- on color since chat channels strip |cff codes).
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

local lbRows, lbHovers = {}, {}
for i = 1, MAX_LB_ROWS do
    local row = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row:SetPoint("TOPLEFT", frame, "TOPLEFT", LB_PAD, LB_ROW_Y0 - (i-1)*LB_ROW_H)
    row:SetWidth(LB_W - 12)
    row:SetJustifyH("LEFT")
    row:SetText("")
    lbRows[i] = row

    local hover = CreateFrame("Frame", nil, frame)
    hover:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    hover:SetSize(LB_W - 12, LB_ROW_H)
    hover:EnableMouse(true)
    hover:SetScript("OnEnter", function(self)
        local e = self.entryData
        if not e then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(e.name, 1, 0.82, 0)
        GameTooltip:AddLine(e.solved and (e.guesses .. "/6 · Solved") or "X/6 · Not solved", 1, 1, 1)
        AddPatternToTooltip(e.pattern)
        GameTooltip:Show()
    end)
    hover:SetScript("OnLeave", function() GameTooltip:Hide() end)
    lbHovers[i] = hover
end

local function UpdateLBPanel()
    if not GuildWordleDB then return end
    local today = date("%Y%m%d")
    local lb = GuildWordleDB.leaderboard and GuildWordleDB.leaderboard[today]

    if not lb or not next(lb) then
        lbSubtitle:SetText("No results yet")
        for i, r in ipairs(lbRows) do
            r:SetText("")
            lbHovers[i].entryData = nil
        end
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

    for i = 1, MAX_LB_ROWS do
        local e = sorted[i]
        if e then
            local score = e.solved and (e.guesses .. "/6") or "X/6"
            local color = e.solved and "|cff538d4e" or "|cffcc4444"
            local name  = #e.name > 9 and (e.name:sub(1,8) .. ".") or e.name
            lbRows[i]:SetText(string.format("|cff888888%d.|r %-9s %s%s|r", i, name, color, score))
            lbHovers[i].entryData = e
        else
            lbRows[i]:SetText("")
            lbHovers[i].entryData = nil
        end
    end
end

GW.OnLeaderboardUpdate = UpdateLBPanel

-- ── Grid helpers ────────────────────────────────────────────────────────────

local STATE_MAP = {[0]="grey", [1]="yellow", [2]="green"}

local function RefreshGrid()
    local game = GuildWordleDB.game
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
    local game = GuildWordleDB.game
    if game.state ~= "playing" then return end
    local row = #game.guesses + 1
    if row > 6 then return end
    text = text:upper()
    for col = 1, 5 do
        local ch = text:sub(col,col)
        SetTileState(tiles[row][col], ch ~= "" and ch or "", ch ~= "" and "filled" or "empty")
    end
end

-- ── Game-state display ────────────────────────────────────────────────────

local WIN_MSGS = {"Genius!", "Magnificent!", "Impressive!", "Splendid!", "Great!", "Phew!"}

local function HideInputRow()
    inputBox:Hide(); inputBox:ClearFocus()
    submitBtn:Hide(); inputLabel:Hide()
end

local function ShowGameResult(won)
    HideInputRow()
    local game = GuildWordleDB.game
    if won then
        local msg = WIN_MSGS[#game.guesses] or "Got it!"
        statusText:SetText("|cff538d4e" .. msg .. "|r")
    else
        statusText:SetText("|cffcc4444The word was: |r|cffFFFFFF" .. GW.todaysWord .. "|r")
    end
end

local function RefreshUI()
    RefreshGrid()
    UpdateLBPanel()
    RefreshAutoShareChecks()

    local game = GuildWordleDB.game
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

-- ── Submit ──────────────────────────────────────────────────────────────

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

    local rowIdx = #GuildWordleDB.game.guesses
    local res    = GuildWordleDB.game.results[rowIdx]
    local guess  = GuildWordleDB.game.guesses[rowIdx]
    for col = 1, 5 do
        SetTileState(tiles[rowIdx][col], guess:sub(col,col), STATE_MAP[res[col]])
    end

    inputBox:SetText("")
    UpdateLBPanel()

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
