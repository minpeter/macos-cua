# JSON Output And Automation

Human-readable stdout is the default.

Add `--json` only when you need machine-readable output for:

- automation
- tests
- logging
- structured post-processing

Examples:

```bash
swift run macos-cua --json state
swift run macos-cua --json onboard --no-wait
```

`--json` is useful for agents and scripts, but it is not the primary human-oriented path in the README.

For stateful multi-step automation, keep `macos-cua` invocations serialized.
When using the shell, prefer `&&` chaining over parallel process launch so a
later `keypress` cannot race ahead of an earlier `type` or `click`.

Errors return a nonzero exit status and a structured
`{"error":{"code":"...","message":"..."}}` object with `--json`; human errors
go to stderr. A failed activation is an error, not an activated result.
If a post-click crop fails, the error explicitly states that the click already
occurred. Do not automatically repeat the click when retrying the capture.

Put global `--json` and `--relative` flags before the command. Repeated flags,
unknown flags, conflicting modes, and extra positional arguments are rejected.
Signed action and scroll integers must fit a 32-bit signed integer.
`wait` accepts only integer milliseconds from 0 through 20000.
Native window IDs are different: `window activate` accepts a positive
CoreGraphics `UInt32` ID, through 4294967295. An in-range ID is not necessarily
a live or activatable window.

## Command Output Fields

The [command matrix](README.md#command-matrix) lists accepted command flags and
positional arguments. Global flags occur before the command and may appear in
either order; each can occur only once. `--relative` is supported only by
`state`, `screenshot`, `move`, `mousedown`, and `click`; all other commands
reject it. It never transforms text, key names, scroll deltas, or native IDs.

| Command family | JSON result |
| --- | --- |
| `doctor` | `accessibility`, `screenRecording`, `syntheticInputReady`, `screenshotReady`, `allReady`, `actionSpace`, foreground records |
| `onboard` | macOS permission status and setup guidance; readiness is not permission to change settings automatically |
| `state` | `defaultCoordinateSpace`, `defaultCoordinateFallback`, `pointerScreen`, nullable `pointerWindow`, `held`, `releaseHints`, foreground records, `actionSpace`, modal state; relative mode adds `pointerRelative` |
| `cursor-position` | `pointerScreen`, nullable `pointerWindow`, `defaultCoordinateSpace` |
| `screen-size` | `actionSpace: {x,y,width,height}` for the primary screen |
| `screenshot` | `path`, effective `target`, `bounds`, `coordinateSpace`, `coordinateFallback`, `image: {width,height}`, `width`, `height`, `actionSpace`; capture metadata distinguishes units, source dimensions and content |
| `move`, `mousedown` | requested coordinates, observed `screenPoint`, coordinate metadata, `profile`; mousedown also has `button` and `mouseAction` |
| `mouseup` | `button`, `mouseAction`, `screenPoint` at release |
| `click` | `accepted: true`, observed `pointerScreen`, `inputUnits: null`; optional post-crop fields describe the image and click point |
| `type` | `accepted: true`, `pointerScreen: null`, `inputUnits` in UTF-16 units |
| `scroll` | requested `dx`, `dy`; these are native macOS CG pixel-scroll inputs, not Windows wheel detents |
| `keypress` | requested `keys` after successful event submission |
| `wait` | `ms` |
| `clipboard get` | `text` |
| `clipboard set` | `ok`, `length` (Swift character count) |
| `clipboard copy`, `clipboard paste` | `ok` after shortcut submission |
| `app list`, `window list` | arrays of app/window records, not an object wrapper; unavailable window IDs are null |
| `app activate`, `window activate` | confirmed `ok` plus selected/foreground records; failure is a nonzero structured error |
| `open-url` | `ok`, `url`, and browser-tool guidance |

Event submission acknowledgements do not prove that an arbitrary target
application consumed text, shortcuts, clipboard pastes, or scrolling. Inspect
that application's resulting state. Native scroll granularity and direction
are controlled by the macOS event/application path; do not reinterpret the
reported deltas as a portable Windows pixel distance.

On the tested AppKit text view, `scroll 0 120` delivered
`scrollingDeltaY=120`, `deltaY=12`, and `hasPreciseScrollingDeltas=true`;
`scroll 0 1` delivered `scrollingDeltaY=1` with approximately `deltaY=0.1`.
Negative inputs preserved their sign; horizontal inputs behaved analogously.
These are measured native event values, not a promise that every application
scrolls its content by the same distance.

The Bunshin descriptor exposes exactly `cua.screenshot`,
`cua.cursor_position`, `cua.screen_size`, `cua.click`, and `cua.type`.
Its text argument follows `type --` so text such as `--fast` remains literal.
Readiness must be checked in the context that actually launches the sidecar:
macOS privacy permissions can differ between SSH and the configured agent.
