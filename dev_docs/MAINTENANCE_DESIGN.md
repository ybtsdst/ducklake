# DuckLake 维护操作设计:CHECKPOINT / Compaction / 快照过期 / 文件清理 / 外部文件导入

> 行号基准:commit `47187559`(HEAD)。

## 概述

DuckLake 的数据文件一旦写出就不可变,所有 DML 都通过"新增文件 + 元数据行"表达(见 07)。
长期运行后会自然累积四类债务:小文件(频繁小批量 INSERT)、高删除率文件(delete file 只标记
不回收空间)、过期 snapshot(元数据膨胀、旧文件无法回收)、以及盘上与元数据失联的文件
(失败/中断的写入留下的垃圾)。本篇覆盖偿还这些债务的全部维护操作,外加一个反方向的操作:
把已存在的外部 parquet 文件登记进表(`ducklake_add_data_files`)。

所有维护操作都以表函数形式暴露(注册机制见 10),`CHECKPOINT` 语句是它们的总入口:
`DuckLakeTransactionManager::Checkpoint`(`src/storage/ducklake_checkpoint.cpp:12-31`)在一个新建的
`Connection` 上**按固定顺序逐条执行六个 `CALL`**,每条是独立的查询(即独立事务/独立提交),
任何一条失败立刻抛错。顺序经过刻意安排(`:14-17` 注释):先 flush inlined data(可能产生大量
小文件,给 compaction 制造输入),再 expire snapshots(制造更多 compaction 机会),然后两个
compaction,最后才是两个删盘函数(它们消费前面步骤排入删除队列的文件)。`force` 参数被忽略。

```
CHECKPOINT (ducklake_checkpoint.cpp:18-21)
 │
 ├─1→ CALL ducklake_flush_inlined_data(cat)    inlined 行落盘为 parquet(详见 08)
 ├─2→ CALL ducklake_expire_snapshots(cat)      按 expire_older_than 过期旧 snapshot   ──┐
 ├─3→ CALL ducklake_merge_adjacent_files(cat)  小文件合并(无 delete 的 live 文件)   ──┤ 写入
 ├─4→ CALL ducklake_rewrite_data_files(cat)    高删除率文件重写(剔除被删行)         │ ducklake_files_
 ├─5→ CALL ducklake_cleanup_old_files(cat)     删盘:消费 scheduled_for_deletion  ←────┘ scheduled_for_deletion
 └─6→ CALL ducklake_delete_orphaned_files(cat) 删盘:data_path 与元数据对账,删孤儿文件
```

两个 compaction 函数的执行模型与众不同:它们不在表函数 execute 回调里干活,而是通过
`bind_operator` 直接产出一棵 **逻辑计划**(scan → sort → copy → 自定义 compaction 算子),
由 DuckDB 执行器并行执行,结果作为本地变更挂到事务 state,随事务提交统一落元数据(衔接 02/03)。
其余四个函数(expire/cleanup/orphan/add_files)是普通表函数,bind 阶段算好候选集,execute
第一次被调用时执行副作用。

### 关键源码位置

| 主题 | 位置 |
|---|---|
| CHECKPOINT 入口(六函数顺序) | `src/storage/ducklake_checkpoint.cpp:12-31` |
| compaction 表函数注册 / bind | `src/functions/ducklake_compaction_functions.cpp:849-897`、`:752-847` |
| 候选选择 `GetFilesForCompaction` | `src/storage/ducklake_metadata_manager.cpp:2150-2326` |
| 分组 + 贪心切分 `GenerateCompactions` | `src/functions/ducklake_compaction_functions.cpp:258-369` |
| 单条 compaction 计划构造 | `src/functions/ducklake_compaction_functions.cpp:453-671` |
| 逻辑算子 `DuckLakeLogicalCompaction` | `src/include/functions/ducklake_compaction_functions.hpp:44-95` |
| 物理算子 `DuckLakeCompaction` | `src/include/storage/ducklake_compaction.hpp:21-63`、`.cpp:75-190` |
| compaction 提交(元数据改写) | `src/storage/ducklake_transaction_state.cpp:626-709`、`:1534-1551`;`ducklake_metadata_manager.cpp:4802-4899` |
| partial_max 读取过滤 | `src/storage/ducklake_metadata_manager.cpp:1097-1104`;`ducklake_multi_file_reader.cpp:304-350` |
| expire_snapshots | `src/functions/ducklake_expire_snapshots.cpp`;`DeleteSnapshots` 在 `ducklake_metadata_manager.cpp:4902` 起 |
| cleanup_old_files / delete_orphaned_files | `src/functions/ducklake_cleanup_files.cpp`;`ducklake_metadata_manager.cpp:4624-4781` |
| add_data_files | `src/functions/ducklake_add_data_files.cpp`(全文件) |
| 维护相关配置项描述 | `src/functions/ducklake_options.cpp:13-42` |

## 关联文档

- [02 TRANSACTION_DESIGN](TRANSACTION_DESIGN.md) — 本地变更 state;`LocalTableDataChanges.compactions` 字段
- [03 COMMIT_PROTOCOL_DESIGN](COMMIT_PROTOCOL_DESIGN.md) — `merge_adjacent` / `rewrite_delete` 变更类型与并发冲突矩阵
- [04 METADATA_SCHEMA_DESIGN](METADATA_SCHEMA_DESIGN.md) — `ducklake_files_scheduled_for_deletion` 等数据字典
- [05 METADATA_MANAGER_DESIGN](METADATA_MANAGER_DESIGN.md) — `GetFilesForCompaction` 等接口全景
- [06 SCAN_DESIGN](SCAN_DESIGN.md) — name map 与 delete file/DV 的读取路径
- [07 DML_DESIGN](DML_DESIGN.md) — delete file 生成;文件命名 `ducklake-{uuidv7}`
- [08 DATA_INLINING_DESIGN](DATA_INLINING_DESIGN.md) — `ducklake_flush_inlined_data` 全流程
- [10 TABLE_FUNCTIONS_DESIGN](TABLE_FUNCTIONS_DESIGN.md) — 表函数注册框架

## 一、compaction 框架

### 1.1 两个入口与参数

`src/functions/ducklake_compaction_functions.cpp` 注册两个表函数,共享同一套 `BindCompaction`
框架,只是 `CompactionType` 不同:

- `ducklake_merge_adjacent_files(catalog [, table])`(`:858-873`),`MERGE_ADJACENT_TABLES`。
  named 参数:`min_file_size`、`max_file_size`、`max_compacted_files`(均 UBIGINT)、`schema`。
- `ducklake_rewrite_data_files(catalog [, table])`(`:884-897`),`REWRITE_DELETES`。
  named 参数:`delete_threshold`(DOUBLE)、`schema`。

两者都用 `function.bind_operator`(`:863`、`:889`)而非普通 bind:bind 阶段直接返回逻辑算子树。
`BindCompaction`(`:752-847`)解析参数后分两条路:

- 只给 catalog:遍历全部 schema 的全部表(`:797-814`),对每个 `auto_compact` 配置为 `"true"`
  (默认值即 `"true"`,`:805-806`)的表调 `GenerateCompaction`;
- 给了表名:只处理该表,同样受 `auto_compact` 门控(`:828-844`)。

多条 compaction 计划用 `Binder::UnionOperators` 拼成 UNION(`GenerateCompactionOperator`,
`:676-703`);没有任何候选时返回 `LogicalEmptyResult`。输出 schema 固定四列:
`schema_name, table_name, files_processed, files_created`。

`delete_threshold` 的取值优先级(`GetDeleteThreshold`,`:732-750`):显式参数 > 表/schema/全局级
`rewrite_delete_threshold` 配置 > 默认 0.95,且必须在 [0,1]。

target file size(`DuckLakeCatalog::GetTargetFileSize`,`src/storage/ducklake_catalog.cpp:1016-1028`):
session setting `ducklake_target_file_size` 优先,否则取 metadata 级配置 `target_file_size`,
默认 `DEFAULT_TARGET_FILE_SIZE = 1 << 29`(512 MiB,`src/include/storage/ducklake_catalog.hpp:86`)。

### 1.2 候选选择:GetFilesForCompaction

`DuckLakeMetadataManager::GetFilesForCompaction`(`src/storage/ducklake_metadata_manager.cpp:2150-2326`)
对单表发一条大 SQL:`ducklake_data_file` LEFT JOIN 三样东西——

1. `snapshot_ranges` CTE(`:2188-2199`):用窗口函数 `LEAD(begin_snapshot)` 把
   `ducklake_schema_versions` 转成 `[begin, next_begin)` 区间,按文件的 `begin_snapshot` 落区间
   求出每个文件的 `schema_version`;
2. 该表的全部 `ducklake_delete_file`(按 `data_file_id`,一个数据文件可关联多代 delete file);
3. `ducklake_file_partition_value` 聚合出的分区值数组。

结果 `ORDER BY data.begin_snapshot, data.row_id_start, data.data_file_id, del.begin_snapshot`
(`:2215`)——这个顺序就是后面 MERGE_ADJACENT "相邻"的定义基础。按类型加 WHERE:

- `REWRITE_DELETES`:只过滤 `data.end_snapshot IS NULL`(当前可见文件,`:2172-2176`);
  **删除率阈值在 C++ 侧算**(`:2306-2323`):活跃删除数 = 最后一代未关闭(`end_snapshot` 无效)
  delete file 的 `delete_count` + inlined 文件删除数(metadata-only 删除,见 08;`:2281-2290` 把
  完整 row-id 集合读进来,重写时要用),`delete_ratio = total_delete / row_count`,
  `ratio < threshold` 或无删除的文件被剔除。注意 `delete_threshold=0.95` 意味着默认只重写
  "几乎删光"的文件。
- `MERGE_ADJACENT_TABLES`:SQL 侧过滤 `file_size_bytes ∈ [min_file_size, effective_max)` 且
  `end_snapshot IS NULL`(`:2177-2186`);`effective_max` = 显式 `max_file_size`,否则 target file
  size。inlined 删除只做廉价存在性检查(`:2291-2304`),因为有删除的文件根本不参与 merge。

### 1.3 分组与"相邻"的确切定义

`DuckLakeCompactor::GenerateCompactions`(`compaction_functions.cpp:258-369`)把候选文件按
**compaction group** 分桶,group key = `(schema_version, partition_id, partition_values)`
(`DuckLakeCompactionGroup`,`:208-256`)。即:只有同一 schema 版本、同一分区的文件才可能合并。

MERGE_ADJACENT 在分桶前还要逐文件排除(`:277-287`):

- 文件自身 ≥ target size(REWRITE_DELETES 不受此限,delete file 必须重写);
- 带任何 delete file 或 inlined 删除的文件——**merge_adjacent 完全不处理删除**,内部还有
  防御性 `InternalException`(`:497-500`);
- `end_snapshot` 已设置(历史文件)。

随后两种类型分道:

- `REWRITE_DELETES`:每个 partition group 的全部候选打包成**一条** compaction 命令(`:296-313`)。
- `MERGE_ADJACENT_TABLES`:组内 ≥2 个文件才考虑;按候选列表顺序(即 SQL 的
  `begin_snapshot, row_id_start` 排序)贪心地把**连续**文件攒进一个 batch,直到累计大小达到
  target file size(`:317-368`);单文件 batch 跳过;`max_compacted_files` 限制本次处理的文件总数。

所以 **"相邻" = 同 (schema_version, partition) 组内、按 (begin_snapshot, row_id_start, file_id)
排序后位置连续**。row_id 是否连续不影响能不能合并,只影响产物怎么写(下一节):
`GenerateCompactionCommand` 里逐文件检查 `prev.row_id_start + prev.row_count == next.row_id_start`
(`:507-517`),全部连续则 `files_are_adjacent = true`。

### 1.4 计划构造:scan → (cast) → (sort) → copy → compaction 算子

`GenerateCompactionCommand`(`:453-671`)为一个 batch 构造逻辑计划:

1. **按文件的历史版本取表**:用第一个源文件的 `begin_snapshot` + `schema_version` 构造
   `DuckLakeSnapshot`,经 `catalog.GetEntryById` 拿到**当时**的表 entry(`:455-463`)——保证
   按写入时的 schema 读老文件。
2. **定制 file list**:把 batch 内文件(REWRITE_DELETES 时附带最后一代活跃 delete file 与
   inlined 删除 row-id 集,`:486-495`)塞进 `DuckLakeMultiFileList`,替换 scan bind data 的
   file list(`:476-525`)——scan 时 delete file 自然生效,被删行被剔除(读取机制见 06)。
3. **hive partition 路径**:分区表从首文件路径中截出 hive 目录段作为输出目录,并校验 batch 内
   所有文件同分区路径(`:531-551`)。
4. **虚拟列矩阵**(`:553-569`):

   | 类型 | write_row_id | write_snapshot_id |
   |---|---|---|
   | MERGE_ADJACENT | `!files_are_adjacent` | **true(总是)** |
   | REWRITE_DELETES | **true(总是)** | false |

   REWRITE_DELETES 因为被删行制造 row-id 空洞,必须把 `row_id` 物化进新文件;MERGE_ADJACENT
   若源文件 row-id 连续则免写(新文件继承 `source_files[0].row_id_start`,`:660-663`),但
   **总是**物化 snapshot_id 列——这是 time travel 的关键(见 1.6)。
5. **cast 投影**(类型需要转换时)与 **sort**(见 1.5)。
6. **`LogicalCopyToFile`**(`:632-658`):单文件输出(`per_thread_output=false`、`rotate=false`、
   `file_size_bytes` 置空)、`preserve_order`、`batch_size = DEFAULT_ROW_GROUP_SIZE`;文件名由
   filename pattern 生成,即 `ducklake-{uuidv7}.parquet`(见 07)。
7. 顶上挂 **`DuckLakeLogicalCompaction`**(`:666-670`)。

`DuckLakeLogicalCompaction` 是 `LogicalExtensionOperator`
(`src/include/functions/ducklake_compaction_functions.hpp:44-95`),`CreatePlan` 直接
`planner.Make<DuckLakeCompaction>`。物理算子 `DuckLakeCompaction`
(`src/include/storage/ducklake_compaction.hpp:21-63`)既是 sink 又是 source,`ParallelSink()`
返回 false。

### 1.5 sort key 重排

如果表配置了 `SET SORTED BY`,compaction 顺带做重排序。注意取 sort 配置用的是**最新**表 entry
(优先事务本地版本,否则最新 snapshot,`compaction_functions.cpp:612-630`),而不是文件写入时的
版本——改过 sort key 后,compaction 会按新 key 重排老文件。

- `ParseSortOrders`(`:37-47`):`DuckLakeSort.fields` 里只取 `dialect == "duckdb"` 的表达式,
  `Parser::ParseExpressionList` 解析成 `OrderByNode`;非 duckdb 方言全被跳过(全部跳过时直接
  返回原计划,`:378-381`)。
- `BindSortOrders`(`:50-70`):建 child binder,把表列以 generic binding 注入作用域,逐个
  `ExpressionBinder::Bind`。
- `InsertSort`(`:371-451`):校验 sort 表达式引用的列存在 → 绑定 → 可选追加
  `(row_id, snapshot_id)` 升序 tiebreaker → `LogicalOrder` + 透传 `LogicalProjection`。
  `add_tiebreakers` 默认 false(hpp `:93`),compaction 路径不加;只有
  `ducklake_flush_inlined_data` 传 true(`ducklake_flush_inlined_data.cpp:362`),用来让文件行序
  与 inlined 删除定位查询的 ORDER BY 严格一致。

### 1.6 产出登记与提交;time travel 语义(★)

**执行期**:`DuckLakeCompaction::Sink` 收集 copy 算子吐出的文件信息
(`DuckLakeInsert::AddWrittenFiles`,`ducklake_compaction_functions.cpp:133-137`);`Finalize`
(`:142-183`)断言**至多一个**输出文件(0 个仅当源行被删光,有行数核对),回填分区值,组装
`DuckLakeCompactionEntry{row_id_start, source_files, written_file, type}`,调
`transaction.AddCompaction`(`ducklake_transaction.cpp:1658`)挂到
`LocalTableDataChanges.compactions`(`src/include/storage/ducklake_transaction.hpp:51-59`)。
此后走普通事务提交(02);compaction 类型映射为 snapshot change `merge_adjacent` /
`rewrite_delete`(`ducklake_transaction.cpp:994-1005`;字符串定义
`src/include/storage/ducklake_metadata_info.hpp:37-39`),与并发 DELETE 的冲突判定见 03。

**提交期**(`DuckLakeTransactionState::GetCompactionChanges`,
`ducklake_transaction_state.cpp:626-709`;FlushChanges 调用点 `:1534-1551`)。每个
`DuckLakeCompactionEntry` 先做行数核对:全部源文件的 `row_count - 活跃 delete 数 - inlined 删除数`
之和不得超过新文件行数;无输出文件时该和必须为 0,否则 `InternalException`(`:672-704`)。
随后两种类型的元数据改写截然不同,导致 time travel 语义不同:

- **MERGE_ADJACENT** → `WriteMergeAdjacent`(`ducklake_metadata_manager.cpp:4802-4845`):
  源文件从 `ducklake_data_file` 及 stats/delete_file/partition_value/variant_stats **物理 DELETE
  行**,并 INSERT 进 `ducklake_files_scheduled_for_deletion`(之后由 cleanup 删盘)。旧文件
  没有版本链可言——**time travel 完全靠新文件自我描述**:
  - 新文件 `begin_snapshot` = 第一个源文件的 `begin_snapshot`(`ducklake_transaction_state.cpp:659-660`),
    不是提交 snapshot;
  - 新文件 `partial_max`(代码字段 `max_partial_file_snapshot`)= 所有源文件
    `max(max_partial_file_snapshot ?? begin_snapshot)`(`:646-664`,多源文件时才设置)——表示
    "此文件内混有截至该 snapshot 的多个版本的行";
  - 合并时每行物化了 `snapshot_id` 列(1.4),读取时若查询 snapshot < `partial_max`,
    `SetSnapshotFilter`(`ducklake_metadata_manager.cpp:1097-1104`)给 file entry 设
    `snapshot_filter_max`,multi file reader 在该文件上追加行级过滤
    `_ducklake_internal_snapshot_id <= snapshot_filter_max`
    (`ducklake_multi_file_reader.cpp:304-350`)。
  - 因此对旧 snapshot,time travel 读到的是**合并文件中按嵌入 snapshot_id 过滤后的行子集**,
    结果与合并前等价。该机制成立的前提正是 1.3 的排除规则:只合并无删除的 live 文件,行集合
    随 snapshot 单调递增,单边 `<=` 过滤即可重建任意历史。
- **REWRITE_DELETES** → `WriteDeleteRewrites`(`:4846-4888`):传统版本链。旧 data file 与其
  delete file 都 `UPDATE ... SET end_snapshot = <rewrite snapshot>`(不删行、不调度删盘),
  新文件 `begin_snapshot` = 提交 snapshot(`ducklake_transaction_state.cpp:643-645`)。旧 snapshot
  的 time travel 继续读旧文件 + delete file;旧文件的回收要等 expire_snapshots 判定
  `[begin, end)` 区间内无存活 snapshot 后才发生(见第二节)。
  另外,重写使表可能重新变为 delete-free,提交时会从重写后的文件集重算 EXACT 级全局
  stats(`:1553-1560` 附近,注释明确说明动机)。

一句话对比:**merge_adjacent 把历史折叠进单文件(行级 snapshot 过滤),rewrite_delete 保留
双版本(文件级 [begin, end) 可见性)**。

## 二、expire_snapshots

`src/functions/ducklake_expire_snapshots.cpp`。普通表函数:bind 算候选,execute 首次调用执行。

### 2.1 参数与候选选择

`DuckLakeExpireSnapshotsBind`(`:20-86`):

- `older_than`(TIMESTAMP_TZ)与 `versions`(UBIGINT 列表)互斥(`:51-55`);`dry_run` 布尔。
- 两者都没给时落到全局配置 `expire_older_than`(interval 字符串,如 `'1 week'`,以当前时间减
  interval 得 cutoff,`:68-77`);该配置默认为空 → **静默 no-op**(`:56-60`)。
- 过滤器永远带一条硬保护:`snapshot_id != (SELECT MAX(snapshot_id) FROM ducklake_snapshot)`
  (`:62-64`)——**最新 snapshot 任何条件下都不会被过期**(★核实)。
- 候选经 `GetAllSnapshots(filter)` 取回(`:81-83`,查询本体在
  `ducklake_metadata_manager.cpp:4594-4622`)。

execute(`:102-130`):非 dry_run 时第一次调用执行 `transaction.DeleteSnapshots`
(`ducklake_transaction.cpp:1485-1488`,纯转发给 metadata manager),并对每个被删 snapshot 的
`schema_version` 调 `DuckLakeCatalog::InvalidateSchemaCache`(`:114-117`)清 catalog 缓存;
然后把被过期的 snapshot 信息按 `ducklake_snapshots()` 的列格式吐出。

### 2.2 DeleteSnapshots:元数据回收语义(★)

`DuckLakeMetadataManager::DeleteSnapshots`(`ducklake_metadata_manager.cpp:4902` 起)是一连串
立即执行的元数据 DML(在当前 metadata 事务内):

1. 从 `ducklake_snapshot` 与 `ducklake_snapshot_changes` 删除目标 snapshot 行(`:4922-4932`)。
2. 找出**不再被任何存活 snapshot 引用的表**(`:4934-4949`):`ducklake_table` 中
   `end_snapshot IS NOT NULL` 且 `[begin_snapshot, end_snapshot)` 区间内已无存活 snapshot,
   且该 `table_id` 没有其他仍可见的版本行。
3. **data file 回收**(`:4969-5029`):`end_snapshot IS NOT NULL` 且区间内无存活 snapshot 的
   文件,或属于第 2 步死表的文件 → 从 `ducklake_data_file` + `ducklake_file_column_stats` +
   `ducklake_file_variant_stats` + `ducklake_file_partition_value` **物理 DELETE 行**,同时
   INSERT 进 `ducklake_files_scheduled_for_deletion`(带 `NOW()` 作 `schedule_start`)。
4. **delete file 回收**(`:5037-5093`):同样的 `[begin, end)` 无存活判定,外加"挂在第 3 步被
   回收的 data file 上"与"属于死表"两个条件;DELETE 行 + 排入删盘队列。
5. 死表的从属元数据(`ducklake_table_stats`/`ducklake_column`/`ducklake_sort_info`/
   `ducklake_schema_versions`/`ducklake_column_mapping` 等 12 张表)整体清掉,并 `DROP` 其
   inlined data 物理表(`:5096-5136`)。
6. views/schemas/tags/macros 按同样的 `[begin, end)` 无存活 snapshot 规则清理(`:5139-5152`),
   macro impl/parameters 按悬挂引用清理(`:5154` 起)。

★重点核实结论:**对 `begin/end` 落在被删快照区间的行,DeleteSnapshots 从不改写 begin/end 字段;
它只做"整行删除或保留"二选一**——判据统一是"`[begin_snapshot, end_snapshot)`(左闭右开)内
是否还存在任何存活 snapshot"。`end_snapshot IS NULL` 的行(当前版本)永远保留;保留的历史行
即使其 begin 指向已删 snapshot 也不修正,可见性判断只依赖存活 snapshot 集合落不落在区间内,
不要求区间端点对应的 snapshot 仍存在。

## 三、cleanup_old_files

`ducklake_cleanup_old_files` 与 `ducklake_delete_orphaned_files` 共享同一套实现
(`src/functions/ducklake_cleanup_files.cpp`),由 `CleanupType`(`OLD_FILES` / `ORPHANED_FILES`,
`src/include/storage/ducklake_metadata_info.hpp:45` 起)区分。

### 3.1 ducklake_files_scheduled_for_deletion 的生命周期

表结构:`(data_file_id, path, path_is_relative, schedule_start TIMESTAMPTZ)`
(`ducklake_metadata_manager.cpp:233`)。代码中 INSERT 共四处,即全部生产者(★核实):

| 生产者 | 场景 | 位置 |
|---|---|---|
| `DeleteOverwrittenDeleteFiles` | 同一 data file 的 delete file 被新一代 delete file 覆盖:旧 delete file 元数据行物理 DELETE + 旧文件排队删盘(07 已述,不是置 end_snapshot) | `ducklake_metadata_manager.cpp:3925-3961` |
| `WriteMergeAdjacent` | merge_adjacent 的源文件 | `:4802-4845` |
| `DeleteSnapshots` | expire 后不再被任何存活 snapshot 引用的 data file | `:5020-5028` |
| `DeleteSnapshots` | 同上,delete file | `:5085-5092` |

注意 `rewrite_data_files` **不直接**排队删盘——它只置 `end_snapshot`,旧文件要经
expire_snapshots 判死后才进队列。消费者唯一:`ducklake_cleanup_old_files`。

### 3.2 参数与执行

`CleanupBind`(`ducklake_cleanup_files.cpp:52-106`,两函数共用):

- `older_than`(TIMESTAMP_TZ)、`cleanup_all`(BOOLEAN)、`dry_run`。`cleanup_all` 与
  `older_than` 互斥;两者都缺时落到配置 `delete_older_than`,**默认 `"2 days"`**(`:59`);
  若该默认也被清空且无参数则报错(`:77-83`)。
- OLD_FILES 的过滤器:`WHERE schedule_start::TIMESTAMPTZ < '<cutoff>'`(`:22-25`);
  `cleanup_all` 时无过滤(全删)。
- 候选 = `GetOldFilesForCleanup`(`ducklake_metadata_manager.cpp:4624-4646`):直接 SELECT
  `ducklake_files_scheduled_for_deletion` 套过滤器,路径按相对路径规则还原。

执行(`DuckLakeCleanupExecute`,`:131-161`):非 dry_run 首次调用时
`fs.RemoveFiles(paths)` 批量删盘,**仅 OLD_FILES** 随后调 `RemoveFilesScheduledForCleanup`
(`ducklake_metadata_manager.cpp:4765-4781`)按 `data_file_id` 从队列表删行;输出列只有 `path`。
删盘与元数据出队不是原子的:进程在两步之间挂掉会留下"队列里有、盘上已无"的行,下次 cleanup
对不存在文件的 `RemoveFiles` 行为取决于文件系统实现。

## 四、delete_orphaned_files

同一文件实现,`CleanupType::ORPHANED_FILES`。orphan 的定义与对账逻辑在
`GetOrphanFilesForCleanup`(`ducklake_metadata_manager.cpp:4687-4751`):

1. **已知文件全集**(`GetKnownFilesForCleanupQuery`,`:4648-4685`):
   `ducklake_data_file` ∪ `ducklake_delete_file`(各自按 schema/table/file 三级
   `path_is_relative` 规则拼出绝对路径)∪ `ducklake_files_scheduled_for_deletion`。
   注意三者都是**全表**,不带 snapshot 过滤——历史文件、已排队待删文件都算"已知"。
2. 已知集合灌进临时表 `__ducklake_known_cleanup_files`(Appender,`:4700-4723`)。
3. 扫描 data path:`read_blob({DATA_PATH} || '**')` 列出全部对象,**只看 `.parquet` 后缀**,
   `NOT EXISTS` 于已知集合者为 orphan(`:4725-4732`);最后拼上时间过滤
   ` AND last_modified::TIMESTAMPTZ < '<cutoff>'`(`ducklake_cleanup_files.cpp:26`)。

什么算 orphan:**data path 下存在、但三张元数据表都不认识的 `.parquet` 文件**。典型来源是
写到一半失败/回滚的事务留下的文件。非 `.parquet` 后缀的对象永远不会被当 orphan 删除。

执行路径与 cleanup_old_files 相同(`fs.RemoveFiles`),但**不写任何元数据**(orphan 本来就不在
元数据里,`:146-151` 的出队只对 OLD_FILES 生效)。

★风险与时间窗核实:**唯一的并发保护就是 `older_than` 时间窗**。in-flight 事务已写盘、尚未提交
的数据文件不在任何元数据表里,对账时必然被判为 orphan;靠的是默认 cutoff = now - `delete_older_than`
(`"2 days"`)且过滤条件作用在对象的 `last_modified` 上——刚写出的文件足够"新",不会落入删除
窗口。没有 lease、锁或其他机制;**`cleanup_all => true` 会绕过时间窗,在有并发写入时可能误删
未提交文件**(候选集在 bind 阶段一次性确定,bind 与删盘之间提交的文件同样有窗口期暴露,只是
被 last_modified 保护)。把 `delete_older_than` 调小到低于最长事务写入时长同样不安全。

## 五、add_data_files

`src/functions/ducklake_add_data_files.cpp`(1288 行)。把**已存在**的外部 parquet 文件登记进
DuckLake 表:不搬移、不重写文件,只解析 footer、做 schema 校验、生成 name map 与 stats,然后
走与 INSERT 完全相同的提交通道。

### 5.1 签名与参数(★核实实际参数集)

`ducklake_add_data_files(catalog, table_name, path_or_list)`,第三参数接受 VARCHAR 或
`LIST(VARCHAR)`,均可含 glob(`:50-63`、`:1273-1286`)。named 参数共四个(`:64-76`):

- `allow_missing`(默认 false):表里有、文件里没有的列放行(读取时补 NULL);
- `ignore_extra_columns`(默认 false):文件里有、表里没有的列放行(读取时忽略);
- `hive_partitioning`(BOOLEAN):三态——不传 = `AUTOMATIC`,显式 true/false = `YES`/`NO`
  (`:19`、`:70-72`)。`AUTOMATIC` 与 `YES` 在现行代码中行为一致:`DetermineMapping` 只判
  `!= NO` 就解析路径中的 hive 键值对(`:1185-1189`);
- `schema`。

多个 glob 重叠时按规范化路径去重(`processed_files`,`:243-248`)。

### 5.2 footer 解析:用什么 reader

不直接调 parquet reader C++ API,而是**发 SQL 走 DuckDB parquet 扩展的
`parquet_full_metadata()` 表函数**(`ReadParquetFullMetadata`,`:170-201`),一次取回三个 list:
file metadata(行数/文件大小/footer 大小)、列级 metadata(min/max/null_count/num_values/
压缩大小/geo_bbox/geo_types)、parquet schema(name/type/converted_type/scale/precision/
field_id/logical_type)。然后手工重建列树:利用每个 schema 元素的 `num_children` 维护栈,
跳过合成 root,叶子列按出现序分配 `column_id`(`:295-363`)。

### 5.3 类型校验与提升规则

`DuckLakeParquetTypeChecker`(`:502-845`)。先 `DeriveLogicalType`(`:541-637`)从 parquet
physical/converted/logical type 还原出 DuckDB 类型(代码自注 FIXME:基本照抄 DuckDB parquet
reader),再与表列类型按以下规则匹配(不匹配抛 `InvalidInputException`,带逐列失败明细):

- 有符号整型(`:676-701`):接受同宽及更窄的有符号、以及窄一级的无符号——如 BIGINT 列接受
  BIGINT/UINTEGER/INTEGER/USMALLINT/SMALLINT/UTINYINT/TINYINT;
- 无符号整型(`:703-725`):只接受同宽及更窄的无符号;
- FLOAT/DOUBLE(`:727-743`):DOUBLE 列接受 FLOAT;
- timestamp 族(`:745-757`):TIMESTAMP/TIMESTAMP_NS 列额外接受 NS,所有 timestamp 列接受
  TIMESTAMP/MS/SEC;TIMESTAMP_TZ 走精确匹配;
- DECIMAL(`:759-775`):要求文件的 precision ≤ 表、scale ≤ 表;
- JSON、GEOMETRY 特判(GeoParquet v1 明确拒绝,只认 parquet 原生 GEOMETRY,`:777-795`);
- STRUCT/LIST/MAP 只要求类型 id 相同,随后递归校验子列;其余类型精确匹配(`:797-844`)。

### 5.4 name map 生成(★无 field id 的文件)

映射是**纯按列名**的(case-insensitive):`MapColumns`(`:1091-1143`)把表的 `field_ids` 建成
名字索引,逐个文件列查找;命中后 `MapColumn`(`:847-901`)生成
`DuckLakeNameMapEntry{source_name → target_field_id}` 并递归处理子列(LIST/MAP 剥掉 parquet
的 REPEATED 中间层、legacy avro `array` 布局兼容,`:874-894`)。文件 footer 里即使带 field_id
也只是被读出存放(`:326-328`),**映射不使用它**——所以"无 field id 的 parquet"与有 field id
的走同一条路:整张表的列名→field id 对应关系封装成 `DuckLakeNameMap`,经
`transaction.AddNameMap(std::move(name_map))` 注册(`:1209`,06 篇已确认这是 `AddNameMap` 的
唯一调用点;实现 `ducklake_transaction.cpp:2067` 起,会先尝试复用已有的兼容 map),返回的
`mapping_id` 记到该文件的元数据行,扫描时按 name map 重定向列(06)。

多余列/缺失列的处理顺序(`:1101-1141`):文件列在表里找不到 → `ignore_extra_columns` 或报错;
表列在文件里找不到 → 先查 hive partition 值,再 `allow_missing` 或报错。

### 5.5 hive partition 推断(★)

存在,且与表的 partition 配置联动:

- `HivePartitioning::Parse(file.filename)` 从路径提取 `k=v` 段(`:1186-1189`);
- identity 分区/普通列:`MapHiveColumn`(`:910-938`)把 hive 字符串值 cast 到列类型(失败报错,
  嵌套类型拒绝),生成 `hive_partition=true` 的 name map entry(该列不在文件数据里,值来自路径);
- 非 identity transform(YEAR/MONTH/DAY/HOUR/BUCKET):`MapPartitionColumns`(`:1145-1183`)按
  partition key 命名规则匹配路径段,推断出分区值(BUCKET 的 stats 不可用);
- 表配置了 partition 时,`AddFileToTable` 校验文件提供的 hive 值与表分区字段**一一对应**,
  否则 `InvalidInputException`(`:1211-1244`),并填充 `partition_values` / `partition_id`。

### 5.6 stats 来源与入账

**不扫数据**:列 stats 全部来自 footer 的 row-group 级统计,`MapColumnStats`(`:940-1089`)
跨 row group 聚合(null_count/num_values 求和,min/max 数值类型 cast 后比较、字符串按字典序,
geo bbox/types 合并);hive 分区列的 stats 直接 min=max=分区值、NULL 分区则全 NULL(`:1062-1088`)。
任一 row group 缺某项统计则整文件该项标记缺失。

入账:`AddFileToTable` 产出 `DuckLakeDataFile`,`created_by_ducklake = false`(`:495`);
**行数为 0 的文件直接跳过不登记**(`:496-498`)。execute 里
`transaction.AppendFiles(table_id, files)`(`:1269` → `ducklake_transaction.cpp:1599-1603`)挂到
`LocalTableDataChanges.new_data_files`——与普通 INSERT 同一通道,随事务提交写
`ducklake_data_file` 等表(02/03)。

## 六、auto_compact 与维护策略配置

`auto_compact` 是 metadata 级配置(`CALL <cat>.set_option('auto_compact', ...)`,可按 schema/
table 覆盖;合法值校验在 `ducklake_set_option.cpp:154` 起),官方描述见
`ducklake_options.cpp:33-35`。★核实:**它不是"commit 后自动跑 compaction"的开关**——DuckLake
没有任何提交后自动维护的触发器;`auto_compact` 只是三个维护函数在批量模式下的 per-table 过滤器:

| 消费点 | 位置 |
|---|---|
| `ducklake_flush_inlined_data` 遍历表时跳过 `!= "true"` 的表 | `ducklake_flush_inlined_data.cpp:644-647` |
| `ducklake_merge_adjacent_files` / `ducklake_rewrite_data_files` 全库与单表两条路径 | `ducklake_compaction_functions.cpp:805-806`、`:832-840` |

默认值是字符串 `"true"`,即默认所有表都参与 CHECKPOINT 触发的维护;设为 false 的表连显式
`CALL ducklake_merge_adjacent_files(cat, 'tbl')` 都会被跳过(`:840-844` 的 gate 对单表路径同样
生效)。`ducklake_flush_inlined_data` 本身(inlined 数据如何选出、flush 计划如何构造、为何无
`chunk_size` 参数)详见 08,本篇不展开。

维护相关配置默认值汇总(均经 `GetConfigOption` 支持 global/schema/table 三级覆盖):

| 配置 | 默认 | 消费者 | 位置 |
|---|---|---|---|
| `auto_compact` | `"true"` | flush / merge / rewrite 的 per-table gate | 见上表 |
| `target_file_size` | 512 MiB(`1<<29`);session setting `ducklake_target_file_size` 优先 | merge_adjacent 的目标大小与候选上限;INSERT 写文件 | `ducklake_catalog.cpp:1016-1023`、`catalog.hpp:86` |
| `rewrite_delete_threshold` | 0.95 | rewrite_data_files 的删除率阈值(参数 `delete_threshold` 优先) | `ducklake_compaction_functions.cpp:732-750` |
| `expire_older_than` | 空(→ 无参 expire 为 no-op) | expire_snapshots 的默认 cutoff interval | `ducklake_expire_snapshots.cpp:31`、`:56-60` |
| `delete_older_than` | `"2 days"` | cleanup_old_files / delete_orphaned_files 的默认 cutoff interval | `ducklake_cleanup_files.cpp:59` |

运维直觉:`CHECKPOINT` 的六步默认行为 = flush 全部 inlined 数据;expire 什么都不做(除非配了
`expire_older_than`);合并小文件;重写删除率 ≥95% 的文件;删掉排队超过 2 天的旧文件;删掉
2 天前遗留的孤儿文件。要让 CHECKPOINT 真正回收历史,先 `set_option('expire_older_than', ...)`。
