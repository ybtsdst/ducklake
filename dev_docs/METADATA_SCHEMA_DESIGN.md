# METADATA_SCHEMA_DESIGN.md — 元数据库数据字典

> 行号基准:commit `47187559`。所有 `file:line` 相对 repo 根。

## 概述

DuckLake 的"catalog"就是一个普通 SQL 数据库:所有表/列定义、snapshot、数据文件清单、
统计、分区信息全部以行的形式存在一组 `ducklake_` 前缀的表里。元数据库可以由任何支持
事务的 SQL 数据库承载(DuckDB / SQLite / Postgres 三个后端,见
[METADATA_MANAGER_DESIGN.md](METADATA_MANAGER_DESIGN.md));所有 SQL 都以
`{METADATA_CATALOG}` 占位符书写,执行前由
`SubstituteCatalogPlaceholders()`(`src/storage/ducklake_metadata_manager.cpp:2379`)替换为
`<catalog>.<schema>` 限定名,`{SNAPSHOT_ID}`/`{SCHEMA_VERSION}` 等快照占位符由
`SubstituteSnapshotPlaceholders()`(`src/storage/ducklake_metadata_manager.cpp:2398`)替换。

建表 DDL 集中在 `GetCreateTableStatements()`
(`src/storage/ducklake_metadata_manager.cpp:213-244`),共 **28 张固定表**(注意不是文档常说
的 ~25 张)。另有两类**动态建表**:per-table 的 inlined data 表
`ducklake_inlined_data_<table_id>_<schema_version>` 和 inlined delete 表
`ducklake_inlined_delete_<table_id>`(见第六章)。

```
                          ┌────────────────────────────────────────────────┐
 快照/版本化              │ ducklake_snapshot   ducklake_snapshot_changes  │
                          │ ducklake_schema_versions                       │
                          └────────────────────────────────────────────────┘
                          ┌────────────────────────────────────────────────┐
 catalog 对象             │ ducklake_schema  ducklake_table  ducklake_view │
 (begin/end versioned)    │ ducklake_column  ducklake_tag  ducklake_column_tag
                          │ ducklake_macro  ducklake_macro_impl            │
                          │ ducklake_macro_parameters                      │
                          └────────────────────────────────────────────────┘
                          ┌────────────────────────────────────────────────┐
 数据文件                 │ ducklake_data_file      ducklake_delete_file   │
                          │ ducklake_files_scheduled_for_deletion          │
                          └────────────────────────────────────────────────┘
                          ┌────────────────────────────────────────────────┐
 统计                     │ ducklake_table_stats  ducklake_table_column_stats
 (非 versioned,当前态)   │ ducklake_file_column_stats                     │
                          │ ducklake_file_variant_stats                    │
                          └────────────────────────────────────────────────┘
                          ┌────────────────────────────────────────────────┐
 分区/排序                │ ducklake_partition_info  ducklake_partition_column
                          │ ducklake_file_partition_value                  │
                          │ ducklake_sort_info  ducklake_sort_expression   │
                          └────────────────────────────────────────────────┘
                          ┌────────────────────────────────────────────────┐
 配置/映射                │ ducklake_metadata                              │
                          │ ducklake_column_mapping  ducklake_name_mapping │
                          └────────────────────────────────────────────────┘
                          ┌────────────────────────────────────────────────┐
 inlined data(动态)      │ ducklake_inlined_data_tables(注册表)           │
                          │ ducklake_inlined_data_<tid>_<sv>(动态)        │
                          │ ducklake_inlined_delete_<tid>(动态)           │
                          └────────────────────────────────────────────────┘
```

关键源码位置:

| 内容 | 位置 |
|---|---|
| 全部建表 DDL | `src/storage/ducklake_metadata_manager.cpp:213-244` |
| 初始数据(snapshot 0 / main schema / version 等) | `src/storage/ducklake_metadata_manager.cpp:185-211` |
| 各 C++ info 结构(行的内存表示) | `src/include/storage/ducklake_metadata_info.hpp` |
| 可见性谓词的典型实例 | `src/storage/ducklake_metadata_manager.cpp:619`、`:1753` |
| changes_made 词表解析 | `src/storage/ducklake_transaction_changes.cpp:36-88` |
| 版本枚举 | `src/include/common/ducklake_version.hpp:15-27` |
| 迁移函数 MigrateV01..V10 | `src/storage/ducklake_metadata_manager.cpp:251-377` |
| 迁移触发链 | `src/storage/ducklake_initializer.cpp:172-267` |
| inlined data 动态表命名/DDL | `src/storage/ducklake_metadata_manager.cpp:2550-2571`、`:2903-2905` |

## 关联文档

- [ATTACH_CATALOG_DESIGN.md](ATTACH_CATALOG_DESIGN.md) — ATTACH 时如何加载本篇各表构建 catalog 缓存;`ducklake_metadata` 配置项的作用域消费方。
- [TRANSACTION_DESIGN.md](TRANSACTION_DESIGN.md) — `DuckLakeSnapshot` C++ 结构与快照获取;本篇只写 `ducklake_snapshot` 表本身。
- [COMMIT_PROTOCOL_DESIGN.md](COMMIT_PROTOCOL_DESIGN.md) — `ducklake_snapshot_changes.changes_made` 是冲突检测的输入。
- [METADATA_MANAGER_DESIGN.md](METADATA_MANAGER_DESIGN.md) — 操作这些表的 manager 代码、SQL 生成、三后端差异、迁移代码;本篇只写各版本 schema 差异"是什么"。
- [SCAN_DESIGN.md](SCAN_DESIGN.md) — 读路径如何消费 `ducklake_data_file`/`ducklake_delete_file`/file stats。
- [DML_DESIGN.md](DML_DESIGN.md) — `DuckLakeColumnStats` C++ 结构与统计收集;本篇只写统计表的列。
- [DATA_INLINING_DESIGN.md](DATA_INLINING_DESIGN.md) — inlined data 表的读写路径与 flush。
- [MAINTENANCE_DESIGN.md](MAINTENANCE_DESIGN.md) — expire_snapshots/cleanup/compaction 对本篇各表的删改。
- [TABLE_FUNCTIONS_DESIGN.md](TABLE_FUNCTIONS_DESIGN.md) — `snapshots()`/`table_changes()` 等直接暴露本篇表内容。

## 一、快照与版本化语义

### 1.1 ducklake_snapshot

```sql
CREATE TABLE ducklake_snapshot(snapshot_id BIGINT PRIMARY KEY, snapshot_time TIMESTAMPTZ,
    schema_version BIGINT, next_catalog_id BIGINT, next_file_id BIGINT);
```
(`src/storage/ducklake_metadata_manager.cpp:216`)

| 列 | 含义 |
|---|---|
| `snapshot_id` | 单调递增的快照号,全局版本计数器。新 DuckLake 初始写入 snapshot 0(`:200`)。 |
| `snapshot_time` | 提交时刻,值为**元数据库端**的 `NOW()`(插入模板 `:4064`),不是客户端时钟。`AT (TIMESTAMP => ...)` 时间旅行按它二分(`:4207-4218`)。 |
| `schema_version` | 该快照对应的 schema 版本号;任何 DDL(含 inlined data 表 schema 翻新)使其 +1。catalog 缓存按 `schema_version` 失效(见 [ATTACH_CATALOG_DESIGN.md](ATTACH_CATALOG_DESIGN.md))。 |
| `next_catalog_id` | 下一个可分配的 catalog 对象 id。schema/table/view/macro/partition_id 共用这一个 id 空间(如 partition_id 直接取 `next_catalog_id++`,`src/storage/ducklake_transaction.cpp:1022`)。 |
| `next_file_id` | 下一个可分配的 `data_file_id`/`delete_file_id`(两者共用)。 |

插入由提交路径以占位符模板完成:`InsertSnapshotSql()`
(`src/storage/ducklake_metadata_manager.cpp:4063-4065`)。"当前快照" = `MAX(snapshot_id)`
(`LatestSnapshotQuery()`,`:4175-4177`)。`AT (VERSION => N)` 直接按 `snapshot_id = N` 查
(`:4202-4206`)。`DuckLakeSnapshot` 的 C++ 侧语义见
[TRANSACTION_DESIGN.md](TRANSACTION_DESIGN.md)。

### 1.2 ducklake_snapshot_changes

```sql
CREATE TABLE ducklake_snapshot_changes(snapshot_id BIGINT PRIMARY KEY, changes_made VARCHAR,
    author VARCHAR, commit_message VARCHAR, commit_extra_info VARCHAR);
```
(`src/storage/ducklake_metadata_manager.cpp:217`)

| 列 | 含义 |
|---|---|
| `snapshot_id` | 与 `ducklake_snapshot` 一一对应(LEFT JOIN USING (snapshot_id),`:4598`)。 |
| `changes_made` | 该快照所做变更的紧凑文本编码:逗号分隔的 `type:value` 列表,value 内可用双引号包裹含逗号的名字。解析器在 `src/storage/ducklake_transaction_changes.cpp:36-131`。 |
| `author` / `commit_message` / `commit_extra_info` | v0.3 新增的提交注记(`:294-296`),由 `ducklake.set_commit_message()` 等设置,可为 NULL。写入 `:4074-4080`。 |

`changes_made` 的完整词表(`src/storage/ducklake_transaction_changes.cpp:44-84`):
`created_schema` / `created_table` / `created_view` / `created_scalar_macro` /
`created_table_macro` / `dropped_schema` / `dropped_table` / `dropped_view` /
`dropped_scalar_macro` / `dropped_table_macro` / `altered_table` / `altered_view` /
`inserted_into_table` / `deleted_from_table` / `compacted_table` / `merge_adjacent` /
`rewrite_delete` / `inlined_insert` / `inlined_delete` / `flushed_inlined`(兼容旧拼写
`inline_flush`)。提交重试时用 `STRING_AGG(changes_made)` 拉取"晚于本事务快照的所有变更"
做冲突检测(`src/storage/ducklake_metadata_manager.cpp:4089-4093`,协议见
[COMMIT_PROTOCOL_DESIGN.md](COMMIT_PROTOCOL_DESIGN.md))。

### 1.3 可见性约定:[begin_snapshot, end_snapshot) 半开区间

所有 versioned 表(schema/table/view/column/tag/column_tag/macro/partition_info/sort_info/
data_file/delete_file/inlined data 行)采用同一对列:

- 创建:`INSERT ... (begin_snapshot = {SNAPSHOT_ID}, end_snapshot = NULL)`;
- 逻辑删除/替换:`UPDATE ... SET end_snapshot = {SNAPSHOT_ID} WHERE end_snapshot IS NULL`
  (通用模板 `FlushDrop()`,`src/storage/ducklake_metadata_manager.cpp:2341-2351`)。

**注意:实现中的区间是左闭右开 `[begin_snapshot, end_snapshot)`,不是 `(begin, end]`。**
代码里所有可见性判断使用同一个谓词形态,以 schema 加载为例
(`src/storage/ducklake_metadata_manager.cpp:619`):

```sql
WHERE {SNAPSHOT_ID} >= begin_snapshot AND ({SNAPSHOT_ID} < end_snapshot OR end_snapshot IS NULL)
```

推论(全系列其它篇引用本节时以此为准):

1. **创建即可见**:snapshot S 提交的行 `begin_snapshot = S`,在 S 本身的读取中可见
   (`>=`)。
2. **删除即不可见**:snapshot S 把行标记 `end_snapshot = S`,在 S 的读取中已不可见
   (`<`)。即 `end_snapshot` 是"第一个看不到该行的快照"。
3. **当前态查询** = 把 `{SNAPSHOT_ID}` 替换为最新 snapshot_id;**历史态(time travel)**
   = 替换为旧 snapshot_id,谓词不变(替换机制 `:2398-2407`)。
4. **存活判定与 GC 一致**:expire_snapshots 判断"行版本是否还被任何 snapshot 引用"用
   `EXISTS(SELECT snapshot_id FROM ducklake_snapshot WHERE snapshot_id >= begin_snapshot AND
   snapshot_id < end_snapshot)`(`:4937-4941`、`:5143-5147`),区间口径与可见性谓词严格一致;
   不被引用的行版本才会被物理 DELETE(见 [MAINTENANCE_DESIGN.md](MAINTENANCE_DESIGN.md))。

增量读取(`table_changes()`)使用区间端点的变体:

- 区间内新增的文件:`begin_snapshot >= start AND begin_snapshot <= {SNAPSHOT_ID}`
  (`:1840-1843`,另以 `partial_max >= start` 捞出跨快照 partial file);
- 区间内整文件删除:`end_snapshot >= start AND end_snapshot <= {SNAPSHOT_ID}`(`:1954`)。

同快照内部的"先插后删"由提交 SQL 侧规避:inlined 行删除时附带
`AND begin_snapshot != {SNAPSHOT_ID}` 防止把本快照新插入的行又关掉(`:2896`)。

### 1.4 ducklake_schema_versions

```sql
CREATE TABLE ducklake_schema_versions(begin_snapshot BIGINT, schema_version BIGINT, table_id BIGINT);
```
(`src/storage/ducklake_metadata_manager.cpp:237`)

per-table 的 schema 版本起点表:每当某 table 的 schema 发生变化,提交时为该 table 插入一行
`(snapshot_id, schema_version, table_id)`(`InsertNewSchema()`,`:5275-5285`)。消费方:

- `GetBeginSnapshotForSchemaVersion()`(`:506-519`):找某 table 某 schema_version 的生效快照,
  无记录时回退 `ducklake_table.begin_snapshot`(`:493-504`)——老表可能从未 ALTER 过;
- compaction 用窗口函数 `LEAD(begin_snapshot)` 把各版本区间补出 end(`:2188-2199`),保证只合并
  同 schema_version 的相邻文件。

历史包袱:v0.3 引入时**没有** `table_id` 列(全局粒度,`:298`),v0.4 迁移补列并按
`ducklake_table` 的区间回填成 per-table 行、删除全局行(`:318`、`:335-357`)。

## 二、catalog 对象表

### 2.1 ducklake_schema

```sql
CREATE TABLE ducklake_schema(schema_id BIGINT PRIMARY KEY, schema_uuid UUID, begin_snapshot BIGINT,
    end_snapshot BIGINT, schema_name VARCHAR, path VARCHAR, path_is_relative BOOLEAN);
```
(`src/storage/ducklake_metadata_manager.cpp:218`)

`schema_id` 出自 `next_catalog_id` 空间;`schema_uuid` 由事务生成(`:198`)。`path` +
`path_is_relative` 是 v0.2 新增的存储路径字段:relative 时相对全局 `data_path` 拼接,NULL 时
直接回退 `data_path`(读取 `:630-640`)。初始 `main` schema 写 `('main', 'main/', true)`
(`:203`)。新建写入 `WriteNewSchemas()`(`:2426-2447`),DROP 走 `FlushDrop`(`:2353-2355`)。
`schema_id` 有 PRIMARY KEY,意味着 schema 不支持产生同 id 多行版本(没有 rename schema)。

### 2.2 ducklake_table

```sql
CREATE TABLE ducklake_table(table_id BIGINT, table_uuid UUID, begin_snapshot BIGINT,
    end_snapshot BIGINT, schema_id BIGINT, table_name VARCHAR, path VARCHAR, path_is_relative BOOLEAN);
```
(`src/storage/ducklake_metadata_manager.cpp:219`)

与 schema 的关键差别:`table_id` **没有** PRIMARY KEY——RENAME 会为同一 `table_id` 写一行新
版本(旧行 `end_snapshot` 关闭、新行携带新 `table_name`),`DropTables(ids, renamed=true)` 只
关 `ducklake_table` 行而保留 column/data_file 等(`:2357-2369`);真正 DROP(renamed=false)
则把 `ducklake_partition_info`/`ducklake_column`/`ducklake_column_tag`/`ducklake_data_file`/
`ducklake_delete_file`/`ducklake_tag`/`ducklake_sort_info` 一起 `FlushDrop`。`path` 相对
schema path 解析(`:717-727`)。写入 `WriteNewTables()`(`:2586-2622`)。

### 2.3 ducklake_view

```sql
CREATE TABLE ducklake_view(view_id BIGINT, view_uuid UUID, begin_snapshot BIGINT, end_snapshot BIGINT,
    schema_id BIGINT, view_name VARCHAR, dialect VARCHAR, sql VARCHAR, column_aliases VARCHAR);
```
(`src/storage/ducklake_metadata_manager.cpp:220`)

`view_id` 与 `table_id` 共用 id 空间(`DuckLakeViewInfo.id` 类型就是 `TableIndex`,
`src/include/storage/ducklake_metadata_info.hpp:315-324`)。`dialect` 当前写 `'duckdb'`;
`sql` 存视图定义文本;`column_aliases` 是带引号的逗号分隔列表,写入用
`DuckLakeUtil::ToQuotedList`(`:2757`)、读取用 `ParseQuotedList`(`:795`)。

### 2.4 ducklake_column

```sql
CREATE TABLE ducklake_column(column_id BIGINT, begin_snapshot BIGINT, end_snapshot BIGINT,
    table_id BIGINT, column_order BIGINT, column_name VARCHAR, column_type VARCHAR,
    initial_default VARCHAR, default_value VARCHAR, nulls_allowed BOOLEAN, parent_column BIGINT,
    default_value_type VARCHAR, default_value_dialect VARCHAR);
```
(`src/storage/ducklake_metadata_manager.cpp:227`)

| 列 | 含义 |
|---|---|
| `column_id` | 即 field id(`FieldIndex`),表内唯一且跨 schema 演进永不复用:`GetNextColumnId()` 取 `MAX(column_id)+1` 且不带快照过滤(`:4783-4800`),被 drop 的列 id 也占号。Parquet 文件的 `field_id` 与之对应。 |
| `column_order` | 展示顺序;当前实现恒等于 `column_id`(`:2500`,注释 `:582-585`),读取按它 ORDER BY。 |
| `column_name` / `column_type` | 类型存 `LogicalType::ToString()` 文本(`:2511-2513`)。 |
| `initial_default` | 列加入时的"补洞"默认值:扫描早于该列的旧 parquet 文件时用它填充(ADD COLUMN 不重写数据)。 |
| `default_value` | `DEFAULT` 子句;无 default 时写**字符串字面量 `'NULL'`**(`:2475`),读回时 `value == "NULL"` 还原为无 default(`:744-748`)。 |
| `default_value_type` | `'literal'` 或 `'expression'`(由表达式类型推断,`GetExpressionType()`,`:2449-2463`);expression 时存表达式 SQL 文本(`:2483-2492`)。v0.4 新增,迁移时旧行回填 `'literal'`(`:312-313`)。 |
| `default_value_dialect` | 当前写死 `'duckdb'`(`:2476`);v0.4 新增。 |
| `nulls_allowed` | NOT NULL 约束取反。 |
| `parent_column` | **嵌套类型的表达方式**:STRUCT/LIST/MAP 的每个子字段单独成行,`parent_column` 指向父行的 `column_id`,根列为 NULL。写入递归展开(`ColumnToSQLRecursive`,`:2465-2509`);读取按 `ORDER BY parent_column NULLS FIRST, column_order` 先根后叶(`:681`),用 `AddChildColumn()` 重建树(`:427-438`)。LIST 子列固定 1 个,MAP 固定 key/value 2 个。 |

DROP COLUMN 按 `(table_id, column_id)` 成对关闭行版本(`WriteDroppedColumns`,
`:2710-2732`);ALTER 加列走 `WriteNewColumns`(`:2734-2745`)。

### 2.5 ducklake_tag / ducklake_column_tag

```sql
CREATE TABLE ducklake_tag(object_id BIGINT, begin_snapshot BIGINT, end_snapshot BIGINT,
    key VARCHAR, value VARCHAR);
CREATE TABLE ducklake_column_tag(table_id BIGINT, column_id BIGINT, begin_snapshot BIGINT,
    end_snapshot BIGINT, key VARCHAR, value VARCHAR);
```
(`src/storage/ducklake_metadata_manager.cpp:221-222`)

任意 catalog 对象级 key/value(COMMENT 等即存于此)。`object_id` 用统一 catalog id 空间,可指
table 或 view(读取时分别按 `object_id=table_id`/`object_id=view_id` 关联,`:661`、`:776`)。
更新模式是"同 (object_id, key) 旧行关 end_snapshot + 插新行"(`WriteNewTags`,
`:4439-4478`;column 维度同构,`:4480-4519`)。

### 2.6 macro 三张表

```sql
CREATE TABLE ducklake_macro(schema_id BIGINT, macro_id BIGINT, macro_name VARCHAR,
    begin_snapshot BIGINT, end_snapshot BIGINT);
CREATE TABLE ducklake_macro_impl(macro_id BIGINT, impl_id BIGINT, dialect VARCHAR, sql VARCHAR, type VARCHAR);
CREATE TABLE ducklake_macro_parameters(macro_id BIGINT, impl_id BIGINT, column_id BIGINT,
    parameter_name VARCHAR, parameter_type VARCHAR, default_value VARCHAR, default_value_type VARCHAR);
```
(`src/storage/ducklake_metadata_manager.cpp:238-240`,v0.4 新增)

只有 `ducklake_macro` 带 begin/end;impl/parameters 不 versioned,生命周期跟随 macro 行:
expire 时用 `NOT EXISTS(... ducklake_macro m WHERE m.macro_id = tbl.macro_id)` 级联清理
(`:5155-5167`)。`impl_id` 是同一 macro 的 overload 序号(写入即 0..n-1 循环下标,
`:2686`);`type` 区分 scalar/table macro;`parameters.column_id` 是参数位置序号
(写入即 `param_id` 循环下标,`:2699-2703`,与 `ducklake_column` 无关);
`default_value_type` 同 2.4。读取走嵌套 LIST 聚合(`:807-842`)。

## 三、数据文件表

### 3.1 ducklake_data_file

```sql
CREATE TABLE ducklake_data_file(data_file_id BIGINT PRIMARY KEY, table_id BIGINT,
    begin_snapshot BIGINT, end_snapshot BIGINT, file_order BIGINT, path VARCHAR,
    path_is_relative BOOLEAN, file_format VARCHAR, record_count BIGINT, file_size_bytes BIGINT,
    footer_size BIGINT, row_id_start BIGINT, partition_id BIGINT, encryption_key VARCHAR,
    mapping_id BIGINT, partial_max BIGINT);
```
(`src/storage/ducklake_metadata_manager.cpp:223`)

写入 SQL 在 `WriteNewDataFilesSqlBatch()`(`:3822-3914`),逐列:

| 列 | 含义 |
|---|---|
| `data_file_id` | 出自 `next_file_id` 空间,PRIMARY KEY(数据文件行版本不会同 id 复制;compaction/expire 直接 DELETE 行)。 |
| `table_id` | 所属表。 |
| `begin_snapshot` | 文件加入快照;通常 `{SNAPSHOT_ID}`,inlined data flush 等场景显式指定历史快照(`:3841-3842`)。 |
| `end_snapshot` | 文件被删除的快照(TRUNCATE/DELETE 全文件命中/compaction rewrite,`:4870-4885`);插入恒 NULL。整文件删除**不写 delete file**,只置此列(注释 `:1896-1900`)。 |
| `file_order` | **当前恒写 NULL**(SQL 路径 `:3850` 第 5 个值,appender 路径 `:3607`);仅 staged commit 的暂存表里有同名实义列(`src/storage/ducklake_staged_commit.cpp:72`)。推断:为多文件提交保序预留。 |
| `path` / `path_is_relative` | relative 时相对 table path(table 再相对 schema、schema 相对 data_path,三级拼接见 `:4649-4672`)。 |
| `file_format` | 恒 `'parquet'`(`:3850`)。 |
| `record_count` | 文件总行数(含已被 delete file 删掉的行);净行数 = `SUM(record_count) - SUM(delete_count) - inlined deletions`(`GetNetDataFileRowCountSql`,`:521-554`)。 |
| `file_size_bytes` | 文件字节数。 |
| `footer_size` | parquet footer 大小,读路径可凭它免一次 footer 探测 IO(进 `DuckLakeFileData.footer_size`,`:1072-1074`)。 |
| `row_id_start` | 该文件首行的逻辑 row id,文件内行号连续递增;row id 由 `ducklake_table_stats.next_row_id` 分配(见 [DML_DESIGN.md](DML_DESIGN.md))。 |
| `partition_id` | 写文件时生效的分区定义,指向 `ducklake_partition_info`;具体分区值在 `ducklake_file_partition_value`。非分区文件为 NULL,两者一致性有断言(`:3875-3877`)。 |
| `encryption_key` | per-file 加密密钥,**Base64 文本**(写 `src/common/ducklake_util.cpp:423-428`,读 `Blob::FromBase64`,`:1081`);未加密为 NULL。 |
| `mapping_id` | 指向 `ducklake_column_mapping`:`ducklake_add_data_files` 注册的、无 field_id 的外部 parquet 需按 name map 解析列(v0.2 新增)。 |
| `partial_max` | 文件含**多个快照的行**时(典型:inlined data flush 一次落盘多个快照的数据),记录文件内最大 snapshot id。time travel 读到 `partial_max > 查询快照` 的文件时设 `snapshot_filter_max` 做行级过滤(`SetSnapshotFilter`,`:1097-1104`、`:1782-1785`);增量读用它把"可能含区间内行"的老文件捞回来(`:1840-1843`)再设 `snapshot_filter_min`(`:1862-1871`)。v0.4 从旧 `partial_file_info` 文本列迁移而来(`:319-330`)。 |

### 3.2 ducklake_delete_file

```sql
CREATE TABLE ducklake_delete_file(delete_file_id BIGINT PRIMARY KEY, table_id BIGINT,
    begin_snapshot BIGINT, end_snapshot BIGINT, data_file_id BIGINT, path VARCHAR,
    path_is_relative BOOLEAN, format VARCHAR, delete_count BIGINT, file_size_bytes BIGINT,
    footer_size BIGINT, encryption_key VARCHAR, partial_max BIGINT);
```
(`src/storage/ducklake_metadata_manager.cpp:226`)

deletion vector 文件(positional delete)的清单,写入 `WriteNewDeleteFiles()`
(`:3963-3996`)。与 data file 不同名的列:

- `data_file_id`:被删行所在的数据文件。**同一 data file 在任一快照下只有一个可见的 delete
  file**:新 delete file 是全量覆盖(含旧 delete 的并集),提交时把被覆盖的旧 delete file 直接
  从元数据 DELETE 并 schedule 删盘(`DeleteOverwrittenDeleteFiles`,`:3924-3961`)——注意这是
  物理 DELETE 而非 end_snapshot 关闭,time travel 读旧快照时按 `begin_snapshot` 选当时最新的
  delete 状态(`DISTINCT ON ... ORDER BY begin_snapshot DESC`,`:1928-1940`)。
- `format`:`DeleteFileFormat`,默认 `'parquet'`(`src/include/storage/ducklake_metadata_info.hpp:197`)。
- `delete_count`:该 delete file 删除的行数,用于净行数与 rewrite_deletes 的 delete ratio
  (`:2306-2323`)。
- `partial_max`:同 data file,flush 场景的多快照 delete(`:3985`)。

行级删除有第三种形态——直接内联进元数据库的 `ducklake_inlined_delete_<tid>` 表,见 6.3。

### 3.3 ducklake_files_scheduled_for_deletion

```sql
CREATE TABLE ducklake_files_scheduled_for_deletion(data_file_id BIGINT, path VARCHAR,
    path_is_relative BOOLEAN, schedule_start TIMESTAMPTZ);
```
(`src/storage/ducklake_metadata_manager.cpp:233`)

"待删盘"队列:元数据里已经没有任何引用、但物理文件还在对象存储上的文件。生产者:

- compaction merge_adjacent 清掉源文件(`:4826-4843`);
- 被覆盖的旧 delete file(`:3959`);
- expire_snapshots 后无快照引用的 data/delete file(`:5022`、`:5086`)。

`data_file_id` 列也会存 `delete_file_id`(`:3946`)——它只是回执 id,删盘成功后按它出队
(`RemoveFilesScheduledForCleanup`,`:4765-4781`)。消费者 `ducklake_cleanup_old_files` 按
`schedule_start` 过滤(`GetOldFilesForCleanup`,`:4624-4646`);orphan 扫描把本表并入"已知
文件"名单防止误删(`:4673-4682`)。详见 [MAINTENANCE_DESIGN.md](MAINTENANCE_DESIGN.md)。

## 四、统计表

统计表与 versioned 表族不同:**没有 begin/end_snapshot,只维护当前态**,UPDATE in place。
time travel 读历史快照时全局统计不可用,只能回退文件级推导。

### 4.1 ducklake_table_stats / ducklake_table_column_stats

```sql
CREATE TABLE ducklake_table_stats(table_id BIGINT, record_count BIGINT, next_row_id BIGINT,
    file_size_bytes BIGINT);
CREATE TABLE ducklake_table_column_stats(table_id BIGINT, column_id BIGINT, contains_null BOOLEAN,
    contains_nan BOOLEAN, min_value VARCHAR, max_value VARCHAR, extra_stats VARCHAR);
```
(`src/storage/ducklake_metadata_manager.cpp:228-229`)

- `record_count`:表当前净行数;`next_row_id`:row id 分配水位(与 3.1 `row_id_start`
  配套);`file_size_bytes`:数据文件总字节。
- column 级是**全表聚合**(跨所有文件 merge 后的结果):`contains_null`/`contains_nan`/
  `min_value`/`max_value`/`extra_stats`,任一列 NULL 表示"未知/已失效"(读取按 IsNull 区分
  has_xxx 标志,`:944-977`)。
- 首次写 INSERT(`:4554-4557`)、其后 UPDATE;column 级故意拆成每列一条 UPDATE 而不是
  `UPDATE ... FROM (VALUES ...)`,以绕开 DuckDB 后端的一个字符串损坏 bug 并兼容 SQLite
  (注释 `:4564-4574`)。读取 query `:1002-1009`(全表)/`:1018-1027`(单表)。
- DROP TABLE 不立即清理;expire_snapshots 确认表彻底不可达后按 `table_id` DELETE
  (`:5113-5126`)。统计收集逻辑与 `DuckLakeColumnStats` 结构归
  [DML_DESIGN.md](DML_DESIGN.md)。

### 4.2 ducklake_file_column_stats

```sql
CREATE TABLE ducklake_file_column_stats(data_file_id BIGINT, table_id BIGINT, column_id BIGINT,
    column_size_bytes BIGINT, value_count BIGINT, null_count BIGINT, min_value VARCHAR,
    max_value VARCHAR, contains_nan BOOLEAN, extra_stats VARCHAR);
```
(`src/storage/ducklake_metadata_manager.cpp:224`)

per (file, column) 的 zone map:`min_value`/`max_value` 统一序列化为 VARCHAR(扫描时按列类
型 CAST 回来做过滤与 Top-N file ordering,`:1706-1711`);`value_count`/`null_count` 供
`contains_null` 推导;`extra_stats` v0.3 新增(`:301`),存几何 bbox 等扩展统计。写入与
data file 同批(`:3853-3862`)。文件裁剪消费路径见 [SCAN_DESIGN.md](SCAN_DESIGN.md)。
`column_id` 对嵌套类型是叶子 field id,因此 STRUCT 子字段有独立 zone map。

### 4.3 ducklake_file_variant_stats

```sql
CREATE TABLE ducklake_file_variant_stats(data_file_id BIGINT, table_id BIGINT, column_id BIGINT,
    variant_path VARCHAR, shredded_type VARCHAR, column_size_bytes BIGINT, value_count BIGINT,
    null_count BIGINT, min_value VARCHAR, max_value VARCHAR, contains_nan BOOLEAN, extra_stats VARCHAR);
```
(`src/storage/ducklake_metadata_manager.cpp:225`,v0.4 新增 `:317`)

VARIANT 列 shredding 后的 per-path 统计:`column_id` 是 VARIANT 根列的 field id,
`variant_path` 是字段路径,`shredded_type` 是该路径 shred 出的物理类型,其余列与 4.2 同构
(写入 `:3863-3873`;C++ 结构 `DuckLakeVariantStatsInfo`,
`src/include/storage/ducklake_metadata_info.hpp:145-149`)。

## 五、分区与排序表

### 5.1 ducklake_partition_info / ducklake_partition_column

```sql
CREATE TABLE ducklake_partition_info(partition_id BIGINT, table_id BIGINT, begin_snapshot BIGINT,
    end_snapshot BIGINT);
CREATE TABLE ducklake_partition_column(partition_id BIGINT, table_id BIGINT,
    partition_key_index BIGINT, column_id BIGINT, transform VARCHAR);
```
(`src/storage/ducklake_metadata_manager.cpp:230-231`)

一行 `partition_info` = 表的一个分区定义版本(`partition_id` 取自 `next_catalog_id`,
`src/storage/ducklake_transaction.cpp:1022`);`SET PARTITIONED BY` 变更时旧定义关
`end_snapshot`、插入新 `partition_id`(`WriteNewPartitionKeys`,`:4267-4327`;与旧定义相同
时识别为 nop,`:4233-4265`)。`partition_column` 不带 begin/end,跟随其 `partition_id`。

- `partition_key_index`:分区键序号(0 起)。
- `column_id`:field id。**v0.1 存的是列序号**,v0.2 迁移时用
  `LIST(column_id ORDER BY column_order)[idx+1]` 转换为 field id(`:262`)。
- `transform`:文本枚举 `'identity'` / `'year'` / `'month'` / `'day'` / `'hour'` /
  `'bucket(N)'`(写入 `src/storage/ducklake_transaction.cpp:1029-1047`,解析
  `src/storage/ducklake_catalog.cpp:625-647`)。

### 5.2 ducklake_file_partition_value

```sql
CREATE TABLE ducklake_file_partition_value(data_file_id BIGINT, table_id BIGINT,
    partition_key_index BIGINT, partition_value VARCHAR);
```
(`src/storage/ducklake_metadata_manager.cpp:232`)

每个分区文件按键序号一行,`partition_value` 文本序列化(NULL 保留 SQL NULL,
`:3878-3890`)。扫描分区裁剪与 bucket 等值裁剪(`:1729-1739`)的依据;compaction 读取时
`ARRAY_AGG(partition_value ORDER BY partition_key_index)` 还原(`:2209-2213`)。

### 5.3 ducklake_sort_info / ducklake_sort_expression

```sql
CREATE TABLE ducklake_sort_info(sort_id BIGINT, table_id BIGINT, begin_snapshot BIGINT, end_snapshot BIGINT);
CREATE TABLE ducklake_sort_expression(sort_id BIGINT, table_id BIGINT, sort_key_index BIGINT,
    expression VARCHAR, dialect VARCHAR, sort_direction VARCHAR, null_order VARCHAR);
```
(`src/storage/ducklake_metadata_manager.cpp:241-242`,v0.4 新增)

`SET SORTED BY` 的定义,版本化模式与 partition 完全同构(`WriteNewSortKeys`,
`:4372-4437`)。`expression` 是任意 SQL 表达式文本 + `dialect`;`sort_direction` 取
`'ASC'`/`'DESC'`、`null_order` 取 `'NULLS_FIRST'`/`'NULLS_LAST'`(写 `:4410-4415`,读
`:904-910`)。写路径排序消费见 [DML_DESIGN.md](DML_DESIGN.md)。

## 六、inlined data 表(动态建表)

### 6.1 注册表 ducklake_inlined_data_tables

```sql
CREATE TABLE ducklake_inlined_data_tables(table_id BIGINT, table_name VARCHAR, schema_version BIGINT);
```
(`src/storage/ducklake_metadata_manager.cpp:234`)

记录每个用户表名下挂着哪些动态 inlined data 表。catalog 加载时作为子查询聚合进 table 信息
(`:664-668`)。注册与建表同一批 SQL 提交(`:2670-2674`)。

### 6.2 数据表 ducklake_inlined_data_<table_id>_<schema_version>

**已核实:确实是 per-table、且 per-schema_version 的动态表名**:

```cpp
// src/storage/ducklake_metadata_manager.cpp:2550-2552
return StringUtil::Format("ducklake_inlined_data_%d_%d", table_id, schema_version);
```

DDL 模板(`InlinedTableDdlSql`,`:2554-2558`):

```sql
CREATE TABLE IF NOT EXISTS <name>(row_id BIGINT, begin_snapshot BIGINT, end_snapshot BIGINT, <用户列定义...>);
```

- 用户列直接以原生类型建在元数据库里;元数据库不原生支持的嵌套类型降级为 VARCHAR
  (`GetColumnType`,`:2515-2548`)。
- 行级可见性与 1.3 同一套 `[begin, end)` 谓词(`:3135`、`:3187`);DELETE 内联行 = UPDATE
  `end_snapshot`(`:2889-2898`)。`row_id` 与 parquet 路径共享同一 row id 空间。
- 表 schema 变化后,写入方发现最新注册表名版本过旧时 bump `schema_version` 并新建一张
  (`WriteNewInlinedData`,`:2800-2831`;查最新版本 `LatestInlinedTableQuery`,
  `:2565-2571`)。
- flush 落盘后 `DELETE ... WHERE begin_snapshot <= flush_snapshot`(`:5253-5273`),被新版本
  取代且已清空的表由 maintenance DROP 并注销(`DropEmptySupersededInlinedTables`,
  `:5190-5240`)。读写细节见 [DATA_INLINING_DESIGN.md](DATA_INLINING_DESIGN.md)。

### 6.3 内联 delete 表 ducklake_inlined_delete_<table_id>

**已核实存在,且命名只含 table_id 不含 schema_version**(删除只关心 file_id/row_id,与表
schema 无关):

```cpp
// src/storage/ducklake_metadata_manager.cpp:2903-2905
return StringUtil::Format("ducklake_inlined_delete_%d", table_id.index);
```

```sql
CREATE TABLE IF NOT EXISTS <name>(file_id BIGINT, row_id BIGINT, begin_snapshot BIGINT);
```
(`:2918-2920`,惰性创建亦见 `:3066-3068`)

对 **parquet 数据文件**的行级删除可以不写 deletion vector 文件、直接把
`(file_id, row_id, begin_snapshot)` 内联进元数据库(小批量 DELETE 的低开销路径)。注意
**没有 `end_snapshot`**:删除记录只追加不回滚,可见性只看
`begin_snapshot <= {SNAPSHOT_ID}`(`:2973-2975`)。`file_id` 指向
`ducklake_data_file.data_file_id`。表是否存在用探测查询 + 两级缓存判定
(`GetInlinedDeletionTableName`,`:3045-3092`)。净行数计算(`:527-534`)、scan
(`:1768-1811`)、compaction(`:2281-2304`)都要合并这一来源。

## 七、配置与映射表

### 7.1 ducklake_metadata

```sql
CREATE TABLE ducklake_metadata(key VARCHAR NOT NULL, value VARCHAR NOT NULL, scope VARCHAR, scope_id BIGINT);
```
(`src/storage/ducklake_metadata_manager.cpp:215`)

catalog 级 key/value 配置。固有 key 在初始化时写入(`:202`):`version`(格式版本字符串,
迁移判定依据)、`created_by`(`DuckDB <source_id>`)、`data_path`、`encrypted`。

scope 语义(`LoadDuckLake()`,`:394-423`;upsert `SetConfigOption()`,`:5330-5374`):

- `scope IS NULL`:全局配置(含上述固有 key);
- `scope = 'schema'`,`scope_id = schema_id`:schema 级配置;
- `scope = 'table'`,`scope_id = table_id`:table 级配置;
- 其它 scope 报错。典型可配置项如 `data_inlining_row_limit`(三级作用域逐层覆盖),配置项
  的消费见 [ATTACH_CATALOG_DESIGN.md](ATTACH_CATALOG_DESIGN.md)。

`scope`/`scope_id` 是 v0.2 加列(`:257-258`),所以 `LoadDuckLake` 对 v0.1 库有两列退化查询
fallback(`:382-393`)。

### 7.2 ducklake_column_mapping / ducklake_name_mapping

```sql
CREATE TABLE ducklake_column_mapping(mapping_id BIGINT, table_id BIGINT, type VARCHAR);
CREATE TABLE ducklake_name_mapping(mapping_id BIGINT, column_id BIGINT, source_name VARCHAR,
    target_field_id BIGINT, parent_column BIGINT, is_partition BOOLEAN);
```
(`src/storage/ducklake_metadata_manager.cpp:235-236`,v0.2 新增 `:260-261`)

name map:为没有 DuckLake field_id 的外部 parquet(`ducklake_add_data_files`)建立
"parquet 字段名 → field id"映射,`ducklake_data_file.mapping_id` 引用之。

- `type`:当前唯一取值 `'map_by_name'`(写 `src/storage/ducklake_transaction_state.cpp:534`,
  读侧遇到其它值直接报错,`src/storage/ducklake_catalog.cpp:685-687`)。
- `column_id`:映射树内的节点 id;`parent_column` 指向父节点(嵌套字段),NULL 为根——结构
  与 `ducklake_column.parent_column` 同构但 id 空间独立。
- `source_name`:parquet 字段名;`target_field_id`:对应 `ducklake_column.column_id`。
- `is_partition`:该字段是 hive partition 虚拟列(值在路径里而非文件里;v0.3 加列
  `:293`)。

读 `GetColumnMappings()`(`:3998-4033`),写 `WriteNewColumnMappings()`(`:4035-4061`)。
两表均不 versioned;mapping 永不更新,孤儿 name_mapping 在 expire 时按
`NOT EXISTS(column_mapping)` 清理(`:5170-5180`)。

## 八、版本演进

版本枚举(`src/include/common/ducklake_version.hpp:15-27`):`V0_1, V0_2, V0_3_DEV1, V0_3,
V0_4_DEV1, V0_4, V1_0, V1_1_DEV_1`,最新 `DUCKLAKE_LATEST_VERSION = V1_1_DEV_1`;字符串映射
在 `src/common/ducklake_version.cpp:6-32`(`'0.1'`…`'1.1-dev1'`)。当前 `ducklake_metadata`
中 `version` 的写入值:基础 manager 写 `'1.0'`
(`src/storage/ducklake_metadata_manager.cpp:246-249`),`DuckLakeMetadataManagerV1_1` 覆写为
`'1.1-dev1'`(`src/metadata_manager/ducklake_metadata_manager_v1_1.cpp:14-18`)。

迁移链按版本逐级执行(`src/storage/ducklake_initializer.cpp:194-229`);`-dev1` 版本走同一迁
移的 `allow_failures=true` 重入模式(DDL 加 `IF NOT EXISTS` 容错,`ExecuteMigration`,
`src/storage/ducklake_metadata_manager.cpp:271-289`)。各版本 schema 差异(均自 MigrateV0X
反推,`:251-377`):

| 迁移 | schema 差异 |
|---|---|
| v0.1→v0.2 (`MigrateV01`, `:251-269`) | `ducklake_schema`/`ducklake_table` + `path`,`path_is_relative`;`ducklake_metadata` + `scope`,`scope_id`;`ducklake_data_file` + `mapping_id`;新增 `ducklake_column_mapping`、`ducklake_name_mapping`(尚无 `is_partition`);`ducklake_partition_column.column_id` 由列序号改写为 field id(`:262`)。 |
| v0.2→v0.3 (`MigrateV02`, `:291-305`) | `ducklake_name_mapping` + `is_partition`;`ducklake_snapshot_changes` + `author`,`commit_message`,`commit_extra_info`;新增 `ducklake_schema_versions`(全局粒度,无 `table_id`,从 snapshot 表 GROUP BY 回填 `:299`);旧表名 `ducklake_file_column_statistics` 改名 `ducklake_file_column_stats`(`:300`);file/table column stats + `extra_stats`。 |
| v0.3→v0.4 (`MigrateV03`, `:307-358`) | 新增 macro 三表、sort 两表、`ducklake_file_variant_stats`;`ducklake_column` + `default_value_type`(回填 `'literal'`)、`default_value_dialect`;`ducklake_schema_versions` + `table_id` 并迁移为 per-table 行(`:335-357`);`ducklake_data_file`/`ducklake_delete_file` + `partial_max`,旧 `partial_file_info` 文本列经 regexp 提取后 DROP(`:319-330`)。 |
| v0.4→v1.0 (`MigrateV04`, `:360-367`) | 无 schema 差异,仅 `version` 字符串改 `'1.0'`。 |
| v1.0→v1.1-dev1 (`MigrateV10`, `:369-376`) | 无 schema 差异,仅 `version` 改 `'1.1-dev1'`;`DuckLakeMetadataManagerV1_1::GetCreateTableStatements()` 目前原样返回基类 DDL(`src/metadata_manager/ducklake_metadata_manager_v1_1.cpp:8-12`),即 1.1 的 DDL 钩子已就位但尚未引入差异。 |

版本策略(`src/storage/ducklake_initializer.cpp:172-230`、`:269-287`):

- 新建 DuckLake 默认用 `DUCKLAKE_LATEST_VERSION`(可被 ATTACH 的 `ducklake_version` 参数或
  全局 setting `ducklake_default_version` 钉住,且必须 ≥ 1.0,`:85-95`、`:160-163`);
- attach 既有 catalog:catalog 版本 > 目标版本直接拒绝(禁止降级,`:181-187`);< 1.0 必须
  迁移(未开 `AUTOMATIC_MIGRATION` 则报错);≥ 1.0 且未显式 pin/未开自动迁移时**停留在
  catalog 当前版本**(`ResolveTargetVersion`,`:269-287`)——因此 1.0 库不会被悄悄升成
  1.1-dev1。
- 迁移代码本身的实现细节归 [METADATA_MANAGER_DESIGN.md](METADATA_MANAGER_DESIGN.md)。
