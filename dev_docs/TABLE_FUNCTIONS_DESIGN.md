# DuckLake 表函数目录与 CDC

> 行号基准:commit `47187559`(HEAD)。

## 概述

DuckLake 扩展对外的"管理面"几乎全部以表函数(table function)形式暴露:快照查询、CDC(change
data feed)、文件清单、配置读写、提交辅助、compaction/cleanup 等维护操作,统一在
`LoadInternal()`(`src/ducklake_extension.cpp:19-126`)里注册。注册形态分三类:

1. **普通 TableFunction / TableFunctionSet**:第一个位置参数固定为 catalog 名(VARCHAR),
   bind 期通过 `DuckLakeBaseMetadataFunction::GetCatalog()` 解析到具体的 attached DuckLake
   catalog。多数纯查询类函数继承 `DuckLakeBaseMetadataFunction`,在 bind 期就把整个结果集物化为
   `MetadataBindData::rows`,执行期只做分块吐出。
2. **default table macro(SQL 宏)**:`ducklake_table_changes` 不是 C++ 实现,而是一段注册进
   系统 catalog 的 SQL 宏(`src/functions/ducklake_table_changes.cpp:7-24`),由
   insertions/deletions 两个表函数 JOIN 拼出 `change_type`。
3. **per-catalog shorthand macro**:每个 DuckLake catalog 的 schema entry 内置一组省略
   catalog 参数的别名宏(`snapshots()`、`table_changes(...)` 等,
   `src/storage/ducklake_default_functions.cpp:10-24`),使 `FROM my_lake.snapshots()` 这种
   写法可用。01 篇已核实:这些内置 macro 的匹配只看函数名,不看 schema,所以在该 catalog 的任意
   schema 限定下都能解析。

此外注册了一个标量函数 `murmur3_32`(Iceberg 兼容 bucket 分区哈希)和 secret 类型/函数;
`ducklake_scan` 本身也注册一份,仅用于计划反序列化时按名查找
(`src/ducklake_extension.cpp:112-114`)。DuckLake **没有注册任何 PRAGMA**:
`DuckLakeSchemaEntry::CreatePragmaFunction` 直接抛 `NotImplementedException`
(`src/storage/ducklake_schema_entry.cpp:182-185`)。

### 全函数目录

下表以 `ducklake_extension.cpp:52-125` 的注册清单为准。"shorthand" 列指
`ducklake_default_functions.cpp` 中是否有省略前缀/由 catalog 限定的别名宏。位置参数中省略了所有
函数共有的第一个 `catalog VARCHAR`(`ducklake_commit` 例外,见 5.2)。

| 函数(注册名) | 位置参数(catalog 之外) | named 参数 | 返回 schema 要点 | 源文件(src/functions/) | shorthand | 详解 |
|---|---|---|---|---|---|---|
| `ducklake_snapshots` | — | — | snapshot_id, snapshot_time, schema_version, changes MAP(VARCHAR,LIST(VARCHAR)), author, commit_message, commit_extra_info | ducklake_snapshots.cpp | `snapshots()` | 本篇 3.1 |
| `ducklake_current_snapshot` | — | — | id UBIGINT(单行) | ducklake_current_snapshot.cpp | `current_snapshot()` | 本篇 3.2 |
| `ducklake_last_committed_snapshot` | — | — | id UBIGINT(单行,可 NULL) | ducklake_last_committed_snapshot.cpp | `last_committed_snapshot()` | 本篇 3.2 |
| `ducklake_table_info` | — | — | table_name, schema_id, table_id, table_uuid, file_count, file_size_bytes, delete_file_count, delete_file_size_bytes | ducklake_table_info.cpp | `table_info()` | 本篇 3.3 |
| `ducklake_list_files` | table VARCHAR | schema, snapshot_version BIGINT, snapshot_time TIMESTAMPTZ | data_file/delete_file 各 4 列(path/size/footer_size/encryption_key) | ducklake_list_files.cpp | 无 | 本篇 3.4 |
| `ducklake_table_insertions` | schema, table, start, end(start/end 为 BIGINT 或 TIMESTAMPTZ 两套 overload) | — | 表在 end 快照时的全部列(snapshot_id/rowid 经虚拟列投影) | ducklake_table_insertions.cpp | `table_insertions(...)` | 本篇 2 |
| `ducklake_table_deletions` | 同上 | — | 同上 | ducklake_table_insertions.cpp | `table_deletions(...)` | 本篇 2 |
| `ducklake_table_changes`(macro) | schema_name, table_name, start_snapshot, end_snapshot | — | snapshot_id, rowid, change_type, 表全列 | ducklake_table_changes.cpp | `table_changes(...)` | 本篇 2.4 |
| `ducklake_set_option` | option VARCHAR, value ANY | table_name, schema | Success BOOLEAN(实际 0 行) | ducklake_set_option.cpp | `set_option(...)` | 本篇 4.3 |
| `ducklake_options` | — | — | option_name, description, value, scope, scope_entry | ducklake_options.cpp | `options()` | 本篇 4.1 |
| `ducklake_settings` | — | — | catalog_type, extension_version, data_path(单行) | ducklake_settings.cpp | `settings()` | 本篇 4.2 |
| `ducklake_set_commit_message` | author VARCHAR, commit_message VARCHAR | extra_info | Success BOOLEAN(实际 0 行) | ducklake_set_commit_message.cpp | `set_commit_message(...)` | 本篇 5.1 |
| `ducklake_commit` | (metadata_schema_name VARCHAR, schema_version BIGINT)——无 catalog 参数 | max_retry_count, retry_wait_ms, retry_backoff | committed_snapshot_id, committed_schema_version, had_flushes | ducklake_commit.cpp | 无 | 注册形态本篇 5.2,协议语义见 03 |
| `ducklake_merge_adjacent_files` | [table VARCHAR](两套 overload:仅 catalog / catalog+table) | min_file_size, max_file_size, max_compacted_files, schema(仅带 table 的 overload) | schema_name, table_name, files_processed, files_created | ducklake_compaction_functions.cpp | `merge_adjacent_files()` | 09 |
| `ducklake_rewrite_data_files` | 同上 | delete_threshold, schema(仅带 table 的 overload) | 同上 | ducklake_compaction_functions.cpp | 无 | 09 |
| `ducklake_expire_snapshots` | — | older_than TIMESTAMPTZ, versions LIST(UBIGINT), dry_run | 与 `ducklake_snapshots` 同构(被过期的快照) | ducklake_expire_snapshots.cpp | 无 | 09 |
| `ducklake_cleanup_old_files` | — | older_than, cleanup_all, dry_run | path VARCHAR | ducklake_cleanup_files.cpp | 无 | 09 |
| `ducklake_delete_orphaned_files` | — | older_than, cleanup_all, dry_run | path VARCHAR | ducklake_cleanup_files.cpp | 无 | 09 |
| `ducklake_flush_inlined_data` | — | schema_name, table_name | schema_name, table_name, rows_flushed | ducklake_flush_inlined_data.cpp | 无 | 08 |
| `ducklake_add_data_files` | table VARCHAR, files(VARCHAR 或 LIST(VARCHAR) 两套 overload) | allow_missing, ignore_extra_columns, hive_partitioning, schema | filename VARCHAR | ducklake_add_data_files.cpp | 无 | 09 |
| `murmur3_32`(标量) | ANY → INTEGER | — | — | ducklake_murmur3.cpp | —(全局标量函数) | 本篇 6 |

注:`ducklake_flush_inlined_data`、`ducklake_merge_adjacent_files`、`ducklake_rewrite_data_files`
不走常规 bind/execute,而是设置 `bind_operator` 直接产出逻辑算子树(如
`ducklake_flush_inlined_data.cpp:761-766`),因此它们是"会写数据"的计划级函数,详解归 08/09。

### 关键源码位置

| 主题 | 位置 |
|---|---|
| 注册清单(唯一事实来源) | `src/ducklake_extension.cpp:52-125` |
| 公共绑定骨架 / GetCatalog | `src/functions/base_metadata_function.cpp:7-65` |
| MetadataBindData 定义 | `src/include/functions/ducklake_table_functions.hpp:30-42` |
| per-catalog shorthand macro 表 | `src/storage/ducklake_default_functions.cpp:10-24` |
| shorthand 的 lookup 钩子 | `src/storage/ducklake_schema_entry.cpp:343-352` |
| CDC bind(insertions/deletions 共用) | `src/functions/ducklake_table_insertions.cpp:46-78` |
| table_changes 宏 SQL | `src/functions/ducklake_table_changes.cpp:7-24` |
| 区间语义(文件级过滤 SQL) | `src/storage/ducklake_metadata_manager.cpp:1818-2067` |
| timestamp→snapshot 解析(LOWER/UPPER_BOUND) | `src/storage/ducklake_metadata_manager.cpp:4195-4231` |
| set_option 校验与写入 | `src/functions/ducklake_set_option.cpp:77-228`、`src/storage/ducklake_metadata_manager.cpp:5330-5374` |
| murmur3_32 实现与消费点 | `src/functions/ducklake_murmur3.cpp:9-102`、`src/storage/ducklake_partition_data.cpp:43-120` |

## 关联文档

- [ATTACH_CATALOG_DESIGN.md](ATTACH_CATALOG_DESIGN.md)(01):扩展入口注册、配置作用域的**读取**链(`TryGetScopedConfigOption`)、table macro 按名匹配的发现。
- [TRANSACTION_DESIGN.md](TRANSACTION_DESIGN.md)(02):`DuckLakeTransaction::GetSnapshot` 的事务内快照 pin 与缓存。
- [COMMIT_PROTOCOL_DESIGN.md](COMMIT_PROTOCOL_DESIGN.md)(03):`ducklake_commit` 的 server 端提交协议、commit_info 的消费时机。
- [METADATA_SCHEMA_DESIGN.md](METADATA_SCHEMA_DESIGN.md)(04):`ducklake_metadata`/`ducklake_snapshot` 等存储表结构。
- [SCAN_DESIGN.md](SCAN_DESIGN.md)(06):`DuckLakeScanType::SCAN_INSERTIONS/SCAN_DELETIONS` 的扫描执行机制、虚拟列投影。
- [DML_DESIGN.md](DML_DESIGN.md)(07):bucket 分区写路径中 murmur3 的用法、UPDATE 保留 row_id 的语义(CDC update 识别的前提)。
- [DATA_INLINING_DESIGN.md](DATA_INLINING_DESIGN.md)(08):`ducklake_flush_inlined_data` 详解。
- [MAINTENANCE_DESIGN.md](MAINTENANCE_DESIGN.md)(09):compaction/expire/cleanup/add_data_files 详解。

## 一、注册框架与调用形态

### 1.1 DuckLakeBaseMetadataFunction:bind 期物化骨架

`DuckLakeBaseMetadataFunction`(`src/functions/base_metadata_function.cpp:63-65`)是一个
`TableFunction` 子类,固定 `{LogicalType::VARCHAR}` 单参数签名(子类可再 push 额外参数,如
`ducklake_list_files`),统一挂 `MetadataFunctionExecute` + `MetadataFunctionInit`,只由子类提供
bind 回调。模式是:**bind 回调直接查元数据并把全部结果行物化进
`MetadataBindData::rows`(`vector<vector<Value>>`)**,`MetadataFunctionExecute`
(`base_metadata_function.cpp:38-61`)只按 `STANDARD_VECTOR_SIZE` 分块 `Vector::Append` 吐出。
这意味着这些函数的结果在 binder 阶段就确定,执行期不再访问元数据;结果集规模默认是"元数据量级"。

采用此骨架的有:`ducklake_snapshots`、`ducklake_table_info`、`ducklake_current_snapshot`、
`ducklake_last_committed_snapshot`、`ducklake_list_files`、`ducklake_settings`、
`ducklake_options`(该函数把物化推迟到了 `init_global`,见 4.1)。

### 1.2 第一参数 catalog 解析

`DuckLakeBaseMetadataFunction::GetCatalog`(`base_metadata_function.cpp:7-23`)按
database 名查 `DatabaseManager`,并校验 `catalog.GetCatalogType() == "ducklake"`,否则
`BinderException`。所有需要 catalog 的表函数(包括非骨架类的 `ducklake_set_option` 等)都在各自
bind 里调用它,即 catalog 参数是**按名解析的 attached database**,与当前 USE 无关。

### 1.3 两层 macro

**全局层**:`ducklake_table_changes` 经 `DefaultTableFunctionGenerator::CreateTableMacroInfo`
注册为系统级 table macro(`ducklake_extension.cpp:91-92`),任何地方都能以全名调用。

**per-catalog 层**:`DuckLakeSchemaEntry::LookupEntry` 对 `TABLE_FUNCTION_ENTRY` 类型的查找先走
`TryLoadBuiltInFunction`(`ducklake_schema_entry.cpp:343-352`),按名匹配
`ducklake_default_functions.cpp:10-24` 的宏表并惰性实例化(每 schema 一份缓存,
`default_function_map`)。宏体在加载时做 `{CATALOG}`/`{SCHEMA}` 文本替换
(`ducklake_default_functions.cpp:27-38`),例如 `my_lake.table_changes('t', 1, 5)` 展开成
`FROM ducklake_table_changes('my_lake', '<当前 schema>', 't', 1, 5)`。shorthand 覆盖的 12 个名字见
总表;注意 `set_option`/`set_commit_message` 的 shorthand 给 named 参数提供了 `NULL` 默认值
(宏表第 12-13 行),而 `merge_adjacent_files()` shorthand 只有全 catalog 形态。

由于匹配只看函数名(01 篇结论),`my_lake.any_schema.snapshots()` 同样解析成功;`{SCHEMA}`
替换的是宏被解析时所在的 schema,这只影响 `table_changes/table_insertions/table_deletions`
三个带 `{SCHEMA}` 的宏的默认 schema 语义。

### 1.4 没有 PRAGMA,没有 CALL 专用入口

所有函数都是表函数,`CALL ducklake_xxx(...)` 只是 DuckDB 对表函数的等价调用语法;DuckLake 自身
不注册 pragma(`ducklake_schema_entry.cpp:182-185` 明确禁止在其 catalog 内创建)。

## 二、CDC 三件套:table_insertions / table_deletions / table_changes

### 2.1 签名与 overload

`DuckLakeTableInsertionsFunction::GetFunctions()`(`ducklake_table_insertions.cpp:88-96`)注册
两个 overload:`(VARCHAR catalog, VARCHAR schema, VARCHAR table, T start, T end)`,其中 `T` 为
`BIGINT`(snapshot version)或 `TIMESTAMP_TZ`(snapshot time),deletions 同构
(`:98-106`)。start/end 必须同类型,不能混用。`AtClauseFromValue`
(`:32-44`)把 BIGINT 包装成 `BoundAtClause("version", v)`,TIMESTAMP_TZ 包装成
`BoundAtClause("timestamp", v)`,NULL 直接 `BinderException`。

### 2.2 bind:复用表扫描 + 替换 scan_type

两个函数共用 `DuckLakeTableChangesBind`(`ducklake_table_insertions.cpp:46-68`),关键动作:

1. 以 **end** 的 at_clause 构造 `EntryLookupInfo` 查表项——即返回列是**表在 end 快照时刻的
   schema**(time travel 语义,schema 演化以 end 为准)。
2. `input.table_function = table.GetScanFunction(...)`:整个函数被**偷换成普通的
   ducklake 表扫描**,自身的 init/execute 是占位符,绑到就抛 `InternalException`(`:80-86`)。
3. 在扫描的 `DuckLakeFunctionInfo` 上设置
   `start_snapshot = transaction.GetSnapshot(start_at_clause, SnapshotBound::LOWER_BOUND)` 和
   `scan_type = SCAN_INSERTIONS / SCAN_DELETIONS`(`:64-66`)。`start_snapshot` 字段仅这两种
   scan type 使用(`src/include/storage/ducklake_scan.hpp:54-55`)。

后续文件清单获取在 `DuckLakeMultiFileList::GetFiles()` 按 scan_type 分派
(`src/storage/ducklake_multi_file_list.cpp:431-451`),insertions/deletions 各走
`GetTableInsertions()/GetTableDeletions()`(`:377-421`),执行机制(虚拟列、delete file 反向
扫描、inlined data 源)见 06。

返回列名/类型取自 `function_info.column_names/column_types`,即表的用户列;宏里引用的
`snapshot_id`、`rowid` 是 ducklake 扫描的**虚拟列**
(`src/storage/ducklake_table_entry.cpp:392-405`,`snapshot_id` BIGINT、`rowid` BIGINT),
需要显式投影才出现。

### 2.3 区间语义:闭区间 [start, end]

**端点解析**(`src/storage/ducklake_metadata_manager.cpp:4195-4231`):

- `version` 单位:精确匹配 `snapshot_id = v`,不存在则报错(bound 参数无效果)。
- `timestamp` 单位:`LOWER_BOUND`(start 用)取 `snapshot_time >= ts` 中最早的快照;
  `UPPER_BOUND`(end 用,`DuckLakeTransaction::GetSnapshot` 的默认值,
  `src/include/storage/ducklake_transaction.hpp:199`)取 `snapshot_time <= ts` 中最晚的快照。
  即时间戳区间被"内收"映射为 snapshot id 闭区间。

**文件级过滤**:

- insertions(`metadata_manager.cpp:1828-1845`):
  `begin_snapshot <= end AND (begin_snapshot >= start OR partial_max >= start)`——即报告
  **由 snapshot ∈ [start, end] 提交的插入行**,两端均含。`partial_max` 分支处理一个数据文件
  跨多个快照追加(data inlining flush、多快照共享文件)的情况:此时文件级无法精确裁剪,改为给
  `file_entry` 挂 `snapshot_filter_min/max` 做行级过滤(`:1860-1871`,行内嵌的
  begin_snapshot 列在扫描时再过滤,机制见 06/08)。
- deletions(`metadata_manager.cpp:1883-2067`):三类来源 UNION——
  (a) delete file:取 `begin_snapshot <= end` 的 delete file,LATERAL JOIN 出同一数据文件
  `begin_snapshot < start` 的"前一版" delete file(`:1922-1947`),报告行 = 当前版减去前版
  (DuckLake 的 delete file 是全量重写,差集即区间内新删的行);
  (b) 整文件删除:`end_snapshot ∈ [start, end]` 的数据文件(`:1951-1955`);
  (c) inlined 删除:元数据库内嵌删除表中 `begin_snapshot ∈ [start, end]` 的行(`:1905-1916`)。
  行级 snapshot 范围随 entry 带下去(`entry.start_snapshot/end_snapshot`,`:2050-2051`)。

因此对单个快照 S 的变更,调用 `(S, S)` 即可;`(0, 当前)` 给出全历史。事务本地(未提交)表不支持:
`GetTableInsertions/GetTableDeletions` 对 transaction-local 表抛 `InternalException`
(`multi_file_list.cpp:378-380, 397-399`)。

### 2.4 ducklake_table_changes:宏组合与 change_type 判定

`ducklake_table_changes.cpp:7-24` 的宏体(节选):

```sql
SELECT i.snapshot_id, i.rowid,
       CASE WHEN d.rowid IS NOT NULL THEN 'update_postimage' ELSE 'insert' END AS change_type, i.*
FROM ducklake_table_insertions(...) i
LEFT JOIN ducklake_table_deletions(...) d
  ON i.snapshot_id = d.snapshot_id AND i.rowid = d.rowid
UNION ALL
SELECT d.snapshot_id, d.rowid,
       CASE WHEN i.rowid IS NOT NULL THEN 'update_preimage' ELSE 'delete' END AS change_type, d.*
FROM ducklake_table_deletions(...) d
LEFT JOIN ducklake_table_insertions(...) i
  ON d.snapshot_id = i.snapshot_id AND d.rowid = i.rowid
```

核实结论:**update 的识别 = 同一 snapshot_id 下同一 rowid 既出现在 deletions 又出现在
insertions**。这成立的前提是 DuckLake 的 UPDATE 实现为 delete + re-insert 且**保留原 row_id**
(07 篇);于是双向 LEFT JOIN 后:只在 insert 侧 → `insert`;只在 delete 侧 → `delete`;两侧都
命中 → insert 侧行标 `update_postimage`(新值)、delete 侧行标 `update_preimage`(旧值)。
代价是 insertions/deletions 各被扫描两次(宏展开后是 4 个表函数实例),DuckDB 不会自动共享。
输出列 = `snapshot_id, rowid, change_type` + `i.*`/`d.*`(表全列;`i.*` 不含虚拟列)。

## 三、快照与状态查询

### 3.1 ducklake_snapshots

bind 期经 `metadata_manager.GetAllSnapshots()` 物化全部快照
(`ducklake_snapshots.cpp:156-170`)。返回 7 列(`:38-59`),核实 **changes 列确为
`MAP(VARCHAR, LIST(VARCHAR))`**,由 `ducklake_snapshot_changes.changes_made` 解析而来
(`GetSnapshotValues`,`:71-154`)。map key 是变更类别,value 是 id 或名字列表;key 全集(按
代码顺序):`schemas_created`、`schemas_dropped`、`tables_created`、`views_created`、
`scalar_macros_created`、`table_macros_created`、`tables_dropped`、`tables_altered`、
`tables_inserted_into`、`tables_deleted_from`、`views_dropped`、`scalar_macros_dropped`、
`table_macros_dropped`、`views_altered`、`inlined_insert`、`inlined_delete`、
`flushed_inlined`、`merge_adjacent`、`rewrite_delete`。created 类的 value 是
`schema.name` 形式的名字,其余是 id 字符串。`author/commit_message/commit_extra_info` 三列
即 5.1 写入的提交信息。`GetSnapshotTypes/GetSnapshotValues` 是 static 的,被
`ducklake_expire_snapshots` 复用作返回 schema(`ducklake_expire_snapshots.cpp:29`)。

### 3.2 current_snapshot vs last_committed_snapshot

两者语义差异(均核实):

- `ducklake_current_snapshot`(`ducklake_current_snapshot.cpp:10-28`)返回
  `transaction.GetSnapshot()`——**当前事务 pin 住的快照**:首次访问时取元数据库最新快照并缓存于
  事务(`src/storage/ducklake_transaction.cpp:1536-1548`);若 ATTACH 时指定了
  `SNAPSHOT_VERSION/SNAPSHOT_TIME`,则恒返回该固定快照(`CatalogSnapshot()` 分支)。同一事务内
  多次调用结果一致;它反映"我在读什么",与别人是否已提交无关。
- `ducklake_last_committed_snapshot`(`ducklake_last_committed_snapshot.cpp:12-31`)返回
  `DuckLakeCatalog::GetLastCommittedSnapshotId()`——一个**纯进程内**的 `optional_idx`
  (`src/include/storage/ducklake_catalog.hpp:234-240`),只在本 attach 的 catalog 上成功提交
  事务时经 commit 回调 `set_committed_snapshot_id` 写入
  (`ducklake_transaction.cpp:1463-1465` → `ducklake_catalog.hpp:221-224`)。语义即"**本进程
  通过这个 attached catalog 最后一次提交产生的 snapshot id**";ATTACH 以来没提交过则为 NULL,
  其它进程/连接的提交不会反映进来。典型用途:写完一批后拿到自己产生的快照号,再喂给 CDC 函数。

### 3.3 ducklake_table_info

`ducklake_table_info.cpp:8-57`:对当前事务快照调 `metadata_manager.GetTableSizes()`,每表一行,
输出名称/ids/uuid 与 data file、delete file 的数量与字节数(均为活跃文件口径)。

### 3.4 ducklake_list_files

`ducklake_list_files.cpp:35-113`。位置参数 `(catalog, table_name)`,named 参数
`schema VARCHAR`、`snapshot_version BIGINT`、`snapshot_time TIMESTAMP_TZ`;后两者互斥
(`:77-79`),给出其一则构造 at_clause 做 time travel(表项查找与文件清单都用该快照,`:83-86`)。
经 `GetFilesForTable(table, snapshot, nullptr)` 取清单(`:91`,filter 传 nullptr,代码留有
FIXME:不支持谓词下推)。每行 = 一个 data file 及其**当前关联的 delete file**;两组各 4 列
(path、size_bytes、footer_size、encryption_key),无 delete file 时 4 列全 NULL
(`AddFileInfo`,`:10-33`)。footer_size 用于免读 parquet footer 的优化、encryption_key 仅在
加密模式下非 NULL——该函数实质是把 06 篇扫描入口拿到的 `DuckLakeFileListEntry` 原样表格化,可供
外部引擎直读数据文件。

## 四、配置函数

### 4.1 ducklake_options:列出已存储的配置

`ducklake_options.cpp:66-177`。它**不是**"有效配置视图",而是 `ducklake_metadata` 表内容的
直接呈现(读取经 `metadata_manager.LoadDuckLake()`,`:104`):global tags、schema 级、table 级
三段分别产出 scope = `GLOBAL` / `SCHEMA` / `TABLE` 的行(`:106-145`),`scope_entry` 列对
schema/table 作用域解析出名字(table 为 `schema.table`)。未显式 SET 过的选项不出现;选项的
内建默认值(如 `parquet_compression` 缺省 snappy)不在结果里。`description` 列查静态表
`DUCKLAKE_OPTIONS`(`:14-41`,目前 20 项),未知 key 给 NULL。结果按 option_name 排序。注意
该函数物化发生在 `init_global` 而非 bind(`:97-150`),与骨架的其它函数不同——行为等价,只是
延迟到执行前。

### 4.2 ducklake_settings:attach 级静态信息

`ducklake_settings.cpp:7-50`,核实内容:单行三列——`catalog_type`(元数据库类型,把
`postgres_scanner`/`sqlite_scanner` 规范化为 `postgres`/`sqlite`,空、`motherduck`、
`md_server` 归为 `duckdb`)、`extension_version`(编译期 `EXT_VERSION_DUCKLAKE`)、
`data_path`。与 `options()` 的区别:它报告的是**这个 attach 的环境信息**而非存储在
`ducklake_metadata` 里的可写配置。

### 4.3 ducklake_set_option:校验 + 写入(本篇职责)

签名 `(catalog, option VARCHAR, value ANY)` + named `table_name`/`schema`
(`ducklake_set_option.cpp:223-228`)。**合法 option 是 bind 里的硬编码 if-else 枚举**
(`:88-167`),未命中直接 `NotImplementedException`(`:166`);没有集中注册表,与 4.1 的
`DUCKLAKE_OPTIONS` 描述表是两份独立清单(后者还含 `version`/`created_by`/`data_path`/
`encrypted` 等只读项,不可经 set_option 写)。可写项及值校验:

| option | 值校验(bind 期) |
|---|---|
| `parquet_compression` | 枚举:uncompressed/snappy/gzip/zstd/brotli/lz4/lz4_raw(大小写不敏感,存小写) |
| `parquet_version` | 1 或 2,存 `V1`/`V2` |
| `parquet_compression_level` | cast 到 UBIGINT |
| `parquet_row_group_size` | UBIGINT 且 != 0 |
| `parquet_row_group_size_bytes` | `DBConfig::ParseMemoryLimit`(支持 `100MB` 等)且 != 0 |
| `target_file_size` | `ParseMemoryLimit` |
| `data_inlining_row_limit` | UBIGINT;>0 时额外校验目标作用域内的表没有与 inlining 系统列冲突的列名(`ValidateNoReservedInliningColumns`,`:49-63`,作用域可为单表/单 schema/全库逐表扫描) |
| `require_commit_message` | BOOLEAN |
| `rewrite_delete_threshold` | DOUBLE ∈ [0,1] |
| `hive_file_pattern` / `per_thread_output` / `write_deletion_vectors` / `sort_on_insert` | BOOLEAN |
| `delete_older_than` / `expire_older_than` | 非空时必须可被 `Interval::FromString` 解析 |
| `auto_compact` | BOOLEAN 且非 NULL |

值类型校验靠 `DefaultCastAs`/`CastAs`,cast 失败即报错——这就是"值类型校验在哪"的答案:没有
独立的类型表,逐项 cast。

**scope 解析与校验**(`:169-197`):`table_name` 非空 → 解析表项取 `table_id`;否则
`schema` 非空 → 取 `schema_id`;都空 → global。transaction-local(本事务新建尚未提交)的表/
schema 拒绝设置(`:186-187, 194-195`)。优先级上 table_name 存在时 schema 仅用于定位表。

**写入发生在 execute 期**(`:215-221`):`transaction.SetConfigOption()` 做两件事
(`ducklake_transaction.cpp:1470-1475`):

1. `metadata_manager->SetConfigOption()`(`metadata_manager.cpp:5330-5374`):对
   `ducklake_metadata` 表按 `(key, scope, scope_id)` 先 COUNT 判存在,再 INSERT 或 UPDATE。
   scope 编码:global 行 `scope IS NULL`,schema/table 行 `scope='schema'/'table'` +
   `scope_id`(存储表结构见 04)。该 SQL 走事务的元数据连接,随 DuckLake 事务一起提交/回滚。
2. `ducklake_catalog.SetConfigOption()`(`ducklake_catalog.cpp:929-945`):同步更新进程内
   `DuckLakeConfigOptions` 的三层 map,使本进程后续读取立即生效(读取链
   `TryGetScopedConfigOption` 的 table > schema > global 优先级归 01 篇)。注意这一步**不等
   提交就改了共享的 catalog 内存态**,事务回滚不会撤销内存里的值。

返回 schema 声明了 `Success BOOLEAN` 一列,但 execute 不向 output 填行(`:215-221`),实际
结果为 0 行——`ducklake_set_commit_message` 同样如此。

## 五、提交辅助

### 5.1 ducklake_set_commit_message

`ducklake_set_commit_message.cpp:32-57`:`(catalog, author VARCHAR, commit_message VARCHAR)` +
named `extra_info VARCHAR`。execute 期把三个值装进 `DuckLakeSnapshotCommit`(置
`is_commit_info_set = true`)并 `transaction.SetCommitMessage()` 存入**事务 state**
(`ducklake_transaction.cpp:1481-1483`),也就是只对当前事务的下一次提交生效。消费点在提交
写 `ducklake_snapshot` 行时:`{AUTHOR}/{COMMIT_MESSAGE}/{COMMIT_EXTRA_INFO}` 模板替换
(`metadata_manager.cpp:2399-2406`、`WriteSnapshotChangesSql` `:4075-4079`),协议细节归 03。
与之配套的 `require_commit_message` 选项在提交期经 `EnsureCommitInfoProvided` 强制:开启后
未调用过本函数的事务提交直接报错(`ducklake_transaction_state.cpp:50-58`,调用点 `:1380`)。
读取侧即 3.1 中 `snapshots()` 的最后三列。

### 5.2 ducklake_commit(server 端函数)

`ducklake_commit.cpp:14-77`。注册形态特殊:**不带 catalog 参数**,位置参数是
`(metadata_schema_name VARCHAR, schema_version BIGINT)`(两者 NULL 则 BinderException),
named 参数 `max_retry_count BIGINT`/`retry_wait_ms BIGINT`/`retry_backoff DOUBLE` 覆盖重试
配置。它不在客户端 DuckLake catalog 上运行,而是设计为**在元数据服务器侧执行**:客户端把变更
暂存(staged tables)后发一条 `FROM ducklake_commit(...)`,server 端构造
`DuckLakeServerSideCommit`(读 staged 表、跑提交重试循环,
`src/storage/ducklake_server_side_commit.cpp`)并返回单行
`(committed_snapshot_id, committed_schema_version, had_flushes)`。是否走该路径由
`DuckLakeCatalog::RetrialsServerSide()` 决定;完整协议语义见 03。该函数没有 shorthand 宏,
不面向最终用户。

## 六、murmur3_32 标量函数

`ducklake_murmur3.cpp:98-102`:`murmur3_32(ANY) → INTEGER`,
`FunctionNullHandling::SPECIAL_HANDLING`(NULL 入参产出 NULL 行而非整体短路)。实现是
Iceberg `murmur3_x86_32`(seed 0)的逐类型适配(`:9-96`):BOOLEAN → 0/1 按 int64 哈希;
所有整型符号扩展到 int64 按 8 字节哈希;FLOAT/DOUBLE → double 的位模式(-0.0 归一化为 +0.0)
按 int64 哈希;VARCHAR 直接哈希 UTF-8 字节;其余复杂类型 fallback 为 `Value::ToString()` 后
哈希字符串(注意这意味着 STRUCT/LIST 的哈希与 Iceberg 规范不兼容,仅 DuckLake 自洽)。

真实用途(核实,共三个消费点,均为 bucket 分区 transform):

1. **写路径分区键计算**(07 篇已确认):`ApplyBucketTransform`
   (`src/storage/ducklake_partition_data.cpp:103-120`)把分区列表达式绑定为
   `(murmur3_32(col) & 2147483647) % bucket_count` 的物理表达式树,INSERT 时按其结果做
   hive 风格目录分桶。
2. **分区裁剪的常量折叠**:`FoldBucketValue`
   (`src/storage/ducklake_metadata_manager.cpp:1492-1515`)把查询里的等值/IN 常量喂进同一
   bucket 表达式 `TryEvaluateScalar`,得到 partition_value 字符串后用于元数据侧文件裁剪——即
   murmur3_32 也被**读路径**用到(失败则回退 zone map)。
3. **flush_inlined_data 的分区过滤 SQL**:`GetPartitionSQLExpression`
   (`ducklake_partition_data.cpp:43-54`)生成文本形式
   `"(murmur3_32(col) & 2147483647) % N"`,由 `BuildPartitionFilter` 拼进 flush 用的查询
   (`ducklake_flush_inlined_data.cpp:121-134`,详解归 08)。

`ducklake_add_data_files` **不**计算 murmur3:bucket 分区的 hive 目录值直接取自路径,且因
"目录名是哈希结果"而放弃为该列生成统计(`ducklake_add_data_files.cpp:1062-1066`)。

## 七、维护类函数签名速查(详解归 08/09)

仅录注册形态,语义见对应篇:

- `ducklake_merge_adjacent_files`:TableFunctionSet,两个 overload——`(catalog)` 全库、
  `(catalog, table)` 单表(后者另有 named `schema`);named `min_file_size`/`max_file_size`/
  `max_compacted_files`(UBIGINT)。`bind_operator` 直接产出 compaction 计划
  (`ducklake_compaction_functions.cpp:858-873`)。全库形态受表级 `auto_compact` 选项 gate
  (`:797-814`)。→ 09
- `ducklake_rewrite_data_files`:同构 overload,named `delete_threshold DOUBLE`
  (`:884-897`)。→ 09
- `ducklake_expire_snapshots`:`(catalog)` + named `older_than TIMESTAMPTZ` /
  `versions LIST(UBIGINT)`(互斥)/ `dry_run BOOLEAN`;两者皆缺时回退 `expire_older_than`
  配置,仍无则静默 no-op;返回被过期快照(schema 复用 3.1)
  (`ducklake_expire_snapshots.cpp:20-61, 133-138`)。→ 09
- `ducklake_cleanup_old_files` / `ducklake_delete_orphaned_files`:`(catalog)` + named
  `older_than`/`cleanup_all`(互斥,皆缺回退 `delete_older_than` 配置)/`dry_run`;返回
  `path` 一列(`ducklake_cleanup_files.cpp:163-177`)。→ 09
- `ducklake_flush_inlined_data`:`(catalog)` + named `schema_name`/`table_name`,
  `bind_operator` 产出 flush 计划,返回 `(schema_name, table_name, rows_flushed)`
  (`ducklake_flush_inlined_data.cpp:659-661, 761-766`)。→ 08
- `ducklake_add_data_files`:`(catalog, table, files)`,files 为 VARCHAR(glob)或
  LIST(VARCHAR) 两个 overload;named `allow_missing`/`ignore_extra_columns`/
  `hive_partitioning`/`schema`;返回 `filename`(`ducklake_add_data_files.cpp:1273-1286`)。→ 09
