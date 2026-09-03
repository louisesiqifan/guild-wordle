# GuildWordle — Expected Behavior Specification

Status: **reviewed and implemented.** Sections 1, 2, 4 and 5 are automated (149 tests,
`./tests/run_all.sh`); section 3 is a manual in-game checklist, driven by the dev panel described in
section 4. Tests reference these IDs by name, so this file stays the source of truth: **add the
spec entry before writing the test.**

## Purpose and scope

This session produced a long string of bugs that were each individually silent until manually
diagnosed: a nil-table crash, a nil-word crash, a malformed Lua pattern that only failed under
WoW's actual Lua 5.1 (not the Lua 5.5 used to spot-check it locally), cascading failures where one
broken subsystem silently aborted unrelated code in the same caller. A test suite's job here is to
catch this *class* of regression automatically, on every future change, instead of relying on
manual in-game testing to eventually surface it.

**In scope for automated tests (`GuildWordle.lua`):** word selection, guess evaluation, streak
math, nickname sanitization/truncation, SavedVariables initialization, the addon-message wire
protocol (serialize + parse), error-handling wrappers. This file only touches a handful of WoW
globals (`UnitName`, `GetRealmName`, `GetGuildInfo`, `IsInGuild`, `IsInGroup`, `IsInRaid`,
`SendChatMessage`, `C_ChatInfo`/`SendAddonMessage`, `C_Timer`, `CreateFrame` for one event frame,
`date`/`time`, `seterrorhandler`/`geterrorhandler`, `strtrim`), all mockable in plain Lua.

**Partially in scope (`GuildWordle_UI.lua`):** this file is wall-to-wall
`CreateFrame`/`SetPoint`/texture/font calls against WoW's live widget system. It *can* be loaded
against the mock (see section 5), which makes its render paths testable for robustness against
awkward data — but the mock's geometry is meaningless (widths/heights stub to 0), so **layout and
anything visual stays manual UAT** (section 3).

**Test levels used below:**
- **Unit** — one function, isolated, mocked inputs. Runs in a plain Lua interpreter against the
  real `GuildWordle.lua` with a small WoW-API mock loaded first.
- **Integration** — multiple functions/subsystems together within the same mocked environment,
  including simulating two or more "clients" (separate `GuildWordleDB` tables) passing addon
  messages to each other to verify gossip behavior end-to-end without a real WoW client.
- **UAT** — end-to-end, in-game, manual. Cannot be automated; listed here as a checklist so
  behavior is still specified and reviewable, and so a future automated UI test (if the tooling
  ever supports it) has something to target.

**ID scheme:** `LEVEL-AREA-##`, e.g. `UNIT-STREAK-03`. Test code should reference these IDs in
comments/names so spec and implementation stay traceable to each other.

**A note on what "correct" means here:** this spec describes the code's *current, intended*
behavior as of this review — not a wishlist of changes. Anything that looks like a design
limitation (e.g. `charNicknames` is never pruned) is called out as a known, accepted characteristic
rather than a bug to fix, unless stated otherwise. Flag anything below that looks wrong during
review rather than assuming it's deliberate.

---

## 1. Unit-level behavior

### 1.1 Word selection (`GW.CurrentWord`, `GetTodaysWord`)

- **UNIT-WORD-01**: Same mocked calendar date, called twice → returns the identical word both
  times (determinism).
- **UNIT-WORD-02**: Two different mocked calendar dates → returns different words (not guaranteed
  mathematically for *every* pair, but true for the specific dates the test fixes — pick two dates
  known to differ, e.g. by checking against a hardcoded expected value or just asserting the LCG
  output differs for two adjacent days).
- **UNIT-WORD-03**: `GuildWordle_Answers` absent or empty → returns the literal string `"ERROR"`,
  does not throw.
- **UNIT-WORD-04**: `GW.CurrentWord()` called multiple times same day → same cached value returned
  without recomputing (verify via a call counter on the underlying word-list lookup, or simply that
  identity holds even if the mock date function is set to error on a second call).
- **UNIT-WORD-05**: Simulate the date changing *between* two calls to `GW.CurrentWord()` (mock
  `date()` to return day N then day N+1) → the second call returns a freshly computed word for the
  new day, not the cached one from day N.
- **UNIT-WORD-06**: `GW.CurrentWord()` called when `GW.todaysWord` has never been set (simulating
  `InitDB()` never having run, or having aborted before priming the cache) → self-heals, computes
  and returns a valid word rather than erroring. This is a regression test for the exact bug that
  produced `attempt to index local 'answer' (a nil value)` on every guess.

### 1.2 Guess evaluation (via `GW.SubmitGuess`, since `EvaluateGuess` itself is not exposed)

Set `GW.todaysWord` (or drive it via the word-list mock) to a known answer for each case.

- **UNIT-GUESS-01**: Guess identical to the answer → all 5 positions green (2), win detected.
- **UNIT-GUESS-02**: Guess shares no letters with the answer → all 5 positions grey (0).
- **UNIT-GUESS-03**: Letter present in the answer but wrong position → yellow (1) at that position.
- **UNIT-GUESS-04 (duplicate-letter, answer has fewer)**: Answer has exactly one of letter X, guess
  has two of letter X in non-matching positions → exactly one of the two guess positions is marked
  yellow, the other grey (never both yellow) — standard Wordle duplicate-letter accounting.
- **UNIT-GUESS-05 (duplicate-letter, one green + one elsewhere)**: Answer has exactly one of letter
  X; guess has letter X in the correct position AND again elsewhere → the correct-position one is
  green, the other is grey (not yellow), since the single occurrence is already accounted for by
  the green match.
- **UNIT-GUESS-06 (duplicate-letter, answer has two)**: Answer has two of letter X, guess has two
  of letter X in wrong positions → both marked yellow.
- **UNIT-GUESS-07**: Guess not exactly 5 letters → rejected with reason `"wrong_length"`, no state
  mutation (guesses/results unchanged, game stays in "playing").
- **UNIT-GUESS-08**: Guess not present in the valid-word dictionary → rejected with reason
  `"not_a_word"`, no state mutation.
- **UNIT-GUESS-09**: Guess submitted lowercase or mixed case → accepted and evaluated the same as
  uppercase (case-insensitive on input, case-normalized internally).
- **UNIT-GUESS-10**: 6th guess, still not correct → game state becomes `"lost"`, `OnGameEnd(false)`
  side effects fire (see 2.1).
- **UNIT-GUESS-11**: Winning guess before the 6th attempt → game state becomes `"won"`,
  `OnGameEnd(true)` fires, and `done`/`won` return values are both true.
- **UNIT-GUESS-12**: Submitting any guess after the game has already ended (won or lost) → rejected
  with reason `"already_done"`, `game.guesses`/`game.results` unchanged (length doesn't grow).

### 1.3 Game state (`GW.CurrentGame`)

- **UNIT-GAME-01**: First-ever call for a given mocked character/realm → returns a fresh table:
  `date` = today, `guesses = {}`, `results = {}`, `state = "playing"`.
- **UNIT-GAME-02**: Repeated calls the same day return the *same* table object (mutations via one
  call's returned reference are visible to the next call) — not a fresh table each time.
- **UNIT-GAME-03**: Mocked date advances to a new day since the stored game's `date` → next call
  returns a fresh `"playing"` state for the new day; the previous day's completed game is not
  reused or merged.
- **UNIT-GAME-04 (corruption repair)**: `games[key].guesses` manually set to a non-table (e.g. a
  string or nil-but-present-key) → next `GW.CurrentGame()` call repairs it to `{}` rather than
  erroring.
- **UNIT-GAME-05 (corruption repair)**: `games[key].guesses` and `.results` manually set to
  different lengths → next call resets both to `{}` and `state` to `"playing"`.
- **UNIT-GAME-06 (corruption repair)**: `games[key].state == "playing"` but `guesses` already has
  6 entries (e.g. from a crash mid-write) → next call forces `state` to `"lost"`.
- **UNIT-GAME-07**: Two different mocked characters (different `UnitName`/`GetRealmName`) each get
  independent game state — playing/winning on one never affects the other's `games` entry.

### 1.4 Nickname sanitization (`FilterLetters`, `GW.TruncateUTF8`, `GW.SetNickname`)

`FilterLetters` and `SetNicknameImpl` are file-local; test through the public `GW.SetNickname` and
by inspecting `GuildWordleDB.settings.nickname` afterward, plus through `GW.TruncateUTF8` directly
(it is exposed).

- **UNIT-NICK-01**: Empty/whitespace-only input → no change to the stored nickname; prints the
  "current nickname" message (verify via a captured `print` call, not just non-crash).
- **UNIT-NICK-02**: Input containing only digits/punctuation/spaces, no letters at all → rejected
  ("letters only" message), stored nickname unchanged.
- **UNIT-NICK-03**: Input mixing letters with digits/punctuation/spaces (e.g. `"Bon1nie!"`) →
  stripped down to just the letters (`"Bonnie"`), stored and confirmed.
- **UNIT-NICK-04**: Input containing a comma and/or semicolon specifically → both are stripped
  (wire-format safety), regardless of the general letters-only rule already covering this.
- **UNIT-NICK-05**: Input containing accented Latin letters (é, ñ, ö) → preserved as-is, not
  stripped, not mangled.
- **UNIT-NICK-06**: Input containing non-Latin letters (Cyrillic, CJK) → preserved as-is.
- **UNIT-NICK-07**: Input longer than 15 characters (pure ASCII) → truncated to exactly 15
  characters.
- **UNIT-NICK-08 (regression)**: Input longer than 15 *characters* where character 15/16 is a
  multi-byte accented character straddling the cut point → truncates at a full-character boundary,
  never leaving a dangling/corrupted trailing byte. This is the exact case `GW.TruncateUTF8` exists
  for; construct a string where a naive `string.sub(1,15)` byte-cut would split a character, and
  assert the result is valid.
- **UNIT-NICK-09**: Setting the nickname to its current value (post-filter) → no-op; "already"
  message printed; `GW.OnNicknameChanged`/`GW.BroadcastStreak`/`GW.BroadcastCharNicknames` are
  **not** triggered (verify via mock call counts).
- **UNIT-NICK-10**: Successful rename → `GuildWordleDB.settings.nickname` updated,
  `GW.OnNicknameChanged` invoked (if defined), `GW.BroadcastStreak()` and
  `GW.BroadcastCharNicknames()` both invoked (verify via mock call counts/spies).
- **UNIT-NICK-11**: `GW.TruncateUTF8("", N)` → returns `""` unchanged for any N ≥ 0.
- **UNIT-NICK-12**: `GW.TruncateUTF8(s, N)` where `s` has fewer than N characters → returns `s`
  unchanged (identity check, not just equal value — same string).
- **UNIT-NICK-13**: `GW.TruncateUTF8(s, N)` where `s` has exactly N characters → returns `s`
  unchanged.
- **UNIT-NICK-14 (regression)**: `GW.SetNickname` given input that would previously have thrown
  `malformed pattern (missing ']')` under the old byte-range-escape implementation — since that
  implementation is gone, this is really a "doesn't throw for any printable input" fuzz-style
  check: feed a range of inputs (digits, symbols, mixed scripts, empty, very long) through
  `GW.SetNickname` and assert none of them raise an uncaught error.
- **UNIT-NICK-15 (`SetNickname` failure containment)**: Force `SetNicknameImpl`'s internals to
  throw (e.g. by making a dependency like `GW.TruncateUTF8` temporarily throw via a test hook, if
  one exists — otherwise this may only be practically verifiable at the integration level) → the
  public `GW.SetNickname` call does not propagate the error to its caller, and prints a
  `"Nickname error: ..."` message instead.

### 1.5 Streak logic (`GW.RecordStreakResult`, `GW.CurrentStreak`)

**The streak measures PARTICIPATION, not success.** Finishing today's puzzle extends the streak
whether or not the word was solved; the only thing that breaks a streak is skipping a day entirely.
`GW.RecordStreakResult()` therefore takes **no argument** — it is called on game end regardless of
outcome. (It previously reset on a loss, making the streak a skill metric rather than a "did you
show up" one; that was changed deliberately, so a test asserting a loss zeroes the streak is
asserting the *old* rule and should be updated, not the code.)

All cases below start from `GuildWordleDB.streak = {current=0, best=0, lastDate=nil}` unless noted,
with the mocked "today" and "yesterday" set explicitly per case.

- **UNIT-STREAK-01**: First-ever play (`lastDate` was nil) → `current = 1`, `best = 1`,
  `lastDate` = today.
- **UNIT-STREAK-02**: Play with `lastDate` == yesterday and `current > 0` → `current` increments by
  1; `best` updates to match if the new `current` exceeds the old `best`, otherwise `best`
  unchanged.
- **UNIT-STREAK-03**: Play with `lastDate` == yesterday but `current == 0` → treated as a fresh
  start, `current = 1`, not extended. Only reachable from legacy data written under the old
  lose-resets rule, but the path still has to behave.
- **UNIT-STREAK-04**: Play with `lastDate` older than yesterday (a day was skipped) → `current`
  resets to 1 (fresh start), not extended, regardless of how high `current` was before.
- **UNIT-STREAK-05**: A **loss** extends the streak exactly like a win — `current` increments,
  `best` rises with it, `lastDate` = today. Losing must never break a streak.
- **UNIT-STREAK-06 (idempotency)**: `RecordStreakResult` called twice with `lastDate` already ==
  today (simulating two alts finishing the same day) → the second call is a complete no-op: no
  change to `current`, `best`, or `lastDate`. Two characters playing the same day is one day of
  participation, not two.
- **UNIT-STREAK-07**: Consecutive days always accumulate — after N consecutive played days,
  `current == N` and `best >= N`, regardless of how many were wins or losses.
- **UNIT-STREAK-07b**: A gap mid-sequence is the only reset — build a run, skip a day, and confirm
  `current` restarts at 1 while `best` retains the earlier run, then builds again from there.
- **UNIT-STREAK-08 (`CurrentStreak` staleness)**: `current > 0` but `lastDate` is neither today nor
  yesterday (a day was skipped with no play at all, and nothing has called `RecordStreakResult`
  since) → `GW.CurrentStreak()` returns `current = 0` at *read time*, without needing another
  `RecordStreakResult` call, and this zeroing is persisted back into `GuildWordleDB.streak` (not
  just reflected in the return value).
- **UNIT-STREAK-09**: `current > 0` and `lastDate` == today → `GW.CurrentStreak()` returns
  `current` unchanged (not stale).
- **UNIT-STREAK-10**: `current > 0` and `lastDate` == yesterday → `GW.CurrentStreak()` returns
  `current` unchanged (grace period — still within the window to extend today).
- **UNIT-STREAK-11**: `current == 0` → `GW.CurrentStreak()` never touches `lastDate` regardless of
  staleness (the staleness check only applies when `current > 0`).

### 1.6 SavedVariables initialization (`InitDB`, tested indirectly — see note)

`InitDB` is file-local and only invoked from the `ADDON_LOADED` handler. Tests should call it
indirectly by simulating `ADDON_LOADED` firing (see 2.6 below, since this is really an integration
concern), **except** for the pieces of pure logic that can be isolated:

- **UNIT-INIT-01**: `CharKey()` equivalent behavior — since `CharKey` is also file-local, verify
  indirectly via `GW.CurrentGame()`'s key when `UnitName`/`GetRealmName` mocks are set to return
  `nil` → does not throw (regression test for the exact crash that left `charNicknames`
  uninitialized for an entire session).
- **UNIT-INIT-02**: `FilterLetters` (already covered under 1.4) applied to a legacy nickname
  containing digits, as the one-time sanitization pass would do — covered by UNIT-NICK-03; no
  separate test needed beyond confirming `InitDB` actually calls it (integration level).

### 1.7 Wire-format serialization

For all of these, mock `SendAddonMessage`/`C_ChatInfo.SendAddonMessage` to capture every call's
arguments into a list rather than actually sending anything.

- **UNIT-WIRE-01 (`RESULTS:`)**: One leaderboard entry for today → exactly one `SendAddonMessage`
  call with message `"RESULTS:<YYYYMMDD>:name,guesses,solved,pattern"` where `solved` is `"1"` or
  `"0"` and the entry has no trailing/leading garbage. This format must never change — treat any
  future diff to this string shape as a breaking change requiring explicit sign-off, not something
  a test should be "fixed" to accommodate.
- **UNIT-WIRE-02**: No leaderboard entries for today (or leaderboard doesn't exist for the current
  guild) → `GW.BroadcastKnownResults()` sends nothing at all (zero calls), not an empty message.
- **UNIT-WIRE-03**: Not in a guild (`IsInGuild()` mocked false) → `GW.BroadcastKnownResults()`
  returns immediately, sends nothing, regardless of what's in `leaderboard`.
- **UNIT-WIRE-04 (batching)**: Enough leaderboard entries that the serialized total would exceed
  `MAX_MSG_LEN` (200) in one message → split across multiple `SendAddonMessage` calls, each
  individually under the cap, with every entry accounted for exactly once across the batch (no
  entry duplicated or dropped).
- **UNIT-WIRE-05 (`NICKS:`)**: One charNicknames entry → message
  `"NICKS:charName,nickname"`. Empty charNicknames table → nothing sent.
- **UNIT-WIRE-06 (`STREAKS:`)**: One streakBoard entry → message
  `"STREAKS:accountId,nickname,current,best,lastDate"`. Verify `GW.RecordOwnStreakEntry()`'s
  effects (own entry populated) show up in the broadcast even if `streakBoard` started empty.
- **UNIT-WIRE-07**: `GW.BroadcastCharNicknames()`/`GW.BroadcastStreak()` both return immediately
  without sending when not in a guild, mirroring UNIT-WIRE-03.

### 1.8 Wire-format parsing (`HandleAddonMessage`)

`HandleAddonMessage` is file-local; test it via the pcall-wrapped `CHAT_MSG_ADDON` path if exposed
for testing, or by exposing it on a test-only hook (see "Open questions" at the end). Mock
`GW.OnLeaderboardUpdate`/`GW.OnStreakBoardUpdate` as spies to verify they fire only when state
actually changes.

- **UNIT-PARSE-01**: Message with the wrong `prefix` argument (not `"GUILDWORDLE"`) → ignored
  entirely, no state change, regardless of `text` content.
- **UNIT-PARSE-02**: `"SYNC_REQ"` from a sender other than self → triggers all three broadcast
  functions (`BroadcastKnownResults`, `BroadcastStreak`, `BroadcastCharNicknames` — verify via
  spies).
- **UNIT-PARSE-03**: `"SYNC_REQ"` where the sender (realm-stripped) equals `UnitName("player")` →
  no broadcasts triggered (prevents responding to your own echo).
- **UNIT-PARSE-04 (`RESULTS:`, correct date)**: `"RESULTS:<today>:name,3,1,02100 21010 22222"` →
  `leaderboard[guildKey][today]["name"]` set to `{guesses=3, solved=true, pattern="02100 21010
  22222"}`; `GW.OnLeaderboardUpdate` fires.
- **UNIT-PARSE-05 (`RESULTS:`, wrong date)**: Same message but with a date that isn't today →
  entirely ignored, nothing stored under any date, `OnLeaderboardUpdate` not fired.
- **UNIT-PARSE-06 (`RESULTS:`, malformed entry)**: A batched message where one `;`-separated entry
  is malformed (wrong field count/shape) and others are well-formed → the malformed entry is
  silently skipped, the well-formed entries in the *same message* are still stored correctly, no
  error thrown.
- **UNIT-PARSE-07 (`RESULTS:`, multiple entries)**: Message with several valid `;`-separated
  entries → all stored, none dropped.
- **UNIT-PARSE-08 (`NICKS:`)**: `"NICKS:CharA,Bonnie;CharB,Byamba"` → both mappings stored in
  `charNicknames[guildKey]`.
- **UNIT-PARSE-09 (`NICKS:`, empty nickname field)**: Entry with an empty nickname
  (`"CharA,"`) → skipped, does not overwrite an existing mapping with blank, and does not create a
  new blank one.
- **UNIT-PARSE-10 (`NICKS:`, unchanged value)**: Entry whose nickname exactly matches what's
  already stored for that character → does not set the "changed" flag (verify
  `OnLeaderboardUpdate` is NOT called for a message that changes nothing).
- **UNIT-PARSE-11 (`STREAKS:`, fresh entry)**: First-ever entry for an `accountId` →
  stored as-is (`nickname`/`current`/`best`/`lastDate` all taken from the message).
- **UNIT-PARSE-12 (`STREAKS:`, best only increases)**: Existing entry has `best=5`; incoming
  message has `best=3` but a *fresher* `lastDate` → the stored `current`/`nickname`/`lastDate`
  update to the incoming values, but `best` stays at 5 (never decreases).
- **UNIT-PARSE-13 (`STREAKS:`, freshness gate blocks stale `current`)**: Existing entry has
  `lastDate="20260810"`, `current=5`; incoming message has `lastDate="20260809"` (older) — even
  with a plausible `current` value → the incoming `current`/`nickname`/`lastDate` are **rejected**,
  existing values retained. This is the regression test for "a stale gossip echo can't make an
  already-broken streak look active again."
- **UNIT-PARSE-14 (`STREAKS:`, stale message can still raise `best`)**: Same stale-`lastDate`
  scenario as above, but the incoming `best` is higher than the stored `best` → `best` still
  updates upward even though `current`/`nickname`/`lastDate` are rejected (best-only-increases is
  independent of the freshness gate).
- **UNIT-PARSE-15 (`STREAKS:`, equal `lastDate`)**: Incoming `lastDate` exactly equals the stored
  one → treated as fresh-enough (accepted), per the `>=` comparison, not strictly `>`.
- **UNIT-PARSE-16**: Message with a completely unrecognized prefix (not `SYNC_REQ`/`RESULTS:`/
  `NICKS:`/`STREAKS:`) → falls through with no error and no state change. (This is the mechanism
  that makes any *future* new message type safely ignorable by clients that predate it, and is also
  what makes an old client's inability to parse `NICKS:`/`STREAKS:` safe rather than crashy — worth
  a test precisely because that safety property is being relied on architecturally.)

### 1.9 Self-healing defensive guards

- **UNIT-HEAL-01**: Call `GW.RecordOwnCharNickname()` with `GuildWordleDB.charNicknames` manually
  set to `nil` beforehand (simulating `InitDB` having aborted before initializing it) → does not
  throw; `GuildWordleDB.charNicknames` ends up a valid table afterward with the caller's own
  mapping present.
- **UNIT-HEAL-02**: Same as above for `GW.RecordOwnStreakEntry()` and `GuildWordleDB.streakBoard`.
- **UNIT-HEAL-03**: Feed a `NICKS:` message into `HandleAddonMessage` with `charNicknames` manually
  nil'd beforehand → does not throw, table is created and the entry stored.
- **UNIT-HEAL-04**: Same as above for a `STREAKS:` message and `streakBoard`.

### 1.10 Error-handling wrappers

- **UNIT-ERR-01**: `GW.SetNickname` — if the underlying implementation throws (simulate by passing
  an input engineered to break something, or via a test seam), the public function does not
  propagate the error and prints a message containing `"Nickname error:"`.
- **UNIT-ERR-02**: The global error handler installed via `seterrorhandler` — feed it a message
  string containing `"AddOns/GuildWordle/GuildWordle.lua:123: some error"` → the addon's own print
  path fires (verify via captured `print` calls) regardless of `devMode`.
- **UNIT-ERR-03**: Feed the same handler a message string that does *not* mention
  `AddOns/GuildWordle/` (simulating another addon's error), with `devMode` false → the addon's
  print path does NOT fire.
- **UNIT-ERR-04**: Same as UNIT-ERR-03 but with `devMode` true → the dev-mode print path DOES fire
  (prefixed differently, `"[GuildWordle DEV]"`).
- **UNIT-ERR-05**: In all of UNIT-ERR-02 through 04, the previously-installed error handler (the
  mock's stand-in for whatever was there before) is still invoked afterward — verify via a spy that
  it's called exactly once regardless of the print-path branch taken.

---

## 2. Integration-level behavior

These run in the same mocked environment as Section 1, but exercise multiple functions together,
and in the gossip cases, simulate **two independent `GuildWordleDB` tables** (two "clients") with
messages manually relayed between them by calling one client's broadcast-capturing mock output
into the other's `HandleAddonMessage`-equivalent entry point.

### 2.1 Full play-through, single client

- **INT-PLAY-01 (win)**: Fresh day, submit the correct word as the first guess → `SubmitGuess`
  returns `won=true`; `GW.CurrentGame().state == "won"`; a leaderboard entry exists for today under
  this character's name with `solved=true, guesses=1`; `GW.CurrentStreak().current == 1` (assuming
  no prior streak); in-guild mock shows `BroadcastKnownResults`, `BroadcastStreak`, and
  `BroadcastCharNicknames` were all called; `ShareToCheckedChannels`-equivalent behavior attempted
  per the mocked auto-share settings.
- **INT-PLAY-02 (loss)**: Fresh day, submit 6 valid-but-wrong guesses → game ends `"lost"`;
  leaderboard entry `solved=false, guesses=6`; the streak **extends** exactly as a win would (the
  leaderboard records the loss, the streak only records that you played); same broadcast side
  effects as above.
- **INT-PLAY-03 (replay blocked)**: After INT-PLAY-01 or 02, submit another guess the same day →
  rejected `"already_done"`; leaderboard entry from the completed game is unchanged (not
  overwritten); no additional broadcasts fired from this rejected attempt.
- **INT-PLAY-04 (not in guild)**: Same as INT-PLAY-01 but `IsInGuild()` mocked false → leaderboard
  entry still created locally, streak still updates, but none of the three broadcast functions
  actually send anything (their own internal `IsInGuild()` guard).
- **INT-PLAY-05 (two alts, same account, same guild, same day)**: Simulate two different
  `UnitName`/`GetRealmName` pairs under the *same* `GuildWordleDB` (same account), both playing and
  finishing the same day, same guild → both get independent leaderboard rows keyed by their own
  character names; `GW.RecordStreakResult` is only meaningfully applied once (the second character's
  finish is a no-op per UNIT-STREAK-06, regardless of win/loss); both leaderboard rows resolve to
  the same nickname via `charNicknames` once `GW.RecordOwnCharNickname` has run for both (see 2.2).

### 2.2 Nickname rename propagation, single client

- **INT-NICK-01**: Character has an existing leaderboard entry for today; rename via
  `GW.SetNickname` → `charNicknames[guildKey][thisChar]` reflects the new name immediately
  (synchronously, without needing a broadcast round-trip) — verify by reading the table right after
  the call returns, before any mocked network delay.
- **INT-NICK-02 (cross-alt propagation)**: Same account has two characters, both with existing
  leaderboard entries in the *same* guild (character A from a previous mocked day still within the
  7-day window, character B currently active). Rename while "logged in" as character B → character
  A's `charNicknames` mapping *also* updates, without needing character A to be the active
  character. Verify this reflects the cross-referencing logic in `GW.RecordOwnCharNickname`
  (`games` × this guild's `leaderboard`).
- **INT-NICK-03 (no cross-guild leak)**: Same as INT-NICK-02, but character A's known leaderboard
  entry is in a **different** guild than character B's current guild → character A's mapping in
  its *own* guild's `charNicknames` bucket is untouched by a rename performed while playing
  character B (renaming only ever touches the currently active guild's bucket, and only for
  characters already confirmed to be in *that* bucket).
- **INT-NICK-04**: Renaming to the same value → no broadcast side effects (per UNIT-NICK-09),
  verified again here at the integration level via the mock spies on `BroadcastStreak`/
  `BroadcastCharNicknames`.

### 2.3 Gossip round-trip (two simulated clients)

Set up two independent `GuildWordleDB` tables (`clientA`, `clientB`), each with its own mocked
`UnitName`/`GetRealmName`/`accountId`, both in the same mocked guild. "Sending" a message means
capturing client A's `SendAddonMessage` calls and manually feeding each captured message string
into client B's message-handling entry point (and vice versa) — there is no real network in the
test harness.

- **INT-GOSSIP-01 (`RESULTS:` round-trip)**: Client A plays and finishes today's game → client A's
  broadcast message, fed into client B, results in client B's `leaderboard[guildKey][today]`
  containing an entry for client A's character name with the correct guesses/solved/pattern.
- **INT-GOSSIP-02 (`NICKS:` round-trip)**: Client A sets a nickname and broadcasts → fed into
  client B, client B's `charNicknames[guildKey][clientAsCharName]` reflects it.
- **INT-GOSSIP-03 (`STREAKS:` round-trip, normal)**: Client A wins today, extending its streak →
  broadcast fed into client B, client B's `streakBoard[guildKey][clientA.accountId]` reflects the
  new current/best/nickname/lastDate.
- **INT-GOSSIP-04 (`STREAKS:` round-trip, out-of-order delivery)**: Client A's streak breaks (a
  loss), then a *stale* echo of A's previous, still-active streak arrives at client B afterward
  (simulate by feeding an older-`lastDate` message after a newer one) → client B's stored `current`
  for A does NOT get rolled back to "active" by the stale echo, but `best` still reflects the
  highest value seen across both messages. This directly exercises the same logic as
  UNIT-PARSE-13/14 but through the full broadcast→parse pipeline rather than a hand-built message
  string.
- **INT-GOSSIP-05 (three-way secondhand propagation)**: Client A plays while client B is offline
  (not simulated in this harness, just: B never receives A's direct broadcast). Client C receives
  A's broadcast directly, and separately client C periodically re-broadcasts *everything it knows*
  (call `GW.BroadcastKnownResults`/`BroadcastStreak`/`BroadcastCharNicknames` on client C's state) →
  feeding *that* rebroadcast into client B results in B learning about A's result/streak/nickname
  secondhand, without A and B ever directly exchanging a message. This is the core "gossip protocol"
  property the whole design relies on — worth a dedicated test rather than assuming it falls out of
  the round-trip tests above.
- **INT-GOSSIP-06 (`SYNC_REQ` triggers full resend)**: Client B sends `SYNC_REQ`; fed into client A
  → client A responds by broadcasting all three message types (verify via spies), even if nothing
  changed recently on A's side (a full-knowledge resend, not a diff).

### 2.4 Wire-format stability (explicit non-regression checks)

- **INT-WIRE-01**: The exact byte format of a `RESULTS:` message is asserted against a hardcoded
  example string end-to-end (build a known leaderboard entry, broadcast it, assert the captured
  message equals a fixed expected string exactly). This format must never change; a failing test
  here means a deliberate, reviewed protocol change, not a bug to "fix" by updating the assertion
  without discussion.
- **INT-WIRE-02**: Confirm `RESULTS:` messages never contain a nickname field under any
  circumstance (loop through several `charNicknames` states, including populated ones, and confirm
  the broadcast `RESULTS:` message shape is unaffected by what's in `charNicknames`) — this is the
  regression test for "nickname must stay a separate, additive concern."

### 2.5 SavedVariables initialization, full sequence

Simulate `ADDON_LOADED` firing (call whatever the test harness exposes as the init entry point)
against various starting `GuildWordleDB` shapes:

- **INT-INIT-01 (fresh/nil `GuildWordleDB`)**: Global starts `nil` → after init, every expected
  subtable exists (`leaderboard`, `games`, `settings`, `streak`, `streakBoard`, `charNicknames`),
  `settings.autoShare` defaults all three channels true, `settings.scale` defaults to 1,
  `settings.nickname` defaults to the mocked `UnitName("player")`, `accountId` is set.
  `GW.CurrentWord()` returns a valid non-nil word afterward.
- **INT-INIT-02 (partially populated)**: `GuildWordleDB` pre-populated with only `settings.scale`
  set → after init, that value is preserved untouched, and every other missing field is filled in
  with defaults (never overwritten if already present).
  Use a realistic snapshot for this (see 2.6) rather than a synthetic minimal one, to catch
  interactions a hand-built fixture might miss.
- **INT-INIT-03 (accountId frozen)**: `GuildWordleDB.accountId` pre-set to a specific value; mocked
  `UnitName`/`GetRealmName` return something that would compute a *different* `CharKey()` → after
  init, `accountId` is unchanged (never recomputed once set).
- **INT-INIT-04 (`UnitName`/`GetRealmName` return nil)**: Both mocked to return `nil` on a
  fresh/nil `GuildWordleDB` (simulating the exact conditions that caused the original crash) → init
  completes without throwing; `leaderboard`/`games`/`streakBoard`/`charNicknames` all end up as
  valid tables regardless of what happens with `accountId`/`nickname` defaulting. This is the
  direct regression test for the bug reported as `attempt to index field 'charNicknames' (a nil
  value)`.
- **INT-INIT-05 (7-day pruning, leaderboard)**: `leaderboard` pre-populated with several
  guild/date buckets, some within 7 days of the mocked "today" and some older → after init, only
  the recent ones remain; entries within the window are untouched (not just "still present" but
  byte-identical to before).
- **INT-INIT-06 (7-day pruning, games)**: Same as above for `games`, keyed by character.
- **INT-INIT-07 (pruning tolerates malformed dates)**: A `leaderboard`/`games` entry with a
  non-numeric or missing date field → pruned (treated as too old / invalid) rather than causing an
  error that aborts the rest of the pruning loop.
- **INT-INIT-08 (legacy nickname cleanup)**: `settings.nickname` pre-set to a value containing
  digits (simulating a nickname saved by a build that predates the letters-only rule) → after init,
  it's cleaned to letters-only, matching what `GW.SetNickname` would have produced.
- **INT-INIT-09 (idempotency)**: Run init twice in a row with no state changes in between → second
  run is a complete no-op relative to the first (every field identical, no double-pruning issues,
  no accidental re-randomization of anything).

### 2.6 Realistic SavedVariables fixtures

Rather than only hand-built minimal fixtures, include at least one integration test that loads a
*realistic*, messy snapshot resembling actual data seen during this session's testing (legacy
top-level `game` singular key from an ancient build, flat un-guild-scoped date keys mixed with
proper guild-scoped ones, a nickname with a trailing digit, no `accountId`/`charNicknames` at all)
and confirms:

- **INT-FIXTURE-01**: Init does not throw against this data.
- **INT-FIXTURE-02**: Legacy/orphaned keys (the stray `game` singular table, the flat date-keyed
  leaderboard entries) are left in place, inert — not actively migrated or deleted, matching the
  current design's "tolerate, don't migrate" stance for pre-existing unknown shapes.
- **INT-FIXTURE-03**: Normal operations (play a guess, set a nickname, print the leaderboard)
  work correctly afterward despite the messy starting state.

### 2.7 Cross-version compatibility

There is no "old" build of this addon to run in the test harness, so these tests describe the
*current* code's side, not a real two-version simulation:

- **INT-COMPAT-01**: Any addon message with an unrecognized prefix (constructed by hand, not
  necessarily matching any real historical format) → `HandleAddonMessage` does not throw and does
  not change any state. This is what makes a hypothetical future client's new message type (or a
  hypothetical old client's now-removed message type) safe to receive.
- **INT-COMPAT-02**: The `RESULTS:` format has exactly 4 comma-separated fields per entry in the
  current code, with no fallback/legacy parsing branch present — confirmed by INT-WIRE-01/02 above;
  no additional test needed here beyond noting explicitly that (per the CLAUDE.md history) an
  earlier design *did* have a 5-field fallback-parsing branch for this message type, and it was
  deliberately removed. A future change that reintroduces field-count branching into `RESULTS:`
  parsing should be treated as suspicious and cross-checked against this spec.

---

## 3. UAT-level behavior (manual, in-game checklist)

Not automatable. Format: numbered steps a human tester performs in-game, with the expected
observation. Organize as a checklist to run through after any UI-file change, or before a release.

### 3.1 First open / empty state

1. **UAT-FIRST-01**: `/wordle` with no prior play today → grid empty, correct date shown, "6
   guesses remaining", input box focused and visible.
2. **UAT-FIRST-02**: Today tab (default) shows "No results yet" when nothing's been played in the
   guild yet today.
3. **UAT-FIRST-03**: Streak label (top of game column) is blank when there's no current streak and
   no best (both zero).

### 3.2 Playing

4. **UAT-PLAY-01**: Type a valid 5-letter guess, press Enter → tiles reveal with correct
   green/yellow/grey colors, on-screen keyboard updates to match, remaining-guesses count
   decrements.
5. **UAT-PLAY-02 (duplicate letters)**: Guess a word with a repeated letter where the answer has
   only one instance → exactly one occurrence is colored (green or yellow), the other grey — visual
   spot-check of UNIT-GUESS-04/05/06.
6. **UAT-PLAY-03**: Win → win message shown ("Genius!"/etc. per guess count), input row hidden,
   "Share results now" button enabled with correct label.
7. **UAT-PLAY-04**: Lose (6 wrong guesses) → word reveal message shown, input row hidden, share
   button enabled.
8. **UAT-PLAY-05**: Invalid guess (not 5 letters, or not a real word) → inline error message shown,
   guess NOT added to the grid, remaining-guesses count unchanged.
9. **UAT-PLAY-06**: Reopen the window after already finishing today → shows the completed grid
   read-only, no input row, correct win/loss message still displayed.
10. **UAT-PLAY-07**: Click "Submit"/"Enter" button with the mouse instead of pressing Enter on the
    keyboard → identical behavior to pressing Enter.

### 3.3 Today's leaderboard

11. **UAT-LB-01**: After playing, own result appears on the Today tab under the current nickname
    (not raw character name, unless nickname happens to equal it).
12. **UAT-LB-02**: Guildmates' results (from another test account/character) appear after their
    broadcast is received — either immediately (if online together) or after the periodic
    re-broadcast / a `/reload` + login sync.
13. **UAT-LB-03**: Sort order: solved entries before unsolved; among solved, fewer guesses first;
    ties broken alphabetically by displayed name.
14. **UAT-LB-04**: Hovering a row shows a tooltip with the name, guess count/solved state, and the
    colored pattern squares matching the actual guesses made.
15. **UAT-LB-05**: Two alts on the same account, both played today, same guild → both appear as
    separate rows under the same nickname; hovering each reveals "Played as \<CharacterName\>" with
    the correct distinct character name per row.
16. **UAT-LB-06**: A single-character player's row does NOT show "Played as" in its tooltip (since
    nickname equals character name, the line is correctly suppressed).

### 3.4 Streak tabs

17. **UAT-STREAK-01**: "Streak" tab shows only accounts with an active (non-zero) current streak;
    an account whose streak just broke — which now means **only** skipping a day, not losing —
    disappears from this tab without needing anyone to reload.
17b. **UAT-STREAK-01b**: Lose today's puzzle deliberately → the streak label above the grid goes
    *up*, not to "Streak broken", and the account stays on the "Streak" tab.
18. **UAT-STREAK-02**: "Best" tab shows every account that has ever had a non-zero best, including
    ones with a currently-broken streak.
19. **UAT-STREAK-03**: Switching between Today/Streak/Best tabs always shows current data — no
    stale content from a previous session or a previous tab view.
20. **UAT-STREAK-04**: The game-column streak label (top-left) matches what the Streak/Best tabs
    show for the current player specifically.

### 3.5 Nickname

21. **UAT-NICK-01**: Opening the window pre-populates the nickname box with the current nickname
    (not blank, not a placeholder) — this is the specific regression check for the bug where it
    showed blank after the `charNicknames` crash.
22. **UAT-NICK-02**: Typing a new nickname and pressing Enter commits it, box loses focus, chat
    confirms the change.
23. **UAT-NICK-03**: Typing a new nickname and clicking elsewhere (not pressing Enter) also commits
    it (click-away save).
24. **UAT-NICK-04**: Typing input with no letters at all (e.g. `"123"`) and pressing Enter → clear
    rejection message, nickname unchanged, box reverts to showing the actual current nickname.
25. **UAT-NICK-05**: Typing an accented name (é, ñ, etc.) → accepted and displayed correctly
    everywhere (box, Today tab, Streak tabs, tooltips).
26. **UAT-NICK-06**: Renaming while the Today tab is the active/visible one → the leaderboard
    updates to show the new name immediately, without switching tabs away and back.
27. **UAT-NICK-07**: Renaming while a Streak tab is active → same immediate-update check for that
    tab.
28. **UAT-NICK-08**: Rename propagates to a second guildmate's client within one periodic broadcast
    cycle (or immediately via login `SYNC_REQ`), without that guildmate needing to do anything.

### 3.6 Window chrome

29. **UAT-CHROME-01**: Dragging the resize grip smoothly scales the whole window between its
    min/max bounds, all elements scaling together (nothing overlaps or clips at either extreme).
30. **UAT-CHROME-02**: The chosen scale persists — close and reopen the window (or `/reload`) and
    it's restored.
31. **UAT-CHROME-03**: The window is draggable by its title bar AND by clicking-and-dragging on a
    leaderboard row (which also still opens a tooltip on hover without accidentally starting a drag
    on a simple hover).

### 3.7 Sharing

32. **UAT-SHARE-01**: Auto-share checkboxes (Guild/Party/Raid) reflect saved state on reopen and
    toggling one updates the setting immediately.
33. **UAT-SHARE-02**: Finishing a game with a checkbox checked AND currently in that channel type →
    a result message posts to that chat channel automatically.
34. **UAT-SHARE-03**: Finishing with a checkbox checked but NOT currently in that channel (e.g.
    "Party" checked but solo) → no message posted to that channel, no error.
35. **UAT-SHARE-04**: "Share results now" button is disabled with progress text while the game is
    still in progress, and becomes an enabled "Share results now" action button once the game ends.
36. **UAT-SHARE-05**: Clicking "Share results now" after toggling a checkbox on post-completion →
    posts to the newly-checked, currently-joined channels.

### 3.8 Reset commands

37. **UAT-RESET-01**: `/wordle reset` wipes only today's in-progress/completed puzzle for the
    current character — leaderboard/streak/nickname data untouched.
38. **UAT-RESET-02**: `/wordle reset-leaderboard` wipes all guilds' results and streak leaderboards
    and this account's own streak — today's in-progress puzzle (if any) is untouched.

### 3.9 Dev mode / error visibility

39. **UAT-DEV-01**: `/wordle dev` toggles with a clear on/off chat confirmation each time, and the
    setting persists across `/reload`.
40. **UAT-DEV-02**: With dev mode OFF, deliberately trigger an error in an unrelated test addon (if
    available) → nothing prints from GuildWordle.
41. **UAT-DEV-03**: With dev mode ON, same unrelated-addon error → prints via GuildWordle's handler
    with the `[GuildWordle DEV]` prefix.
42. **UAT-DEV-04**: Regardless of dev mode on/off, an error originating from GuildWordle's own code
    always prints with the plain `[GuildWordle]` prefix (no toggle needed) — this is the property
    that should make a repeat of this session's silent-failure debugging loop impossible going
    forward.

### 3.10 Multi-account / guild simulation (mirrors how this session was actually tested)

43. **UAT-MULTI-01**: Two separate WoW accounts, same guild, both playing the same day → both see
    each other's results, nicknames, and streak updates within one periodic cycle or immediately
    via login sync.
44. **UAT-MULTI-02**: One account with two characters in different guilds → results/streaks/
    nicknames from one guild never appear while playing a character in the other guild.

---

---

## 4. Dev panel (`GuildWordle_Dev.lua`)

An in-game panel that simulates the things a single client can't otherwise exercise: what the UI
does when *other* clients talk to it. Bound to the same `/wordle dev` switch as error visibility —
dev mode on means the panel is up — and persisted, so it survives a `/reload` (which matters,
since reload-time bugs are exactly the ones worth having it open for).

Fake guildmates are injected by handing genuine addon-message strings to the real
`HandleAddonMessage`, **not** by writing to the DB directly, so what appears on screen is what a
real guildmate's broadcast would actually produce, parsing included. All fake characters/accounts
carry a `Zzt` prefix so cleanup can find them unambiguously.

**Safety:** injected data lands in real SavedVariables, which the 5-minute gossip ticker would then
broadcast to the real guild — fake players would appear on real guildmates' boards. The panel's
**Isolate** toggle (ON automatically whenever the panel opens) replaces the three outgoing
broadcast functions with no-ops. Turning it off, or closing the panel, restores normal
broadcasting. Closing the panel also turns dev mode off, so "dev mode ⟺ panel visible" stays true.

- **DEV-01/02**: An injected result becomes a real leaderboard entry with the right
  guesses/solved/pattern, and its nickname resolves through `charNicknames` — i.e. the injection
  exercises the display path, not just storage.
- **DEV-03**: The 8-result set contains both solved and unsolved entries, so sort order
  (solved first, then fewest guesses, then alphabetical) is actually observable.
- **DEV-04**: The scroll set yields 30 distinct rows — enough to exercise scrolling and the
  `ROW_POOL_SIZE` cap.
- **DEV-05**: Long / exactly-15 / accented / Cyrillic nicknames survive the wire round-trip intact,
  and truncation of them never ends on a dangling UTF-8 lead byte.
- **DEV-06**: Streak injection produces both active and broken-with-a-best entries, so "Streak" and
  "Best" tabs show visibly different sets.
- **DEV-07**: The simulated rename updates in place — the row count is unchanged and the old
  nickname is gone, not duplicated. (This is the bug that shipped once.)
- **DEV-07b**: The rename reaches **both** boards. A real rename sends `NICKS:` *and* `STREAKS:`
  (`GW.SetNickname` broadcasts both), because the two boards carry the nickname differently: the
  results board looks it up from `charNicknames`, the streak board stores it as a field on the
  entry. An action sending only `NICKS:` updates the Today tab and leaves Streak/Best showing the
  old name — a state no real client can produce. This shipped broken once.
- **DEV-08**: The stale-echo action cannot revive a broken streak, but `best` still rises —
  demonstrating the freshness gate and best-only-increases rules together.
- **DEV-09**: Forced win/loss produce a coherent finished game (`guesses`/`results` same length, or
  `CurrentGame()`'s corruption repair would wipe it) and a matching own-result row.
- **DEV-10**: The streak helpers set 5/10, and the "break" helper produces a stale `lastDate` that
  reads as broken immediately. Note the only way to *break* a streak is a date gap — "Force loss"
  will extend it, which is itself worth eyeballing after this rule change.
- **DEV-10b**: Those helpers also push the result onto the guild streak board, or the tabs keep
  showing whatever was there before.
- **DEV-10c**: Every action that changes local state out-of-band triggers a **full-window** refresh
  via `GW.RefreshMainUI`, not just `GW.OnStreakBoardUpdate`. The left-column streak label, share
  button and grid are refreshed by file-local functions in `GuildWordle_UI.lua` that otherwise only
  run on frame-show — without the full refresh those actions repainted the tabbed panel and left the
  label stale until the window was closed and reopened. This shipped broken once.
- **DEV-11**: "Clear fake data" removes every `Zzt`-prefixed entry from all three tables and leaves
  real data untouched.
- **DEV-12/13**: Panel visibility follows `devMode`; `/wordle dev` toggles both together; re-showing
  after hiding reuses the frame rather than rebuilding it.
- **DEV-14 (SYNC_REQ preview)**: `SYNC_REQ` is the one action that's about *outgoing* behavior —
  a guildmate asking "catch me up", answered by re-broadcasting everything known. That's invisible
  in the usual testing setup twice over: every broadcast function early-returns when not in a
  guild (so a guildless test character sees nothing), and Isolate replaces those same functions
  with no-ops (so even in a real guild there'd be nothing to watch). The action therefore
  *captures* the outgoing messages rather than sending them, and prints the wire payload — which
  works solo and with Isolate on. It reaches past Isolate to the stashed real broadcasters, so the
  preview reflects genuine behavior.
- **DEV-14b**: `IsInGuild` is temporarily forced true to get past those early-returns. It is a
  Blizzard global other addons read, so it must be restored on **every** path including the error
  path — verified by forcing a broadcast to throw mid-capture.
- **DEV-14c**: The reply is never actually empty: `BroadcastStreak`/`BroadcastCharNicknames` call
  `RecordOwnStreakEntry`/`RecordOwnCharNickname` first, so even a brand-new client announces its
  own (zero) streak and nickname. `RESULTS` is the only one of the three that can legitimately
  have nothing to send.

## 5. UI render robustness (`GuildWordle_UI.lua`, partial automation)

`GuildWordle_UI.lua` *can* be loaded against the mock, but the mock's geometry is meaningless
(widths/heights stub to 0) — so **nothing here tests layout**; that stays manual UAT (section 3).
What is automated is the render paths' robustness against awkward data, which is where every
UI-surfacing crash actually lived: the panel hit a nil table or missing field and took unrelated
code down with it.

Note these tests assert **both** that rendering doesn't throw *and* that the panel didn't print an
internal error. A bare no-throw check is insufficient, because `SafeUpdateLBPanel` swallows throws
by design — a broken render would otherwise register as a pass.

- **UI-01/02**: Renders cleanly with an empty leaderboard, and with a populated one.
- **UI-03/04 (regression)**: Renders cleanly with `charNicknames` / `streakBoard` set to `nil` —
  the exact shape of the reported in-game crash.
- **UI-05**: Renders more entries than the row pool holds.
- **UI-06**: Renders long, accented, and Cyrillic nicknames.
- **UI-07**: Renders a finished game's own result, after both a win and a loss.
- **UI-08**: Renders a leaderboard entry whose `pattern` field is missing — one bad row (e.g. from
  a truncated gossip message) must not blank the whole panel.
- **UI-09**: Renders outside a guild.
- **UI-10**: A forced error inside the render path is contained and reported by
  `SafeUpdateLBPanel`, not propagated to the caller.
- **UI-11**: A rename mid-session re-renders without error and refreshes the nickname lookup
  synchronously.

---

## Open questions for review

1. **Test-only export surface.** Several high-value unit/integration tests above (`HandleAddonMessage`
   parsing in particular — arguably the highest-risk, fiddliest code in the addon) require calling
   functions that are currently `local` to `GuildWordle.lua` and not reachable from outside it. The
   plan is to add a small, clearly-marked block like:
   ```lua
   GW._test = { HandleAddonMessage = HandleAddonMessage, EvaluateGuess = EvaluateGuess, ... }
   ```
   at the very end of the file — harmless to ship (a few extra function references nobody else
   reads), but it does slightly widen the "public" surface of the file. Alternative: exclude
   `tests/` from the packaged CurseForge zip (there's currently no `.pkgmeta`, so nothing is
   excluded today) and don't worry about it either way. Preference?
2. **RESOLVED — Lua version for the test runner.** Vanilla Lua 5.1 couldn't be built from source
   (local git/Xcode toolchain is broken), but `brew install luajit` pulls a **precompiled bottle**
   (no local compilation needed) of LuaJIT, which implements Lua 5.1 semantics and reports
   `_VERSION == "Lua 5.1"`. Verified directly: it reproduces the exact `malformed pattern (missing
   ']')` error WoW threw on the old byte-range nickname pattern, which Lua 5.5 did not catch, and
   confirms the current `FilterLetters` fix is correct under real 5.1 pattern-matching semantics.
   The test suite runs under `luajit`, not a newer Lua.
3. **UAT automation.** None of section 3 can run unattended. If that's ever worth revisiting (e.g.
   via a WoW UI-testing addon/framework, if such a thing exists for Classic), it'd be a separate,
   later effort — not blocking on it now.
