# METADATA_MANAGER_DESIGN.md — DuckLakeMetadataManager 通信层与后端方言

> 行号基准:commit `47187559`。所有 `file:line` 相对 repo 根。

## 概述

`DuckLakeMetadataManager` 是 DuckLake 与元数据库之间的**通信层**(类注释原话:"the
communication layer between the system and the metadata catalog",
`src/include/storage/ducklake_metadata_manager.hpp:112`)。它不持有连接、不管理事务
生命周期——连接和事务边界归 `DuckLakeTransaction`(见
[TRANSACTION_DESIGN.md](TRANSACTION_DESIGN.md));manager 的职责是三件事:

1. **SQL 生成**:把"读 snapshot 下的 catalog"、"写入一批 data file"等语义操作翻译成
   带占位符(`{METADATA_CATALOG}`/`{SNAPSHOT_ID}` 等)的 SQL 文本;
2. **执行与解析**:经事务的 `Connection` 执行 SQL,把 `QueryResult` 解析回
   `ducklake_metadata_info.hpp` 中的 C++ 结构体(`DuckLakeCatalogInfo`、
   `DuckLakeFileListEntry`、`DuckLakeGlobalStatsInfo`……);
3. **后端方言适配**:基类直接面向 DuckDB 元数据库;Postgres/SQLite/quack 子类覆盖
   类型映射、执行通道、能力探测等少量虚函数,绝大多数 SQL 模板三个后端共用。

类层次(实现文件):

```
DuckLakeMetadataManager                      src/storage/ducklake_metadata_manager.cpp (5380 行)
  │   基类 == DuckDB 后端(本地/远端 duckdb 文件,亦是默认 fallback)
  │
  ├── PostgresMetadataManager                src/metadata_manager/postgres_metadata_manager.cpp
  │     读走 postgres_scanner ATTACH(DuckDB 本地执行),写走 CALL postgres_execute()
  ├── SQLiteMetadataManager                  src/metadata_manager/sqlite_metadata_manager.cpp
  │     读写都走 sqlite_scanner ATTACH,仅覆盖类型支持/映射
  ├── QuackMetadataManager                   src/metadata_manager/quack_metadata_manager.cpp
  │     远端 DuckDB server,读写全部包成 CALL quack_query_by_name() RPC
  │
  └── DuckLakeMetadataManagerV1_1<Base>      src/metadata_manager/ducklake_metadata_manager_v1_1.cpp
        模板装饰层,Base ∈ {DuckLakeMetadataManager, SQLiteMetadataManager,
        PostgresMetadataManager};只改版本字符串,v1.1-dev1 与 v1.0 无 DDL 差异
```

后端的选择由静态注册表 `metadata_managers`(`src/storage/ducklake_metadata_manager.cpp:44-47`,
预注册 `postgres`/`postgres_scanner`/`quack`/`quack_scanner`/`sqlite`/`sqlite_scanner` 六个
key)+ `Register()`(`:51`)动态扩展;`Create()`(`:59-72`)按
`catalog.MetadataType()`(ATTACH 时的 `METADATA_CATALOG_TYPE` 参数)查表,查不到则
fallback 到基类(DuckDB)。ATTACH 流程中何时构造 manager、metadata db 如何挂载见
[ATTACH_CATALOG_DESIGN.md](ATTACH_CATALOG_DESIGN.md)。

大量接口是 **static 纯 SQL builder**(返回带占位符的 SQL 串,不执行)——这是为了让
server-side commit 路径(quack 后端,见 [COMMIT_PROTOCOL_DESIGN.md](COMMIT_PROTOCOL_DESIGN.md))
能在不持有 manager 实例的情况下复用同一套 SQL 模板(hpp:196-198 的注释明说了这个动机)。

关键源码位置:

| 内容 | 位置 |
|---|---|
| 类定义 / 接口面 | `src/include/storage/ducklake_metadata_manager.hpp:113-526` |
| 解析结果结构体 | `src/include/storage/ducklake_metadata_info.hpp` |
| 注册表 / 工厂 | `ducklake_metadata_manager.cpp:44-72` |
| 占位符替换 | `SubstituteCatalogPlaceholders` :2379 / `SubstituteSnapshotPlaceholders` :2398 |
| 执行通道 | `Query`/`Execute` :2409-2421;`DuckLakeTransaction::ExecuteRaw` `src/storage/ducklake_transaction.cpp:1505` |
| 28 张表 DDL | `GetCreateTableStatements` :213-243(数据字典见 [METADATA_SCHEMA_DESIGN.md](METADATA_SCHEMA_DESIGN.md)) |
| catalog 整体加载 | `BuildCatalogForSnapshot` :611-915 |
| 文件清单查询 | `GetFilesForTable` :1660 / `GetTableInsertions` :1818 / `GetTableDeletions` :1883 / `GetExtendedFilesForTable` :2071 / `GetFilesForCompaction` :2150 |
| filter 下推 SQL | `ConvertFilterPushdownToSQL` :1378 / `GenerateConstantFilter` :1149 / `BuildBucketPartitionPruningClause` :1604 |
| 路径解析 | :3354-3569 |
| 迁移 | `MigrateV01..V10` :251-376;触发链 `src/storage/ducklake_initializer.cpp:194-230` |
| Postgres 子类 | `src/metadata_manager/postgres_metadata_manager.cpp` + `src/include/metadata_manager/postgres_metadata_manager.hpp` |
| SQLite 子类 | `src/metadata_manager/sqlite_metadata_manager.cpp` |
| quack 子类 | `src/metadata_manager/quack_metadata_manager.cpp` |
| V1_1 模板 | `src/metadata_manager/ducklake_metadata_manager_v1_1.cpp` |

## 关联文档

- [ATTACH_CATALOG_DESIGN.md](ATTACH_CATALOG_DESIGN.md) — ATTACH 时如何选择/构造 manager、metadata db 挂载
- [TRANSACTION_DESIGN.md](TRANSACTION_DESIGN.md) — `DuckLakeTransaction` 与 metadata Connection 生命周期
- [COMMIT_PROTOCOL_DESIGN.md](COMMIT_PROTOCOL_DESIGN.md) — 提交协议、冲突重试、server-side commit(`ducklake_commit`)
- [METADATA_SCHEMA_DESIGN.md](METADATA_SCHEMA_DESIGN.md) — 28 张元数据表逐列数据字典
- [SCAN_DESIGN.md](SCAN_DESIGN.md) — filter 下推的调用方语义(谁构造 `FilterPushdownInfo`)
- [DML_DESIGN.md](DML_DESIGN.md) / [DATA_INLINING_DESIGN.md](DATA_INLINING_DESIGN.md) — 写路径与 inlined data 的上层逻辑
- [MAINTENANCE_DESIGN.md](MAINTENANCE_DESIGN.md) — expire/cleanup/compaction 调用方

## 一、执行通道:借事务的 Connection 执行 SQL

### 1.1 Connection 从哪来

manager 自己不开连接。`DuckLakeTransaction::GetConnection()`
(`src/storage/ducklake_transaction.cpp:759-786`)懒构造一条指向**同一个 DuckDB 实例**的
`Connection`,并做四件事:把 catalog search path 锁定到
`<metadata_catalog>.<metadata_schema>`;把 `catalog_error_max_schemas` 设为 0(报错时不
扫其他 catalog);若后端是 postgres 则 `SET pg_experimental_filter_pushdown=false`
(postgres_scanner 的实验性下推不支持 EXPRESSION_FILTER);最后 `BeginTransaction()` 并设置
`current_transaction_invalidation_policy='SYNTACTIC_ERRORS_DO_NOT_INVALIDATE'`。也就是说,
**元数据库上的事务边界 = 这条 Connection 上的显式事务**,DuckLake 事务 commit/rollback 时
转发到 `connection->Commit()/Rollback()`(:740-757)。

最底层入口是 `DuckLakeTransaction::ExecuteRaw()`(:1505-1519):执行 + 计时 + 写
`DuckLakeMetadataLogType` 日志 + 可选回调 `GetQueryCallback()`。它**不做任何
占位符替换**——替换是 manager 层的事。

### 1.2 Query / Execute 三个重载

```cpp
// ducklake_metadata_manager.cpp:2409-2421
unique_ptr<QueryResult> Execute(DuckLakeSnapshot, string &query);   // 基类 = Query
unique_ptr<QueryResult> Query(DuckLakeSnapshot, string &query);     // 先替换快照占位符
unique_ptr<QueryResult> Query(string &query);                       // 只替换 catalog 占位符
```

调用链:`Query(snapshot, q)` → `SubstituteSnapshotPlaceholders` → `Query(q)` →
`SubstituteCatalogPlaceholders` → `transaction.ExecuteRaw(q)`。注意参数是 `string &`,
替换**就地改写调用者的字符串**(日志里看到的是替换后的最终 SQL)。

`Execute` 与 `Query` 的区分只对 Postgres 有意义:基类 `Execute` 就是 `Query`(:2409),
而 `PostgresMetadataManager::Execute` 把 SQL 包进 `CALL postgres_execute(...)` 发到
Postgres 端执行(见第六章)。约定是:**读用 Query,写(commit 批)用 Execute**——
`DuckLakeTransaction::RunCommitLoop` 里 `execute_commit_batch` 回调用的就是
`metadata_manager->Execute(snapshot, query)`(`ducklake_transaction.cpp:1361`)。

`DuckLakeTransaction::Query()`(:1521-1527)是个便捷转发,等价于
`metadata_manager->Query(...)`——manager 内部大量 `transaction.Query(...)` 调用其实是
绕了一圈又回到自己,这样基类方法的 SQL 也能享受子类覆盖的 `Query`(quack 的 RPC 包装
正是靠这个生效)。

### 1.3 占位符机制

两组占位符,全部用 `StringUtil::Replace` 纯文本替换(没有 prepared statement):

**catalog 组**(`SubstituteCatalogPlaceholders`,:2379-2396):

| 占位符 | 替换为 |
|---|---|
| `{METADATA_CATALOG}` | `<catalog标识符>.<schema标识符>`(SQL identifier,带引号转义) |
| `{METADATA_CATALOG_NAME_LITERAL}` / `{METADATA_CATALOG_NAME_IDENTIFIER}` | catalog 名的字面量 / 标识符形式 |
| `{METADATA_SCHEMA_NAME_LITERAL}` / `{METADATA_SCHEMA_ESCAPED}` | schema 名字面量 / 内嵌单引号转义版(用于嵌套在字符串里的 SQL,见 postgres_query) |
| `{METADATA_PATH}` / `{DATA_PATH}` | metadata 路径 / data 根路径(字面量) |

**snapshot 组**(`SubstituteSnapshotPlaceholders`,:2398-2407):`{SNAPSHOT_ID}`、
`{SCHEMA_VERSION}`、`{NEXT_CATALOG_ID}`、`{NEXT_FILE_ID}`,以及提交信息
`{AUTHOR}`/`{COMMIT_MESSAGE}`/`{COMMIT_EXTRA_INFO}`(取自 `transaction.GetCommitInfo()`)。

snapshot 组占位符是**提交重试的关键设计**:commit 批 SQL 在冲突重试时只需用新 snapshot
重新替换一遍模板即可重放,不必重新生成(详见 COMMIT_PROTOCOL_DESIGN.md)。此外还有局部
约定:个别函数自己定义一次性占位符,如 `{TABLE_ID}`(:498)和迁移用的
`{IF_NOT_EXISTS}`/`{IF_EXISTS}`/`{WHERE_EMPTY}`(见第五章)。

版本可见性谓词在所有读 SQL 中是统一的左闭右开 `[begin_snapshot, end_snapshot)`:

```sql
{SNAPSHOT_ID} >= begin_snapshot AND ({SNAPSHOT_ID} < end_snapshot OR end_snapshot IS NULL)
```

## 二、接口面分组走读

### 2.1 初始化:AttachMetadata / MetadataExists / InitializeDuckLake

- `AttachMetadata(attach_query)`(:161-165):执行 initializer 拼好的
  `ATTACH OR REPLACE {METADATA_PATH} AS {METADATA_CATALOG_NAME_IDENTIFIER} (...)`
  (`ducklake_initializer.cpp:67-70`)。基类直接 `ExecuteRaw`;quack 覆盖为带重试的
  fresh Connection(见第八章)。
- `MetadataExistsQuery()`(:167-169):`SELECT NULL FROM {METADATA_CATALOG}.ducklake_metadata LIMIT 1`。
  `MetadataExists()`(:171-183)靠**错误类型**判断:`ExceptionType::CATALOG` ⇒ 全新
  DuckLake(表不存在),其他错误向上抛。注释(`ducklake_initializer.cpp:99-101`)解释了
  为什么不用 `duckdb_tables()`:避免某个损坏的 catalog 阻塞无关 DuckLake 的初始化。
- `InitializeDuckLake(has_explicit_schema, encryption)`(:185-211):一条多语句批:
  可选 `CREATE SCHEMA IF NOT EXISTS {METADATA_CATALOG}` + `GetCreateTableStatements()`
  的 28 张表 DDL(:215-242,逐列含义归 METADATA_SCHEMA_DESIGN.md)+ 初始数据:
  snapshot 0、`created_schema:"main"` 变更记录、`ducklake_metadata` 四个 key
  (`version`/`created_by`/`data_path`/`encrypted`)、schema 0(`main`,相对路径 `main/`)。
- `LoadDuckLake()`(:378-425):读 `ducklake_metadata` 全表,失败时降级为两列查询
  (兼容尚无 `scope` 列的 v0.1 库),按 `scope`(NULL/schema/table)分发到
  `DuckLakeMetadata` 的全局 tag / schema_settings / table_settings。
- `GetVersionString()`(:246-249)返回 `"1.0"`,写进 `ducklake_metadata.version`;
  V1_1 模板覆盖为 `"1.1-dev1"`(第九章)。

### 2.2 快照:GetSnapshot 各 overload

- `LatestSnapshotQuery()`(static,:4175-4177):
  `SELECT snapshot_id, schema_version, next_catalog_id, next_file_id FROM ... ducklake_snapshot
  WHERE snapshot_id = (SELECT MAX(snapshot_id) ...)`。虚函数 `GetLatestSnapshotQuery()`
  (:4179)默认转发到它,Postgres 覆盖为 server 端执行版(第六章)。
- `GetSnapshot()`(:4183-4193):执行上述查询 + `ParseSnapshot`(:4160-4173,多行即
  视为 catalog 损坏)。
- `GetSnapshot(BoundAtClause&, SnapshotBound)`(:4195-4231):time travel。
  `AT (VERSION => n)` 直接按 snapshot_id 查;`AT (TIMESTAMP => t)` 按
  `snapshot_time::TIMESTAMPTZ >/<= t ORDER BY ... LIMIT 1`,`SnapshotBound`
  决定取下界还是上界(`FOR ... BETWEEN` 场景两端各调一次)。
- `GetSnapshotAndStatsAndChangesQuery()`(:4082-4132):提交冲突检测专用,把
  "最新 snapshot + 自 `{SNAPSHOT_ID}` 以来的 changes_made 聚合 + 全部 global table stats"
  用 `UNION ALL` 拼成**单次往返**(第一行是 snapshot+changes,后续行是 stats);
  `ParseSnapshotAndStatsAndChanges`(:4134-4151)按行号区分解析。这是为远端后端
  (Postgres/quack)省 round-trip 的典型手法。

### 2.3 catalog 加载:GetCatalogForSnapshot / BuildCatalogForSnapshot

`GetCatalogForSnapshot(snapshot)`(:604-609)只是一层薄封装,把
`[this](s, q) { return Query(s, q); }` 作为 executor 传给 **static** 的
`BuildCatalogForSnapshot(snapshot, query_executor, base_data_path, separator)`
(:611-915)。static 化的意义同样是给 server-side 路径复用(hpp:207-209 注释)。

它**一次加载某个 snapshot 可见的全部 catalog 对象**,共 6 条查询,产物是
`DuckLakeCatalogInfo { schemas, tables, views, macros, partitions, sorts }`:

1. **schema**(:616-620):`ducklake_schema` 直查;`path` 为 NULL 时回退
   `base_data_path`,否则经 `FromRelativePath(path, base_data_path, separator)` 解析
   (schema 路径继承,见第四章)。
2. **table + column(+tags + inlined tables)**(:655-684):核心一条大 SQL——
   `ducklake_table LEFT JOIN ducklake_column USING (table_id)`,表级 tag、
   per-table inlined data 表清单、列级 tag 都用**相关子查询 + ListAggregation** 内联成
   单列,避免多次往返:

   ```sql
   SELECT schema_id, tbl.table_id, table_uuid::VARCHAR, table_name,
       (SELECT LIST({'key': key, 'value': value}) FROM ... ducklake_tag tag
        WHERE object_id=table_id AND <可见性谓词>) AS tag,
       (SELECT LIST({'name': table_name, 'schema_version': schema_version})
        FROM ... ducklake_inlined_data_tables ...) AS inlined_data_tables,
       path, path_is_relative,
       col.column_id, column_name, column_type, ..., parent_column,
       (SELECT LIST(...) FROM ... ducklake_column_tag ...) AS column_tags, default_value_type
   FROM {METADATA_CATALOG}.ducklake_table tbl
   LEFT JOIN {METADATA_CATALOG}.ducklake_column col USING (table_id)
   WHERE <tbl 可见> AND (<col 可见> OR column_id IS NULL)
   ORDER BY table_id, parent_column NULLS FIRST, column_order
   ```

   解析按 `ORDER BY table_id` 做 run-length 分组(`tables.back().id != table_id` 才新建
   表项,:694);嵌套列靠 `parent_column NULLS FIRST` 保证父先于子,
   `AddChildColumn()`(:427-438)递归挂到父列的 `children`。零列的表直接报
   catalog 损坏(:731-733)。
3. **view**(:771-781):带 tag 子查询,`column_aliases` 用
   `DuckLakeUtil::ParseQuotedList` 解析。
4. **macro**(:820-829):两层嵌套 ListAggregation——实现列表里每个 struct 内嵌参数
   列表(:803-817),`LoadMacroImplementations`(:467-491)两层展开。
5. **partition**(:845-851):`ducklake_partition_info JOIN ducklake_partition_column`,
   按 `table_id, partition_id, partition_key_index` 排序后 run-length 分组。
6. **sort**(:876-882):`ducklake_sort_info JOIN ducklake_sort_expression`,同样手法。

`ListAggregation(fields)`(:149-159)是 static 的,只产 DuckDB 方言
`LIST({'k1': v1, ...})`。hpp:403-405 的注释写着 Postgres 应是
`jsonb_agg(jsonb_build_object(...))`,但**当前 HEAD 并没有 Postgres 覆盖**(static 也
无法虚化)——之所以可行,是因为 Postgres 后端的读查询并不发往 Postgres,而是由本地
DuckDB 引擎在 postgres_scanner 挂载的 catalog 上执行(第六章),`LIST({...})` 由
DuckDB 自己求值;对应的解析端 `LoadTags`/`LoadInlinedDataTables`(:440-465)按
LIST-of-STRUCT 取值。

### 2.4 文件操作

公共构件:

- `GetFileSelectList(prefix)`(:1033-1048):产
  `path, path_is_relative, file_size_bytes, footer_size[, encryption_key]` 的别名选择列,
  未加密时砍掉 key 列;`GetDeleteFileSelectList`(:1050)再加 `format`。
- `ReadDataFile`/`ReadDeleteFile`(:1054-1095):模板化的逐列游标解析,`col_idx` 引用
  递增;路径经 `FromRelativePath(path, table.DataPath())` 还原为绝对路径,加密库强制要求
  `encryption_key` 非 NULL(:1077-1079)。

五个查询入口(filter 下推部分见第三章):

- **`GetFilesForTable`**(:1660-1816):常规 scan 的文件清单。基础形态
  (:1743-1755)是 `ducklake_data_file data LEFT JOIN (delete_file 可见子查询) del ON
  del.data_file_id = data.data_file_id`,主表谓词即可见性 + `table_id`。三个可选增强:
  ① filter 下推的 CTE + WHERE(第三章);② bucket 分区裁剪子句;③ Top-N dynamic filter:
  对带 dynamic filter 的列追加
  `LEFT JOIN ducklake_file_column_stats stats_i`(:1690-1693)把该列 min/max 带回
  `DuckLakeFileListEntry::column_min_max`,并按第一个 dynamic filter 列生成
  `ORDER BY max_value DESC / min_value ASC NULLS LAST`(:1699-1713),让文件按可能命中
  Top-N 的顺序返回以便早裁剪。`partial_max` 列经 `SetSnapshotFilter`(:1097-1104)转成
  行级 `snapshot_filter_max`(部分可见文件,行内嵌 snapshot id 过滤)。最后用
  `ReadInlinedFileDeletions`(:2966)把 metadata 内联删除合并进每个文件项。
- **`GetTableInsertions`**(:1818-1881):增量 scan(`ducklake_table_insertions` 表函数,
  归 TABLE_FUNCTIONS_DESIGN.md)。谓词是"`begin_snapshot` 落在 [start, end] **或**
  `partial_max >= start`"(:1840-1843);delete file 一律为 NULL(用常量子查询占位),
  必要时设置 `snapshot_filter_min/max` 行级过滤。
- **`GetTableDeletions`**(:1883-2069):最复杂的一条。注释(:1896-1900)给出三类删除:
  ① `ducklake_delete_file` 的 partial delete;② data file 整体被置 `end_snapshot`
  (full file delete);③ metadata 内联删除。SQL 结构:可选的 `inlined_dels` CTE(把
  内联删除按 file_id `LIST(STRUCT_PACK(row_id, snapshot_id))` 聚合)+ `main_results` CTE
  内 `UNION ALL` 三段;每段都用 `LEFT JOIN LATERAL (SELECT DISTINCT ON (data_file_id) ...
  ORDER BY begin_snapshot DESC)` 找出**前一版 delete file**(排除此前已删的行)。
- **`GetExtendedFilesForTable`**(:2071-2148):`ducklake_list_files` / flush 用的扩展版,
  额外带 `data_file_id`/`delete_file_id`/`record_count`/`del.begin_snapshot`;同样支持
  filter 下推与 bucket 裁剪。
- **`GetFilesForCompaction`**(:2150-2326):先用窗口函数把 `ducklake_schema_versions`
  变成区间表(`LEAD(begin_snapshot) OVER (ORDER BY begin_snapshot)` 作右边界,:2188-2199),
  据此给每个文件标 `schema_version`(merge 只能合并同 schema version 的相邻文件);再
  LEFT JOIN 全部 delete file 和聚合后的分区值。REWRITE_DELETES 的删除率阈值**在 C++ 侧**
  算(:2306-2323),因为要把内联删除计入分子;内联删除对 rewrite 拉全量 row id,对
  merge 只做存在性探测(`GetFileIdsWithInlinedDeletions`,:2989)。

### 2.5 统计

- `GlobalTableStatsQuery()`(static,:996-1010):全表版
  `ducklake_table_stats LEFT JOIN ducklake_table_column_stats USING (table_id)`。注释
  特意强调模板里**不能出现 printf 占位符**(`%llu`)——server-side commit 会原样执行
  该 SQL。单表版 `GetGlobalTableStats`(:1016-1031)另有自己的 Format 查询。两者共用
  `TransformGlobalStatsRow`(:917-980)做 run-length 解析,每个 stats 字段都带
  `has_xxx` 标志位区分 NULL。
- `UpdateGlobalTableStatsSql`(static,:4539-4586):未初始化走 INSERT;已初始化走
  UPDATE,且**每列一条独立 UPDATE** 而非 `UPDATE ... FROM (VALUES ...)`——注释
  (:4564-4574)记录了两个方言坑:DuckDB 后端在 VALUES 列表混 NULL 与长字符串时会写坏
  字符串载荷;SQLite 解析器不认 `::boolean`,所以统一 ANSI `CAST(x AS BOOLEAN)`。
- 行数核算:`GetNetDataFileRowCount(Sql)`(:521-563)单条 SQL 算
  `SUM(record_count) - SUM(delete_count) - 内联删除数`(delete 只在对应 data file 仍可见
  时计入);`GetNetInlinedRowCount(Sql)`(:565-580)数 inlined 表可见行。
- 其余 static builder(`GetTableColumnSchemaSql` :582、`GetInlinedTableNamesSql` :596、
  `ReadInlinedDataAggregatesSql` :3182、`ReadFileColumnStatsForTableSql` :3192)服务于
  flush 后的 stats 重算,调用方自行替换占位符执行。

### 2.6 写入 SQL 生成器:共同模式

写接口约 20 个,绝大多数是 static、返回多行 `INSERT INTO ... VALUES (...),(...);` 批,
共同模式有四条:

1. **快照列写 `{SNAPSHOT_ID}` 占位符**而非具体值(如 `WriteNewSchemas` :2426 的
   `({id}, '{uuid}', {SNAPSHOT_ID}, NULL, ...)`)——重试时换 snapshot 重放即可。
2. **逻辑删除统一走 `FlushDrop`**(:2340-2351):
   `UPDATE ... SET end_snapshot = {SNAPSHOT_ID} WHERE end_snapshot IS NULL AND <id> IN (...)`;
   `DropSchemas`/`DropTables`/`DropViews`/`DropMacros`/`DropDataFiles`/`DropDeleteFiles`
   (:2353-2377, :3916-3922)都是它的实例化,`DropTables` 会级联 8 张关联表。
3. **路径由调用方解析**:涉及文件路径的 builder(`WriteNewSchemas`/`WriteNewTables`/
   `WriteNewDataFilesSqlBatch`/`WriteNewDeleteFiles`/`WriteMergeAdjacent` 等)签名里都带
   `const vector<DuckLakePath> &resolved_paths`(与对象一一对应),因为相对化依赖
   catalog 的 data_path/separator 实例状态,static 函数拿不到(hpp:249-250 注释)。
4. **diff 型 builder 由调用方提供旧状态**:`WriteNewPartitionKeys(existing, new)`
   (:4267)与 `WriteNewSortKeys`(:4372)先在 C++ 侧对比新旧(nop 检测,:4233-4264 /
   :4356-4370),再生成"老记录置 end_snapshot + 插新记录"两段。

逐个一句话:`WriteNewTables`(:2586)同时产 `ducklake_table` 与递归展开的
`ducklake_column` 插入(`ColumnToSQLRecursive` :2465,嵌套列 parent_column 链);
`WriteNewViews` :2747;`WriteNewMacros` :2677(三张 macro 表);
`WriteDroppedColumns` :2710 / `WriteNewColumns` :2734(ALTER 路径);
`WriteNewTags` :4439 / `WriteNewColumnTags` :4480(`WITH overwritten_tags(...) UPDATE` 先
失效旧 tag 再插入);`WriteNewColumnMappings` :4035;`InsertSnapshotSql` :4063 与
`WriteSnapshotChangesSql` :4074(整条由占位符构成);`InsertNewSchema` :5275(写
`ducklake_schema_versions`);`WriteCompactions` :4890 分派到
`WriteMergeAdjacent` :4802 / `WriteDeleteRewrites` :4846;
`DeleteOverwrittenDeleteFiles` :3924(物理 DELETE 旧 delete file 记录 + 进
`ducklake_files_scheduled_for_deletion`)。

**data file 写入的双路径**:`WriteNewDataFiles`(:3803-3820)在 `SupportsAppender()`
(基类 true,三个外部后端 false)时走 `WriteNewDataFilesWithAppender`(:3572),直接用
DuckDB `Appender` API 对 `ducklake_data_file`/`ducklake_file_column_stats`/
`ducklake_file_partition_value`/`ducklake_file_variant_stats` 四表行级 append(大批量
insert 比 SQL 文本快得多,返回空串);否则走 `WriteNewDataFilesSqlBatch`(:3822-3914)
生成四表的 VALUES 批。`TryAppendDataFiles`(:3792)是 commit 路径上的 opt-in 探测。

**inlined data 写入**(机制归 DATA_INLINING_DESIGN.md,这里只列 SQL 形态):
`WriteNewInlinedTables`(:2638)/`GetInlinedTableQueries`(:2624)产
`ducklake_inlined_data_tables` 注册行 + `InlinedTableDdlSql`(:2554)的
`CREATE TABLE IF NOT EXISTS ducklake_inlined_data_<tid>_<sv>(row_id BIGINT, begin_snapshot
BIGINT, end_snapshot BIGINT, <用户列>)`;列类型经 `GetColumnType`(:2515-2548)走后端
类型映射(非原生支持的嵌套类型整体降级 VARCHAR)。`WriteNewInlinedData`(:2766-2846)
找不到现存 inlined 表时会**就地 `commit_snapshot.schema_version++` 并新建表**(:2826);
行内容由 `DuckLakeUtil::ChunkRowToSQL` 转成 SQL 字面量,经 `FormatInlinedDataInsert`
(:2848)拼 VALUES。`WriteNewInlinedDeletes`(:2874)用
`WITH deleted_row_list(...) UPDATE ... SET end_snapshot = {SNAPSHOT_ID}` 软删;
`WriteNewInlinedFileDeletesSql`(:2907)对 parquet 文件的内联删除产
`CREATE TABLE IF NOT EXISTS ducklake_inlined_delete_<tid>(file_id, row_id, begin_snapshot)`
+ INSERT。新建任何 inlined 表都会 `MarkPendingCacheClear()`(quack 端要刷 server 缓存)。

`GetInlinedDeletionTableName`(:3045-3092)值得一提:表名确定,但**存在性**要探测——
两级缓存(事务级 `delete_inlined_table_cache` + catalog 级跨事务缓存),miss 时靠
`SELECT NULL FROM ... LIMIT 1` 的错误状态判断存在与否(:3080-3091,自带 TODO 承认这很
脆弱);`create_if_not_exists` 时只进事务级缓存(CREATE 可能随事务回滚)。

### 2.7 维护类接口

`GetAllSnapshots`(:4594)/`DeleteSnapshots`(:4902-5188,expire 的级联清理:删
snapshot 行 → 找出不再被任何 snapshot 引用的表/文件 → 物理 DELETE 元数据行并把文件挂入
`ducklake_files_scheduled_for_deletion` → 清孤儿 macro/name_mapping)、
`GetOldFilesForCleanup`(:4624)、`GetOrphanFilesForCleanup`(:4687,把已知文件灌进
临时表 `__ducklake_known_cleanup_files` 后用 `read_blob({DATA_PATH} || '**')` 对 data
目录做反连接)、`DropEmptySupersededInlinedTables`(:5190-5240,flush 后把被新
schema_version 取代且已空的 inlined 表 DROP 掉)、`GetTableSizes`(:5287,双 LATERAL
聚合)、`SetConfigOption`(:5330,按 scope 查重后 INSERT/UPDATE `ducklake_metadata`)。
这些语义归 MAINTENANCE_DESIGN.md,此处不展开。

## 三、filter 下推 SQL 生成

调用方(scan 的 bind/list 阶段,语义见 SCAN_DESIGN.md)把可下推谓词整理成
`FilterPushdownInfo { column_filters: map<field_index, ColumnFilterInfo> }`
(hpp:66-104),每列一个 `ExpressionFilter`。manager 侧把它翻译成
`GetFilesForTable`/`GetExtendedFilesForTable` SQL 的 **CTE 段 + WHERE 追加段**
(`FilterPushdownQueryComponents`,hpp:106-110)。

### 3.1 谓词 → zone map 条件

`GenerateFilterFromExpression`(:1244-1368)递归翻译 bound expression,产出**针对
`ducklake_file_column_stats` 列的统计谓词**(任何不认识的形态返回空串 = 放弃该谓词,
保守不裁剪):

- 比较运算(`GenerateConstantFilter` :1149-1195):`x = C` → `C BETWEEN min_value AND
  max_value`;`x <> C` → `NOT (min = C AND max = C)`;`x >= C` → `max_value >= C`,以此
  类推。`min_value`/`max_value` 是 VARCHAR 存储,数值/时间类型经 `CastStatsToTarget`
  (:1136)包 `TRY_CAST(stats AS <type>)`;常量经 `CastValueToTarget`(:1127)。含
  `'\0'` 的常量直接放弃(:1153,Postgres VARCHAR 不能存 NUL)。BLOB 列不下推(:1262)。
- FLOAT/DOUBLE 走 `GenerateConstantFilterDouble`(:1197-1242):`= NaN` 翻译成
  `contains_nan`;`>`/`>=` 在数值条件外再 `OR contains_nan`(NaN 最大);`<`/`<=`/`<>`
  对 NaN 常量放弃。
- `IS NULL` → `null_count > 0`;`IS NOT NULL` → `value_count > 0`(:1275-1286)。
- `IN (C1..Cn)` 展开为各等值条件的 OR(:1287-1325);AND/OR conjunction 递归拼接,OR
  的任一子项失败则整体放弃(:1330-1348);`optional_filter` /
  `selectivity_optional_filter` 标记函数被透明拆包(:1349-1363)。

翻译过程顺带收集 `referenced_stats`(本谓词引用了哪些 stats 列),驱动 CTE 只投影
所需列。

### 3.2 CTE + 反裁剪保护

`ConvertFilterPushdownToSQL`(:1378-1428)对每个翻译成功的列生成一个 CTE 引用
`col_<field_index>_stats`,WHERE 片段形如:

```sql
(data.data_file_id NOT IN (SELECT data_file_id FROM col_5_stats)
 OR data.data_file_id IN (SELECT data_file_id FROM col_5_stats
      WHERE (value_count IS NULL OR value_count > 0)
        AND (min_value IS NULL OR max_value IS NULL OR (<zone map 条件>))))
```

三层保护语义:① 该文件**没有这列的 stats 行**(列是后来 ALTER 加的)⇒ 不裁剪
(:1408-1409 注释);② 引用了 min/max 时加 `value_count` guard(:1399-1403,全 NULL
文件 min/max 无意义);③ 每个被引用的 stats 列都带 `IS NULL OR` 短路(stats 缺失 ⇒ 不
裁剪)。注意 stats 的接入方式是 **`NOT IN`/`IN` 子查询对 CTE,而不是把
`ducklake_file_column_stats` JOIN 进主查询**——每列一个 CTE,
`GenerateCTESectionFromRequirements`(:1441-1466)拼 `WITH col_5_stats AS MATERIALIZED
(...)`(同一 CTE 被 NOT IN/IN 引用两次,`reference_count=2` ⇒ MATERIALIZED 强制物化,
单次引用则 NOT MATERIALIZED)。CTE 体由虚函数 `GenerateFileColumnStatsCTEBody`
(:1430-1439)生成,基类直查
`ducklake_file_column_stats WHERE column_id = <fid> AND table_id = <tid>`;Postgres 覆盖
为 `postgres_query(...)` server 端执行(第六章)。

### 3.3 bucket 分区裁剪

与 zone map 正交的第二条裁剪路径(:1604-1658):对 `bucket(N)` transform 的分区列,把
等值/IN 常量在 **C++ 侧**过一遍 bucket 变换(`FoldBucketValue` :1495-1515,构造
`ApplyBucketTransform` 表达式 `TryEvaluateScalar` 折叠),得到分区值字符串,生成:

```sql
data.data_file_id IN (SELECT data_file_id FROM {METADATA_CATALOG}.ducklake_file_partition_value
                      WHERE table_id = <tid> AND partition_key_index = <k>
                        AND partition_value IN ('6', '3'))
```

只用字符串等值比较,任何后端都能执行(:478-481 hpp 注释)。`CollectBucketEqualityValues`
(:1521-1602)只接受等值/IN/AND 形态;OR 会漏桶、范围比较无法折叠,均放弃交还 zone map
路径兜底(矛盾 AND 导致的过包含是 correctness-safe 的,残余 filter 仍会执行,:1572-1574)。

## 四、路径解析

元数据库里所有文件路径按 `(path, path_is_relative)` 二元组存储(`DuckLakePath`,
info hpp:516-519),且**统一用 `/` 作分隔符**:

- `StorePath` / `LoadPath`(实例版 :3393-3407,static 版 :3424-3436):写入前把平台
  分隔符(如 Windows `\`)换成 `/`,读出时换回。分隔符来自 catalog 缓存或
  `FileSystem::PathSeparator`(:3383-3391)。
- `GetRelativePath(path, base)`(:3370-3381):新文件落库前,若 `path` 以 base 开头则
  截掉前缀、记 `path_is_relative=true`,否则原样存绝对路径。
- `FromRelativePath(path, base)`(:3409-3414):读出时反向拼接。

**继承链**:文件路径相对 table data path 存,table path 相对 schema path 存,schema
path 相对 catalog `data_path` 存——所以解析任何一级都要先解析上一级:

- `GetPathForSchema`(:3207-3230):优先在本次提交新建的 `new_schemas_result` 里找,
  否则查 `ducklake_schema`,再 `FromRelativePath` 到 catalog data_path。
- `GetPathForTable`(:3249-3310):新表 → 先解析其 schema 路径(查库或 new_schemas);
  存量表 → 一条 `ducklake_schema JOIN ducklake_table` 同时取两级,逐级
  `FromRelativePath`。
- `GetPath(SchemaIndex/TableIndex, ...)`(:3312-3352):带 `paths_lock` 互斥的
  per-manager 缓存(`schema_paths`/`table_paths`),优先从 catalog 内存对象
  (`DuckLakeSchemaEntry::DataPath()`)拿,miss 才查库。
- 三个 `GetRelativePath` 实例重载(:3354-3368)分别相对 catalog/schema/table 相对化,
  写入器据表的 data path 生成相对路径。:3460-3569 是同名 static família,把
  `query_executor`/`base_data_path`/`separator` 显式传参,供 server-side commit 复用。

`BuildCatalogForSnapshot` 在加载时把继承链就地展开:schema.path 解析为绝对(:639),
table.path 再相对 schema.path 解析(:726),所以内存中的 catalog entry 永远持绝对路径。

## 五、迁移框架

触发点在 ATTACH 加载阶段(`DuckLakeInitializer::LoadExistingDuckLake`,
`ducklake_initializer.cpp:194-230`):读出 `ducklake_metadata.version` 后,与
`ResolveTargetVersion`(:269-287,优先级:ATTACH 显式 pin > `automatic_migration` 时取
`DUCKLAKE_LATEST_VERSION` > 沿用 catalog 版本)比较;catalog 比目标新 ⇒ 拒绝降级;
catalog 旧且未开 `AUTOMATIC_MIGRATION` ⇒ 报错;否则**逐级链式迁移**
v0.1→0.2→0.3→0.4→1.0(→1.1-dev1,仅当目标确为 1.1)。每步迁移就是一段多语句 SQL 批,
在元数据库上执行并把 `version` UPDATE 到下一档:

- `MigrateV01`(:251-269):加 schema/table 的 `path`/`path_is_relative`、metadata 的
  `scope`/`scope_id`、data_file 的 `mapping_id`,建 column_mapping/name_mapping 两表,
  并把 `ducklake_partition_column.column_id` 从"列序号"改写为真实 column_id。
- `MigrateV02`(:291-305):name_mapping 加 `is_partition`,snapshot_changes 加
  author/commit_message/commit_extra_info,建 `ducklake_schema_versions` 并从
  `ducklake_snapshot` 回填,`ducklake_file_column_statistics` 改名 `_stats`,加
  `extra_stats`。
- `MigrateV03`(:307-358):建 macro 三表、sort 两表、variant stats 表;column 加
  default_value_type/dialect;schema_versions 加 `table_id`(随后两条独立语句把全局行
  按表展开再删全局行);`partial_file_info` 文本列经 TEMP 表 + regexp 迁移为
  `partial_max BIGINT`。
- `MigrateV04`(:360-367)/`MigrateV10`(:369-376):纯版本号 bump(0.4→1.0、
  1.0→1.1-dev1),无 DDL——这也印证 v1.1-dev1 与 v1.0 schema 完全一致。

**allow_failures 机制**:dev 版本(`0.3-dev1`/`0.4-dev1`)的库可能已部分包含目标 DDL,
对应迁移以 `allow_failures=true` 重入。`ExecuteMigration`(:271-289)用三个占位符实现
幂等开关:`{IF_NOT_EXISTS}`/`{IF_EXISTS}` 在宽容模式替换为对应 SQL 子句、严格模式替换
为空串(重复执行即报错),`{WHERE_EMPTY}` 给回填 INSERT 加"目标表为空才插"的 guard。
注意 `MigrateV01` 不走该框架(v0.1 无 dev 分支)。迁移产生的列级差异细节见
METADATA_SCHEMA_DESIGN.md 第八章。

迁移完成后 `SetVersionedMetadataManager`(:291-308)按 resolved version 决定是否把
manager 换成 V1_1 模板实例(第九章)。

## 六、PostgresMetadataManager

(`src/metadata_manager/postgres_metadata_manager.cpp`,头文件
`src/include/metadata_manager/postgres_metadata_manager.hpp`)

**读写双通道**是它最大的特点:

- **读**:`Query(snapshot, q)` 直接转发基类(cpp:119-121)——SQL 由本地 DuckDB 引擎在
  postgres_scanner ATTACH 的 catalog 上执行,所以基类全部 DuckDB 方言 SQL(LIST、
  STRUCT_PACK、LATERAL、QUALIFY 之类)不需要 Postgres 化。
- **写**:`Execute(snapshot, q)` → `ExecuteQuery(..., "postgres_execute")`(:83-117):
  自行做两组占位符替换(`{METADATA_CATALOG}` 替换成**仅 schema 标识符**,因为 SQL 将在
  Postgres 端执行,没有 DuckDB 的 catalog 限定),然后整批包成
  `CALL postgres_execute('<catalog>', '<sql>')` 发到 Postgres 原生执行——绕开 scanner
  的写路径,multi-statement 批一次往返。
- 两个**读也走 server 端**的例外:`GetLatestSnapshotQuery`(:123-131)和
  `GenerateFileColumnStatsCTEBody`(:133-143)都改用
  `postgres_query({METADATA_CATALOG_NAME_LITERAL}, '... {METADATA_SCHEMA_ESCAPED}.xxx ...')`
  ——前者保证拿到 Postgres 端最新快照,后者把 file_column_stats 的过滤留在 Postgres 侧
  (只回传 `data_file_id` + 所需 stats 列),避免 scanner 全表拉取。

**类型限制**(`TypeIsNativelySupported`,:14-42)——以下类型不能原样建列,逐条注释:
STRUCT/MAP/LIST(无匿名复合类型)、UBIGINT/HUGEINT/UHUGEINT(超出范围)、DATE 与全部
TIMESTAMP 变体(TIMESTAMP/TIMESTAMP_TZ/TIMESTAMP_TZ_NS/TIMESTAMP_SEC/TIMESTAMP_MS/
TIMESTAMP_NS,注释:"Postgres timestamp/date ranges are narrower than DuckDB's",即
infinity/超界年份等无法 round-trip)、BLOB(bytea 输入格式与 DuckDB blob 文本不同)、
VARCHAR(**Postgres TEXT 不能存 NUL 字节**)、VARIANT、GEOMETRY(注释:若已知装了
PostGIS 将来可支持)。不支持的类型在 inlined 表里按 `GetColumnTypeInternal`(:51-81)
映射:

| DuckDB | Postgres 列型 | 说明 |
|---|---|---|
| DOUBLE | `DOUBLE PRECISION` | 名称差异 |
| FLOAT | `REAL` | 同上 |
| TINYINT | `SMALLINT`;UTINYINT/USMALLINT → `INTEGER`;UINTEGER → `BIGINT` | 升宽容纳无符号 |
| BLOB / VARCHAR | `BYTEA` | 字节序列保真(NUL 安全);读回时 `TransformInlinedData`(:146-188)把 BLOB 向量 `Reinterpret` 回 VARCHAR |
| UBIGINT/HUGEINT/UHUGEINT/DATE/TIMESTAMP 全family | `VARCHAR` | 文本 round-trip,读回经 `CastColumnToTarget` 的 ANSI `CAST` 还原(`src/storage/ducklake_inlined_data_reader.cpp:73-81`) |
| 其余 | `column_type.ToString()` | 原样 |

值字面量侧的配套在 `DuckLakeUtil`:非原生 VARCHAR/BLOB 用 bytea hex 字面量
(`src/common/ducklake_util.cpp:291/297`),非原生类型统一按 VARCHAR 文本写
(:130-134)。**内联数据对 VARIANT 的限制**:`SupportsInlining` 覆盖(:44-49)直接对
VARIANT 返回 false(基类只禁 GEOMETRY,:96-101)——含 VARIANT 列的表在 Postgres 后端
整体不可 inlining(`CanInlineColumns` 递归检查,:103-143)。

其他差异:`SupportsAppender() = false`、`MaxIdentifierLength() = 63`(Postgres
NAMEDATALEN-1,超长列名的表不可 inlining)。聚合方言:hpp:403-405 注释提到 Postgres 用
`jsonb_agg(jsonb_build_object(...))`,但当前 HEAD **没有**该覆盖(`ListAggregation` 是
static),实际靠"读在 DuckDB 侧执行"消解,注释属于历史/前瞻描述。

## 七、SQLiteMetadataManager

(`src/metadata_manager/sqlite_metadata_manager.cpp`,共 50 行)最薄的子类:执行通道
完全用基类(读写都经 sqlite_scanner ATTACH 由 DuckDB 执行),只覆盖三个函数:

- `TypeIsNativelySupported`(:12-30)禁:STRUCT/MAP/LIST(无复合类型)、
  **FLOAT/DOUBLE**(注释原话:SQLite 存 double 时把 IEEE 754 NaN 转成 NULL,为让 NaN
  round-trip 必须以 VARCHAR 存)、**TIMESTAMP_TZ 与 TIMESTAMP_TZ_NS**(普通
  TIMESTAMP/DATE **不**禁,与 Postgres 不同)、VARIANT。
- `GetColumnTypeInternal`(:39-48):FLOAT/DOUBLE/VARIANT → `VARCHAR`,其余原样
  (SQLite 类型亲和性宽松,BIGINT/VARCHAR 等直接可用)。
- `SupportsInlining`(:32-37):VARIANT 不可内联(同 Postgres)。

头文件里 `SupportsAppender() = false`;`MaxIdentifierLength` 不覆盖(无限制)。另有
两处基类代码因 SQLite 存在:统计 UPDATE 用 ANSI `CAST` 而非 `::`(:4571-4574 注释),
`CastColumnToTarget` 同理(:1144-1147 注释)。注册表里 `sqlite_scanner` 出现两次
(map :47 + `Create` 的冗余分支 :68-70)。

## 八、QuackMetadataManager

(`src/metadata_manager/quack_metadata_manager.cpp`)面向 **quack 远端 DuckDB server**:
元数据库不在本进程,所有 SQL 都要打包成 RPC。

### 8.1 quack_query_by_name 传输形态

`Query(string&)`(:16-32)是唯一通道(`Query(snapshot,...)`/`Execute` 都归并到它,
:53-60):

```cpp
query = Replace(query, "{METADATA_CATALOG}", schema_identifier);   // 只留 schema,server 端无本地 catalog 名
SubstituteCatalogPlaceholders(query);                               // 其余占位符照常
auto wrapper = StringUtil::Format("CALL system.main.quack_query_by_name(%s, %s)",
                                  metadata_catalog_name_literal, SQLString(query));
auto result = transaction.ExecuteRaw(std::move(wrapper));
```

即:整条(可能是多语句的)SQL 作为字符串参数,经本地的 quack 扩展表函数发给名为
`<metadata_catalog_name>` 的远端库执行。失败时立即
`ROLLBACK; BEGIN TRANSACTION;`(:27-30)复位远端会话事务,避免半失败状态卡死后续重试。

`AttachMetadata`(:34-51)用 fresh `Connection`(不进事务连接)执行 ATTACH,并对
`Invalid connection id` / `Couldn't connect to server` / `Failed to send message` 三类
瞬时网络错误最多重试 5 次。`MetadataExistsQuery`(:62-65)改查
`information_schema.tables`(server 端 catalog error 不会以 `ExceptionType::CATALOG`
形态穿回 RPC,基类的错误类型判断不可用);`MetadataExists`(:139-150)按 COUNT 判断。
`ClearCache()`(:67-70)发 `CALL quack_clear_cache()`——server 对远端库 schema 有缓存,
凡动态建了 `ducklake_inlined_data_*`/`ducklake_inlined_delete_*` 表都要刷
(`MarkPendingCacheClear` → commit 时 `TakePendingCacheClear` → `ClearCache`,
`ducklake_transaction.cpp:1363-1367`)。

### 8.2 能力探测与 server-side commit 衔接

`ProbeServerCapabilities`(:72-84)在 ATTACH 完成后由 initializer 调一次
(`ducklake_initializer.cpp:115-118`):

```sql
SELECT 1 FROM duckdb_functions() WHERE function_name = 'ducklake_commit' LIMIT 1
```

查到即 `SetRetrialsServerSide(true)`——server 装了 ducklake 扩展,提交重试循环可以搬到
server 端跑。基类该函数为空(hpp:133-134),Postgres/SQLite 永远 client-side。

`CanSkipSnapshotFetch(changes)`(:94-100)决定客户端能否不取最新 snapshot、直接把
commit 批交给 server:条件是 `ExecuteRetrialsServerSide() && IsDataOnlyCommit(changes)`
且 `!transaction.GetRequiresNewInlinedTable()`。`IsDataOnlyCommit`(:86-92)要求无任何
DDL(created/dropped/altered schemas、tables、views、macros 全空)——纯数据提交的 SQL
模板与 snapshot 解耦(占位符可由 server 替换),而 DDL 需要客户端先分配 catalog id;
新建 inlined 表同理(server-side commit 无法替客户端建表并刷新本地缓存)。

`FlushChangesServerSide`(:102-137):不满足条件回落
`flush_transaction.RunCommitLoop(...)`(客户端循环);满足则用 `DuckLakeStagedCommit`
构建一条含 `ducklake_commit(...)` 的批,经 `Query` RPC 发出,从结果行解析
`(committed_snapshot_id, committed_schema_version, had_flushes)` 回填本地状态,必要时
做客户端侧 `DropEmptySupersededInlinedTablesClientSide` 与 `ClearCache`。staged commit
的批内容、重试协议归 [COMMIT_PROTOCOL_DESIGN.md](COMMIT_PROTOCOL_DESIGN.md)。

quack 的 `SupportsAppender() = false`(Appender 不能跨 RPC);类型映射不覆盖
(server 是 DuckDB,全类型原生)。

## 九、DuckLakeMetadataManagerV1_1 模板子类

(`src/metadata_manager/ducklake_metadata_manager_v1_1.cpp`,25 行;头文件
`src/include/metadata_manager/ducklake_metadata_manager_v1_1.hpp`)

```cpp
template <typename Base>
class DuckLakeMetadataManagerV1_1 : public Base {
    string GetCreateTableStatements() override;   // = Base::GetCreateTableStatements(),无任何 DDL 差异
    string GetVersionString() override;           // = "1.1-dev1"
};
```

**覆盖的虚函数清单就这两个**;显式实例化三种(cpp:21-23):

- `DuckLakeMetadataManagerV1_1<DuckLakeMetadataManager>`(DuckDB 后端)
- `DuckLakeMetadataManagerV1_1<SQLiteMetadataManager>`
- `DuckLakeMetadataManagerV1_1<PostgresMetadataManager>`

替换时机在 `DuckLakeInitializer::SetVersionedMetadataManager`
(`ducklake_initializer.cpp:289-308`):resolved version 为 V1_0 时 nop(基类即 1.0),
为 V1_1_DEV_1 时按 `dynamic_cast` 判别当前 manager 类型构造对应模板实例并
`transaction.SetMetadataManager(...)` 换掉。新建 DuckLake 走 `ducklake_default_version`
设置或 ATTACH 参数决定初始用哪一档(`Initialize` :85-96)。

两个值得注意的边角:① **没有 `DuckLakeMetadataManagerV1_1<QuackMetadataManager>`**——
quack 后端的 catalog 若 version 是 1.1-dev1,`SetVersionedMetadataManager` 的
dynamic_cast 两个分支都不命中,会落到 else 构造
`DuckLakeMetadataManagerV1_1<DuckLakeMetadataManager>`,即 **quack 的 RPC 覆盖会丢失**
(疑似遗漏,quack 部署目前以 1.0 catalog 为前提);② 模板的
`GetCreateTableStatements` 原样转发,说明 1.1-dev1 是为后续 schema 演进预留的版本闸门,
当前仅版本字符串不同。

## 十、错误处理与后端能力差异总结

**错误处理通例**:所有读路径在 `result->HasError()` 时
`GetErrorObject().Throw("Failed to ... from DuckLake: ")` 加前缀重抛;仅两处把错误当
信号用——`MetadataExists` 的 `ExceptionType::CATALOG` ⇒ 新库(:176-179),
`GetInlinedDeletionTableName` 的探测查询失败 ⇒ 表不存在(:3080-3091,自带 TODO)。
quack 额外在 RPC 失败后复位远端事务(第八章)。写路径的冲突检测/重试不在 manager 层,
归 COMMIT_PROTOCOL_DESIGN.md。

能力矩阵(行为差异均已在前文给出出处):

| 能力 | DuckDB(基类) | Postgres | SQLite | quack |
|---|---|---|---|---|
| 执行通道 | 本地 Connection | 读=scanner 本地执行;写=`CALL postgres_execute` | 读写=scanner 本地执行 | 全部 `CALL quack_query_by_name` RPC |
| `SupportsAppender`(data file 快速写入) | ✓ | ✗ | ✗ | ✗ |
| server-side commit(`ProbeServerCapabilities`/`FlushChangesServerSide`) | ✗ | ✗ | ✗ | ✓(探测到 `ducklake_commit` 时) |
| `CanSkipSnapshotFetch` | 恒 false | 恒 false | 恒 false | data-only commit 且无新 inlined 表时 true |
| 类型原生支持 | 全部 | 禁 STRUCT/MAP/LIST、U/HUGEINT、DATE+全 TIMESTAMP、BLOB、VARCHAR、VARIANT、GEOMETRY | 禁 STRUCT/MAP/LIST、FLOAT/DOUBLE、TIMESTAMP_TZ(_NS)、VARIANT | 全部 |
| 数据内联(`SupportsInlining`) | 除 GEOMETRY | 再禁 VARIANT | 再禁 VARIANT | 同基类 |
| `MaxIdentifierLength` | ∞ | 63 | ∞ | ∞ |
| `ClearCache` | nop | nop | nop | `CALL quack_clear_cache()` |
| 最新 snapshot 查询 | 本地 SQL | `postgres_query()` server 端 | 本地 SQL | RPC(同通道) |
| filter 下推 CTE 体 | 直查 stats 表 | `postgres_query()` server 端过滤 | 直查 | 直查(server 端执行) |
| V1_1 模板实例 | ✓ | ✓ | ✓ | ✗(见第九章) |

一句话总结:**SQL 模板尽量写一份**(ANSI CAST、字符串化 stats、`/` 路径、占位符),
后端差异收敛在"谁来执行这条 SQL"(通道)与"什么类型能落到内联表"(方言)两个很窄的
虚函数面上;真正分叉大的只有 quack——它把"元数据库在远端"推到极致,顺带打开了
server-side commit 的大门。
