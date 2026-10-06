# ADR-0008: Shared software renderer

- **Status:** Accepted
- **Date:** 2026-10-07

## Context

The source architecture suggests Direct2D/DirectWrite, Core Graphics/Core Text and Wayland/X11 + FreeType/HarfBuzz per platform. Three rendering stacks cost too much, carry too much uncertainty, and make deterministic golden tests hard.

## Decision

- One framework-owned software rasterizer (`libs/ui/render`) outputs a BGRA pixel buffer. Text uses stb_truetype + the embedded Inter font + a runtime fallback to the system CJK font.
- Platform backends only handle windows, input, DPI and pixel presentation: macOS AppKit (Objective-C runtime), Windows Win32, Linux X11 (pure Zig wire protocol).
- Products cannot ship HTML, CSS, native code or custom pages; they can only configure a logo, accent, copy and license.
- Values from external platform design skills are expressed through tokens; no platform UI framework is introduced.

## Consequences

- Offscreen rendering produces identical pixels on every platform, so golden tests are deterministic.
- Text shaping is limited (no complex-script shaping); RTL gets layout mirroring only. Accessibility bridges (UIA, NSAccessibility, AT-SPI) are deferred, but the SemanticTree is generated and tested now.
