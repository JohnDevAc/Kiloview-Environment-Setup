# Asset licensing

`setup-icon.png` and `setup.ico` are original project artwork created for
Kiloview Environment Setup.

Copyright (c) 2026 John Lightfoot. Licensed under the MIT License in the
repository root. These assets are not official Kiloview or NDI logos.

## Red and papaya identity

The 2.0.1 artwork uses a hexagonal server-and-signal badge, replacing the
previous blue link emblem. The source PNG has a transparent background.

| Role | Colour |
|---|---|
| Header / icon base | Oxblood red `#571A1C` |
| Primary actions | Vermilion `#B93627` |
| Highlights / icon rim | Papaya `#FF943F` |
| Panels | Warm ivory `#FFF8F2` |
| Body text | Warm charcoal `#331F1B` |

Windows success and error states retain distinct semantic colours. The
progress percentage sits on an ivory badge for contrast across the gradient.

`setup.ico` contains 16, 20, 24, 32, 40, 48, 64, 96, 128 and 256 pixel PNG
frames. Repackage the unchanged source artwork after replacing the PNG:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\assets\Build-Icon.ps1
.\Build-Setup.ps1
```

The ICO is embedded both as the executable's Windows icon and as a managed
resource for window/taskbar use, so the application does not inherit a host
process icon when loaded by the preview harness.

## Artwork generation

Generated with the built-in ImageGen tool on 6 September 2026. Final prompt:

> Create a new Windows desktop app icon for a server installer, square 1024x1024, transparent background outside the icon. The app sets up network video servers. Make a distinctive bold geometric server-and-signal emblem: a compact deep oxblood red (#571A1C) hexagonal badge with a papaya orange (#FF943F) beveled rim, and a very simple warm ivory two-slot server rack at its center with one papaya status dot on each slot. One broad angular papaya signal chevron extends from the right of the server stack, contained within the hexagon. Straight-on, balanced, centered, large silhouette filling about 86% of the square. Restrained soft dimensional bevels, crisp large shapes, premium industrial control-panel feel, legible as a Windows taskbar icon at 24-32px. Palette strictly deep red, vermilion red (#C63729), papaya orange, warm ivory. No text, letters, chain links, intertwined ribbons, Wi-Fi arcs, gradients to blue, cyan, purple, green, extra tiny details or cast shadow outside the badge. This is original independent app artwork, not a vendor logo.
