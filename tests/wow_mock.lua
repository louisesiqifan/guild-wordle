-- Minimal mock of the WoW globals GuildWordle.lua touches. Loaded once,
-- before GuildWordle.lua, into the SAME global environment (there is no
-- module system here — this mirrors how a real WoW addon executes: straight
-- top-level Lua against a shared _G). Tests reset MockState fields between
-- cases rather than reloading files, matching how the real addon resets via
-- a fresh InitDB() call rather than a fresh Lua load.
--
-- Run under LuaJIT specifically (implements Lua 5.1 semantics, matching
-- WoW's actual embedded interpreter) -- see BEHAVIOR_SPEC.md's "Open
-- questions" section for why this matters; Lua 5.4/5.5 do NOT reliably catch
-- the same bugs (verified: the malformed-pattern crash this addon shipped
-- with only reproduces under 5.1/LuaJIT, not 5.5).

local MockState = {
    unitName    = "Testchar",
    realmName   = "Testrealm",
    guildName   = nil,      -- nil = not in a guild
    inGroup     = false,
    inRaid      = false,
    now         = os.time(),  -- epoch seconds; controls date()/time()
    printed     = {},         -- every print() call, args joined with \t
    sentAddon   = {},         -- {prefix, text, channel}
    sentChat    = {},         -- {msg, channel}
    createdFrames = {},       -- every CreateFrame() result, in creation order
    lastTicker  = nil,        -- most recent C_Timer.NewTicker callback, for manual firing
    errorHandlerCalls = {},   -- args seen by whatever seterrorhandler installs as "previous"
}

-- Resets everything a test could have mutated, back to fresh defaults.
-- Does NOT touch GuildWordleDB (tests do that explicitly, since some tests
-- deliberately want to start from a pre-seeded/messy state).
function MockState.reset()
    MockState.unitName  = "Testchar"
    MockState.realmName = "Testrealm"
    MockState.guildName = nil
    MockState.inGroup   = false
    MockState.inRaid    = false
    MockState.now       = os.time()
    MockState.printed   = {}
    MockState.sentAddon = {}
    MockState.sentChat  = {}
    MockState.createdFrames = {}
    MockState.lastTicker = nil
    MockState.errorHandlerCalls = {}
end

-- ── Unit/character/guild identity ───────────────────────────────────────────

function _G.UnitName(unit) return MockState.unitName end
function _G.GetRealmName() return MockState.realmName end
function _G.GetGuildInfo(unit) return MockState.guildName end
function _G.IsInGuild() return MockState.guildName ~= nil end
function _G.IsInGroup() return MockState.inGroup end
function _G.IsInRaid() return MockState.inRaid end

-- ── Date/time (controllable "now" instead of the real wall clock) ──────────

function _G.date(fmt, t)
    return os.date(fmt, t or MockState.now)
end

function _G.time(t)
    if t ~= nil then return os.time(t) end
    return MockState.now
end

-- ── strtrim (WoW global; not in standard Lua) ───────────────────────────────

function _G.strtrim(s)
    return (s:match("^%s*(.-)%s*$"))
end

-- ── print (captured, not echoed, so test output stays clean) ───────────────

function _G.print(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do
        parts[i] = tostring(select(i, ...))
    end
    table.insert(MockState.printed, table.concat(parts, "\t"))
end

-- ── Addon messages / chat ───────────────────────────────────────────────────

_G.C_ChatInfo = {
    SendAddonMessage = function(prefix, text, channel)
        table.insert(MockState.sentAddon, {prefix = prefix, text = text, channel = channel})
    end,
    RegisterAddonMessagePrefix = function(prefix) end,
}
_G.SendAddonMessage = _G.C_ChatInfo.SendAddonMessage
_G.RegisterAddonMessagePrefix = function(prefix) end

function _G.SendChatMessage(msg, channel)
    table.insert(MockState.sentChat, {msg = msg, channel = channel})
end

-- ── Timers ───────────────────────────────────────────────────────────────────
-- After() fires synchronously (there's no real async in a test harness, and
-- tests want deterministic ordering). NewTicker() does NOT fire on its own —
-- tests that care about "the periodic ticker fired" call MockState.lastTicker()
-- manually, or just call the underlying GW.Broadcast* functions directly,
-- which is simpler and doesn't depend on ticker plumbing at all.

_G.C_Timer = {
    After = function(delay, fn) fn() end,
    NewTicker = function(interval, fn)
        MockState.lastTicker = fn
        return {Cancel = function() end}
    end,
}

-- ── Frames ───────────────────────────────────────────────────────────────────
-- Generic enough to survive any CreateFrame(...) call anywhere in
-- GuildWordle.lua without erroring: real implementations for
-- RegisterEvent/SetScript/GetScript (since the event-dispatch frame actually
-- needs these to work, so tests can simulate ADDON_LOADED/CHAT_MSG_ADDON by
-- fetching the frame and invoking its stored OnEvent handler), and a
-- catch-all no-op for everything else (SetSize, SetPoint, Hide, Show, ...).

-- A single object that absorbs anything done to it: indexable to any depth
-- (`x.Foo.Bar`), callable both as a function and as a method (`x:SetText(n)`),
-- and truthy. Returning a bare function instead would break real addon
-- patterns like `if frame.TitleText then frame.TitleText:SetText(...) end` --
-- the guard passes (functions are truthy) and then indexing it errors, which
-- is a mock artifact rather than a genuine finding.
-- __call returns the stub itself so factory-style methods keep working:
-- `local tex = frame:CreateTexture(...)` must yield something usable rather
-- than nil, or the very next `tex:SetPoint(...)` blows up.
-- Arithmetic metamethods let measurement-style calls (GetStringWidth,
-- GetHeight, ...) flow into layout math without erroring. The resulting
-- numbers are meaningless, so nothing here can meaningfully test *layout* --
-- but it does let GuildWordle_UI.lua load, which makes its non-layout logic
-- (sorting, nickname resolution, tooltip payloads) reachable from tests.
local function stubZero() return 0 end
local universalStub = setmetatable({}, {
    __index = function(t) return t end,
    __call  = function(t) return t end,
    __add = stubZero, __sub = stubZero, __mul = stubZero,
    __div = stubZero, __unm = stubZero, __mod = stubZero,
    __lt  = function() return false end,
    __le  = function() return false end,
    __tostring = function() return "<stub>" end,
})

local function NewMockFrame()
    local frame = {}
    local scripts = {}
    local events = {}

    function frame:RegisterEvent(e) events[e] = true end
    function frame:UnregisterEvent(e) events[e] = nil end
    function frame:IsEventRegistered(e) return events[e] or false end
    function frame:SetScript(script, fn) scripts[script] = fn end
    function frame:GetScript(script) return scripts[script] end
    function frame:Show() self._shown = true end
    function frame:Hide()
        self._shown = false
        local onHide = scripts["OnHide"]
        if onHide then onHide(self) end
    end
    function frame:IsShown() return self._shown == true end

    return setmetatable(frame, {__index = function() return universalStub end})
end

function _G.CreateFrame(frameType, name, parent, template)
    local f = NewMockFrame()
    table.insert(MockState.createdFrames, f)
    return f
end

-- Root frame everything anchors to. Only referenced by files that build UI
-- (GuildWordle_UI.lua, GuildWordle_Dev.lua).
_G.UIParent = NewMockFrame()

-- ── Slash commands ───────────────────────────────────────────────────────────
-- GuildWordle.lua registers into these at load time. Tests drive the command
-- handler through GW._test.HandleSlashCommand (or SlashCmdList.GUILDWORDLE
-- for the pcall-wrapped outer layer) rather than through any real chat input.

_G.SlashCmdList = {}

-- ── Error handler ────────────────────────────────────────────────────────────
-- Starts as a simple recorder (not WoW's real default handler, which isn't
-- meaningful in a headless test) so tests can assert the addon's own handler
-- always calls through to "whatever was previously installed."

local defaultHandler = function(msg)
    table.insert(MockState.errorHandlerCalls, msg)
end
local currentHandler = defaultHandler

function _G.geterrorhandler() return currentHandler end
function _G.seterrorhandler(fn) currentHandler = fn end

-- Test-only accessor, since geterrorhandler() after GuildWordle.lua loads
-- returns GuildWordle's OWN wrapper, not this original recorder.
MockState.defaultErrorHandler = defaultHandler

return MockState
