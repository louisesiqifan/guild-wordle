#!/bin/bash
# Produces a simulated RELEASE build in a temp dir and prints its path.
#
# The sed expressions below are copied verbatim from BigWigsMods/packager's
# release.sh (toc_filter / lua_filter, "non-debug" build type) so this mirrors
# what CurseForge actually publishes rather than approximating it. Getting
# this wrong is not theoretical: the .lua filter wraps debug blocks in a LONG
# COMMENT (--[==[ ... ]==]), which behaves differently from commenting each
# line, and the .toc filter deletes lines outright.
#
# Used by release_check.lua to prove the addon still loads and plays with the
# developer-only files genuinely absent.

set -e
SRC="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"

# toc_filter debug true -- delete debug blocks, uncomment non-debug blocks
sed -e "/#@debug@/,/#@end-debug@/d" \
    -e "/#@non-debug@/,/#@end-non-debug@/s/^#[[:blank:]]\{1,\}//" \
    -e "/#@\(end-\)\{0,1\}non-debug@/d" \
    "$SRC/GuildWordle.toc" > "$OUT/GuildWordle.toc"

# lua_filter debug -- turn debug blocks into long comments (width "==")
for f in GuildWordle.lua GuildWordle_UI.lua; do
    sed -e "s/--@debug@/--[==[@debug@/g" \
        -e "s/--@end-debug@/--@end-debug@]==]/g" \
        -e "s/--\[===\[@non-debug@/--@non-debug@/g" \
        -e "s/--@end-non-debug@\]===\]/--@end-non-debug@/g" \
        "$SRC/$f" > "$OUT/$f"
done

cp "$SRC/words.lua" "$OUT/words.lua"

# Deliberately NOT copied, mirroring .pkgmeta's ignore list: GuildWordle_Dev.lua,
# tests/, CLAUDE.md. Their absence is the whole point of this build.

echo "$OUT"
