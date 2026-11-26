# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@AGENTS.md

## Claude Code notes

- Three SwiftPM targets: `LiveIslandCore` (no UI, the only tested code), the `LiveIsland` app on top of it, and `LiveIslandCoreTests`. Logic you want tested belongs in Core; `swift build` is the quick compile check.
- Trust `swift build` over SourceKit's single-file "Cannot find … in scope" noise.
- Run one suite or test by its Swift type and function name, not the `@Suite` title: `./scripts/test.sh --filter DisplayChoiceTests` or `--filter "DisplayChoiceTests/goesWhereThePersonPicked"`. The script passes extra arguments to `swift test`.
- Builds need only the Command Line Tools and CMake (`brew install cmake`); `./scripts/build.sh` builds `build/LiveIsland.app`; the installed copy lives in `/Applications` and updates through Settings › Software Update. CI (`.github/workflows/build.yml`) runs on `macos-26` because Liquid Glass needs the macOS 26 SDK; glass calls sit behind `#available(macOS 26, *)` in `Island/Glass.swift` so macOS 14 still works.
- What the closed notch shows comes from `IslandModel.activities` → `IslandActivity.mostImportant` (priorities live in `LiveIslandCore`, so they're tested); the open island's tab follows from that activity, then `tabOrder`.
- `docs/` is the project website (static HTML), not developer docs.
- Terminal usually can't take screenshots (no Screen Recording permission); ask the user for one to check the UI.
- Your own session shows up in the island while you work on it: a "working" Claude Code session is expected, not a bug.
- Each new ad-hoc-signed build may need Calendar, Bluetooth and Automation permissions granted again.
- `open "liveisland://…"` goes to whichever copy macOS picks, often the installed `/Applications/LiveIsland.app`, which then runs next to your build. Test links with `open -a "$PWD/build/LiveIsland.app" "liveisland://…"`.
- `pkill -x LiveIsland` quits it cleanly (it handles SIGTERM and stops the media adapter); a leftover adapter from a crash is cleaned up at the next launch.
