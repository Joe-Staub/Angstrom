-- Stored procedures the Angstrom logic charts call through the DBProcedure cell.
-- Run once against the PWInventory2 database (schema v2) on every machine that runs
-- this configuration, from a command prompt on that machine:
--
--     sqlcmd -S <server>\SQLEXPRESS -d PWInventory2 -E -i Create-Angstrom-Procedures.sql
--
-- or open it in SQL Server Management Studio with PWInventory2 selected and execute it.
-- Safe to re-run: an existing procedure is dropped and recreated. Written for any
-- SQL Server from 2012 on (no CREATE OR ALTER, which older Express editions reject).
-- Check afterwards:  SELECT OBJECT_ID('dbo.Angstrom_NextLotNumber')   -- a number, not NULL

-- Next sequential box number for a container part. Box serials are one side letter
-- followed by the number (L00012, R00007); older plant serials were L000012. The
-- procedure strips the first character and takes the highest number that parses, so
-- numbering continues from whatever the database already holds, and a wiped
-- configuration cannot reissue a serial. Returns 1 when the part has no boxes yet.
IF OBJECT_ID('dbo.Angstrom_NextLotNumber', 'P') IS NOT NULL
    DROP PROCEDURE dbo.Angstrom_NextLotNumber;
GO

CREATE PROCEDURE dbo.Angstrom_NextLotNumber
    @PartNumber varchar(50),
    @NextLot    int OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @NextLot = ISNULL(MAX(n.Number), 0) + 1
    FROM (
        SELECT TRY_CAST(SUBSTRING(i.Serial_Nbr, 2, 20) AS int) AS Number
        FROM dbo.Item i
        WHERE i.Part_Number = @PartNumber      -- schema v2 carries the part number on the item
    ) n
    WHERE n.Number IS NOT NULL;   -- filtered here so no null-aggregate warning reaches the caller
END
GO

-- Confirmation for whoever runs this by hand.
IF OBJECT_ID('dbo.Angstrom_NextLotNumber', 'P') IS NOT NULL
    PRINT 'dbo.Angstrom_NextLotNumber is installed.';
ELSE
    PRINT 'dbo.Angstrom_NextLotNumber is MISSING - look for an error above.';
GO
