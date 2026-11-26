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
- `Tests/KiCadKitTests`: tests against the THRH_Node (Roomy v4) sample board.

```sh
swift test
swift run kicad-inspect Tests/KiCadKitTests/Fixtures/THRH_Node.kicad_pcb
```
