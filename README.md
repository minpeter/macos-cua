# macos-cua

`macos-cua` is a macOS-only low-level computer-use runtime for agents.

`macos-cua` is the most compatible GUI computer-use runtime: if a human can do
it, `macos-cua` can usually do it too. It is not the optimal choice for
browser workflows or strong-a11y apps.

In a larger CU stack:

- use `macos-cua` when the task is fundamentally pointer, keyboard, screenshot,
  clipboard, or window-control work
- use Codex Computer Use when the target app exposes a strong enough
  accessibility tree that element-level actions are cleaner than coordinate
  loops
- use `bb-browser` when the task is primarily a website workflow inside a
  controlled Chrome session

If you are choosing between runtimes, see the
[runtime selection guide](docs/runtime-selection.md).

Its default path is simple:

- coordinates are absolute
- coordinates are window-first
- stdout is human-readable by default

## Install

Build locally:

```bash
swift build
```

Run with either:

```bash
swift run macos-cua <command>
```

or:

```bash
./.build/debug/macos-cua <command>
```

## Authorize

`macos-cua` needs two standard macOS permissions:

- `Accessibility` for mouse, keyboard, and window actions
- `Screen Recording` for screenshots

First check readiness:

```bash
swift run macos-cua doctor
```

Then start the built-in onboarding flow:

```bash
swift run macos-cua onboard
```

If you are running in a terminal and want it to wait for you:

```bash
swift run macos-cua onboard --wait --timeout 180
```

## Happy Path

Daily use should start with absolute coordinates.

1. Inspect the current coordinate space:

```bash
swift run macos-cua state
```

2. Capture the frontmost window:

```bash
swift run macos-cua screenshot /tmp/frontmost.png
```

3. Or Capture a region in the active coordinate space:

```bash
swift run macos-cua screenshot --region 100 100 300 200 /tmp/region.png
```

4. Move and click with absolute coordinates:

```bash
swift run macos-cua move 800 400 --precise
swift run macos-cua click 800 400 --fast
```

5. Use primary-screen coordinates only when needed:

```bash
swift run macos-cua screenshot --screen /tmp/screen.png
swift run macos-cua move 800 400 --screen --precise
swift run macos-cua click 800 400 --screen --fast
```

Coordinates are macOS logical points, not Retina backing pixels. Screenshots
are normalized to these action units. Without a usable frontmost window,
window-first commands fall back to the primary screen. `pointerScreen` and
window bounds remain screen-global; see the [coordinate model](docs/coordinate-model.md).

## Context Helpers

Keep the command surface small. Outside the screenshot-and-action loop, the
main helpers are:

- `clipboard get|set|copy|paste` for moving text across apps
- `open-url <url>` for direct URL handoff, while browser workflows should still prefer `bb-browser`
- `app list|activate` for bringing the target app frontmost
- `window list|activate` for picking the right window before resuming visual actions

Examples:

```bash
swift run macos-cua clipboard set "https://example.com"
swift run macos-cua open-url https://example.com
swift run macos-cua app activate Safari
swift run macos-cua window list
```

Use a freshly listed native window ID for exact activation. IDs can be null
when macOS cannot associate an Accessibility window with a unique native
window; a title alone is not an identity. Activation can fail and returns a
nonzero exit status rather than claiming success.

Text accepts at most 8192 UTF-16 units. Use `--` before literal text that looks
like an option:

```bash
swift run macos-cua type -- "--fast"
```

## Agent Sequencing

When an agent needs multiple stateful steps, prefer a single shell command with
`&&` so each step runs only after the previous one exits successfully.

This avoids race conditions between separate `macos-cua` processes, especially
for flows such as click -> type -> submit.

Prefer:

```bash
swift run macos-cua click 120 73 --precise \
  && swift run macos-cua type "Slack" \
  && swift run macos-cua wait 150 \
  && swift run macos-cua keypress return
```

Avoid launching independent `macos-cua` commands in parallel when order matters.
For example, do not fire `type` and `keypress return` at the same time.

## Dense UI Fallback

When a page is visually dense and the target is a small icon, URL, or toolbar
item, treat `screenshot --region` as the fallback inspection step instead of
guessing a final click from the full screenshot alone.

Recommended pattern:

1. Capture the full frontmost window for global context.
2. Take a second local crop tightly around the likely target area.
3. Re-read the local crop, then issue the final click.

Example:

```bash
swift run macos-cua screenshot /tmp/frontmost.png
swift run macos-cua screenshot --region 720 88 220 96 /tmp/toolbar-crop.png
swift run macos-cua click 812 132 --fast
```

## Model Resolution

Use absolute coordinates when your screenshot can be consumed at full useful resolution by the model. If the image must be resized or compressed before inference, switch to the relative-mode workflow in the docs.

As of 2026-04-18, public vendor docs indicate the following:

| Model | Documented vision resolution support |
| --- | --- |
| [`gpt-5.4`](https://developers.openai.com/api/docs/models/gpt-5.4) | Up to 6000 px max dimension with `detail: "original"`; 2048 px max dimension with `detail: "high"`. |
| [`gpt-5.4-mini`](https://developers.openai.com/api/docs/models/gpt-5.4-mini) | Up to 2048 px max dimension with `detail: "high"`. |
| [Claude Opus 4.7](https://platform.claude.com/docs/en/build-with-claude/vision) | Up to 2576 px on the long edge. |
| [Claude Sonnet 4.5 / 4.6 and other current Claude vision models](https://platform.claude.com/docs/en/build-with-claude/vision) | Up to 1568 px on the long edge. See the [relative-mode workflow](docs/README.md#relative-mode-and-resized-images). |

Older or weaker vision models are not recommended for coordinate-driven desktop control.

## More

Advanced workflows and reference material live under [docs/README.md](docs/README.md).
