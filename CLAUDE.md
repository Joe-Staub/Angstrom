# Angstrom axle-tube line – PlantWatch configuration

This repo is a PlantWatch configuration: the `pw*.yaml` files are the whole plant setup and
are edited either in the PlantWatch Configurator or by hand. This file is for anyone updating
it conversationally with Claude Code. The engine's own rules (grid semantics, build and
verification recipes) are in `CLAUDE.md` of the PlantWatch repo; read that too.

## What the line does

Two identical stations, **Left** (GM part 85545338) and **Right** (85545339), each with a
scanner, an axle-label printer and a stack light, sharing one box-label printer. An operator
scans a tube's ID; PlantWatch births it in the inventory database, prints its label, adds it to
the open **box** (a container item), and when the box holds **18** tubes prints the box label
and opens the next box. Boxes are serials `L00001…` / `R00001…`, sequential per side.

| Device (`pwDevice.yaml`) | Role |
|---|---|
| `Left-Side-Scanner-Net` 192.168.1.51:9004, `Right-Side-Scanner-Net` .52:9005 | Scanners, Automatic message mode (no terminator) |
| `Left-Axle-Printer` .57:9100, `Right-Axle-Printer` .58:9100 | Zebra, ZPL template `ConfigFiles/AxleLabelTemplate.zpl` (prints `${LabelData}`) |
| `Box-Printer` .55:9100 | Zebra, `BoxLabelTemplate.zpl` (prints `${LblBoxId}`) |
| `Left-Light` COM6, `Right-Light` COM7 | Stack lights, write-only binary frames |
| `ReportingScheduler` | Nightly CSV export of the day's genealogy |

Database: `PWDatabase` → `localhost\SQLEXPRESS`, catalog `PWInventory`, provider `pw`.

## Naming and conventions

- Everything per side carries a `Left`/`Right` prefix: `Left-PartId-Data`, `LeftLotLabel`,
  `Left-Error-Message`, `Left-Print-Status`, `Left-Stack-Alert`, … Older names mix `Left-X-Y`
  and `LeftXY`; keep whichever exists rather than renaming (screens and charts bind by name).
- Constants (`variableType: Constant`): `BATCH_SIZE` 18, `LEFT_CONTAINER`/`RIGHT_CONTAINER`
  (`LOT85545338`/`LOT85545339`, the box part numbers), `Left/Right-Supplier-Part-No-Constant`,
  `NOREAD`, `BLANK` (two spaces, used to "clear" a message), `LIGHT_SLEEP`, `OUTPUT_FOLDER`.
- **`Left-Stack-Alert` = 1 means an error is posted and not cleared.** While it is 1 every scan
  is ignored entirely. `Left-Flag-Error` sets it (and turns the Clear Error button red);
  `LeftAlert` additionally drives the light red; `Left-Clear-Alert` (the Clear Error button)
  resets light, button colour and flag.
- `Left-Error-Message` is the only text the operator sees; it also carries non-error notices
  ("Container Label Printed", "Label reprinted").
- Persistence group `Angstrom-Axle-Tube`: `LeftLotLabel`, `RightLotLabel`,
  `Left/Right-Production-Count` only. Box counts are **not** persisted; they live in the
  database (see below).

## Chart map (`pwLogic.yaml`)

Per side (Left shown; Right is the mirror with `Right`/`RIGHT`/`R` substituted):

- `Left-Side-Scanner_Logic` (device chart): ignore if `Left-Stack-Alert` ≠ 0 → record scan
  time and data → uppercase → NoRead? → `Left-Clear-Parsed` → RegexExtract → parsed?
  (`LeftGMPartNumber <> -`, else `Left-Parse-Error`) → own part? (else `Left-Wrong-Part`) →
  Birth (duplicate → `LeftAlert`, message, `Left-Log-Duplicate`) → `Left-Axle-Print-Label` →
  production count → `LeftAddToBatch` → consumed? (else `Left-Lot-Error`) → box full?
  (`Left-Container-Count < BATCH_SIZE` false → `Left-Box-Print-Label`, `CreateLeftLot`).
- `Left-Ensure-Box`: label known? read its lot quantity from the DB into `Left-Container-Count`;
  missing or failed → `CreateLeftLot`. Called from `Initialize` and before every add.
- `CreateLeftLot`: `DBProcedure dbo.Angstrom_NextLotNumber` → `L${LeftLotNumber:%05d}` → Birth
  with quantity 0 → count 0, persist. Failures post a message and flag the error.
- `LeftAddToBatch`: Ensure-Box, ConsumeMaterial into the box, on success
  `LotManagement IncrementLotQuantityValue` → `Left-Container-Count`.
- `Left-Axle-Print-Label` / `Left-Box-Print-Label`: fill template, write, status to
  `Left-Print-Status`; success remembers `Left-Last-Label` / `Left-Last-Box-Label`, failure posts
  the printer error and flags.
- `Left-Light-Connected` (TriggerMode **OnConnected** on `Left-Light`): clears the light when
  no error is posted, re-asserts red when one is. This is how the lights get their startup
  state; `Initialize` runs before the COM ports are open and must not talk to them.
- Screen charts: `Left-Clear-Ack-Button_Logic_1`, `Left-Reprint-Button_Logic`,
  `Left-Reprint-Box-Button_Logic` on `Screen:Left-Main/...`.
- Shared: `Initialize` (OnStart: load templates, Ensure-Box both sides), `LoadPrintTemplates`,
  `NightlyReport` → `CreateCSV`.
- **Dead charts, left in place:** `CheckLeftNoRead`, `ClearProductionCounts`, `ExtractLeftData`,
  `PrintLeftAxleLable`, and the two orphans `BTNCreateCSV_Logic_1` /
  `Reset-ProductionCounts_Logic_1` whose screen controls were removed.

## Screens (`pwGui.yaml`)

`Left-Main` (startup) and `Right-Main`, identical layouts, no navigation between them (the
runtime shows one screen; Right-Main is for a future per-station window). Each shows the last
scan, its time, production count, current box and count, the six parsed fields (year, day of
year, line, daily sequence, GM part, supplier part), the error bar, and three gradient buttons:
Clear Error (`bGColorVariable` → red on error), Reprint Last Label, Reprint Last Box Label.
When the Left layout changes, copy geometry to the Right twins (same control order; names
differ, e.g. `Label1`→`Label1_2`, `OutputText2`→`OutputText2_2`, `Label-Left-*`→`Label-Right-*`).

## Error handling model

| Situation | Message | Alert (light + lockout) | Logged to |
|---|---|---|---|
| Duplicate ID | "Duplicate Part, already in the database" | yes | `C:\AxleReports\DuplicateScans.csv` |
| ID does not parse | "Unreadable part ID" | yes | `C:\AxleReports\UnreadableScans.csv` |
| Other side's part | "Part belongs on the other line" | yes | – |
| Neither side's part | "Unknown part number N - bad read?" | yes | – |
| Consume failed | "Can't Add to Lot" | flag only | – |
| Box creation failed | "Cannot get the next box number" / "Cannot create a new box" | flag only | – |
| Printer write failed | the `Fail: …` text | flag only | – |

Every flag locks out scanning until Clear Error. CSV rows are `timestamp,side,serial`; the
charts never write a header, the files are created by hand with `Timestamp,Side,Serial`.

## Deployment checklist (new machine or the plant)

1. Run `misc/Create-Angstrom-Procedures.sql` against `PWInventory` (creates
   `dbo.Angstrom_NextLotNumber`; safe to re-run). Without it no box can be created.
2. Create `C:\AxleReports\` with `DuplicateScans.csv` and `UnreadableScans.csv` (header row).
3. Serial ports must be COM6/COM7 as Device Manager numbers them; on the Parallels dev VM use
   `PlantWatch.Simulator\Setup-Simulation.ps1 -RenamePorts`. Printer/scanner addresses on the dev
   VM are aliases on the second adapter (`Setup-Simulation.ps1 -Adapter "Ethernet 2"`).
4. **PlantWatch build dependency:** this configuration needs PlantWatch with the runtime colour
   binding and the `OnConnected` trigger (branch `feature/onconnected-and-colour-binding` until
   merged). On an older build the buttons never turn red, the lights are not cleared at
   startup, and the simulator rejects `{oneof}` in `pwSimulator.yaml`.
5. Simulator: `PWSimulate /config:<this folder>`; `pwSimulator.yaml` alternates `ESAT`/`esat`
   prefixes. `pwSimulatorState.yaml` is the simulator's counters.

## Editing safely

- Hand edits to `pwLogic.yaml` are fine but follow the grid rules in the PlantWatch CLAUDE.md;
  then **verify by loading a copy through DomainModel** (recipe there) before handing over:
  empty validation report, no invalid cells, grids printed for the charts you touched.
- If PlantWatch is open on this folder, reload the configuration there before anyone saves
  from the Configurator, or the save overwrites the hand edits. The Configurator's own save
  reorders variables and trims grid widths; commit that re-save on its own.
- Files are CRLF. Keep names stable: screens bind controls to variables by name and charts are
  wired to devices and controls by name.
- Deploying the stored procedure, creating the CSV files, renaming COM ports and rebuilding
  PlantWatch are outside this repo; say so in the hand-over when a change needs one of them.
