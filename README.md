# vo

`vo` is an on-device live transcription and translation CLI for macOS 26+.

https://github.com/user-attachments/assets/6c11b6bc-395f-4593-8eca-856c4e7fbc93

## Features

- Live transcription via Apple's [`SpeechTranscriber`](https://developer.apple.com/documentation/speech/speechtranscriber) (on-device, no network)
- Live translation via [`TranslationSession`](https://developer.apple.com/documentation/translation/translationsession) (on-device)
- Bidirectional / multi-locale interpretation via comma-separated `--src` / `--dst` (e.g. `--src en-US,ja-JP --dst ja-JP,en-US` in one process)
- Mic and system speaker captured as separate channels
- On-disk audio file as input via `--input` (any format `AVAudioFile` reads), runs as fast as the analyzer can keep up
- Strict source-order output, even when translations arrive out of order
- TTY and JSONL output modes (auto-detected)
- Wall-clock timestamps and audio time range per chunk
- Transcription confidence per chunk (mean + min) in JSONL output
- Optional voice processing (echo cancellation + noise reduction)
- Environment diagnostics via `--doctor`

## Install

**homebrew tap:**

```console
$ brew install k1LoW/tap/vo
```

> [!IMPORTANT]
> `vo` is distributed as an ad-hoc signed binary. macOS attaches `com.apple.quarantine` to the downloaded tarball at the network-stack layer, so the formula runs `xattr -cr` against the installed binary in its `install` step to strip the attribute. Without this step, Gatekeeper would block the binary from launching on first run.

**manually:**

Download the binary from the [releases page](https://github.com/k1LoW/vo/releases), then strip the quarantine attribute and place it on your `PATH`.

```console
$ tar -xzf vo_*_darwin_arm64.tar.gz
$ xattr -cr vo
$ chmod +x vo
$ mv vo /usr/local/bin/
```

> [!IMPORTANT]
> `xattr -cr` strips `com.apple.quarantine` that macOS attaches to downloaded archives. Without it, Gatekeeper blocks the ad-hoc signed binary from launching.

## Usage

```console
$ vo                                  # Listen to mic + speaker, transcribe only
$ vo --src en-US --dst ja-JP          # Transcribe and translate
$ vo --no-speaker                     # Mic only
$ vo --no-mic --src en-US --dst ja-JP # Speaker only, with translation
$ vo --input meeting.m4a              # Transcribe an on-disk audio file instead
$ vo --select-device                  # Pick & pin the mic / speaker at startup
$ vo --json | jq                      # JSONL output for piping
$ vo --doctor                         # Environment diagnostics
```

`vo` opens the mic and system audio simultaneously, transcribes each channel with `SpeechTranscriber`, optionally translates each finalized chunk with `TranslationSession`, and prints results as you speak. Press `Ctrl-C` to stop and see a summary.

### TTY output

```
vo 0.6.0 — listening on mic + speaker (en-US → ja-JP)
  mic      MacBook Pro Microphone  (default)
  speaker  External Headphones     [pinned]

08:34:56 [mic]  How are you doing?
                元気ですか？
08:34:58 [spk]  I'm fine, thanks.
                元気だよ、ありがとう。
```

Under the header, one line per active channel shows the device it is capturing from. A dim note reads `(default)` when the channel follows the system default device (and rebinds automatically if that default changes), or `[pinned]` when `--select-device` locked the channel to a specific device.

The `[mic]` / `[spk]` label is shown only when both channels are active; with `--no-mic` or `--no-speaker` it is omitted and the timestamp alone marks each line. The timestamp shares the channel's tint (amber for mic, teal for speaker), so a single glance tells you which side just spoke.

Translation lines are shown in dim text under the source. Pairs are emitted in source order, so a slow translation holds back subsequent pairs to keep the output coherent.

### JSONL output

`--json` forces JSONL. When STDOUT is not a TTY, JSONL is selected automatically.

```jsonl
{"seq":0,"channel":"mic","timestamp":"2026-06-10T08:34:56.234+09:00","audio":{"start":0.124,"end":1.582},"src":{"lang":"en-US","text":"Hey, Tim.","confidence":{"mean":0.83,"min":0.62}},"dst":{"lang":"ja-JP","text":"ねえ、ティム。"}}
```

`dst` is present only when `--dst` is given. `seq` is monotonic across both channels. `audio.start` / `audio.end` come from `SpeechTranscriber.Result.range`.

`src.confidence` reports the transcription's per-chunk confidence, with `mean` weighted across the chunk and `min` taken from its least-confident run. This is acoustic confidence rather than a correctness guarantee, so a low `min` is a useful cue that a chunk is worth re-listening to. There is no counterpart for `dst`, because the translation framework exposes no quality score. The object is omitted only when no confidence value is available.

### Live interpretation with `say`

`vo --json` emits each finalized translation as soon as it is ready, so piping `dst.text` into `say` turns `vo` into an on-device live interpreter. No network, no API key.

```console
$ vo --src ja-JP --dst en-US --no-speaker --json \
    | jq -r --unbuffered '.dst.text // empty' \
    | while read -r line; do say -v Samantha "$line"; done
```

`jq --unbuffered` flushes each line as it arrives, so `say` speaks each chunk the moment `vo` finalizes it. `say -v '?'` lists installed voices.

### Device selection

By default `vo` captures from the system default microphone and output device and follows them. If the default input or output changes mid-session (you switch output, or plug in headphones), `vo` rebuilds that channel on the new default and keeps going instead of stopping. A device that is not ready yet is retried with a backoff for several minutes, since a Bluetooth headset can stay busy for seconds while it switches between its playback and headset profiles.

`--select-device` instead prompts you to pick the mic and speaker device at startup and pins the choice, so a later system-default change is ignored and the chosen device stays in use. The picker writes its menu to stderr and reads your choice from stdin, so `vo --select-device --json > out.jsonl` keeps stdout pure JSONL while you select. It needs a terminal for stdin and stderr, so it errors out when stdin is piped.

A pinned device that is unplugged mid-session goes quiet rather than rebuilding, so re-run `vo` to pick a new one. The startup banner shows which device each channel is using, with a `(default)` or `[pinned]` note.

### Voice processing

`--voice-processing` turns on Apple's voice IO (echo cancellation + noise reduction + AGC). Useful when running mic + speaker on the same physical device without headphones. The trade-off is that the macOS audio session enters communication mode, which lowers system speaker volume while `vo` is running. Off by default.

### Transcribing from a file

`--input PATH` reads an on-disk audio file and feeds it through the same `SpeechTranscriber` + `TranslationSession` pipeline as live capture. Any format `AVAudioFile` accepts works (wav, m4a, mp3, caf, aiff, and so on). Processing is bounded by what the analyzer can do per chunk rather than by the file's playback length, so a long recording finishes in a fraction of its runtime on Apple Silicon.

```console
$ vo --input meeting.m4a --src en-US --dst ja-JP > meeting.jsonl
```

Mic and speaker capture are bypassed in this mode. `--input` is mutually exclusive with `--no-mic`, `--no-speaker`, `--voice-processing`, and `--select-device`; passing any of those alongside `--input` errors out with a message naming the conflict. `audio.start` / `audio.end` in the JSONL line up with the file's own timecode, so a downstream consumer (e.g. an SRT writer) can use them as the playback timeline directly.

File reads are paced by the analyzer's drain rate via a bounded internal buffer, so memory stays small even for multi-hour files. A mid-stream read failure (truncated, corrupt, or disconnected-volume file) exits with an error naming the path, rather than silently producing a partial transcript.

### Bidirectional translation

`--src` and `--dst` accept comma-separated locale lists, position-paired. Each `--src` entry runs its own `SpeechTranscriber` in parallel, and the matching `--dst` entry is the translation target for that source.

```console
$ vo --src en-US,ja-JP --dst ja-JP,en-US
```

The command above turns `vo` into a single bidirectional interpreter. English speech becomes Japanese output, and Japanese speech becomes English output, all from one process.

For each utterance, `vo` listens with every `--src` transcriber in parallel, waits up to 300 ms after the first finalized candidate so slower locales can contribute, and emits the candidate with the highest `src.confidence.mean`. Its translation is routed to the position-paired `--dst`. `seq` is assigned at decision time, so the renderer's strict source-order guarantee still holds. A late candidate that overlaps an already-emitted utterance is dropped so the same utterance is never doubled.

A same-language pair such as `--dst ja-JP,ja-JP` short-circuits the Translation framework (which rejects same-language pairs as unsupported) and passes the source text through as `dst.text`. The TTY view skips the redundant translation line in that case, while JSONL keeps `dst` present so consumers see a stable schema.

The single-locale form (`--src en-US --dst ja-JP`) takes a fast path with no buffering and no timer, so its behaviour and latency match earlier releases.

```console
$ vo --src en-US,ja-JP --dst ja-JP,ja-JP   # English in to ja, Japanese in passthrough
$ vo --src en-US,ja-JP                     # transcribe-only, language auto-picked per utterance
```

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--src` | system locale | Source locale(s), BCP-47. Comma-separated for auto-detect (e.g. `en-US,ja-JP`); each entry must be in `SpeechTranscriber.supportedLocales` |
| `--dst` | (none) | Target locale(s), BCP-47. Comma-separated and position-paired with `--src` (e.g. `--src en-US,ja-JP --dst ja-JP,en-US` for bidirectional interpretation). Omit to skip translation |
| `--no-mic` | (off, mic on) | Disable microphone capture |
| `--no-speaker` | (off, speaker on) | Disable system audio capture |
| `--select-device` | off | Interactively pick (and pin) the mic / speaker device at startup. Needs a terminal |
| `--voice-processing` | off | Apply echo cancellation on mic input |
| `--input <path>` | (none) | Transcribe an on-disk audio file instead of live mic / speaker. Mutually exclusive with `--no-mic` / `--no-speaker` / `--voice-processing` / `--select-device` |
| `--json` | | Force JSONL output |
| `--transcript <path>` | (none; prompts at exit in TTY) | Stream finalized chunks as JSONL to `<path>` incrementally. Skips the interactive save prompt |
| `--doctor` | | Print full environment diagnostics and exit |

`vo --doctor` lists supported locales, installed speech models, available translation languages, and audio input devices. Run it first if something behaves unexpectedly.

## Requirements

- macOS 26+
- Apple Silicon (Neural Engine)
- TCC permissions: Microphone, Speech Recognition, and Audio Recording (speaker capture is on by default; disable it with `--no-speaker`)

### Permissions attach to vo, not your terminal

A bare CLI normally hands its TCC prompts to the **terminal emulator** that launched it, which means every other command you run in that terminal would then share the Microphone / Audio Recording grants. `vo` avoids that: on startup it re-execs itself as its own TCC responsible process, so the prompts and the grants attach to **`vo`** (shown as `vo` under System Settings > Privacy & Security), not to Terminal.app / iTerm2.

> [!IMPORTANT]
> Because the released binary is ad-hoc signed, its signature changes with every release, so macOS re-prompts for permissions after each `vo` update. Granting again attaches to the same `vo` entry (it does not pile up duplicates). A stable code signature removes the re-prompt entirely; build with `VO_CODESIGN_IDENTITY` set (see Build) if you want grants to persist across rebuilds.

This relies on a private macOS API and only applies to the released / `scripts/build.sh` binary (which embeds the required usage descriptions). A plain `swift build` binary has no embedded `Info.plist`, so it falls back to the terminal's identity. If the re-exec fails for any reason, `vo` logs a notice to stderr and continues rather than refusing to start.

## Models

`vo` runs entirely on-device, so the speech and translation models for your languages must be present locally.

- **Speech model** (`--src`): downloaded automatically on first run. `vo` prints `Downloading speech model for <locale>…` to stderr and blocks until it finishes, so the first launch takes a few extra seconds.
- **Translation model** (`--src` → `--dst`): cannot be downloaded by `vo`. macOS only installs translation languages through a system UI, so install the pair yourself via **System Settings > General > Language & Region > Translation Languages**, then re-run. If the pair is missing, `vo` exits at startup with instructions instead of failing on every line.

Run `vo --doctor` to see which speech models are installed and which translation languages are available on this device.

> [!NOTE]
> Downloading a translation language in System Settings does **not** auto-download the matching speech model, and vice versa. They are separate assets.

## Troubleshooting

Run `vo --doctor` first. It reports the macOS version, which speech models are installed, the available translation languages, and the audio input devices, and most setup problems surface there.

**Nothing is transcribed.** Check the TCC permissions. `vo` needs Microphone, Speech Recognition, and (unless `--no-speaker`) Audio Recording. If you denied any, enable them under System Settings > Privacy & Security, then restart `vo`. Also confirm the grants reached `vo` itself. The signed `scripts/build.sh` and Homebrew binaries claim `vo`'s own TCC identity, so the grants attach to the `vo` entry; a plain `swift build` binary has no embedded usage descriptions and runs under the launching terminal's identity instead, so its grants attach to your terminal app, which is easy to overlook. Prefer the signed binary. Finally, make sure `--src` matches the spoken language; on the first run for a locale `vo` blocks while it downloads the speech model (a `Downloading speech model…` line on stderr).

**The speaker side transcribes nothing while the mic works.** Look at the startup banner. The `speaker` line names the output device `vo` is capturing from, and `vo` only hears audio that actually plays through that device. If an app (a meeting client, for instance) is set to output to a different device than the one shown, its audio never reaches `vo`. Point the app's output at the same device, or pin the right one with `--select-device`. Restarting `vo` alone does not help when the system default never changed, because `vo` re-reads that same default on each launch.

**A device disappears mid-session and that channel goes quiet.** An unpinned channel follows the system default and rebuilds on the new one automatically. A channel pinned with `--select-device` does not follow, so an unplugged pinned device stays silent. Re-run `vo` to pick another.

**The mic keeps re-transcribing what the speakers play.** That is acoustic feedback between the speaker and the mic. Use headphones, drop one side with `--no-mic` / `--no-speaker`, or enable `--voice-processing` (echo cancellation, at the cost of lower system volume).

**Output is JSONL when you expected the live view, or the reverse.** `vo` prints the ANSI live view only when STDOUT is a TTY and emits JSONL otherwise, so piping or redirecting switches it to JSONL. Pass `--json` to force JSONL explicitly. The startup banner and the per-channel device lines appear only in the TTY view.

**Translation is missing or shows `[translation failed]`.** A missing or unsupported `--src → --dst` model is caught at startup, where `vo` exits with install instructions rather than running. Install the pair via System Settings > General > Language & Region > Translation Languages (see Models), then re-run. A `[translation failed: <error>]` line is a different case. It is a runtime failure of that one chunk's translation, with the cause in the message, while the rest of the session keeps going. Transcription itself works without `--dst`.

## Build

```console
$ swift build                 # debug build
$ ./scripts/build.sh          # release + embed Info.plist + ad-hoc codesign
```

For a signature stable across rebuilds (so permission grants persist across `vo` updates instead of re-prompting), pass a signing identity:

```console
$ VO_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build.sh
```

A self-signed code-signing certificate created in Keychain Access works too; any identity with a stable designated requirement keeps the cdhash steady so macOS stops re-prompting after each build.

## License

[MIT License](LICENSE)
