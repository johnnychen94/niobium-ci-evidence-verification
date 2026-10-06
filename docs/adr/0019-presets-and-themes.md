# ADR-0019: Presets and themes

- **Status:** Proposed
- **Date:** 2026-10-07

## Context

The developer experience of a product's installer is in scope for Niobium. Today a product developer writes `product.json`, one `component.json` per component and a branding file by hand. Then they run `nbpack keygen`, `component build`, `publish`, `config` and `bundle` ([nbpack CLI](../../apps/user-docs/src/content/docs/reference/nbpack-cli.md)). Nothing generates a starting point, and the installer window can be seen only after a full pack. The look of the installer window can be changed only through `branding`: product name, publisher, accent colour, texts and logo ([cli-v1](../spec/cli-v1.md)).

## Decision

Proposed:

- A **preset** is versioned data in this repository that describes a starting point for one kind of product. The first presets are a desktop application, a command-line tool, an Electron application and a background service.
  - A scaffold command, tentatively `nbpack init --preset <name> --out <dir>`, expands a preset into ordinary `product.json`, `component.json` and branding files, plus a `build.zig` fragment that uses the build API.
  - The generated files belong to the developer. A preset has no meaning after generation: `setup`, the engine and the repository never read presets.
  - A preset can contain only fields that the existing schemas accept. Each preset is generated, decoded strictly, built and installed in the e2e suite.
- A **theme** is one of a closed set of named token sets shipped with Niobium, selected by name in `branding`.
  - A theme changes token values only: colours, corner radii, spacing and type scale. It adds no layout, components, markup or styling language, so [ADR-0008](0008-shared-software-renderer.md) and [ADR-0009](0009-zon-screen-ir-and-tokens-codegen.md) still hold.
  - The accent contrast rule (4.5:1 on light and dark) still applies to the brand accent on top of any theme.
- A **preview** renders the installer screens for a given product config and theme without packing a release, reusing the golden and gallery pipeline.

Open questions, to settle before this ADR is accepted:

- How does a theme combine with the per-platform look of [niobium-native-look](../../.agents/skills/niobium-native-look/SKILL.md)? Does a theme replace platform tokens, or adjust them within limits?
- Does a preset also choose feature modules ([ADR-0018](0018-built-in-feature-modules.md)), once a product config can select them?
- Is the scaffold an `nbpack` command, a build API step, or both?

## Consequences

- Adding `theme` to `branding` is a contract change: spec, schema and tests change in the same commit.
- Every theme multiplies the golden screens. Golden updates stay scoped by component (AGENTS.md section 6).
- Each preset is maintained like a test fixture: a schema change that breaks a preset fails the e2e suite.
