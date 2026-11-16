# Contributing

Bug reports and pull requests are welcome. For anything larger than a fix, open an issue first so the approach can be agreed before you spend time on it. The project is deliberately small: per-app volume and mute, and little else.

## Building and testing

```bash
./build.sh --test
```

This runs the unit tests, makes a release build in `dist/`, and verifies the bundle. A pull request needs it to pass. While developing:

```bash
source Scripts/env.sh
swift build "${SWIFTPM_FLAGS[@]}"
swift test "${SWIFTPM_FLAGS[@]}"
.build/debug/NotchmixProbe                       # what discovery sees right now
.build/debug/NotchmixProbe --snapshot panel.png  # render the panel with sample data
```

`Scripts/env.sh` keeps every cache and temporary file inside the project folder.

## Rules for the audio thread

`Sources/CAudioRender` runs on Core Audio's real-time thread. Code there must not:

- allocate or free memory
- take a lock, or wait on anything
- call into the Swift or Objective-C runtime
- log, or do any file or network I/O

State shared with the rest of the app goes through lock-free C11 atomics. Anything you add to the render path needs a test in `RenderTests.swift`.

## Rules for everything else

- Every Core Audio call happens on the engine's serial queue, never on the main thread.
- A failure must end with taps removed, which returns an app to normal playback. Losing control is acceptable; leaving an app silent is not.
- No third-party dependencies.
- New logic comes with tests. Code that can only run against live audio hardware should be kept thin, with the decisions in something testable.

## Your responsibility for what you submit

You are the author of your contribution, whatever tools helped you write it. That means you have read and understood every line, you have run it, and you have the right to submit it under the [MIT licence](LICENSE).

If an AI assistant wrote a substantial part of a change, say so in the pull request description. Do not paste in code copied from other projects unless its licence allows it and you say where it came from.

## Pull requests

- Keep each pull request to one change.
- Describe what it does and how you tested it.
- Commit messages: a short summary line, then why the change was needed.
