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
| `Left-Light` COM6, `Right-Light` COM7 | SL60USB2 USB stack lights, write-only. Frames `A0 <channel#> <on/off> <mode>`: channel 1 red, 2 green, 4 buzzer; mode = channel + A1 steady, + B2 flash, buzzer + C3/D4 soft. The alert sends red flash (`A0 01 01 B3`) and buzzer flash soft (`A0 04 01 D8`). |
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

- `Left-Side-Scanner_Logic` (device chart): ignore if `Left-Stack-Alert` ≠ 0 → clear the
  message → record scan time and data → uppercase → `NOREAD`? (compared after the uppercase)
  → `Left-Clear-Parsed` → RegexExtract → parsed? (`LeftGMPartNumber <> -`, else
  `Left-Parse-Error`) → own part? (else `Left-Wrong-Part`) → `Left-Build-Label` → Birth of the
  label serial → birthed? → `Left-Birth-Original` → `Left-Axle-Print-Label` → production
  count → `LeftAddToBatch` → `Left-Box-Check`.
  Birth failed: if the label serial equals `Left-Unboxed-Serial` (a tube that was labelled but
  never boxed) it is boxed now instead; else if the failure text contains `IX_Item_Entity_Serial`
  it is a duplicate (`LeftAlert`, message, `Left-Log-Duplicate`); anything else is shown as
  the database error.
- `Left-Build-Label`: the scan's line digit must be 1 or 2; it is printed as 3 or 4
  (`Left-Label-Line`) and the **label serial** `Left-LabelData` is built as `ESAT` + year + day of
  year + `Left-Label-Line` + daily sequence + GM part number, without the supplier part number.
  Any other line digit posts "Unexpected line number N - bad read?", alerts and stops the scan
  before the Birth, so the tube is neither in the database nor labelled.
- **Two items per tube.** The scanner chart births the **label serial** (`Left-LabelData`); it is
  the inventory item, so the duplicate check, the unboxed-serial recovery, the label and the box
  all work on it. Tubes processed before label serials existed are therefore accepted once more.
  `Left-Birth-Original` then records the original scan (`Left-PartId-Data`) as its own item,
  never boxed; "already exists" is ignored, any other failure posts "Original scan not recorded -
  …" and flags, but the tube is still labelled and boxed.
- `Left-Box-Check`: consumed? (else `Left-Lot-Error`) → count updated (`Left-Lot-Status =
  Pass`, else `Left-Count-Error`) → `Left-Container-Count < BATCH_SIZE`, else
  `Left-Box-Print-Label` and `CreateLeftLot`. Row-1 branches are separated by NoOps on row 0
  so they cannot run into each other.
- `Left-Lot-Error` remembers the tube in `Left-Unboxed-Serial`; `Left-Count-Error` does not
  (the tube is in the box, only the count failed).
- `Left-Ensure-Box`: label known? read its lot quantity from the DB into `Left-Container-Count`.
  `Item not found` → `CreateLeftLot`; any other failure → message, flag, keep the current box;
  found but full (a successor box that failed to open) → `CreateLeftLot`. Called from
  `Initialize` and before every add.
- `CreateLeftLot`: `DBProcedure dbo.Angstrom_NextLotNumber` → `L${LeftLotNumber:%05d}` → Birth
  with quantity 0 → count 0, persist. Failures post a message and flag the error.
- `LeftAddToBatch`: Ensure-Box, ConsumeMaterial of the label serial (`Left-LabelData`) into the
  box, on success
  `LotManagement IncrementLotQuantityValue` → `Left-Container-Count`.
- `Left-Axle-Print-Label` / `Left-Box-Print-Label`: print `Left-LabelData` / `Left-LblBoxId`;
  remember `Left-Last-Label` /
  `Left-Last-Box-Label` *before* printing (so a failed print can be reprinted), fill the
  side's own template (`Left-AxleTemplate` from `ConfigFiles/AxleLabelTemplate-Left.zpl`,
  which prints `${Left-LabelData}`; box: `BoxLabelTemplate-Left.zpl`, `${Left-LblBoxId}`),
  write, status to `Left-Print-Status`; failure posts the printer error and flags. Every
  variable a print touches is per side; the two scanner threads share nothing but the
  box printer socket.
- `Left-Light-Connected` (TriggerMode **OnConnected** on `Left-Light`): clears the light when
  no error is posted, re-asserts red when one is. This is how the lights get their startup
  state; `Initialize` runs before the COM ports are open and must not talk to them.
- Screen charts: `Left-Clear-Ack-Button_Logic_1`, `Left-Reprint-Button_Logic`,
  `Left-Reprint-Box-Button_Logic` on `Screen:Left-Main/...` and the three `Right-*`
  equivalents on `Screen:Right-Main/...`. John wants the two screens kept identical and
  separate (no Right controls on Left-Main); note that the runtime on main shows one window,
  so until a per-station window exists the Right buttons are not reachable at runtime.
- Shared: `Initialize` (OnStart: load templates, Ensure-Box both sides), `LoadPrintTemplates`
  (four files, two per side), `NightlyReport` → `CreateCSV` (runs at 00:00 and lists every
  tube born the *previous* day with the box it went into; the box columns are empty for an
  unboxed tube; only label serials are listed, selected by their line digit 3 or 4 at position
  10, so the kept original scans do not double the rows; status to `Error-Mesage`, which
  nothing displays).
- Dead charts were removed on 2026-11-12; `pwLogic.yaml` holds only live charts.

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
| Duplicate label serial | "Duplicate Part, already in the database" | yes | `C:\AxleReports\DuplicateScans.csv` |
| ID does not parse | "Unreadable part ID" | yes | `C:\AxleReports\UnreadableScans.csv` |
| Other side's part | "Part belongs on the other line" | yes | – |
| Neither side's part | "Unknown part number N - bad read?" | yes | – |
| Line digit not 1 or 2 | "Unexpected line number N - bad read?" | yes | – |
| Original scan could not be recorded | "Original scan not recorded - …" (tube still labelled and boxed) | flag only | – |
| Consume failed | "Can't Add to Lot - clear the error and scan the tube again" (the rescan boxes it) | flag only | – |
| Count update failed | "Box count failed - check the box" | flag only | – |
| Birth failed, not a duplicate | the database error text | flag only | – |
| Reprint with nothing printed yet | "Nothing to reprint yet" / "No box label printed yet" | none | – |
| No read | "No read - scan the tube again"; the next scan clears it | none | – |
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

## Scripts in `misc/`

- `Create-Angstrom-Procedures.sql`: the stored procedure the box numbering needs.
- `Export-LotContents.ps1` (`.cmd` wrapper): boxes and their tubes to CSV, one row per tube;
  `-Lot L00012`, `-Side Right`, `-Since`/`-Until`, `-OutFile`. Default output
  `C:\AxleReports\LotContents_<stamp>.csv`. Note `Item_Gene.TimeStamp` in the pw schema is a
  computed `getdate()`, so "when was it added" is not stored; the tube's birth time is used.
- `Export-LotContentsFromLogs.ps1`: the same per-tube CSV rebuilt from `PlantWatch.*.log`
  files (logic-chart debug logging must have been on), for days the database does not
  cover. Pairs each side's last scanner trigger with the next ConsumeMaterial line; flags
  boxes whose serial already existed when issued and tubes whose birth failed.
- `Backup-PWInventory.ps1` (repo root): nightly database backup, see its help.

## Editing safely

- Hand edits to `pwLogic.yaml` are fine but follow the grid rules in the PlantWatch CLAUDE.md;
  then **verify by loading a copy through DomainModel** (recipe there) before handing over:
  empty validation report, no invalid cells, grids printed for the charts you touched.
- **Inserting a step before an `If` in a chart the Configurator has saved** shifts row 0 right but
  not the `*oN` alias copies of the row-1 cells, which then overwrite the real false branch one
  column to the left (every cell still validates). Delete every `- action: *oN` entry and the
  `&oN` anchors from that chart before inserting, and print the grid rows afterwards; the
  scanner charts had their duplicate and recovery rows made unreachable this way (2026-11-12).
- If PlantWatch is open on this folder, reload the configuration there before anyone saves
  from the Configurator, or the save overwrites the hand edits. The Configurator's own save
  reorders variables and trims grid widths; commit that re-save on its own.
- Files are CRLF. Keep names stable: screens bind controls to variables by name and charts are
  wired to devices and controls by name.
- Deploying the stored procedure, creating the CSV files, renaming COM ports and rebuilding
  PlantWatch are outside this repo; say so in the hand-over when a change needs one of them.
