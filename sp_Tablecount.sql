USE [master];
GO

/*********************************************
Procedure Name: sp_Tablecount
Author: Adrian Buckman
Revision date: 03/10/2019
Version: 1

© www.sqlundercover.com 

MIT License
------------
 
Copyright 2018 Sql Undercover
 
Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files
(the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:
 
The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
 
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE. 

*********************************************/

CREATE PROCEDURE [dbo].[sp_Tablecount] (
@databasename NVARCHAR(128) = NULL,
@schemaname NVARCHAR(128) = NULL,
@tablename NVARCHAR(128) = NULL,
@sortorder NVARCHAR(30) = NULL, --VALID OPTIONS 'Schema' 'Table' 'Rows' 'Delta'
@top INT = NULL,
@interval TINYINT = NULL
)
AS
BEGIN 

SET NOCOUNT ON;

DECLARE @Sql NVARCHAR(4000);
DECLARE @Delay VARCHAR(8);


IF OBJECT_ID('tempdb.dbo.#RowCounts') IS NOT NULL 
DROP TABLE [#RowCounts]

CREATE TABLE [#RowCounts] (
Schemaname NVARCHAR(128),
Tablename NVARCHAR(128),
TotalRows BIGINT,	
StorageInfo	XML,
IndexTypes VARCHAR(256)
);


--Show debug info:
PRINT 'Parameter values:'
PRINT '@databasename: '+ISNULL(@databasename,'NULL');
PRINT '@schemaname: '+ISNULL(@schemaname,'NULL');
PRINT '@tablename: '+ISNULL(@tablename,'NULL') 
PRINT '@sortorder: '+ISNULL(@sortorder,'NULL'); 
PRINT '@top: '+ISNULL(CAST(@top AS VARCHAR(20)),'NULL');
PRINT '@interval '+ISNULL(CAST(@interval AS VARCHAR(3)),'NULL');

IF @databasename IS NULL 
BEGIN 
	SET @databasename = DB_NAME();
END 

--Ensure database exists.
IF DB_ID(@databasename) IS NULL 
BEGIN 
	RAISERROR('Invalid databasename',11,0);
	RETURN;
END 

--Delta maximum is 60 seconds 
IF (@interval > 60) 
BEGIN 
	SET @interval = 60;
	PRINT '@interval was changed to the maximum value of 60 seconds';
END 

--Set delay for WAITFOR
IF (@interval IS NOT NULL AND @interval > 0)
BEGIN 	
	SET @Delay = '00:00:'+CASE WHEN @interval < 10 THEN '0'+CAST(@interval AS VARCHAR(2)) ELSE CAST(@interval AS VARCHAR(2)) END;
END 

--UPPER @sortorder
IF @sortorder IS NOT NULL 
BEGIN 
	SET @sortorder = UPPER(@sortorder);
	
	IF @sortorder NOT IN ('SCHEMA','TABLE','ROWS','DELTA')
	BEGIN 
		RAISERROR('Valid options for @sortorder are ''Schema'' ''Table'' ''Rows'' ''Delta''',11,0);
		RETURN;
	END 

	IF (@sortorder = 'DELTA' AND (@interval IS NULL OR @interval = 0))
	BEGIN 
		RAISERROR('@sortorder = Delta is invalid with @interval is null or zero',11,0);
		RETURN;	
	END
END

SET @Sql = N'
SELECT'
+CASE 
	WHEN @top IS NOT NULL THEN ' TOP ('+CAST(@top AS VARCHAR(20))+')'
	ELSE ''
END
+'
schemas.name AS Schemaname,
tables.name AS Tablename,
partitions.rows AS TotalRows,
CAST(Allocunits.PageInfo AS XML) AS StorageInfo,
ISNULL((SELECT type_desc + '': ''+CAST(COUNT(*) AS VARCHAR(6))+ ''  '' 
	FROM ['+@databasename+'].sys.indexes 
	WHERE object_id = tables.object_id AND indexes.type > 0 
	GROUP BY type_desc 
	ORDER BY type_desc 
	FOR XML PATH('''')),''HEAP'') AS IndexTypes
FROM ['+@databasename+'].sys.tables
INNER JOIN ['+@databasename+'].sys.schemas ON tables.schema_id = schemas.schema_id
INNER JOIN ['+@databasename+'].sys.partitions ON tables.object_id = partitions.object_id
CROSS APPLY (SELECT type_desc 
			+ N'': Total pages: ''
			+CAST(total_pages AS NVARCHAR(10))
			+ '' ''
			+CHAR(13)+CHAR(10)
			+N'' Used pages: ''
			+CAST(used_pages AS NVARCHAR(10))
			+ '' ''
			+CHAR(13)+CHAR(10)
			+N'' Total Size: ''
			+CAST((total_pages*8)/1024 AS NVARCHAR(10))
			+N''MB''
			+N'' ''
			FROM ['+@databasename+'].sys.allocation_units Allocunits 
			WHERE partitions.partition_id = Allocunits.container_id 
			ORDER BY type_desc ASC
			FOR XML PATH('''')) Allocunits (PageInfo)
WHERE index_id IN (0,1)'
+
CASE 
	WHEN @tablename IS NULL THEN '' 
	ELSE '
AND tables.name = @tablename'
END
+
CASE 
	WHEN @schemaname IS NULL THEN '' 
	ELSE '
AND schemas.name = @schemaname'
END+'
ORDER BY '
+CASE 
	WHEN @sortorder = 'SCHEMA' THEN 'schemas.name ASC,tables.name ASC;'
	WHEN @sortorder = 'TABLE' THEN 'tables.name ASC;'
	WHEN @sortorder = 'ROWS' THEN 'partitions.rows DESC'
	ELSE 'schemas.name ASC,tables.name ASC;' 
END

PRINT '
Dynamic SQL:';
PRINT @Sql;

IF (@interval IS NULL OR @interval = 0)
BEGIN 
	EXEC sp_executesql @Sql,
	N'@tablename NVARCHAR(128), @schemaname NVARCHAR(128)',
	@tablename = @tablename, @schemaname = @schemaname;
END
ELSE 
BEGIN 
	INSERT INTO #RowCounts (Schemaname,Tablename,TotalRows,StorageInfo,IndexTypes)
	EXEC sp_executesql @Sql,
	N'@tablename NVARCHAR(128), @schemaname NVARCHAR(128)',
	@tablename = @tablename, @schemaname = @schemaname;

	WAITFOR DELAY @Delay;

SET @Sql = N'
SELECT'
+CASE 
	WHEN @top IS NOT NULL THEN ' TOP ('+CAST(@top AS VARCHAR(20))+')'
	ELSE ''
END
+'
schemas.name AS Schemaname,
tables.name AS Tablename,
#RowCounts.TotalRows AS TotalRows,
partitions.rows-#RowCounts.TotalRows AS TotalRows_Delta,
#RowCounts.StorageInfo,
#RowCounts.IndexTypes
FROM ['+@databasename+'].sys.tables
INNER JOIN ['+@databasename+'].sys.schemas ON tables.schema_id = schemas.schema_id
INNER JOIN ['+@databasename+'].sys.partitions ON tables.object_id = partitions.object_id
INNER JOIN #RowCounts ON tables.name = #RowCounts.Tablename AND schemas.name = #RowCounts.Schemaname
WHERE index_id IN (0,1)'
+
CASE 
	WHEN @tablename IS NULL THEN '' 
	ELSE '
AND tables.name = @tablename'
END
+
CASE 
	WHEN @schemaname IS NULL THEN '' 
	ELSE '
AND schemas.name = @schemaname'
END+'
ORDER BY '
+CASE 
	WHEN @sortorder = 'SCHEMA' THEN 'schemas.name ASC,tables.name ASC;'
	WHEN @sortorder = 'TABLE' THEN 'tables.name ASC;'
	WHEN @sortorder = 'ROWS' THEN 'partitions.rows DESC'
	WHEN @sortorder ='DELTA' THEN 'ABS(partitions.rows-#RowCounts.TotalRows) DESC'
	ELSE 'schemas.name ASC,tables.name ASC;' 
END


	EXEC sp_executesql @Sql,
	N'@tablename NVARCHAR(128), @schemaname NVARCHAR(128)',
	@tablename = @tablename, @schemaname = @schemaname;

END 

END