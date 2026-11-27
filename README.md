# PCB Review

A personal macOS app (Swift/SwiftUI) for reviewing KiCad 10 board files.

Planned:
1. KiCad 10 `.kicad_pcb` / `.kicad_pro` / `.kicad_dru` reader
2. Board view with layer toggles
3. Deterministic DRC and JLCPCB / PCBWay fab-rule checks with clickable findings
4. Separately labelled AI review

## Layout

- `Sources/KiCadKit`: the reader library (no UI). Parses `.kicad_pcb`, `.kicad_pro` and `.kicad_dru` into a board model in absolute millimetre coordinates.
- `Sources/kicad-inspect`: a small command line tool that prints a summary of a board.
- `Sources/PCBReview`: the SwiftUI macOS app (board view, layers, inspector). Built only on macOS.
- `Tests/KiCadKitTests`: tests against the THRH_Node (Roomy v4) sample board.

```sh
swift test
swift run kicad-inspect Tests/KiCadKitTests/Fixtures/THRH_Node.kicad_pcb
```

## Running the app (macOS)

```sh
swift run PCBReview Tests/KiCadKitTests/Fixtures/THRH_Node.kicad_pcb
```

Or open `Package.swift` in Xcode and run the `PCBReview` scheme, then use File › Open Board (⌘O).

Navigation: pinch, ⌘-scroll or ⌘+ / ⌘− to zoom (a mouse wheel zooms directly), two-finger scroll, drag or the arrow keys to pan (Shift moves further), ⌘0 to fit, click to select, Esc to clear the selection.

- Tabs above the board: All active layers, then each copper layer (⌘1, ⌘2, …).
- Layers: green check marks switch layers on and off; click a colour swatch to change its colour (right-click to reset).
- View: rulers (⌘R, click a ruler to cycle mm → in → pt → mil, drag from a ruler to place a guide, drag a guide back onto its ruler to remove it, View › Clear All Guides), origin marker (click it to move the origin to the next board corner), Flip X (⇧⌘X) and Flip Y (⇧⌘Y).
- Dimensions on User.Drawings: overall board size and mounting-hole spacing.
- File: Page Setup (⇧⌘P), Print (⌘P), and Export to PDF (true scale), PNG, SVG, HP-GL, GLB and USDZ.
