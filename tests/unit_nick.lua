-- Spec: BEHAVIOR_SPEC.md section 1.4 (Nickname sanitization)
local T = require("runner")
local H = require("harness")
local GW, Mock = H.GW, H.Mock

local function nick()
    return GuildWordleDB.settings.nickname
end

local function lastPrint()
    return Mock.printed[#Mock.printed] or ""
end

-- Spies on the broadcast side effects a successful rename should trigger.
local function withSpies(fn)
    local calls = {streak = 0, nicks = 0, changed = 0}
    local realStreak, realNicks, realChanged =
        GW.BroadcastStreak, GW.BroadcastCharNicknames, GW.OnNicknameChanged
    GW.BroadcastStreak        = function() calls.streak = calls.streak + 1 end
    GW.BroadcastCharNicknames = function() calls.nicks = calls.nicks + 1 end
    GW.OnNicknameChanged      = function() calls.changed = calls.changed + 1 end
    local ok, err = pcall(fn, calls)
    GW.BroadcastStreak        = realStreak
    GW.BroadcastCharNicknames = realNicks
    GW.OnNicknameChanged      = realChanged
    if not ok then error(err, 0) end
    return calls
end

T.suite("1.4 Nickname sanitization", function()

    T.test("UNIT-NICK-01: empty/whitespace input leaves the nickname unchanged and reports current", function()
        H.freshDB()
        GuildWordleDB.settings.nickname = "Bonnie"
        GW.SetNickname("   ")
        T.assertEquals(nick(), "Bonnie")
        T.assertContains(lastPrint(), "Current nickname")
    end)

    T.test("UNIT-NICK-02: input with no letters at all is rejected", function()
        H.freshDB()
        GuildWordleDB.settings.nickname = "Bonnie"
        GW.SetNickname("123 !@#")
        T.assertEquals(nick(), "Bonnie", "nickname must not change")
        T.assertContains(lastPrint(), "only contain letters")
    end)

    T.test("UNIT-NICK-03: mixed input is stripped down to just letters", function()
        H.freshDB()
        GW.SetNickname("Bon1nie! 2")
        T.assertEquals(nick(), "Bonnie")
    end)

    T.test("UNIT-NICK-04: commas and semicolons are stripped (wire-format safety)", function()
        H.freshDB()
        GW.SetNickname("Bon,nie;X")
        T.assertEquals(nick(), "BonnieX")
        T.assertFalse(nick():find(",", 1, true), "no comma may survive")
        T.assertFalse(nick():find(";", 1, true), "no semicolon may survive")
    end)

    T.test("UNIT-NICK-05: accented Latin letters are preserved", function()
        H.freshDB()
        GW.SetNickname("Bonni\195\169")     -- Bonnié
        T.assertEquals(nick(), "Bonni\195\169")
    end)

    T.test("UNIT-NICK-06: non-Latin (Cyrillic) letters are preserved", function()
        H.freshDB()
        local cyrillic = "\208\145\208\190\208\189"   -- Бон
        GW.SetNickname(cyrillic)
        T.assertEquals(nick(), cyrillic)
    end)

    T.test("UNIT-NICK-07: ASCII input longer than 15 chars is truncated to 15", function()
        H.freshDB()
        GW.SetNickname("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        T.assertEquals(nick(), "ABCDEFGHIJKLMNO")
        T.assertEquals(#nick(), 15)
    end)

    T.test("UNIT-NICK-08 (regression): truncation never splits a multi-byte character", function()
        H.freshDB()
        -- 14 ASCII letters then an accented 2-byte char at character 15.
        local s = string.rep("A", 14) .. "\195\169"    -- ...AAé  (15 chars, 16 bytes)
        GW.SetNickname(s)
        T.assertEquals(nick(), s, "15 characters should survive intact even though it is 16 bytes")
        -- Now 15 ASCII + accented char at character 16 -> the accented char is dropped whole.
        H.freshDB()
        local s2 = string.rep("B", 15) .. "\195\169"
        GW.SetNickname(s2)
        T.assertEquals(nick(), string.rep("B", 15), "the 16th character must be dropped entirely, not half-cut")
        -- A dangling lone continuation byte would be invalid UTF-8; assert none.
        T.assertFalse(nick():find("\195"), "no dangling lead byte may remain")
    end)

    T.test("UNIT-NICK-09: setting the same value is a no-op with no side effects", function()
        H.freshDB()
        GuildWordleDB.settings.nickname = "Bonnie"
        local calls = withSpies(function()
            GW.SetNickname("Bonnie")
        end)
        T.assertEquals(calls.streak, 0, "BroadcastStreak must not fire")
        T.assertEquals(calls.nicks, 0, "BroadcastCharNicknames must not fire")
        T.assertEquals(calls.changed, 0, "OnNicknameChanged must not fire")
        T.assertContains(lastPrint(), "already")
    end)

    T.test("UNIT-NICK-10: successful rename fires all three side effects", function()
        H.freshDB()
        GuildWordleDB.settings.nickname = "Bonnie"
        local calls = withSpies(function()
            GW.SetNickname("Byamba")
        end)
        T.assertEquals(nick(), "Byamba")
        T.assertEquals(calls.changed, 1)
        T.assertEquals(calls.streak, 1)
        T.assertEquals(calls.nicks, 1)
    end)

    T.test("UNIT-NICK-11: TruncateUTF8('' , n) returns empty", function()
        T.assertEquals(GW.TruncateUTF8("", 5), "")
        T.assertEquals(GW.TruncateUTF8("", 0), "")
    end)

    T.test("UNIT-NICK-12: TruncateUTF8 leaves shorter strings unchanged", function()
        T.assertEquals(GW.TruncateUTF8("abc", 10), "abc")
    end)

    T.test("UNIT-NICK-13: TruncateUTF8 leaves exactly-N-character strings unchanged", function()
        T.assertEquals(GW.TruncateUTF8("abcde", 5), "abcde")
        local accented = "\195\169\195\169"   -- éé = 2 chars, 4 bytes
        T.assertEquals(GW.TruncateUTF8(accented, 2), accented)
    end)

    T.test("UNIT-NICK-14 (regression): no input shape makes SetNickname throw", function()
        -- The malformed-pattern bug this covers only reproduced under Lua 5.1
        -- semantics -- which is exactly what this suite runs under (LuaJIT).
        local inputs = {
            "", "   ", "123", "!@#$%^&*()", "a", string.rep("z", 500),
            "Bon,nie;X", "\195\169\195\177\195\182", "\208\145\208\190",
            "mixed 123 !@# Text", "\t\n ", "[]{}()<>",
            "\\", "%", "%%", "%a", "[a-z]", "^$.*+-?",
        }
        for _, input in ipairs(inputs) do
            H.freshDB()
            local ok, err = pcall(GW.SetNickname, input)
            T.assertTrue(ok, "SetNickname threw on input " .. string.format("%q", input)
                .. ": " .. tostring(err))
        end
    end)

    T.test("UNIT-NICK-15: SetNickname contains failures and reports them instead of propagating", function()
        H.freshDB()
        local realTrunc = GW.TruncateUTF8
        GW.TruncateUTF8 = function() error("boom") end
        local ok = pcall(GW.SetNickname, "Something")
        GW.TruncateUTF8 = realTrunc
        T.assertTrue(ok, "the public SetNickname must not propagate an internal error")
        T.assertContains(lastPrint(), "Nickname error")
    end)

end)

T.run()
