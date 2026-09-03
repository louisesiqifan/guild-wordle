-- Loads the WoW API mock, then the real addon files, into this process's
-- global environment -- mirrors how a real WoW client loads addon files:
-- straight top-level execution against a shared _G, no module system.
-- Cached via require()'s normal semantics, so however many test files
-- require("harness"), the addon files only actually execute once per
-- process (important: re-running GuildWordle.lua's top-level
-- seterrorhandler() call would chain a new wrapper around the previous
-- one every time, which is exactly the kind of thing tests should not have
-- to think about).
--
-- Must be run with the current working directory set to tests/ (both
-- require()'s default package.path and the dofile() calls below are
-- CWD-relative, not relative to this file's own location -- a plain Lua
-- gotcha, not a WoW-specific one).

local Mock = require("wow_mock")

-- words.lua defines GuildWordle_Answers / GuildWordle_ValidWords as plain
-- globals; loaded for real (not faked) so word-selection/guess-validation
-- tests exercise the actual shipped word list, not a stand-in.
dofile("../words.lua")

dofile("../GuildWordle.lua")

local GW = _G.GuildWordle
assert(GW and GW._test, "GuildWordle.lua did not load correctly, or GW._test hooks are missing")

-- The addon's event-dispatch frame, captured now because it's created once
-- at load time and Mock.reset() clears the createdFrames list -- tests that
-- want to simulate ADDON_LOADED / CHAT_MSG_ADDON need a stable handle to it.
local eventFrame
for _, f in ipairs(Mock.createdFrames) do
    if f.GetScript and f:GetScript("OnEvent") and f:IsEventRegistered("CHAT_MSG_ADDON") then
        eventFrame = f
    end
end
assert(eventFrame, "could not find GuildWordle's event frame in the mock's created-frame list")

local H = {
    Mock       = Mock,
    GW         = GW,
    eventFrame = eventFrame,
}

-- Fires an event at the addon exactly as the WoW client would.
function H.fireEvent(event, ...)
    return eventFrame:GetScript("OnEvent")(eventFrame, event, ...)
end

-- Resets to a fresh, freshly-InitDB()'d state, the same way a real client
-- starts a session (fresh SavedVariables + ADDON_LOADED). Most tests should
-- call this first, before touching GuildWordleDB or the mock's identity
-- fields.
function H.freshDB()
    Mock.reset()
    _G.GuildWordleDB = nil
    GW._test.InitDB()
end

-- Sets the mocked "now" to a specific calendar day (noon, to stay well clear
-- of any timezone-related day-boundary edge cases in os.time()).
function H.setDate(year, month, day)
    Mock.now = os.time({year = year, month = month, day = day, hour = 12})
end

-- YYYYMMDD string for the mocked "now", matching GW._test.GetDateString().
function H.dateStr(year, month, day)
    if year then H.setDate(year, month, day) end
    return GW._test.GetDateString()
end

return H
