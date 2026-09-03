#!/bin/bash
# Runs every GuildWordle test file and reports a combined result.
#
# Requires luajit (brew install luajit) -- NOT lua/lua@5.4. LuaJIT implements
# Lua 5.1 semantics, matching WoW's embedded interpreter; newer Lua versions
# accept pattern/string constructs that WoW rejects at runtime, so passing
# under them proves nothing. See BEHAVIOR_SPEC.md for the full rationale.
#
# Each file runs in its own process deliberately: GuildWordle.lua executes
# top-level side effects at load (installs an error handler, creates its event
# frame, registers slash commands), so a fresh process per file keeps those
# from accumulating across suites.

cd "$(dirname "$0")" || exit 1

if ! command -v luajit >/dev/null 2>&1; then
    echo "error: luajit not found. Install it with:  brew install luajit"
    exit 127
fi

FILES=(
    unit_word.lua
    unit_guess.lua
    unit_game.lua
    unit_nick.lua
    unit_streak.lua
    unit_wire.lua
    unit_resilience.lua
    unit_devpanel.lua
    unit_ui.lua
    integration.lua
    crossversion.lua
)

total_failed=0
for f in "${FILES[@]}"; do
    printf '\n=== %s ===' "$f"
    if ! luajit "$f"; then
        total_failed=$((total_failed + 1))
    fi
done

# Release build: everything above loads GuildWordle_Dev.lua, so only this can
# catch a break that appears once the developer-only files are stripped --
# a reference to a removed function, a debug block that doesn't close, or a
# .toc still naming a file that no longer ships.
printf '\n=== release_check.lua (simulated release build) ==='
if RELEASE_BUILD_DIR="$(bash build_release.sh)"; then
    if ! luajit release_check.lua "$RELEASE_BUILD_DIR"; then
        total_failed=$((total_failed + 1))
    fi
    rm -rf "$RELEASE_BUILD_DIR"
else
    echo "failed to build the release simulation"
    total_failed=$((total_failed + 1))
fi

echo
if [ "$total_failed" -eq 0 ]; then
    echo "All suites passed."
    exit 0
else
    echo "$total_failed suite(s) failed."
    exit 1
fi
