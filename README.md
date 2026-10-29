# Canopy

Canopy is a macOS menu bar app for church A/V teams. It does three jobs:

1. **Live captions and voice cues.** It listens to the sound board, sends a live
   transcript (and optional translations) to the church website, and turns spoken
   phrases into cues: OSC, MIDI, web requests, or whole automations.
2. **Automations.** Step-by-step jobs that run on a schedule, a trigger, or by hand:
   record on HyperDecks, offload, make proxies, rename, copy, clean up, format a
   drive, send email, start live transcription, send a cue, and more.
3. **Remote Host.** Lets a paired iPad running TailDesk see and control this Mac.

Canopy has no Dock icon. Everything is in the menu bar and the Settings window.

## Using it

- **Menu bar:** start or stop transcribing, pick audio inputs, run an automation,
  stop a running one, resume one interrupted by a crash, open the live transcript.
- **Settings → General:** open at login, updates, data backup.
- **Settings → Transcription:** audio inputs, translation, saved transcripts,
  vocabulary and corrections, sensitivity, voice cue options.
- **Settings → Automations:** build, run and duplicate automations; the run history
  sits beside them. "Describe It" drafts one from plain language.
- **Settings → Devices:** HyperDecks, network storage (Cloud Store, Synology NAS)
  and local folders, found by scan or added by hand; file naming and performance.
- **Settings → Connections:** the church website, Planning Center, email, Remote
  Host, OSC/MIDI control, live alerts and on-device AI.

Triggers for an automation: daily or one-time schedule, Planning Center service
time, OSC message, MIDI message, voice cue, or another automation.

## Requirements

- macOS 26 or later
- Network access to the devices being managed; a microphone or audio interface
  for captions

## Project structure

- `Canopy/Transcriber/` — live transcription, audio, speech, cues, Planning Center
- `Canopy/Models/` — persisted state and data types (devices, automations, settings)
- `Canopy/Support/` — services that do the work (transfer, conversion, scheduling,
  monitoring, alerts, OSC/MIDI, email)
- `Canopy/Views/` — SwiftUI Settings pages and the automation builder
- `Canopy/RemoteHost/` — screen streaming and input for TailDesk
- `ChurchKit/` — local Swift package shared with the church website tools
- `docs/` — current plans; `docs/archive/` holds finished or outdated ones

Built with SwiftUI; Sparkle handles updates. `./run.sh` builds and launches a dev
copy; `release.sh` builds a release.
