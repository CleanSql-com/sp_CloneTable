USE [master]
GO

IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.ROUTINES WHERE ROUTINE_NAME = 'sp_CloneTable')
    EXEC ('CREATE PROC dbo.sp_CloneTable AS SELECT ''stub version, to be replaced''')
GO

EXEC [sys].[sp_MS_marksystemobject] '[dbo].[sp_CloneTable]';
GO

ALTER PROCEDURE [dbo].[sp_CloneTable]

/* ==================================================================================================================== */
/* Author:      CleanSql.com © Copyright CleanSql.com                                                                   */
/* Create date: 2023-08-23                                                                                              */
/* Description: Clones all tables from SourceDB into TargetDB, specified by input parameters: @SchemaNames/@TableNames  */
/*              including all constraints, indexes (including XML indexes) and triggers                                 */
/*              by default it will "translate" all user-defined datatypes from source into matching SQL Data types      */
/*              for example datatype FLAG defined as BIT in Source DB will be transalted to BIT on Target               */
/*              this can be changed by using setting @TranslateUDDT = 0                                                 */
/*              if Source Schema name does not exist on Target DB the sp will create it in TargetDb using default       */
/*              permissions and owner, this can be changed by setting @CreateTgtSchemaIfMissing = 0                     */
/* ==================================================================================================================== */
/* Change History:                                                                                                      */
/* -------------------------------------------------------------------------------------------------------------------- */
/* Date:       User:           Version:  Change:                                                                        */
/* -------------------------------------------------------------------------------------------------------------------- */
/* 2023-08-23  CleanSql.com    1.00      Created                                                                        */
/* -------------------------------------------------------------------------------------------------------------------- */
/* ==================================================================================================================== */
/* Example use:
                                                                                                                     
USE [AdventureWorks2019];
GO

DECLARE @SchemaNames              NVARCHAR(MAX) = N' Production'
      , @TableNames               NVARCHAR(MAX) = N' Product
                                                   , ProductInventory
                                                   , Location
                                                   , ProductModel
                                                   , ProductCategory
                                                   , ProductSubcategory
                                                   , ScrapReason
                                                   , UnitMeasure
                                                   , WorkOrder'
      , @TargetDbName             SYSNAME       = N'AdventureWorks2019_Clone'

EXEC [dbo].[sp_CloneTable] @SchemaNames = @SchemaNames
                         , @TableNames = @TableNames
                         , @TargetDbName  = @TargetDbName
*/
/*THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO    */
/*THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE      */
/*AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, */
/*TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE      */
/*SOFTWARE.                                                                                                           */
/*LICENSE: https://github.com/CleanSql-com/sp_CloneTable?tab=MIT-1-ov-file#readme                                  */
/* ===================================================================================================================*/

    /* Input parameters: */
    @SchemaNames                     NVARCHAR(MAX) = N''    /* for example: N'Sales' */
  , @TableNames                      NVARCHAR(MAX) = N''    /* for example: N'SalesOrderHeader,SalesOrderHeaderSalesReason,Customer,CreditCard,PersonCreditCard,CurrencyRate' */
  , @Delimiter                       CHAR(1)       = ','    /* character that was used to delimit the list of names above in @SchemaNames/@TableNames */
  , @WhatIf                          BIT           = 0      /* 1 = only printout commands to be executed, without running them */
  , @ContinueOnError                 BIT           = 0      /* Set to = 1 ONLY if you do not care about any errors encountered during create */
  , @TranslateUDDT                   BIT           = 1      /* 1 = Translate User-defined Data types into matching standard SQL data types */
  , @TargetDbName                    SYSNAME                /* if other than current DB it has to be a valid Target DB Name */
  , @KeepSourceCollation             BIT           = 0
  , @CreateTgtSchemaIfMissing        BIT           = 1      /* this will create the schema in TargetDb with default permissions and owner */

AS
BEGIN
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE

/* ==================================================================================================================== */
/* ----------------------------------------- VARIABLE AND TEMP TABLE DECLARATIONS: ------------------------------------ */
/* ==================================================================================================================== */

/* Internal parameters: */
        @ObjectId            INT
      , @SchemaId            INT
      , @StartSearchSch      INT
      , @DelimiterPosSch     INT
      , @SchemaName          SYSNAME
      , @TableName           SYSNAME
      , @ConstraintName      SYSNAME
      , @StartSearchTbl      INT
      , @DelimiterPosTbl     INT
      , @Id                  INT
      , @IdMax               INT
      , @SelectedTableId     INT
      , @SelectedTableIdMax  INT
      , @SqlEngineVersion    INT
      , @DbCollation         VARCHAR(256)
      , @ConstraintType      VARCHAR(2)

      /* Table-Count Variables: */
      , @CountSelectedTables INT
      , @CountColumnList     INT

      /* Dynamic sql variables: */
      , @SqlSchemaId         NVARCHAR(MAX)
      , @SqlExeTargetDb      NVARCHAR(MAX) = QUOTENAME(@TargetDbName) + N'.sys.sp_executesql'
      , @SqlStmt             NVARCHAR(MAX)
      , @SqlLogError         NVARCHAR(MAX)
      , @ParamDefinition     NVARCHAR(4000)
      , @crlf                CHAR(2)       = CHAR(13) + CHAR(10)


       /* Trigger parsing variables: */
      , @TriggerId           INT
      , @TriggerName         SYSNAME
      , @IsEncrypted         BIT
      , @TriggerDefinition   NVARCHAR(MAX)
      , @PointerString       INT
      , @PointerNewLine      INT
      , @LineOfCode          NVARCHAR(MAX)
      , @LineOfCodeId        INT
      , @LineOfCodeIdMax     INT

      /* Error handling varaibles: */
      , @ErrorSeverity11     INT           = 11 /* 11 changes the message color to red */
      , @ErrorSeverity18     INT           = 18 /* 16 and below does not break execution */
      , @ErrorState          INT
      , @ErrorMessage        NVARCHAR(MAX);     

/* ============================================================================================================================================ */
/* TEMP TABLE DEFINITIONS: */
/* ============================================================================================================================================ */

CREATE TABLE [#SelectedTables]
(
    [Id]                   INT           NOT NULL PRIMARY KEY CLUSTERED IDENTITY(1, 1)
  , [SchemaID]             INT           NOT NULL
  , [ObjectID]             BIGINT        NOT NULL UNIQUE
  , [SchemaName]           SYSNAME       NOT NULL
  , [TableName]            SYSNAME       NOT NULL
  , [IsClonedSuccessfully] BIT           NULL
  , [ErrorMessage]         NVARCHAR(MAX) NULL
);

CREATE TABLE [#ColumnList]
(
    [ObjectId]                   INT           NOT NULL
  , [column_id]                  INT           NOT NULL
  , [ColumnName]                 NVARCHAR(258) NOT NULL
  , [ColumnDefinition]           NVARCHAR(MAX) NOT NULL
  , [ColumnDefinitionTranslated] NVARCHAR(MAX) NOT NULL
  , PRIMARY KEY CLUSTERED ([ObjectId], [column_id])
);

CREATE TABLE [#ConstraintList]
(
    [ObjectId]             INT            NOT NULL
  , [ConstraintId]         INT            NOT NULL UNIQUE
  , [ConstraintName]       NVARCHAR(258)  NOT NULL UNIQUE
  , [Type]                 VARCHAR(2)     NOT NULL
  , [ConstraintType]       NVARCHAR(4000) NOT NULL
  , [ColumnList]           NVARCHAR(MAX)  NOT NULL
  , [ConstraintDefinition] NVARCHAR(MAX)  NOT NULL
  , [OnFgPsName]           SYSNAME        NULL
  , [IsClonedSuccessfully] BIT            NULL
  , [ErrorMessage]         NVARCHAR(MAX)  NULL
  , PRIMARY KEY CLUSTERED ([ObjectId], [ConstraintId])
);

CREATE TABLE [#IndexList]
(
    [ObjectId]             INT           NOT NULL
  , [IndexId]              INT           NOT NULL
  , [ConstraintId]         INT           NULL
  , [IndexType]            TINYINT       NOT NULL
  , [IsUnique]             VARCHAR(8)    NULL
  , [IndexTypeDescr]       NVARCHAR(60)  NOT NULL
  , [XmlType]              NVARCHAR(60)  NULL        
  , [IndexName]            SYSNAME       NOT NULL
  , [OnTable]              SYSNAME       NOT NULL
  , [ColumnListIndexed]    NVARCHAR(MAX) NOT NULL
  , [ColumnListIncluded]   NVARCHAR(MAX) NULL
  , [OnFgPsName]           SYSNAME       NOT NULL
  , [UsingXmlIndex]        SYSNAME       NULL
  , [FilteredDefinition]   NVARCHAR(MAX) NULL
  , [IsClonedSuccessfully] BIT           NULL
  , [ErrorMessage]         NVARCHAR(MAX) NULL
  , PRIMARY KEY CLUSTERED ([ObjectId], [IndexId])
);

CREATE TABLE [#TriggerList]
(
    [ObjectId]             INT           NOT NULL
  , [TriggerId]            INT           NOT NULL PRIMARY KEY CLUSTERED
  , [TriggerName]          SYSNAME       NOT NULL
  , [IsEncrypted]          BIT           NOT NULL
  , [IsClonedSuccessfully] BIT           NULL
  , [ErrorMessage]         NVARCHAR(MAX) NULL
);

CREATE TABLE [#TriggerDefinitions]
(
    [ObjectId]   INT           NOT NULL
  , [TriggerId]  INT           NOT NULL
  , [LineId]     INT           IDENTITY(1, 1) NOT NULL
  , [LineOfCode] NVARCHAR(MAX) NOT NULL
  , PRIMARY KEY CLUSTERED ([ObjectId], [TriggerId], [LineId])
);

IF (COALESCE(@TargetDbName, '') <> '' AND NOT EXISTS (SELECT 1 FROM [master].sys.[databases] WHERE [name] = @TargetDbName))
BEGIN
    SET @ErrorMessage = CONCAT('Could not find @TargetDbName: ', @TargetDbName);
    GOTO ERROR;
END;

SELECT @SqlEngineVersion = CAST(SUBSTRING(CAST(SERVERPROPERTY('ProductVersion') AS VARCHAR(20)), 1, 2) AS INT);
SELECT @DbCollation = [collation_name]
FROM [master].sys.[databases]
WHERE [name] = COALESCE(@TargetDbName, DB_NAME());


/* remove new-line and append delimiter at the end of @SchemaNames/@TableNames if it is missing: */
SET @SchemaNames = REPLACE(@SchemaNames, @crlf, '')
SET @TableNames = REPLACE(@TableNames, @crlf, '')
IF  LEN(@SchemaNames) > 0 AND (RIGHT(@SchemaNames, 1)) <> @Delimiter
    SET @SchemaNames = CONCAT(@SchemaNames, @Delimiter);
IF  LEN(@TableNames) > 0 AND (RIGHT(@TableNames, 1)) <> @Delimiter
    SET @TableNames = CONCAT(@TableNames, @Delimiter);

/* ============================================================================================================================================ */
/* COLLECT LIST OF SOURCE-TABLES SPECIFIED ABOVE TO BE CLONED: */
/* ============================================================================================================================================ */

SET @StartSearchSch = 0;
SET @DelimiterPosSch = 0;
WHILE CHARINDEX(@Delimiter, @SchemaNames, @StartSearchSch + 1) > 0
BEGIN
    SET @DelimiterPosSch = CHARINDEX(@Delimiter, @SchemaNames, @StartSearchSch + 1) - @StartSearchSch;
    SET @SchemaName = TRIM(SUBSTRING(@SchemaNames, @StartSearchSch, @DelimiterPosSch));
    SET @SchemaId = NULL;

    SET @SqlSchemaId = CONCAT('SELECT @_SchemaId = schema_id FROM [', DB_NAME(), '].sys.schemas WHERE name = @_SchemaName;');
    SET @ParamDefinition = N'@_SchemaName SYSNAME, @_SchemaId INT OUTPUT';

    EXEC sys.sp_executesql @stmt = @SqlSchemaId
                         , @params = @ParamDefinition
                         , @_SchemaName = @SchemaName
                         , @_SchemaId = @SchemaId OUTPUT;

    IF (@SchemaId IS NULL)
    BEGIN
        SET @ErrorMessage = CONCAT('Could not find @SchemaName: ', @SchemaName);
        GOTO ERROR;    
    END
    ELSE 
    BEGIN
        SET @StartSearchTbl = 0;
        SET @DelimiterPosTbl = 0;

        WHILE CHARINDEX(@Delimiter, @TableNames, @StartSearchTbl + 1) > 0
        BEGIN
            SET @DelimiterPosTbl = CHARINDEX(@Delimiter, @TableNames, @StartSearchTbl + 1) - @StartSearchTbl;
            SET @TableName = TRIM(SUBSTRING(@TableNames, @StartSearchTbl, @DelimiterPosTbl));
            
            IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE [name] = @TableName)
            BEGIN
                SET @ErrorMessage = CONCAT('Could not find @TableName: ', @TableName, ' LEN: ', LEN(@TableName));
                GOTO ERROR;    
            END

            SET @ObjectId = NULL;
            SET @ObjectId = OBJECT_ID('[' + @SchemaName + '].[' + @TableName + ']');

            SELECT @ObjectId = OBJECT_ID(CONCAT(QUOTENAME(@SchemaName), '.', QUOTENAME(@TableName)));
            IF (@ObjectId IS NOT NULL)
            BEGIN
                INSERT INTO [#SelectedTables] ([SchemaID], [ObjectID], [SchemaName], [TableName])
                VALUES (@SchemaId, @ObjectId, @SchemaName, @TableName);
            END
            SET @StartSearchTbl = CHARINDEX(@Delimiter, @TableNames, @StartSearchTbl + @DelimiterPosTbl) + 1;
        END;
    END;
    SET @StartSearchSch = CHARINDEX(@Delimiter, @SchemaNames, @StartSearchSch + @DelimiterPosSch) + 1;
END;

IF NOT EXISTS (SELECT 1 FROM [#SelectedTables])
BEGIN
    BEGIN
        SET @ErrorMessage = CONCAT('Could not find any objects specified in the list of schemas: [', @SchemaNames, N'] and tables: [', @TableNames, N'] in database: [', DB_NAME(DB_ID()), N'].');
        GOTO ERROR;
    END;
END
ELSE 
BEGIN
    SELECT @CountSelectedTables = COUNT (1) FROM [#SelectedTables]
    PRINT(CONCAT('Populated [#SelectedTables] with: ', @CountSelectedTables, ' records'))
END

/* ============================================================================================================================================ */
/* COLLECT AND SAVE EACH TABLE'S COLUMN LIST: */
/* ============================================================================================================================================ */        

INSERT INTO [#ColumnList] ([ObjectId], [column_id], [ColumnName], [ColumnDefinition], [ColumnDefinitionTranslated])
SELECT [st].[ObjectID]
     , [sc].[column_id]
     , QUOTENAME([sc].[name]) AS [ColumnName]
     , CASE
           WHEN [sc].[is_computed] = 1 THEN 'AS ' + [cc].[definition]
           ELSE
               UPPER([tp].[name]) + CASE
                                        WHEN [tp].[name] IN ( 'varchar', 'char', 'varbinary', 'binary', 'text' ) THEN '(' + CASE
                                                                                                                                WHEN [sc].[max_length] = -1 THEN 'MAX'
                                                                                                                                ELSE CAST([sc].[max_length] AS VARCHAR(5))
                                                                                                                            END + ')'
                                        WHEN [tp].[name] IN ( 'nvarchar', 'nchar', 'ntext' ) THEN '(' + CASE
                                                                                                            WHEN [sc].[max_length] = -1 THEN 'MAX'
                                                                                                            ELSE CAST([sc].[max_length] / 2 AS VARCHAR(5))
                                                                                                        END + ')'
                                        WHEN [tp].[name] IN ( 'datetime2', 'time2', 'datetimeoffset' ) THEN '(' + CAST([sc].[scale] AS VARCHAR(5)) + ')'
                                        WHEN [tp].[name] = 'decimal' THEN '(' + CAST([sc].[precision] AS VARCHAR(5)) + ',' + CAST([sc].[scale] AS VARCHAR(5)) + ')'
                                        ELSE ''
                                    END + CASE
                                              WHEN [tp].[is_user_defined] = 0
                                              AND  [sc].[collation_name] <> @DbCollation
                                              AND  @KeepSourceCollation = 1 THEN ' COLLATE ' + [sc].[collation_name]
                                              ELSE ''
                                          END + CASE WHEN [sc].[is_nullable] = 1 THEN ' NULL' ELSE ' NOT NULL' END
               + CASE
                     WHEN [ic].[is_identity] = 1 THEN ' IDENTITY(' + CAST(ISNULL([ic].[seed_value], '0') AS CHAR(1)) + ',' + CAST(ISNULL([ic].[increment_value], '1') AS CHAR(1)) + ')'
                     ELSE ''
                 END
       END AS [ColumnDefinition]
     , CASE [tp].[is_user_defined]
           WHEN 0 THEN ''
           ELSE
               CASE
                   WHEN [sc].[is_computed] = 1 THEN 'AS ' + [cc].[definition]
                   ELSE
                       UPPER([fn].[SystemTypeName])
                       + CASE
                             WHEN [fn].[SystemTypeName] IN ( 'varchar', 'char', 'varbinary', 'binary', 'text' ) THEN '(' + CASE
                                                                                                                               WHEN [fn].[max_length] = -1 THEN 'MAX'
                                                                                                                               ELSE CAST([fn].[max_length] AS VARCHAR(5))
                                                                                                                           END + ')'
                             WHEN [fn].[SystemTypeName] IN ( 'nvarchar', 'nchar', 'ntext' ) THEN '(' + CASE
                                                                                                           WHEN [fn].[max_length] = -1 THEN 'MAX'
                                                                                                           ELSE CAST([fn].[max_length] / 2 AS VARCHAR(5))
                                                                                                       END + ')'
                             WHEN [fn].[SystemTypeName] IN ( 'datetime2', 'time2', 'datetimeoffset' ) THEN '(' + CAST([fn].[scale] AS VARCHAR(5)) + ')'
                             WHEN [fn].[SystemTypeName] = 'decimal' THEN '(' + CAST([fn].[precision] AS VARCHAR(5)) + ',' + CAST([fn].[scale] AS VARCHAR(5)) + ')'
                             ELSE ''
                         END + CASE
                                   WHEN [sc].[collation_name] <> @DbCollation
                                   AND  @KeepSourceCollation = 1 THEN ' COLLATE ' + [sc].[collation_name]
                                   ELSE ''
                               END + CASE WHEN [sc].[is_nullable] = 1 THEN ' NULL' ELSE ' NOT NULL' END
                       + CASE
                             WHEN [ic].[is_identity] = 1 THEN ' IDENTITY(' + CAST(ISNULL([ic].[seed_value], '0') AS CHAR(1)) + ',' + CAST(ISNULL([ic].[increment_value], '1') AS CHAR(1)) + ')'
                             ELSE ''
                         END
               END
       END AS [ColumnDefinitionTranslated]
FROM sys.columns AS [sc]
JOIN [#SelectedTables] AS [st]
    ON [st].[ObjectID] = [sc].[object_id]
JOIN sys.types AS [tp]
    ON [sc].[user_type_id] = [tp].[user_type_id]
LEFT JOIN sys.computed_columns AS [cc]
    ON  [sc].[object_id] = [cc].[object_id]
    AND [sc].[column_id] = [cc].[column_id]
LEFT JOIN sys.identity_columns AS [ic]
    ON  [sc].[is_identity] = 1
    AND [sc].[object_id] = [ic].[object_id]
    AND [sc].[column_id] = [ic].[column_id]
OUTER APPLY (
                SELECT TYPE_NAME([st].[system_type_id]) AS [SystemTypeName]
                     , [st].[max_length]
                     , [st].[precision]
                     , [st].[scale]
                     , [st].[collation_name]
                     , [st].[is_nullable]
                FROM sys.types AS [st]
                WHERE [st].[is_user_defined] = 1
                AND   [st].[user_type_id] = [sc].[user_type_id]
                AND   [st].[system_type_id] = [tp].[system_type_id]
            ) AS [fn];

IF NOT EXISTS (SELECT 1 FROM [#ColumnList])
BEGIN
    BEGIN
        SET @ErrorMessage = CONCAT('Could not find any columns for schemas: [', @SchemaNames, N'] and tables: [', @TableNames, N'] in database: [', DB_NAME(DB_ID()), N'].');
        GOTO ERROR;
    END;
END
ELSE 
BEGIN
    SELECT @CountColumnList = COUNT (1) FROM [#ColumnList]
    PRINT(CONCAT('Populated [#ColumnList] with: ', @CountColumnList, ' records'))
END

/* ============================================================================================================================================ */
/* COLLECT AND SAVE PK/UNIQUE CONSTRAINT DEFINIIONS: */
/* ============================================================================================================================================ */    

INSERT INTO [#ConstraintList]
    (
        [ObjectId]
      , [ConstraintId]
      , [ConstraintName]
      , [Type]
      , [ConstraintType]
      , [ColumnList]
      , [ConstraintDefinition]
      , [OnFgPsName]
    )
SELECT [st].[ObjectID]
     , [kc].[object_id]
     , QUOTENAME([kc].[name]) AS [ConstraintName]
     , [kc].[type] AS [Type]
     , CONCAT(REPLACE(REPLACE([kc].[type_desc], '_', ' '), 'CONSTRAINT', ''), [si].[type_desc]) AS [ConstraintType]
     , CASE
           WHEN @SqlEngineVersion < 14 THEN /* For SQL Versions older than 14 (2017) use FOR XML PATH for all multi-column constraints: */
     (STUFF((/* STUFF is needed to get rid of comma ',' before the first element of the column list */
                SELECT ', ' + QUOTENAME([sc].[name]) + CASE WHEN [ic].[is_descending_key] = 1 THEN ' DESC' ELSE ' ASC' END
                FROM sys.index_columns AS [ic]
                INNER JOIN sys.columns AS [sc]
                    ON  [sc].[object_id] = [ic].[object_id]
                    AND [sc].[column_id] = [ic].[column_id]
                WHERE [ic].[is_included_column] = 0
                AND   [ic].[object_id] = [kc].[parent_object_id]
                AND   [ic].[index_id] = [kc].[unique_index_id]
                ORDER BY [ic].[key_ordinal]
                FOR XML PATH(N''), TYPE
            ).[value]('.', 'NVARCHAR(MAX)')
          , 1
          , 2
          , ''
           )
     )
           /* For SQL Versions 2017+ use STRING_AGG for all multi-column constraints: */
           ELSE STRING_AGG(QUOTENAME([sc].[name]) + CASE WHEN [ic].[is_descending_key] = 1 THEN ' DESC' ELSE ' ASC' END, ', ')WITHIN GROUP(ORDER BY [ic].[key_ordinal])
       END AS [ColumnList]
     , '' AS [ConstraintDefinition]
     , [ds].[name] AS [OnFgPsName]
FROM sys.key_constraints AS [kc]
JOIN [#SelectedTables] AS [st]
    ON [st].[ObjectID] = [kc].[parent_object_id]
LEFT JOIN sys.indexes AS [si]
    ON  [si].[object_id] = [kc].[parent_object_id]
    AND [si].[index_id] = [kc].[unique_index_id]
LEFT JOIN sys.index_columns AS [ic]
    ON  [ic].[object_id] = [kc].[parent_object_id]
    AND [ic].[index_id] = [kc].[unique_index_id]
LEFT JOIN sys.columns AS [sc]
    ON  [sc].[object_id] = [ic].[object_id]
    AND [sc].[column_id] = [ic].[column_id]
JOIN sys.data_spaces AS [ds]
    ON [si].[data_space_id] = [ds].[data_space_id]
AND   [kc].[type] IN ( 'PK', 'UQ' )
GROUP BY [st].[ObjectID]
       , [si].[index_id]
       , [kc].[object_id]
       , [kc].[type]
       , [kc].[type_desc]
       , [si].[type]
       , [si].[type_desc]
       , [kc].[name]
       , [kc].[parent_object_id]
       , [kc].[unique_index_id]
       , [ds].[name];

/* ============================================================================================================================================ */
/* COLLECT AND SAVE DEFAULT CONSTRAINT DEFINITIONS: */
/* ============================================================================================================================================ */

INSERT INTO [#ConstraintList]
    (
        [ObjectId]
      , [ConstraintId]
      , [ConstraintName]
      , [Type]
      , [ConstraintType]
      , [ColumnList]
      , [ConstraintDefinition]
    )
SELECT [st].[ObjectID]
     , [dc].[object_id] AS [ConstraintId]
     , QUOTENAME([dc].[name]) AS [ConstraintName]
     , [dc].[type] AS [Type]
     , REPLACE([dc].[type_desc], '_CONSTRAINT', '') AS [ConstraintType] /* remove suffix '_CONSTRAINT' from [ConstraintType] */
     , QUOTENAME([c].[name]) AS [ColumnList]
     , [dc].[definition] AS [ConstraintDefinition]
FROM sys.default_constraints AS [dc]
JOIN sys.columns AS [c]
    ON  [c].[default_object_id] <> 0
    AND [c].[object_id] = [dc].[parent_object_id]
    AND [c].[column_id] = [dc].[parent_column_id]
JOIN [#SelectedTables] AS [st]
    ON [st].[ObjectID] = [c].[object_id]
WHERE [dc].[type] = 'D';

/* ============================================================================================================================================ */
/* COLLECT AND SAVE CHECK CONSTRAINT DEFINITIONS: */
/* ============================================================================================================================================ */

INSERT INTO [#ConstraintList]
    (
        [ObjectId]
      , [ConstraintId]
      , [ConstraintName]
      , [Type]
      , [ConstraintType]
      , [ColumnList]
      , [ConstraintDefinition]
    )
SELECT [st].[ObjectID]
     , [cc].[object_id] AS [ConstraintId]
     , QUOTENAME([cc].[name]) AS [ConstraintName]
     , [cc].[type] AS [Type]
     , REPLACE([cc].[type_desc], '_CONSTRAINT', '') AS [ConstraintType] /* remove suffix '_CONSTRAINT' from [ConstraintType] */
     , '' AS [ColumnList]
     , [cc].[definition] AS [ConstraintDefinition]
FROM sys.check_constraints AS [cc]
JOIN [#SelectedTables] AS [st]
    ON [st].[ObjectID] = [cc].[parent_object_id]

/* ============================================================================================================================================ */
/* COLLECT AND SAVE FOREIGN-KEY CONSTRAINT DEFINITIONS: */
/* ============================================================================================================================================ */

; WITH [fkc]
AS (SELECT [st].[ObjectID]
         , [fk].[object_id] AS [ForeignKeyId]
         , [fk].[type] AS [Type]
         , [fk].[type_desc] AS [ConstraintTypeDescr]
         , [fk].[name] AS [ForeignKeyName]
         , [fk].[delete_referential_action]
         , [fk].[update_referential_action]
         , [col_src].[name] AS [ColumnNameSrc]
         , [sch_tgt].[SchemaName] AS [SchemaNameTgt]
         , OBJECT_NAME([fkc].[referenced_object_id]) AS [TableNameTgt]
         , [fkc].[referenced_column_id] AS [ColumnIdTgt]
         , [col_tgt].[name] AS [Column_Name_Tgt]
    FROM sys.foreign_keys AS [fk]
    JOIN [#SelectedTables] AS [st]
        ON [st].[ObjectID] = [fk].[parent_object_id]
    CROSS APPLY (
                    SELECT [fkc].[parent_column_id]
                         , [fkc].[parent_object_id]
                         , [fkc].[referenced_object_id]
                         , [fkc].[referenced_column_id]
                    FROM sys.foreign_key_columns AS [fkc]
                    WHERE [fk].[parent_object_id] = [fkc].[parent_object_id]
                    AND   [fk].[referenced_object_id] = [fkc].[referenced_object_id]
                    AND   [fk].[object_id] = [fkc].[constraint_object_id]
                ) AS [fkc]
    CROSS APPLY (
                    SELECT [ss].[name] AS [SchemaName]
                    FROM sys.objects AS [so]
                    INNER JOIN sys.schemas AS [ss]
                        ON [ss].[schema_id] = [so].[schema_id]
                    WHERE [so].[object_id] = [fkc].[parent_object_id]
                ) AS [sch_src]
    CROSS APPLY (
                    SELECT [sc].[name]
                    FROM sys.columns AS [sc]
                    WHERE [sc].[object_id] = [fk].[parent_object_id]
                    AND   [sc].[column_id] = [fkc].[parent_column_id]
                ) AS [col_src]
    CROSS APPLY (
                    SELECT [ss].[schema_id] AS [SchemaId]
                         , [ss].[name] AS [SchemaName]
                    FROM sys.objects AS [so]
                    INNER JOIN sys.schemas AS [ss]
                        ON [ss].[schema_id] = [so].[schema_id]
                    WHERE [so].[object_id] = [fkc].[referenced_object_id]
                ) AS [sch_tgt]
    CROSS APPLY (
                    SELECT [sc].[name]
                    FROM sys.columns AS [sc]
                    WHERE [sc].[object_id] = [fk].[referenced_object_id]
                    AND   [sc].[column_id] = [fkc].[referenced_column_id]
                ) AS [col_tgt]
)
INSERT INTO [#ConstraintList]
    (
        [ObjectId]
      , [ConstraintId]
      , [ConstraintName]
      , [Type]
      , [ConstraintType]
      , [ColumnList]
      , [ConstraintDefinition]
    )
(SELECT [fkc].[ObjectID]
      , [fkc].[ForeignKeyId] AS [ConstraintId]
      , QUOTENAME([fkc].[ForeignKeyName]) AS [ConstraintName]
      , [fkc].[Type]
      , REPLACE((REPLACE([fkc].[ConstraintTypeDescr], '_', ' ')), 'CONSTRAINT', '') AS [ConstraintType] /* remove suffix '_CONSTRAINT' from [ConstraintType] */
      , CASE
            WHEN @SqlEngineVersion < 14
            /* For SQL Versions older than 14 (2017) use FOR XML PATH for all multi-column constraints: */
            THEN      STUFF((
                                SELECT ', ' + QUOTENAME([t].[ColumnNameSrc])
                                FROM [fkc] [t]
                                WHERE [t].[ForeignKeyId] = [fkc].[ForeignKeyId]
                                ORDER BY [t].[ColumnIdTgt] --This is identical to the ORDER BY in WITHIN GROUP clause in STRING_AGG
                                FOR XML PATH(''), TYPE
                            ).[value]('(./text())[1]', 'VARCHAR(MAX)')
                          , 1
                          , 2
                          , '')
            ELSE /* For SQL Versions 14+ (2017+) use STRING_AGG for all multi-column constraints: */
                    STRING_AGG(QUOTENAME([fkc].[ColumnNameSrc]), ', ')WITHIN GROUP(ORDER BY [fkc].[ColumnIdTgt])
        END AS [ColumnList]
      , CONCAT(
                  'REFERENCES '
                , QUOTENAME([fkc].[SchemaNameTgt]) + '.' + QUOTENAME([fkc].[TableNameTgt])
                , ' ('
                , CASE
                      WHEN @SqlEngineVersion < 14
                      /* For SQL Versions older than 14 (2017) use FOR XML PATH for all multi-column constraints: */
                      THEN
                          STUFF((
                                    SELECT ', ' + QUOTENAME([t].[Column_Name_Tgt])
                                    FROM [fkc] [t]
                                    WHERE [t].[ForeignKeyId] = [fkc].[ForeignKeyId]
                                    ORDER BY [t].[ColumnIdTgt] --This is identical to the ORDER BY in WITHIN GROUP clause in STRING_AGG
                                    FOR XML PATH(''), TYPE
                                ).[value]('(./text())[1]', 'VARCHAR(MAX)')
                              , 1
                              , 2
                              , ''
                               )
                      ELSE
                          /* For SQL Versions 2017+ use STRING_AGG for all multi-column constraints: */
                          STRING_AGG(QUOTENAME([fkc].[Column_Name_Tgt]), ', ')WITHIN GROUP(ORDER BY [fkc].[ColumnIdTgt])
                  END
                , ')'
                , CASE
                      WHEN [fkc].[delete_referential_action] = 1 THEN ' ON DELETE CASCADE'
                      WHEN [fkc].[delete_referential_action] = 2 THEN ' ON DELETE SET NULL'
                      WHEN [fkc].[delete_referential_action] = 3 THEN ' ON DELETE SET DEFAULT'
                      ELSE ''
                  END 
                + CASE
                      WHEN [fkc].[update_referential_action] = 1 THEN ' ON UPDATE CASCADE'
                      WHEN [fkc].[update_referential_action] = 2 THEN ' ON UPDATE SET NULL'
                      WHEN [fkc].[update_referential_action] = 3 THEN ' ON UPDATE SET DEFAULT'
                      ELSE ''
                  END
              ) AS [ConstraintDefinition]
 FROM [fkc]
 GROUP BY [fkc].[ObjectID]
        , [fkc].[ForeignKeyId]
        , [fkc].[Type]
        , [fkc].[ConstraintTypeDescr]
        , [fkc].[ForeignKeyName]
        , [fkc].[SchemaNameTgt]
        , [fkc].[TableNameTgt]
        , [fkc].[delete_referential_action]
        , [fkc].[update_referential_action])


/* ============================================================================================================================================ */
/* COLLECT AND SAVE INDEX DEFINITIONS (NOT INCLUDED AS PART OF CONSTRAINT LIST): */
/* ============================================================================================================================================ */

INSERT INTO [#IndexList]
    (
        [ObjectId]
      , [IndexId]
      , [ConstraintId]
      , [IndexType]
      , [IsUnique]
      , [IndexTypeDescr]
      , [XmlType]
      , [IndexName]
      , [OnTable]
      , [ColumnListIndexed]
      , [ColumnListIncluded]
      , [OnFgPsName]
      , [UsingXmlIndex]
      , [FilteredDefinition]
    )
SELECT 
       [so].[object_id]                                                             AS [ObjectId]
     , [si].[index_id]                                                              AS [IndexId]
     , [kc].[object_id]                                                             AS [ConstraintId]
     --, 'CREATE '
     , [si].[type]                                                                  AS [IndexType]
     , CASE WHEN [si].[is_unique] = 1 THEN ' UNIQUE ' ELSE '' END                   AS [IsUnique]
     , [si].[type_desc]                                                             AS [IndexTypeDescr]
     , IIF([xm].[xml_index_type] = 0, ' PRIMARY ', '')                              AS [XmlType]
     --, ' INDEX '
     , QUOTENAME([si].[name])                                                       AS [IndexName]
     --, ' ON '
     , CONCAT(QUOTENAME([ss].[name]), '.', QUOTENAME([so].[name]), ' ')             AS [OnTable]
     , [colidx].[ColumnListIndexed]
     , IIF([colincl].[ColumnListIncl] IS NOT NULL, [colincl].[ColumnListIncl], '')  AS [ColumnListIncluded]
     , IIF([si].[type] <> 3, CONCAT(' ON ', QUOTENAME([ds].[name])), '' )           AS [OnFgPsName]
     , IIF([xm].[xml_index_type] = 1, 
            CONCAT(' USING XML INDEX ', QUOTENAME([use].[name]), ' FOR '
         , [xm].[secondary_type_desc] COLLATE SQL_Latin1_General_CP1_CI_AS), '')    AS [UsingXmlIndex]
     , CASE [si].[has_filter]
           WHEN 1 THEN CONCAT('WHERE ', [si].[filter_definition])
           ELSE ''
       END                                                                          AS [FilteredDefinition]
FROM sys.indexes AS [si]
JOIN sys.objects AS [so]
    ON [so].[object_id] = [si].[object_id]
JOIN [#SelectedTables] AS [st]
    ON [st].[ObjectID] = [so].[object_id]
JOIN sys.schemas AS [ss]
    ON [ss].[schema_id] = [so].[schema_id]
JOIN sys.data_spaces AS [ds]
    ON [si].[data_space_id] = [ds].[data_space_id]
LEFT JOIN sys.xml_indexes AS [xm]
    ON [xm].[index_id] = [si].[index_id]
    AND [xm].[object_id] = [so].[object_id]
LEFT JOIN sys.xml_indexes AS [use]
    ON [use].[index_id] = [xm].[using_xml_index_id]
    AND [use].[object_id] = [xm].[object_id]
CROSS APPLY 
(
    SELECT DISTINCT
       CONCAT('(', STRING_AGG(   QUOTENAME([_sc].[name]) 
                                        + CASE
                                               WHEN [_si].[type] < 3
                                               AND  [_ic].[is_descending_key] = 1 THEN ' DESC'
                                               WHEN [_si].[type] < 3
                                               AND  [_ic].[is_descending_key] = 0 THEN ' ASC'
                                               ELSE ''
                                           END
                   , ', '
                 )WITHIN GROUP(ORDER BY [_ic].[key_ordinal]), ')') AS [ColumnListIndexed]
    FROM sys.indexes AS [_si]
    JOIN sys.data_spaces AS [_ds]
        ON [_si].[data_space_id] = [_ds].[data_space_id]
    JOIN sys.objects AS [_so]
        ON [_si].[index_id] = [si].[index_id]
        AND [_si].[object_id] = [so].[object_id]
    JOIN sys.schemas AS [_ss]
        ON [_ss].[schema_id] = [_so].[schema_id]
    JOIN sys.index_columns AS [_ic]
        ON  [_ic].[object_id]   = [_so].[object_id]
        AND [_si].[object_id] = [_so].[object_id]
    JOIN sys.columns AS [_sc]
        ON  [_sc].[object_id] = [_ic].[object_id]
        AND [_sc].[column_id] = [_ic].[column_id]
        AND [_ic].[index_id] = [_si].[index_id]
    WHERE [_so].[is_ms_shipped] <> 1
    AND   [_si].[is_hypothetical] = 0
    AND   [_si].[type] > 1 /* excluding heap and clustered objects */
    AND   [_si].[index_id] <> 0
    AND   [_si].[is_primary_key] = 0
    AND   [_ic].[is_included_column] = 0
    GROUP BY [_si].[index_id]
)   AS [colidx]
OUTER APPLY 
(
    SELECT [_si].[index_id], 
         CONCAT('INCLUDE (', STRING_AGG(QUOTENAME([_sc].[name]), ', ') WITHIN GROUP(ORDER BY [_ic].[key_ordinal]) , ')') AS [ColumnListIncl]
    FROM sys.indexes AS [_si]
    JOIN sys.data_spaces AS [_ds]
        ON [_si].[data_space_id] = [_ds].[data_space_id]
    JOIN sys.objects AS [_so]
        ON [_si].[index_id] = [si].[index_id]
        AND [_si].[object_id] = [so].[object_id]
    JOIN sys.schemas AS [_ss]
        ON [_ss].[schema_id] = [_so].[schema_id]
    JOIN sys.index_columns AS [_ic]
        ON  [_ic].[object_id]   = [_so].[object_id]
        AND [_si].[object_id] = [_so].[object_id]
    JOIN sys.columns AS [_sc]
        ON  [_sc].[object_id] = [_ic].[object_id]
        AND [_sc].[column_id] = [_ic].[column_id]
        AND [_ic].[index_id] = [_si].[index_id]
    WHERE [_so].[is_ms_shipped] <> 1
    AND   [_si].[is_hypothetical] = 0
    AND   [_si].[type] > 1 /* excluding heap and clustered objects */
    AND   [_si].[index_id] <> 0
    AND   [_si].[is_primary_key] = 0
    AND   [_ic].[is_included_column] = 1
    GROUP BY [_si].[index_id]
)   AS [colincl]
LEFT JOIN sys.key_constraints AS [kc]
    ON [kc].[name] = [si].[name]
    AND [kc].[object_id] = [so].[object_id]
LEFT JOIN [#ConstraintList] AS [cl]
    ON [kc].[object_id] = [cl].[ConstraintId]
WHERE [so].[is_ms_shipped] <> 1
AND   [si].[is_hypothetical] = 0
AND   [si].[type] > 0 /* excluding heap objects */
AND   [si].[index_id] <> 0
AND   [cl].[ConstraintId] IS NULL /* we want only the indexes that have not already been included in [#ConstraintList] */
ORDER BY [OnTable], [si].[index_id]

/* ============================================================================================================================================ */
/* COLLECT AND SAVE TRIGGER CONSTRAINT DEFINITIONS: */
/* ============================================================================================================================================ */

TRUNCATE TABLE [#TriggerList];
INSERT INTO [#TriggerList] ([ObjectId], [TriggerId], [TriggerName], [IsEncrypted])
SELECT [st].[ObjectID]
     , [tr].[object_id] AS [TriggerId]
     , OBJECT_NAME([tr].[object_id]) AS [TriggerName]
     , OBJECTPROPERTY([tr].[object_id], 'IsEncrypted') AS [IsEncrypted]
FROM sys.triggers [tr]
JOIN [#SelectedTables] AS [st]
    ON [st].[ObjectID] = [tr].[parent_id];

IF EXISTS (SELECT 1 FROM [#TriggerList])
BEGIN
    SELECT @Id = MIN([TriggerId]), @IdMax = MAX([TriggerId]) FROM [#TriggerList];
    WHILE (@Id <= @IdMax)
    BEGIN
        SELECT @ObjectId = [ObjectId]
             , @TriggerId = [TriggerId]
             , @TriggerName = [TriggerName]
             , @IsEncrypted = [IsEncrypted]
        FROM [#TriggerList]
        WHERE [TriggerId] = @Id;

        IF (@IsEncrypted = 1)
        BEGIN
            SELECT @ErrorMessage = CONCAT('Definition of Trigger: ', @TriggerName, ' is encrypted, unable to clone it');
            RAISERROR(@ErrorMessage, @ErrorSeverity11, 1);
        END;
        ELSE
        BEGIN
            SELECT @TriggerDefinition = [definition] FROM sys.sql_modules WHERE [object_id] = @TriggerId;
            SET @PointerString = 0;
            SET @PointerNewLine = -2; /* (-2) because at first iteration we want to catch the first 2 characters of the first line */

            DBCC CHECKIDENT('#TriggerDefinitions', RESEED, 0) WITH NO_INFOMSGS;

            /* Print out (save into temp table) each line at a time: */
            WHILE @PointerString <= LEN(@TriggerDefinition)
            BEGIN
                IF (   (SUBSTRING(@TriggerDefinition, @PointerString + 1, 2) = @crlf)
                 OR    (@PointerString = LEN(@TriggerDefinition))
                   )
                BEGIN
                    SELECT @LineOfCode = REPLACE(REPLACE(SUBSTRING(@TriggerDefinition, @PointerNewLine + LEN(@crlf), (@PointerString - @PointerNewLine)), CHAR(13), ''), CHAR(10), '');
                    INSERT INTO [#TriggerDefinitions] ([ObjectId], [TriggerId], [LineOfCode]) VALUES (@ObjectId, @TriggerId, @LineOfCode);
                    SET @PointerNewLine = @PointerString;
                END;
                SET @PointerString = @PointerString + 1;
            END;
        END;
        SELECT @Id = MIN([TriggerId]) FROM [#TriggerList] WHERE [TriggerId] > @Id;
    END;
END;

/* ============================================================================================================================================ */
/* EXECUTE AND/OR PRINTOUT TABLE DEFINITIONS: */
/* ============================================================================================================================================ */

BEGIN TRANSACTION;

SELECT @SelectedTableId = MIN([Id]), @SelectedTableIdMax = MAX([Id]) FROM [#SelectedTables];
WHILE (@SelectedTableId <= @SelectedTableIdMax)
BEGIN

    SELECT @ObjectId = [ObjectID]
         , @SchemaName = [SchemaName]
         , @TableName = [TableName]
    FROM [#SelectedTables]
    WHERE [Id] = @SelectedTableId;

    SET @SchemaId = NULL
    SET @SqlSchemaId = 'SELECT @_SchemaId = schema_id FROM sys.schemas WHERE name = @_SchemaName;';
    SET @ParamDefinition = N'@_SchemaName SYSNAME, @_SchemaId INT OUTPUT';

    EXECUTE @SqlExeTargetDb @stmt = @SqlSchemaId
                         , @params = @ParamDefinition
                         , @_SchemaName = @SchemaName
                         , @_SchemaId = @SchemaId OUTPUT;

    IF (@SchemaId IS NULL)
    BEGIN
        IF (@CreateTgtSchemaIfMissing <> 1)
        BEGIN
            SET @ErrorMessage = CONCAT('Could not find @SchemaName: ', @SchemaName, ' try setting @CreateTgtSchemaIfMissing = 1');
            GOTO ERROR;        
        END
        ELSE 
        BEGIN
            SELECT @SqlStmt = CONCAT('CREATE SCHEMA [', @SchemaName, ']')
            EXECUTE @SqlExeTargetDb @stmt = @SqlStmt;
            PRINT (CONCAT('Successfully created missing Schema: ', QUOTENAME(@SchemaName), ' in database: ', QUOTENAME(@TargetDbName)));
        END
    END    

    SELECT @SqlStmt = CONCAT('CREATE TABLE ', QUOTENAME(@SchemaName), '.', QUOTENAME(@TableName), '(', @crlf);
    SELECT @SqlStmt
        = CONCAT(
                    @SqlStmt
                  , IIF([column_id] > 1, ', ', '')
                  , [ColumnName]
                  , ' '
                  , IIF(LEN([ColumnDefinitionTranslated]) > 1 AND @TranslateUDDT = 1, [ColumnDefinitionTranslated], [ColumnDefinition])
                  , @crlf
                )
    FROM [#ColumnList]
    WHERE [ObjectId] = @ObjectId
    ORDER BY [column_id];

    SELECT @SqlStmt = CONCAT(@SqlStmt, ');', @crlf);
    IF (@WhatIf = 0)
    BEGIN TRY
        EXECUTE @SqlExeTargetDb @stmt = @SqlStmt; /* Execute Table Definition */
        PRINT (CONCAT('Successfully created table ', QUOTENAME(@SchemaName), '.', QUOTENAME(@TableName), ' in database: ', QUOTENAME(@TargetDbName)));
        UPDATE [#SelectedTables] SET [IsClonedSuccessfully] = 1 WHERE [Id] = @SelectedTableId;
    END TRY
    BEGIN CATCH
        SET @ErrorMessage = CONCAT('Error: ', ERROR_MESSAGE(), ' Failed executing: ', @SqlStmt);
        GOTO ERROR;
    END CATCH;
    ELSE IF (@WhatIf = 1)
    BEGIN
        PRINT (@SqlStmt); /* Printout Table Definition */
    END;
    SET @SqlStmt = NULL;

    SELECT @SelectedTableId = MIN([Id]) FROM [#SelectedTables] WHERE [Id] > @SelectedTableId;
END;

/* ============================================================================================================================================ */
/* EXECUTE AND/OR PRINTOUT CHECK, DEFAULT CONSTRAINT DEFINITIONS: */
/* ============================================================================================================================================ */

SELECT @SelectedTableId = MIN([Id]), @SelectedTableIdMax = MAX([Id]) FROM [#SelectedTables];
WHILE (@SelectedTableId <= @SelectedTableIdMax)
BEGIN

    SELECT @ObjectId = [ObjectID]
         , @SchemaName = [SchemaName]
         , @TableName = [TableName]
    FROM [#SelectedTables]
    WHERE [Id] = @SelectedTableId

    SELECT @Id = MIN([ConstraintId]), @IdMax = MAX([ConstraintId]) FROM [#ConstraintList] WHERE [Type] IN ('C', 'D') AND [ObjectId] = @ObjectId;

    WHILE @Id <= @IdMax
    BEGIN
        SELECT @ConstraintType = [Type]
             , @ConstraintName = [ConstraintName]
        FROM [#ConstraintList]
        WHERE [ConstraintId] = @Id
        AND   [ObjectId] = @ObjectId

        /* simulate error
        IF (@Id = 178099675)  
        BEGIN
            UPDATE [#ConstraintList] SET [ColumnList] = '[Foo]' WHERE [ConstraintId] = @id
        END
        */
        
        SELECT @SqlStmt = CONCAT(
                                    'ALTER TABLE '
                                  , QUOTENAME(@SchemaName), '.', QUOTENAME(@TableName), ' '
                                  , 'ADD CONSTRAINT '
                                  , [ConstraintName], ' '
                                  , [ConstraintType], ' '
                                  , IIF(@ConstraintType = 'D', [ConstraintDefinition] + ' FOR ', '')
                                  , IIF(@ConstraintType IN ( 'C', 'D' ), [ColumnList], '(' + [ColumnList] + ') ')
                                  , IIF(@ConstraintType IN ( 'C' ), [ConstraintDefinition], ''), ';'
                                )
        FROM [#ConstraintList]
        WHERE [ConstraintId] = @Id
        AND   [ObjectId] = @ObjectId;

        IF (@WhatIf = 0)
        BEGIN TRY            
            IF (@ContinueOnError = 1 AND XACT_STATE() <> 0 AND @@TRANCOUNT > 0)
            BEGIN
                COMMIT TRANSACTION;
                BEGIN TRANSACTION;
            END;            
            EXECUTE @SqlExeTargetDb @stmt = @SqlStmt; /* Execute FK Constraint Definition */
            IF (@ContinueOnError = 1 AND XACT_STATE() <> 0 AND @@TRANCOUNT > 0)
            BEGIN
                COMMIT TRANSACTION;
                BEGIN TRANSACTION;
            END;
            PRINT (CONCAT('Successfully created constraint: ', @ConstraintName, ' ON ', QUOTENAME(@SchemaName), '.', QUOTENAME(@TableName), ' in database: ', QUOTENAME(@TargetDbName)));
            UPDATE [#ConstraintList] SET [IsClonedSuccessfully] = 1 WHERE [ObjectId] = @ObjectId AND [ConstraintId] = @Id;
        END TRY
        BEGIN CATCH
              SET @ErrorMessage = CONCAT('Error: ', ERROR_MESSAGE(), ' Failed executing: ', @SqlStmt);
              IF (@ContinueOnError <> 1)
                  GOTO ERROR;
              ELSE /* continue execution but log the error: */
              BEGIN
                RAISERROR(@ErrorMessage, @ErrorSeverity11, 1) WITH NOWAIT;                
                IF (XACT_STATE() <> 0 AND @@TRANCOUNT > 0)
                BEGIN
                    ROLLBACK TRANSACTION;
                    BEGIN TRANSACTION;
                END;
                
                SET @ParamDefinition = '@_ErrorMessage NVARCHAR(4000), @_Id INT, @_ObjectId INT';
                SET @SqlLogError = 'UPDATE [#ConstraintList] SET [ErrorMessage] = CONCAT([ErrorMessage]+''; '', @_ErrorMessage) WHERE [ConstraintId] = @_Id AND [ObjectId] = @_ObjectId';
                EXEC sys.sp_executesql @stmt = @SqlLogError, @params = @ParamDefinition, @_ErrorMessage = @ErrorMessage, @_Id = @Id, @_ObjectId = @ObjectId;
                
                IF (XACT_STATE() <> 0 AND @@TRANCOUNT > 0)
                BEGIN
                    COMMIT TRANSACTION;
                    BEGIN TRANSACTION;
                END;
                SET @ErrorMessage = NULL;
              END;
        END CATCH
        ELSE IF (@WhatIf = 1)
        BEGIN
            PRINT (@SqlStmt); /* Printout Constraint Definition */
        END;
        SET @SqlStmt = NULL;
        SELECT @Id = MIN([ConstraintId]) FROM [#ConstraintList] WHERE [Type] IN ('C', 'D') AND [ObjectId] = @ObjectId AND [ConstraintId] > @Id;
    END;

    SELECT @SelectedTableId = MIN([Id]) FROM [#SelectedTables] WHERE [Id] > @SelectedTableId;
END;

/* ============================================================================================================================================ */
/* to do here: EXECUTE AND/OR PRINTOUT DATA COPY COMMANDS/JOB DEFINITIONS, IF AN OPTION TO DO SO IS USED: */
/* ============================================================================================================================================ */

/* ============================================================================================================================================ */
/* EXECUTE AND/OR PRINTOUT PRIMARY KEY/UNIQUE CONSTRAINT DEFINITIONS: */
/* ============================================================================================================================================ */

SELECT @SelectedTableId = MIN([Id]), @SelectedTableIdMax = MAX([Id]) FROM [#SelectedTables];
WHILE (@SelectedTableId <= @SelectedTableIdMax)
BEGIN

    SELECT @ObjectId = [ObjectID]
         , @SchemaName = [SchemaName]
         , @TableName = [TableName]
    FROM [#SelectedTables]
    WHERE [Id] = @SelectedTableId

    SELECT @Id = MIN([ConstraintId]), @IdMax = MAX([ConstraintId]) FROM [#ConstraintList] WHERE [Type] IN ('PK', 'UQ') AND [ObjectId] = @ObjectId;

    WHILE @Id <= @IdMax
    BEGIN
        SELECT @ConstraintType = [Type]
             , @ConstraintName = [ConstraintName]
        FROM [#ConstraintList]
        WHERE [ConstraintId] = @Id
        AND   [ObjectId] = @ObjectId

        SELECT @SqlStmt = CONCAT(
                                    'ALTER TABLE ', QUOTENAME(@SchemaName), '.', QUOTENAME(@TableName), ' '
                                  , 'ADD CONSTRAINT ', [ConstraintName], ' ', [ConstraintType], ' '
                                  , '(' + [ColumnList] + ') '
                                  , IIF(@ConstraintType = 'PK', 'ON ' + QUOTENAME([OnFgPsName]), ''), ';'
                                )
        FROM [#ConstraintList]
        WHERE [ConstraintId] = @Id
        AND   [ObjectId] = @ObjectId;

        IF (@WhatIf = 0)
        BEGIN TRY            
            IF (@ContinueOnError = 1 AND XACT_STATE() <> 0 AND @@TRANCOUNT > 0)
            BEGIN
                COMMIT TRANSACTION;
                BEGIN TRANSACTION;
            END;            
            EXECUTE @SqlExeTargetDb @stmt = @SqlStmt; /* Execute FK Constraint Definition */
            IF (@ContinueOnError = 1 AND XACT_STATE() <> 0 AND @@TRANCOUNT > 0)
            BEGIN
                COMMIT TRANSACTION;
                BEGIN TRANSACTION;
            END;
            PRINT (CONCAT('Successfully created constraint: ', @ConstraintName, ' ON ', QUOTENAME(@SchemaName), '.', QUOTENAME(@TableName), ' in database: ', QUOTENAME(@TargetDbName)));
            UPDATE [#ConstraintList] SET [IsClonedSuccessfully] = 1 WHERE [ObjectId] = @ObjectId AND [ConstraintId] = @Id;
        END TRY
        BEGIN CATCH
              SET @ErrorMessage = CONCAT('Error: ', ERROR_MESSAGE(), ' Failed executing: ', @SqlStmt);
              IF (@ContinueOnError <> 1)
                  GOTO ERROR;
              ELSE /* continue execution but log the error: */
              BEGIN
                RAISERROR(@ErrorMessage, @ErrorSeverity11, 1) WITH NOWAIT;                
                IF (XACT_STATE() <> 0 AND @@TRANCOUNT > 0)
                BEGIN
                    ROLLBACK TRANSACTION;
                    BEGIN TRANSACTION;
                END;
                
                SET @ParamDefinition = '@_ErrorMessage NVARCHAR(4000), @_Id INT, @_ObjectId INT';
                SET @SqlLogError = 'UPDATE [#ConstraintList] SET [ErrorMessage] = CONCAT([ErrorMessage]+''; '', @_ErrorMessage) WHERE [ConstraintId] = @_Id AND [ObjectId] = @_ObjectId';
                EXEC sys.sp_executesql @stmt = @SqlLogError, @params = @ParamDefinition, @_ErrorMessage = @ErrorMessage, @_Id = @Id, @_ObjectId = @ObjectId;
                
                IF (XACT_STATE() <> 0 AND @@TRANCOUNT > 0)
                BEGIN
                    COMMIT TRANSACTION;
                    BEGIN TRANSACTION;
                END;
                SET @ErrorMessage = NULL;
              END;
        END CATCH
        ELSE IF (@WhatIf = 1)
        BEGIN
            PRINT (@SqlStmt); /* Printout Constraint Definition */
        END;
        SET @SqlStmt = NULL;
        SELECT @Id = MIN([ConstraintId]) FROM [#ConstraintList] WHERE [Type] IN ('PK', 'UQ') AND [ObjectId] = @ObjectId AND [ConstraintId] > @Id;
    END;

    SELECT @SelectedTableId = MIN([Id]) FROM [#SelectedTables] WHERE [Id] > @SelectedTableId;
END;

/* ============================================================================================================================================ */
/* EXECUTE AND/OR PRINTOUT NCL INDEX DEFINITIONS: */
/* ============================================================================================================================================ */

SELECT @SelectedTableId = MIN([Id]), @SelectedTableIdMax = MAX([Id]) FROM [#SelectedTables];
WHILE (@SelectedTableId <= @SelectedTableIdMax)
BEGIN

    SELECT @ObjectId = [ObjectID]
         , @SchemaName = [SchemaName]
         , @TableName = [TableName]
    FROM [#SelectedTables]
    WHERE [Id] = @SelectedTableId

    SELECT @Id = MIN([IndexId]), @IdMax = MAX([IndexId]) FROM [#IndexList] WHERE [ObjectId] = @ObjectId;

    WHILE @Id <= @IdMax
    BEGIN

        SELECT @ConstraintName = [IndexName]
        FROM [#IndexList]
        WHERE [IndexId] = @Id
        AND   [ObjectId] = @ObjectId      
        
        SELECT @SqlStmt = CONCAT(
                                     'CREATE '
                                   , [IsUnique], ' '
                                   , [XmlType]
                                   , [IndexTypeDescr], ' '
                                   , 'INDEX '
                                   , [IndexName], ' '
                                   , 'ON ', QUOTENAME(@SchemaName), '.', QUOTENAME(@TableName), ' '
                                   , [ColumnListIndexed], ' '
                                   , [ColumnListIncluded]
                                   , [OnFgPsName]
                                   , [UsingXmlIndex]
                                   , [FilteredDefinition], ';'
                                )
        FROM [#IndexList]
        WHERE [IndexId] = @Id
        AND   [ObjectId] = @ObjectId;

        IF (@WhatIf = 0)
        BEGIN TRY            
            IF (@ContinueOnError = 1 AND XACT_STATE() <> 0 AND @@TRANCOUNT > 0)
            BEGIN
                COMMIT TRANSACTION;
                BEGIN TRANSACTION;
            END;            
            EXECUTE @SqlExeTargetDb @stmt = @SqlStmt; /* Execute IX Constraint Definition */
            IF (@ContinueOnError = 1 AND XACT_STATE() <> 0 AND @@TRANCOUNT > 0)
            BEGIN
                COMMIT TRANSACTION;
                BEGIN TRANSACTION;
            END;
            PRINT (CONCAT('Successfully created index: ', @ConstraintName, ' ON ', QUOTENAME(@SchemaName), '.', QUOTENAME(@TableName), ' in database: ', QUOTENAME(@TargetDbName)));
            UPDATE [#IndexList] SET [IsClonedSuccessfully] = 1 WHERE [ObjectId] = @ObjectId AND [IndexId] = @Id;
        END TRY
        BEGIN CATCH
              SET @ErrorMessage = CONCAT('Error: ', ERROR_MESSAGE(), ' Failed executing: ', @SqlStmt);
              IF (@ContinueOnError <> 1)
                  GOTO ERROR;
              ELSE /* continue execution but log the error: */
              BEGIN
                RAISERROR(@ErrorMessage, @ErrorSeverity11, 1) WITH NOWAIT;                
                IF (XACT_STATE() <> 0 AND @@TRANCOUNT > 0)
                BEGIN
                    ROLLBACK TRANSACTION;
                    BEGIN TRANSACTION;
                END;
                
                SET @ParamDefinition = '@_ErrorMessage NVARCHAR(4000), @_Id INT, @_ObjectId INT';
                SET @SqlLogError = 'UPDATE [#IndexList] SET [ErrorMessage] = CONCAT([ErrorMessage]+''; '', @_ErrorMessage) WHERE [IndexId] = @_Id AND [ObjectId] = @_ObjectId';
                EXEC sys.sp_executesql @stmt = @SqlLogError, @params = @ParamDefinition, @_ErrorMessage = @ErrorMessage, @_Id = @Id, @_ObjectId = @ObjectId;
                
                IF (XACT_STATE() <> 0 AND @@TRANCOUNT > 0)
                BEGIN
                    COMMIT TRANSACTION;
                    BEGIN TRANSACTION;
                END;
                SET @ErrorMessage = NULL;
              END;
        END CATCH
        ELSE IF (@WhatIf = 1)
        BEGIN
            PRINT (@SqlStmt); /* Printout Constraint Definition */
        END;
        SET @SqlStmt = NULL;
        SELECT @Id = MIN([IndexId]) FROM [#IndexList] WHERE [ObjectId] = @ObjectId AND [IndexId] > @Id;
    END;

    SELECT @SelectedTableId = MIN([Id]) FROM [#SelectedTables] WHERE [Id] > @SelectedTableId;
END;

/* ============================================================================================================================================ */
/* EXECUTE AND/OR PRINTOUT FOREIGN-KEY CONSTRAINT DEFINITIONS: */
/* ============================================================================================================================================ */

SELECT @SelectedTableId = MIN([Id]), @SelectedTableIdMax = MAX([Id]) FROM [#SelectedTables];
WHILE (@SelectedTableId <= @SelectedTableIdMax)
BEGIN

    SELECT @ObjectId = [ObjectID]
         , @SchemaName = [SchemaName]
         , @TableName = [TableName]
    FROM [#SelectedTables]
    WHERE [Id] = @SelectedTableId

    SELECT @Id = MIN([ConstraintId]), @IdMax = MAX([ConstraintId]) FROM [#ConstraintList] WHERE [Type] IN ('F') AND [ObjectId] = @ObjectId;

    WHILE @Id <= @IdMax
    BEGIN
        SELECT @ConstraintType = [Type]
             , @ConstraintName = [ConstraintName]
        FROM [#ConstraintList]
        WHERE [ConstraintId] = @Id
        AND   [ObjectId] = @ObjectId

        /* simulate error
        IF (@Id = 178099675)  
        BEGIN
            UPDATE [#ConstraintList] SET [ColumnList] = '[Foo]' WHERE [ConstraintId] = @id
        END
        */
        
        SELECT @SqlStmt = CONCAT(
                                    'ALTER TABLE '
                                  , QUOTENAME(@SchemaName), '.', QUOTENAME(@TableName), ' '
                                  , 'ADD CONSTRAINT '
                                  , [ConstraintName], ' '
                                  , [ConstraintType], ' '
                                  , '(' + [ColumnList] + ') '
                                  , [ConstraintDefinition]
                                )
        FROM [#ConstraintList]
        WHERE [ConstraintId] = @Id
        AND   [ObjectId] = @ObjectId;

        IF (@WhatIf = 0)
        BEGIN TRY            
            IF (@ContinueOnError = 1 AND XACT_STATE() <> 0 AND @@TRANCOUNT > 0)
            BEGIN
                COMMIT TRANSACTION;
                BEGIN TRANSACTION;
            END;            
            EXECUTE @SqlExeTargetDb @stmt = @SqlStmt; /* Execute FK Constraint Definition */
            IF (@ContinueOnError = 1 AND XACT_STATE() <> 0 AND @@TRANCOUNT > 0)
            BEGIN
                COMMIT TRANSACTION;
                BEGIN TRANSACTION;
            END;
            PRINT (CONCAT('Successfully created constraint: ', @ConstraintName, ' ON ', QUOTENAME(@SchemaName), '.', QUOTENAME(@TableName), ' in database: ', QUOTENAME(@TargetDbName)));
            UPDATE [#ConstraintList] SET [IsClonedSuccessfully] = 1 WHERE [ObjectId] = @ObjectId AND [ConstraintId] = @Id;
        END TRY
        BEGIN CATCH
              SET @ErrorMessage = CONCAT('Error: ', ERROR_MESSAGE(), ' Failed executing: ', @SqlStmt);
              IF (@ContinueOnError <> 1)
                  GOTO ERROR;
              ELSE /* continue execution but log the error: */
              BEGIN
                RAISERROR(@ErrorMessage, @ErrorSeverity11, 1) WITH NOWAIT;                
                IF (XACT_STATE() <> 0 AND @@TRANCOUNT > 0)
                BEGIN
                    ROLLBACK TRANSACTION;
                    BEGIN TRANSACTION;
                END;
                
                SET @ParamDefinition = '@_ErrorMessage NVARCHAR(4000), @_Id INT, @_ObjectId INT';
                SET @SqlLogError = 'UPDATE [#ConstraintList] SET [ErrorMessage] = CONCAT([ErrorMessage]+''; '', @_ErrorMessage) WHERE [ConstraintId] = @_Id AND [ObjectId] = @_ObjectId';
                EXEC sys.sp_executesql @stmt = @SqlLogError, @params = @ParamDefinition, @_ErrorMessage = @ErrorMessage, @_Id = @Id, @_ObjectId = @ObjectId;
                
                IF (XACT_STATE() <> 0 AND @@TRANCOUNT > 0)
                BEGIN
                    COMMIT TRANSACTION;
                    BEGIN TRANSACTION;
                END;
                SET @ErrorMessage = NULL;
              END;
        END CATCH
        ELSE IF (@WhatIf = 1)
        BEGIN
            PRINT (@SqlStmt); /* Printout Constraint Definition */
        END;
        SET @SqlStmt = NULL;
        SELECT @Id = MIN([ConstraintId]) FROM [#ConstraintList] WHERE [Type] IN ('F') AND [ObjectId] = @ObjectId AND [ConstraintId] > @Id;
    END;

    SELECT @SelectedTableId = MIN([Id]) FROM [#SelectedTables] WHERE [Id] > @SelectedTableId;
END;

/* ============================================================================================================================================ */
/* EXECUTE AND/OR PRINTOUT TRIGGER DEFINITIONS: */
/* ============================================================================================================================================ */

SELECT @SelectedTableId = MIN([Id]), @SelectedTableIdMax = MAX([Id]) FROM [#SelectedTables];
WHILE (@SelectedTableId <= @SelectedTableIdMax)
BEGIN

    SELECT @ObjectId = [ObjectID]
         , @SchemaName = [SchemaName]
         , @TableName = [TableName]
    FROM [#SelectedTables]
    WHERE [Id] = @SelectedTableId

    SELECT @Id = MIN([TriggerId]), @IdMax = MAX([TriggerId]) FROM [#TriggerList] WHERE [ObjectId] = @ObjectId;

    WHILE @Id <= @IdMax
    BEGIN

        SELECT @TriggerName = [TriggerName]
        FROM [#TriggerList]
        WHERE [TriggerId] = @Id AND   [ObjectId] = @ObjectId      
        
        SELECT @LineOfCodeId = MIN([LineId]), @LineOfCodeIdMax = MAX([LineId]) 
        FROM [#TriggerDefinitions]
        WHERE [ObjectId] = @ObjectId AND [TriggerId] = @Id       

        WHILE (@LineOfCodeId <= @LineOfCodeIdMax)
        BEGIN
            SELECT @SqlStmt = CONCAT(@SqlStmt, [LineOfCode], @crlf)
            FROM [#TriggerDefinitions] 
            WHERE [ObjectId] = @ObjectId AND [TriggerId] = @Id AND [LineId] = @LineOfCodeId

            SELECT @LineOfCodeId = MIN([LineId]) FROM [#TriggerDefinitions]
            WHERE [ObjectId] = @ObjectId AND [TriggerId] = @Id AND [LineId] > @LineOfCodeId
        END

        IF (@WhatIf = 0)
        BEGIN TRY            
            IF (@ContinueOnError = 1 AND XACT_STATE() <> 0 AND @@TRANCOUNT > 0)
            BEGIN
                COMMIT TRANSACTION;
                BEGIN TRANSACTION;
            END;            
            EXECUTE @SqlExeTargetDb @stmt = @SqlStmt; /* Execute Trigger Definition */
            IF (@ContinueOnError = 1 AND XACT_STATE() <> 0 AND @@TRANCOUNT > 0)
            BEGIN
                COMMIT TRANSACTION;
                BEGIN TRANSACTION;
            END;
            PRINT (CONCAT('Successfully created trigger: ', @TriggerName, ' ON ', QUOTENAME(@SchemaName), '.', QUOTENAME(@TableName), ' in database: ', QUOTENAME(@TargetDbName)));
            UPDATE [#TriggerList] SET [IsClonedSuccessfully] = 1 WHERE [ObjectId] = @ObjectId AND [TriggerId] = @Id;
        END TRY
        BEGIN CATCH
              SET @ErrorMessage = CONCAT('Error: ', ERROR_MESSAGE(), ' Failed executing: ', @SqlStmt);
              IF (@ContinueOnError <> 1)
                  GOTO ERROR;
              ELSE /* continue execution but log the error: */
              BEGIN
                RAISERROR(@ErrorMessage, @ErrorSeverity11, 1) WITH NOWAIT;                
                IF (XACT_STATE() <> 0 AND @@TRANCOUNT > 0)
                BEGIN
                    ROLLBACK TRANSACTION;
                    BEGIN TRANSACTION;
                END;
                
                SET @ParamDefinition = '@_ErrorMessage NVARCHAR(4000), @_Id INT, @_ObjectId INT';
                SET @SqlLogError = 'UPDATE [#TriggerList] SET [ErrorMessage] = CONCAT([ErrorMessage]+''; '', @_ErrorMessage) WHERE [TriggerId] = @_Id AND [ObjectId] = @_ObjectId';
                EXEC sys.sp_executesql @stmt = @SqlLogError, @params = @ParamDefinition, @_ErrorMessage = @ErrorMessage, @_Id = @Id, @_ObjectId = @ObjectId;
                
                IF (XACT_STATE() <> 0 AND @@TRANCOUNT > 0)
                BEGIN
                    COMMIT TRANSACTION;
                    BEGIN TRANSACTION;
                END;
                SET @ErrorMessage = NULL;
              END;
        END CATCH
        ELSE IF (@WhatIf = 1)
        BEGIN
            PRINT (@SqlStmt); /* Printout Constraint Definition */
        END;
        SET @SqlStmt = NULL;
        SELECT @Id = MIN([TriggerId]) FROM [#TriggerList] WHERE [ObjectId] = @ObjectId AND [TriggerId] > @Id;
    END;

    SELECT @SelectedTableId = MIN([Id]) FROM [#SelectedTables] WHERE [Id] > @SelectedTableId;
END;

/* ============================================================================================================================================ */
/* COMMIT OR ROLLBACK: */
/* ============================================================================================================================================ */

IF (XACT_STATE() <> 0 AND @@TRANCOUNT > 0 AND @@ERROR = 0)
BEGIN
    IF (@WhatIf <> 1)
        PRINT ('/* Committing the transaction */');
    COMMIT TRANSACTION;
END;
GOTO SUMMARY;

ERROR:
BEGIN
    IF (@ErrorMessage IS NOT NULL AND XACT_STATE() <> 0 AND @@TRANCOUNT > 0)
    BEGIN
        ROLLBACK TRANSACTION;
        SET @ErrorMessage = CONCAT('/* Rolling back transaction: */ ', @ErrorMessage);
    END;
    RAISERROR(@ErrorMessage, @ErrorSeverity18, @ErrorState) WITH NOWAIT;
    GOTO FINISH;
END;

/* ============================================================================================================================================ */
/* OUTPUT SUMMARY: */
/* ============================================================================================================================================ */

SUMMARY:
BEGIN
    SELECT [Id]
         , [SchemaID]
         , [ObjectID]
         , [SchemaName]
         , [TableName]
         , [IsClonedSuccessfully]
         , [ErrorMessage]
    FROM [#SelectedTables];

    /*
    SELECT CONCAT(QUOTENAME([st].[SchemaName]), '.', QUOTENAME([st].[TableName])) AS [Table]
         , [cl].[column_id]
         , [cl].[ColumnName]
         , [cl].[ColumnDefinition]
         , [cl].[ColumnDefinitionTranslated]
    FROM [#ColumnList] AS [cl]
    JOIN [#SelectedTables] AS [st]
        ON [st].[ObjectID] = [cl].[ObjectId]
    ORDER BY [st].[Id]
           , [cl].[column_id];
    */

    SELECT CONCAT(QUOTENAME([st].[SchemaName]), '.', QUOTENAME([st].[TableName])) AS [Table]
         , [cl].[ObjectId]
         , [cl].[ConstraintId]
         --, ROW_NUMBER() OVER (PARTITION BY [cl].[ObjectId] ORDER BY [cl].[ConstraintId]) AS [Rn]
         , [cl].[ConstraintName]
         , [cl].[IsClonedSuccessfully]
         , [cl].[ErrorMessage]
         , [cl].[Type]
         , [cl].[ConstraintType]
         , [cl].[ColumnList]         
         , [cl].[ConstraintDefinition]
         , [cl].[OnFgPsName]
    FROM [#ConstraintList] AS [cl]
    JOIN [#SelectedTables] AS [st]
        ON [st].[ObjectID] = [cl].[ObjectId]
    ORDER BY [cl].[ObjectId]
           , [cl].[ConstraintId];

    SELECT CONCAT(QUOTENAME([st].[SchemaName]), '.', QUOTENAME([st].[TableName])) AS [Table]
         , [il].[IndexId]
         , [il].[ConstraintId]
         , [il].[IndexType]
         , [il].[XmlType]
         , [il].[IsUnique]
         , [il].[IndexTypeDescr]
         , [il].[IndexName]
         , [il].[IsClonedSuccessfully]
         , [il].[ErrorMessage]
         , [il].[OnTable]
         , [il].[ColumnListIndexed]
         , [il].[ColumnListIncluded]
         , [il].[OnFgPsName]
         , [il].[UsingXmlIndex]
         , [il].[FilteredDefinition]
    FROM [#IndexList] AS [il]
    JOIN [#SelectedTables] AS [st]
        ON [st].[ObjectID] = [il].[ObjectId]

    SELECT CONCAT(QUOTENAME([st].[SchemaName]), '.', QUOTENAME([st].[TableName])) AS [Table]
         , [tl].[TriggerId]
         , [tl].[TriggerName]
         , [tl].[IsEncrypted]
         , [tl].[IsClonedSuccessfully]
         , [tl].[ErrorMessage]
    FROM [#TriggerList] AS [tl]
    JOIN [#SelectedTables] AS [st]
        ON [st].[ObjectID] = [tl].[ObjectId];

END;
FINISH:
END;