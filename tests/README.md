# GuildWordle tests

## Running

```sh
brew install luajit     # one-time
./tests/run_all.sh
```

Or a single suite: `cd tests && luajit unit_streak.lua`

## Use LuaJIT, not `lua`

WoW embeds **Lua 5.1**. LuaJIT implements 5.1 semantics; Homebrew's `lua`
(5.4/5.5) does not, and the difference is not academic — this addon shipped a
`gsub` pattern that worked fine under 5.5 and threw
`malformed pattern (missing ']')` in-game under WoW's 5.1, breaking the
nickname feature outright. A suite passing under 5.4/5.5 proves less than it
appears to. `run_all.sh` requires `luajit` and refuses to fall back.

## Layout

| File | Contents |
|---|---|
| `BEHAVIOR_SPEC.md` | Plain-language spec of expected behavior, with stable IDs (`UNIT-*`, `INT-*`, `UAT-*`). Written and reviewed **before** the tests; every test names the ID it covers. |
| `wow_mock.lua` | Mocks the WoW globals `GuildWordle.lua` touches (identity, date/time, addon messages, frames, error handler). Controllable "now" so date-dependent logic is testable. |
| `harness.lua` | Loads the mock + the real `words.lua`/`GuildWordle.lua` into one global env, mirroring how WoW loads an addon. Exposes `freshDB()`, `setDate()`, `fireEvent()`. |
| `runner.lua` | ~130-line test runner. No external dependency, deliberately — a broken local toolchain already cost this project time; the tests shouldn't add another thing that can break. |
| `unit_*.lua`, `integration.lua` | The suites. |
| `../GuildWordle_Dev.lua` | The in-game dev panel (not a test file, but what section 3's manual UAT is driven with). |

## Coverage

145 automated tests. Spec sections 1, 2, 4 and 5 are automated. **Section 3
(UAT) stays a manual in-game checklist** — the mock's geometry is meaningless
(widths stub to 0), so layout/visual behavior can't be asserted headlessly.

For manual UAT there's an in-game **dev panel** (`GuildWordle_Dev.lua`, opened
with `/wordle dev`) that simulates other clients talking to yours: injecting
fake guildmate results, nicknames, streaks, renames, stale echoes and
`SYNC_REQ`. It feeds real message strings through the real receive path, so
what you see is what a real guildmate's broadcast would produce. Keep its
**Isolate** toggle on (default) so fake data can't reach your real guild.

Regression tests exist for every bug that reached the user in-game:

| Test ID | Bug it pins down |
|---|---|
| `UNIT-INIT-01`, `INT-INIT-04` | `CharKey()` concatenating a nil `GetRealmName()`, aborting `InitDB()` and leaving `charNicknames` nil for the whole session |
| `UNIT-NICK-14` | The `[\0-\64...]` byte-range pattern that only fails under Lua 5.1 |
| `UNIT-WORD-06` | `GW.todaysWord` never primed → `attempt to index local 'answer'` on every guess |
| `UNIT-HEAL-01..04` | Nil `charNicknames`/`streakBoard` at every call site that touches them |
| `UNIT-PARSE-13/14`, `INT-GOSSIP-04` | Stale gossip echo reviving a broken streak |
| `UNIT-STREAK-06` | An alt's loss wiping a streak the first character already earned that day |
| `UNIT-NICK-08` | Byte-based truncation splitting a multi-byte character |
| `UNIT-ERR-*`, slash/event dispatch tests | The silent-failure class generally — errors must surface, not vanish |

The suite was validated by reintroducing two of these bugs and confirming the
relevant tests fail (and only those), then restoring.

## Adding tests

1. Add the case to `BEHAVIOR_SPEC.md` first, with an ID.
2. Write the test referencing that ID in its name.
3. Confirm it fails against the unfixed code before you fix it.

## Notes

- `GW._test` at the bottom of `GuildWordle.lua` exposes file-local internals
  (`InitDB`, `HandleAddonMessage`, `EvaluateGuess`, …). Nothing in the addon
  reads it; it exists so the highest-risk code — wire parsing and
  SavedVariables bring-up — is reachable from tests at all.
- Each suite runs in its own process: `GuildWordle.lua` has top-level side
  effects (installs an error handler, creates its event frame), so a fresh
  process per file keeps them from stacking.
- "Two clients" in the gossip tests = two `GuildWordleDB` tables plus two
  character identities, swapped between calls, with broadcast output fed
  manually into the other client's message handler. There's no real network.
