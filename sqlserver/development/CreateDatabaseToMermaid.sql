
/*
===============================================================================
 SQL Server データベース構造 Mermaid ER図生成SQL

 Version : Rev2.1
 Target  : SQL Server 2019
 Compatibility Level : 100以上

 【機能】
   ・テーブル定義の取得
   ・スキーマ名の取得
   ・単一主キー、複合主キーの取得
   ・単一外部キー、複合外部キーの取得
   ・データ型、サイズ、NULL許容の取得
   ・拡張プロパティの取得
   ・対象テーブルの絞り込み
   ・厳格な条件による外部キーの推測（オプション）
   ・Mermaid ER図形式での出力

 【注意事項】
　 ※※※　生成AIを使って作成したスクリプトです。十分に確認が取れていない可能性がありますので自己責任でご利用ください。　※※※
   ・データ自体にはアクセスしません。
   ・データベースの更新は行いません。
   ・推測外部キーは初期設定では出力しません。
   ・Mermaidはエンティティの別名表示に対応した版を使用しています。
===============================================================================
*/

SET NOCOUNT ON;

-- ============================================================
-- 1. 出力設定
-- ============================================================

-- 対象スキーマ（NULL：すべて）
DECLARE @SchemaName SYSNAME = NULL;

-- 対象テーブル名（LIKE検索）
DECLARE @TableNamePattern NVARCHAR(128) = N'%';

-- 推測外部キーの出力
DECLARE @IncludeInferredFK BIT = 0;

-- テーブルコメントの出力
DECLARE @IncludeTableComment BIT = 1;

-- 列コメントの出力
DECLARE @IncludeColumnComment BIT = 1;

-- 改行コード
DECLARE @CRLF NVARCHAR(2) = NCHAR(13) + NCHAR(10);


;WITH

-- ============================================================
-- 2. 全ユーザーテーブル
-- ============================================================

AllTables AS (
    SELECT
        t.object_id,
        s.name AS SchemaName,
        t.name AS TableName,

        s.name + N'.' + t.name AS FullTableName,

        -- Mermaid内部識別子
        N'T_' + REPLACE(
            CONVERT(NVARCHAR(20), t.object_id),
            N'-', N'N'
        ) AS EntityName

    FROM sys.tables t

    INNER JOIN sys.schemas s
        ON t.schema_id = s.schema_id

    WHERE t.is_ms_shipped = 0
),

-- ============================================================
-- 3. 出力対象テーブル
-- ============================================================

TargetTables AS (
    SELECT *
    FROM AllTables

    WHERE
        (@SchemaName IS NULL
            OR SchemaName = @SchemaName)

        AND TableName LIKE @TableNamePattern
),

-- ============================================================
-- 4. 全テーブルの列情報
-- ============================================================

AllColumns AS (
    SELECT
        t.object_id,
        t.SchemaName,
        t.TableName,
        t.FullTableName,
        t.EntityName,

        c.column_id,
        c.name AS ColumnName,

        c.system_type_id,
        c.user_type_id,
        c.max_length,
        c.precision,
        c.scale,
        c.collation_name,

        c.is_nullable,
        c.is_identity,
        c.is_computed,
        c.is_hidden,

        SCHEMA_NAME(ty.schema_id) AS TypeSchemaName,
        ty.name AS TypeName,
        ty.is_user_defined,
        ty.is_assembly_type

    FROM AllTables t

    INNER JOIN sys.columns c
        ON t.object_id = c.object_id

    INNER JOIN sys.types ty
        ON c.user_type_id = ty.user_type_id
),

-- ============================================================
-- 5. 主キー情報
-- ============================================================

PrimaryKeys AS (
    SELECT
        c.object_id,
        c.column_id,
        c.TableName,
        c.ColumnName AS PKColumnName,

        c.system_type_id,
        c.user_type_id,
        c.max_length,
        c.precision,
        c.scale,
        c.collation_name,

        ic.key_ordinal,

        COUNT(*) OVER (
            PARTITION BY c.object_id
        ) AS PKColumnCount

    FROM AllColumns c

    INNER JOIN sys.indexes i
        ON c.object_id = i.object_id
        AND i.is_primary_key = 1

    INNER JOIN sys.index_columns ic
        ON i.object_id = ic.object_id
        AND i.index_id = ic.index_id
        AND c.column_id = ic.column_id
        AND ic.key_ordinal > 0
),

-- ============================================================
-- 6. 実外部キーの列情報
-- ============================================================

ActualFKColumns AS (
    SELECT
        fk.object_id AS FKObjectId,
        fk.name AS FKName,

        fk.parent_object_id,
        fkc.parent_column_id,

        fk.referenced_object_id,
        fkc.referenced_column_id,

        fkc.constraint_column_id,

        pc.ColumnName AS ParentColumn,
        rc.ColumnName AS RefColumn,

        pc.is_nullable AS IsNullable,

        fk.is_disabled AS IsDisabled,
        fk.is_not_trusted AS IsNotTrusted,

        CASE
            WHEN pk.column_id IS NOT NULL THEN 1
            ELSE 0
        END AS IsPartOfPK

    FROM sys.foreign_keys fk

    INNER JOIN sys.foreign_key_columns fkc
        ON fk.object_id = fkc.constraint_object_id

    INNER JOIN AllColumns pc
        ON fkc.parent_object_id = pc.object_id
        AND fkc.parent_column_id = pc.column_id

    INNER JOIN AllColumns rc
        ON fkc.referenced_object_id = rc.object_id
        AND fkc.referenced_column_id = rc.column_id

    LEFT JOIN PrimaryKeys pk
        ON pc.object_id = pk.object_id
        AND pc.column_id = pk.column_id
),

-- ============================================================
-- 7. 実外部キーの制約単位の集約
--
-- Rev2.1:
-- 集約処理と文字列連結処理を分離
-- ============================================================

ActualFKAggregated AS (
    SELECT
        FKObjectId,
        FKName,
        parent_object_id,
        referenced_object_id,

        MAX(CONVERT(INT, IsNullable))
            AS HasNullableColumn,

        MAX(CONVERT(INT, IsDisabled))
            AS IsDisabled,

        MAX(CONVERT(INT, IsNotTrusted))
            AS IsNotTrusted,

        MIN(IsPartOfPK)
            AS IsIdentifying,

        COUNT(*) AS FKColumnCount

    FROM ActualFKColumns

    GROUP BY
        FKObjectId,
        FKName,
        parent_object_id,
        referenced_object_id
),

-- ============================================================
-- 8. 実外部キーの列対応情報
--
-- Rev2.1:
-- 互換性レベル100対応
-- STRING_AGG / WITHIN GROUPを使用しない
-- ============================================================

ActualFKs AS (
    SELECT
        afk.*,

        STUFF(
            (
                SELECT
                    N', ' +
                    fc.ParentColumn +
                    N'->' +
                    fc.RefColumn

                FROM ActualFKColumns fc

                WHERE fc.FKObjectId = afk.FKObjectId

                ORDER BY fc.constraint_column_id

                FOR XML PATH(''), TYPE

            ).value('.', 'NVARCHAR(MAX)'),

            1,
            2,
            N''

        ) AS ColumnMapping

    FROM ActualFKAggregated afk
),

-- ============================================================
-- 9. 一意インデックスのキー列
--
-- フィルター付き、無効化済み、仮想インデックスは除外
-- INCLUDE列は一意性の判定対象外
-- ============================================================

UniqueIndexColumns AS (
    SELECT
        i.object_id,
        i.index_id,
        ic.column_id

    FROM sys.indexes i

    INNER JOIN sys.index_columns ic
        ON i.object_id = ic.object_id
        AND i.index_id = ic.index_id

    INNER JOIN AllTables t
        ON i.object_id = t.object_id

    WHERE i.is_unique = 1
      AND i.is_disabled = 0
      AND i.is_hypothetical = 0
      AND i.has_filter = 0

      -- 1: クラスター化
      -- 2: 非クラスター化
      -- 7: 非クラスター化ハッシュ
      AND i.type IN (1, 2, 7)

      AND ic.key_ordinal > 0
),

-- ============================================================
-- 10. 一意な外部キーの判定
--
-- 一意インデックスの全キー列が外部キー列に
-- 含まれる場合、子側は最大1件と判定する
-- ============================================================

UniqueFKs AS (
    SELECT DISTINCT
        afk.FKObjectId

    FROM ActualFKAggregated afk

    INNER JOIN UniqueIndexColumns uic
        ON afk.parent_object_id = uic.object_id

    WHERE NOT EXISTS (
        SELECT 1

        FROM UniqueIndexColumns uc

        WHERE uc.object_id = uic.object_id
          AND uc.index_id = uic.index_id

          AND NOT EXISTS (
              SELECT 1

              FROM ActualFKColumns fc

              WHERE fc.FKObjectId = afk.FKObjectId
                AND fc.parent_column_id = uc.column_id
          )
    )
),

-- ============================================================
-- 11. 推測外部キーの候補列名
--
-- 単一主キーかつテーブル名と主キー列名が
-- 命名規則上一致するものに限定する
-- ============================================================

ReferenceCandidates AS (
    SELECT DISTINCT
        pk.object_id,
        pk.column_id,
        pk.PKColumnName,

        pk.system_type_id,
        pk.user_type_id,
        pk.max_length,
        pk.precision,
        pk.scale,
        pk.collation_name,

        v.CandidateColumnName

    FROM PrimaryKeys pk

    CROSS APPLY (
        VALUES
            (pk.TableName + N'Id'),

            (pk.TableName + N'_id'),

            (
                CASE
                    WHEN RIGHT(pk.TableName, 1) = N's'
                     AND LEN(pk.TableName) > 1
                    THEN LEFT(
                        pk.TableName,
                        LEN(pk.TableName) - 1
                    ) + N'Id'
                END
            ),

            (
                CASE
                    WHEN RIGHT(pk.TableName, 1) = N's'
                     AND LEN(pk.TableName) > 1
                    THEN LEFT(
                        pk.TableName,
                        LEN(pk.TableName) - 1
                    ) + N'_id'
                END
            )

    ) v(CandidateColumnName)

    WHERE @IncludeInferredFK = 1
      AND pk.PKColumnCount = 1
      AND v.CandidateColumnName IS NOT NULL
      AND pk.PKColumnName = v.CandidateColumnName
),

-- ============================================================
-- 12. 推測外部キーの抽出
--
-- ・列名一致
-- ・データ型、サイズ、精度、スケール一致
-- ・照合順序一致
-- ・実外部キーが存在する列は除外
-- ・自己参照は対象外
-- ・IDENTITY列、計算列、非表示列は対象外
-- ============================================================

InferredFKCandidates AS (
    SELECT DISTINCT
        pc.object_id AS parent_object_id,
        pc.column_id AS parent_column_id,
        pc.ColumnName AS ParentColumn,

        rc.object_id AS referenced_object_id,
        rc.column_id AS referenced_column_id,
        rc.PKColumnName AS RefColumn

    FROM AllColumns pc

    INNER JOIN ReferenceCandidates rc
        ON pc.ColumnName = rc.CandidateColumnName

        AND pc.object_id <> rc.object_id

        AND pc.system_type_id = rc.system_type_id
        AND pc.user_type_id = rc.user_type_id
        AND pc.max_length = rc.max_length
        AND pc.precision = rc.precision
        AND pc.scale = rc.scale

        AND ISNULL(pc.collation_name, N'')
            = ISNULL(rc.collation_name, N'')

    WHERE @IncludeInferredFK = 1

      AND pc.is_identity = 0
      AND pc.is_computed = 0
      AND pc.is_hidden = 0

      AND NOT EXISTS (
          SELECT 1

          FROM ActualFKColumns afk

          WHERE afk.parent_object_id = pc.object_id
            AND afk.parent_column_id = pc.column_id
      )
),

-- ============================================================
-- 13. 推測候補の件数判定
--
-- 出力対象の絞り込み前に候補数を判定する
-- ============================================================

InferredFKsRanked AS (
    SELECT
        *,

        COUNT(*) OVER (
            PARTITION BY
                parent_object_id,
                parent_column_id
        ) AS CandidateCount

    FROM InferredFKCandidates
),

-- ============================================================
-- 14. 推測外部キーの出力候補
--
-- 候補が複数存在する場合は出力しない
-- ============================================================

InferredFKs AS (
    SELECT *
    FROM InferredFKsRanked

    WHERE CandidateCount = 1
),

-- ============================================================
-- 15. 出力対象列とコメントの取得
-- ============================================================

TableColumns AS (
    SELECT
        c.*,

        CASE
            WHEN @IncludeTableComment = 1
            THEN CONVERT(NVARCHAR(MAX), ep_t.value)
            ELSE NULL
        END AS TableComment,

        CASE
            WHEN @IncludeColumnComment = 1
            THEN CONVERT(NVARCHAR(MAX), ep_c.value)
            ELSE NULL
        END AS ColComment,

        CASE
            WHEN pk.column_id IS NOT NULL THEN 1
            ELSE 0
        END AS IsPK,

        CASE
            WHEN EXISTS (
                SELECT 1

                FROM ActualFKColumns afk

                WHERE afk.parent_object_id = c.object_id
                  AND afk.parent_column_id = c.column_id
            )
            THEN 1
            ELSE 0
        END AS IsFK

    FROM AllColumns c

    INNER JOIN TargetTables t
        ON c.object_id = t.object_id

    LEFT JOIN PrimaryKeys pk
        ON c.object_id = pk.object_id
        AND c.column_id = pk.column_id

    LEFT JOIN sys.extended_properties ep_t
        ON c.object_id = ep_t.major_id
        AND ep_t.minor_id = 0
        AND ep_t.class = 1
        AND ep_t.name = N'MS_Description'

    LEFT JOIN sys.extended_properties ep_c
        ON c.object_id = ep_c.major_id
        AND c.column_id = ep_c.minor_id
        AND ep_c.class = 1
        AND ep_c.name = N'MS_Description'
),

-- ============================================================
-- 16. Mermaid用識別子の変換判定
--
-- COL_から始まる列名も変換対象とすることで
-- 自動生成識別子との重複を防止する
-- ============================================================

ColumnNameFlags AS (
    SELECT
        *,

        CASE
            WHEN ColumnName COLLATE Latin1_General_100_BIN2
                    LIKE N'[A-Za-z]%'

             AND ColumnName COLLATE Latin1_General_100_BIN2
                    NOT LIKE N'%[^A-Za-z0-9_]%'

             AND UPPER(ColumnName) NOT LIKE N'COL[_]%'

             AND UPPER(ColumnName) NOT IN (
                 N'PK', N'FK', N'UK',
                 N'ERDIAGRAM', N'DIRECTION',
                 N'STYLE', N'CLASS', N'CLASSDEF',
                 N'END'
             )

            THEN 0
            ELSE 1

        END AS IsColumnNameConverted,

        CASE
            WHEN TypeName COLLATE Latin1_General_100_BIN2
                    LIKE N'[A-Za-z]%'

             AND TypeName COLLATE Latin1_General_100_BIN2
                    NOT LIKE N'%[^A-Za-z0-9_]%'

             AND UPPER(TypeName) NOT IN (
                 N'PK', N'FK', N'UK',
                 N'ERDIAGRAM', N'DIRECTION',
                 N'STYLE', N'CLASS', N'CLASSDEF',
                 N'END'
             )

            THEN 0
            ELSE 1

        END AS IsTypeNameConverted

    FROM TableColumns
),

-- ============================================================
-- 17. Mermaid用のデータ型、識別子、コメント生成
-- ============================================================

ColumnsFormatted AS (
    SELECT
        *,

        -- データ型とサイズ
        CASE
            WHEN IsTypeNameConverted = 1
            THEN N'custom_type'
            ELSE TypeName
        END +

        CASE
            WHEN is_user_defined = 1
              OR is_assembly_type = 1
            THEN N''

            WHEN TypeName IN (N'nvarchar', N'nchar')
            THEN
                N'(' +
                CASE
                    WHEN max_length = -1
                    THEN N'MAX'

                    ELSE CONVERT(
                        NVARCHAR(10),
                        max_length / 2
                    )
                END +
                N')'

            WHEN TypeName IN (
                N'varchar', N'char',
                N'varbinary', N'binary'
            )
            THEN
                N'(' +
                CASE
                    WHEN max_length = -1
                    THEN N'MAX'

                    ELSE CONVERT(
                        NVARCHAR(10),
                        max_length
                    )
                END +
                N')'

            WHEN TypeName IN (N'decimal', N'numeric')
            THEN
                N'(' +
                CONVERT(NVARCHAR(10), precision) +
                N'_' +
                CONVERT(NVARCHAR(10), scale) +
                N')'

            WHEN TypeName IN (
                N'datetime2',
                N'datetimeoffset',
                N'time'
            )
            THEN
                N'(' +
                CONVERT(NVARCHAR(10), scale) +
                N')'

            WHEN TypeName = N'float'
            THEN
                N'(' +
                CONVERT(NVARCHAR(10), precision) +
                N')'

            ELSE N''

        END AS DataTypeWithSize,

        -- Mermaid用の列識別子
        CASE
            WHEN IsColumnNameConverted = 0
            THEN ColumnName

            ELSE N'COL_' +
                CONVERT(NVARCHAR(10), column_id)

        END AS MermaidColumnName,

        -- テーブル表示名
        REPLACE(
            REPLACE(
                REPLACE(
                    REPLACE(
                        FullTableName,
                        NCHAR(13), N' '
                    ),
                    NCHAR(10), N' '
                ),
                NCHAR(9), N' '
            ),
            N'"', N''''
        ) AS SafeTableName,

        -- テーブルコメント
        REPLACE(
            REPLACE(
                REPLACE(
                    REPLACE(
                        TableComment,
                        NCHAR(13), N' '
                    ),
                    NCHAR(10), N' '
                ),
                NCHAR(9), N' '
            ),
            N'"', N''''
        ) AS SafeTableComment,

        -- 列コメント
        REPLACE(
            REPLACE(
                REPLACE(
                    REPLACE(
                        ColComment,
                        NCHAR(13), N' '
                    ),
                    NCHAR(10), N' '
                ),
                NCHAR(9), N' '
            ),
            N'"', N''''
        ) AS SafeColComment,

        -- 元の列名
        REPLACE(
            REPLACE(
                REPLACE(
                    REPLACE(
                        ColumnName,
                        NCHAR(13), N' '
                    ),
                    NCHAR(10), N' '
                ),
                NCHAR(9), N' '
            ),
            N'"', N''''
        ) AS SafeOriginalColumnName,

        -- 元のデータ型名
        -- ユーザー定義型はスキーマ名を付加する
        REPLACE(
            REPLACE(
                REPLACE(
                    REPLACE(
                        CASE
                            WHEN is_user_defined = 1
                            THEN ISNULL(
                                TypeSchemaName + N'.',
                                N''
                            ) + TypeName

                            ELSE TypeName
                        END,

                        NCHAR(13), N' '
                    ),
                    NCHAR(10), N' '
                ),
                NCHAR(9), N' '
            ),
            N'"', N''''
        ) AS SafeOriginalTypeName

    FROM ColumnNameFlags
),

-- ============================================================
-- 18. 列コメントの組み立て
-- ============================================================

ColumnsRanked AS (
    SELECT
        *,

        ROW_NUMBER() OVER (
            PARTITION BY object_id
            ORDER BY column_id
        ) AS RowNum,

        COUNT(*) OVER (
            PARTITION BY object_id
        ) AS TotalCols,

        LTRIM(RTRIM(
            CONVERT(NVARCHAR(MAX), N'') +

            CASE
                WHEN is_nullable = 0
                THEN N'[NOT NULL] '
                ELSE N''
            END +

            CASE
                WHEN is_identity = 1
                THEN N'[IDENTITY] '
                ELSE N''
            END +

            CASE
                WHEN is_computed = 1
                THEN N'[COMPUTED] '
                ELSE N''
            END +

            CASE
                WHEN is_hidden = 1
                THEN N'[HIDDEN] '
                ELSE N''
            END +

            CASE
                WHEN IsColumnNameConverted = 1
                THEN
                    N'[COLUMN: ' +
                    SafeOriginalColumnName +
                    N'] '
                ELSE N''
            END +

            CASE
                WHEN is_user_defined = 1
                  OR is_assembly_type = 1
                  OR IsTypeNameConverted = 1
                THEN
                    N'[TYPE: ' +
                    SafeOriginalTypeName +
                    N'] '
                ELSE N''
            END +

            ISNULL(SafeColComment, N'')

        )) AS FinalComment

    FROM ColumnsFormatted
),

-- ============================================================
-- 19. テーブル定義の生成
-- ============================================================

TableDefs AS (
    SELECT
        1 AS SortGroup,
        FullTableName AS SortName,
        object_id AS SortObjectId,
        RowNum AS ColOrder,

        CONVERT(NVARCHAR(MAX), N'') +

        CASE
            WHEN RowNum = 1
            THEN

                CASE
                    WHEN NULLIF(
                        LTRIM(RTRIM(SafeTableComment)),
                        N''
                    ) IS NOT NULL

                    THEN
                        N'    %% ' +
                        SafeTableComment +
                        @CRLF

                    ELSE N''
                END +

                N'    ' +
                EntityName +
                N'["' +
                SafeTableName +
                N'"] {' +
                @CRLF

            ELSE N''
        END +

        N'        ' +
        DataTypeWithSize +
        N' ' +
        MermaidColumnName +

        CASE
            WHEN IsPK = 1 AND IsFK = 1
            THEN N' PK,FK'

            WHEN IsPK = 1
            THEN N' PK'

            WHEN IsFK = 1
            THEN N' FK'

            ELSE N''
        END +

        CASE
            WHEN NULLIF(FinalComment, N'') IS NOT NULL
            THEN N' "' + FinalComment + N'"'

            ELSE N''
        END +

        CASE
            WHEN RowNum = TotalCols
            THEN @CRLF + N'    }'

            ELSE N''
        END AS LineText

    FROM ColumnsRanked
),

-- ============================================================
-- 20. 実リレーションの生成
--
-- 親側：
--   NULL許容あり → 0または1
--   NULL許容なし → 1
--
-- 子側：
--   一意性あり → 0または1
--   一意性なし → 0以上
--
-- 識別関係：
--   外部キーの全構成列が子の主キーに含まれる場合
--
-- Rev2.1:
-- 制約状態と設計上の多重度を分離する
-- ============================================================

Relations_Actual AS (
    SELECT
        2 AS SortGroup,

        rt.FullTableName +
            N'_' + pt.FullTableName +
            N'_' + afk.FKName AS SortName,

        afk.FKObjectId AS SortObjectId,
        0 AS ColOrder,

        CONVERT(NVARCHAR(MAX), N'    ') +

        rt.EntityName +

        -- 親側の多重度
        CASE
            WHEN afk.HasNullableColumn = 1
            THEN N' |o'
            ELSE N' ||'
        END +

        -- 識別・非識別リレーション
        CASE
            WHEN afk.IsIdentifying = 1
            THEN N'--'
            ELSE N'..'
        END +

        -- 子側の多重度
        CASE
            WHEN ufk.FKObjectId IS NOT NULL
            THEN N'o| '
            ELSE N'o{ '
        END +

        pt.EntityName +

        N' : "' +

        -- 外部キー名と列対応
        REPLACE(
            REPLACE(
                REPLACE(
                    REPLACE(
                        afk.FKName +
                        N' (' +
                        ISNULL(afk.ColumnMapping, N'') +
                        N')',

                        NCHAR(13), N' '
                    ),
                    NCHAR(10), N' '
                ),
                NCHAR(9), N' '
            ),
            N'"', N''''
        ) +

        -- 制約の状態
        CASE
            WHEN afk.IsDisabled = 1
            THEN N' [DISABLED]'
            ELSE N''
        END +

        CASE
            WHEN afk.IsNotTrusted = 1
            THEN N' [NOT TRUSTED]'
            ELSE N''
        END +

        N'"' AS LineText

    FROM ActualFKs afk

    INNER JOIN TargetTables pt
        ON afk.parent_object_id = pt.object_id

    INNER JOIN TargetTables rt
        ON afk.referenced_object_id = rt.object_id

    LEFT JOIN UniqueFKs ufk
        ON afk.FKObjectId = ufk.FKObjectId
),

-- ============================================================
-- 21. 推測リレーションの生成
--
-- 推測であることをラベルで明示する
-- 多重度は仮定として任意の参照を表現する
-- ============================================================

Relations_Inferred AS (
    SELECT
        3 AS SortGroup,

        rt.FullTableName +
            N'_' + pt.FullTableName +
            N'_' + ifk.ParentColumn AS SortName,

        ifk.parent_object_id AS SortObjectId,
        ifk.parent_column_id AS ColOrder,

        CONVERT(NVARCHAR(MAX), N'    ') +

        rt.EntityName +
        N' |o..o{ ' +
        pt.EntityName +

        N' : "INFERRED: ' +

        REPLACE(
            REPLACE(
                REPLACE(
                    REPLACE(
                        ifk.ParentColumn +
                        N'->' +
                        ifk.RefColumn,

                        NCHAR(13), N' '
                    ),
                    NCHAR(10), N' '
                ),
                NCHAR(9), N' '
            ),
            N'"', N''''
        ) +

        N'"' AS LineText

    FROM InferredFKs ifk

    INNER JOIN TargetTables pt
        ON ifk.parent_object_id = pt.object_id

    INNER JOIN TargetTables rt
        ON ifk.referenced_object_id = rt.object_id
),

-- ============================================================
-- 22. 出力内容の結合
-- ============================================================

Combined AS (
    SELECT
        0 AS SortGroup,
        N'' AS SortName,
        0 AS SortObjectId,
        0 AS ColOrder,

        CONVERT(
            NVARCHAR(MAX),
            N'erDiagram'
        ) AS LineText

    UNION ALL

    SELECT
        SortGroup,
        SortName,
        SortObjectId,
        ColOrder,
        LineText

    FROM TableDefs

    UNION ALL

    SELECT
        SortGroup,
        SortName,
        SortObjectId,
        ColOrder,
        LineText

    FROM Relations_Actual

    UNION ALL

    SELECT
        SortGroup,
        SortName,
        SortObjectId,
        ColOrder,
        LineText

    FROM Relations_Inferred
)

-- ============================================================
-- 23. Mermaidコードの出力
-- ============================================================

SELECT
    LineText AS MermaidCode

FROM Combined

ORDER BY
    SortGroup,
    SortName,
    SortObjectId,
    ColOrder;
