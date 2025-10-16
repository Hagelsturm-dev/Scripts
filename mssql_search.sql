SET NOCOUNT ON;
GO
IF OBJECT_ID('dbo.SearchDatabase','P') IS NOT NULL
    DROP PROCEDURE dbo.SearchDatabase;
GO

CREATE PROCEDURE dbo.SearchDatabase
    @SearchTerm       NVARCHAR(4000),
    @Exact            BIT           = 0,
    @IncludeNonText   BIT           = 0,
    @SchemaFilter     SYSNAME       = NULL,
    @TableFilter      SYSNAME       = NULL,
    @MaxRowsPerTable  INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @SearchTerm IS NULL OR LTRIM(RTRIM(@SearchTerm)) = N''
    BEGIN
        RAISERROR('Search term must not be empty.', 16, 1);
        RETURN;
    END;

    -- LIKE-Sonderzeichen escapen und Pattern bauen
    DECLARE @Escaped NVARCHAR(4000) =
        REPLACE(REPLACE(REPLACE(REPLACE(@SearchTerm, N'~', N'~~'), N'%', N'~%'), N'_', N'~_'), N'[', N'~[');

    DECLARE @Pattern NVARCHAR(4000) =
        CASE WHEN @Exact = 1 THEN @Escaped ELSE N'%' + @Escaped + N'%' END;

    CREATE TABLE #Results
    (
        SchemaName   SYSNAME,
        TableName    SYSNAME,
        ColumnName   SYSNAME,
        PrimaryKey   NVARCHAR(4000) NULL,
        MatchedValue NVARCHAR(4000) NULL
    );

    -- Zielspalten materialisieren
    CREATE TABLE #Targets
    (
        SchemaName SYSNAME,
        TableName  SYSNAME,
        object_id  INT,
        column_id  INT,
        ColumnName SYSNAME,
        TypeName   SYSNAME
    );

    INSERT INTO #Targets (SchemaName, TableName, object_id, column_id, ColumnName, TypeName)
    SELECT
        s.name  AS SchemaName,
        t.name  AS TableName,
        t.object_id,
        c.column_id,
        c.name  AS ColumnName,
        ty.name AS TypeName
    FROM sys.tables t
    JOIN sys.schemas s ON s.schema_id = t.schema_id
    JOIN sys.columns c ON c.object_id = t.object_id
    JOIN sys.types   ty ON ty.user_type_id = c.user_type_id
    WHERE t.is_ms_shipped = 0
      AND (@SchemaFilter IS NULL OR s.name = @SchemaFilter)
      AND (@TableFilter  IS NULL OR t.name  = @TableFilter)
      AND (
            ty.name IN (N'nvarchar', N'varchar', N'nchar', N'char', N'text', N'ntext', N'xml', N'sql_variant', N'uniqueidentifier')
            OR @IncludeNonText = 1
          );

    DECLARE @sql NVARCHAR(MAX);
    DECLARE @paramDef NVARCHAR(200) = N'@p NVARCHAR(4000)';
    DECLARE @sch SYSNAME, @tab SYSNAME, @obj INT, @colId INT, @col SYSNAME;

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT SchemaName, TableName, object_id, column_id, ColumnName
        FROM #Targets
        ORDER BY SchemaName, TableName, column_id;

    OPEN cur;
    FETCH NEXT FROM cur INTO @sch, @tab, @obj, @colId, @col;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        /* Primärschlüssel-Ausdruck je Tabelle zusammensetzen:
           Ergebnis ist z.B.  CAST([PK1] AS NVARCHAR(4000)) + '|' + CAST([PK2] AS NVARCHAR(4000))
           oder NULL wenn kein PK existiert. */
        DECLARE @pkExpr NVARCHAR(MAX) = N'NULL';

        IF EXISTS (
            SELECT 1
            FROM sys.indexes i
            JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
            WHERE i.object_id = @obj AND i.is_primary_key = 1
        )
        BEGIN
            DECLARE @tmp NVARCHAR(MAX) = N'';
            SELECT @tmp = @tmp + CASE WHEN @tmp = N'' THEN N'' ELSE N' + ''|'' + ' END
                           + N'CAST(' + QUOTENAME(c2.name) + N' AS NVARCHAR(4000))'
            FROM sys.indexes i
            JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
            JOIN sys.columns c2 ON c2.object_id = ic.object_id AND c2.column_id = ic.column_id
            WHERE i.object_id = @obj AND i.is_primary_key = 1
            ORDER BY ic.key_ordinal;

            IF @tmp <> N'' SET @pkExpr = @tmp;
        END

        DECLARE @top NVARCHAR(50) = CASE WHEN @MaxRowsPerTable IS NOT NULL THEN N'TOP(' + CAST(@MaxRowsPerTable AS NVARCHAR(20)) + N') ' ELSE N'' END;

        -- Suche: immer CAST auf NVARCHAR(MAX), damit alle Typen vergleichbar sind.
        SET @sql = N'
            INSERT INTO #Results (SchemaName, TableName, ColumnName, PrimaryKey, MatchedValue)
            SELECT ' + @top + N'
                   N' + QUOTENAME(@sch,'''') + N' AS SchemaName,
                   N' + QUOTENAME(@tab,'''') + N' AS TableName,
                   N' + QUOTENAME(@col,'''') + N' AS ColumnName,
                   ' + @pkExpr + N' AS PrimaryKey,
                   LEFT(CAST(' + QUOTENAME(@col) + N' AS NVARCHAR(4000)), 4000) AS MatchedValue
            FROM ' + QUOTENAME(@sch) + N'.' + QUOTENAME(@tab) + N'
            WHERE ' + CASE WHEN @IncludeNonText = 1 
                           THEN N'CAST(' + QUOTENAME(@col) + N' AS NVARCHAR(MAX))'
                           ELSE N'CAST(' + QUOTENAME(@col) + N' AS NVARCHAR(MAX))'
                      END + N' ' + CASE WHEN @Exact = 1 THEN N'= @p' ELSE N'LIKE @p ESCAPE ''~''' END + N';';

        EXEC sp_executesql @sql, @paramDef, @p = @Pattern;

        FETCH NEXT FROM cur INTO @sch, @tab, @obj, @colId, @col;
    END

    CLOSE cur;
    DEALLOCATE cur;

    SELECT SchemaName, TableName, ColumnName, PrimaryKey, MatchedValue
    FROM #Results
    ORDER BY SchemaName, TableName, ColumnName, PrimaryKey;
END
GO

-- Beispiele:
-- EXEC dbo.SearchDatabase @SearchTerm = N'muster';
-- EXEC dbo.SearchDatabase @SearchTerm = N'AB-1234', @Exact = 1;
-- EXEC dbo.SearchDatabase @SearchTerm = N'foo', @SchemaFilter = N'dbo', @TableFilter = N'Customers', @MaxRowsPerTable = 200;
-- EXEC dbo.SearchDatabase @SearchTerm = N'2024-12-31', @IncludeNonText = 1;
