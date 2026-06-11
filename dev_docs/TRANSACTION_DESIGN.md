# DuckLake 事务与快照模型(TRANSACTION_DESIGN)

> 行号基准:commit `47187559`(分支 local_dev)。引用格式 `src/storage/xxx.cpp:123`。

## 概述

DuckLake 是 DuckDB 的 lakehouse 扩展:表数据存放在对象存储/文件系统上的 parquet 文件中,
元数据(catalog、文件清单、统计)存放在一个普通 SQL 数据库(DuckDB/PostgreSQL/SQLite/MySQL,
统称 metadata catalog)里。它的事务模型与 DuckDB 自身的 MVCC 完全不同:**没有版本链
(version chain)、没有 undo buffer、没有 row-level 锁**。一个 DuckLake 事务由三样东西组成:

1. **一个不可变的快照(`DuckLakeSnapshot`)**——事务开始后第一次需要时从 metadata catalog
   惰性读出的四元组 `{snapshot_id, schema_version, next_catalog_id, next_file_id}`,事务内
   所有读取都基于这个快照解析 schema 与文件清单,天然得到 snapshot isolation;
2. **一份纯事务本地(transaction-local)的变更状态(`DuckLakeTransactionState`)**——新建/
   删除/重命名的 catalog entry、新写出的 data file/delete file、inlined data 等,全部只挂在
   事务对象上,对其他事务不可见;
3. **乐观提交**——commit 时把本地状态翻译成针对 metadata catalog 的一批 SQL,在 metadata
   数据库自身的事务里原子写入;若与并发提交冲突则回滚重试(提交协议归
   [COMMIT_PROTOCOL_DESIGN.md](COMMIT_PROTOCOL_DESIGN.md),本篇不展开)。

因此 DuckLake 的"事务可见性"问题被拆成两半:对**已提交数据**的可见性由 snapshot_id 决定
(metadata 查询全部带 `begin_snapshot <= S < end_snapshot` 一类谓词);对**本事务未提交数据**
的可见性由事务对象上的本地集合决定——catalog 查找先查 transaction-local 集合,scan 在文件
清单末尾追加 transaction-local 文件。两套机制在 ID 空间上用高位标记区分:本地分配的
catalog id 从 `2^63` 起,本地 row id 从 `10^18` 起。

```
            DuckLakeTransactionManager (per attached DuckLake catalog)
                 | StartTransaction / CommitTransaction / RollbackTransaction
                 v
  +---------------------------------------------------------------+
  | DuckLakeTransaction                                           |
  |   snapshot_lock ─ snapshot: unique_ptr<DuckLakeSnapshot>      |  lazy: 首次 GetSnapshot()
  |   snapshot_cache: value_map_t<DuckLakeSnapshot>               |  AT (VERSION/TIMESTAMP) 缓存
  |   connection_lock ─ connection: unique_ptr<Connection>        |  指向 metadata catalog
  |   local_catalog_id (从 2^63 自增)                              |  事务本地 id 分配器
  |   state: unique_ptr<DuckLakeTransactionState>                 |
  |     ├─ new_schemas / new_tables / new_*_macros (CatalogSet)   |  DDL: 新建 entry
  |     ├─ dropped_* / renamed_* (set<index>)                     |  DDL: 删除/重命名
  |     ├─ dropped_files / tables_deleted_from                    |  文件级删除
  |     ├─ local_changes: LocalTableChanges                       |  DML: per-table 数据变更
  |     │    └─ map<TableIndex, LocalTableDataChanges>            |
  |     │         {new_data_files, new_inlined_data,              |
  |     │          new_delete_files, new_inlined_data_deletes,    |
  |     │          new_inlined_file_deletes, compactions}         |
  |     └─ flushed_inlined_tables                                 |
  +---------------------------------------------------------------+
       |  读路径: snapshot + local state            | Commit(): 翻译成 SQL 批
       v                                            v
   parquet files (data path)                metadata catalog (__ducklake_metadata_*)
```

关键源码位置:

| 主题 | 位置 |
|---|---|
| TransactionManager 薄封装 | `src/storage/ducklake_transaction_manager.cpp:11`(整文件 45 行) |
| CHECKPOINT 实现 | `src/storage/ducklake_checkpoint.cpp:12` |
| DuckLakeSnapshot 结构 | `src/include/common/ducklake_snapshot.hpp:18` |
| DuckLakeTransaction 类 | `src/include/storage/ducklake_transaction.hpp:167` |
| 事务本地状态 DuckLakeTransactionState | `src/include/storage/ducklake_transaction_state.hpp:111` |
| LocalTableChanges / LocalTableDataChanges | `src/include/storage/ducklake_transaction.hpp:51`、`:66` |
| 惰性快照获取 GetSnapshot | `src/storage/ducklake_transaction.cpp:1536` |
| AT 时间旅行 + snapshot_cache | `src/storage/ducklake_transaction.cpp:1550` |
| 每事务 metadata Connection | `src/storage/ducklake_transaction.cpp:759` |
| transaction-local id 常量 | `src/include/common/index.hpp:17` |
| Rollback 与文件清理 | `src/storage/ducklake_transaction.cpp:748`、`:66` |

## 关联文档

- [ATTACH_CATALOG_DESIGN.md](ATTACH_CATALOG_DESIGN.md):ATTACH 流程、DuckLakeCatalog、per-snapshot schema 缓存(`GetSchemaForSnapshot`)、配置作用域。
- [COMMIT_PROTOCOL_DESIGN.md](COMMIT_PROTOCOL_DESIGN.md):`Commit()`/`FlushChanges()`/`RunCommitLoop` 重试循环、冲突检测、server-side commit 与 staged commit。
- [METADATA_SCHEMA_DESIGN.md](METADATA_SCHEMA_DESIGN.md):`ducklake_snapshot` 等元数据表的数据字典(本篇只讲 C++ 侧结构)。
- [METADATA_MANAGER_DESIGN.md](METADATA_MANAGER_DESIGN.md):`DuckLakeMetadataManager` 接口与 SQL 模板。
- [SCAN_DESIGN.md](SCAN_DESIGN.md):事务本地文件/inlined data 如何叠加进 multi-file scan。
- [DML_DESIGN.md](DML_DESIGN.md) / [DATA_INLINING_DESIGN.md](DATA_INLINING_DESIGN.md):变更的生产端。
- [MAINTENANCE_DESIGN.md](MAINTENANCE_DESIGN.md):CHECKPOINT 串起来的各维护函数。

## 一、DuckLakeTransactionManager 与事务生命周期

### 1.1 三个入口都是薄封装

`DuckLakeTransactionManager`(`src/include/storage/ducklake_transaction_manager.hpp:17`)持有
`ducklake_catalog` 引用和一张 `reference_map_t<Transaction, shared_ptr<DuckLakeTransaction>>
transactions` 注册表,仅此而已——没有全局事务 id 分配、没有 active transaction 序列化点
(对照 DuckDB 自身 `DuckTransactionManager` 的 start/commit 锁)。三个 override 都是一两行
转发:

- `StartTransaction`(`src/storage/ducklake_transaction_manager.cpp:11`):构造
  `DuckLakeTransaction` 并调用 `transaction->Start()`,注册进 `transactions`。
  `DuckLakeTransaction::Start()` 是**空函数**(`src/storage/ducklake_transaction.cpp:734`)——
  事务开始时不接触 metadata catalog,快照延迟到首次 `GetSnapshot()`(见 2.3)。
- `CommitTransaction`(`:26`):调 `ducklake_transaction.Commit()`,异常转成 `ErrorData`
  返回,最后从注册表移除。提交内部流程归 03。
- `RollbackTransaction`(`:38`):调 `ducklake_transaction.Rollback()` 后移除(见七)。

`DuckLakeTransaction` 构造函数(`src/storage/ducklake_transaction.cpp:700`)做四件事:创建
本事务私有的 `DuckLakeMetadataManager`(`metadata_manager = DuckLakeMetadataManager::Create(*this)`,
接口归 05)、把 `local_catalog_id` 初始化为 `TRANSACTION_LOCAL_ID_START`、`catalog_version`
置 0、并创建 `DuckLakeTransactionState`(见四)。

### 1.2 immediate transaction mode 与 `get_snapshot` 再入保护

`StartTransaction` 中有一段特殊逻辑(`src/storage/ducklake_transaction_manager.cpp:14`):若
`immediate_transaction_mode` 开启且成员 `bool get_snapshot = true`
(`src/include/storage/ducklake_transaction_manager.hpp:31`),则立刻调 `transaction->GetSnapshot()`
把快照取出来,而不是惰性等待。取快照前先把 `get_snapshot` 置 false、取完恢复 true:
`GetSnapshot()` 会对 metadata catalog 发查询,在 immediate transaction mode 下该查询又会对
所有 attached database(包括本 DuckLake catalog 自己)启动事务,从而再次进入
`StartTransaction`——这个 flag 阻断了无限递归,内层事务退回惰性快照路径。

### 1.3 CHECKPOINT(一句话,详见 09)

`Checkpoint`(`src/storage/ducklake_checkpoint.cpp:12`)不走事务状态机,而是开一个新
`Connection` 顺序执行六个维护函数:`ducklake_flush_inlined_data` → `ducklake_expire_snapshots`
→ `ducklake_merge_adjacent_files` → `ducklake_rewrite_data_files` → `ducklake_cleanup_old_files`
→ `ducklake_delete_orphaned_files`,详见 [MAINTENANCE_DESIGN.md](MAINTENANCE_DESIGN.md)。

## 二、快照模型

### 2.1 DuckLakeSnapshot 结构

`src/include/common/ducklake_snapshot.hpp:18`:

```cpp
struct DuckLakeSnapshot {
	idx_t snapshot_id;      // 快照编号,全局单调递增;读取时作为可见性谓词的 S
	idx_t schema_version;   // schema 版本号,仅当快照包含 DDL 时递增;
	                        //   是 DuckLakeCatalog per-snapshot schema 缓存的 key(见 01)
	idx_t next_catalog_id;  // 该快照之后下一个可用的 catalog id(schema/table/view/
	                        //   partition/sort key 等共用一个计数器);提交时从这里取号
	idx_t next_file_id;     // 下一个可用的 data file / delete file id,同上
	void Serialize(Serializer &) const;            // server-side commit 跨进程传递用
	static DuckLakeSnapshot Deserialize(Deserializer &);
};
```

默认构造全部为 `DConstants::INVALID_INDEX`(`:24`)。四个字段一一对应元数据表
`ducklake_snapshot` 的四列,最新快照查询就是一条 max 查询
(`src/storage/ducklake_metadata_manager.cpp:4175`):

```sql
SELECT snapshot_id, schema_version, next_catalog_id, next_file_id
FROM {METADATA_CATALOG}.ducklake_snapshot
WHERE snapshot_id = (SELECT MAX(snapshot_id) FROM {METADATA_CATALOG}.ducklake_snapshot);
```

`ParseSnapshot`(`:4160`)校验恰好一行,多行即 "Corrupt DuckLake"。

**`snapshot_id` 与 `schema_version` 的递增关系**:每次成功提交产生一个新快照,
`snapshot_id` 恒 +1;`schema_version` 仅当 `SchemaChangesMade()`
(`src/storage/ducklake_transaction_state.cpp:68`,判断 new_tables/dropped_tables/new_schemas/
dropped_schemas/dropped_views/renamed_views/各类 macro 是否非空)为真时 +1,见提交循环中的
`commit_snapshot.snapshot_id++` / `commit_snapshot.schema_version++`
(`src/storage/ducklake_transaction_state.cpp:1711-1715`,循环本身归 03)。因此
`schema_version` 是 `snapshot_id` 的"低频投影":纯 DML 快照共享同一 schema_version,
catalog 层可以按 schema_version 缓存整棵 schema 树(01 篇)。

### 2.2 快照即隔离:与 DuckDB MVCC 的对照

DuckDB 自身一个事务的可见性由 `start_time/transaction_id` 对 version chain 逐行判定;
DuckLake 则把可见性下推成 metadata SQL:文件清单查询带
`begin_snapshot <= S AND (end_snapshot IS NULL OR S < end_snapshot)` 谓词(模板在 05),
S 就是本事务的 `snapshot_id`。快照一旦取得,事务内不再前进(可重复读);写写冲突推迟到
commit 时检测(乐观并发,03)。**同一事务读自己的写**不靠快照,靠事务本地状态(见六)。

### 2.3 惰性获取与 snapshot_lock

`GetSnapshot()`(`src/storage/ducklake_transaction.cpp:1536`):

```cpp
DuckLakeSnapshot DuckLakeTransaction::GetSnapshot() {
	auto catalog_snapshot = ducklake_catalog.CatalogSnapshot();
	if (catalog_snapshot) {       // ATTACH ... (SNAPSHOT_VERSION/SNAPSHOT_TIME ...)
		return GetSnapshot(catalog_snapshot);
	}
	lock_guard<mutex> guard(snapshot_lock);
	if (!snapshot) {
		snapshot = metadata_manager->GetSnapshot();   // SELECT max(snapshot_id) ...
	}
	return *snapshot;
}
```

要点:

- 成员 `unique_ptr<DuckLakeSnapshot> snapshot` + `mutex snapshot_lock`
  (`src/include/storage/ducklake_transaction.hpp:346-347`)。加锁是因为同一事务的并行
  scan/operator 可能并发触发首次加载。
- 只读事务若从未触碰 DuckLake 表,则整个事务零 metadata 交互(`Start()` 为空 +
  惰性快照 + `Commit()` 里 `ChangesMade()` 为 false)。
- 若 catalog 以固定快照 ATTACH(`ducklake_catalog.CatalogSnapshot()` 返回 ATTACH 时存下的
  `BoundAtClause`,`src/storage/ducklake_catalog.cpp:915`),每次都改走 AT 路径,事务级
  `snapshot` 成员保持为空。
- commit 重试时会 `snapshot.reset()` 强制重新加载(`prepare_retry` 回调,
  `src/storage/ducklake_transaction.cpp:1376-1380`,协议归 03)。

### 2.4 AT (VERSION => / TIMESTAMP =>) 时间旅行与 snapshot_cache

带 AT 子句的重载(`src/storage/ducklake_transaction.cpp:1550`):

1. `at_clause` 为空 → 退回 `GetSnapshot()`;
2. 否则把 AT 条件构造成 STRUCT value `{"unit": value}`(如 `{'version': 2}`、
   `{'timestamp': '2025-...'}`)作为缓存 key;
3. 在 `value_map_t<DuckLakeSnapshot> snapshot_cache`
   (`src/include/storage/ducklake_transaction.hpp:355`)中查找,命中直接返回——同一事务内
   同一 AT 条件解析到同一快照(尤其 TIMESTAMP:避免一条查询内两次解析撞上并发提交得到
   不同版本);
4. 未命中则 `metadata_manager->GetSnapshot(*at_clause, bound)` 查询并填入缓存。查找也在
   `snapshot_lock` 下进行(`:1561`)。

底层查询(`src/storage/ducklake_metadata_manager.cpp:4195`):`version` 直接按
`snapshot_id = N` 取;`timestamp` 按 `snapshot_time` 取边界快照。`SnapshotBound`
(`src/include/storage/ducklake_metadata_manager.hpp:45`,`LOWER_BOUND/UPPER_BOUND`)控制
取 `>=`(ASC 第一条)还是 `<=`(DESC 第一条),默认 UPPER_BOUND;LOWER_BOUND 由
`ducklake_table_changes` 等增量函数使用(10 篇)。单位非 version/timestamp 抛
`InvalidInputException`。

注意 `LookupSchema`(`src/storage/ducklake_catalog.cpp:825`)中的规则:**带 AT 子句的查找
永远跳过 transaction-local 集合**,也不做 `IsDeleted` 过滤——时间旅行读到的是已提交历史,
与本事务未提交变更无交集。

## 三、与元数据库的连接

### 3.1 每事务独立 Connection

`GetConnection()`(`src/storage/ducklake_transaction.cpp:759`)在 `connection_lock` 下惰性
创建一个指向**本进程内** DuckDB 实例的 `Connection`,通过它访问 ATTACH 进来的 metadata
catalog(`__ducklake_metadata_<name>`,ATTACH 流程见 01)。每个 DuckLake 事务一条独立
metadata 连接意味着:DuckLake 事务的原子性直接寄生在 metadata 数据库的事务上——
`connection->BeginTransaction()` 在创建时立即调用(`:782`),提交/回滚见
`Commit()/Rollback()`(七)。

### 3.2 连接上的会话设置及原因

创建连接时依次设置(`:763-783`):

| 设置 | 值 | 原因 |
|---|---|---|
| `catalog_search_path` | `{MetadataDatabaseName, MetadataSchemaName}`(schema 为空则 `main`),`SET_DIRECTLY` | 元数据 SQL 里的裸表名(`ducklake_snapshot` 等)只解析到 metadata catalog,不会撞用户 catalog |
| `catalog_error_max_schemas` | 0 | 报错时不遍历其他 schema/catalog 生成 "Did you mean" 候选——避免错误路径上反向触碰 DuckLake catalog 自身 |
| `pg_experimental_filter_pushdown` | false(仅 metadata type 为 `postgres`/`postgres_scanner` 时) | 源码 FIXME 注明:postgres_scanner 的实验性 filter pushdown 不支持 DuckDB 可能下推的所有 filter 类型(如 `EXPRESSION_FILTER`),对元数据查询禁用 |
| `current_transaction_invalidation_policy` | `'SYNTACTIC_ERRORS_DO_NOT_INVALIDATE'` | 元数据连接上个别语句语法报错不应作废整个 metadata 事务(commit 重试还要复用该连接) |

### 3.3 Query / ExecuteRaw

`DuckLakeTransaction::Query(...)`(`:1521`、`:1525`)委托 `metadata_manager`(占位符替换如
`{METADATA_CATALOG}`、`{SNAPSHOT_ID}`,归 05);`ExecuteRaw`(`:1505`)绕过 metadata-manager
直接在连接上执行,并计时打 `DuckLakeMetadataLogType` 日志、回调
`ducklake_catalog.GetQueryCallback()`。

## 四、事务本地状态:DuckLakeTransactionState

### 4.1 所有权与字段总表

`DuckLakeTransactionState`(`src/include/storage/ducklake_transaction_state.hpp:111`)由
`DuckLakeTransaction` 通过 `unique_ptr` 持有(`src/include/storage/ducklake_transaction.hpp:353`),
集中存放"本事务做过什么"的全部可变状态,同时承载 Commit 循环的实现(后者归 03;
同文件 `DuckLakeCommitContext`(`:26`)是 transaction → state 的回调集,亦归 03)。
公开字段(`src/include/storage/ducklake_transaction_state.hpp:182-206`)逐一注释:

```cpp
DatabaseInstance &db;                  // 用于 Rollback 时拿 FileSystem 删文件
bool require_commit_message;           // catalog 选项 require_commit_message(ATTACH 时快照)
DuckLakeNameMapSet &new_name_maps;     // 反向引用 transaction 上的事务本地 name map 集合
                                       //   (ducklake_add_data_files 的列名映射,10 篇)
string data_path;                      // catalog 数据根路径(算相对路径用)
string separator;                      // 路径分隔符(写入元数据前统一成 '/')
DuckLakeSnapshotCommit commit_info;    // set_commit_message 设置的 author/message/extra_info

// ---- DDL:新建 entry(均为 DuckLakeCatalogSet,schema 名 → entry 集合) ----
case_insensitive_map_t<unique_ptr<DuckLakeCatalogSet>> new_tables;        // 新表 + 新视图 +
                                       //   被 ALTER 的表的新版本(同名 entry 用 Child() 链)
set<TableIndex> dropped_tables;        // 本事务 DROP 的已提交表 id
case_insensitive_map_t<unique_ptr<DuckLakeCatalogSet>> new_scalar_macros; // CREATE MACRO
case_insensitive_map_t<unique_ptr<DuckLakeCatalogSet>> new_table_macros;  // CREATE MACRO ... TABLE
set<MacroIndex> dropped_scalar_macros; // DROP MACRO
set<MacroIndex> dropped_table_macros;
set<TableIndex> renamed_tables;        // 被 RENAME 的已提交表的原 id(旧名查找需屏蔽)
set<TableIndex> renamed_views;
set<TableIndex> dropped_views;
unique_ptr<DuckLakeCatalogSet> new_schemas;                   // CREATE SCHEMA(惰性创建)
map<SchemaIndex, reference<DuckLakeSchemaEntry>> dropped_schemas;  // DROP SCHEMA

// ---- 文件级删除(整文件淘汰,非行级 delete file) ----
unordered_map<string, DataFileIndex> dropped_files;  // path → file id;来源:
                                       //   DELETE 命中整文件、compaction 淘汰源文件
set<TableIndex> tables_deleted_from;   // 发生过(整文件或行级)删除的表,冲突检测口径

// ---- DML 数据变更 ----
LocalTableChanges local_changes;       // per-table 数据变更主容器,见 4.2
vector<FlushedInlinedTableInfo> flushed_inlined_tables;  // ducklake_flush_inlined_data 标记的
                                       //   {inlined_table, flush_snapshot_id},提交后清理用
```

`new_tables` 等集合中,被 ALTER 的已提交表也会以"新 entry"形式进入(见 6.2),提交时按
entry 上的 `LocalChangeType` 区分 CREATE 与各类 ALTER
(`GetTransactionTableChanges`,`src/storage/ducklake_transaction.cpp:806`)。

### 4.2 LocalTableChanges:per-table 数据变更容器

`LocalTableChanges`(`src/include/storage/ducklake_transaction.hpp:66`)= 一把 `mutex lock` +
`map<TableIndex, LocalTableDataChanges> changes`(`:106-107`)。所有方法先加锁再操作,
因为并行 INSERT/DELETE 的多个 sink 会并发登记;遍历用 RAII helper
`LocalTableChangeIterationHelper`(`:110`)在整个迭代期间持锁。

`LocalTableDataChanges`(`:51`)逐字段:

```cpp
struct LocalTableDataChanges {
	vector<DuckLakeDataFile> new_data_files;
	//   本事务写出的 parquet 数据文件。两种来源:普通 INSERT/CTAS(begin_snapshot 不设),
	//   以及 flush 已提交 inlined data 产出的文件(begin_snapshot 设为原 inlined 行的快照)。
	unique_ptr<DuckLakeInlinedData> new_inlined_data;
	//   本事务新写的 inlined 行(ColumnDataCollection + per-column stats + 可选保留 row_ids),
	//   见 08;追加时若 ALTER 改了列类型会现场 cast 合并(ducklake_transaction.cpp:197)。
	unordered_map<string, vector<DuckLakeDeleteFile>> new_delete_files;
	//   data file path → 针对它的 delete file 列表。REGULAR 来源同一 data file 只保留最新
	//   一个(新 delete file 覆盖全量删除位图,旧的当场从磁盘删掉);FLUSH 来源允许并存
	//   (AddDeletesToMap,ducklake_transaction.cpp:613)。
	unordered_map<string, unique_ptr<DuckLakeInlinedDataDeletes>> new_inlined_data_deletes;
	//   inlined-data 表名 → 删除的 row id 集合(set<idx_t>):对已提交 inlined 行的删除。
	unique_ptr<DuckLakeInlinedFileDeletes> new_inlined_file_deletes;
	//   file_id → set<row_id>:对已提交 parquet 文件的"行删除以 inlined 形式记在元数据库"
	//   (写进 ducklake_inlined_delete_<id> 表,不写 delete file),见 08。
	vector<DuckLakeCompactionEntry> compactions;
	//   compaction 结果:{source_files, written_file, row_id_start, type(MERGE_ADJACENT/
	//   REWRITE_DELETES)}(src/include/storage/ducklake_metadata_info.hpp:472),见 09。
	bool IsEmpty() const;   // 六项全空
};
```

其中数据载体:`DuckLakeDataFile`(`src/include/common/ducklake_data_file.hpp:59`)带
`file_name/row_count/file_size_bytes/footer_size/partition_id/delete_files/column_stats/
partition_values/encryption_key/mapping_id/begin_snapshot/max_partial_file_snapshot/
flush_row_id_start/created_by_ducklake`;**`delete_files` 嵌在 data file 里**表示"对本事务
自己刚写的文件的删除"(先 INSERT 后 DELETE 同一事务),与 map 形式的
`new_delete_files`(针对已提交文件)分开存。`created_by_ducklake = false` 的文件
(`ducklake_add_data_files` 登记的既有外部文件)回滚时不删(见七)。
`DuckLakeDeleteFile`(`:41`)带 `data_file_id/data_file_path/file_name/format(PARQUET|PUFFIN)/
delete_count/.../overwrites_existing_delete + overwritten_delete_file/begin_snapshot/
max_snapshot/source(REGULAR|FLUSH)`。

`ChangesMade()`(`src/storage/ducklake_transaction.cpp:801`)= `SchemaChangesMade() ||
local_changes.HasChanges() || !dropped_files.empty() || !new_name_maps.name_maps.empty()`,
是 `Commit()` 决定走提交协议还是直接放行的总开关。提交前 `GetTransactionChanges()`
(`:889`)把上述全部集合折叠成 `TransactionChangeInformation`
(`src/include/storage/ducklake_transaction_changes.hpp:22`,created/dropped/altered/
inserted/deleted/compacted 等 18 个集合)交给冲突检测——其消费归 03。

## 五、变更登记调用点速查

DML/DDL 执行路径把变更塞进 state 的入口(`DuckLakeTransaction` 的转发方法本体在
`src/storage/ducklake_transaction.cpp:1599-1705`):

| 变更 | transaction API | 调用点 |
|---|---|---|
| INSERT/CTAS 写出 parquet | `AppendFiles` | `src/storage/ducklake_insert.cpp:248`(Sink Finalize) |
| ducklake_add_data_files 登记外部文件 | `AppendFiles` | `src/functions/ducklake_add_data_files.cpp:1269` |
| flush inlined data 产出文件 | `AppendFiles` + `MarkInlinedDataForDeletion` | `src/functions/ducklake_flush_inlined_data.cpp:196`、`:198` |
| flush 时迁移既有 inlined 删除 | `AddDeletes` | `src/functions/ducklake_flush_inlined_data.cpp:573` |
| INSERT 小数据走 inlining | `AppendInlinedData` | `src/storage/ducklake_inline_data.cpp:406` |
| DELETE 写 delete file(已提交文件) | `AddDeletes` | `src/storage/ducklake_delete.cpp:606` |
| DELETE 命中本事务自写文件 | `TransactionLocalDelete` | `src/storage/ducklake_delete.cpp:603` |
| DELETE 整文件全删 | `DropFile` | `src/storage/ducklake_delete.cpp:363` |
| DELETE 本事务 inlined 行 | `DeleteFromLocalInlinedData` | `src/storage/ducklake_delete.cpp:494` |
| DELETE 已提交 inlined 行 | `AddNewInlinedDeletes` | `src/storage/ducklake_delete.cpp:499` |
| DELETE 走 inlined file deletes | `AddNewInlinedFileDeletes` | `src/storage/ducklake_delete.cpp:520` |
| compaction 完成 | `AddCompaction` | `src/functions/ducklake_compaction_functions.cpp:181` |
| CREATE SCHEMA | `CreateEntry` | `src/storage/ducklake_catalog.cpp:280` |
| CREATE TABLE / MACRO / VIEW | `CreateEntry` | `src/storage/ducklake_schema_entry.cpp:88`、`:136`、`:163` |
| ALTER TABLE/VIEW(含 RENAME) | `AlterEntry` | `src/storage/ducklake_schema_entry.cpp:216`、`:236`、`:249`、`:259`、`:275` |
| DROP TABLE/VIEW/MACRO | `DropEntry` | `src/storage/ducklake_schema_entry.cpp:340`、`:539-548` |
| DROP SCHEMA | `DropEntry`(→`DropSchema`) | `src/storage/ducklake_catalog.cpp:292` |

UPDATE 与 MERGE 没有独立登记入口:物理计划分解为 delete + insert(07 篇),复用上表。

## 六、事务内可见性

### 6.1 catalog 查找:transaction-local 集合优先

DuckLake 没有 DuckDB 内核那种带版本的 `CatalogSet`;已提交 schema 树是按 snapshot 缓存的
**不可变只读结构**(01 篇),事务内可见性靠"先查本地、再查共享并过滤"实现:

- entry 查找:`DuckLakeSchemaEntry::LookupEntry`(`src/storage/ducklake_schema_entry.cpp:343`)
  先 `duck_transaction.GetTransactionLocalEntry(...)`(命中本事务新建/新改的 entry),
  miss 后查共享 catalog set,再用 `IsDeleted`/`IsRenamed` 把本事务删除或改名的旧 entry
  挡掉(`:367`)。
- schema 查找:`DuckLakeCatalog::LookupSchema`(`src/storage/ducklake_catalog.cpp:825`)
  同构;带 AT 子句时跳过本地集合(见 2.4)。
- 枚举:`ScanSchemas`(`:295`)、`GetSimilarEntry`(`src/storage/ducklake_schema_entry.cpp:373`)
  都是"本地集合 + 共享集合(过滤 IsDeleted/IsRenamed)"的并集。
- 按 id 查找:`DuckLakeCatalog::GetEntryById`(`:317`、`:327`)先
  `transaction.GetLocalEntryById(...)`(`src/storage/ducklake_transaction.cpp:2050`,
  线性扫 `new_schemas`/`new_tables`)。

`IsDeleted`/`IsRenamed`(`src/storage/ducklake_transaction.cpp:1841`、`:1869`)就是查
state 里的 `dropped_*`/`renamed_*` set。同一 entry 在一个事务内被多次 ALTER 时,新版本通过
`CatalogEntry::SetChild()` 挂成链,旧版本留在链尾(`HandleRenameOldEntry`,`:1907`);提交时
`GetTransactionTableChanges`(`:806`)沿 `Child()` 链逐个收集变更。

### 6.2 本地数据如何被本事务的 scan 看到(数据结构侧)

scan 构建文件清单时(机制细节归 06):`DuckLakeMultiFileList::GetFilesForTable`
(`src/storage/ducklake_multi_file_list.cpp:318`)先从 metadata 按快照取已提交文件,然后:

1. 用 `transaction.FileIsDropped(path)` 把本事务 `dropped_files` 中的文件从清单剔除;
2. 用 `GetLocalDeleteForFile` 把本事务对已提交文件的最新 delete file 挂到对应 entry;
3. 用 `GetLocalInlinedFileDeletesForFile` 合并 inlined 形式的行删除;
4. 把 `GetTransactionLocalFiles(table_id)` 返回的本地文件追加到清单尾部,`row_id_start` 从
   `TRANSACTION_LOCAL_ROW_ID_START`(`10^18`)起按文件行数累加(`:349-358`;扩展清单同构
   逻辑在 `:281`);
5. 本地 inlined data 以一个特殊文件名 `DUCKLAKE_TRANSACTION_LOCAL_INLINED_FILENAME` 的
   dummy entry 出现(`:370`;扩展清单版在 `:307`)。

因此本事务内 row id 空间分三段:已提交文件用元数据里的 `row_id_start`;本地文件从 `10^18`
排;判别函数 `DuckLakeConstants::IsTransactionLocalRowId`
(`src/include/common/index.hpp:21`)。DELETE 执行时据此把行删除分流到
`TransactionLocalDelete` 还是 `AddDeletes`(见五;07 篇)。

### 6.3 transaction-local catalog id 的判别与分配

- 常量:`TRANSACTION_LOCAL_ID_START = 9223372036854775808ULL`(`src/include/common/index.hpp:18`)
  即 `2^63`——**判别方式是无符号比较 `id >= 2^63`,等价于把 idx_t 最高位当 local 标记**
  (`DuckLakeTransaction::IsTransactionLocal`,
  `src/include/storage/ducklake_transaction.hpp:260`;`SchemaIndex::IsTransactionLocal` 等
  在 `src/include/common/index.hpp:46`、`:52`、`:77`)。已提交 id 由 `next_catalog_id`
  从 0 侧增长,两个空间不可能相遇。
- 分配:`GetLocalCatalogId()`(`src/storage/ducklake_transaction.cpp:1573`)对
  `local_catalog_id` 简单自增(无锁;构造时初始化为 `2^63`,`:703`)。使用方:新 schema id
  (`src/storage/ducklake_catalog.cpp:274`)、新 table/view id
  (`src/storage/ducklake_schema_entry.cpp:79`、`:152`)、未提交的 partition id / sort id
  (`src/storage/ducklake_table_entry.cpp:625`、`:1323`)、事务本地 name map id
  (`src/storage/ducklake_transaction.cpp:2079`)。
- 换号:提交时凡 `IsTransactionLocal(id)` 的 entry 都从 `commit_snapshot.next_catalog_id++`
  取正式 id 并维护 local→committed 映射(`GetNewTable`,
  `src/storage/ducklake_transaction.cpp:1117`;映射机制归 03);带本地 table-id 写
  partition/sort 直接抛 `InternalException`(`:1012`、`:1060`)。
- 注意与 6.2 的 row id 是**两个独立空间**:catalog id 用 `2^63`,row id 用 `10^18`
  (row id 是 `int64_t`,须保持为正且留出已提交 row id 的增长空间)。

## 七、回滚与清理

### 7.1 Rollback 路径

`Rollback()`(`src/storage/ducklake_transaction.cpp:748`):

```cpp
if (connection) {
	connection->Rollback();    // 回滚 metadata 事务(本事务对元数据库的一切写入)
	connection.reset();
}
state->CleanupFiles();         // 删除已写出的孤儿数据文件(见 7.2)
state->local_changes.Clear();
SetRequiresNewInlinedTable(false);
```

DDL 本地集合(`new_tables` 等)不需要显式撤销——它们只存在于事务对象里,事务销毁即消失。
对照 `Commit()`(`:737`):无变更但开过 metadata 连接(纯读也会查快照)时只
`connection->Commit()` 收尾。

### 7.2 孤儿 parquet 文件何时删

事务写 parquet 是"先写文件、后登记元数据",失败路径必须删掉已落盘文件。三个触发点,
全部收敛到 `LocalTableChanges` 的两个 `CleanupFiles` 重载:

1. **显式/隐式 ROLLBACK**:`Rollback()` → `DuckLakeTransactionState::CleanupFiles()`
   (`src/storage/ducklake_transaction_state.cpp:63`)→
   `LocalTableChanges::CleanupFiles(db)`(`src/storage/ducklake_transaction.cpp:66`):遍历
   所有表的 `new_data_files`(`created_by_ducklake` 为 false 的外部文件跳过,只删
   DuckLake 自己写的)及其内嵌 delete files、所有 `new_delete_files`,逐个
   `fs.TryRemoveFile`(容忍已不存在)。inlined data / compaction 记录无落盘文件,清 map 即可。
2. **提交最终失败**:重试次数耗尽或不可重试错误时,提交循环同样调 `CleanupFiles()` 再抛错
   (`src/storage/ducklake_transaction_state.cpp:1746`,循环归 03)。
3. **事务内 DROP 刚建的表**:`DropTable` 对 transaction-local 表调
   `local_changes.CleanupFiles(context, table_id)`(`src/storage/ducklake_transaction.cpp:1737`
   → `:592`)只清这一张表的文件。同理,事务内对自写文件的"覆盖式"删除会当场删旧
   delete file(`TransactionLocalDelete`,`:575-583`;`DropTransactionLocalFile`,`:139`)。

已提交后的孤儿(提交成功但后被 expire 的快照引用的文件、崩溃残留)不归事务管,由
`ducklake_cleanup_old_files`/`ducklake_delete_orphaned_files` 维护函数处理(09 篇)。
注意崩溃(进程被 kill)时来不及执行 1/2,会留下真正的孤儿文件——这正是
`ducklake_delete_orphaned_files` 存在的原因。

## 八、ID 与命名

### 8.1 next_catalog_id / next_file_id

两者都是**存放在快照里的全局计数器**而非自增列:提交时从事务快照(重试时是冲突解析后的
最新快照)拷出 `commit_snapshot`,需要多少号就 `next_catalog_id++`/`next_file_id++` 多少次
(例:`GetNewTable` `src/storage/ducklake_transaction.cpp:1118`、`BuildDataFileInfo`
`:1231`、`GetNewDeleteFile` `:1257`、partition id `:1022`、sort id `:1071`),最终把递增后
的值随新快照行一起写回 `ducklake_snapshot`。因此 id 分配的并发正确性由提交协议保证
(两个并发提交基于同一快照取号必然写出相同 `snapshot_id` 而冲突,03 篇),事务内则完全
无协调开销。catalog id 由 schema/table/view/partition key/sort key/name map 共享一个序列,
file id 由 data file/delete file 共享另一个序列。

### 8.2 GenerateUUID(UUIDv7)与文件/目录命名

`GenerateUUID()`(`src/storage/ducklake_transaction.cpp:2103`)返回
`UUID::ToString(UUIDv7::GenerateRandomUUID())`(`GenerateUUIDv7`,`:2099`)。UUIDv7 带
时间戳前缀,同目录文件名近似按写入时间有序,对对象存储 listing 友好。使用方:

- 表/schema/视图的稳定 uuid 及数据目录名:`src/storage/ducklake_schema_entry.cpp:97`、
  `src/storage/ducklake_catalog.cpp:275`、`src/storage/ducklake_insert.cpp:856`
  (CTAS,经 `DuckLakeCatalog::GeneratePathFromName(uuid, name)` 生成目录);
- delete file 文件名:`ducklake-<uuid>-delete.parquet` / `.puffin`
  (`src/storage/ducklake_delete.cpp:35`、`:161`);数据文件名 `ducklake-<uuid>.parquet`
  由 insert 的 copy 计划生成(07 篇)。

### 8.3 catalog_version:DuckDB 缓存失效的桥梁

DuckDB 内核用 `Catalog::GetCatalogVersion(context)` 判断绑定缓存是否失效。DuckLake 的实现
(`src/storage/ducklake_catalog.cpp:925`)转发到
`DuckLakeTransaction::GetCatalogVersion()`(`src/storage/ducklake_transaction.cpp:2107`):
事务无未提交 DDL 时返回快照的 `schema_version`;一旦本事务发生 DDL
(`CreateEntry/DropEntry/AlterEntry` 都会执行
`catalog_version = ducklake_catalog.GetNewUncommittedCatalogVersion()`,`:1702`、`:1805`、
`:1891`),则返回 catalog 级单调计数器 `last_uncommitted_catalog_version` 的新值
(`src/include/storage/ducklake_catalog.hpp:217`,不持久化、重启归零但恒大于任何
schema_version 语义上不要求——只要求变化)。提交成功后由 `set_catalog_version` 回调把
`catalog_version` 设为新 `schema_version`(`src/storage/ducklake_transaction.cpp:1460`)。

---

事务的终点是 `Commit()` → `FlushChanges()`(`src/storage/ducklake_transaction.cpp:1303`):
把本篇描述的全部本地状态翻译成一批元数据 SQL,经冲突检测/重试循环(或 server-side /
staged commit 路径)原子写入 metadata catalog——该协议全程见
[COMMIT_PROTOCOL_DESIGN.md](COMMIT_PROTOCOL_DESIGN.md)。
