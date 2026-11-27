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

Navigation: pinch, ⌘-scroll, ⌘+ (also ⌘ numpad + or ⌘⇧1) / ⌘− to zoom (a mouse wheel zooms directly), two-finger scroll, drag or the arrow keys to pan (Shift moves further), ⌘0 to fit, click to select, Esc to clear the selection.

- Tabs above the board: All active layers, then each copper layer (⌘1, ⌘2, …).
- Layers: green check marks switch layers on and off; click a colour swatch to change its colour (right-click to reset).
- View: rulers (⌘R, click a ruler to cycle mm → in → pt → mil, drag from a ruler to place a guide, drag a guide back onto its ruler to remove it, View › Clear All Guides), origin marker (click it to move the origin to the next board corner), Flip X (⇧⌘X) and Flip Y (⇧⌘Y).
- Dimensions on User.Drawings: overall board size and mounting-hole spacing.
- File: Page Setup (⇧⌘P), Print (⌘P), and Export to PDF (true scale), PNG, SVG, HP-GL, GLB and USDZ.

## Design checks

The Findings panel (right side) runs deterministic checks when a board opens, in two clearly separate sections:

- **KiCad rules**: the board's own rules from the `.kicad_pro` (board setup minimums, net class clearances) and the `.kicad_dru` (custom rules, with the last matching rule winning as in KiCad). A custom rule whose condition uses something the checker does not understand is listed under "Rules not checked" instead of being guessed.
- **Fab limits**: JLCPCB or PCBWay, picked at the top of the panel. Each limit lives in a data file in `Sources/KiCadKit/Profiles/` with the fab's page, the wording on it and the date it was checked. Values not confirmed word for word give warnings, not errors, and so do silkscreen limits.

Checked: copper clearance (tracks, pads, vias, zone fills), hole to copper, hole to hole, copper to board edge, track width, via size, drill and annular ring, pad drill, slot width and annular ring, silkscreen line width and clearance to pads, text height and thickness, board thickness. Not checked yet: connectivity (unrouted nets), zone fill rules, courtyards and solder mask. Use KiCad's own DRC for those.

- **KiCad DRC cross-check**: the "Cross-check with KiCad DRC" button runs `kicad-cli pcb drc` (from KiCad in /Applications) on the same file and lists its violations, unconnected items and parity problems in a third section, so the two can be compared.

Click a finding to zoom to it. Checks › Next / Previous Finding (⌘] / ⌘[), Run Checks Again (⇧⌘K), Copy Findings as Text (⇧⌘C).

```sh
swift run kicad-inspect board.kicad_pcb --check jlcpcb   # or pcbway, or kicad
```
