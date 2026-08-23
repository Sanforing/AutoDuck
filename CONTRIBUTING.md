# Contributing

Thanks for looking under the hood. AutoDuck is small on purpose; good contributions keep it that way.

**Before a big change, open an issue** so we can agree on the shape. Small fixes: just send a PR.

## Setup

```sh
Scripts/build-app.sh --run      # SwiftPM release build → build/AutoDuck.app, launched
open Package.swift              # or work in Xcode
```

macOS 14+, Xcode 15+ (Xcode 26 used for development). No dependencies.

## What helps most right now

- **Real-room test reports.** Follow `docs/TESTING.md` on your Mac and open an issue with
  the numbers (Mac model, speakers, volume, what triggered / what was missed). Detection tuning is
  the whole game.
- Bug reports with the unified log:
  `/usr/bin/log show --predicate 'subsystem == "com.autoduck.app"' --last 5m --info`
- Localisation (EN and Traditional Chinese first).

## Ground rules

- Audio never touches disk or network. PRs that add telemetry, analytics, or uploads won't be merged.
- Keep the UI calm: no windows, no notifications, no dock icon.
- Error messages say what happened and what to do; jokes go in marketing, not in errors.
- Contributions are accepted under the GPLv3, same as the project. The AutoDuck name and mascot are
  trademarks (see `TRADEMARK.md`).
