-- Stored procedures the Angstrom logic charts call through the DBProcedure cell.
-- Run once against the PWInventory database (pw schema) on every machine that runs
-- this configuration:  sqlcmd -S localhost\SQLEXPRESS -d PWInventory -E -i Create-Angstrom-Procedures.sql
-- Safe to re-run: CREATE OR ALTER replaces the procedure in place.

-- Next sequential box number for a container part. Box serials are one side letter
-- followed by the number (L00012, R00007); older plant serials were L000012. The
-- procedure strips the first character and takes the highest number that parses, so
-- numbering continues from whatever the database already holds, and a wiped
-- configuration cannot reissue a serial. Returns 1 when the part has no boxes yet.
CREATE OR ALTER PROCEDURE dbo.Angstrom_NextLotNumber
    @PartNumber varchar(50),
    @NextLot    int OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @NextLot = ISNULL(MAX(n.Number), 0) + 1
    FROM (
        SELECT TRY_CAST(SUBSTRING(i.Serial_Nbr, 2, 20) AS int) AS Number
        FROM dbo.Item i
        INNER JOIN dbo.Part p ON p.Part_Key = i.Part_Key
        WHERE p.Part_Number = @PartNumber
    ) n
    WHERE n.Number IS NOT NULL;   -- filtered here so no null-aggregate warning reaches the caller
END
GO
