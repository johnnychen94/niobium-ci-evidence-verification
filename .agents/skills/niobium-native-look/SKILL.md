---
name: niobium-native-look
description: Maps the look and interaction conventions of macOS / Windows 11 / GNOME onto the tokens of Niobium's shared software renderer. Use when adjusting installer visuals, button order, sizes, font sizes, corner radii, focus rings, light/dark appearance, or platform differences. External GUI skills only supply values and do not change ADR-0008.
---

# Native look mapping

Niobium does not use AppKit controls, WinUI/XAML, or GTK widgets; every pixel is drawn by `libs/ui/render` (ADR-0008). The "native feel" comes from three things: platform values (tokens), platform interaction conventions (kit behavior), and real system integration (window, file picker, DPI, and dark mode detection are provided by the backend).

## Value sources and mapping

| tokens.json `platforms.<os>.*` | macOS (`apple-hig`) | Windows (`winui-app`) | GNOME (`gtk-ui-ux-engineer`) |
|---|---|---|---|
| `control_height` | 28 (recommended hit target 28×28 pt) | 32 (Fluent standard control height) | 34 (libadwaita button) |
| `radius_control` | 6 | 4 (ControlCornerRadius) | 6 |
| `radius_surface` | 10 | 8 (OverlayCornerRadius) | 12 (card/dialog) |
| `body_size` / `body_line` | 13 / 18 | 14 / 20 (Body) | 14 / 20 |
| `title_size` | 20 | 20 (Subtitle) | 20 |
| `focus_ring` | 3 (system focus ring extends outward) | 2 (two-color focus rectangle) | 2 |
| `primary_on_right` | true: primary button at the far right | false: primary button at the far left of the button group | true: suggested action on the right |

When changing values: first find the source in the corresponding external skill and record it in the "source" column of this table or in the commit message; then run `zig build golden -Dupdate=<component>` and compare all three platforms in the gallery.

## Interaction conventions

- **Default button**: Enter triggers the primary button, Esc triggers cancel; identical on all three platforms.
- **Button order**: screen templates are written in macOS/GNOME order (secondary on the left, primary on the right). When `primary_on_right = false`, `libs/ui/core/order.zig` reorders adjacent buttons in the same row during `frame.build`: back, primary, then the rest (the Windows wizard's "Back / Install / Cancel"). Do not write two per-platform variants in a screen.
- **Focus**: Tab order follows UiTree document order; the focus ring is shown only after keyboard navigation (macOS, GNOME), while Windows always shows the keyboard focus rectangle.
- **Dark mode**: the backend's `system()` reports the appearance (macOS `effectiveAppearance`; Windows registry `AppsUseLightTheme`; X11 reads `gtk-application-prefer-dark-theme` and `gtk-theme-name` from `~/.config/gtk-3.0/settings.ini` plus `GTK_THEME`, without going through the D-Bus portal), and `tokens.themeName` maps it to `ThemeName`. When the appearance changes, the backend emits an `.appearance` event, and the session re-fetches the theme and redraws.
- **High contrast**: Windows `SPI_GETHIGHCONTRAST`, macOS "Increase contrast" (`accessibilityDisplayShouldIncreaseContrast`), and GTK's HighContrast theme name all map to the two token sets `contrast_light` / `contrast_dark`, and the brand accent is ignored in that case. Screen golden generates high-contrast variants only for Windows, because only Windows high contrast rewrites all system colors.
- **Reduced motion**: macOS `accessibilityDisplayShouldReduceMotion`, Windows `SPI_GETCLIENTAREAANIMATION`, and GTK `gtk-enable-animations=false` all stop the indeterminate progress bar animation.
- **DPI**: the backend reports device pixels per 100 logical pixels, rounded to 25% steps, in the range 100-400 (macOS `backingScaleFactor`, Windows `GetDpiForWindow` and `WM_DPICHANGED`, X11 `GDK_SCALE` or `Xft.dpi`). Layout uses logical pixels; the raster is scaled up by the scale.
- **Folder picker**: macOS `NSOpenPanel`, Windows `IFileDialog` (`FOS_PICKFOLDERS`). X11 has no native picker, so `capabilities.native_folder_picker = false` and the location field is edited directly.
- **Copy**: the difference between sentence case (Windows, GNOME) and title case (macOS buttons) is not handled for now; the MVP uses sentence case everywhere.

## Out of scope

- Do not emulate frosted glass, Mica, Acrylic, or vibrancy; use a solid `surface` color.
- Do not bring in platform font rendering: system font files are also rasterized by stb_truetype. Windows loads `%WINDIR%\Fonts\segoeui.ttf` / `seguisb.ttf`; Linux tries the static weights of Ubuntu, Cantarell, Noto Sans, and DejaVu Sans in order; macOS SF exists only as a variable font, so the embedded Inter is used directly. Any load failure falls back to Inter (`libs/ui/backend/fonts.zig`).
- Do not change flow order per platform; change only appearance values and button order.
