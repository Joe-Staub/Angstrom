# Cutover to PWInventory2 (inventory schema v2)

The ordered steps for moving the Angstrom line from the PWInventory database (schema v1,
provider `pw`) to PWInventory2 (schema v2, provider `pw2`), with the checks that prove each
step before the next. Written for the maintenance weekend of 14-15 November 2026; the
rehearsal on the dev VM ran the same steps against a restored copy of the plant backup.

The configuration on `main` already expects PWInventory2. Nothing in it works against the old
database any more, so the database steps come first.

## 0. Before touching anything

- [ ] PlantWatch and RemotePW are stopped on the master and the remote.
- [ ] You have the PlantWatch build that contains `PWInventoryMigrate` (PlantWatch repo `main`
      from 14 November or later: `PlantWatch.InventoryMigrator\bin\...\PWInventoryMigrate.exe`,
      with its DLLs beside it). Copy that folder to the master.
- [ ] You have this repo's `misc\Create-Angstrom-Procedures.sql` on the master.

## 1. Back up the old database

On the master, from this folder:

```
Backup-PWInventory.cmd -Instance Axletube\SQLEXPRESS -Database PWInventory
```

The `.bak` lands in `C:\PWInventoryBackups\<yyyyMMdd>.BAK`. Copy it to the jump
drive as well. PWInventory itself is left in place as the fallback for the whole weekend.

## 2. Pre-flight the migration (writes nothing)

```
PWInventoryMigrate --server <master>\SQLEXPRESS --create-schema --check
```

`--create-schema --check` creates an empty PWInventory2 if it does not exist and then only
reports. Expect the row counts of the plant data and one finding about a station name with no
Station row (the plant data references one; that is what `--skip-orphans` is for). Exit code 1
with that single finding is normal. Anything else: stop and read the log beside the exe.

## 3. Migrate

```
PWInventoryMigrate --server <master>\SQLEXPRESS --create-schema --skip-orphans
```

One transaction: it either completes and reconciles counts, or nothing is written. The log
ends with the reconciliation and the status mapping line (v1 status `NEW` becomes the target's
name for index 1, `Out of Route`). The skipped station links are in `dbo.Migration_Skipped`,
the run itself in `dbo.Migration_Log`.

Check from a command prompt:

```
sqlcmd -S <master>\SQLEXPRESS -d PWInventory2 -E -Q "SELECT (SELECT COUNT(*) FROM dbo.Item) Items, (SELECT COUNT(*) FROM dbo.Item_Gene) Links, (SELECT MAX(Serial_Nbr) FROM dbo.Item WHERE Part_Number='LOT85545338') LastLeftBox, (SELECT MAX(Serial_Nbr) FROM dbo.Item WHERE Part_Number='LOT85545339') LastRightBox"
```

The item and link counts must match the `--check` report. The last box serials are what the
next boxes continue from.

## 4. Install the box-number procedure

```
sqlcmd -S <master>\SQLEXPRESS -d PWInventory2 -E -i misc\Create-Angstrom-Procedures.sql
```

It prints `dbo.Angstrom_NextLotNumber is installed.` Without it every box creation fails with
"Cannot get next box number".

Then give the account PlantWatch runs as (the operator login, `axletube\angstrom` at the
plant) access to the new database. The migrator creates PWInventory2 under whoever runs it,
so that account has a server login but no user in the new database, and PlantWatch logs
`Cannot open database "PWInventory2" requested by the login` on every inventory call:

```
sqlcmd -S <master>\SQLEXPRESS -d PWInventory2 -E -C -Q "IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name='axletube\angstrom') CREATE USER [axletube\angstrom] FOR LOGIN [axletube\angstrom]; ALTER ROLE db_owner ADD MEMBER [axletube\angstrom]"
```

Newer `sqlcmd` builds encrypt by default and reject SQL Express's self-signed certificate;
`-C` trusts it. The remote's RemotePW account needs the same: a local account with the same
name and password as the master's works through integrated security; otherwise create a SQL
login and use `User Id=...;Password=...` in the three connection strings.

## 5. Point the configuration at the master's SQL Server

`pwInventory.yaml`, `pwTraceDatabase.yaml` and `pwDBBDatabase.yaml` carry
`Data Source=localhost\SQLEXPRESS`. On the remote, `localhost` is the remote itself, so before
the configuration is pushed to the remote all three must name the master:

```
Data Source=<master>\SQLEXPRESS;Initial Catalog=PWInventory2;Integrated Security=SSPI
```

and SQL Server on the master must accept it: TCP/IP enabled in SQL Server Configuration
Manager, SQL Server Browser running, firewall open for TCP 1433 and UDP 1434, and the remote's
account allowed to log in (or use a SQL login with `User Id=...;Password=...` instead of
`Integrated Security=SSPI`). Test from the remote before starting anything:

```
sqlcmd -S <master>\SQLEXPRESS -d PWInventory2 -E -Q "SELECT COUNT(*) FROM dbo.Item"
```

Optional, same edit session: `pwStation.yaml` still names the template's `ABCStation`; schema v2
writes that name on every genealogy link. Rename it if you want the links to carry a real name.

## 6. Start the master, push the configuration, start the remote

1. Start PlantWatch on the master with this configuration. The status strip must show the
   database connected; the log (`%ProgramData%\HTE\PlantWatch\Logs\PlantWatch.log`) must have no
   `PWInventory2 ... failed` lines at startup.
2. Push the configuration to RIGHTREMOTE (Save Assignment, Push Config). The remote now
   receives the subroutines and OnStart charts its charts call.
3. Start RemotePW. Firewall: TCP 1883 inbound on the master, UDP 19883 inbound on the remote
   (`Setup\Enable-PlantWatchFirewall.ps1 -Role ...` in the PlantWatch repo).

## 7. Prove it with one tube per side

Scan one tube on each side and box it (or let it fall into the open box). Then:

```
sqlcmd -S <master>\SQLEXPRESS -d PWInventory2 -E -Q "SELECT TOP 4 Serial_Nbr, Part_Number, Birth_DateTime FROM dbo.Item ORDER BY Birth_DateTime DESC; SELECT TOP 2 Parent_Serial_Nbr, Child_Serial_Nbr, Consumed_At, Station FROM dbo.Item_Gene ORDER BY Consumed_At DESC"
```

Expect the label serial for each side as a new item, each linked into its side's current box,
`Station` filled in. Scan the same tube again: the screen must report the duplicate, not a
database error (the charts now look for "already exists" in the provider's message).

Then open the reporting service (PWInventoryReporting, port 5001, pointed at the master's
PWInventory2 through `%APPDATA%\HTE\pwinventoryreporting.yaml`) and confirm the two boxes show
for today with the test tubes in them.

## 8. Reports

- `ReportingScheduler` runs the CSV report at 23:55 daily and keeps its window end in the
  persisted variable `CSV-Last-Reported` (group `Angstrom-Axle-Tube`), so no batch is reported
  twice and none is missed. On a fresh machine the first run reports from the previous day.
- `misc\Export-LotContents.cmd` and `Backup-PWInventory.cmd` default to PWInventory2.

## Fallback

Set `provider: pw` and `Initial Catalog=PWInventory` back in the three YAML files, re-run
`Create-Angstrom-Procedures.sql` from the previous `main` (its v1 body) against PWInventory,
restart. Nothing in this cutover modifies PWInventory.

## 9. GM serial reload (19 November 2026)

The plant's PWInventory2 is replaced by a copy prepared on the dev machine: every item and box
removed, then the 2428 checked GM Grand Rapids serials loaded (22 characters, line digit as
scanned, birth date from the serial). `misc\Prepare-GMSerials.ps1` and `misc\Load-GMSerials.cmd`
did it there; the plant gets the result by backup, copy and restore:

1. On the master, stop PlantWatch, RemotePW and PWInventoryReporting (all hold connections).
2. Back up what is there: `Backup-PWInventory.cmd -Instance Axletube\SQLEXPRESS -Database PWInventory2`.
3. Copy the dev backup (`C:\PWInventoryBackups\<yyyyMMdd>.BAK` from the dev machine) to the
   master, for example `C:\PWInventoryBackups\GM-reload.BAK`, then:
   ```
   sqlcmd -S Axletube\SQLEXPRESS -E -C -Q "ALTER DATABASE PWInventory2 SET SINGLE_USER WITH ROLLBACK IMMEDIATE; RESTORE DATABASE PWInventory2 FROM DISK='C:\PWInventoryBackups\GM-reload.BAK' WITH REPLACE; ALTER DATABASE PWInventory2 SET MULTI_USER"
   ```
4. Database users travel with the backup; server logins do not. The dev backup holds one
   user, `dbo`, and the login that runs the RESTORE becomes the owner, so restoring from a
   prompt running as `axletube\angstrom` gives that account full access with nothing more to
   do (if another account restores, run `Step4b-Grant-PlantWatch-Access.cmd` for angstrom).
   The `pwplant2` SQL login has no user in the dev backup, so create it:
   ```
   sqlcmd -S Axletube\SQLEXPRESS -d PWInventory2 -E -C -Q "CREATE USER pwplant2 FOR LOGIN pwplant2; ALTER ROLE db_owner ADD MEMBER pwplant2"
   ```
5. `dbo.Angstrom_NextLotNumber` is inside the backup; nothing to run. Proof:
   `sqlcmd -S Axletube\SQLEXPRESS -d PWInventory2 -E -C -Q "SELECT OBJECT_ID('dbo.Angstrom_NextLotNumber')"` prints a number.
6. Check: `SELECT COUNT(*) FROM dbo.Item` must read 2428 and `SELECT COUNT(*) FROM dbo.Item
   WHERE Part_Number LIKE 'LOT%'` must read 0. Box numbering starts again at L00001 and R00001.
7. Push the matching configuration (line digit kept, full scan on the label, no second item per
   tube) to the master and the remote before the first scan.
