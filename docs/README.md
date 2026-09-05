# Docs

This directory holds the non-homepage material for `macos-cua`.

Start here when the default absolute-coordinate workflow is not enough.

## Guides

- [Relative mode and resized images](relative-mode.md)
- [Coordinate model](coordinate-model.md)
- [Model resolution guide](model-resolution.md)
- [JSON output and automation](json-output.md)
- [Runtime selection guide](runtime-selection.md)

## Command Matrix

Global syntax: `macos-cua [--json] [--relative] <command>`.
Arguments containing spaces must be passed as one quoted argument.

| Command | Purpose |
| --- | --- |
| `doctor` | Inspect Accessibility, Screen Recording, capture readiness and primary action space |
| `onboard [--wait\|--no-wait] [--timeout seconds] [--no-request] [--no-open]` | Guide macOS permission setup; never substitute Windows service setup |
| `state` | Inspect foreground, coordinates, held input and modal state |
| `cursor-position` | Report observed screen/window pointer coordinates |
| `screen-size` | Report the primary action-space dimensions |
| `screenshot [--screen] path.png [window\|screen]` | Capture the selected window or primary screen |
| `screenshot [--screen] --region x y w h path.png` | Capture a visible desktop region in the selected coordinate space |
| `move x y [--screen] [--fast\|--precise]` | Move the pointer |
| `mousedown x y [left\|right\|middle] [--screen] [--fast\|--precise]` | Move and hold a mouse button |
| `mouseup [left\|right\|middle]` | Release a button at the current pointer |
| `click x y [left\|right\|middle] [--screen] [--fast\|--precise] [--post-crop path.png]` | Click and optionally capture a diagnostic crop |
| `scroll dx dy` | Scroll horizontally and vertically |
| `keypress key[+key...]` | Send a validated key combination with native macOS modifiers |
| `type [--fast] [--] text` | Type one text argument, at most 8192 UTF-16 units |
| `wait ms` | Wait 0 through 20000 milliseconds |
| `clipboard get` / `clipboard set text` | Read or replace clipboard text |
| `clipboard copy` / `clipboard paste` | Copy the selection or paste the current clipboard |
| `app list` / `app activate query` | Discover or activate an application |
| `window list` / `window activate id` | Discover windows or activate an exact native ID |
| `open-url url` | Open a URL using the system handler |

Cross-platform command names do not imply identical OS behavior. macOS uses
logical points, native `cmd` modifiers, Accessibility and Screen Recording.
Windows uses its native coordinate units, modifiers and interactive execution
setup. Capture occlusion and application activation remain subject to each OS.

## Research

- [Movement anti-bot notes](research/movement-anti-bot.md)
