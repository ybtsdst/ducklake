# DuckLake 乐观并发提交协议设计(COMMIT PROTOCOL)

> 行号基准:commit `47187559`。

## 概述

DuckLake 的写事务在执行期间只在本地累积变更(新写出的 parquet 文件、delete file、
catalog 变更等,数据结构见 02 篇),对元数据库不加任何长持锁。提交时才把全部变更
编译成**一个 SQL batch**,以"新 snapshot_id = 当前最大 snapshot_id + 1"的方式
INSERT 进 `ducklake_snapshot`,在元数据库的**单个事务**内原子执行。并发控制是纯
乐观的:若两个写者同时认领同一个 snapshot_id,后提交者会触发元数据库
`ducklake_snapshot` 主键冲突而失败;失败方捕获错误、回滚元数据事务,然后进入重试
轮——重试轮先拉取最新 snapshot 与 `ducklake_snapshot_changes` 中"事务快照之后"
所有已提交快照的变更摘要,做**逻辑冲突检测**(第四节冲突矩阵);逻辑上可交换
(如双方 INSERT 同一张表)则基于新 snapshot 重放 SQL batch,逻辑冲突(如对方已
ALTER 我方正在 INSERT 的表)则立即抛 `TransactionException` 放弃。

物理冲突信号(主键冲突)负责串行化,逻辑冲突检测负责判定"能否在新基底上重放",
两者组合等价于以表/文件为粒度的 first-committer-wins。重试带指数退避加随机因子。
除经典的 client-side 重试循环外,还有两条把重试搬到元数据服务器侧的路径
(server-side / staged commit,第七、八节),三条路径共享同一个
`DuckLakeTransactionState::Commit()` 重试循环,差异全部被 `DuckLakeCommitContext`
的回调闭包吸收。

提交时序:

```
 本地事务 state                            元数据库
 (DuckLakeTransactionState, 见 02 篇)
        │ DuckLakeTransaction::Commit() → FlushChanges()
        ▼
 GetTransactionChanges() → TransactionChangeInformation
        │
        ▼ 路径选择(第一节)
   ┌─ client-side RunCommitLoop ── DuckLakeCommitContext ─┐
   ├─ server-side(quack):staged 临时表 + ducklake_commit│
   └─ (服务器端复用同一循环) ──────────────────────────┘
        │
        ▼ 第 i 次尝试(i = 0 .. max_retry_count)
 ┌──────────────────────────────────────────────────────────┐
 │ i==0: commit_snapshot = 事务快照                          │
 │ i>0 : CheckForConflicts:                                  │
 │        SELECT 最新 snapshot + STRING_AGG(changes_made)    │
 │               WHERE snapshot_id > {事务快照 id} + 全局stats│
 │        逻辑冲突 ──► TransactionException(不可重试)──► 放弃 │
 │ commit_snapshot.snapshot_id++                              │
 │ SchemaChangesMade() ──► commit_snapshot.schema_version++   │
 │ batch = InsertSnapshotSql + CommitChanges                  │
 │       + WriteSnapshotChanges (占位符形式)                  │
 │ execute_commit_batch(commit_snapshot, batch) ── 一次执行   │
 │   └─ 并发认领同一 snapshot_id ──► PK/unique 冲突异常 ──┐  │
 │ commit_connection() → 收尾(清缓存/catalog_version)      │  │
 └──────────────────────────────────────────────────────│──┘
        ▲                                                │
        │  RetryOnError(primary key/unique/conflict/    │
        │  concurrent)且未达 max_retry_count:           │
        │  sleep(retry_wait_ms × U[0.5,1.0) × backoff^i) │
        └── prepare_retry()(清 inlined 缓存/重开事务)◄─┘
            否则 CleanupFiles() 删本地已写文件后抛错
```

关键源码位置:

| 主题 | 位置 |
| --- | --- |
| 提交入口 `Commit()` / `ChangesMade()` / `FlushChanges()` 三分支 | `src/storage/ducklake_transaction.cpp:737,801,1303` |
| `RunCommitLoop()`(client-side context 装配) | `src/storage/ducklake_transaction.cpp:1345` |
| `DuckLakeCommitContext` 定义 | `src/include/storage/ducklake_transaction_state.hpp:26` |
| 重试循环 `DuckLakeTransactionState::Commit()` | `src/storage/ducklake_transaction_state.cpp:1691` |
| 冲突检测 `CheckForConflicts`(矩阵本体) | `src/storage/ducklake_transaction_state.cpp:141,1675` |
| `TransactionChangeInformation` / `SnapshotChangeInformation` | `src/include/storage/ducklake_transaction_changes.hpp:22,46` |
| `changes_made` 解析 | `src/storage/ducklake_transaction_changes.cpp:135` |
| `RetryOnError` / `DuckLakeRetryConfig` | `src/storage/ducklake_transaction.cpp:1271,1288` |
| snapshot 写入 SQL | `src/storage/ducklake_metadata_manager.cpp:4063,4074` |
| 路径选择 gating(quack) | `src/metadata_manager/quack_metadata_manager.cpp:86-137` |
| server-side commit | `src/storage/ducklake_server_side_commit.cpp` |
| staged commit(临时表 staging) | `src/storage/ducklake_staged_commit.cpp` |
| id 重映射 `DuckLakeCommitState` | `src/include/storage/ducklake_commit_state.hpp:51` |

## 关联文档

- `ATTACH_CATALOG_DESIGN.md`(01):catalog 装载、`DuckLakeCatalog` 缓存。
- `TRANSACTION_DESIGN.md`(02):事务生命周期、快照模型、`LocalTableChanges`
  等本地变更 state——本篇只引用不重述。
- `METADATA_SCHEMA_DESIGN.md`(04):`ducklake_snapshot` / `ducklake_snapshot_changes`
  等元数据表的列级数据字典。
- `METADATA_MANAGER_DESIGN.md`(05):`DuckLakeMetadataManager` 接口与三后端;
  其 quack 节只描述 RPC 传输层,server-side commit 协议语义在本篇第七、八节。
- `DATA_INLINING_DESIGN.md`(08):inlined data 的写入/flush,本篇仅涉及其冲突语义。
- `MAINTENANCE_DESIGN.md`(09):compaction 的产生侧;其提交/冲突语义在本篇。
- `TABLE_FUNCTIONS_DESIGN.md`(10):`ducklake_commit` / `ducklake_set_commit_message`
  表函数的注册;其协议语义在本篇第六、七节。

## 一、提交入口与路径选择

### 1.1 Commit() → ChangesMade()

DuckDB 事务管理器提交时进入 `DuckLakeTransaction::Commit()`
(`ducklake_transaction.cpp:737`):有变更则 `FlushChanges()`,否则只
`connection->Commit()` 结束只读元数据事务;随后清空 `local_changes`。
`ChangesMade()`(`:801`)的判据:

```cpp
return state->SchemaChangesMade() || state->local_changes.HasChanges() ||
       !state->dropped_files.empty() || !new_name_maps.name_maps.empty();
```

其中 `SchemaChangesMade()`(`ducklake_transaction_state.cpp:68`)涵盖
new/dropped tables、schemas、views、renamed views、macros——它后续还决定
schema_version 是否自增(3.2 节)。

### 1.2 FlushChanges() 三分支

`FlushChanges()`(`ducklake_transaction.cpp:1303`):

```cpp
auto retry_config = DuckLakeRetryConfig::FromContext(*context.lock());
auto transaction_changes = GetTransactionChanges();
if (metadata_manager->CanSkipSnapshotFetch(transaction_changes)) {
    // 分支 A:连快照都不取,直接 server-side
    //(snapshot 已加载则传之,否则传 default 构造的 sentinel,
    //  其 snapshot_id == DConstants::INVALID_INDEX,由服务器读最新快照)
    metadata_manager->FlushChangesServerSide(*this, snapshot_or_sentinel, ...);
} else {
    auto transaction_snapshot = GetSnapshot();
    if (metadata_manager->ExecuteRetrialsServerSide()) {
        metadata_manager->FlushChangesServerSide(...);   // 分支 B
    } else {
        RunCommitLoop(transaction_snapshot, transaction_changes, retry_config); // 分支 C
    }
}
```

三个判定函数:

- `ExecuteRetrialsServerSide()`(`ducklake_metadata_manager.cpp:74`)读
  `DuckLakeCatalog::RetrialsServerSide()` 标志。该标志默认 `false`
  (`ducklake_catalog.hpp:307`),只有 quack 后端在 ATTACH 初始化时由
  `ProbeServerCapabilities()`(`quack_metadata_manager.cpp:72`,调用点
  `ducklake_initializer.cpp:117`)探测到服务器 `duckdb_functions()` 中存在
  `ducklake_commit` 函数后置 `true`。
- `CanSkipSnapshotFetch()` 基类恒 `false`(`ducklake_metadata_manager.cpp:78`);
  quack 覆写(`quack_metadata_manager.cpp:94`)为
  `ExecuteRetrialsServerSide() && IsDataOnlyCommit(changes)`,且
  `transaction.GetRequiresNewInlinedTable()` 时强制 `false`(服务器端无法创建
  inlined-data 表)。
- `IsDataOnlyCommit()`(`quack_metadata_manager.cpp:86`):所有 DDL 集合为空——
  `created_schemas/dropped_schemas/created_tables/created_*_macros/altered_tables/
  altered_tables_with_schema_version_changes/altered_views/dropped_tables/
  dropped_views/dropped_*_macros` 全空。即纯数据提交
  (insert/delete/inlined/compaction/flush)。

因此实际组合:基类(DuckDB/PostgreSQL/MySQL 直连)与 SQLite 后端永远走分支 C
client-side 循环;quack 后端在数据-only 提交时走 A(免一次快照 round-trip),
DDL 提交走 B——但 B 内部 `FlushChangesServerSide`
(`quack_metadata_manager.cpp:106`)再次判 `IsDataOnlyCommit`,DDL 提交会回落
`RunCommitLoop` client-side。即 **server-side 路径只承接数据-only 提交**,
A/B 的差别仅在是否预取了事务快照。

基类 `FlushChangesServerSide`(`ducklake_metadata_manager.cpp:82`)直接抛
`InternalException`,防御不支持 server-side 的后端误入。

## 二、RunCommitLoop 与 DuckLakeCommitContext

`RunCommitLoop()`(`ducklake_transaction.cpp:1345`)本身不含循环逻辑,职责是装配
`DuckLakeCommitContext` 后调 `state->Commit(...)`。`DuckLakeCommitContext`
(`ducklake_transaction_state.hpp:26-106`)是提交循环对外部环境的全部依赖,
server-side commit 复用同一循环时只需换一套闭包(7.4 节对照):

| 成员 | client-side 绑定(`transaction.cpp` 行号) | 作用 |
| --- | --- | --- |
| `conflict_query_executor` | `:1349` `metadata_manager->Query(transaction_snapshot, q)` | 重试轮冲突检测查询;`{SNAPSHOT_ID}` 被替换为**事务快照** id,出错即抛 |
| `get_snapshot` | `:1357` `GetSnapshot()` | 首轮取提交基底快照(client-side 即缓存的事务快照) |
| `execute_commit_batch` | `:1360` `metadata_manager->Execute(snapshot, query)` | 执行整个 SQL batch;此时才用 commit_snapshot 替换 `{SNAPSHOT_ID}/{SCHEMA_VERSION}/{NEXT_CATALOG_ID}/{NEXT_FILE_ID}` 占位符(`ducklake_metadata_manager.cpp:2398`) |
| `flush_cache_if_pending` | `:1363` | 提交成功后若 `TakePendingCacheClear()` 则 `ClearCache()` |
| `commit_connection` | `:1368` `connection->Commit()` | 提交元数据库事务 |
| `try_rollback` | `:1371` | 失败后若元数据事务仍活跃则 `Rollback()` |
| `prepare_retry` | `:1376` | 重试前:`ClearInlinedTableCaches()`、重开元数据事务、`snapshot.reset()` |
| `query_metadata` / `query_metadata_with_snapshot` | `:1381,1384` | 提交期间的辅助查询(建表路径解析、stats 重算等) |
| `try_append_data_files` | `:1387` | 可选 Appender 快路径:成立则跳过 data file 的 SQL 文本生成 |
| `write_inlined_tables` / `write_inlined_data` / `write_inlined_file_deletes` | `:1392,1398,1395` | inlined data 三类 SQL 的生成(见 08 篇) |
| `get_table_stats` / `build_stats_map` | `:1403,1453` | 首轮 per-table 取全局 stats / 重试轮由冲突查询结果重建 stats map |
| `get_table_column_schema` / `get_inlined_table_names` / `get_net_data_file_row_count` / `get_net_inlined_row_count` | `:1406,1428,1439,1446` | REWRITE_DELETES 后全局 stats 精确重算所需(`RecomputeGlobalStatsAfterRewrite`) |
| `invalidate_schema_cache` | `:1457` | drop 空 inlined 表后失效 catalog schema 缓存 |
| `set_catalog_version` | `:1460` | 成功后把新 `schema_version` 发布为本事务 `catalog_version` |
| `set_committed_snapshot_id` | `:1463` | 成功后记录到 `DuckLakeCatalog::SetCommittedSnapshotId` |
| `commit_info` | `:1466` `state->commit_info` | author / message / extra_info(第六节) |
| `skip_drop_empty_inlined` | 默认 `false` | `true` 时循环内跳过 `DropEmptySupersededInlinedTables`(server-side 置 `true`,由客户端善后) |

注意 `execute_commit_batch` 的占位符替换发生在 batch 字符串**构造完成之后**:
`CommitChanges` 过程中 `commit_snapshot.next_catalog_id/next_file_id` 被各 id
分配点递增,最终 `InsertSnapshotSql` 里的 `{NEXT_CATALOG_ID}/{NEXT_FILE_ID}`
替换为**分配完毕后的值**,故新 snapshot 行天然记录了下一个可用 id 水位。

## 三、DuckLakeTransactionState::Commit 重试循环

循环本体在 `ducklake_transaction_state.cpp:1691-1775`,骨架:

```cpp
for (idx_t i = 0; i < retry_config.max_retry_count + 1; i++) {
    bool can_retry;
    auto attempt_changes = transaction_changes;   // 每轮拷贝(下游会改写它)
    try {
        can_retry = false;
        if (i > 0) {
            commit_stats_snapshot = CheckForConflicts(transaction_snapshot,
                attempt_changes, context.conflict_query_executor);
            stats = &commit_stats_snapshot.stats;
        } else {
            commit_stats_snapshot.snapshot = context.get_snapshot();
        }
        commit_snapshot.snapshot_id++;
        if (SchemaChangesMade()) commit_snapshot.schema_version++;
        can_retry = true;
        DuckLakeCommitState commit_state(commit_snapshot);
        string batch_queries = DuckLakeMetadataManager::InsertSnapshotSql();
        batch_queries += CommitChanges(commit_state, attempt_changes, stats, context);
        batch_queries += WriteSnapshotChanges(commit_state, attempt_changes,
                                              context.commit_info);
        auto res = context.execute_commit_batch(commit_snapshot, batch_queries);
        ...
```

### 3.1 首轮与重试轮的快照获取差异

- **首轮(i==0)**:`context.get_snapshot()`,client-side 即事务自己的快照
  (`GetSnapshot()` 有缓存,`ducklake_transaction.cpp:1536`)。提交基底 =
  事务读到的世界。
- **重试轮(i>0)**:`CheckForConflicts`(`:1675`)经
  `GetSnapshotAndStatsAndChanges` 一条 UNION ALL 查询同时拿回三样东西
  (`ducklake_metadata_manager.cpp:4082`):最新 snapshot 行、
  `STRING_AGG(changes_made)`(`WHERE c.snapshot_id > {SNAPSHOT_ID}`,占位符 =
  事务快照 id)、以及全表全局 stats。最新快照成为新的提交基底;stats 通过
  `context.build_stats_map` 重建,替代首轮 per-table 的
  `context.get_table_stats`——因为对方事务可能已改写
  `ducklake_table_stats`,本地缓存不可信。

随后 `snapshot_id++`;若 `SchemaChangesMade()` 则 `schema_version++`(纯数据提交
沿用基底 schema_version,这正是 `ducklake_snapshot.schema_version` 可以多个
snapshot 相同的原因)。

### 3.2 SQL batch 构造顺序

batch = `InsertSnapshotSql()` + `CommitChanges()` + `WriteSnapshotChanges()`,
全部以占位符形式拼成单个字符串,**一次** `execute_commit_batch` 执行。
`CommitChanges`(`:1374-1586`)内部的生成顺序(各 `DuckLakeMetadataManager`
静态 SQL 生成函数签名见 05 篇):

1. drop:tables(`renamed_tables` 也走 `DropTables`,带 rename 标志)、views、
   macros、schemas;
2. 新 schemas(`GetNewSchemas`,分配 `next_catalog_id`)→ 新 tables/views/
   partition keys/tags/column tags/dropped columns/new columns/inlined-data
   tables/sort keys(`GetNewTables`);
3. 新 macros、新 name maps(`GetNewNameMaps`,分配 mapping id);
4. 数据:`GetNewDataFiles`(分配 file id、合并全局 stats、生成
   `UpdateGlobalTableStatsSql`)→ data file INSERT(或 Appender 快路径)→
   inlined data;
5. flush 重试补偿:`GenerateDeleteFlushedInlinedData`(flush 型事务重试时重发
   对 inlined 表的删除);
6. `DropDataFiles`(`dropped_files`)→ 新 delete files(含覆写旧 delete file
   的删除)→ inlined deletes / inlined file deletes;
7. compaction:MERGE_ADJACENT 与 REWRITE_DELETES 两类
   `WriteCompactions`+输出文件;REWRITE_DELETES 后触发
   `RecomputeGlobalStatsAfterRewrite`(`:790`,表回到 delete-free 时把全局
   min/max 重算为精确值);
8. `InsertNewSchema(commit_snapshot, tables_with_schema_changes)`
   (`ducklake_metadata_manager.cpp:5275`):为列定义发生变化的表登记新的
   per-table schema 版本。

`WriteSnapshotChanges`(`:303`)最后生成 `ducklake_snapshot_changes` 的 INSERT
(第六节),并在此处把事务本地 id 经 `commit_state` 重映射后**重新汇总**
`attempt_changes`——这就是循环每轮拷贝 `transaction_changes` 的原因:重映射和
re-add 会污染该结构,重试轮必须从原始值重来。

### 3.3 成功收尾与失败路径

执行成功后(`:1726-1735`):若本提交 flush 过 inlined data,记录之;
`flush_cache_if_pending()` → `commit_connection()`(元数据库事务真正 COMMIT,
乐观窗口在此关闭)→ 若 flush 过且未 `skip_drop_empty_inlined` 则
`DropEmptySupersededInlinedTables(context)`(`:1613`,提交**之后**的 best-effort
清理:删空的、已被新 schema 版本取代的 inlined-data 表并失效 schema 缓存)→
`set_catalog_version(schema_version)` → break。循环外
`set_committed_snapshot_id(snapshot_id)`(`:1774`)。

失败路径见第五节;值得注意的是 `can_retry` 标志:`CheckForConflicts` 抛出的
`TransactionException` 发生在 `can_retry = true` 之前,因此**逻辑冲突永不重试**,
直接走放弃分支——重试只服务于"物理碰撞但逻辑可交换"的情形。

## 四、冲突检测

### 4.1 输入:TransactionChangeInformation

我方变更摘要由 `GetTransactionChanges()`(`ducklake_transaction.cpp:889`)从事务
state 汇总,数据文件粒度的归类在 `AddTableChanges()`(`:967`)。结构定义
`ducklake_transaction_changes.hpp:22-44`:

```cpp
struct TransactionChangeInformation {
    case_insensitive_set_t created_schemas;        // 本事务 CREATE SCHEMA 的名字
    map<SchemaIndex, reference<DuckLakeSchemaEntry>> dropped_schemas; // DROP SCHEMA(id→entry,冲突文案需要名字)
    case_insensitive_map_t<reference_set_t<CatalogEntry>> created_tables;        // schema 名→新建 table/view entry
    case_insensitive_map_t<reference_set_t<CatalogEntry>> created_scalar_macros; // 同上,scalar macro
    case_insensitive_map_t<reference_set_t<CatalogEntry>> created_table_macros;  // 同上,table macro

    set<TableIndex> altered_tables;          // 任何 ALTER(含 comment/sort key)
    set<TableIndex> altered_tables_with_schema_version_changes; // 其中改了列定义/分区键的子集(决定 per-table schema 版本)
    set<TableIndex> altered_views;           // view 的 SET_COMMENT
    set<TableIndex> dropped_tables;          // DROP TABLE
    set<TableIndex> dropped_views;           // DROP VIEW
    set<MacroIndex> dropped_scalar_macros;   // DROP MACRO
    set<MacroIndex> dropped_table_macros;    // DROP MACRO(table)
    set<TableIndex> tables_inserted_into;    // 写出了新 data file(非 flush 来源)
    set<TableIndex> tables_deleted_from;     // 写出了新 delete file / 整文件删除
    set<TableIndex> tables_inserted_inlined; // 新 inlined data
    set<TableIndex> tables_deleted_inlined;  // inlined 行删除 / inlined file delete
    set<TableIndex> tables_flushed_inlined;  // flush:data file 带 begin_snapshot
    set<TableIndex> tables_compacted;        // (汇总侧未使用,见 4.4)
    set<TableIndex> tables_merge_adjacent;   // MERGE_ADJACENT compaction
    set<TableIndex> tables_rewrite_delete;   // REWRITE_DELETES compaction
};
```

`AddTableChanges` 的归类细节:同一表的 `new_data_files` 中
`begin_snapshot.IsValid()` 的文件来自 inlined flush,记 `tables_flushed_inlined`,
否则记 `tables_inserted_into`;两者可同时成立。

他方变更 `SnapshotChangeInformation`(`hpp:46`)字段一一对应,由
`ParseChangesMade()` 从 `changes_made` 字符串解析(created_* 存
schema→name→类型字符串,dropped/数据类存 id 集合)。

### 4.2 检测流程

`CheckForConflicts`(public,`ducklake_transaction_state.cpp:1675`)→
拉取并解析他方 changes → 调 const 重载(`:141-283`)逐条
`ConflictCheck(index, conflict_map, action, conflict_action)`:命中即抛
`TransactionException("Transaction conflict - attempting to <action> ... - but
another transaction has <conflict_action>")`。

### 4.3 ★冲突矩阵

逐条核自 `ducklake_transaction_state.cpp:141-283`。"我方变更"对照
`TransactionChangeInformation` 字段;"他方变更"是事务快照之后**所有已提交**
snapshot 的 `changes_made` 并集。

| 我方变更 | 与之冲突的他方变更 | 代码行 |
| --- | --- | --- |
| DROP TABLE (`dropped_tables`) | 同表 DROP TABLE | `:146` |
| DROP VIEW (`dropped_views`) | 同 view DROP VIEW | `:150` |
| DROP MACRO(scalar/table) | 同 macro DROP | `:154,157` |
| DROP SCHEMA (`dropped_schemas`) | 同 schema DROP;他方在该 schema 内 CREATE 了 table/view | `:161-168` |
| CREATE SCHEMA (`created_schemas`) | 同名 CREATE SCHEMA | `:170` |
| CREATE MACRO(table/scalar) | 所在 schema 被 DROP;同 schema 同名 CREATE | `:175,176` |
| CREATE TABLE / CREATE VIEW (`created_tables`) | 所在 schema 被 DROP;同 schema 同名 CREATE(table 或 view) | `:177,179-203` |
| INSERT(文件,`tables_inserted_into`) | 同表 DROP / ALTER / DELETE(文件)/ DELETE(inlined) | `:204-210` |
| INSERT(inlined,`tables_inserted_inlined`) | 同上四类 | `:211-217` |
| DELETE(文件,`tables_deleted_from`) | 同表 DROP / ALTER / MERGE_ADJACENT / REWRITE_DELETES / INSERT(文件)/ INSERT(inlined);他方同表也 DELETE 时降级为**文件粒度**检查(见下) | `:218-250` |
| DELETE(inlined,`tables_deleted_inlined`) | 同表 DROP / ALTER / DELETE(inlined)/ FLUSH / INSERT(文件)/ INSERT(inlined) | `:251-258` |
| FLUSH inlined (`tables_flushed_inlined`) | 同表 DROP / DELETE(inlined)/ FLUSH | `:259-263` |
| compaction(MERGE_ADJACENT) | 同表 DROP / DELETE(文件)/ 任一类 compaction | `:264-269` |
| compaction(REWRITE_DELETES) | 同上 | `:270-275` |
| ALTER TABLE (`altered_tables`) | 同表 DROP / ALTER | `:276-279` |
| ALTER VIEW (`altered_views`) | 同 view ALTER | `:280-282` |

**DELETE × DELETE 的文件粒度检查**(`:226-250`):双方对同一张表都有 delete
并不直接冲突;此时调 `GetFilesDeletedOrDroppedAfterSnapshot`(`:1588`)查询
事务快照之后他方动过的 data file 集合:

```sql
SELECT data_file_id FROM {METADATA_CATALOG}.ducklake_delete_file
WHERE begin_snapshot > {SNAPSHOT_ID}
UNION ALL
SELECT data_file_id FROM {METADATA_CATALOG}.ducklake_data_file
WHERE end_snapshot IS NOT NULL AND end_snapshot > {SNAPSHOT_ID}
```

我方 `new_delete_files` 的 `data_file_id` 以及 `dropped_files`(整文件删除)
命中该集合才冲突。即**对不同文件的并发 DELETE 可交换**(各自的 delete file
互不覆盖),对同一文件的并发 DELETE 冲突(后者的 delete file 基于过期的删除
位图,会丢失对方的删除)。

值得注意的**允许并发**组合(代码里没有对应检查,经核实):

- INSERT × INSERT(同表):双方只各自追加 data file 行,全局 stats 在重试轮
  用最新值重算,完全可交换。这是该协议相对"表级锁"的核心增益。
- INSERT × compaction(双向):INSERT 不检查他方 `tables_merge_adjacent/
  tables_rewrite_delete`;compaction 也不检查他方 `inserted_tables`。compaction
  只改写既有文件,与新增文件正交。
- DELETE(inlined)× DELETE(文件):互不出现在对方的冲突列表中(作用于不同
  存储层)。
- FLUSH × INSERT/DELETE(文件)/compaction:flush 只检查 DROP、inlined delete
  与 flush 自身。

**非对称性**(first-committer-wins 的方向性):检查只在"我提交、他已提交"时
执行,且各方向集合并不对称:

- 我 ALTER × 他已 INSERT/DELETE:**允许**(ALTER 只查 DROP/ALTER);反方向我
  INSERT/DELETE × 他已 ALTER:**冲突**。即先提交的 DML 不阻挡后到的 DDL,
  先提交的 DDL 压制后到的 DML。
- 我 DROP TABLE × 他已 INSERT 同表:**允许**(DROP 只查同表 DROP)——表被删,
  对方刚提交的数据随之消失,语义上等价于"DROP 排在后"。
- 我 ALTER VIEW × 他已 DROP VIEW:未检查(view 只查 altered_views),与 table
  的 ALTER×DROP 检查不对称。

### 4.4 与 changes_made 解析的两处错配

核实 `ducklake_transaction_changes.cpp` 时发现两点(行为现状,非笔误):

1. 解析器接受 `compacted_table` 类型并填入 `tables_compacted`
   (`:72,196`),但 `CheckForConflicts` 从不读取 `tables_compacted`;当前
   序列化器只产出 `merge_adjacent`/`rewrite_delete`,该类型属兼容旧格式的
   遗留通道,旧格式快照的 compaction 对新事务不构成冲突输入。
2. `flushed_inlined` 与 `inline_flush` 都解析为 FLUSH(`:82-84`);序列化侧
   (`WriteSnapshotChanges`)写的是 `inline_flush`。

## 五、重试判定与退避

### 5.1 RetryOnError

`DuckLakeTransaction::RetryOnError`(`ducklake_transaction.cpp:1271`)对错误消息
做小写化子串匹配,命中任一即可重试:

- `"primary key"` 或 `"unique"`——并发认领同一 snapshot_id 时,
  `ducklake_snapshot`(或 `ducklake_snapshot_changes`)主键/唯一约束冲突,
  覆盖 DuckDB/PostgreSQL/MySQL/SQLite 各自的报错措辞;
- `"conflict"`——含 PostgreSQL serialization conflict、DuckDB
  "write-write conflict" 等;
- `"concurrent"`——并发访问类报错(如 SQLite busy/locked 的包装)。

其余错误(网络断连、SQL 语法、磁盘满……)一律不重试。

### 5.2 DuckLakeRetryConfig 与退避公式

定义在 `ducklake_transaction.hpp:159-165`,默认值与扩展选项注册
(`ducklake_extension.cpp:28-34`)一致:

```cpp
struct DuckLakeRetryConfig {
    idx_t max_retry_count = 10;   // SET ducklake_max_retry_count(UBIGINT, GLOBAL)
    idx_t retry_wait_ms = 100;    // SET ducklake_retry_wait_ms
    double retry_backoff = 1.5;   // SET ducklake_retry_backoff
};
```

`FromContext()`(`ducklake_transaction.cpp:1288`)在每次 FlushChanges 时从当前
设置读取。总尝试次数 = `max_retry_count + 1`(`i` 为零基尝试序号,
`i >= max_retry_count` 即 `finished_retrying`,`:1743`)。退避
(`ducklake_transaction_state.cpp:1759-1766`):

```cpp
double random_multiplier = (random.NextRandom() + 1.0) / 2.0;   // U[0.5, 1.0)
uint64_t sleep_amount = (uint64_t)((double)retry_config.retry_wait_ms *
    random_multiplier * pow(retry_config.retry_backoff, (double)i));
```

即第 i 次失败后 sleep `retry_wait_ms × U[0.5,1.0) × backoff^i` 毫秒;随机因子
打散同时碰撞的写者,避免重试再次同步碰撞。`DUCKDB_NO_THREADS` 编译下不 sleep。
sleep 后 `prepare_retry()`:client-side 清 inlined 表缓存、`BeginTransaction()`
重开元数据事务、`snapshot.reset()`。

### 5.3 放弃与 CleanupFiles

`!can_retry`(逻辑冲突,3.3 节)、`!retry_on_error` 或 `finished_retrying`
任一成立则放弃(`:1744-1757`):先 `CleanupFiles()`
(`ducklake_transaction_state.cpp:63` → `local_changes.CleanupFiles(db)`)
删除本事务已写到对象存储的数据/删除文件——元数据从未提交,这些文件是孤儿;
然后把原始错误包上 "Failed to commit DuckLake transaction",若因重试耗尽还附加
建议调大 `ducklake_max_retry_count` 的提示后抛出。

## 六、snapshot 写入

### 6.1 两条 INSERT

`InsertSnapshotSql()`(`ducklake_metadata_manager.cpp:4063`):

```sql
INSERT INTO {METADATA_CATALOG}.ducklake_snapshot VALUES
    ({SNAPSHOT_ID}, NOW(), {SCHEMA_VERSION}, {NEXT_CATALOG_ID}, {NEXT_FILE_ID});
```

`WriteSnapshotChangesSql()`(`:4074`):

```sql
INSERT INTO {METADATA_CATALOG}.ducklake_snapshot_changes VALUES
    ({SNAPSHOT_ID}, <changes_made|NULL>, <author>, <commit_message>, <extra_info>);
```

列含义见 04 篇;本篇视角下关键点:`snapshot_id` 上的主键是乐观并发的物理仲裁,
`changes_made` 是逻辑冲突检测的输入,next_catalog_id/next_file_id 是占位符在
执行时刻按"分配完毕后"的水位替换(2 节末)。

### 6.2 changes_made 字符串格式

由 `WriteSnapshotChanges`(`ducklake_transaction_state.cpp:303-398`)序列化,
`SnapshotChangeInformation::ParseChangesMade`
(`ducklake_transaction_changes.cpp:135`)解析。格式为逗号分隔的
`<type>:<value>` 列表;`value` 内的逗号通过 `"` 引用规避(`ParseChangeValue`
`:90`,双引号翻转 in_quotes,只在未引用状态的逗号处切分)。

类型与取值(序列化侧):

| type | value |
| --- | --- |
| `created_schema` | 带引号 schema 名 |
| `created_table` / `created_view` | `"schema"."name"`(`SQLIdentifierToString`) |
| `created_scalar_macro` / `created_table_macro` | 同上 |
| `dropped_schema` / `dropped_table` / `dropped_view` / `dropped_scalar_macro` / `dropped_table_macro` | 数字 id |
| `inserted_into_table` / `deleted_from_table` / `altered_table` / `altered_view` | 表/视图 id(经 `commit_state.GetTableId` 重映射为真实 id) |
| `inlined_insert` / `inlined_delete` / `inline_flush` | 表 id |
| `merge_adjacent` / `rewrite_delete` | 表 id |

序列化前先用重映射后的 id 重新汇总 `local_changes`(确保事务内新建表的数据变更
以真实 id 记账,`:308-314`);并强制约束(`:391-394`)
"`Transactions can either make changes OR perform compaction - not both`":
compaction 与其他任何变更互斥——这保证了冲突矩阵中 compaction 行的封闭性。

### 6.3 commit message / extra_info

`DuckLakeSnapshotCommit`(`ducklake_metadata_info.hpp:521`)四字段:
`author/commit_message/commit_extra_info`(均为 `Value`,NULL 即 SQL NULL)+
`is_commit_info_set`。`CALL ducklake_set_commit_message(catalog, author, message,
extra_info => ...)`(`functions/ducklake_set_commit_message.cpp:53`,注册见 10
篇)把它挂到 `DuckLakeTransaction::SetCommitMessage`(transaction-local,随提交
写入,作用于下一次 commit)。若 catalog 选项 `require_commit_message` 为真且未
设置,`EnsureCommitInfoProvided`(`ducklake_transaction_state.cpp:50`)在
`CommitChanges` 一开始抛 `InvalidConfigurationException`。

## 七、server-side commit

### 7.1 动机

client-side 循环的每轮重试都要跨网络:冲突检测一查、batch 一执行,加上元数据
事务的 BEGIN/COMMIT/ROLLBACK,在客户端到元数据服务器 RTT 高时,高争用表的提交
延迟随重试次数线性放大。server-side commit 把**整个重试循环**搬进元数据服务器
(quack 后端,服务器本身是装载了 ducklake 扩展的 DuckDB):客户端单程上传变更
(staged 临时表 + 一次 `ducklake_commit` 调用),冲突检测/退避/重放全部发生在
服务器本地,降低 round-trip;`CanSkipSnapshotFetch` 路径下客户端甚至不需要先取
快照。

### 7.2 ducklake_commit 表函数契约

`functions/ducklake_commit.cpp`(注册见 10 篇):

```
ducklake_commit(metadata_schema_name VARCHAR, schema_version BIGINT,
                max_retry_count => BIGINT, retry_wait_ms => BIGINT,
                retry_backoff => DOUBLE)
→ (committed_snapshot_id BIGINT, committed_schema_version BIGINT,
   had_flushes BOOLEAN)
```

`schema_version` 传 `-1` 表示客户端没有事务快照(配合 COMMIT_HEADER 中
`transaction_snapshot_id = NULL`,服务器自行读最新快照,
`ducklake_server_side_commit.cpp:189-202`)。execute 时构造
`DuckLakeServerSideCommit` 并 `Run()`(`functions/ducklake_commit.cpp:59`)。
重试参数由客户端把自己的 `DuckLakeRetryConfig` 内联在 staged batch 末尾的调用
里转发(8.2 节),`SetRetryConfigOverride` 覆盖服务器默认值。

### 7.3 服务端执行:DuckLakeServerSideCommit::Run

`ducklake_server_side_commit.cpp:131-166`。在服务器的会话内:

1. 依次 `ReadCommitHeader/ReadColumnTypes/ReadStagedDeleteFiles/
   ReadStagedDataFiles/ReadStagedInlinedData/ReadStagedInlinedDeletes/
   ReadStagedInlinedFileDeletes/ReadStagedDroppedFiles/
   ReadStagedFlushedInlinedTables/ReadStagedCompactions/ReadStagedNameMaps/
   ReadExistingTableStats`——从 17 张 staging 临时表(8.1 节)**反序列化出一个
   `DuckLakeTransactionState`**(`ScanStagedTable` 直接走 catalog API 扫存储,
   不发 SQL,`:798`)。列类型从 `ducklake_column` 现查(staging 表里 stats 的
   min/max 是字符串,需类型重建 `DuckLakeColumnStats`)。
2. 用与客户端 `DuckLakeTransaction::AddTableChanges` **同一个**静态函数重导出
   `transaction_changes`(`:146-152`),保证冲突语义逐字节一致。
3. `fresh_conn.BeginTransaction()` 后调 `state->Commit(transaction_snapshot,
   transaction_changes, retry_config, BuildContext(...))`——**与 client-side
   完全相同的重试循环**(第三节),在服务器本地连接上跑。

### 7.4 服务端 context 与客户端的差异

`BuildContext()`(`:669-776`)相对 `RunCommitLoop` 的关键差异:

- `skip_drop_empty_inlined = true`:DropEmptySupersededInlinedTables 留给客户端
  (quack 客户端持有 inlined 表缓存,必须由它失效);
- 所有查询走 `fresh_conn` 本地连接 + `SubstitutePlaceholders`(`:778`,服务器上
  `{METADATA_CATALOG}` 只是 schema 名);`conflict_query_executor` 的
  `{SNAPSHOT_ID}` 替换为 header 里带来的事务快照 id;
- `prepare_retry` 仅 `BeginTransaction()`(无客户端缓存可清);
- `write_inlined_data` 改为 `BuildInlinedDataInserts`(`:638`):staged 的行已是
  SQL literal 元组文本,剥外层括号后拼回共享的
  `FormatInlinedDataInsert`;若目标表尚无 inlined-data 表则抛
  `InternalException`("this commit should have taken the client-side path",
  与 1.2 节 `GetRequiresNewInlinedTable` gating 互为印证);
- `set_catalog_version`/`set_committed_snapshot_id` 写到局部变量,经函数返回值
  带回客户端。

### 7.5 客户端善后

quack `FlushChangesServerSide`(`quack_metadata_manager.cpp:102-137`)拿到结果行
后:`SetCommittedSnapshotId` → `ApplyServerSideCommit(schema_version)`
(`ducklake_transaction.cpp:1327`,设 `catalog_version` 并提交本地元数据连接)
→ `had_flushes` 为真则 `DropEmptySupersededInlinedTablesClientSide()`
(`:1334`)→ 无条件 `ClearCache()`(提交可能在服务器上建了
`ducklake_inlined_data_*`/`ducklake_inlined_delete_*` 表,客户端缓存必须失效)。

## 八、staged commit

### 8.1 17 张 staging 临时表

`DuckLakeStagedTable`(`ducklake_staged_commit.cpp:24-177`)定义 17 种
`DuckLakeStagedTableType`,全部是服务器会话内的
`CREATE TEMPORARY TABLE IF NOT EXISTS`(随后 `TRUNCATE` 清残留):

| 类型 | 表名 | 内容 |
| --- | --- | --- |
| COMMIT_HEADER | `ducklake_staged_commit` | author/message/extra_info、事务快照(snapshot_id 可 NULL)、data_path、separator、next_catalog_id/next_file_id |
| DATA_FILE | `ducklake_staged_data_file` | 新 data file(本地 file id、table_id、路径、行数、stats 锚点、`compaction_id` 区分 compaction 输出) |
| DATA_FILE_COLUMN_STATS | `..._data_file_column_stats` | per-file 列 stats(13 列共享 payload `STAGED_STAT_COLUMNS`) |
| DATA_FILE_PARTITION | `..._data_file_partition` | per-file 分区值 |
| DELETE_FILE | `ducklake_staged_delete_file` | delete file;`attached_local_file_id` 非 NULL 表示挂在本事务新 data file 上 |
| INLINED_DATA / INLINED_ROW / INLINED_COLUMN_STATS | `..._inlined_*` | inlined 表头(has_preserved_row_ids)、逐行 SQL literal 元组、列 stats |
| INLINED_DELETE / INLINED_FILE_DELETE | `..._inlined_(file_)delete` | inlined 行删除(按 inlined 表名)/ parquet 文件上的 inlined 删除(按 file id) |
| DROPPED_FILE / TABLES_DELETED_FROM | `..._dropped_file` / `..._tables_deleted_from` | 整文件删除与"该表发生过删除"标记 |
| FLUSHED_INLINED | `..._flushed_inlined` | flush 掉的 inlined 表(名字、schema_version、flush 快照) |
| COMPACTION / COMPACTION_SOURCE | `..._compaction(_source)` | compaction 头(类型、row_id_start、输出文件指针)与源文件明细 |
| NAME_MAP / NAME_MAP_ENTRY | `..._name_map(_entry)` | 列名映射树(parent_entry_id 编码层级) |

### 8.2 Build() 产物

`DuckLakeStagedCommit::Build()`(`:498-528`)在**客户端**把事务 state 序列化为
一个 SQL batch 字符串:

```
CreateAllSql + TruncateAllSql
+ EmitCommitHeader + EmitDataFiles + EmitCompactions + EmitInlinedData
+ EmitInlinedDeletes + EmitInlinedFileDeletes + EmitDeleteFiles
+ EmitDroppedFiles + EmitFlushedInlinedTables + EmitNameMaps
+ "SELECT * FROM ducklake_commit('<schema>', <schema_version|-1>,
     max_retry_count => N, retry_wait_ms => N, retry_backoff => F);"
```

quack 的 `FlushChangesServerSide` 把这个 batch 经一次
`CALL quack_query_by_name(...)` RPC 发给服务器执行(`quack_metadata_manager.cpp:
111-119`)——临时表填充与 `ducklake_commit` 调用同会话完成,这正是 staging 用
TEMPORARY 表的原因:无并发可见性问题,也无需清理协议。

### 8.3 ★与 server-side commit 的分工边界(已从两文件核实)

报告素材中此处是推断,现以代码为准:

- **staged commit(`ducklake_staged_commit.cpp`)是纯生产者/编码器**:只把
  `DuckLakeTransaction` 的本地变更 state(`LocalTableChanges`、dropped files、
  flushed inlined tables、name maps、commit_info、事务快照)序列化成临时表
  INSERT 文本,自身不接触元数据表、不做冲突检测、不重试;它的最后一条语句
  调用 `ducklake_commit` 把控制权交给服务器。
- **server-side commit(`ducklake_server_side_commit.cpp`)是消费者/执行器**:
  在服务器进程内读回临时表、重建 `DuckLakeTransactionState` 与
  `TransactionChangeInformation`,然后运行与 client-side 完全相同的
  `DuckLakeTransactionState::Commit()` 循环(含 CheckForConflicts、退避、
  snapshot 写入)。两者的 schema 由同一组 `DuckLakeStagedTable::Columns()`
  定义钉死,stats payload 的编/解码函数(`EmitColumnStatsValues` ↔
  `ReadColumnStatsRow`)注释互指。
- **启用条件**:两者总是成对启用,仅在 quack 后端 + 服务器探测到
  `ducklake_commit` + 数据-only 提交 + 不需要新建 inlined-data 表时走此路;
  其余一律 client-side `RunCommitLoop`。不存在"staged 但 client-side 执行"
  或反之的组合。

## 九、commit 辅助:DuckLakeCommitState 与 id 重映射

事务执行期内新建的 schema/table/view、partition key、name mapping 都使用
transaction-local id:`TableIndex/SchemaIndex` 等 ≥
`DuckLakeConstants::TRANSACTION_LOCAL_ID_START = 2^63`
(`common/index.hpp:18`),inlined row id ≥ `10^18`(`:19`)。真实 id 只能在
提交时刻从 `commit_snapshot.next_catalog_id/next_file_id` 顺序分配——这两个
计数器属于被认领的新 snapshot,因而天然无并发分配冲突(冲突由 snapshot_id 仲裁)。

`DuckLakeCommitState`(`ducklake_commit_state.hpp:51-109`)是单次提交尝试内的
"local id → 真实 id"翻译层:

```cpp
struct DuckLakeCommitState {
    DuckLakeSnapshot &commit_snapshot;            // 本轮提交快照(id 分配计数器所在)
    map<SchemaIndex, SchemaIndex> committed_schemas;   // local schema id → 已分配真实 id
    map<TableIndex, TableIndex> committed_tables;      // local table/view id → 真实 id(view 共用)
    map<idx_t, idx_t> committed_partition_ids;         // local partition id → 真实 id
    map<MappingIndex, MappingIndex> committed_mapping_indexes; // local name-map id → 真实 id
    map<TableIndex, vector<DuckLakeDeleteFile>> local_delete_files;
        // 挂在"本事务新建 data file"上的 delete file:
        // 须等 GetNewDataFiles 给 data file 分配真实 file id 后才能写出
};
```

`RemapIdentifier`/`RemapPartitionId`/`RemapMappingIndex` 均为"查到则替换、查不
到原样返回"的幂等映射,因此对已是真实 id 的引用无害。填表点:
`GetNewSchemas`(`ducklake_transaction_state.cpp:1366`)、
`GetNewTableInfo`/`GetNewViewInfo`(`:1227,1325`,同事务 CREATE+RENAME 时改为
patch 已生成行,`RenameEmittedEntry`)、`GetNewPartitionKey`
(`ducklake_transaction.cpp:1022-1024`)、`GetNewNameMaps`(`:546`)。消费点
贯穿 `CommitChanges` 全程:data/delete file 的 `table_id`、`partition_id`、
`mapping_id`(`GetNewDataFile`,`:513-520`),以及 `WriteSnapshotChanges` 里
changes_made 的 id 序列化(4.1/6.2 节)。由于 `DuckLakeCommitState` 每轮尝试
重新构造(`:1717`),重试轮会基于新 `commit_snapshot` 重新分配全部 id——
这也是 batch 必须整体重建而非缓存复用的原因。

`GetNewDeleteFiles`(`:551-584`)最后统一收割两类 delete file:作用于既有文件
的(直接来自 `local_changes`,可能触发覆写旧 delete file 的删除)与
`commit_state.local_delete_files` 里挂在本事务新文件上的(断言不可能覆写)。
