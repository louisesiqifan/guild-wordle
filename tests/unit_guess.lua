-- Spec: BEHAVIOR_SPEC.md section 1.2 (Guess evaluation)
-- Uses GW._test.EvaluateGuess directly for the pure scoring cases, and
-- GW.SubmitGuess for the cases that also involve game state / validation.
local T = require("runner")
local H = require("harness")
local GW, Mock = H.GW, H.Mock

-- Compact result comparison: EvaluateGuess returns {2,1,0,...}; tests
-- express expectations as "21000" strings for readability.
local function score(guess, answer)
    local r = GW._test.EvaluateGuess(guess, answer)
    return table.concat(r)
end

local function setup(answer)
    H.freshDB()
    H.setDate(2026, 3, 15)
    GW._test.SetWordForTest(answer, H.dateStr())
end

T.suite("1.2 Guess evaluation", function()

    T.test("UNIT-GUESS-01: exact match => all green", function()
        T.assertEquals(score("CRANE", "CRANE"), "22222")
    end)

    T.test("UNIT-GUESS-02: no shared letters => all grey", function()
        -- ROBOT vs CHEEK share nothing
        T.assertEquals(score("ROBOT", "CHEEK"), "00000")
    end)

    T.test("UNIT-GUESS-03: right letter, wrong position => yellow", function()
        -- Answer CRANE, guess ROBOT: R is in the answer but not at index 1.
        local s = score("ROBOT", "CRANE")
        T.assertEquals(s:sub(1, 1), "1", "R should be yellow (present, wrong spot)")
        T.assertEquals(s:sub(2, 2), "0", "O is not in CRANE")
    end)

    T.test("UNIT-GUESS-04: duplicate in guess, answer has one => exactly one yellow, other grey", function()
        -- Answer BANAL has one E? No -- use: answer CANAL (one L), guess LLAMA.
        -- LLAMA: L,L,A,M,A ; CANAL: C,A,N,A,L
        -- No positional matches. Answer pool: C,A,N,A,L.
        -- L(1): in pool -> yellow, consumes the single L.
        -- L(2): pool exhausted of L -> grey.
        local s = score("LLAMA", "CANAL")
        local lStates = s:sub(1, 1) .. s:sub(2, 2)
        T.assertTrue(lStates == "10" or lStates == "01",
            "exactly one of the two L's should be marked, got " .. lStates)
    end)

    T.test("UNIT-GUESS-05: duplicate where one is green => the other is grey, not yellow", function()
        -- Answer ABBEY? Use answer = ERASE, guess = SPEED.
        -- Simpler explicit case: answer "CHEEK" has two E; use one-E answer.
        -- Answer = "CRANE" (one E). Guess = "EERIE": E,E,R,I,E
        -- Positions: C/E no, R/E no, A/R no, N/I no, E/E YES (index 5 green).
        -- Pool from non-matching answer positions: C,R,A,N (no E left).
        -- So E(1), E(2) both grey; R(3) -> R is in pool -> yellow.
        local s = score("EERIE", "CRANE")
        T.assertEquals(s:sub(5, 5), "2", "final E should be green")
        T.assertEquals(s:sub(1, 1), "0", "first E should be grey (single E already consumed by the green)")
        T.assertEquals(s:sub(2, 2), "0", "second E should be grey")
        T.assertEquals(s:sub(3, 3), "1", "R is present in CRANE, wrong position")
    end)

    T.test("UNIT-GUESS-06: answer has two of a letter, guess has two in wrong spots => both yellow", function()
        -- Answer = "GEESE" (E at 2,3,5 -> three E). Use a cleaner pair:
        -- Answer = "SPEED" has two E (positions 3,4).
        -- Guess = "ERASE": E,R,A,S,E
        -- Positional: E/S no, R/P no, A/E no, S/E no, E/D no -> none green.
        -- Answer pool: S,P,E,E,D
        -- E(1) -> yellow (consumes one E), R -> not in pool -> grey,
        -- A -> grey, S -> in pool -> yellow, E(5) -> second E -> yellow.
        local s = score("ERASE", "SPEED")
        T.assertEquals(s:sub(1, 1), "1", "first E yellow")
        T.assertEquals(s:sub(5, 5), "1", "second E yellow (answer has two E)")
    end)

    T.test("UNIT-GUESS-07: wrong length rejected, no state mutation", function()
        setup("CRANE")
        local before = #GW.CurrentGame().guesses
        local ok, reason = GW.SubmitGuess("ABCD")
        T.assertFalse(ok)
        T.assertEquals(reason, "wrong_length")
        T.assertEquals(#GW.CurrentGame().guesses, before, "guess list must not grow")
        T.assertEquals(GW.CurrentGame().state, "playing")
    end)

    T.test("UNIT-GUESS-08: not in dictionary rejected, no state mutation", function()
        setup("CRANE")
        local before = #GW.CurrentGame().guesses
        local ok, reason = GW.SubmitGuess("ZZZZZ")
        T.assertFalse(ok)
        T.assertEquals(reason, "not_a_word")
        T.assertEquals(#GW.CurrentGame().guesses, before)
    end)

    T.test("UNIT-GUESS-09: lowercase/mixed case accepted and normalized", function()
        setup("CRANE")
        local ok = GW.SubmitGuess("rObOt")
        T.assertTrue(ok, "mixed-case valid word should be accepted")
        T.assertEquals(GW.CurrentGame().guesses[1], "ROBOT", "stored uppercased")
    end)

    T.test("UNIT-GUESS-10: 6 wrong guesses => state 'lost'", function()
        setup("CRANE")
        local words = {"ROBOT", "SHEEP", "LLAMA", "ABBEY", "SASSY", "ADDED"}
        local done, won
        for i, w in ipairs(words) do
            local ok, _, d, wn = GW.SubmitGuess(w)
            T.assertTrue(ok, "guess " .. i .. " (" .. w .. ") should be accepted")
            done, won = d, wn
        end
        T.assertTrue(done, "should be done after 6 guesses")
        T.assertFalse(won)
        T.assertEquals(GW.CurrentGame().state, "lost")
    end)

    T.test("UNIT-GUESS-11: correct guess before the 6th => state 'won', done+won true", function()
        setup("CRANE")
        GW.SubmitGuess("ROBOT")
        local ok, _, done, won = GW.SubmitGuess("CRANE")
        T.assertTrue(ok)
        T.assertTrue(done)
        T.assertTrue(won)
        T.assertEquals(GW.CurrentGame().state, "won")
    end)

    T.test("UNIT-GUESS-12: guessing after the game ended => 'already_done', no mutation", function()
        setup("CRANE")
        GW.SubmitGuess("CRANE")
        local countAfterWin = #GW.CurrentGame().guesses
        local ok, reason = GW.SubmitGuess("ROBOT")
        T.assertFalse(ok)
        T.assertEquals(reason, "already_done")
        T.assertEquals(#GW.CurrentGame().guesses, countAfterWin, "guess list must not grow after the game ended")
    end)

end)

T.run()
