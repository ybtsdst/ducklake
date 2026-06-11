# DML_DESIGN.md — 写路径设计(INSERT / DELETE / UPDATE / MERGE)

> 行号基准:HEAD = 47187559(`471875597ed5ed38e2a29a6e4671672977999f34`)。

## 概述

DuckLake 的写路径围绕一个核心决策展开:**不自己实现 parquet writer,而是把 DuckDB 内核的
`PhysicalCopyToFile`(parquet COPY TO)当作写数据文件的引擎复用**。INSERT 的算子树本质上是
`DUCKLAKE_INSERT → PhysicalCopyToFile → 上游 plan`:COPY 算子负责把数据写成 parquet 文件并以
`CopyFunctionReturnType::WRITTEN_FILE_STATISTICS` 的形式把"每个写出的文件 + 逐列统计 + 分区值"作为
chunk 吐给上层;`DuckLakeInsert` 作为 Sink 只做一件事——解析这些 chunk,组装 `DuckLakeDataFile`
内存结构,在 `Finalize` 时把它登记进事务本地变更(`DuckLakeTransaction::AppendFiles`)。文件本身
在执行期就已落盘,但**元数据在 COMMIT 之前对其他事务不可见**;回滚只需删掉这些文件
(见 02 TRANSACTION_DESIGN.md / 03 COMMIT_PROTOCOL_DESIGN.md)。

DELETE 不重写数据文件,而是 MVCC 风格的 positional delete:从 scan 拿到每行的
`(filename, file_index, file_row_number)` 虚拟列,按文件分组收集被删行号,Finalize 时为每个数据文件
写一个 delete file(parquet 格式,或实验性的 Puffin deletion vector)。UPDATE 被显式建模为
DELETE + INSERT:`DuckLakeUpdate` 是一个 Operator(非 Sink),对每个输入 chunk 把删除信息旁路 Sink
进内嵌的 `DuckLakeDelete`,把新值(**整行**)继续向上传给 COPY → INSERT 链。MERGE INTO 复用 DuckDB
内核的 `PhysicalMergeInto`,DuckLake 只为每个 WHEN 分支提供对应的算子(其中 INSERT/UPDATE 分支需要
专门的包装算子来协调"COPY 是 Sink 但 MERGE 分支需要 Operator 语义"这一阻抗失配)。

四种 DML 的算子树对比(`[...]` 为可选节点,自下而上执行):

```
INSERT INTO / CTAS                          DELETE
─────────────────────                       ─────────────────────
DUCKLAKE_INSERT (Sink)                      DUCKLAKE_DELETE (Sink)
└─ PhysicalCopyToFile (parquet)             └─ 上游 plan(DuckLake scan,投影
   └─ [PhysicalProjection: cast]               filename/file_index/file_row_number
      └─ [PhysicalProjection: 分区表达式]       三个虚拟列 + WHERE filter)
         └─ [DuckLakeInlineData]
            └─ [PhysicalOrder: SORTED BY]
               └─ 上游 plan

UPDATE                                      MERGE INTO
─────────────────────                       ─────────────────────
DUCKLAKE_INSERT (Sink)                      PhysicalMergeInto (DuckDB core)
└─ PhysicalCopyToFile                       ├─ 上游 plan(source ⋈ target)
   └─ [DuckLakeInlineData]                  └─ 每个 WHEN 分支一个算子:
      └─ DUCKLAKE_UPDATE (Operator)            ├─ UPDATE → DuckLakeMergeUpdate
         │  (内嵌引用,非 child:)               │   {update_op, copy_op, insert_op}
         │   DUCKLAKE_DELETE ◄──旁路 Sink      ├─ DELETE → DUCKLAKE_DELETE
         └─ 上游 plan(scan+全列+虚拟列)        └─ INSERT → DuckLakeMergeInsert
                                                    {copy_op, insert_op}
```

关键源码位置:

| 文件 | 内容 |
|---|---|
| `src/storage/ducklake_insert.cpp` | `DuckLakeInsert` 算子、COPY 组装(`GetCopyOptions`/`PlanCopyForInsert`)、统计解析、分区表达式生成 |
| `src/include/storage/ducklake_insert.hpp` | `DuckLakeCopyInput` / `DuckLakeCopyOptions` / `InsertVirtualColumns` |
| `src/storage/ducklake_delete.cpp` | `DuckLakeDelete` 算子、delete file / deletion vector 写出、合并重写 |
| `src/include/storage/ducklake_delete.hpp` | `DuckLakeDeleteMap`、`WriteDeleteFileInput*`、`DuckLakeDeleteFileWriter` |
| `src/storage/ducklake_update.cpp` | `DuckLakeUpdate` 算子、`BindUpdateConstraints`(整行重写) |
| `src/storage/ducklake_merge_into.cpp` | `DuckLakeMergeInsert` / `DuckLakeMergeUpdate`、`PlanMergeInto` |
| `src/storage/ducklake_partition_data.cpp` | partition transform 表达式(identity/year/.../bucket) |
| `src/storage/ducklake_sort_data.cpp` | `DuckLakeSort::BuildSortOrderSQL` |
| `src/include/storage/ducklake_stats.hpp` | `DuckLakeColumnStats` / `DuckLakeTableStats` |
| `src/storage/statistics/` | geo / variant extra stats 实现 |
| `src/include/common/ducklake_data_file.hpp` | `DuckLakeDataFile` / `DuckLakeDeleteFile` |
| `src/storage/ducklake_transaction.cpp` | `AppendFiles` / `AddDeletes` / `TransactionLocalDelete` 登记入口 |
| `src/storage/ducklake_transaction_state.cpp` | 提交期 `row_id_start` 分配(`GetNewDataFiles`) |

## 关联文档

- 01 ATTACH_CATALOG_DESIGN.md — catalog/配置选项(`target_file_size` 等 per-schema/per-table 配置)的解析层级
- 02 TRANSACTION_DESIGN.md — `LocalTableChanges{mutex + map<TableIndex, LocalTableDataChanges>}` 事务本地变更容器的数据结构;本篇只写调用点
- 03 COMMIT_PROTOCOL_DESIGN.md — 提交时把本地变更落进元数据目录的协议(本篇 §8 衔接)
- 04 METADATA_SCHEMA_DESIGN.md — `ducklake_data_file` / `ducklake_file_column_stats` 等存储表
- 06 SCAN_DESIGN.md — delete file / deletion vector 的**格式与读取**(本篇只写生成与写出);列统计的裁剪用法
- 08 DATA_INLINING_DESIGN.md — `DuckLakeInlineData` 算子细节(本篇只交代 INSERT 链上的分叉点)
- 09 MAINTENANCE_DESIGN.md — compaction / flush_inlined_data(复用本篇的 COPY 组装与 `AddWrittenFiles(set_snapshot_id=true)` 路径)

## 一、INSERT 算子链

### 1.1 两种 plan 入口:INSERT INTO 与 CREATE TABLE AS

`DuckLakeInsert` 有两个构造函数(`ducklake_insert.cpp:37-49`):INSERT INTO 持有
`optional_ptr<DuckLakeTableEntry> table`;CREATE TABLE AS 持有 `schema + BoundCreateTableInfo info +
table_uuid + table_data_path`。区别体现在 `GetGlobalSinkState`(`:58-72`):CTAS 在**算子初始化时**才
通过 `DuckLakeSchemaEntry::CreateTableExtended` 创建事务本地表项,之后两条路径汇合到同一个
`DuckLakeInsertGlobalState`。`GetName()` 据此返回 `DUCKLAKE_INSERT` 或 `DUCKLAKE_CREATE_TABLE_AS`(`:256-258`)。

plan 组装入口分别是 `DuckLakeCatalog::PlanInsert`(`:786-837`)与 `PlanCreateTableAs`(`:839-869`),
拼链顺序(自下而上):

1. 上游 plan(INSERT INTO 时若 `column_index_map` 非空,先 `ResolveDefaultsProjection` 补默认值,`:794-796`);
2. `PhysicalOrder` —— 表配置了 SORTED BY 且 `sort_on_insert` 为 true(§4);
3. `DuckLakeInlineData` —— `data_inlining_row_limit > 0` 时(`:813-828`)。**这就是 data inlining 的分叉点**:
   低于行数阈值的数据被该算子吸收为事务本地 inlined data,超限数据穿透继续走 parquet 路径,细节见 08;
4. `PlanCopyForInsert`(§1.2)生成 `PhysicalCopyToFile`(其下还可能插分区表达式 projection 与 cast projection);
5. 顶层 `DuckLakeInsert`,并把 `inline_data->insert` 回指到它(`:832-834`),让 inlining 算子能把
   inlined 行数也计入插入计数。

CTAS 额外做两件事:逐列 `DuckLakeTypes::CheckSupportedType`(`:853-855`);用
`duck_transaction.GenerateUUID()` 生成 table_uuid,数据目录为
`schema.DataPath() + GeneratePathFromName(table_uuid, table_name)`(`:856-858`)——
`GeneratePathFromName`(`ducklake_catalog.cpp:249-255`)在表名全为字母数字/`_`/`-` 时用表名做目录名,
否则退回 uuid。

### 1.2 复用 parquet COPY TO:DuckLakeCopyInput 与 GetCopyOptions

`DuckLakeCopyInput`(`ducklake_insert.hpp:141-156`)是组装 COPY 的输入参数包:

```cpp
struct DuckLakeCopyInput {
	DuckLakeCatalog &catalog;                       // 目标 catalog(读配置、生成加密 key)
	optional_ptr<DuckLakePartition> partition_data; // 表的分区定义(无分区为 null)
	optional_ptr<DuckLakeFieldData> field_data;     // 列的 field id 树(CTAS 时为 null,现生成)
	const ColumnList &columns;                      // 要写出的列
	const string data_path;                         // 写入目录 = table.DataPath() + hive_partition 后缀
	string encryption_key;                          // 本次写入的加密 key(未加密为空串)
	SchemaIndex schema_id;                          // 用于按 schema 解析配置项
	TableIndex table_id;                            // 用于按 table 解析配置项
	InsertVirtualColumns virtual_columns;           // 是否额外写 row_id / snapshot_id 列(UPDATE/flush 用)
	optional_idx get_table_index;                   // 逻辑 plan 阶段生成列引用时的 table index
};
```

表级构造函数(`ducklake_insert.cpp:336-344`)从 `DuckLakeTableEntry` 取 `partition_data`/`field_data`,
`data_path = table.DataPath() + hive_partition`(`hive_partition` 默认空串,flush inlined data 按分区
写出时传非空后缀),并当场调用 `catalog.GenerateEncryptionKey(context)`。

`GetCopyOptions`(`:467-590`)做 COPY 的 bind:

- `info->format = "parquet"`,并通过 `info->options["field_ids"]` 把 DuckLake 的 field id 树传给 parquet
  writer(`WrittenFieldIds`,`:316-330`;嵌套类型递归生成带 `__duckdb_field_id` 的 STRUCT 值)。
  `virtual_columns` 要求写 row_id / snapshot_id 时,追加 `_ducklake_internal_row_id`
  (field id = `MultiFileReader::ROW_ID_FIELD_ID`)与 `_ducklake_internal_snapshot_id` 列(`:322-328`、`:533-540`);
- 从 catalog 配置逐项透传 `parquet_compression` / `parquet_version` / `parquet_compression_level` /
  `parquet_row_group_size` / `parquet_row_group_size_bytes` / `per_thread_output`(`:492-516`);
- 强制 `geoparquet_version = "NONE"`,GEOMETRY 列始终用 parquet 原生 geometry 类型写出(`:519-520`);
- 通过 `DuckLakeFunctions::GetCopyFunction(context, "parquet")`(`:269-289`)拿 parquet 的
  `CopyFunctionCatalogEntry`(必要时自动加载扩展),执行 `copy_to_bind`;
- `return_type = CopyFunctionReturnType::WRITTEN_FILE_STATISTICS`(`:581`)——这是统计收集(§2)的来源;
- `overwrite_mode = COPY_OVERWRITE_OR_IGNORE`、`use_tmp_file = false`(`:556`、`:578`)。

若表的类型含 DuckLake 不直接落盘的类型(`DuckLakeTypes::RequiresCast`),`PlanCopyForInsert`
(`:646-713`)会在 COPY 下插一层 cast projection(`InsertCasts`,`:605-619`);对 MERGE/UPDATE 这类
没有 child plan、由外层算子直接向 COPY Sink chunk 的场景,只改写 `expected_types`,由调用方自己
pre-cast(`:662-670`)。最后把 `DuckLakeCopyOptions` 的字段逐一搬到 `PhysicalCopyToFile` 物理算子上
(`:674-707`),`batch_size` 取 row_group_size(默认 `DEFAULT_ROW_GROUP_SIZE`)。

### 1.3 数据文件命名与写入路径(★核实)

数据文件名**不是 DuckLake 自己拼的**,而是设置 `PhysicalCopyToFile` 的 `FilenamePattern`:

```cpp
result.filename_pattern.SetFilenamePattern("ducklake-{uuidv7}");   // ducklake_insert.cpp:558(分区)/:563(非分区)
result.file_extension = "parquet";                                  // :577
```

`{uuidv7}` 占位符由 DuckDB 内核 `FilenamePattern` 在 COPY 打开每个文件时展开为一个 **UUIDv7**
(时间有序,便于按创建时间排序/排查),最终文件名形如
`<data_path>/ducklake-<uuidv7>.parquet`。写入目录 = 表的 `data_path`(INSERT INTO)或
CTAS 新生成的 `<schema_data_path>/<table_name 或 uuid>/`;`GetCopyOptions` 写前会
`EnsureDirectoryExists`(`:526`)。分区写入时再叠加 hive 子目录(§3.4)。

与之对照,**delete file 的文件名由 DuckLake 自己生成**:
`"ducklake-" + transaction.GenerateUUID() + "-delete.parquet"`(`ducklake_delete.cpp:35`)或
`"-delete.puffin"`(`:161`),`GenerateUUID()` 同样是 UUIDv7(`ducklake_transaction.cpp:2099-2105`)。

### 1.4 target_file_size 与文件切分(★核实:per-file rotate)

`GetCopyOptions` 末段(`:556-574`)按是否分区分两支:

- **非分区写**:`result.rotate = true` 且 `result.file_size_bytes = max(target_file_size, 4096)`。
  rotation 是 `PhysicalCopyToFile` 的既有机制:**以 row group 为粒度**,当前文件写满
  `file_size_bytes` 后关闭、按 filename pattern 开下一个文件——即确认是 per-file rotate,单条
  INSERT 可以产出多个文件。4096 字节的下限钳制是为了避免 target 小于 parquet 最小物理文件尺寸时
  rotation 循环不前进(死循环),注释明确说明该钳制不影响 compaction 读取原始值做跳过判断(`:566-572`);
- **分区写**:`rotate = false`(分区输出与 file_size_bytes rotation 互斥,见注释 `:566`),
  `partition_output = true`、`write_empty_file = true`。

`target_file_size` 的解析(`ducklake_catalog.cpp:1016-1027`):session 级
`SET ducklake_target_file_size` 优先,否则走 per-table → per-schema → 全局的 `target_file_size`
配置项,默认 `DEFAULT_TARGET_FILE_SIZE = 1 << 29`(512 MiB,`ducklake_catalog.hpp:86`)。

### 1.5 加密 key 生成点

`DuckLakeCatalog::GenerateEncryptionKey`(`ducklake_insert.cpp:727-740`):catalog 未开启加密时返回
空串;否则用 `RandomEngine` 生成 **16 字节随机 key**。生成点在 `DuckLakeCopyInput` 构造时
(`:343`/`:350`),即**每次 INSERT/UPDATE/MERGE 计划期为该次写入生成一个新 key**,经
`info->options["encryption_config"].footer_key_value` 传给 parquet writer(`:483-489`),并随
`DuckLakeDataFile.encryption_key` 登记进元数据(per-file key,key 本身存在元数据目录里)。delete
file 写出同样带 key(`ducklake_delete.cpp:58-64`)。加密开启时 `hive_file_pattern` 默认翻转为
false(§3.4),避免目录名泄露分区值。

### 1.6 Sink / Finalize

`DuckLakeInsert::Sink`(`:220-224`)收到的不是数据,而是 COPY 返回的文件统计 chunk,直接交给
`AddWrittenFiles`(§2.1)。`Finalize`(`:240-251`)累加 `total_insert_count`,然后调用
`transaction.AppendFiles(table_id, std::move(written_files))` 把 `vector<DuckLakeDataFile>` 登记进
事务本地变更(§8)。作为 Source,`GetDataInternal`(`:229-236`)返回单行 BIGINT 插入行数。
注意 `ParallelSink() = false`(`ducklake_insert.hpp:104-106`)——并行性在 COPY 层
(`physical_copy.parallel = true`,`:705`),`DuckLakeInsert` 收文件元数据本身是串行的。

## 二、统计收集

### 2.1 AddWrittenFiles:解析 WRITTEN_FILE_STATISTICS chunk

COPY 返回 chunk 的列布局(`AddWrittenFiles`,`ducklake_insert.cpp:113-218`):

| 列 | 内容 |
|---|---|
| 0 | 文件路径(VARCHAR) |
| 1 | row_count |
| 2 | file_size_bytes |
| 3 | footer_size |
| 4 | 列统计:`MAP(列路径 → MAP(stat_name → stat_value))`,key 是 `.` 连接的 quoted 嵌套列路径 |
| 5 | 分区值:`MAP(分区名 → 值)`,非分区写为 NULL |

每行对应一个写出的 parquet 文件,组装一个 `DuckLakeDataFile`。列统计 map 逐项处理(`:131-190`):

- 列路径经 `DuckLakeUtil::ParseQuotedList(col_name, '.')` 还原为嵌套路径,再用
  `table.GetFieldId(column_names, &name_offset)` 解析到 `DuckLakeFieldId`,以 `FieldIndex` 为 key 存入
  `data_file.column_stats`;
- `_ducklake_internal_snapshot_id` / `_ducklake_internal_row_id` 两个内部列只在
  `set_snapshot_id = true`(flush_inlined_data 路径,普通 INSERT 为 false)时被消费:前者的 min/max 写入
  `begin_snapshot` / `max_partial_file_snapshot`,后者的 min 写入 `flush_row_id_start`(`:137-159`),
  使 flush 出的文件保留原 row_id 区间(§8.3);
- 对基础列,若 `null_count > 0` 且该列在 `not_null_fields` 中,在此抛 `ConstraintException`——
  即 **NOT NULL 约束是写完文件后靠统计校验的**(`:182-187`);
- VARIANT 列的统计按嵌套 path 逐字段返回(`name_offset` 有效),用 `PartialVariantStats` 增量累积,
  最后 `Finalize()` 合成单个列统计(`:161-177`、`:191-195`);
- 分区值列按位置序号组装 `DuckLakeFilePartition{partition_column_idx, partition_value}`(`:196-208`)。

### 2.2 DuckLakeColumnStats 字段

C++ 定义在 `ducklake_stats.hpp:25-67`(存储表见 04,scan 端裁剪用法见 06):

```cpp
struct DuckLakeColumnStats {
	LogicalType type;            // 列逻辑类型;构造时 GEOMETRY/VARIANT 类型自动挂 extra_stats
	                             // (ducklake_stats.cpp:21-28)
	string min;                  // min 值的字符串表示(统一存字符串,数值/时间类型比较时按值解析,
	                             //  见 RequiresValueComparison,ducklake_stats.hpp:18-20)
	string max;                  // max 值的字符串表示
	idx_t null_count = 0;        // NULL 值个数
	idx_t num_values = 0;        // 总值个数(含 NULL)
	idx_t column_size_bytes = 0; // 该列在文件中占用的字节数(累加进表级 table_size_bytes)
	bool contains_nan = false;   // 浮点列是否含 NaN(NaN 不参与 min/max,需单独标记才能正确裁剪)
	bool has_null_count = false; // 以下 has_* 标记对应字段是否有效(parquet writer 可能不产出某项)
	bool has_num_values = false;
	bool has_min = false;
	bool has_max = false;
	bool any_valid = true;       // 是否可能存在非 NULL 值(AnyValid() 优先用 num_values>null_count 推导)
	bool has_contains_nan = false;
	unique_ptr<DuckLakeColumnExtraStats> extra_stats; // 类型特定扩展统计(geo/variant)
};
```

表级聚合结构 `DuckLakeTableStats`(`ducklake_stats.hpp:70-79`)持有
`record_count` / `table_size_bytes` / `next_row_id` / `map<FieldIndex, DuckLakeColumnStats>`,
提交时通过 `MergeFileStats(file)` 把每个新文件的统计合并进全局统计(§8.3)。

### 2.3 ParseColumnStats

`DuckLakeInsert::ParseColumnStats`(`ducklake_insert.cpp:77-111`)把单列的
`MAP(stat_name → 字符串值)` 解析为 `DuckLakeColumnStats`:识别
`min` / `max` / `null_count` / `num_values` / `column_size_bytes` / `has_nan` 六种标准统计名;
不认识的名字先交给 `extra_stats->ParseStats(stats_name, ...)`(`:103-105`),仍不认识则抛
`NotImplementedException`。所有值在此层都是字符串(COPY 统计接口的约定),数值统计用
`StringUtil::ToUnsigned` 转换。

### 2.4 extra_stats 体系:geo stats 与 variant stats

`DuckLakeColumnExtraStats`(`ducklake_extra_stats.hpp:26-66`)是类型特定统计的抽象基类,接口为
`Merge` / `Copy` / `ParseStats`(消费 writer 统计)/ `Serialize`(写入 per-file 统计表)/
`TrySerialize`(全局统计的字符串表示,如 JSON)/ `Deserialize`。两个实现:

- **`DuckLakeColumnGeoStats`**(`ducklake_geo_stats.hpp:15-32`,实现
  `src/storage/statistics/ducklake_geo_stats.cpp`):字段为 x/y/z/m 四轴 bbox
  (`xmin..mmax`,8 个 double)加 `set<string> geo_types`。`ParseStats`
  (`ducklake_geo_stats.cpp:139-165`)识别 parquet geometry writer 产出的
  `bbox_xmin`/`bbox_xmax`/.../`bbox_mmax` 与 `geo_types`;
- **`DuckLakeColumnVariantStats`**(`ducklake_variant_stats.hpp:22-41`):持有
  `unordered_map<string, DuckLakeVariantStats> shredded_field_stats` —— shredded VARIANT 的
  **path 级**统计,每个 shredded 字段一份 `{shredded_type, DuckLakeColumnStats}`。写路径侧的构造
  辅助类 `PartialVariantStats`(`:44-57`)在 `AddWrittenFiles` 中按嵌套 path 增量收集
  (`ParseVariantStats(path, variant_field_start, col_stats)`),区分 fully shredded 字段,
  `Finalize()` 时折叠成挂着 variant extra_stats 的单列统计。

## 三、分区写入(★核实)

### 3.1 分区定义结构

`ducklake_partition_data.hpp:18-43`:

```cpp
enum class DuckLakeTransformType { IDENTITY, BUCKET, YEAR, MONTH, DAY, HOUR };

struct DuckLakeTransform {
	DuckLakeTransformType type;
	idx_t bucket_count = 0;        // 仅 BUCKET transform 使用
};

struct DuckLakePartitionField {
	idx_t partition_key_index = 0; // 在分区 key 中的序号
	FieldIndex field_id;           // 分区源列的 field id(只支持顶层列,见 GetTopLevelColumn)
	DuckLakeTransform transform;   // 应用的 transform
};

struct DuckLakePartition {
	idx_t partition_id = 0;        // 分区方案 id(随 ALTER ... SET PARTITIONED BY 演进)
	vector<DuckLakePartitionField> fields;
};
```

`DuckLakeInsert::GetTopLevelColumn`(`ducklake_insert.cpp:361-378`)强制分区列必须是顶层物理列,
否则抛 `"Partitioning is only supported on top-level columns"`。

### 3.2 复用 PhysicalCopyToFile 的 PARTITION_BY(核实:是)

按分区分流到多个文件**完全复用 `PhysicalCopyToFile` 的 hive partition 输出机制**,DuckLake 不自己
做分流:`GetCopyOptions` 在有 `partition_data` 时设置 `partition_output = true` 并填
`partition_columns`(输入 chunk 中分区列的下标),由 COPY 算子按分区值切文件、拼 hive 路径。
`GeneratePartitionExpressions`(`ducklake_insert.cpp:409-465`)分两种情况:

- **全部 transform 为 IDENTITY**:直接把分区源列的列下标填进 `partition_columns`(`:418-427`),
  分区列照常写入数据文件;
- **存在非 identity transform**:在 COPY 之下插入一层 `PhysicalProjection`(`projection_list`,由
  `PlanCopyForInsert:651-654` 物化):前段原样投影所有物理列(+虚拟列),尾部追加每个分区字段的
  transform 表达式(`GetPartitionExpression`,`:397-401`);`partition_columns` 指向这些尾部计算列,
  并置 `write_partition_columns = false`(`:441-446`)——**计算出的分区 key 只用于分流和 hive 路径,
  不写进 parquet 文件**(源列本身已在文件里,识别名见 §3.4)。

**partition_values 的回收**(核实:属实,但列号是 5):COPY 写完后,每个文件的实际分区值通过返回
chunk 的**第 6 列(下标 5)** map 回传,`AddWrittenFiles:196-208` 解析为
`DuckLakeFilePartition{partition_column_idx, partition_value}` 存进 `DuckLakeDataFile.partition_values`,
提交时写入 `ducklake_file_partition_value` 元数据表——scan 端分区裁剪靠的是元数据里的这些值,
不是解析 hive 路径(见 06)。

### 3.3 partition transform(核实:支持 identity/year/month/day/hour/bucket)

`DuckLakePartitionUtils::ApplyPartitionTransform`(`ducklake_partition_data.cpp:135-154`)把
transform 落成普通标量表达式:YEAR/MONTH/DAY/HOUR 直接 bind DuckDB 内建 `year()`/`month()`/... 函数
(返回 BIGINT);BUCKET 为 Iceberg 兼容实现 `ApplyBucketTransform`(`:103-133`):
`(murmur3_32(col) & 2147483647) % bucket_count`(murmur3_x86_32 seed 0,掩掉符号位,返回 INTEGER)。
没有 Iceberg 的 truncate/void transform。

### 3.4 hive 路径拼接与 hive_file_pattern

hive 子目录名由 COPY 算子按 `copy_options.names` 拼出(`<name>=<value>/`)。分区 key 的名字由
`GetPartitionKeyName`(`ducklake_partition_data.cpp:12-41`)生成:IDENTITY 用列名,其余用
`year`/`month`/`day`/`hour`/`bucket` 前缀,撞名时退化为 `<prefix>_<field_name>`。

是否真用 hive 目录受 `hive_file_pattern` 配置控制(`ducklake_insert.cpp:706-707`):
`UseHiveFilePattern(!is_encrypted, schema_id, table_id)`(`ducklake_catalog.hpp:198-202`)——
**未加密时默认 true,加密时默认 false**(分区值不进路径),可被配置项覆盖。关掉时分区文件
仍按分区切分,只是平铺在 data_path 下。

## 四、排序写入

### 4.1 sort_on_insert 与 PhysicalOrder 的插入位置(核实:是,COPY 前插 PhysicalOrder)

表通过 `ALTER TABLE ... SET SORTED BY`(存于 `DuckLakeSort`)声明排序键后,
`DuckLakeCatalog::PlanInsert` 读取配置项 `sort_on_insert`(默认 `"true"`,`ducklake_insert.cpp:802-803`):

- `sort_on_insert = true`:`PlanInsertSort`(`:752-784`)在 INSERT 链上插入一个 **`PhysicalOrder`**
  全量排序算子(identity projection map),位置在 `DuckLakeInlineData` 之下(即 inlined 数据也是排过
  序的输入);
- `sort_on_insert = false` 但 inlining 开启:排序算子插在 `DuckLakeInlineData` **之上**(`:818-827`)
  ——被 inline 吸收的数据不付排序代价,只有穿透到 parquet 的数据被排序(注释直述此设计)。

排序表达式的构造复用 compactor 的逻辑:`DuckLakeCompactor::ParseSortOrders` 把存储的 SQL 表达式
重新 parse,`BindSortOrders` bind 到表上,再把 `BoundColumnRefExpression` 改写成
`BoundReferenceExpression`(`ResolveColumnRefs`,`:742-750`)适配物理 plan。
`ValidateSortExpressionColumns` 校验排序表达式引用的列仍存在(`:762`)。

### 4.2 DuckLakeSort 结构

`ducklake_sort_data.hpp:19-34`:

```cpp
struct DuckLakeSortField {
	idx_t sort_key_index = 0;     // 排序键序号
	string expression;            // 排序表达式原文(SQL 字符串,允许非裸列表达式)
	string dialect;               // 方言标记,目前仅消费 "duckdb"
	OrderType sort_direction;     // ASC / DESC
	OrderByNullType null_order;   // NULLS FIRST / LAST
};
struct DuckLakeSort {
	idx_t sort_id = 0;            // 排序方案 id
	vector<DuckLakeSortField> fields;
};
```

`BuildSortOrderSQL`(`ducklake_sort_data.cpp:17-58`)把 fields 还原成 ORDER BY 子句字符串,供
flush inlined data 在元数据连接上执行查询时使用;若 flush 时列已改名,会重新 parse 表达式并按
当前列名 → inlined 表列名的 rename map 改写列引用。

## 五、DELETE

### 5.1 算子结构与 row-id 三元组

`DuckLakeCatalog::PlanDelete`(`ducklake_delete.cpp:680-693`)从 `LogicalDelete.expressions[1..3]`
取出三个 `BoundReferenceExpression` 的下标作为 `row_id_indexes` —— 它们对应 DuckLake 表暴露的
row id 列组合(`DuckLakeTableEntry::GetRowIdColumns`,`ducklake_table_entry.cpp:407-414`):
`rowid` 之外还有 `filename`(VARCHAR)、`file_index`(UBIGINT)、`file_row_number`(BIGINT)三个
multi-file 虚拟列。也就是说 DELETE 的子 plan 是一次普通的 DuckLake scan,只是额外投影出"这行在
哪个文件的第几行"。

`DuckLakeDelete::PlanDelete`(`:660-678`)还做一件关键接线:`FindDeleteSource`(`:635-658`)在子
plan 里找到发出 `file_row_number` 的 `PhysicalTableScan`,把其 file list 的扩展信息
(`GetFilesExtended`,含每个文件的 file_id、行数、既有 delete file 信息)灌进共享的
`DuckLakeDeleteMap`(`ducklake_delete.hpp:87-132`,`filename → DuckLakeFileListExtendedEntry` +
`filename → 既有 DuckLakeDeleteData` 两张 map,带锁),并把它同时挂到 scan 的
`DuckLakeMultiFileReader` 上——scan 读到某文件的既有 deletes 时会填进这张 map,供 Finalize 合并(§5.5)。

### 5.2 Sink:按文件分组收集行号

`Sink`(`:295-340`)逐行读 `(filename, file_index, file_row_number)`。local state 维护
`current_file_index` 和一段 `vector<idx_t> file_row_numbers`;file_index 变化时把已积累的行号
`Flush` 进 global state(`:233-272`)——global 端按 file_index 维护
`unordered_map<uint64_t, unique_ptr<ColumnDataCollection>> deleted_rows`(UBIGINT 单列 collection)。
这一编排假设输入大体按文件聚簇(multi-file scan 天然如此),跨文件交错时退化为频繁加锁 flush 但仍正确。
`ParallelSink() = true`。

### 5.3 Finalize:FlushDelete 决策树

`Finalize`(`:577-608`)对每个文件调用 `FlushDelete`(`:473-575`),决策顺序:

1. 行号去重排序进 `set<idx_t>`;若有重复且 `allow_duplicates = false`(UPDATE 路径),抛
   `"The same row was updated multiple times"`(`:487-490`);
2. **事务本地 inlined data** → `transaction.DeleteFromLocalInlinedData`,直接从内存里删(`:492-496`);
   **已提交 inlined data** → `transaction.AddNewInlinedDeletes`,deletes 直接进元数据,不写文件
   (`:497-501`;inlined 细节见 08);
3. **inlined file deletions**:若 data inlining 开启且本次删除行数 ≤ 阈值,deletes 作为行内数据写进
   元数据目录的 inlined-deletes 表(`AddNewInlinedFileDeletes`,`:509-524`),省一个小文件;
4. 文件已有 deletes(§5.5)→ 合并重写;
5. 否则写新 delete file:按 `WriteDeletionVectors` 配置选 Puffin DV 或 parquet(`:556-569`);
6. 任一写文件路径之前都先过 `TryDropFullyDeletedFile`(`:355-368`):删除行数 == 文件行数时整文件
   作废——已提交文件走 `transaction.DropFile`(记 end_snapshot),事务本地文件走
   `DropTransactionLocalFile`(直接从变更列表移除并删盘上文件,`ducklake_transaction.cpp:139-167`)。

Finalize 末尾(`:593-607`)把 written_files 分两路登记:`data_file_id` 有效(删的是已提交文件)→
`transaction.AddDeletes`;无效(删的是本事务新写的文件)→ `transaction.TransactionLocalDelete`(§5.6)。

### 5.4 delete file 的两种输出格式

`DuckLakeDeleteFileWriter`(`ducklake_delete.hpp:79-85`)三个入口,核心是模板函数
`WriteDeleteFileInternal`(`ducklake_delete.cpp:31-148`):

- **parquet positional delete file**:不经过物理 plan,直接手工驱动 parquet copy function 的
  bind/init/sink/combine/finalize 五段(`:67-132`)。schema 为 `file_path`(VARCHAR,常量向量)+
  `pos`(BIGINT,升序行号);field id 取 Iceberg 的保留值
  (`FILENAME_FIELD_ID` / `ORDINAL_FIELD_ID`,`:45-47`),即**文件本身与 Iceberg positional delete
  兼容**。带快照版本(`WriteDeleteFileWithSnapshots`)时追加第三列
  `_ducklake_internal_snapshot_id`(`LAST_UPDATED_SEQUENCE_NUMBER_ID`),逐位置记录该删除生效的
  snapshot,并把最小值记为 delete file 的 `begin_snapshot`(`:96-112`、`:144-146`);
- **Puffin deletion vector**(`WriteDeletionVectorFile`,`:159-185`):位置集合经
  `DuckLakeDeletionVectorData::ToBlob` 序列化(Iceberg V3 Puffin blob,格式见 06),直接
  `fs.OpenFile + Write` 落盘,`format = DeleteFileFormat::PUFFIN`。

选择开关 `WriteDeletionVectors`(`ducklake_catalog.hpp:204-207`)读配置项
`write_deletion_vectors`,**默认 `"false"`**;选项描述明确标注
`[EXPERIMENTAL - do not use outside testing]`(`src/functions/ducklake_options.cpp:38`),
可经 ATTACH 选项、`ducklake_set_option`、或全局 `SET ducklake_write_deletion_vectors` 打开
(`ducklake_extension.cpp:48`、`ducklake_catalog.cpp:221-224`)。DV 不支持 per-position snapshot,
合并时退化为平面位置集合(`FlushMergedDeletionVector` 注释,`:376-378`)。

### 5.5 对既有 delete file 的合并重写(核实:整体重写,非追加)

DuckLake 的不变式是**每个数据文件至多挂一个有效 delete file**。同一文件被再次 DELETE 时
(`FlushDelete:526-550`),旧 deletes(scan 时已被灌进 `delete_map` 的 `DuckLakeDeleteData`)与新
deletes 合并后**重写一个全新 delete file**,旧文件被标记 `overwrites_existing_delete = true` 并通过
`overwritten_delete_file{delete_file_id, path}` 记账,提交时从元数据删除(并清理磁盘文件)。分两种:

- 既有 deletes 来自**已提交** delete file(`data_file_info.delete_file_id` 有效)或本身带嵌入
  snapshot:走 `FlushDeleteWithSnapshots`(`:406-471`)——老位置保留原 snapshot(无嵌入时统一用老
  delete file 的 `begin_snapshot` 兜底,见 `MergeDeletesWithSnapshots`,`ducklake_delete.hpp:31-57`),
  新位置赋 `当前 snapshot_id + 1`(预期提交快照,`:422-423`),写带 snapshot 列的 delete file,
  并记录 `max_snapshot`。per-position snapshot 让时间旅行读(`[begin, end)` 左闭右开可见性)能区分
  "这行是哪个快照删的";
- 既有 deletes 是**本事务**早先写的(无元数据 id、无嵌入 snapshot):直接并集后按普通路径重写(`:542-550`)。

### 5.6 对事务本地新文件的 DELETE(核实:不改 parquet,挂 delete file 到内存结构)

删除本事务刚 INSERT 的文件时,**数据文件不动,照样写 delete file**,但登记方式不同:
`TransactionLocalDelete`(`ducklake_transaction.cpp:564-590`)在 `LocalTableChanges` 里找到对应的
`DuckLakeDataFile`,把新 delete file 挂进其 `delete_files` 成员(若已有旧的事务本地 delete file,
先删盘上旧文件再替换)。提交时这些 delete file 跟随数据文件一起写入元数据
(`ducklake_transaction_state.cpp:974-979`)。唯一"直接改内存"的情形是事务本地 **inlined data**
(§5.3 第 2 步)。对已提交文件的 `AddDeletes` 路径中,同文件的旧 REGULAR delete file 也会被新的
顶替并删除(`AddDeletesToMap`,`ducklake_transaction.cpp:613-638`)。

## 六、UPDATE = DELETE + INSERT

### 6.1 BindUpdateConstraints:整行重写(核实)

`DuckLakeTableEntry::BindUpdateConstraints`(`ducklake_update.cpp:289-332`)把
`update.update_is_del_and_insert = true`,并对**所有未被 SET 的物理列**补上 `i = i` 形式的伪更新
表达式(向 `LogicalGet` 补投影、向 `LogicalUpdate.columns` 追加)。因此到物理算子时
`op.columns` 覆盖全部物理列——**UPDATE 重写整行**,新文件是完整行的 parquet,而不是只含更新列;
这是 copy-on-write 到新文件 + positional delete 旧行的必然要求。

### 6.2 算子结构:Operator + 内嵌 delete_op

`DuckLakeUpdate`(`:44-51`)是一个 **Operator**(非 Sink),child 是 scan plan,同时持有一个
**不在算子树 children 里的** `DuckLakeDelete &delete_op`(同一 child 构造,
`PlanUpdateOperator:233-234`,`allow_duplicates = false`)。输入 chunk 布局:前段为全部物理列的新值
来源列,`row_id_index` 处是 rowid,**尾部 3 列**(`DELETION_INFO_SIZE = 3`,
`ducklake_update.hpp:30`)是 `(filename, file_index, file_row_number)` 删除信息。

`Execute`(`:111-179`)每个 chunk 做四件事:去重(§6.3)→ 用 `ExpressionExecutor` 求值 SET 表达式
得到新行 → 输出 chunk = 新行 + rowid(交给上方 COPY 写新文件,`virtual_columns = WRITE_ROW_ID`,
即**新文件里嵌入 `_ducklake_internal_row_id` 列,row_id 保持不变**)→ 把尾部 3 列切出
`delete_chunk`,手工调用 `delete_op.Sink` 旁路灌入。生命周期同样手工托管:
`GetGlobalOperatorState` 初始化 `delete_op.sink_state`(`:79-84`),`FinalExecute` 调
`delete_op.Combine`(`:181-194`),`OperatorFinalize` 调 `delete_op.Finalize`(`:196-204`)——
即 DELETE 的全部写出动作发生在 UPDATE 算子的 finalize 阶段。

`PlanUpdate`(`:259-287`)的外层拼装与 INSERT 相同:`DuckLakeUpdate` 之上可插 `DuckLakeInlineData`,
再接 `PlanCopyForInsert` + `PlanInsert`。注意 UPDATE 链上**没有 PhysicalOrder**(sort_on_insert 只
作用于 INSERT plan)。

### 6.3 first-write-wins 去重(核实语义)

`DuckLakeUpdateGlobalState`(`:56-66`)持有全局
`mutex seen_rows_lock + unordered_set<FileRowId, FileRowIdHash> seen_rows`,key 为
`{file_index, row_number}`(`:29-42`)。`Execute` 开头在锁内对每行做 `seen_rows.insert`,**只保留
首次出现的行**,重复行整体从 chunk 中 slice 掉(`:127-147`)——既不再次求值,也不会再进 delete。
语义上:

- 这是**单条语句内**的去重(GlobalOperatorState 随语句生命周期),针对 `UPDATE ... FROM` 等 join
  产生多重匹配的场景:同一目标行匹配多次时,"第一个到达的匹配"生效,其余静默丢弃;并行下哪个先到
  不确定,因此多匹配时结果是非确定的(first-write-wins 而非报错——与之相对,DELETE 端
  `allow_duplicates=false` 的报错检查因为这里已去重而通常不会触发,只是兜底);
- **同事务两条 UPDATE 语句**更新同一行不受此影响:第二条语句看到的是第一条写出的事务本地新文件,
  其删除走 §5.6 的 `TransactionLocalDelete` 路径,正常叠加。

### 6.4 与 MERGE 共享

`PlanUpdateOperator` 被 `PlanUpdate` 和 MERGE 的 UPDATE 分支共用;后者通过覆写
`update_op.row_id_index`(rowid 在 MERGE 输入里位于删除信息之前,
`ducklake_merge_into.cpp:450-451`)适配不同的输入布局。

## 七、MERGE INTO

### 7.1 总体结构

`DuckLakeCatalog::PlanMergeInto`(`ducklake_merge_into.cpp:547-576`)把每个
`BoundMergeIntoAction` 翻译成一个 `MergeIntoOperator`(action 算子),装进 DuckDB 内核的
`PhysicalMergeInto`;join 后的行由内核算子按 WHEN 条件路由到各 action 的算子上。当前限制:**整条
MERGE 至多一个 UPDATE/DELETE action**(`:558-566`),否则
`NotImplementedException`;`RETURNING` 不支持(`:549-551`)。

难点在于 action 算子拿到的是 Operator/Sink 混合语义,而 DuckLake 的 INSERT 链顶端
(`PhysicalCopyToFile`)是个标准 Sink、`DuckLakeInsert` 又要消费 COPY 的 Source 输出。两个包装算子
解决这一阻抗失配,共同的骨架是:COPY 算子脱离主算子树(child 是只为提供 types 的
`PhysicalDummyScan`,`:465-466`、`:523-525`),包装算子手工持有 `copy.sink_state` 并把数据 Sink 进
去;Finalize 时注册 `DuckLakeFinalizeCopyToInsertEvent`(`:170-185`)——一个 pipeline event,在
COPY Finalize 完成后执行 `FinalizeCopyToInsert`(`:127-168`):手工驱动 copy 作为 Source 取出文件
统计 chunk,逐个 Sink 进 `DuckLakeInsert` 并走完其 Combine/Finalize,完成事务登记。

### 7.2 MERGE_INSERT:DuckLakeMergeInsert

`DuckLakeMergeInsert`(`:26-63`)持有 `copy` 与 `insert` 两个引用。`Sink`(`:112-118`)把路由来的
行经 `ProjectAndCastForCopy`(`:80-98`,共享 helper:先执行 `extra_projections`——非 identity 分区
的 transform 表达式,再按 `PhysicalCopyToFile::expected_types` 逐列 cast)后直接 Sink 进 copy;
`Combine` 透传;`Finalize`(`:187-199`)先挂 finalize event 再 finalize copy。INSERT 分支的
`column_index_map` 重排/默认值填充在 plan 期完成(`:501-515`)。

### 7.3 MERGE_UPDATE:DuckLakeMergeUpdate

`DuckLakeMergeUpdate`(`:225-265`)是四件套协调器:`update_op`(§6 的 `DuckLakeUpdate`,内嵌
delete)、可选 `inline_data_op`、`copy_op`、`insert_op`,全部手工托管 state。`Sink`(`:317-359`):
chunk → `update_op.Execute`(去重 + SET 求值 + 旁路 delete)→ 输出有 inlining 时过
`inline_data_op.Execute`(吸收或穿透)→ `ProjectAndCastForCopy` → `copy_op.Sink`。`Combine`
(`:361-390`)排空 inline 算子的 FinalExecute 残留并依次 combine;`Finalize`(`:392-414`)按
update(触发 delete 写出)→ inline → finalize event → copy 的顺序收尾。

### 7.4 MERGE_DELETE

最简单:构造一个临时 `LogicalDelete`,expressions[1..3] 指向 MERGE 输出布局中
`row_id_start + 1..3` 处的三个虚拟列,直接复用 `catalog.PlanDelete`(`:481-493`)。
`MERGE_ERROR` / `MERGE_DO_NOTHING` 不涉及写路径(`:536-540`)。

## 八、Finalize 与事务登记

### 8.1 调用点汇总

写路径与事务本地变更容器(`LocalTableChanges`,结构归 02)的全部交点:

| 调用点 | 入口 | 落点 |
|---|---|---|
| INSERT/CTAS/UPDATE/MERGE 新数据文件 | `DuckLakeInsert::Finalize` → `DuckLakeTransaction::AppendFiles`(`ducklake_transaction.cpp:1599-1603`) | `LocalTableChanges::AppendFiles`(`:169-182`)→ `new_data_files` |
| 对已提交文件的 deletes | `DuckLakeDelete::Finalize` → `AddDeletes`(`:1653-1656`) | `AddDeletesToMap`(`:613-638`)→ `new_delete_files[data_file_path]`,顶替旧 REGULAR delete file |
| 对事务本地文件的 deletes | 同上 → `TransactionLocalDelete`(`:1691-1695`) | 挂到对应 `DuckLakeDataFile.delete_files` |
| 整文件删空 | `TryDropFullyDeletedFile` → `DropFile` / `DropTransactionLocalFile` | 元数据置 end_snapshot / 当场移除+删盘 |
| inlined data 的 insert/delete | `AppendInlinedData` / `DeleteFromLocalInlinedData` / `AddNewInlinedDeletes` | 见 08 |

回滚清理:`LocalTableChanges::CleanupFiles`(`:592-611`)删除所有已写出的数据文件与 delete file。

### 8.2 DuckLakeDataFile 结构

`ducklake_data_file.hpp:59-80`,写路径的核心内存载体(写出后、提交前的文件描述):

```cpp
struct DuckLakeDataFile {
	string file_name;                  // 文件完整路径(ducklake-<uuidv7>.parquet)
	idx_t row_count;                   // 文件行数(COPY 返回 chunk 第 1 列)
	idx_t file_size_bytes;             // 文件大小
	optional_idx footer_size;          // parquet footer 大小(加密读取需要)
	optional_idx partition_id;         // 写入时表的分区方案 id
	vector<DuckLakeDeleteFile> delete_files;          // 同事务内对本文件追加的 delete file(§5.6)
	map<FieldIndex, DuckLakeColumnStats> column_stats; // 逐列统计(§2)
	vector<DuckLakeFilePartition> partition_values;    // 本文件的分区值(§3.2)
	string encryption_key;             // per-file 加密 key(§1.5)
	MappingIndex mapping_id;           // name mapping id(add_files 等外部文件路径使用)
	optional_idx begin_snapshot;       // 仅 flush 路径:文件内最小 snapshot_id
	optional_idx max_partial_file_snapshot; // 仅 flush 路径:文件内最大 snapshot_id(partial file)
	optional_idx flush_row_id_start;   // 仅 flush 路径:文件内嵌 row_id 的最小值(§2.1)
	bool created_by_ducklake = true;   // false 表示外部文件(add_files)
};
```

### 8.3 row_id_start 何时定(★核实:提交时,不在写时)

`DuckLakeDataFile` **没有** `row_id_start` 字段——普通 INSERT 写出的 parquet 不嵌 row_id 列,写入
期也无法知道起始 row_id(并发事务都在追加)。该值在**提交期**才确定:
`DuckLakeTransactionState::GetNewDataFiles`(`ducklake_transaction_state.cpp:928` 起)按表取全局
统计 `DuckLakeTableStats`,对每个新文件:

```cpp
// ducklake_transaction_state.cpp:971-973
auto row_id_start = file.flush_row_id_start.IsValid()
                        ? file.flush_row_id_start.GetIndex()   // flush 的文件保留原 row_id 区间
                        : new_stats.next_row_id;               // 普通插入:从全局 next_row_id 分配
auto data_file = GetNewDataFile(file, commit_state, table_id, row_id_start);
```

随后 `new_stats.MergeFileStats(file)` 推进 `next_row_id`(inlined data 同理,`:995-1014`;
`next_row_id` 单调前进、只继承不重算,`:814` 注释)。`row_id_start` 最终落在
`DuckLakeFileInfo.row_id_start`(`ducklake_metadata_info.hpp:163`),经
`BuildDataFileInfo`(`ducklake_transaction.cpp:1228-1251`)写入 `ducklake_data_file` 表。读侧用
`row_id_start + file_row_number` 重构每行 rowid(见 06)。提交冲突重试时该流程整体重跑,保证
row_id 区间与最终提交快照一致(见 03)。

### 8.4 DuckLakeDeleteFile 结构

`ducklake_data_file.hpp:41-57`:

```cpp
struct DuckLakeDeleteFile {
	DataFileIndex data_file_id;        // 目标数据文件的元数据 id(事务本地文件时无效)
	string data_file_path;             // 目标数据文件路径(与 delete file 配对的依据)
	string file_name;                  // delete file 自身路径
	DeleteFileFormat format;           // PARQUET(positional)或 PUFFIN(DV)
	idx_t delete_count;                // 删除位置数
	idx_t file_size_bytes;             // delete file 大小
	idx_t footer_size;                 // parquet footer 大小(PUFFIN 为 0)
	string encryption_key;             // 加密 key
	bool overwrites_existing_delete;   // 是否顶替既有 delete file(§5.5)
	DuckLakeOverwrittenDeleteFile overwritten_delete_file; // 被顶替者 {delete_file_id, path},提交时删
	optional_idx begin_snapshot;       // 文件内最小删除生效 snapshot(带 snapshot 列时)
	optional_idx max_snapshot;         // 文件内最大删除生效 snapshot(partial delete file)
	DeleteFileSource source;           // REGULAR(DELETE 语句)/ FLUSH(flush inlined data 产生)
};
```

提交时经 `GetNewDeleteFiles`(`ducklake_transaction_state.cpp:551` 起)与 `GetNewDeleteFile`
(`ducklake_transaction.cpp:1253-1269`)分配 `data_file_id` 并写入 `ducklake_delete_file` 表;
事务本地文件上的 deletes 在数据文件拿到正式 id 后回填 `data_file_id`
(`ducklake_transaction_state.cpp:974-979`)。
