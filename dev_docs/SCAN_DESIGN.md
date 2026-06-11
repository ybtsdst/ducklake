# DuckLake 读路径设计(SCAN_DESIGN)

> 行号基准:commit `47187559`(分支 local_dev)。引用格式 `src/storage/xxx.cpp:123`。

## 概述

DuckLake 没有自己的执行算子:读路径是把 parquet 扩展的 `parquet_scan` TableFunction 原样
拿来,替换其中的 `MultiFileReader` 工厂与若干回调,让"文件从哪来、每个文件怎么读、列怎么
映射、哪些行被删了"这些决策全部改由 DuckLake 元数据驱动。具体来说有三层注入点:

1. **`DuckLakeMultiFileList`(MultiFileList 实现)**——文件清单不来自 glob,而来自对
   metadata catalog 的 SQL 查询(`ducklake_data_file` 按快照过滤),并在尾部叠加事务本地
   新文件、inlined data 表;filter pushdown 在这一层翻译成 metadata 查询的 WHERE 子句,
   实现文件级裁剪。
2. **`DuckLakeMultiFileReader`(MultiFileReader 实现)**——per-file 装配:行级删除
   (`DuckLakeDeleteFilter`,支持 parquet positional delete file 与 Puffin deletion vector
   两种格式)、schema evolution 列映射(field_id / name map / 位置映射三条路径)、虚拟列
   `row_id`/`snapshot_id` 的表达式生成,以及 inlined data 的 reader 替换。
3. **TableFunction 回调**——`statistics`/`get_partition_stats` 把 catalog 级列统计与行数
   暴露给 optimizer(MIN/MAX 折叠、COUNT(*) 免扫),`get_virtual_columns`/`get_bind_info`
   等把表元数据接进 binder。

读路径调用链:

```
Binder: DuckLakeTableEntry::GetScanFunction()           table_entry.cpp:353
  ├─ GetDuckLakeScanFunction(): 拷贝 parquet_scan,     scan.cpp:222
  │    function.get_multi_file_reader = DuckLakeMultiFileReader::CreateInstance
  │    function.statistics/get_partition_stats/... = DuckLake 回调
  ├─ function_info = DuckLakeFunctionInfo::Create(table, txn, snapshot)
  └─ BindDuckLakeScan() → parquet_scan.bind()           table_entry.cpp:341
       └─ MultiFileReader 框架回调:
            DuckLakeMultiFileReader::CreateFileList()    multi_file_reader.cpp:181
              └─ new DuckLakeMultiFileList(txn-local files + inlined data)
            DuckLakeMultiFileReader::Bind()              multi_file_reader.cpp:222
              └─ global schema = 表的 field_id 树, mapping = BY_FIELD_ID

Optimizer: ComplexFilterPushdown / DynamicFilterPushdown    multi_file_list.cpp:86 / :58
  └─ 生成带 FilterPushdownInfo 的新 DuckLakeMultiFileList(文件级裁剪)

Execution: MultiFileGlobalState 逐文件:
  DuckLakeMultiFileList::GetFiles()                     multi_file_list.cpp:431
    └─ GetFilesForTable(): metadata 查询 + 事务本地叠加  multi_file_list.cpp:318
  DuckLakeMultiFileReader::CreateReader()               multi_file_reader.cpp:403
    └─ TryCreateInlinedDataReader() 或 parquet reader
  DuckLakeMultiFileReader::InitializeReader()           multi_file_reader.cpp:240
    ├─ CanSkipFileByTopNDynamicFilter → SKIP_READING_FILE
    ├─ 装配 DuckLakeDeleteFilter(delete file / DV / inlined / max_row_count)
    └─ snapshot_filter_min/max → TableFilter on _ducklake_internal_snapshot_id
  DuckLakeMultiFileReader::CreateMapping()              multi_file_reader.cpp:494
    └─ mapping_id 路径 / 无 field_id 位置映射 / BY_FIELD_ID
  DuckLakeMultiFileReader::GetVirtualColumnExpression() multi_file_reader.cpp:569
    └─ row_id = row_id_start + file_row_number / snapshot_id = 常量
  parquet scan 执行,每个 chunk:
    DuckLakeDeleteFilter::Filter()(行级删除过滤)       delete_filter.cpp:104
    DuckLakeMultiFileReader::FinalizeChunk()            multi_file_reader.cpp:687
```

关键源码位置:

| 主题 | 位置 |
|---|---|
| TableFunction 构造与回调注入 | `src/storage/ducklake_scan.cpp:222-251` |
| `DuckLakeFunctionInfo` / `DuckLakeScanType` | `src/include/storage/ducklake_scan.hpp:38-58` |
| 文件清单 `DuckLakeMultiFileList` | `src/storage/ducklake_multi_file_list.cpp` |
| `DuckLakeFileListEntry` 等清单结构 | `src/include/storage/ducklake_metadata_info.hpp:359-424` |
| metadata 侧文件查询(filter 下推目标) | `src/storage/ducklake_metadata_manager.cpp:1660-1816` |
| per-file 装配 `DuckLakeMultiFileReader` | `src/storage/ducklake_multi_file_reader.cpp` |
| 行级删除 `DuckLakeDeleteFilter` | `src/storage/ducklake_delete_filter.cpp` |
| Puffin deletion vector 编解码 | `src/storage/ducklake_deletion_vector.cpp` |
| name map 结构 | `src/include/common/ducklake_name_map.hpp` |
| 表级统计回调 | `src/storage/ducklake_scan.cpp:160-220` |
| 独立单文件扫描器 `ParquetFileScanner` | `src/common/parquet_file_scanner.cpp` |

## 关联文档

- [ATTACH_CATALOG_DESIGN.md](ATTACH_CATALOG_DESIGN.md):catalog/表 entry 的来历,本篇从
  `DuckLakeTableEntry::GetScanFunction` 接手。
- [TRANSACTION_DESIGN.md](TRANSACTION_DESIGN.md):事务本地变更的数据结构
  (`new_data_files`、`dropped_files`、本地 delete 等);本篇写它们**叠加进扫描的机制**。
- [METADATA_SCHEMA_DESIGN.md](METADATA_SCHEMA_DESIGN.md):`ducklake_data_file` /
  `ducklake_delete_file` / `ducklake_file_column_stats` / `ducklake_name_mapping` 等表的数据字典。
- [METADATA_MANAGER_DESIGN.md](METADATA_MANAGER_DESIGN.md):filter 下推的 **SQL 生成实现**
  (CTE 拼装、stats 转义);本篇只写语义(什么 filter 能下推、何时触发)。
- [DML_DESIGN.md](DML_DESIGN.md):delete file / deletion vector 的**生成侧**;格式与读取归本篇。
- [DATA_INLINING_DESIGN.md](DATA_INLINING_DESIGN.md):inlined data 读取细节;本篇只写它混入
  MultiFileList 的入口。
- [TABLE_FUNCTIONS_DESIGN.md](TABLE_FUNCTIONS_DESIGN.md):CDC 表函数
  `ducklake_table_insertions/deletions` 的对外接口;它们复用的 scan type 机制在本篇交代。

## 一、表函数构造

### 1.1 复用 parquet_scan + 替换回调

`DuckLakeFunctions::GetDuckLakeScanFunction`(`src/storage/ducklake_scan.cpp:222-251`)从
catalog 里取出 `parquet_scan` 的第 0 个 overload 整体拷贝,然后只改一个字段就完成了"夺舍":

```cpp
function = parquet_scan.functions.GetFunctionByOffset(0);
function.get_multi_file_reader = DuckLakeMultiFileReader::CreateInstance;   // scan.cpp:233
```

`bind`/`init_global`/`init_local`/`function`(执行体)全部沿用 parquet 扩展的实现——DuckLake
的所有定制都通过 MultiFileReader 接口回调进来。随后替换/补充的 TableFunction 回调
(`scan.cpp:236-247`):

| 回调 | 实现 | 作用 |
|---|---|---|
| `statistics` / `statistics_extended` | `DuckLakeStatistics`(`scan.cpp:91-105`) | 列统计给 optimizer;有事务本地写入时返回 `nullptr`(全局 stats 不含本地数据) |
| `get_bind_info` | `DuckLakeBindInfo`(`scan.cpp:114`) | 把扫描映射回 `DuckLakeTableEntry`(供 `BindInfo(table)`) |
| `get_virtual_columns` | `DuckLakeVirtualColumns`(`scan.cpp:120`) | 见第六节 |
| `get_row_id_columns` | `DuckLakeGetRowIdColumn`(`scan.cpp:128`) | 行标识 = `{filename, file_row_number}` |
| `get_partition_stats` | `DuckLakeGetPartitionStats`(`scan.cpp:160`) | 表级精确行数 + MIN/MAX 折叠,见 3.3 |
| `serialize` / `deserialize` | `scan.cpp:279-334` | 按 `{catalog, schema, table, snapshot, scan_type, start_snapshot}` 序列化,反序列化时重查 catalog 重新 bind |
| `to_string` / `get_metrics` | `scan.cpp:23-89` | EXPLAIN 显示表名;profiling 统计 read/skipped 文件数与文件名列表 |

### 1.2 DuckLakeFunctionInfo

扫描的"身份证"挂在 `TableFunction::function_info` 上
(`src/include/storage/ducklake_scan.hpp:40-58`):

```cpp
struct DuckLakeFunctionInfo : public TableFunctionInfo {
    DuckLakeTableEntry &table;                 // 被扫描的表 entry(catalog 版本已按快照解析)
    weak_ptr<DuckLakeTransaction> transaction; // 弱引用;事务结束后扫描会抛 NotImplemented(scan.cpp:270-277)
    string table_name;                         // 表名(to_string / 序列化用)
    vector<string> column_names;               // bind 输出列名(= 表的逻辑列)
    vector<LogicalType> column_types;          // bind 输出类型
    DuckLakeSnapshot snapshot;                 // 本次扫描固定的快照(含 AT 子句 time travel)
    TableIndex table_id;                       // 表 id(事务本地表的 id >= 2^63)
    DuckLakeScanType scan_type = SCAN_TABLE;   // 扫描语义,见 1.3
    unique_ptr<DuckLakeSnapshot> start_snapshot; // 仅 SCAN_INSERTIONS/SCAN_DELETIONS:变更区间下界
};
```

工厂 `DuckLakeFunctionInfo::Create`(`scan.cpp:258-268`)在 bind 时从表 entry 拷贝列名/类型。
注意 `transaction` 是 `weak_ptr`:bind 结果(乃至 prepared statement)可能活得比事务长,
`GetTransaction()` 在 lock 失败时显式报错而不是悬空。

`DuckLakeTableEntry::GetScanFunction`(`src/storage/ducklake_table_entry.cpp:353-390`)是绑定
入口:构造 function_info(快照来自 `transaction.GetSnapshot(at_clause)`,所以 time travel 在
这里定格)、检查表没有被本事务 drop/rename,然后 `BindDuckLakeScan`
(`table_entry.cpp:341-351`)用空参数直接调 `parquet_scan.bind`。bind 过程中框架回调
`DuckLakeMultiFileReader::Bind`(`multi_file_reader.cpp:222-232`):global schema 不来自文件
footer,而是表的 field_id 树(`ColumnsFromFieldData`,每列 `identifier = field_id`,
`default_expression = initial_default`),并把列映射模式定为
`MultiFileColumnMappingMode::BY_FIELD_ID`。

### 1.3 DuckLakeScanType 四种

`src/include/storage/ducklake_scan.hpp:38`:

| 类型 | 用途 | 文件清单来源 |
|---|---|---|
| `SCAN_TABLE` | 普通 `SELECT`(默认) | `GetFilesForTable`(2.3) |
| `SCAN_INSERTIONS` | CDC:`ducklake_table_insertions(start, end)` | `GetTableInsertions`(`multi_file_list.cpp:377`)——只取 `begin_snapshot` 落在区间内的文件 |
| `SCAN_DELETIONS` | CDC:`ducklake_table_deletions(start, end)` | `GetTableDeletions`(`multi_file_list.cpp:396`)——delete filter 语义反转,只返回被删的行(4.4) |
| `SCAN_FOR_FLUSH` | `ducklake_flush_inlined_data` 内部:把 inlined data 全量读出写 parquet | 不走 `GetFiles()` 的分派(该 switch 对它 throw,`multi_file_list.cpp:445`),而是由调用方直接用第三种构造函数钉死文件清单 |

CDC 两个表函数的 bind(`src/functions/ducklake_table_insertions.cpp:46-68`)就是常规
`GetScanFunction` 之后改写 `function_info.scan_type` 和 `start_snapshot`(end 快照通过 AT
子句进 `lookup_info` 成为 `snapshot`),其余整条 pipeline 复用;对外接口归
[TABLE_FUNCTIONS_DESIGN.md](TABLE_FUNCTIONS_DESIGN.md)。`SCAN_FOR_FLUSH` 同理
(`src/functions/ducklake_flush_inlined_data.cpp:296-301`),它把
`MultiFileBindData::file_list` 直接换成只含一张 inlined 表的清单。

## 二、文件列表:DuckLakeMultiFileList

### 2.1 三种构造路径

`src/storage/ducklake_multi_file_list.cpp:19-41`:

1. **惰性路径**(`:19`,常规扫描):只记 `read_info` + 事务本地文件/inlined data +
   可选 `FilterPushdownInfo`,`read_file_list = false`,清单到 `GetFiles()` 第一次被调用才
   物化。`DuckLakeMultiFileReader::CreateFileList`(`multi_file_reader.cpp:181-189`)走的就是
   这条:它在 bind 时从事务取 `GetTransactionLocalFiles(table_id)` 与本地 inlined data 塞进来。
2. **预先给定文件清单**(`:27`,`read_file_list = true`):调用方已经算好要扫哪些文件。
   使用者是 compaction(`src/functions/ducklake_compaction_functions.cpp:525`,merge 一组
   相邻文件时只扫这组)。
3. **单张 inlined 表**(`:32`):`SCAN_FOR_FLUSH` 用,清单只有一个
   `DuckLakeDataType::INLINED_DATA` 条目。

`GetFiles()`(`:431-451`)持锁惰性物化,按 `scan_type` 分派到
`GetFilesForTable/GetTableInsertions/GetTableDeletions`。

### 2.2 GetFilesForTable:metadata 清单 + 事务本地叠加

`src/storage/ducklake_multi_file_list.cpp:318-375`,五步:

1. **metadata 文件清单**:若表不是事务本地新建表
   (`IsTransactionLocal(table_id)`,id >= 2^63 即未提交),调
   `metadata_manager.GetFilesForTable(table, snapshot, filter_info)`。metadata 侧的查询
   (`ducklake_metadata_manager.cpp:1743-1755`)对 `ducklake_data_file` 与
   `ducklake_delete_file` 都施加左闭右开可见性谓词
   `{SNAPSHOT_ID} >= begin_snapshot AND ({SNAPSHOT_ID} < end_snapshot OR end_snapshot IS NULL)`,
   delete file 取的是**对本快照可见的那一个**(LEFT JOIN);filter_info 翻译成额外的
   WHERE/CTE(见 3.1)。
2. **过滤事务本地 dropped files**(`:326-333`):本事务内被 DELETE 整文件删除/compaction
   重写的文件(`transaction.FileIsDropped`)从清单中剔除。
3. **叠加事务本地 delete**(`:334-339`):本事务对已提交文件做过 DELETE 的,把
   `file_entry.delete_file` 替换为本地新写的 delete file
   (`GetLocalDeleteForFile`)——覆盖第 1 步查到的已提交 delete file(本地 delete 生成时
   已合并旧内容,见 [DML_DESIGN.md](DML_DESIGN.md))。
4. **叠加事务本地 inlined file deletes**(`:340-348`):删除位置记在事务状态而非 delete
   file 里的(小删除内联进 metadata),填进 `file_entry.inlined_file_deletions`。
5. **追加事务本地新数据**(`:349-374`):本事务 INSERT 写出的 parquet 文件逐个追加,
   `row_id_start` 从 `DuckLakeConstants::TRANSACTION_LOCAL_ROW_ID_START = 10^18`
   (`src/include/common/index.hpp:19`)起顺次分配;然后追加已提交 inlined data 表
   (`INLINED_DATA` 条目,每表一条)和本事务的 inlined data
   (`TRANSACTION_LOCAL_INLINED_DATA`,文件名是哨兵串
   `__ducklake_inlined_transaction_local_data`,`multi_file_list.hpp:23`)。

另有姊妹版 `GetFilesExtended()`(`:257-316`),供 DML 侧(DuckLakeDelete 的 delete_map)
取带 `file_id/row_count/delete_count` 的扩展清单,不缓存进 `files`。

### 2.3 DuckLakeFileListEntry

`src/include/storage/ducklake_metadata_info.hpp:373-392`:

```cpp
struct DuckLakeFileListEntry {
    optional_idx data_file_id;        // (历史字段,GetFilesForTable 实际填的是下面的 file_id)
    DuckLakeFileData file;            // 数据文件 {path, encryption_key, file_size_bytes, footer_size, format}
    DuckLakeFileData delete_file;     // 对本快照可见的 delete file(可空;格式 PARQUET 或 PUFFIN)
    optional_idx row_id_start;        // 该文件首行的全局 row_id(行数连续编址);无则文件内嵌 row_id 列
    optional_idx snapshot_id;         // 文件写入快照(虚拟列 snapshot_id 的常量来源)
    optional_idx max_row_count;       // 截断:只读前 N 行(compaction 后 time travel 老快照用)
    optional_idx snapshot_filter_max; // 行级过滤:只含 _ducklake_internal_snapshot_id <= max 的行
    optional_idx snapshot_filter_min; // 行级过滤:>= min(CDC 区间扫描用)
    MappingIndex mapping_id;          // name map id(add_data_files 导入的外来文件;无效=按 field_id 映射)
    DuckLakeDataType data_type;       // DATA_FILE / INLINED_DATA / TRANSACTION_LOCAL_INLINED_DATA
    DataFileIndex file_id;            // metadata 里的 data_file_id
    set<idx_t> inlined_file_deletions;          // 内联在 metadata 库中的删除位置(行号)
    unordered_map<idx_t, pair<string,string>> column_min_max; // field_id -> (min,max) 串,TopN 动态裁剪用(3.2)
};
```

`snapshot_filter_max` 的来源:`ducklake_data_file.partial_max` 非空说明该文件由
merge_adjacent_files 合并而来、内嵌多个快照的行;若 `partial_max > 当前快照`,则置
`snapshot_filter_max = 当前快照`,读取时按内嵌 `_ducklake_internal_snapshot_id` 列行级过滤
(`ducklake_metadata_manager.cpp:1097-1104`,装配见 4.3)。

### 2.4 GetFile:把 per-file 元数据塞进 OpenFileInfo

框架按下标取文件时,`GetFile(i)`(`multi_file_list.cpp:148-212`)把清单条目翻译成
`OpenFileInfo + ExtendedOpenFileInfo::options`(string→Value map),这是 DuckLake 向 parquet
reader 传递 per-file 信息的唯一通道:

- 普通数据文件(`:180-208`):`file_size`、`footer_size`(有则免 footer 探测,见 8.2)、
  `row_id_start`、`snapshot_id`、`encryption_key`(BLOB)、`mapping_id`、
  `has_deletes`(有 delete file 或 max_row_count 时置位,提示框架不能盲信行数)。
  另有缓存优化:DuckLake 管理的文件不可变,`validate_external_file_cache=false` +
  dummy `etag`/`last_modified`,external file cache 可以永久复用。
- inlined data 条目(`:161-179`):`inlined_data=true` + `table_name`/`schema_version`
  (事务本地的则给 `transaction_local_data=true`),供 `TryCreateInlinedDataReader` 识别(第七节)。

## 三、文件级裁剪

### 3.1 filter 下推到 metadata 查询

两个 MultiFileList 虚函数把执行计划里的 filter 转交 metadata 查询,二者都只在
`scan_type == SCAN_TABLE` 时生效,并返回一个**携带 `FilterPushdownInfo` 的新
DuckLakeMultiFileList**(替换原清单,文件列表重新惰性物化):

- `ComplexFilterPushdown`(`multi_file_list.cpp:86-118`):优化器把 scan 上方的
  filter 表达式交下来,先用 `FilterCombiner::GenerateTableScanFilters` 归一化成
  TableFilter,再逐列转 `ExpressionFilter` 收进 pushdown info。
- `DynamicFilterPushdown`(`multi_file_list.cpp:58-84`):TopN / join filter 场景,执行期
  动态生成的 `TableFilterSet` 走这条;之后既参与 metadata 查询过滤,也支撑 3.2 的执行期
  逐文件跳过。

`AddFilterToPushdownInfo`(`:43-56`)做列号翻译:scan 的 `column_t` → 表的
root `field_index`(虚拟列直接丢弃),类型取表 schema 的列类型。收集结果
`FilterPushdownInfo { unordered_map<field_index, ColumnFilterInfo{column_field_index,
column_type, ExpressionFilter}> }`(`src/include/storage/ducklake_metadata_manager.hpp:66-104`)。

**哪些 filter 真正起作用**由 metadata 侧的表达式翻译决定
(`DuckLakeMetadataManager::GenerateFilterFromExpression`,
`ducklake_metadata_manager.cpp:1244-1368`;SQL 拼装细节归
[METADATA_MANAGER_DESIGN.md](METADATA_MANAGER_DESIGN.md)),语义上是把行级谓词改写成
**对 `ducklake_file_column_stats` 的 min/max/null_count 可满足性测试**:

- 支持:`col <cmp> 常量`(六种比较,`:1149-1195`,如 `x = C` → `C BETWEEN min AND max`)、
  `IS [NOT] NULL`(→ `null_count > 0` / `value_count > 0`)、`col IN (常量...)`(展开为 OR)、
  AND/OR 连接(`:1330-1348`)、optional filter 包装的解包(`:1349-1363`)。
- FLOAT/DOUBLE 特判(`:1197-1242`):NaN 比一切大,`x > C` 还要 OR `contains_nan`;
  `x = NaN` 直接测 `contains_nan`。
- 不支持即放弃(返回空串):BLOB 列、常量含 NUL 字符、列-列比较、任意函数表达式;
  **AND 里不可译的子项跳过(仍保守正确),OR 里有一个不可译则整个 OR 放弃**(`:1336-1340`)。
- 安全网(`ConvertFilterPushdownToSQL`,`:1378-1428`):某列**没有 stats 行的文件不裁**
  (老文件可能没写该列的 stats),stats 为 NULL 不裁,min/max 参与判定时附加
  `value_count > 0` guard(全 NULL 文件的 min/max 无意义)。
- 追加一类结构裁剪:`BuildBucketPartitionPruningClause`(`:1604-1658`)对
  `bucket()` 分区列上的等值/IN 常量谓词,把常量折叠过 bucket transform 后直接按
  `ducklake_file_partition_value` 裁文件,与 zone-map 子句 AND 复合。

文件级裁剪是纯优化:被裁掉的文件保证不含满足谓词的行,留下的文件仍由 parquet reader 的
zone map 与残余 filter 兜底。

### 3.2 TopN 动态过滤:执行期逐文件跳过

`DynamicFilter` 在 bind 期没有值(TopN 堆还没建立),所以走两段:

1. metadata 查询阶段(`GetFilesForTable`,`ducklake_metadata_manager.cpp:1665-1714`):
   发现 pushdown info 里有 dynamic filter 列时,LEFT JOIN 出该列每个文件的
   `min_value/max_value` 原串填进 `DuckLakeFileListEntry::column_min_max`;并按比较方向给
   文件清单加 ORDER BY(求大值则 `max_value DESC NULLS LAST`)——让 TopN 先扫最可能出
   结果的文件,使后续文件更容易被动态阈值跳过。
2. 执行阶段(`CanSkipFileByTopNDynamicFilter`,
   `src/storage/ducklake_multi_file_reader.cpp:86-157`):`InitializeReader` 对每个文件
   (`:251`)取 dynamic filter 的当前阈值(持锁快照;未初始化则不裁),与
   `column_min_max` 比较:`x > C` 时 `file_max <= C` 即整文件跳过
   (`SKIP_READING_FILE`),`x < C` 对称用 file_min。min/max 串与常量都 `DefaultTryCastAs`
   到列类型,任何 cast 失败都放弃裁剪。仅对 `DATA_FILE` 生效(`:88`)。

### 3.3 表级统计回调 DuckLakeGetPartitionStats

`src/storage/ducklake_scan.cpp:160-220`。DuckDB 的 `StatisticsPropagator` 用
`get_partition_stats` 把 `COUNT(*)` 和(stats 精确时)`MIN/MAX(col)` 折叠成常量,免扫数据。
DuckLake 返回**单个 partition**,但有一串保守的禁用条件,任一命中即返回空(回退全扫):

- `scan_type != SCAN_TABLE`(`:169`);
- **time travel**(`:186-189`):`func_info.snapshot != 事务当前快照`(AT 子句)或 catalog
  attach 在历史快照。原因:merge_adjacent_files 合并后的文件 metadata `record_count` 是
  全量行数,按历史快照应只算 `_ducklake_internal_snapshot_id` 过滤后的子集,只有真扫才知道;
- 事务本地新建表(无已提交 stats,`:192`);
- 表上有任何事务本地变更(`HasAnyLocalChanges`,`:199`)——本地新文件/删除使全局账难算。

通过后:`count = GetNetDataFileRowCount + GetNetInlinedRowCount`(净行数,已扣除 delete),
`COUNT_EXACT`。MIN/MAX 的精确性单独判定(`:205-211`):全局列 stats 只在 insert 时
widen、从不因 delete/compaction 收紧,所以**当且仅当从未有行被删除**(gross
`record_count` == net 行数)时 min/max 才精确;`DuckLakePartitionRowGroup::MinMaxIsExact`
(`:138-158`)据此回答,嵌套子字段一律回退(只有顶层列 stats)。`COUNT(*)` 不受
min_max_exact 影响,两条路径独立。

另外普通的 `statistics` 回调(`DuckLakeStatistics`,`scan.cpp:91-105`)把 catalog 列 stats
(min/max/null 性)交给 optimizer 做基数估计/常量折叠,但**有事务本地写入时返回
nullptr**——本地数据没进全局 stats,宁可不给。`GetCardinality`
(`multi_file_list.cpp:136-142`)同样用表 stats 的 `record_count` 报基数。

## 四、行级删除过滤

### 4.1 DuckLakeDeleteFilter:二分定位 + 快照过滤

数据结构(`src/include/storage/ducklake_delete_filter.hpp:16-50`):

```cpp
struct DuckLakeDeleteData {
    vector<idx_t> deleted_rows;     // 被删行位置,升序(delete file 保证严格递增)
    vector<idx_t> snapshot_ids;     // 与 deleted_rows 平行:每个删除发生的快照(可为空=无快照信息)
    unordered_map<idx_t, idx_t> scan_snapshot_map; // 仅 SCAN_DELETIONS:row→删除快照(4.4)
    bool uses_row_id = false;       // scan_snapshot_map 的 key 是全局 row_id 还是文件内位置
};
class DuckLakeDeleteFilter : public DeleteFilter {  // DuckDB MultiFileReader 的行级过滤接口
    shared_ptr<DuckLakeDeleteData> delete_data;
    optional_idx max_row_count;     // 只读前 N 行(SetMaxRowCount)
    optional_idx snapshot_filter;   // 只认 snapshot_id <= 此值的删除(SetSnapshotFilter)
};
```

`Filter(start_row, count, sel)`(`delete_filter.cpp:104-115`)先用 `max_row_count` 截断
(起点超界直接返回 0),再进 `DuckLakeDeleteData::Filter`(`:58-90`):对 `deleted_rows`
做 `std::lower_bound` 二分定位本 vector 范围的第一条删除,无交集快速返回全量;否则构建
selection vector 逐行剔除。若给定 `snapshot_filter` 且有平行 `snapshot_ids`,只有
`snapshot_ids[i] <= snapshot_filter` 的删除才算数——这让**一个物理 delete file 服务多个
历史快照**(time travel 读老快照时,晚于该快照的删除被无视)。

### 4.2 两种持久格式

**(a) parquet positional delete file**(`ScanDeleteFile`,`delete_filter.cpp:147-251`)。
schema 校验接受三种形态(`:164-187`):

- `(file_path VARCHAR, pos BIGINT)`——标准两列;
- `(file_path, pos, _ducklake_internal_snapshot_id BIGINT)`——DuckLake 扩展,第三列记录
  每条删除发生的快照(名字匹配才认,`:184`);
- `(file_path, pos, row ...)`——Iceberg 格式,第三列忽略。

读取用 `ParquetFileScanner`(8.3)单文件扫描,套一个定制
`DeleteFileMultiFileReader`(`:24-53`)把 `file_size/encryption_key/etag` 预填进
`OpenFileInfo`,避免对象存储 HEAD 请求。`pos` 必须非 NULL 且严格递增(`:226-234`),
直接顺序 push 进 `deleted_rows`。有快照列且调用方给了区间时,把
`snapshot_id ∈ [min,max]` 作为 TableFilter 推给这次 parquet 扫描(`:190-207`,CDC 用)。

**(b) Puffin deletion vector(Roaring blob)**。`delete_file.format == PUFFIN`
(`DeleteFileFormat`,`src/include/common/ducklake_data_file.hpp:22-25`)时走
`ScanDeletionVectorFile`(`delete_filter.cpp:117-137`):整个文件读进内存,按 Iceberg V3
`deletion-vector-v1` blob 解码(`DuckLakeDeletionVectorData::FromBlob`,
`src/storage/ducklake_deletion_vector.cpp:56-120`):

```
[u32 BE vector_size][magic D1 D3 39 64][i64 LE bitmap 数]
  { [i32 LE key(row 高 32 位)][roaring portable bitmap(低 32 位)] }*
[u32 BE CRC32(从 magic 到最后一个 bitmap)]
```

`vector_size` 与 CRC 是**大端**(`BSwap`,`:64-65`/`:107`),bitmap 数与 key 为小端 Load;
64 位行号拆成 高 32 位 key → roaring bitmap of 低 32 位;magic 不符或 CRC 不符直接抛
corrupt。解码后 `ToSet`(`:192-206`)展平成有序 set 再灌入 `deleted_rows`,与 parquet
格式殊途同归——上层 `DuckLakeDeleteData` 不感知格式差异(DV 路径没有 per-row 快照信息,
`has_embedded_snapshots = false`)。两种格式的**生成侧**见
[DML_DESIGN.md](DML_DESIGN.md) 与 [MAINTENANCE_DESIGN.md](MAINTENANCE_DESIGN.md)。

### 4.3 InitializeReader:为每个文件装配 filter

`src/storage/ducklake_multi_file_reader.cpp:240-354`,常规扫描(非 delete scan)分支:

1. **inlined data 条目**(`:256-263`):问事务要 `GetInlinedDeletes(table_id, 表名)`
   ——对 inlined 表的事务本地删除记录在事务状态里,转成
   `Initialize(DuckLakeInlinedDataDeletes)`(`delete_filter.cpp:259-299`,与既有删除做
   归并,inlined 删除的 snapshot_id 记 0)。
2. **数据文件**(`:264-291`),满足任一即建 `DuckLakeDeleteFilter`:
   - 有 `delete_file` → `Initialize(context, delete_file)` 读 4.2 两种格式之一;
     若 DML 侧挂了 `delete_map`(`DuckLakeDelete::PlanDelete` 注入,
     `src/storage/ducklake_delete.cpp:664-674`),把 delete data 拷贝登记给它——DELETE
     算子要在写新 delete file 时合并旧删除,扫描顺手把已读的内容共享出去;
   - 有 `inlined_file_deletions`(metadata 库内联删除)→ 归并进同一个 filter;
   - 有 `max_row_count` → `SetMaxRowCount` 截断(compaction 把多文件合并后,老快照只能
     看到属于它的前缀行数);
   - **snapshot filter**(`:283-289`):若该文件**不是**本事务刚删过的
     (`HasLocalDeleteForFile` 为假),`SetSnapshotFilter(snapshot.snapshot_id)`——
     delete file 内嵌快照列时按 4.1 规则过滤掉"未来的删除";本事务删过的文件其本地
     delete file 必然是最新全集,无需过滤。
3. 调基类 `MultiFileReader::InitializeReader` 完成常规列映射后,处理
   `snapshot_filter_max/min`(`:304-352`,merge 后多快照文件):在文件列里按
   field identifier `LAST_UPDATED_SEQUENCE_NUMBER_ID` 找到内嵌
   `_ducklake_internal_snapshot_id` 列(没有则抛错),若未被查询投影则**追加投影**,然后
   构造 `<=` / `>=` 的 `ExpressionFilter` 直接 push 进该 reader 的 TableFilterSet
   (`AddSnapshotFilter`,`:62-70`)。即:删除靠 DeleteFilter,版本可见性靠普通列 filter,
   两套机制正交。

### 4.4 SCAN_DELETIONS:语义反转

delete scan 分支(`:292-300`)对每个数据文件用
`Initialize(context, DuckLakeDeleteScanEntry)`(`delete_filter.cpp:373-450`)构造**反向**
filter——`deleted_rows` 里放的是"**没**被删的行",于是 Filter 之后只剩被删的行:

- `DuckLakeDeleteScanEntry`(`metadata_info.hpp:394-410`)由
  `GetTableDeletions`(`ducklake_metadata_manager.cpp:1883`)产出,除当前 delete file 外
  还带 `previous_delete_file`(区间起点之前已存在的删除)与 `row_count`;
- 有 delete file:按区间 `[start_snapshot, end_snapshot]` 扫出删除位 → `rows_to_scan` 置位;
  无 delete file 但整文件被删(`snapshot_id` 有效):全部行都算被删(`:401-407`);
  inlined file deletions 追加置位(`:414-420`);
- 无内嵌快照列时,`previous_delete_file` 的删除被**扣除**(老删除不属于本区间,`:427-441`);
- 每条被删行的删除快照收进 `scan_snapshot_map`:`PopulateSnapshotMapFromPositions`
  (`:343-371`)先 `ScanDataFileRowIds`(`:301-341`)扫数据文件的
  `_ducklake_internal_row_id` 列把文件位置翻译成全局 row_id(有内嵌 row_id 时
  `uses_row_id=true`),供第六节 `GatherDeletionScanSnapshots` 逐行回填虚拟列
  `snapshot_id` = 删除发生的快照(而非写入快照)。

## 五、schema evolution:name map 与列映射

### 5.1 默认路径:field_id

DuckLake 自己写出的 parquet 文件每列都带 field_id(等于 metadata 的 `column_id`),Bind
时 global schema 也以 field_id 为 identifier(1.2),所以默认映射模式是 `BY_FIELD_ID`:
改名零成本(名字根本不参与匹配);删列后老文件多出的列不被引用;新增列在老文件中缺失,
由 global column 的 `default_expression` 补值——`CreateColumnFromFieldId`
(`multi_file_reader.cpp:191-210`)把它设为该列的 `initial_default`(无则 NULL 常量),
这正是"加列带 default 不重写数据"的实现点。类型 promotion 由 MultiFileReader 框架的
cast 兜底。

### 5.2 name map:外来文件的身份登记

`ducklake_add_data_files` 导入的外来 parquet 文件可能**没有** field_id,或 field_id 与表
对不上。DuckLake 为这类文件登记一份 name map(`src/include/common/ducklake_name_map.hpp:23-46`):

```cpp
struct DuckLakeNameMapEntry {
    string source_name;          // 文件中的列名(匹配 key)
    FieldIndex target_field_id;  // 映射到表的哪个 field_id
    bool hive_partition = false; // true: 该列不在文件里,从文件路径的 hive 分区段提值
    vector<unique_ptr<DuckLakeNameMapEntry>> child_entries; // 嵌套类型递归
};
struct DuckLakeNameMap {
    MappingIndex id;             // mapping_id
    TableIndex table_id;
    vector<unique_ptr<DuckLakeNameMapEntry>> column_maps;   // 顶层列
};
```

**mapping_id 的来源**:add_data_files 分析完文件 schema 后调
`DuckLakeTransaction::AddNameMap`(`src/functions/ducklake_add_data_files.cpp:1209` →
`ducklake_transaction.cpp:2067-2083`),先在 catalog 已有/本事务新增的 name map 里找
**结构兼容**的复用(`IsCompatibleWith` 按 source_name + target_field_id + 子树整体比对,
`ducklake_name_map.cpp:13-63`),没有才分配新 id。commit 时持久化到
`ducklake_column_mapping` + `ducklake_name_mapping` 两张表
(`ducklake_metadata_manager.cpp:235-236`,数据字典归
[METADATA_SCHEMA_DESIGN.md](METADATA_SCHEMA_DESIGN.md)),`ducklake_data_file.mapping_id`
指向它。读取时 `GetMappingById`(`ducklake_transaction.cpp:2085-2097`)先查本事务新建的,
再查 catalog 缓存。

### 5.3 CreateMapping:三分支

`DuckLakeMultiFileReader::CreateMapping`(`multi_file_reader.cpp:494-567`)在每个文件
打开后、列映射建立前介入(开头还做了 `NormalizeListChildNames`:legacy parquet/Avro 的
list 子节点 `array`/`element` 归一化为 `list`,`:73-84`):

1. **mapping_id 路径**(`:535-547`):文件的 extended_info 带 `mapping_id`(2.4 注入)→
   `GetMappingById` 取 name map → `CreateNewMapping` 改写出一套新的 global columns →
   以 **BY_NAME** 模式调基类映射。
2. **位置映射路径**(`:549-564`):文件没有 mapping_id 且列不带 field_id
   (`ColumnsHaveFieldIds`,`:36-43`)→ 现场用
   `DuckLakeNameMap::CreatePositionalMapping`(`ducklake_name_map.cpp:81-93`)按
   "文件第 i 列 ↔ 表第 i 列"造一个临时 name map,同样走 BY_NAME。兜底 legacy 场景
   (如 mapping 丢失的外部文件)。
3. **默认路径**(`:565`):直接 BY_FIELD_ID。

中间一段 delete-scan 专用逻辑(`:500-533`):`SCAN_DELETIONS` 时记录 rowid/snapshot_id
两个虚拟列在输出 chunk 的下标;若用户查询没投影 rowid,则**内部追加**
`COLUMN_IDENTIFIER_ROW_ID` 投影(`internally_projected_rowid`)——4.4 的
snapshot 回填需要按 row_id 查 map(6.3)。

### 5.4 MapColumns:name map 的施加 + hive partition 提值

`MapColumns`(`multi_file_reader.cpp:425-486`)拿 global columns 的拷贝,逐列按
identifier(field_id)查 name map:

- 命中 → identifier 改写为 `source_name`(于是基类的 BY_NAME 匹配到文件列),
  嵌套类型递归处理 children(list 子名归一化同样适用);
- 未命中 → identifier 置为哨兵 `"__ducklake_unknown_identifier"`,文件中必然匹配不到,
  框架走 default_expression(= 新增列在老文件上的表现);
- `hive_partition` 列 → 同样置哨兵让文件匹配落空,但把 default_expression 替换为从
  `HivePartitioning::Parse(文件路径)` 解析出的分区值(`:452-470`,
  `HivePartitioning::GetValue` 处理 `__HIVE_DEFAULT_PARTITION__` 与类型 cast;路径里
  找不到该 key 直接报错)。即分区值不存储在文件中、每文件常量注入。

汇总:**改名**对 field_id 路径免费、对 name map 路径不影响(map 钉死了
source_name→field_id);**删列**只是 global schema 不再引用;**加列**在所有老文件上
表现为 default_expression(initial_default / hive 分区值 / NULL)。

## 六、虚拟列

### 6.1 列表

`DuckLakeTableEntry::GetVirtualColumns`(`src/storage/ducklake_table_entry.cpp:392-405`):
`filename`(VARCHAR)、`file_row_number`(BIGINT)、`file_index`(UBIGINT)、
`rowid`(BIGINT)、`snapshot_id`(BIGINT)、空列(COUNT(*) 用)。前三个由
MultiFileReader/parquet 框架原生处理;`rowid` 用 DuckDB 通用的
`COLUMN_IDENTIFIER_ROW_ID`,`snapshot_id` 用 DuckLake 自定义的
`COLUMN_IDENTIFIER_SNAPSHOT_ID = 10^19`(`multi_file_reader.hpp:22`)。DML 的行标识
取 `{rowid, filename, file_index, file_row_number}`(`table_entry.cpp:407-414`)。

### 6.2 GetVirtualColumnExpression

`multi_file_reader.cpp:569-630`,框架对每个文件、每个未在文件中物理出现的虚拟列回调:

- **row_id**(`:573-611`):先按 field identifier `ROW_ID_FIELD_ID` 在文件列里找内嵌
  `_ducklake_internal_row_id` 列(compaction/flush 写出的文件带它,行号不再连续,必须
  物化),找到则直接读列;否则取 extended_info 的 `row_id_start`,把虚拟列重写为
  `row_id_start + file_row_number`(BoundFunction `+`,column_id 偷换成
  `COLUMN_IDENTIFIER_FILE_ROW_NUMBER`)。两者都没有则报错。
- **snapshot_id**(`:612-627`):同样先找内嵌列(identifier
  `LAST_UPDATED_SEQUENCE_NUMBER_ID`,merge 后多快照文件有),否则用 extended_info 的
  `snapshot_id` 做**每文件常量**(文件整体写入于一个快照)。
- 其余交还基类。

### 6.3 FinalizeChunk 与 GatherDeletionScanSnapshots

`FinalizeChunk`(`multi_file_reader.cpp:687-731`)默认直通基类;`SCAN_DELETIONS` 且文件有
deletion filter 时追加一步 `GatherDeletionScanSnapshots`(`:632-685`):此时输出里的
`snapshot_id` 常量(写入快照)不是用户要的"**删除**发生在哪个快照",逐行用 row_id
(内嵌 row_id 文件直接用全局 row_id;否则减 `row_id_start` 还原文件位置)查 4.4 建好的
`scan_snapshot_map`,把 `snapshot_id` 列覆写为删除快照。若 rowid 是 5.3 内部追加投影的,
先把基类 FinalizeChunk 写进带尾列 row_id 的临时 chunk,回填后再把用户列引用回输出
chunk(`:694-720`)。

## 七、inlined data 混入(入口)

inlined data(小批量写入直接存 metadata 库)在读路径上伪装成"文件":2.2 第 5 步混入清单,
2.4 打上 `inlined_data=true` 标记。两个 `CreateReader` override
(`multi_file_reader.cpp:403-423`)先尝试 `TryCreateInlinedDataReader`(`:356-401`):

- 事务本地 inlined data(无 `table_name`):直接拿内存中的
  `transaction_local_data` 建 `DuckLakeInlinedDataReader`;
- 已提交 inlined 表:按条目的 `schema_version` 解析**当时**的表 schema(老 inlined 表
  可能是加列前建的,`GetBeginSnapshotForSchemaVersion` → `GetEntryById`,`:380-392`),
  列定义前插 row_id/snapshot_id 两个内嵌列,reader 在被调度时对 metadata 库发 SQL。

`DuckLakeInlinedDataReader` 实现 `BaseFileReader`,对框架与 parquet reader 同形:删除过滤
复用第四节的 `DuckLakeDeleteFilter`(row_id→ordinal 换算见
`ducklake_inlined_data_reader.cpp:85-145`),scan_type 决定发哪条 SQL
(`:110-127`:SCAN_TABLE→`ReadInlinedData`,SCAN_INSERTIONS/DELETIONS→按区间,
SCAN_FOR_FLUSH→全量含已删行);虚拟列 snapshot_id 映射到 inlined 表的
`begin_snapshot`(删除扫描用 `end_snapshot`,`:55-62`)。读取细节归
[DATA_INLINING_DESIGN.md](DATA_INLINING_DESIGN.md)。

## 八、加密、footer_size 与 ParquetFileScanner

### 8.1 per-file encryption key

DuckLake 加密时每个文件有独立密钥,存在 metadata
(`ducklake_data_file.encryption_key`,delete file 同理)。主扫描路径经
`GetFile` 的 extended_info `encryption_key`(BLOB)传给 parquet reader
(`multi_file_list.cpp:195-197`);旁路扫描(delete file、`ParquetFileScanner`)则显式构造
`encryption_config = {footer_key_value: BLOB}` 命名参数
(`src/common/parquet_file_scanner.cpp:31-35`)或同样塞 extended_info
(`delete_filter.cpp:36-38`)。密钥管理与写入侧归
[ATTACH_CATALOG_DESIGN.md](ATTACH_CATALOG_DESIGN.md) / [DML_DESIGN.md](DML_DESIGN.md)。

### 8.2 footer_size

写文件时记录的 parquet footer 字节数,随 metadata 存储,经 extended_info `footer_size`
透传(`multi_file_list.cpp:182-184`)。消费方在 duckdb 子模块的 parquet reader:
`duckdb/extension/parquet/parquet_reader.cpp:1047-1049` 取出后,`LoadMetadata`
(`:256/:288`)据此**一次性精确读出整个 footer**——否则需要先读文件尾 8 字节拿
footer_len 再二次读取。对象存储上省一次 range request;配合 `file_size`(免 HEAD)与
`validate_external_file_cache=false`(免重验),DuckLake 扫描每文件的元数据 IO 被压到最少。

### 8.3 ParquetFileScanner:旁路单文件扫描器

`src/common/parquet_file_scanner.cpp:8-113` 是一个绕开 MultiFile 框架的工具类:手工调
`parquet_scan` 的 bind/init_global/init_local/function,同步逐 chunk 拉取单个 parquet 文件,
支持 SetFilters/SetColumnIds/FindColumn;bind 时强制 `hive_partitioning=false`
(`:29`,DuckLake 管理的路径里可能出现伪 `key=value` 段)。当前(HEAD=47187559)唯一使用者
是 `ducklake_delete_filter.cpp`:读 parquet delete file(4.2a)与扫数据文件的内嵌 row_id 列
(4.4 `ScanDataFileRowIds`)。它不参与主查询 pipeline,无并行,适合"读一个小文件拿全部行"
的元数据级任务。
