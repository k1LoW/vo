# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`vo` is a macOS 26+ Apple Silicon CLI that performs **on-device** live transcription and translation. It listens to the user's microphone and the system speaker output simultaneously, transcribes both streams via Apple's `SpeechTranscriber`, optionally translates each finalized chunk through `TranslationSession`, and prints results to STDOUT. No network calls.

## Build / Run

```bash
swift build                            # debug build, produces .build/debug/vo
swift build -c release --arch arm64    # release
./scripts/build.sh                     # release + embeds Info.plist + ad-hoc codesign
.build/debug/vo --help                 # help
.build/debug/vo --doctor               # environment check (no TCC required)
```

## Test

```bash
./scripts/test.sh                      # Swift Testing suite (swift test under the hood)
```

Tests use Swift Testing (`import Testing`, `@Test`) in `Tests/voTests/`. They cover only the
TCC-free pure logic: `StreamRenderer` JSONL output (source-order commit, volatile suppression,
null-target on EOF), `VoError` messages, `detectRenderMode`, `RebindBox`, the `catchingNSException`
bridge, and the `reopenBackoffDelay` schedule. The audio / Speech / Translation
paths require TCC grants and macOS 26 hardware, so they are not unit-tested.

`scripts/test.sh` exists because on a Command Line Tools-only install (no full Xcode) the Swift
Testing framework and its `lib_TestingInterop` dylib are off the default search / rpath; the script
injects the needed `-F` / `-rpath` flags only when that layout is detected. Under full Xcode (CI's
`macos-26` runner) it runs a plain `swift test`. CI lives in `.github/workflows/test.yml`.

## Runtime requirements

- macOS 26+ (uses `SpeechTranscriber`, `SpeechAnalyzer`, `TranslationSession`, all macOS 26 only)
- Apple Silicon (Neural Engine)
- TCC permissions granted on first run: Microphone, Speech Recognition, and (unless `--no-speaker` is passed) Audio Recording. The speaker channel uses a Core Audio process tap, **not** ScreenCaptureKit, so it needs only the Audio Recording grant, never Screen Recording. When launched from Terminal.app, the grants attach to Terminal.app rather than `vo` itself unless `vo` is properly bundled and signed.
- On-device models. `Pipeline.run()` resolves both before any channel starts (once, since both channels share `--src`). The speech model for `--src` downloads headlessly via `AssetInventory.downloadAndInstall()` on first run, with a one-line `Downloading speech model…` notice on **stderr** (so JSONL on stdout stays clean). The translation model for `--src → --dst` **cannot** be downloaded headlessly (the Translation framework only downloads via a UI sheet a CLI can't present), so `ensureTranslationModel` checks `LanguageAvailability.status` up front and fails fast with `VoError.translationModelNotInstalled` (install via System Settings) or `.unsupportedTranslationPair`, rather than letting every chunk surface `[translation failed]`.

## CLI surface

Flat command (no subcommands). `--doctor` is the only "different mode"; everything else configures the live listen loop.

```
vo [--src LOCALE] [--dst LOCALE] [--no-mic] [--no-speaker]
   [--voice-processing] [--select-device] [--input PATH]
   [--transcript PATH] [--doctor] [--json]
```

- `--src` defaults to `Locale.current.identifier(.bcp47)`. Must be in `SpeechTranscriber.supportedLocales` (all regional, no bare `en` / `ja`). Unsupported values produce a helpful error suggesting matching regional variants.
- `--dst` is optional. Without it, `vo` is transcribe-only and never calls `TranslationSession`.
- `--input PATH` transcribes an on-disk audio file (any format `AVAudioFile` can read, wav, m4a, mp3, caf, aiff, …) instead of live mic / speaker. End-to-end backpressure keeps memory bounded for long files: `FileSource` is pull-based (`nextBuffer() throws -> TimedBuffer?`), and `BoundedAnalyzerInputBuffer` (`AsyncSequence` actor, capacity 8) suspends the resampler's `send` whenever the analyzer has not drained. So total in-flight PCM is one buffer in the resampler plus eight in the bounded buffer, regardless of file duration; processing speed is whatever the analyzer can sustain, not wall-clock playback length. A mid-stream read failure rethrows as `VoError.inputFileReadFailed` via `try await resampler.value` so a corrupt / truncated / disconnected-volume file is surfaced instead of being silently treated as EOF. File mode runs as a single `.file` channel with `sessionStart = 0`, so `audio.start` / `audio.end` in the JSONL line up with the file's own timecode. `timestamp` is also anchored to the file timeline rather than wall-clock processing time. The chunk's `timestamp` is computed as `(local-TZ 1970-01-01T00:00:00) + audio.start`, so in JSONL it prints as `"1970-01-01T00:00:0X.XXX±HH:MM"` and is essentially a redundant view of `audio.start`. This keeps the schema identical to live mode (still an ISO8601 string) while making sure two runs of the same file in the same local timezone produce identical JSONL (the ISO8601 offset segment changes if `TZ` differs), and the TTY `HH:MM:SS` column reads `00:00:0X`. A missing `audio.start` (invalid range) falls back to the same anchor as `audio.start = 0` (the local-TZ epoch above), not Unix epoch 00:00Z. EOF on the file closes the analyzer input, which lets `transcriber.results` drain and the channel exit naturally without SIGINT. Mutually exclusive with `--no-mic` / `--no-speaker` / `--voice-processing` / `--select-device` (each combination is rejected with its own `ValidationError`). The TCC re-exec still runs because the Speech Recognition grant attaches to vo regardless of input; the Microphone / Audio Recording grants are simply not exercised in file mode. See `FileSource` in `AudioSource.swift` and `Pipeline.runFileChannel`.
- `--voice-processing` enables AVAudioInputNode voice processing (echo cancellation + noise reduction). **Default off** because enabling it puts the OS audio session into communication mode and lowers system speaker volume. Use only when running mic + speaker on the same physical device without headphones.
- `--select-device` makes vo prompt for the mic / speaker device at startup instead of using the system defaults. It prints a numbered picker for each enabled channel (mic input from `collectInputDevices()`, speaker output from `collectOutputDevices()`), reads the choice, and **pins** the result. A pinned channel suppresses its `DefaultDeviceChangeListener` (`MicCapture` / `SpeakerCapture`), so a later system-default change is ignored and capture stays on the chosen device. An unpinned channel does the opposite. It follows the system default, and when the default changes mid-session it rebuilds the capture on the new default and keeps feeding the same analyzer (the device-follow loop in `Pipeline.runChannel`, coordinated by `RebindBox`), so the session continues instead of stopping. The reopen is retried (`reopenCapture`, `maxReopenAttempts` attempts with the `reopenBackoffDelay` schedule, roughly ten minutes in total) because a Bluetooth headset switching between its playback and headset profiles leaves the device unopenable for seconds at a time, and a single refusal used to drop that channel for the rest of the session while vo still looked healthy. The first attempt runs with no delay, so an ordinary same-format switch follows as immediately as before. Only when the whole budget is spent does the channel end, naming the last error on stderr. A pinned device that disappears is not rebuilt, so that channel goes quiet until restart. `MicCapture` pins via `kAudioOutputUnitProperty_CurrentDevice` on the input node's HAL unit; `SpeakerCapture` swaps the aggregate's anchor UID. The picker writes to **stderr** and reads **stdin**, never touching stdout, so `vo --select-device --json | jq` keeps stdout pure JSONL while still selecting interactively. It is gated on `canSelectDevicesInteractively()` (stdin **and** stderr are TTYs; stdout may be piped); otherwise it fails with a `ValidationError`. The prompt runs in `Listen.swift` after the re-exec (so it happens once, in the disclaimed child that owns stdin) and before the banner. Empty input picks the default-marked device. See `DeviceSelection.swift`.
- TCC attribution: vo always re-execs itself as its own TCC responsible process (via the private `responsibility_spawnattrs_setdisclaim`) so the Microphone / Speech / Audio Recording grants attach to vo, not the launching terminal. There is no flag; it runs unconditionally in `Listen.swift` after the `mic || speaker` validation. The re-exec is gated on the embedded `Info.plist` being present (`Responsibility.hasEmbeddedInfoPlist`), so the release / `build.sh` binary claims its own identity while a plain `swift build` binary (no usage descriptions, would be killed on mic access) stays on the terminal's identity. The parent becomes a thin launcher that waits and forwards the child's exit status; any failure falls back to running in-process. Because the released binary is ad-hoc signed, macOS re-prompts after each release (the signing identifier stays `io.github.k1low.vo`, so it's one entry, not duplicates); a stable `VO_CODESIGN_IDENTITY` removes the re-prompt. See `Responsibility.swift`.
- `--json` forces JSONL output. Without it, auto-detects: TTY → ANSI redraw, non-TTY → JSONL.
- `--transcript PATH` streams finalized chunks as JSONL into `PATH`. Without it, vo streams the same JSONL into a temp file under `TMPDIR` and at Ctrl-C asks `Save transcript to ./vo-<stamp>.jsonl? [Y/n/<path>]`. If the chosen target (or `PATH` itself) exists, vo prompts `Overwrite? [y/N]`. Memory usage stays bounded across long sessions because nothing is buffered.

## Architecture

The whole pipeline is one TaskGroup orchestrating two parallel channels (mic + speaker) that feed a single `Renderer` actor.

```
                    AVAudioEngine.inputNode  ──► MicCapture
                                                     │
                                                     ▼
            (per-channel)  AsyncStream<AVAudioPCMBuffer>  ──► AVAudioConverter
                                                                       │
                                                                       ▼
                                                          SpeechAnalyzer + SpeechTranscriber
                                                                       │
                                                                       ▼
                                                          AsyncSequence<Result>
                                                                       │
                          ┌────────────────────────────────────────────┤
                          │ volatile (partial)            isFinal       │
                          ▼                              ▼               │
                  RenderEvent.volatile        RenderEvent.finalized      │
                                                  │                     │
                                                  ▼                     │
                                          TranslationSession  ◄─────────┘
                                                  │
                                                  ▼
                                       RenderEvent.translated
                                                  │
                                                  ▼
                                          StreamRenderer (actor)
                                                  │
                                                  ▼
                                              STDOUT
```

### Files in `Sources/vo/`

| File | Role |
|---|---|
| `Vo.swift` | `@main` `AsyncParsableCommand`. Pure flag-parse and dispatch to either `runListen` or `runDoctor`. |
| `Listen.swift` | Entry point for the main capture loop. Sets up `StreamRenderer`, `Pipeline`, SIGINT handler, banner, exit summary. |
| `Pipeline.swift` | The TaskGroup orchestration. Spawns `runChannel(.mic, …)` and `runChannel(.speaker, …)` concurrently. Each channel constructs its own `SpeechTranscriber`, `SpeechAnalyzer`, and (if translating) `TranslationSession`. **Important: `TranslationSession` is a non-Sendable class; it is constructed inside the Task closure to avoid Sendable warnings — do not hoist it.** Also contains `convertBuffer` and `VoError`. |
| `AudioSource.swift` | `MicCapture` (AVAudioEngine input node) and `SpeakerCapture` (Core Audio process tap: `CATapDescription` + `AudioHardwareCreateProcessTap`, mounted on a private aggregate device with an IOProc). Both expose `AsyncStream<AVAudioPCMBuffer>`. Includes the `AVAudioPCMBuffer.copy()` extension and `CoreAudioError`. |
| `Renderer.swift` | `StreamRenderer` actor + `RenderEvent` + `ChunkTiming`. Owns the strict-order commit queue, the volatile live region, the TTY rendering, the JSONL emission, the wall-clock timestamp formatting, and the wrap-aware screen-row accounting. |
| `Doctor.swift` | `runDoctor(json:)`. Gathers OS info, speech model status, translation language list, input device list via the helpers below, then renders human text or JSON. |
| `Locales.swift` | `collectSpeechLocales()` and `collectTranslationLanguages()`. Pure data collection, no I/O. |
| `Devices.swift` | `collectInputDevices()`. Direct Core Audio enumeration via `AudioObjectGetPropertyData`. |
| `Responsibility.swift` | `Responsibility.reexecAsResponsibleProcess()`. Bridges the private `responsibility_spawnattrs_setdisclaim` and re-execs vo so TCC grants attach to vo rather than the terminal. Called unconditionally from `Listen.swift`, but gated on `hasEmbeddedInfoPlist()` (release builds only) and best-effort: returns and continues in-process on any failure. |
| `NSExceptionBridge.swift` | `catchingNSException(_:)`. Wraps the `VoObjC` target's `@try` shim so a Cocoa API that reports failure by raising (`AVAudioNode.installTap` on a format mismatch) becomes a Swift error instead of an abort. The shim lives in `Sources/VoObjC` because Swift cannot catch an `NSException` at all. |
| `SessionLog.swift` | Streaming JSONL transcript file. Two modes: explicit (`--transcript <path>` writes directly there) or temp (`TMPDIR` file moved/discarded on exit). Owns the overwrite-confirm and `Save transcript?` prompts. |

### Key invariants in `StreamRenderer`

1. **Strict source-order commit.** `commitQueue` is FIFO; pairs are emitted to scrollback only when the queue head has its translation filled in. A slow translation for chunk N blocks chunks N+1, N+2 from being committed even if their translations arrive earlier. This is intentional — the JSONL/TTY readers must never see out-of-order lines.
2. **Live region uses physical screen rows, not logical lines.** Long source text on a narrow terminal wraps, and a naive `\e[A`-based clear leaves ghost copies of the source line. `redrawLiveRegion` counts rows via `rowsNeeded(forLine:termWidth:)` which strips ANSI escapes and counts East Asian wide chars as 2 cells. **Never assume one `writeLine` = one screen row.**
3. **JSONL mode never writes the banner or summary** (`Listen.swift` checks `isTTY`). Anything other than valid JSONL going to STDOUT in `--json` mode is a bug.
4. **Volatile updates do not reach JSONL.** Only finalized chunks are emitted. The `RenderEvent.volatile` case is a no-op in JSONL mode.
5. **Timestamps are local timezone in both TTY and JSONL.** ISO8601 output uses `+09:00`-style offset, not `Z`. The TTY `HH:MM:SS` and JSONL ISO string represent the same wall-clock instant. `TZ=UTC vo …` flips both consistently.

### Channel-pair coupling

There is no global lock between the mic and speaker channels — they each construct their own `SpeechTranscriber`, `SpeechAnalyzer`, and `TranslationSession`. They share only:

- The `Renderer` actor (serializes all event handling).
- A `SeqCounter` actor (gives a monotonic `seq` across both channels so output order corresponds to which channel finalized first).

This is why the mic re-capturing speaker audio (acoustic feedback) appears as duplicate `[mic]` + `[spk]` events with similar content. `--voice-processing` is the only software mitigation we have; otherwise the user is expected to use headphones or `--no-mic`.

## Output formats

### TTY (default when STDOUT is a tty)

```
vo 0.1.0 — listening on mic + speaker (en-US → ja-JP)

08:34:56 [mic]  How are you doing?
                元気ですか？
08:34:58 [spk]  I'm fine, thanks.
                元気だよ、ありがとう。
                                                        ← live region below
         [mic]  … in-progress fragment                  ← volatile, redrawn in place
```

When only one channel is active (`--no-mic` or `--no-speaker`), the `[mic]` / `[spk]` label is suppressed and source text follows the timestamp directly with a three-space gap:

```
08:34:56   How are you doing?
           元気ですか？
```

Colors (256-color palette, Terminal.app safe). Both the timestamp and the channel label use the channel's tint, so the eye reads them as one unit:

- mic timestamp + `[mic]` label: 130 (amber)
- speaker timestamp + `[spk]` label: 24 (teal)
- Translation 244 (gray, sits behind source)
- In-progress volatile fragment text: 244 (same dim as translation, so it reads as "not committed yet")
- `(translating…)`, `(no translation)`, `… ` volatile leader: 240 (darker gray)

### JSONL (`--json` or non-TTY)

One JSON object per finalized chunk. `dst` is present only when `--dst` was supplied.

```jsonl
{"seq":0,"channel":"mic","timestamp":"2026-06-10T08:34:56.234+09:00","audio":{"start":0.124,"end":1.582},"src":{"lang":"en-US","text":"Hey, Tim.","confidence":{"mean":0.83,"min":0.62}},"dst":{"lang":"ja-JP","text":"ねえ、ティム。"}}
```

`audio.start` / `audio.end` are offsets in seconds on a **shared session timeline** whose origin (`sessionStart`, a host-time instant taken once before either channel starts) is common to both channels, so mic and speaker chunks are directly comparable. Each `SpeechTranscriber.Result.range` (CMTimeRange) is relative to the samples fed to that channel's analyzer, so the resampler aligns the analyzer timeline to the shared axis using the host time each captured buffer carries (`AVAudioTime` for mic, the IOProc `AudioTimeStamp` for speaker). It pads the first buffer with silence equal to `firstSampleHostTime - sessionStart`, so analyzer time 0 lands on `sessionStart` and the chunk `range` becomes the offset directly. The `audio` object is **omitted** when the range is invalid or non-finite, because vo does not backfill an approximation, mirroring how a nil `confidence` is dropped rather than zero-filled. A consumer that needs a timecode for every chunk (e.g. an SRT writer) reconstructs the missing one from `timestamp` (always present) and neighbouring chunks, the same way it resolves channel overlap. A device-follow rebind keeps the same analyzer; because `range` advances with fed samples and not wall-clock, the reopen gap (no samples are fed while the new default device opens) is bridged with an equal span of silence (`makeSilentBuffer`), sized from the buffer host times, so offsets after the rebind stay aligned across channels rather than drifting earlier by the gap. The residual error is bounded by the buffers' host-time precision (sub-millisecond) plus the two devices' independent clock drift (ppm), not by the gap length. `seq` is monotonic across channels. `src.lang` echoes the BCP-47 form of `--src` (so `--src en` would give `"lang":"en"`, not `"en-US"`).

`src.confidence` carries the chunk's transcription confidence, aggregated from the per-run `transcriptionConfidence` attribute (requested unconditionally via `attributeOptions`). `mean` is weighted by run length and `min` is the worst run, both rounded to three decimals. It is **acoustic per-character confidence, not word correctness** (a fully wrong transcription can still score a high mean while its `min` dips), so `min` is the more actionable "re-listen here" signal. The whole `confidence` object is omitted only when no run carried a value. There is no confidence for `dst`. The Translation framework exposes no quality score, so `src.confidence` is the pipeline's only quality signal. Confidence never appears in TTY output, only JSONL/transcript.

## Distribution plan (not yet implemented)

- Ship as a bare Mach-O binary, **ad-hoc signed** (not Developer ID). `scripts/build.sh` embeds `Resources/Info.plist` into `__TEXT,__info_plist` via linker, then `codesign -s -` with `Resources/vo.entitlements`.
- Distribute via a personal Homebrew tap (`k1LoW/homebrew-tap`) as a Formula. Homebrew's `formula_installer.rb` has no quarantine code path, but macOS still applies `com.apple.quarantine` to the downloaded tarball at the network-stack / LaunchServices layer regardless of HTTP client, and `tar -x` carries the attribute over to the staged binary. The Formula's `install` step therefore runs `xattr -cr bin/"vo"` to strip it before Gatekeeper inspects the ad-hoc-signed binary. Users install with `brew install k1LoW/tap/vo`. The proper long-term fix is Developer ID signing + `notarytool`, which would remove the need for the strip; we defer that until vo's audience justifies the $99/year + CI work.
- `.app` bundle is **not** required for ad-hoc signing or for TCC; embedding Info.plist into the Mach-O is sufficient.

## Style notes

- All Swift comments are in English (per `~/.claude/CLAUDE.md` global rule).
- Source comments explain "why" only — no narration of what the code does.
- Punctuation rule for prose: avoid em dash (`—`), and avoid `:` / `-` as sentence connectors. They are allowed inside code, YAML keys, URLs, and command flags.
