# Coordinate Model

`macos-cua` is window-first by default.

## Default Behavior

- `screenshot`, `move`, and `click` use frontmost-window coordinates
- `--screen` switches them to primary-screen coordinates
- if no usable frontmost window is available, these commands fall back to the primary screen

This is the default action model and the preferred happy path.

## Native Units And Display Bounds

macOS coordinates are Cocoa/CoreGraphics logical points. A Retina display may
have multiple backing pixels per point; captured PNGs are normalized to the
logical dimensions advertised for the action space. Windows CUA instead uses
its native per-monitor-DPI-aware physical pixels. Do not copy coordinates
between operating systems or multiply macOS coordinates by the backing scale.

`actionSpace` describes the primary screen in `state`, `doctor`, and
`screen-size`, even when a window on another display is active. Window-local
coordinates translate through the window's screen-global origin.
Pointer bounds are half-open: `0 <= x < width`, `0 <= y < height`.
The translated point must belong to an actual display; an empty gap between
monitors is not a valid pointer destination.

## Diagnostics

These remain screen-global diagnostics:

- `window list`
- `state.frontmostWindow.bounds`

This makes local-to-global translation explicit instead of hiding it.

## State Fields

Use `state` to inspect the current action context:

- `defaultCoordinateSpace`
- `defaultCoordinateFallback`
- `pointerScreen`
- `pointerWindow`
- `pointerRelative` when running with `--relative`

## Region Screenshots

- default `screenshot --region x y w h` uses the active coordinate space
- with `--screen`, the region is relative to the primary-screen origin
- with `--relative`, the region is interpreted in `[0, 1000]` relative to the active coordinate space

Do not add a positional `window` or `screen` target to a region command.
Region origin and size use the full selected extent, so
`--region 0 0 1000 1000` in relative mode covers that extent exactly.
Relative pointer coordinates instead map `1000` to the last usable point,
`size - 1`.

Region captures show the composited visible desktop, including overlapping
windows. Native window captures can provide window content despite occlusion;
screen capture is not equivalent to a guarantee of offscreen or protected
content. Inspect the capture metadata and actual image rather than assuming
identical occlusion behavior across platforms. PNG output requires a `.png`
suffix; parent directories are created and completed images are published
atomically.

For dense pages and small targets, use `screenshot --region` as a second-pass
inspection step:

1. capture the full window for context
2. crop tightly around the likely target area
3. re-read that local crop before issuing the final click

## Why Absolute Comes First

When the screenshot is consumed at its useful logical resolution, absolute coordinates keep `image space` and `action space` directly aligned. That usually gives the best click precision and the easiest debugging path.
