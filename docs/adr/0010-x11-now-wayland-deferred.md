# ADR-0010: X11 on Linux first, Wayland deferred

- **Status:** Accepted
- **Date:** 2026-10-07

## Context

Without depending on GTK/Qt, Linux needs its own window and input implementation. A Wayland client needs several protocols, including xdg-shell, shm and seat.

## Decision

- v0.1 implements a subset of the X11 wire protocol in pure Zig (connection, MIT-MAGIC-COOKIE-1 authentication, CreateWindow, PutImage, events, WM_DELETE_WINDOW) without linking libX11.
- Wayland sessions run through XWayland; a native Wayland backend is recorded as deferred.
- Without a GUI session, `setup` falls back to the CLI and prints a clear notice.

## Consequences

- The Linux binary can be cross-compiled from macOS and has no dynamic GUI dependencies.
