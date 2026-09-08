# Input delivery and native dispatch

## Submission is not target consumption

Successful `type` output (`accepted: true`, `inputUnits`) acknowledges submission
of keyboard events. It does not acknowledge that the foreground application has
finished editing or rendering. For end-to-end verification, observe the intended
recipient's exact text change, with a deadline armed before typing. Measure the
submission acknowledgment and target receipt separately.

Text is sent without changing the clipboard, in payloads of at most 20 UTF-16
units without splitting surrogate pairs. Both modes use the full payload
capacity; `--fast` reduces the pacing interval. CRLF and CR normalize to LF.
Newlines use separate events because AppKit can interpret a leading newline as
an editing command and discard any suffix in the same event.

## Mouse events and context menus

Mouse events follow normal macOS dispatch. A text editor's context menu can
consume the right-button release in its tracking loop. Subsequent clicks can
target the menu window rather than the underlying editor. An editor-local
`NSEvent` monitor is therefore not a complete delivery oracle while a menu is
tracking, even when the button was released correctly.

Check native button state and the actual recipient (including menu windows),
then dismiss or interact with the menu normally before sending editor input.
The runtime does not dismiss menus automatically, duplicate clicks into the
editor, or synthesize a second release to satisfy a local monitor. A missing
editor receipt is not by itself proof of missing OS delivery.

## Activation

Activation confirms foreground identity, not merely an accepted request.
For a hidden application, the runtime observes that application's unhide
notification before requesting foreground. When Accessibility is already
authorized, it uses AXFrontmost rather than relying solely on cooperative
AppKit activation. Exact window activation also verifies the requested native
window identity. No permission prompt is introduced by activation.
