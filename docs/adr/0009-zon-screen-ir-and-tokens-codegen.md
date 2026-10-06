# ADR-0009: ZON screen IR and tokens code generation

- **Status:** Accepted
- **Date:** 2026-10-07

## Context

The installer needs a dedicated, closed, testable component library that avoids the complexity of a general UI framework, with a single source for visual values.

## Decision

- `libs/ui/tokens/tokens.json` is the single source for colors, type ramp, spacing, radii, motion, focus ring and contrast pairs. `tools/gen-tokens` generates a Zig module, and the build fails if any contrast pair is below 4.5:1. Generated files are not edited by hand and not committed.
- Screens are written in ZON (`libs/ui/screens/*.zon`) and parsed at comptime through `@import`. Unknown fields, missing ids and bindings to nonexistent ViewModel fields are compile errors.
- Closed IR vocabulary: Window, Stack, Card, Text, Image, Button, Checkbox, RadioGroup, Link, ProgressBar, ProgressRing, Scroll, Modal, Divider, Spacer, FolderPicker. There is no text input, no pixel coordinates and no style escape hatch; sizes are only `fixed`/`content`/`fill`.
- Components live in `libs/ui/kit/<component>/`, and `catalog.zon` lists the states for which every component must have a golden.

## Consequences

- Adding an IR node or a token category requires updating [ui-ir-v1](../spec/ui-ir-v1.md) first.
