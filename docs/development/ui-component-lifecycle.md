# UI component lifecycle

The installer UI vocabulary is closed (see [ui-ir-v1](../spec/ui-ir-v1.md)). The bar for adding a component or variant is high: a competitor having a feature is not a reason.

## Classify the task

| Task | Minimum input | Done when |
|---|---|---|
| Fix an existing component | Reproducible input, expected and actual | Regression golden and behavior tests pass |
| Add a state or variant | Use case, why existing combinations are not enough | catalog states, golden and SemanticTree snapshots done in the same change |
| Add an IR node | ADR/spec update, capability notes for every backend | Template validation, layout, drawing, semantics and fallback tests |
| Token adjustment | List of affected components | Contrast gate passes, each affected golden reviewed individually |

## Spec template

1. Problem and scope: which install step, which user, what is not covered.
2. Reuse: can it be solved by combining existing nodes.
3. States: default, hover, pressed, focus, disabled; light/dark; 100/150/200% DPI; long text, CJK, RTL mirroring.
4. Semantics: role, name, state, keyboard operation.
5. Verification: catalog entry, golden scope, behavior tests.

## catalog

Each entry in `libs/ui/kit/catalog.zon` contains:

- `name`: the component directory name, which must have a matching sample in `catalog_samples.zig`;
- `states`: a subset of default, hover, pressed, focus, disabled, checked, fallback;
- `themes` (default light, dark) and extra `scales` (default 150, 200, in percent);
- `content`: a subset of long, cjk, rtl;
- `width`, `height`: viewport in logical pixels.

Each entry expands into the following cases, one golden per case, at the path `tests/golden/kit/<name>/<state or content>-<theme>@<scale>.png`:

- every state × every theme, at 100% scale;
- default × every theme × every extra scale;
- every content, light theme, at 100% scale.

`zig build check` verifies that the golden set is complete; kit tests verify that every case is generated deterministically and that drawing does not go outside the viewport.

The bundled font Inter covers only Latin characters, so CJK glyphs render as placeholder boxes. CJK golden only verifies line breaking and layout, not glyphs; a CJK fallback font belongs to a later slice.

## Rules

- Components accept no color, font or pixel-size parameters; visual values come only from tokens.
- Visual changes must be actually inspected in the PNGs from `zig build gallery`; screenshots do not replace behavior assertions.
- Golden updates must name a component scope: `zig build golden -Dupdate=<component>`; the scope name for page golden is `screens`. On mismatch, the actual image is written to `zig-out/golden-actual/`; update only after review.
