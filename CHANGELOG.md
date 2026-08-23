# Changelog

## 0.2.0 — 2026-08-24

Listening is now inaudible until the duck actually happens.

- **Fixed: music/video sounded muffled and quieter ("behind a door") whenever Mr. AutoDuck was on.**
  macOS applies a flat −15 dB duck to all other audio the moment the echo-cancelling unit starts and
  never lifts it. The app now releases its own process's duck right after the mic starts
  (`SystemDuck.swift`); the system's configurable ducking layer is set to voice-gated ("advanced")
  instead of a constant −4 dB.
- **Fixed: stuttering playback / constant engine restarts whenever a Bluetooth device was connected.**
  The engine restarted on every configuration-change notification, but on macOS 26 that notification
  usually arrives with the engine still running. Now it restarts only when the engine really stopped,
  with a back-off and a no-audio watchdog.
- **Fixed: Bluetooth headset mics (AirPods & friends) are never used for listening.** Opening one drops
  the headset into the hands-free profile — everything it plays turns muffled mono. If the default
  input is a Bluetooth mic, the app listens through the built-in mic instead (the popover shows which),
  falling back gracefully when it can't.
- **Fixed: a crash during mic start no longer bricks the app.** If a start never completes, the next
  launch comes up paused with an explanation instead of crashing on every launch.
- Added: the popover shows which microphone is in use, and why a Bluetooth mic was skipped.

## 0.1.0 — 2026-08-23

First working prototype: menu-bar app, echo-cancelled mic, classifier + level gate or Apple's
muted-speech detector, smooth system-volume ducking with user-override, test button, ⌥⌘L hotkey,
launch at login.
