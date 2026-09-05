# Relative Mode And Resized Images

Use `--relative` only as a fallback.

When you add `--relative`, all action coordinates are interpreted as integers in `[0, 1000]` relative to the active coordinate space.

Affected commands:

- `state`
- `screenshot`
- `move`
- `mousedown`
- `click`

This mode is most useful when a screenshot was resized between capture and inference, so `image space` is no longer 1:1 with `action space`.

## When To Switch

Stay on the absolute workflow first.

Switch to `--relative` only when:

- actions repeatedly miss after an agent or model call
- a model or client stack downsamples the screenshot before inference
- you intentionally compress, tile, or otherwise remap the screenshot before reasoning

## Contract

- `0` means the top or left edge of the active coordinate space
- for pointer actions, `1000` means the last usable point (`size - 1`)
- for region origin and size, `1000` spans the full extent
- there are no alternate relative-coordinate flags or alternate ranges
- do not mix absolute logical-point coordinates with `--relative`

## Example

```bash
swift run macos-cua --relative screenshot --region 500 0 500 500 /tmp/right-half.png
swift run macos-cua --relative click 950 120 --fast
```

## Returned Values

When you run with `--relative`:

- `state` includes `pointerRelative`
- `screenshot --region ...` interprets the region in `[0, 1000]`
- returned screenshot `bounds` are reported in that same relative space

## Recommended Pattern

1. Capture and act with absolute coordinates first.
2. If actions drift after inference, suspect resize or downsampling.
3. Retry the same flow with `--relative`.
