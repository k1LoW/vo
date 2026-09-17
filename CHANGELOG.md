# Changelog

## [v0.9.1](https://github.com/k1LoW/vo/compare/v0.9.0...v0.9.1) - 2026-09-17

### Fix bug 🐛
- fix: keep capturing across a Bluetooth device switch by @k1LoW in https://github.com/k1LoW/vo/pull/48
### Dependency Updates ⬆️
- chore(deps): bump the dependencies group with 2 updates by @dependabot[bot] in https://github.com/k1LoW/vo/pull/44

## [v0.9.0](https://github.com/k1LoW/vo/compare/v0.8.1...v0.9.0) - 2026-06-26

### New Features 🎉
- feat: --src / --dst take locale lists for bidirectional translation by @k1LoW in https://github.com/k1LoW/vo/pull/42

## [v0.8.1](https://github.com/k1LoW/vo/compare/v0.8.0...v0.8.1) - 2026-06-24

### Other Changes
- feat: parallelize per-chunk translation with bounded fan-out by @k1LoW in https://github.com/k1LoW/vo/pull/39
- feat: anchor --input timestamp to the file's audio timeline by @k1LoW in https://github.com/k1LoW/vo/pull/40

## [v0.8.0](https://github.com/k1LoW/vo/compare/v0.7.1...v0.8.0) - 2026-06-24

### New Features 🎉
- feat: transcribe an on-disk audio file via --input by @k1LoW in https://github.com/k1LoW/vo/pull/37
### Dependency Updates ⬆️
- chore(deps): bump actions/checkout from 6.0.3 to 7.0.0 in the dependencies group by @dependabot[bot] in https://github.com/k1LoW/vo/pull/35
### Other Changes
- docs: show piping vo --json into say as a live interpreter by @k1LoW in https://github.com/k1LoW/vo/pull/38

## [v0.7.1](https://github.com/k1LoW/vo/compare/v0.7.0...v0.7.1) - 2026-06-21

### Other Changes
- refactor: unify Core Audio property-read boilerplate into shared helpers by @k1LoW in https://github.com/k1LoW/vo/pull/30
- Revert "refactor: unify Core Audio property-read boilerplate into shared helpers" by @k1LoW in https://github.com/k1LoW/vo/pull/33
- refactor: decompose Pipeline.runChannel into resampler/translator/drain helpers by @k1LoW in https://github.com/k1LoW/vo/pull/31
- Revert "Revert "refactor: unify Core Audio property-read boilerplate into shared helpers"" by @k1LoW in https://github.com/k1LoW/vo/pull/34

## [v0.7.0](https://github.com/k1LoW/vo/compare/v0.6.0...v0.7.0) - 2026-06-19

### New Features 🎉
- feat: put audio offsets on a shared session timeline by @k1LoW in https://github.com/k1LoW/vo/pull/28

## [v0.6.0](https://github.com/k1LoW/vo/compare/v0.5.1...v0.6.0) - 2026-06-16

### New Features 🎉
- feat: select mic / speaker device interactively at startup by @k1LoW in https://github.com/k1LoW/vo/pull/23
- feat: follow the system default device instead of stopping on change by @k1LoW in https://github.com/k1LoW/vo/pull/24
- feat: show the capture device for each channel in the startup banner by @k1LoW in https://github.com/k1LoW/vo/pull/26
### Other Changes
- docs: add a Troubleshooting section to the README by @k1LoW in https://github.com/k1LoW/vo/pull/27

## [v0.5.1](https://github.com/k1LoW/vo/compare/v0.5.0...v0.5.1) - 2026-06-12

### Other Changes
- fix: drop float artifacts from JSONL confidence and audio offsets by @k1LoW in https://github.com/k1LoW/vo/pull/21

## [v0.5.0](https://github.com/k1LoW/vo/compare/v0.4.0...v0.5.0) - 2026-06-12

### New Features 🎉
- feat: emit per-chunk transcription confidence under src.confidence by @k1LoW in https://github.com/k1LoW/vo/pull/19
- feat: stop gracefully when the audio device changes mid-session by @k1LoW in https://github.com/k1LoW/vo/pull/20

## [v0.4.0](https://github.com/k1LoW/vo/compare/v0.3.0...v0.4.0) - 2026-06-11

### New Features 🎉
- feat: attribute TCC permissions to vo, not the launching terminal by @k1LoW in https://github.com/k1LoW/vo/pull/16

## [v0.3.0](https://github.com/k1LoW/vo/compare/v0.2.1...v0.3.0) - 2026-06-11

### New Features 🎉
- feat: use a Core Audio tap for speaker capture to drop Screen Recording by @k1LoW in https://github.com/k1LoW/vo/pull/14
- feat: resolve speech and translation models up front at startup by @k1LoW in https://github.com/k1LoW/vo/pull/15
### Other Changes
- test: add Swift Testing suite and CI by @k1LoW in https://github.com/k1LoW/vo/pull/11
- fix: drop script subtag from --doctor translation list by @k1LoW in https://github.com/k1LoW/vo/pull/13

## [v0.2.1](https://github.com/k1LoW/vo/compare/v0.2.0...v0.2.1) - 2026-06-10

### Other Changes
- fix: correctness and stability bugs surfaced by live runs by @k1LoW in https://github.com/k1LoW/vo/pull/10

## [v0.2.0](https://github.com/k1LoW/vo/compare/v0.1.1...v0.2.0) - 2026-06-10

### New Features 🎉
- feat: add --transcript option with exit-time save prompt by @k1LoW in https://github.com/k1LoW/vo/pull/4
- feat: lower live-caption latency via fastResults + prepareToAnalyze by @k1LoW in https://github.com/k1LoW/vo/pull/6
### Other Changes
- docs: document manual install steps and fix releases URL by @k1LoW in https://github.com/k1LoW/vo/pull/7
- feat: quiet down channel labels and tint timestamps by channel by @k1LoW in https://github.com/k1LoW/vo/pull/8

## [v0.1.1](https://github.com/k1LoW/vo/compare/v0.1.0...v0.1.1) - 2026-06-10

### Dependency Updates ⬆️
- chore(deps): bump actions/checkout from 4.3.1 to 6.0.3 in the dependencies group across 1 directory by @dependabot[bot] in https://github.com/k1LoW/vo/pull/2

## [v0.1.0](https://github.com/k1LoW/vo/commits/v0.1.0) - 2026-06-10
