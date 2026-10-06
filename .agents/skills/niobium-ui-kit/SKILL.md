---
name: niobium-ui-kit
description: Use when changing the Niobium installer UI (tokens, kit components, catalog states, screens, golden, gallery). Defines the component lifecycle, the closed node vocabulary of ZON templates, golden update discipline, and accessibility semantic tree requirements.
---

# Installer UI kit

Pipeline: `ViewModel → screen ZON template binding → UiTree → layout → DisplayList + SemanticTree → rasterizer → backend`. See [docs/architecture/ui-engine.md](../../../docs/architecture/ui-engine.md) and [docs/spec/ui-ir-v1.md](../../../docs/spec/ui-ir-v1.md).

## Where to make changes

| To change | Change here | Do not |
|---|---|---|
| Colors, spacing, font sizes, corner radii | `libs/ui/tokens/tokens.json` | Write literal colors in components |
| Values for one platform | `tokens.json` `platforms.<os>` + the `niobium-native-look` table | Special-case it in the backend |
| Component appearance or state | `libs/ui/kit/<component>/` | Draw primitives in a screen |
| Page structure | `libs/ui/screens/<screen>.zon` | Add node types that bypass the kit |
| New node type | `ui-ir-v1` spec + `libs/ui/core` + kit + catalog | Change only code without changing the spec |

## New component process

1. Register it in the node table of `docs/spec/ui-ir-v1.md` (name, properties, child node rules, semantic role).
2. `libs/ui/kit/<component>/root.zig`: `measure`, `emit` (DisplayList), `semantics`, `handleEvent`. Each function ≤ 70 lines.
3. `libs/ui/kit/catalog.zon`: list the required states `default, hover, pressed, focus, disabled` × `light, dark` × scale `1, 2` (where applicable).
4. Generate golden with `zig build golden -Dupdate=<component>`; inspect it manually in the `zig build gallery` output.
5. `tools/check` verifies that every state in the catalog has a golden file.

## Rules

- Token contrast: every pair in `contrast_pairs` ≥ 4.5:1; if `gen-tokens` fails, the build fails.
- Every interactive node must have a semantic role and name (SemanticTree), even though the MVP is not yet wired to UIA/NSAccessibility/AT-SPI.
- Text goes only through `ui_render.text`; do not call stb inside components.
- Golden may only be updated per component; state the reason for the update in the PR description.
