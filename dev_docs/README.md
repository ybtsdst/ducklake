# DuckLake 源码走读系列

本目录是 DuckLake 扩展(DuckDB lakehouse 格式)的源码走读文档,面向有 DuckDB 内核经验的
DB 内核工程师,聚焦实现细节:关键调用链、结构体字段、设计取舍,不做概念科普。

**源码基准:commit `47187559`(2026-06-11,local_dev 分支)。** 文中所有 `file:line`
引用以该版本为准,代码演进后行号会漂移,但函数/类名与章节结构仍可作为定位锚点。

## 架构总图

```
                              DuckDB core
        ┌─────────────────────────┼─────────────────────────────┐
        │ ATTACH/Catalog API      │ Optimizer/Executor          │ CALL ...
        ▼                         ▼                             ▼
┌──────────────────┐   ┌─────────────────────────┐   ┌──────────────────────┐
│ DuckLakeCatalog   │   │ 数据面                  │   │ 表函数 (10)           │
│ schema 缓存/entry │   │  Scan (06)              │   │  CDC / 检查 / 配置    │
│ 配置作用域 (01)   │   │  INSERT/DELETE/UPDATE/  │   │ 维护操作 (09)         │
└────────┬─────────┘   │  MERGE (07)             │   │  CHECKPOINT/compaction│
         │             │  data inlining (08)     │   │  /expire/cleanup/     │
         ▼             └───────────┬─────────────┘   │  add_data_files       │
┌──────────────────┐               │ 变更登记          └──────────┬───────────┘
│ DuckLakeTransaction│◄────────────┘                             │
│ 快照模型/本地变更  │                                            │
│ state (02)        │──── 提交协议:乐观并发+重试 (03) ───────────┤
└────────┬─────────┘     server-side / staged commit            │
         ▼                                                      ▼
┌───────────────────────────────────────────────────────────────────────┐
│ DuckLakeMetadataManager:SQL 生成/方言/迁移 (05)                        │
│   后端:DuckDB 本地 │ Postgres │ SQLite │ quack(远端 DuckDB server)   │
└────────────────────────────┬──────────────────────────────────────────┘
                             ▼
   metadata db:28 张 ducklake_* 表 + per-table 动态内联表 (04)
   data path:ducklake-<uuidv7>.parquet + delete file / deletion vector
```

## 文档导览

| # | 文档 | 定位 | 核心源码 |
|---|------|------|---------|
| 01 | [ATTACH_CATALOG_DESIGN.md](ATTACH_CATALOG_DESIGN.md) | ATTACH 初始化、schema 缓存(ObjectCache+query pin)、catalog entry 体系、field id、配置作用域、secret | ducklake_storage / initializer / catalog / *_entry |
| 02 | [TRANSACTION_DESIGN.md](TRANSACTION_DESIGN.md) | 事务生命周期、DuckLakeSnapshot 快照模型、lazy 快照与 AT 时间旅行、本地变更 state、事务内可见性、回滚清理 | ducklake_transaction(前半)/ transaction_state |
| 03 | [COMMIT_PROTOCOL_DESIGN.md](COMMIT_PROTOCOL_DESIGN.md) | 乐观并发提交:重试循环、冲突矩阵、SQL batch、server-side / staged commit | transaction(后半)/ transaction_changes / server_side_commit / staged_commit |
| 04 | [METADATA_SCHEMA_DESIGN.md](METADATA_SCHEMA_DESIGN.md) | 元数据库数据字典:28 张表逐列、**[begin_snapshot, end_snapshot) 左闭右开可见性**、动态内联表、版本演进 | metadata_manager 建表 SQL / metadata_info.hpp |
| 05 | [METADATA_MANAGER_DESIGN.md](METADATA_MANAGER_DESIGN.md) | MetadataManager 通信层:接口面、filter 下推 SQL 生成、路径解析、迁移框架、Postgres/SQLite/quack 方言 | metadata_manager.cpp / src/metadata_manager/* |
| 06 | [SCAN_DESIGN.md](SCAN_DESIGN.md) | 读路径:文件列表与事务本地叠加、文件级裁剪、delete filter 与 deletion vector、name map、虚拟列 | scan / multi_file_list / multi_file_reader / delete_filter / deletion_vector |
| 07 | [DML_DESIGN.md](DML_DESIGN.md) | 写路径:INSERT 算子链与文件命名、统计收集、分区/排序写入、DELETE/UPDATE/MERGE | insert / delete / update / merge_into / partition_data / sort_data |
| 08 | [DATA_INLINING_DESIGN.md](DATA_INLINING_DESIGN.md) | data inlining:三阶段写入算子、内联表存储、读取混入、flush 落盘全流程 | inline_data / inlined_data* / flush_inlined_data |
| 09 | [MAINTENANCE_DESIGN.md](MAINTENANCE_DESIGN.md) | CHECKPOINT 编排、compaction(merge_adjacent/rewrite)、expire_snapshots、文件清理、add_data_files | checkpoint / compaction_functions / expire / cleanup / add_data_files |
| 10 | [TABLE_FUNCTIONS_DESIGN.md](TABLE_FUNCTIONS_DESIGN.md) | 表函数全目录、CDC 三件套(table_insertions/deletions/changes)、配置函数、murmur3 | src/functions/* |

## 推荐阅读顺序

- **初读主线**:01 → 02 → 03 → 06 → 07,先建立控制面(catalog→事务→提交)再走数据面(读→写)。
- **参考字典**:04(表结构)、05(manager 接口)不必通读,按别篇链接跳转查阅。
- **专题**:08(inlining)、09(维护)、10(表函数)独立成篇,按需阅读。

## 全系列共用约定

- 版本可见性统一为左闭右开 `[begin_snapshot, end_snapshot)`,谓词
  `{SNAPSHOT_ID} >= begin_snapshot AND ({SNAPSHOT_ID} < end_snapshot OR end_snapshot IS NULL)`,
  详见 04 §1.3。
- `snapshot_id` 每次提交 +1;`schema_version` 仅 DDL 提交时 +1,schema 按 schema_version
  缓存(01 §四)。
- 事务本地对象 id 从 `2^63` 起、事务本地 row_id 从 `10^18` 起(02 §六)。
- 数据文件名 `ducklake-{uuidv7}.parquet`,delete file 名 `ducklake-<uuidv7>-delete.parquet/.puffin`(07 §一/§五)。
