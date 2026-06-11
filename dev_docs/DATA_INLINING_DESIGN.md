# DuckLake Data Inlining 子系统设计(DATA_INLINING_DESIGN)

> 行号基准:commit `47187559`(分支 local_dev)。

## 概述

DuckLake 的所有表数据正常落在 parquet 文件中,但 lakehouse 负载里大量出现"每次只插几行"的
小写入:若每个小事务都产出一个 parquet 文件,既造成小文件爆炸,也让每次写入背上一次对象存储
round-trip。data inlining 的思路是:**当一次写入的行数不超过阈值(`data_inlining_row_limit`,
默认 10)时,数据不写 parquet,而是以 SQL 行的形式直接写进 metadata catalog 里一张
per-table 的动态表** `ducklake_inlined_data_<table_id>_<schema_version>`。这些行对读路径伪装成
一个特殊"文件"混进 MultiFileList,后续由 `CALL ducklake_flush_inlined_data()` 批量落成
parquet(checkpoint 会自动调用,见 09)。

数据流全景:

```
INSERT/UPDATE/MERGE plan
        |
        v
  DuckLakeInlineData (operator, 三阶段状态机)
        |--- 行数 <= limit: 截留进 ColumnDataCollection --> OperatorFinalize
        |                                                      |
        |--- 超限: 回吐已积累行 + pass-through                  v
        v                                   DuckLakeTransaction::AppendInlinedData
  COPY TO parquet --> DuckLakeInsert            (LocalTableDataChanges.new_inlined_data)
                                                       |
                          commit ----------------------+
                          |  WriteNewInlinedData: INSERT INTO
                          |    {METADATA_CATALOG}.ducklake_inlined_data_<tid>_<sv>
                          |    (row_id, begin_snapshot, end_snapshot=NULL, <user cols>)
                          v
            +--------------------------------+
            | metadata catalog               |     读路径 (06 入口)
            |  ducklake_inlined_data_tables  | --> DuckLakeMultiFileList 附加
            |  ducklake_inlined_data_<t>_<v> |     "伪文件" entry (INLINED_DATA /
            |  ducklake_inlined_delete_<t>   |      TRANSACTION_LOCAL_INLINED_DATA)
            +--------------------------------+ --> DuckLakeInlinedDataReader
                          |
                          v
       CALL ducklake_flush_inlined_data(): SCAN_FOR_FLUSH 全量扫
         --> COPY 写 parquet(携带显式 row_id/snapshot_id 列)
         --> 删除行转 delete file --> DELETE FROM 内联表
         --> 提交后 DropEmptySupersededInlinedTables
```

关键源码位置:

| 模块 | 文件 |
|---|---|
| 写入侧算子 `DuckLakeInlineData` | `src/storage/ducklake_inline_data.cpp` |
| 事务内形态 `DuckLakeInlinedData` | `src/storage/ducklake_inlined_data.cpp` / `src/include/storage/ducklake_inlined_data.hpp` |
| 事务本地变更容器 | `src/storage/ducklake_transaction.cpp:197-308` |
| 提交 SQL 生成 | `src/storage/ducklake_metadata_manager.cpp:2550-2935` |
| 读取侧 reader | `src/storage/ducklake_inlined_data_reader.cpp` |
| 伪文件注入 | `src/storage/ducklake_multi_file_list.cpp` / `ducklake_multi_file_reader.cpp` |
| flush | `src/functions/ducklake_flush_inlined_data.cpp` |
| 配置解析 | `src/storage/ducklake_catalog.cpp:998-1042` |

## 关联文档

- 01 ATTACH_CATALOG_DESIGN.md:`data_inlining_row_limit` 的 catalog/schema/table 作用域解析。
- 02 TRANSACTION_DESIGN.md:`LocalTableDataChanges` 等本地变更 state 的总体结构。
- 03 COMMIT_PROTOCOL_DESIGN.md:提交协议;`GetRequiresNewInlinedTable()` 对 server-side commit 的影响、冲突矩阵。
- 05 METADATA_MANAGER_DESIGN.md:各后端(postgres/sqlite/quack)metadata manager 差异。
- 06 SCAN_DESIGN.md:读路径主链,内联"伪文件"的混入入口。
- 07 DML_DESIGN.md:INSERT/DELETE/UPDATE 主链。
- 09 MAINTENANCE_DESIGN.md:CHECKPOINT 中对 flush 的调用。
- 10 TABLE_FUNCTIONS_DESIGN.md:`ducklake_table_insertions/deletions` 等 CDC 函数。

## 一、写入侧:DuckLakeInlineData 算子

### 1.1 插入位置

`DuckLakeInlineData` 是一个 `PhysicalOperatorType::EXTENSION` 的中间算子(非 sink),输出类型与
child 完全一致(`ducklake_inline_data.cpp:15-19`)。它由四个 plan 函数构造,统一插在
**数据源 plan 与 `DuckLakeInsert::PlanCopyForInsert` 生成的物理 COPY 之间**:

- `DuckLakeCatalog::PlanInsert`(`ducklake_catalog.cpp:813-816`);
- `DuckLakeCatalog::PlanCreateTableAs`(CTAS,`ducklake_catalog.cpp:847-851`,此时表尚无
  table id,用 schema 级配置 + `CanInlineColumns(columns)` 判定);
- `DuckLakeCatalog::PlanUpdate`(`ducklake_update.cpp:274-277`,见第五节);
- MERGE INTO 的 update 分支(`ducklake_merge_into.cpp:455-458`)。

构造后把同一 plan 里的 `DuckLakeInsert` sink 回填给 `inline_data->insert`
(`ducklake_catalog.cpp:832-834`),供 `OperatorFinalize` 直接操作 insert 的 global sink state。
与 `sort_on_insert` 的互动:`sort_on_insert=true` 时排序在 inline 算子之前;`=false` 但启用
inlining 时,排序插在 inline 算子**之后**——被截留的行不经过排序,只有超限 pass-through 进
parquet 的行才需要排序(`ducklake_catalog.cpp:818-827`)。

### 1.2 三阶段状态机

每线程 `InlineDataState` 持有 `phase` 与本线程的 `ColumnDataCollection inlined_data`;全局
`InlineDataGlobalState` 持锁维护 `total_inlined_rows` 与 `global_inlined_data`
(`ducklake_inline_data.cpp:21-70`)。`enum class InlinePhase`(line 21):

- **INLINING_ROWS**:初始态。每个 input chunk 先经 `AddRows` 把行数累进全局计数
  (line 38-51):若 `total_inlined_rows > inline_row_limit` 则越限——把已沉淀到全局的
  `global_inlined_data` 挪回当前线程的本地 collection,转入回吐;否则把 chunk append 进本线程
  collection 并返回 `NEED_MORE_INPUT`(line 114-119),行被"吃掉"不向下游输出。
- **EMITTING_PREVIOUSLY_INLINED_ROWS**:决定不内联后的**回吐**态。对本地 collection 起 scan,
  逐 chunk 以 `HAVE_MORE_OUTPUT` 吐还给下游 COPY(line 89-98);吐完销毁 collection 转
  PASS_THROUGH。注意阈值判断在 `AddRows` 中是先累加再比较,因此一旦越限,**本批连同之前截留的
  所有行全部回吐**,不存在"前 N 行内联、其余写文件"的拆分。
- **PASS_THROUGH_ROWS**:直接 `chunk.Reference(input)` 透传(line 84-88)。

`FinalExecute`(line 122-151)处理 source 耗尽时的收尾:持全局锁复查计数,若全局已越限则本线程
也转入回吐(line 143-147,覆盖"别的线程把总数顶爆"的情形);否则把本地 collection 合并进
`global_inlined_data`。由于计数是全局的,**并行 pipeline 下阈值语义是整条 INSERT 的总行数**,
而非 per-thread。

### 1.3 OperatorFinalize:统计、约束与移交

pipeline 完成后 `OperatorFinalize`(line 320-407)执行:

1. 若无全局内联数据直接结束;否则懒初始化 `insert->sink_state`(line 328-334)。此时 COPY 没有
   收到任何行,故 `DuckLakeInsertGlobalState.total_insert_count` 必为 0,否则抛
   `"Inlining rows but also inserting rows through a file"`(line 336-338)——内联与写文件在
   单条 INSERT 内互斥。
2. 对前 `PhysicalColumnCount()` 列逐 chunk 计算列统计(line 349-356):`GetVectorStats`
   (line 242-261)把向量 cast 成 VARCHAR 再求 min/max(数值类型经
   `StatsNumericFallbackOperator` 按原类型语义比较),FLOAT/DOUBLE 额外算 `contains_nan`;嵌套
   类型(STRUCT/LIST/MAP,VARIANT 除外)递归到子字段(`UpdateStats`,line 263-309)。同时校验
   NOT NULL 约束(line 357-369)——内联路径不经过 parquet writer,约束检查必须在这里补。
3. 若 collection 列数多于物理列(UPDATE/MERGE 内联,child 输出额外带 row_id 列):把第
   `physical_col_count` 列抽成 `result->row_ids`,并把数据裁剪回纯物理列(line 371-395)。
4. 若 `table.GetInlinedDataTables()` 为空(该表还没有任何内联数据表),
   `transaction.SetRequiresNewInlinedTable(true)`(line 403-404)——本次提交需要 DDL 建表,
   这会禁用 server-side commit(见 3.4)。最后 `transaction.AppendInlinedData(table_id, result)`
   移交事务(line 406)。

### 1.4 阈值来源:GetInliningLimit

`DuckLakeCatalog::GetInliningLimit`(`ducklake_catalog.cpp:1030-1042`)=
`DataInliningRowLimit(context, schema_id, table_id)`,再叠加
`metadata_manager.CanInlineColumns(table.GetColumns())` 类型门槛(不满足则返回 0 → 不插算子)。
`DataInliningRowLimit`(line 1002-1014)的解析顺序:

1. catalog 持久化配置 `data_inlining_row_limit`(table > schema > catalog 作用域,经
   `TryGetConfigOption`;来源是 ATTACH 选项 `ducklake_storage.cpp:35-36` 或
   `ducklake_set_option`,作用域细节见 01);
2. 否则 DuckDB 全局 setting `ducklake_default_data_inlining_row_limit`;
3. 否则硬编码 **10**。

注意:extension 注册的 `ducklake_default_data_inlining_row_limit` 默认值即 `UBIGINT(10)`
(`ducklake_extension.cpp:35-37`),即 **当前 HEAD 上 inlining 默认开启**(上游 commit
`d18f5726` "Adjustments to make default inlining happen" 引入);设为 0 才是关闭。

## 二、事务内形态:DuckLakeInlinedData

`src/include/storage/ducklake_inlined_data.hpp:17-43`:

```cpp
struct DuckLakeInlinedData {
	unique_ptr<ColumnDataCollection> data;        // 内联行本体(仅物理列)
	idx_t external_row_count = 0;                 // data 为空时的显式行数(server-side commit
	                                              //   读 staged 表只拿计数,见 ducklake_server_side_commit.cpp:355-373)
	map<FieldIndex, DuckLakeColumnStats> column_stats; // 1.3 算出的列统计,提交时并入全局 stats
	vector<int64_t> row_ids;                      // UPDATE 内联保留下来的 row_id;空 = 普通 INSERT
};
struct DuckLakeInlinedDataDeletes { set<idx_t> rows; };          // 对内联行的删除(row_id 集合)
struct DuckLakeInlinedFileDeletes { map<idx_t, set<idx_t>> file_deletes; }; // file_id -> 删除行号(第五节)
```

挂载点是 `LocalTableDataChanges`(`ducklake_transaction.hpp:51-59`,总体结构归 02):
`new_inlined_data`(每表一份)、`new_inlined_data_deletes`(按内联表名分桶)、
`new_inlined_file_deletes`。

行为(`ducklake_inlined_data.cpp:7-63`):

- `HasPreservedRowIds()`:`row_ids` 非空,即数据来自 UPDATE/MERGE。
- `GetRowId(pos)` / `GetOutputRowId(pos)`:无保留 row_id 时,事务本地行的逻辑 row_id 就是
  ordinal;对外输出 row_id 为 `TRANSACTION_LOCAL_ROW_ID_START + pos`。
  `DuckLakeConstants::TRANSACTION_LOCAL_ROW_ID_START = 10^18`(`src/include/common/index.hpp:19`,
  02 已核),用于把事务本地行的 row_id 空间与已提交行隔开。
- `MergeRowIds(new_data, n)`(line 32-63):同事务先 UPDATE 后 INSERT(或反之)时合并两份数据的
  row_id 语义——一旦任一侧有保留 row_id,另一侧按 `TRANSACTION_LOCAL_ROW_ID_START` 起补发
  顺序 id,保证 `row_ids` 与 collection 行一一对应。

`LocalTableChanges::AppendInlinedData`(`ducklake_transaction.cpp:197-245`)做同表多次内联的
合并:若两批类型不一致(同事务内 `ALTER COLUMN TYPE` 后再插),先把旧 collection 整体 cast 到
新类型(line 207-226);随后追加 chunk、`MergeRowIds`、逐列 `MergeStats`。同事务的
ADD/DROP COLUMN 也会就地改写本地内联数据
(`AddColumnToLocalInlinedData`/`RemoveColumnFromLocalInlinedData`,
`ducklake_transaction.cpp:317-364`、`ducklake_transaction.hpp:83-86`):新列按 default 或 NULL
补一个常量向量。读取用的 `GetTransactionLocalInlinedData` 返回**深拷贝**
(`ducklake_transaction.cpp:118-137`),避免 scan 期间被本事务后续 DML 改写。

## 三、提交落库

### 3.1 物理表与注册表

每张用户表对应零或多张内联数据表,表名
`ducklake_inlined_data_<table_id>_<schema_version>`(`InlinedTableNameFor`,
`ducklake_metadata_manager.cpp:2550-2552`),DDL(`InlinedTableDdlSql`,line 2554-2558):

```sql
CREATE TABLE IF NOT EXISTS {METADATA_CATALOG}.ducklake_inlined_data_<tid>_<sv>(
    row_id BIGINT, begin_snapshot BIGINT, end_snapshot BIGINT, <user columns...>);
```

行可见性是左闭右开 `[begin_snapshot, end_snapshot)`:`ReadInlinedData` 的谓词为
`{SNAPSHOT_ID} >= begin_snapshot AND ({SNAPSHOT_ID} < end_snapshot OR end_snapshot IS NULL)`
(line 3128-3139)。所有内联数据表登记在 `ducklake_inlined_data_tables(table_id, table_name,
schema_version)`(line 2560-2563、2672;表结构归 04),table entry 加载时填进
`DuckLakeTableEntry::inlined_data_tables`(`ducklake_table_entry.hpp:78-79,184`)。

**为何表名带 schema_version**:用户列直接成为该表的物理列,schema evolution(加列/删列/改类型)
后旧表的列布局不再匹配;DuckLake 不迁移旧表,而是在下次内联写入时按新 schema_version 建新表,
新旧并存、各自按其版本的 schema 读取(读取侧见 4.2),旧表待 flush 清空后删除(见 6.5)。

### 3.2 commit 时的 SQL 生成

提交时 `GetNewDataFiles` 把每表的 `new_inlined_data` 包装成
`DuckLakeInlinedDataInfo {table_id, row_id_start, data}`
(`ducklake_transaction_state.cpp:988-1017`;struct 定义
`ducklake_metadata_info.hpp:173-177`):`row_id_start` 取自全局 stats 的 `next_row_id`;
普通 INSERT 把 `next_row_id` 推进 `record_count`,而保留 row_id 的混合数据只为其中事务本地
id(≥ 10^18)分配新号(line 1004-1014)。若本次只有内联变更,仍强制 `next_file_id++` 以制造
snapshot 的数据变更信号(line 1019-1022)。

`WriteNewInlinedData`(`ducklake_metadata_manager.cpp:2766-2846`)生成实际 INSERT:

1. 定位目标表:优先本次提交刚注册的新表,其次 per-transaction cache,否则查
   `LatestInlinedTableQuery`(取该 table_id 下 `MAX(schema_version)` 的表,line 2565-2571)。
2. 若不存在(首次内联):`commit_snapshot.schema_version++`(line 2826)并就地生成
   `ducklake_inlined_data_tables` 注册 INSERT + `CREATE TABLE`(`GetInlinedTableQueries`,
   line 2624-2636)。普通 `CREATE TABLE` 提交也会为启用 inlining 的新表预建内联表
   (`WriteNewInlinedTables`,line 2638-2675,跳过类型不可内联或事务本地的表)。
3. 数据经 `DuckLakeUtil::ChunkRowToSQL` 逐行转 SQL 字面量,由 `FormatInlinedDataInsert`
   (line 2848-2872)拼成
   `INSERT INTO {METADATA_CATALOG}.<tbl> VALUES (<row_id>, {SNAPSHOT_ID}, NULL, <cells>...)`;
   保留 row_id 的行用原值,事务本地 id 重编号为 `row_id_start++`(line 2856-2864)。代码自注
   `FIXME: we can do a much faster append than this`——目前是纯文本 VALUES 批。

snapshot 变更记录写入 `inlined_insert:<table_id>`(`ducklake_transaction_state.cpp:388`),
冲突检测上等价于一次插入(协议归 03)。

### 3.3 RequiresNewInlinedTable 与 server-side commit

quack(server)后端可把 data-only commit 整体下推服务端执行,但服务端的 `ducklake_commit`
无法替客户端创建内联表。因此 `QuackMetadataManager::CanSkipSnapshotFetch` 与
`FlushChangesServerSide` 在 `transaction.GetRequiresNewInlinedTable()` 为 true 时强制回落
client-side `RunCommitLoop`(`src/metadata_manager/quack_metadata_manager.cpp:94-108`)。
置位点有二:首次内联写入(1.3 第 4 步)和首次内联 file delete(第五节,
`ducklake_delete.cpp:515-519`)。commit/rollback 后复位(`ducklake_transaction.cpp:745,756`)。
协议细节归 03。

## 四、读取侧:DuckLakeInlinedDataReader

### 4.1 伪装成文件混入 MultiFileList

`DuckLakeMultiFileList::GetFilesForTable`(`ducklake_multi_file_list.cpp:318-375`)在真实
parquet 列表之后追加:每张已提交内联表一个 entry(`file.path = 表名`,
`data_type = INLINED_DATA`,`row_id_start = 0`——row_id 物化在表里,不需要偏移);若事务有本地
内联数据,再追加一个 `DUCKLAKE_TRANSACTION_LOCAL_INLINED_FILENAME`
(`"__ducklake_inlined_transaction_local_data"`,`ducklake_multi_file_list.hpp:23-24`)entry,
`data_type = TRANSACTION_LOCAL_INLINED_DATA`,row_id 起点在 `TRANSACTION_LOCAL_ROW_ID_START`
之后顺延。`GetFile`(line 148-179)把身份信息塞进 `OpenFileInfo.extended_info->options`:
`inlined_data=true`,已提交表带 `table_name` + `schema_version`,本地数据带
`transaction_local_data=true`。`GetFilesExtended`(line 257-316)为 DELETE 路径生成同构列表。
入口与主链归 06。

`DuckLakeMultiFileReader::CreateReader` 对每个"文件"先试
`TryCreateInlinedDataReader`(`ducklake_multi_file_reader.cpp:356-401,403-422`):

- 本地数据:直接包 `transaction.GetTransactionLocalInlinedData()` 的 collection;
- 已提交表:若 `schema_version` 非当前版本,先用
  `GetBeginSnapshotForSchemaVersion` 取**该版本时点的 table entry**,用旧 schema 的字段定义构造
  reader 列(line 374-392)——这正是 schema 变更后旧内联表仍可读的机制:列匹配走
  `BY_FIELD_ID` mapping(line 228),缺列由 `MultiFileColumnDefinition.default_expression`
  (`initial_default`,line 191-210)补默认值,与读旧 parquet 完全同构;
- 列表前部插入两个虚拟列定义 `_ducklake_internal_row_id`(identifier=`ROW_ID_FIELD_ID`)与
  `_ducklake_internal_snapshot_id`(identifier=`LAST_UPDATED_SEQUENCE_NUMBER_ID`)
  (line 160-163、394-396)。

### 4.2 已提交内联表的扫描

`TryInitializeScan`(`ducklake_inlined_data_reader.cpp:26-184`)对已提交表的路径
(line 36-154)是**把列投影直接下推成对 metadata catalog 的 SQL**:

- 按 `column_indexes` 逐列翻译:row_id 虚拟列 → `row_id` 物理列;snapshot 虚拟列 →
  `begin_snapshot`(SCAN_DELETIONS 时为 `end_snapshot`,line 55-62);非 duckdb 系 metadata
  catalog(postgres/mysql 等)对非 VARCHAR 列追加 `CastColumnToTarget` 显式 cast
  (line 72-81,后端差异归 05)。
- 空投影(`COUNT(*)`)退化为只扫 `row_id` 且标记 `COLUMN_EMPTY` 不输出(line 97-102)。
- 按 `read_info.scan_type` 选择四种 SQL 之一(line 109-127;SQL 体见
  `ducklake_metadata_manager.cpp:3128-3180`):
  `SCAN_TABLE`(快照可见行,`ORDER BY row_id`)、`SCAN_INSERTIONS`(`begin_snapshot` 落在
  `[start, end]` 窗口)、`SCAN_DELETIONS`(`end_snapshot` 落在窗口)、`SCAN_FOR_FLUSH`
  (见 6.2)。结果经 `TransformInlinedData` 物化为 `ColumnDataCollection`
  (line 3094-3112;postgres 子类对 BLOB→VARCHAR 做 reinterpret,
  `postgres_metadata_manager.cpp:147-160`)。
- 若挂了 `deletion_filter`(内联行上有本事务删除):因 delete filter 记录的是 row_id 而扫描
  过滤按 ordinal,初始化时额外扫一遍 `row_id` 列把"删除 row_id 集合"重映射为"删除 ordinal
  集合"(line 85-96、133-153)。

事务本地数据路径(line 155-179)无需 SQL:按列 id 投影直接 scan 本地 collection,越界列 id
即 row_id 虚拟列(`COLUMN_ROW_ID`),并恒附加一列用于推算 cardinality。

`Scan`(line 206-294):虚拟列就地填充——`COLUMN_ROW_ID` 用保留 row_ids 或
`file_row_number + r` ordinal(line 228-251);列类型不符时补 cast(line 220-225);最后统一应用
`deletion_filter` 与下推的 table filters(经 `ColumnSegment::FilterSelection` 逐行过滤,
line 264-291)——内联数据没有 zonemap,filter 纯靠行级求值。

## 五、内联数据上的 DELETE / UPDATE

DELETE 主链归 07;`DuckLakeDelete::FlushDelete`(`ducklake_delete.cpp:473-524`)按目标分三路:

1. **事务本地内联行**(`TRANSACTION_LOCAL_INLINED_DATA`):
   `transaction.DeleteFromLocalInlinedData`(`ducklake_transaction.cpp:265-308`)直接重建
   collection 把删除行剔掉,幸存行获得保留 row_ids(`GetOutputRowId`)。不产生任何元数据。
2. **已提交内联行**(`INLINED_DATA`):`AddNewInlinedDeletes(table_id, 内联表名, row_ids)`
   (`ducklake_transaction.cpp:247-263`)记入 `new_inlined_data_deletes`;提交时
   `WriteNewInlinedDeletes`(`ducklake_metadata_manager.cpp:2874-2901`)生成
   `UPDATE <内联表> SET end_snapshot = {SNAPSHOT_ID} WHERE row_id IN (...) AND end_snapshot IS
   NULL AND begin_snapshot != {SNAPSHOT_ID}`——即**关闭版本区间**而非物理删除,时间旅行与
   SCAN_DELETIONS 由此可用。变更记录为 `inlined_delete:<tid>`
   (`ducklake_transaction_state.cpp:389`),读侧未提交期间经
   `transaction.GetInlinedDeletes()` 转成 `deletion_filter`
   (`ducklake_multi_file_reader.cpp:254-263`)。
3. **parquet 文件上的小删除 → inlined file deletes**:若删除行数 ≤
   `data_inlining_row_limit`,不写 delete file,而是写进 per-table 追加式表
   `ducklake_inlined_delete_<table_id>(file_id BIGINT, row_id BIGINT, begin_snapshot BIGINT)`
   (`ducklake_delete.cpp:508-524`;表名 `InlinedFileDeletionTableName`,
   `ducklake_metadata_manager.cpp:2903-2905`;懒建表 `GetInlinedDeletionTableName`,
   line 3045-3092)。注意该表**无 schema_version、无 end_snapshot,只追加**——它删的是
   不可变 parquet 文件里的行,行号永远有效。读侧把它合并进 delete filter
   (`ReadInlinedFileDeletions` line 2966-2986;`ducklake_multi_file_reader.cpp:274-279`;
   事务本地的经 `GetLocalInlinedFileDeletesForFile` 注入 file entry,
   `ducklake_multi_file_list.cpp:340-348`)。首次可能建表时同样
   `SetRequiresNewInlinedTable(true)`(`ducklake_delete.cpp:515-519`)。

**UPDATE 内联行**:DuckLake 的 UPDATE 一律 delete + insert
(`update.update_is_del_and_insert = true`,`ducklake_update.cpp:292`)。`PlanUpdate`
(line 259-287)给 copy_input 设 `WRITE_ROW_ID` 并复用 INSERT 的 inlining 包装:更新链输出
"新值 + row_id"列,删除走上面三路之一,重插行带着原 row_id 进 `DuckLakeInlineData`,由 1.3
第 3 步抽成保留 row_ids ——**flush 前后、更新前后 row_id 恒定**。

## 六、★flush:CALL ducklake_flush_inlined_data

`src/functions/ducklake_flush_inlined_data.cpp`(全文 768 行)。函数签名
`ducklake_flush_inlined_data(catalog, schema_name := ..., table_name := ...)`
(line 761-766)。**当前 HEAD 没有 chunk_size 参数**;CHECKPOINT 的第一步就是调它
(`ducklake_checkpoint.cpp:12-21`,归 09)。

### 6.1 bind:为每张内联表生成一条 flush 子计划

`FlushInlinedDataBind`(line 586-759)是 `bind_operator`(直接产出 logical plan):

- 解析 schema/table 过滤,默认扫全 catalog 所有表(line 596-638);
- 配置 `auto_compact != 'true'` 的表跳过(line 643-647);
- 对每张表的**每个** `GetInlinedDataTables()` entry(可能多版本并存)生成一个
  `DuckLakeDataFlusher::GenerateFlushCommand()` 子计划(line 648-654),并顺手执行
  `FlushInlinedFileDeletions`(6.4);
- 多个子计划 `UNION ALL` 后套 `GROUP BY schema_name, table_name` + `SUM(rows_flushed)` +
  `HAVING > 0` 的 logical 聚合(line 675-758),输出 `(schema_name, table_name, rows_flushed)`。

### 6.2 数据搬运计划:复用 INSERT 的 COPY 链

`GenerateFlushCommand`(line 281-397)拼出
`LogicalGet → (projection/casts) → (sort) → LogicalCopyToFile → DuckLakeLogicalFlush`:

- **扫描**:取该内联表 `schema_version` 对应时点的 table entry(line 283-291,保证列布局与
  内联表一致),拿表的常规 scan function 但把 `read_info.scan_type` 改成
  `DuckLakeScanType::SCAN_FOR_FLUSH`,file list 替换成只含这张内联表的
  `DuckLakeMultiFileList`(line 296-301)。`SCAN_FOR_FLUSH` 的 SQL
  (`ReadAllInlinedDataForFlush`,`ducklake_metadata_manager.cpp:3169-3180`)是
  `WHERE {SNAPSHOT_ID} >= begin_snapshot ORDER BY row_id, begin_snapshot`——**不过滤
  end_snapshot**,已删行也搬,完整保留历史。
- **列**:physical 列 + `COLUMN_IDENTIFIER_ROW_ID` + `COLUMN_IDENTIFIER_SNAPSHOT_ID`
  (line 322-327);`copy_input.virtual_columns = WRITE_ROW_ID_AND_SNAPSHOT_ID`(line 314),
  COPY 复用 `DuckLakeInsert::GetCopyOptions`(line 316),于是 **parquet 文件里显式多出
  `_ducklake_internal_row_id` 与 `_ducklake_internal_snapshot_id` 两列**(field id 映射见
  `ducklake_insert.cpp:322-328`)。
- **排序**:取**最新**(含事务本地 ALTER)的 `SET SORTED BY` 配置插入 sort + tiebreaker
  (line 345-364),并记下 `sort_order_sql` 供 Finalize 对位。
- sink 不是 `DuckLakeInsert` 而是 `DuckLakeFlushData`(同样消费 COPY 的
  RETURN_STATS 输出),`copy->batch_size = DEFAULT_ROW_GROUP_SIZE`(line 380)。

### 6.3 DuckLakeFlushData:row_id 保留与删除搬运

`Sink`(line 102-106)调 `DuckLakeInsert::AddWrittenFiles(..., set_snapshot_id=true)`:从
COPY 返回的列统计中提取 `_ducklake_internal_snapshot_id` 的 min/max 作为文件的
`begin_snapshot` / `max_partial_file_snapshot`、`_ducklake_internal_row_id` 的 min 作为
`flush_row_id_start`(`ducklake_insert.cpp:137-158`)。提交时这类文件用
`flush_row_id_start` 而非新分配的 `next_row_id` 注册
(`ducklake_transaction_state.cpp:969-973`)——加上文件里物化的 row_id 列,**flush 后行的
row_id 与内联期完全一致**(核实成立)。

`Finalize`(line 113-200)收尾四件事:

1. **删除搬运**:对每个写出的文件,按与 6.2 相同的排序键(`sort_order_sql + row_id ASC,
   begin_snapshot ASC`;分区表叠加 partition filter 并维护 per-partition 行偏移)对内联表跑
   `ROW_NUMBER() OVER (...) - 1` 计算每行在文件内的 position,筛出 `end_snapshot IS NOT NULL`
   的行(line 126-169),按文件写出携带 per-position snapshot 的 delete file
   (`DeleteFileSource::FLUSH`,line 171-188)并挂到对应 data file 上
   (`AttachDeleteFilesToWrittenFiles`,line 34-47)。即"已删行进文件 + 同时生成 delete
   file",时间旅行语义无损。
2. `transaction.AppendFiles(...)`:写出的 parquet 走普通新增文件提交链(line 196)。
3. `transaction.DeleteFlushedInlinedData(inlined_table, snapshot_id)`:**立即**对 metadata
   连接执行 `DELETE FROM <内联表> WHERE begin_snapshot <= <flush_snapshot>`
   (`ducklake_metadata_manager.cpp:5253-5263`)。
4. `transaction.MarkInlinedDataForDeletion(...)`:把 `FlushedInlinedTableInfo{表, snapshot}`
   记入事务(`ducklake_transaction.cpp:1501-1503`),commit 批里会再生成同一条 DELETE
   (`GenerateDeleteFlushedInlinedData`,`ducklake_transaction_state.cpp:1492-1495`)——这是
   为 commit 冲突重试(rollback 后重放 batch)准备的幂等补偿。

### 6.4 inlined file deletes 的 flush

`FlushInlinedFileDeletions`(line 418-581)在 bind 阶段同步执行:join
`ducklake_inlined_delete_<tid>` × `ducklake_data_file` × 现存 `ducklake_delete_file`
(line 432-445),按 file 分组;若文件已有 delete file,先 `ScanDeleteFile` 读出旧删除并
`MergeDeletesWithSnapshots` 合并(line 521-544);为每个文件写出新 delete file
(overwrite 旧的,line 549-569),`transaction.AddDeletes` 注册,最后
`DELETE FROM ducklake_inlined_delete_<tid>` 整表清空(line 575-580)。

### 6.5 事务性与并发

flush 走**正常 commit 协议**(无独立提交路径):snapshot 变更记为
`inline_flush:<tid>`(`ducklake_transaction_state.cpp:390`),冲突矩阵
(line 251-263,完整矩阵归 03):flush 与同表的 drop / `inlined_delete` / 另一个 flush 互斥;
反向地,`inlined_delete` 也与 flush 互斥。**并发的内联 INSERT 与 flush 不冲突**:DELETE 谓词
`begin_snapshot <= flush_snapshot` 天然放过 flush 后才提交的新行。

提交成功后,若本事务 flush 过内联表且 `!skip_drop_empty_inlined`,执行
`DropEmptySupersededInlinedTables`(`ducklake_transaction_state.cpp:1726-1731,1613-1673`):
找出 schema_version 落后于本表最大版本、且已为空的内联表,`DELETE` 其注册行并
`DROP TABLE`,随后失效 schema cache。该清理在 commit 之外 best-effort 执行,失败不影响已
提交的 flush。quack server-side commit 返回 `had_flushes` 时同样在客户端补这一步
(`quack_metadata_manager.cpp:129-133`;另有 server 侧变体
`DuckLakeMetadataManager::DropEmptySupersededInlinedTables`,
`ducklake_metadata_manager.cpp:5190-5240`)。当前版本的内联表(最大 schema_version)即使空也
保留,避免反复建表。

## 七、配置与限制

- **`data_inlining_row_limit`**:见 1.4。三个设置入口:ATTACH 选项
  (`ducklake_storage.cpp:35-36`)、`ducklake_set_option`(可带 schema/table 作用域;>0 时校验
  无保留列名冲突,`ducklake_set_option.cpp:128-133`)、全局 setting
  `ducklake_default_data_inlining_row_limit`(默认 10)。**默认开启**;设 0 关闭。
- **保留列名**:`row_id` / `begin_snapshot` / `end_snapshot` / `_ducklake_internal_row_id` /
  `_ducklake_internal_snapshot_id`(`DuckLakeUtil::IsInlinedSystemColumn`,
  `ducklake_util.cpp:334-338`)。含这些列名的表不能内联(`CanInlineColumns`,
  `ducklake_metadata_manager.cpp:116-143`,同时受后端 `MaxIdentifierLength` 约束);启用
  inlining 后 ALTER RENAME/ADD 撞名直接报错(`ducklake_table_entry.cpp:727-734,772-780`)。
- **类型限制**(细节归 05):基类 `SupportsInlining` 仅排除 GEOMETRY
  (`ducklake_metadata_manager.cpp:96-101`);postgres 与 sqlite 后端额外排除 VARIANT
  (`postgres_metadata_manager.cpp:44-49`、`sqlite_metadata_manager.cpp:32-37`);sqlite 的
  FLOAT/DOUBLE/VARIANT 在内联表中以 VARCHAR 落地、postgres 经 BLOB reinterpret 读回
  (4.2)。类型不可内联时 `GetInliningLimit` 返回 0,整张表静默退回 parquet 路径。
- **与 CDC 的交互**(函数本体归 10):`ducklake_table_insertions` / `ducklake_table_deletions`
  把同一张表 scan 的 `scan_type` 改为 `SCAN_INSERTIONS` / `SCAN_DELETIONS`
  (`ducklake_table_insertions.cpp:46-68`),file list 照常附加内联表
  (`ducklake_multi_file_list.cpp:377-421`),reader 分别用窗口谓词查 `begin_snapshot` /
  `end_snapshot`(4.2;删除扫描的 snapshot 虚拟列映射到 `end_snapshot`)。由于 flush 把
  per-row snapshot 写进文件、删除带 snapshot 写进 delete file,flush 前后的 CDC/时间旅行
  结果一致。
- **其他边界**:内联与写文件在单条 INSERT 内互斥(1.3);单事务内"内联 + 文件"可以共存于不同
  语句;compaction(`merge_adjacent_files` 等)不处理内联数据,必须先 flush——这也是
  CHECKPOINT 把 flush 排在第一步的原因(`ducklake_checkpoint.cpp:14-19`)。
