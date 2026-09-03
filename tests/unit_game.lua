-- Spec: BEHAVIOR_SPEC.md section 1.3 (Game state)
local T = require("runner")
local H = require("harness")
local GW, Mock = H.GW, H.Mock

local function key()
    return GW._test.CharKey()
end

T.suite("1.3 Game state", function()

    T.test("UNIT-GAME-01: first call returns a fresh playing state for today", function()
        H.freshDB()
        H.setDate(2026, 3, 15)
        local g = GW.CurrentGame()
        T.assertEquals(g.date, H.dateStr())
        T.assertEquals(#g.guesses, 0)
        T.assertEquals(#g.results, 0)
        T.assertEquals(g.state, "playing")
    end)

    T.test("UNIT-GAME-02: repeated same-day calls return the same table (mutations persist)", function()
        H.freshDB()
        H.setDate(2026, 3, 15)
        local g1 = GW.CurrentGame()
        g1.guesses[1] = "CRANE"
        g1.results[1] = {2,2,2,2,2}
        local g2 = GW.CurrentGame()
        T.assertSame(g2, g1, "should be the same table object")
        T.assertEquals(g2.guesses[1], "CRANE")
    end)

    T.test("UNIT-GAME-03: new day => fresh playing state, previous day not reused", function()
        H.freshDB()
        H.setDate(2026, 3, 15)
        GW._test.SetWordForTest("CRANE", H.dateStr())
        GW.SubmitGuess("CRANE")
        T.assertEquals(GW.CurrentGame().state, "won")

        H.setDate(2026, 3, 16)
        local g = GW.CurrentGame()
        T.assertEquals(g.state, "playing")
        T.assertEquals(#g.guesses, 0)
        T.assertEquals(g.date, H.dateStr())
    end)

    T.test("UNIT-GAME-04: non-table guesses field is repaired, not fatal", function()
        H.freshDB()
        H.setDate(2026, 3, 15)
        GuildWordleDB.games[key()] = {
            date = H.dateStr(), guesses = "corrupted", results = {}, state = "playing",
        }
        local ok, g = pcall(GW.CurrentGame)
        T.assertTrue(ok, "must not throw on corrupted guesses field")
        T.assertEquals(type(g.guesses), "table")
    end)

    T.test("UNIT-GAME-05: mismatched guesses/results lengths => both reset, state back to playing", function()
        H.freshDB()
        H.setDate(2026, 3, 15)
        GuildWordleDB.games[key()] = {
            date = H.dateStr(),
            guesses = {"CRANE", "ROBOT"},
            results = {{2,2,2,2,2}},   -- only one result for two guesses
            state = "won",
        }
        local g = GW.CurrentGame()
        T.assertEquals(#g.guesses, 0)
        T.assertEquals(#g.results, 0)
        T.assertEquals(g.state, "playing")
    end)

    T.test("UNIT-GAME-06: 6 guesses but still marked playing => forced to lost", function()
        H.freshDB()
        H.setDate(2026, 3, 15)
        local guesses, results = {}, {}
        for i = 1, 6 do
            guesses[i] = "ROBOT"
            results[i] = {0,0,0,0,0}
        end
        GuildWordleDB.games[key()] = {
            date = H.dateStr(), guesses = guesses, results = results, state = "playing",
        }
        T.assertEquals(GW.CurrentGame().state, "lost")
    end)

    T.test("UNIT-GAME-07: two characters on one account keep independent game state", function()
        H.freshDB()
        H.setDate(2026, 3, 15)
        GW._test.SetWordForTest("CRANE", H.dateStr())

        Mock.unitName = "Alpha"
        GW.SubmitGuess("CRANE")
        T.assertEquals(GW.CurrentGame().state, "won")

        Mock.unitName = "Beta"
        local g = GW.CurrentGame()
        T.assertEquals(g.state, "playing", "second character should have its own untouched game")
        T.assertEquals(#g.guesses, 0)

        -- And the first character's game is still intact.
        Mock.unitName = "Alpha"
        T.assertEquals(GW.CurrentGame().state, "won")
    end)

end)

T.run()
