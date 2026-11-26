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

Navigation: pinch or ⌘-scroll to zoom (a mouse wheel zooms directly), two-finger scroll or drag to pan, ⌘0 to fit, click to select, Esc to clear the selection.
