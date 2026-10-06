# UI engine

```text
tokens.json ──gen-tokens──► tokens module (with contrast gate)
screens/*.zon ──comptime──► static templates (binding validation)
engine state ─► ViewModel ─► bind ─► UiTree ─► layout ─► DisplayList ─► rasterizer ─► backend
                                                     └─► SemanticTree ─► (accessibility bridge, deferred)
```

- **ui_core**: closed IR, comptime template validation and binding, layout (column/row, `content`/`fill`/`fixed`), DisplayList (fill, stroke, text, image, icon, ring, clip), SemanticTree (role, name, value, state, focusable, actions), focus and input model, capability fallback diagnostics. No IO dependency.
  - Measuring and drawing of leaf nodes is injected by the kit as comptime parameters: `measure(env, node, max_width)`, `emit(env, node, placement, state, list)` (optional `overlay`).
  - Text width is provided by ui_render through the `TextMeasurer` interface.
  - `ui_core.testing` provides a monospace measurer and a minimal kit for writing tests in modules that depend on it.
- **ui_tokens**: Zig constants generated from `tokens.json` (colors, spacing, sizes, per-platform metrics).
- **ui_kit**:
  - `Kit` dispatches by node type to the component directories (`button/`, `checkbox/`, `radio/`, `text/`, `progress/`, `surface/`, `folder_picker/`, `image/`), measuring and drawing nodes into DisplayList commands. Components only read tokens and accept no color or size parameters.
  - `theme.zig`: runtime derivation of the brand accent. The light theme moves toward black and the dark theme toward white by 5% per step until both text on the accent and the accent as link text reach 4.5:1; if this is not reached within 20 steps, it is rejected with `UiAccentRejected`. hover and pressed then darken or lighten a further 10% and 20%.
  - `catalog.zon` lists each component's state, theme, scale and content variants, and `catalog.zig` generates a sample tree for each case (rules in [UI component lifecycle](../development/ui-component-lifecycle.md#catalog)).
- **ui_screens**:
  - Five ZON templates, Welcome, Options, Progress, Failure and Complete, compiled at comptime and bound to `contracts.ui.ViewModel`.
  - `model.zig` builds the initial ViewModel from the product config's `branding` and the defaults resolved by the frontend, and validates branding.
  - `Controller` turns input intents into ViewModel changes and engine commands: `start` (equivalent to the CLI's `--scope` and `--install-dir`), `cancel`, `launch`, `close`, `choose_folder`.
  - Cancel requires confirmation first; in the confirmation dialog, both Escape and Enter mean "continue".
- **ui_render**: rasterizes the display list into a `Canvas` (`u32` 0xAARRGGBB, which in little-endian memory order is BGRA, straight alpha). Distance-field-based antialiased rounded rectangles, strokes, line segments and icons; clip stack depth limited to 16 (`UiClipDepth`); stb_truetype glyph cache (keyed by font size and 1/4-pixel phase, at most 4096 entries); area-averaging image scaling; pure-Zig PNG encode/decode (decoding limited to 8-bit, 4096 per side, CRC checked). The same input produces bit-identical pixels on every target.
- **ui_backend**: one `Session` (theme, scale, interaction state, frame and canvas) paired with four window backends.
  - AppKit (`appkit.zig`): calls the objc runtime directly, registering `NiobiumView` and the window delegate at runtime; the canvas is drawn into the view as an sRGB `CGImage`.
  - Win32 (`win32.zig`): `CreateWindowExW` + `SetDIBitsToDevice` (top-down 32-bit DIB), per-monitor DPI v2, dark title bar via DWM attribute 20.
  - X11 (`x11.zig` + `x11_wire.zig`): links neither libX11 nor libc and speaks the core protocol directly over `/tmp/.X11-unix/X<n>`; `x11_wire` is pure-function encoding/decoding, unit-tested on every host; `x11.zig` handles only the socket, self-pipe wakeup and `poll`. Requires a 24-bit TrueColor, 32 bpp, LSB root visual.
  - offscreen (`offscreen.zig`): the same rendering path used by golden, gallery and tests.
  - Shared conventions (`window.zig`): coordinates are in device pixels; OS callbacks only push events into a bounded queue of capacity 64 (when full, pointer motion is dropped first), and errors are not propagated inside callbacks; `Waker` lets the worker thread wake the UI thread's `next`. `driver.zig` is the event loop: one frame every 16 ms while animating, otherwise it blocks waiting. `host.zig` connects controller commands to an `Operation` (an engine transaction), and the worker thread merges progress through a `Mailbox` and then wakes the UI thread.
  - Verification: `zig build workbench -- window --smoke` opens a window, reads back the window pixels and compares them with the canvas. AppKit reads back through the view cache (Display P3 conversion allows an error of 40 per channel); X11 uses `GetImage` and is bit-identical under Xvfb. Win32 is currently only cross-compiled; runtime verification is in vm-smoke.

## Threads

The UI thread owns the window and rendering; the engine runs on a worker thread and publishes snapshots (phase, progress, message) through a bounded queue. The UI only reads snapshots, and user actions are sent back to the engine as intents. When the heartbeat exceeds a threshold, it shows "Not responding" and offers cancel.
