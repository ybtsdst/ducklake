# ATTACH_CATALOG_DESIGN.md — ATTACH 初始化与 Catalog 体系

> 行号基准:HEAD = 47187559(`471875597ed5ed38e2a29a6e4671672977999f34`)。

## 概述

DuckLake 以 DuckDB `StorageExtension` 的形式接入:`ATTACH 'ducklake:...'` 经由注册在
`DBConfig` 上的 attach 回调 `DuckLakeAttach` 构造出一个 `DuckLakeCatalog`(`Catalog` 子类),
随后 DuckDB core 调用 `Catalog::FinalizeLoad`,DuckLake 在其中通过 `DuckLakeInitializer`
完成真正的初始化:把元数据库(DuckDB/SQLite/Postgres/quack)作为一个隐藏 catalog ATTACH
进当前 instance、判定是加载既有 DuckLake 还是新建、解析格式版本并按需迁移、最后探测
metadata server 的可选能力(server-side commit)。

与 DuckDB 内置 catalog 最大的不同在于:DuckLake 的 catalog 内容不常驻、不带版本链
(没有 `CatalogEntry` 的 MVCC chain)。每个 `schema_version` 对应一份**不可变**的
`DuckLakeCatalogSet`(schema/table/view/macro 全量物化),按
`ducklake:<name>:<metadata_path>:<instance_id>:schema:<schema_version>` 为 key 缓存在
DuckDB instance 级的 `ObjectCache` 中;查询期间通过 `ClientContext::registered_state`
里的 `DuckLakeSchemaPinState` 把 `shared_ptr` pin 到 query 结束,保证 binder 拿到的裸引用
在 cache 被并发失效(commit / expire_snapshots / flush inlined data)时依然安全。

事务对象(`DuckLakeTransaction`)只在本文涉及 initializer 与 snapshot 获取的最小切面,
完整生命周期见 [TRANSACTION_DESIGN.md](TRANSACTION_DESIGN.md)。

```
                          DuckDB instance
  ┌─────────────────────────────────────────────────────────────────┐
  │  ATTACH 'ducklake:...'                                          │
  │     │                                                           │
  │     ▼                                                           │
  │  DuckLakeStorageExtension ── attach ──► DuckLakeAttach          │
  │                                              │                  │
  │                                              ▼                  │
  │  ┌──────────────────────── DuckLakeCatalog ────────────────┐    │
  │  │ DuckLakeOptions / instance_id / last_committed_snapshot │    │
  │  │ FinalizeLoad ──► DuckLakeInitializer::Initialize        │    │
  │  │ GetSchemaForSnapshot(schema_version → CatalogSet)       │    │
  │  └───────┬───────────────────────────────┬─────────────────┘    │
  │          │ MetadataManager(SQL)          │ ObjectCache          │
  │          ▼                               ▼                      │
  │  ┌──────────────────────┐   ┌─────────────────────────────┐     │
  │  │ metadata db(隐藏 ATTACH│  │ DuckLakeSchemaCacheEntry     │     │
  │  │ __ducklake_metadata_X)│  │  └ DuckLakeCatalogSet(不可变)│     │
  │  │ duckdb/sqlite/pg/quack│  │ DuckLakeTableStatsCacheEntry │     │
  │  └──────────────────────┘   └─────────────────────────────┘     │
  └─────────────────────────────────────────────────────────────────┘
              │ data_path(尾部保证以分隔符结尾)
              ▼
       data files(parquet / dv puffin),按 schema/table 子目录组织
```

关键源码位置:

| 主题 | 文件 |
|---|---|
| 扩展入口、选项/函数/secret 注册 | `src/ducklake_extension.cpp` |
| attach 回调、`DuckLakeOptions` 解析 | `src/storage/ducklake_storage.cpp`、`src/include/common/ducklake_options.hpp` |
| 初始化器(ATTACH 元数据库、版本迁移、能力探测) | `src/storage/ducklake_initializer.cpp` |
| Catalog 本体、schema 缓存、配置作用域 | `src/storage/ducklake_catalog.cpp`、`src/include/storage/ducklake_catalog.hpp` |
| 每 schema_version 的 entry 容器 | `src/storage/ducklake_catalog_set.cpp` |
| schema/table/view/macro entry | `src/storage/ducklake_schema_entry.cpp`、`ducklake_table_entry.cpp`、`ducklake_view_entry.cpp`、`src/include/storage/ducklake_macro_entry.hpp` |
| field id(schema evolution 根基) | `src/storage/ducklake_field_data.cpp` |
| secret、autoload、内置 macro、日志类型 | `src/storage/ducklake_secret.cpp`、`ducklake_autoload_helper.cpp`、`ducklake_default_functions.cpp`、`ducklake_log_type.cpp` |

## 关联文档

- [TRANSACTION_DESIGN.md](TRANSACTION_DESIGN.md) — 事务生命周期、快照模型、transaction-local 变更
- [COMMIT_PROTOCOL_DESIGN.md](COMMIT_PROTOCOL_DESIGN.md) — 提交重试、冲突检测、server-side/staged commit
- [METADATA_SCHEMA_DESIGN.md](METADATA_SCHEMA_DESIGN.md) — `ducklake_*` 元数据表数据字典(含配置存储表)
- [METADATA_MANAGER_DESIGN.md](METADATA_MANAGER_DESIGN.md) — MetadataManager 接口、SQL 生成、迁移与多后端
- [TABLE_FUNCTIONS_DESIGN.md](TABLE_FUNCTIONS_DESIGN.md) — `ducklake_set_option` 等表函数
- [DATA_INLINING_DESIGN.md](DATA_INLINING_DESIGN.md) — data inlining(本篇只涉及 `data_inlining_row_limit` 的作用域解析)

## 一、扩展入口与注册

### 1.1 LoadInternal

入口是 `src/ducklake_extension.cpp:19` 的 `LoadInternal(ExtensionLoader &)`,做四类注册:

1. **日志类型**:`instance.GetLogManager().RegisterLogType(make_uniq<DuckLakeMetadataLogType>())`
   (`src/ducklake_extension.cpp:23`),见 8.3。
2. **storage extension**:`StorageExtension::Register(config, "ducklake", make_shared_ptr<DuckLakeStorageExtension>())`
   (`src/ducklake_extension.cpp:26`),使 `ATTACH 'ducklake:...'` / `ATTACH ... (TYPE ducklake)` 路由到本扩展。
3. **扩展选项**(`AddExtensionOption`,全部 `SetScope::GLOBAL`),见 1.2。
4. **表函数 + secret + scalar 函数**:`src/ducklake_extension.cpp:52-125` 注册
   `ducklake_snapshots`/`ducklake_table_info`/`ducklake_merge_adjacent_files`/`ducklake_expire_snapshots`
   等约 20 个表函数(逐个清单与语义见 [TABLE_FUNCTIONS_DESIGN.md](TABLE_FUNCTIONS_DESIGN.md));
   `ducklake_scan` 在 `:113-114` 显式注册以支持计划反序列化;secret type 与
   `CREATE SECRET (TYPE ducklake)` 函数在 `:117-121`;`:124-125` 注册 `murmur3_32`
   (Iceberg 兼容 bucket partitioning 用的 hash)。

### 1.2 扩展选项一览

均在 `src/ducklake_extension.cpp:28-50` 注册:

| 选项 | 类型 | 默认值 | 含义 |
|---|---|---|---|
| `ducklake_max_retry_count` | UBIGINT | 10 | 事务提交最大重试次数 |
| `ducklake_retry_wait_ms` | UBIGINT | 100 | 重试间隔 |
| `ducklake_retry_backoff` | DOUBLE | 1.5 | 重试等待的指数退避因子 |
| `ducklake_default_data_inlining_row_limit` | UBIGINT | 10 | data inlining 默认行数上限(0 关闭) |
| `ducklake_default_version` | VARCHAR | NULL | 新建 catalog 的默认 DuckLake 格式版本 |
| `ducklake_target_file_size` | VARCHAR | NULL | 写入/compaction 目标文件大小,set 回调里用 `DBConfig::ParseMemoryLimit` 预校验(`:40-46`) |
| `ducklake_write_deletion_vectors` | BOOLEAN | false | [EXPERIMENTAL] 写 Iceberg V3 deletion vector(puffin)而非 positional delete parquet |

注意这些是 DuckDB setting,与持久化在元数据表里的 catalog 级配置(第七节)是两套体系;
二者的合并优先级因选项而异(见 7.2)。

## 二、DuckLakeAttach 与参数解析

### 2.1 attach 回调与路径三分支

`DuckLakeStorageExtension` 构造函数(`src/storage/ducklake_storage.cpp:134-137`)只填两个回调:
`attach = DuckLakeAttach`、`create_transaction_manager = DuckLakeCreateTransactionManager`
(后者 `:128-132`,构造 `DuckLakeTransactionManager`,归
[TRANSACTION_DESIGN.md](TRANSACTION_DESIGN.md))。

`DuckLakeAttach`(`src/storage/ducklake_storage.cpp:72-126`)对 `info.path` 三分支:

1. **空路径**:加载名为 `__default_ducklake` 的默认 secret(`DuckLakeSecret::DEFAULT_SECRET`,
   `src/include/storage/ducklake_secret.hpp:18`),没有则报错(`:77-83`)。
2. **纯名字**(`PathIsSecret`:只含字母数字和 `_`,`src/storage/ducklake_secret.cpp:18-30`):
   按 secret 名加载;找不到时报错并提示 `duckdb:` 前缀写法(`:84-91`)。
3. **其余**:整段作为 `options.metadata_path`(`:92-95`)。

若命中 secret,把 `KeyValueSecret::secret_map` 的每个 kv 喂给 `HandleDuckLakeOption`(`:96-102`);
之后再遍历 `attach_options.options`(ATTACH 语句括号里的选项)同样喂给
`HandleDuckLakeOption`(`:105-110`)——即 **ATTACH 显式选项覆盖 secret 中的同名配置**(后写赢)。

收尾逻辑(`:111-125`):

- READ_ONLY 且用户没显式给 `create_if_not_exists` → 强制 `create_if_not_exists = false`;
- `metadata_database` 缺省命名为 `"__ducklake_metadata_" + name`(`:114-116`);
- 存在 `at_clause`(`SNAPSHOT_VERSION`/`SNAPSHOT_TIME`)时要求只读:READ_WRITE 直接报错,
  AUTOMATIC 被改为 READ_ONLY 并 `db.SetReadOnlyDatabase()`(`:117-123`);
- `attach_options.options["busy_timeout"] = Value::INTEGER(options.busy_timeout)`(`:124`)
  回写给外层 AttachedDatabase 选项(供 SQLite 等元数据后端);
- `make_uniq<DuckLakeCatalog>(db, std::move(options))`(`:125`)。此时**尚未接触元数据库**。

### 2.2 DuckLakeOptions

`src/include/common/ducklake_options.hpp:24-42`:

```cpp
struct DuckLakeOptions {
	string metadata_database;            // 元数据库 ATTACH 进来的 catalog 名(默认 __ducklake_metadata_<name>)
	string metadata_path;                // 元数据库连接串/路径(ATTACH 主路径或 secret 的 metadata_path)
	string metadata_schema;              // 元数据表所在 schema(空 = 元数据库默认 schema)
	string data_path;                    // 数据文件根路径(始终以分隔符结尾,见 3.2)
	bool override_data_path = false;     // 允许 data_path 与 catalog 中记录不一致
	AccessMode access_mode = AccessMode::AUTOMATIC;
	DuckLakeEncryption encryption = DuckLakeEncryption::AUTOMATIC;   // {AUTOMATIC, ENCRYPTED, UNENCRYPTED}
	bool create_if_not_exists = true;    // 元数据不存在时是否初始化新 DuckLake
	bool automatic_migration = false;    // 老版本 catalog 是否自动迁移
	bool hide_metadata_catalog = true;   // 元数据库 ATTACH 时带 HIDDEN true
	unique_ptr<BoundAtClause> at_clause; // SNAPSHOT_VERSION / SNAPSHOT_TIME(整库 time travel)
	case_insensitive_map_t<Value> metadata_parameters; // 透传给元数据库 ATTACH 的参数(TYPE、连接参数等)
	option_map_t config_options;                       // GLOBAL 作用域 catalog 配置(string→string)
	map<SchemaIndex, option_map_t> schema_options;     // SCHEMA 作用域配置
	map<TableIndex, option_map_t> table_options;       // TABLE 作用域配置
	idx_t busy_timeout = 5000;
	DuckLakeVersion ducklake_version = DuckLakeVersion::UNSET;       // 用户 pin 的格式版本
};
```

### 2.3 HandleDuckLakeOption 选项映射

`src/storage/ducklake_storage.cpp:10-70`,大小写不敏感:

| ATTACH/secret 选项 | 落点 |
|---|---|
| `data_path` / `override_data_path` | `options.data_path` / `options.override_data_path` |
| `metadata_schema` / `metadata_catalog` / `metadata_path` | 同名字段(注意 `metadata_catalog` 落 `metadata_database`) |
| `metadata_parameters`(MAP) | 逐项拆入 `options.metadata_parameters` |
| `meta_<x>`(前缀) | 等价于 metadata_parameters 中加 `<x>`(`:47-49`) |
| `encrypted`(BOOL) | `encryption = ENCRYPTED/UNENCRYPTED` |
| `data_inlining_row_limit` | 写入 `config_options["data_inlining_row_limit"]`(GLOBAL 作用域) |
| `write_deletion_vectors` | 写入 `config_options["write_deletion_vectors"]` |
| `snapshot_version` / `snapshot_time` | 构造 `BoundAtClause("version"/"timestamp", v)`;二者互斥(`:37-46`) |
| `create_if_not_exists` / `automatic_migration` / `hide_metadata_catalog` / `busy_timeout` | 同名字段 |
| `ducklake_version` | `DuckLakeVersionFromString`,要求 ≥ '1.0'(`:61-66`) |
| 其他 | `NotImplementedException` |

## 三、DuckLakeInitializer

### 3.1 FinalizeLoad → Initialize 链

DuckDB core 在 ATTACH 流程中调用 `DuckLakeCatalog::FinalizeLoad(optional_ptr<ClientContext>)`
(`src/storage/ducklake_catalog.cpp:213-234`):没有 context 时自建 `Connection` 并
`BeginTransaction`;若 `config_options` 未含 `write_deletion_vectors`,从 DuckDB setting
`ducklake_write_deletion_vectors` 补默认(`:221-226`);然后构造
`DuckLakeInitializer(*context, *this, options)` 并 `Initialize()`,成功后
`db.tags["data_path"] = DataPath()`(`:229`)、`initialized = true`。
两个 `Initialize` override(`:206-211`)分别直接抛错/为空——DuckLake 的初始化全部推迟到
FinalizeLoad,且必须有 ClientContext。

`DuckLakeInitializer` 构造函数(`src/storage/ducklake_initializer.cpp:20-23`)先行调用
`InitializeDataPath()`;主体 `Initialize()` 在 `src/storage/ducklake_initializer.cpp:64-123`,
顺序为:ATTACH 元数据库 → 决定 metadata_schema/目标版本 → `MetadataExists()` 分支 →
重取 metadata manager → `ProbeServerCapabilities()` + `ClearCache()` → AT 子句快照校验。

### 3.2 data path 初始化与扩展自动加载

`InitializeDataPath()`(`src/storage/ducklake_initializer.cpp:125-145`):data_path 为空直接返回;
否则先 `CheckAndAutoloadedRequiredExtension(data_path)`(见 8.2,例如 `s3://` 前缀触发
autoload httpfs),再去掉尾部 `/`、`\` 后**强制补一个平台分隔符**,并把分隔符写回
`catalog.Separator()`。后续所有 path 拼接(schema/table 子目录)都依赖"data_path 一定以
分隔符结尾"这个不变式。

### 3.3 ATTACH 元数据库

`Initialize()` 开头(`src/storage/ducklake_initializer.cpp:64-77`):

```cpp
const string attach_query =
    "ATTACH OR REPLACE {METADATA_PATH} AS {METADATA_CATALOG_NAME_IDENTIFIER}" + GetAttachOptions();
auto result = metadata_manager.AttachMetadata(attach_query);
```

placeholder 由 `DuckLakeMetadataManager::SubstituteCatalogPlaceholders`
(`src/storage/ducklake_metadata_manager.cpp:2379-2397`)统一替换
(`{METADATA_PATH}` → 路径字面量、`{METADATA_CATALOG}` → `catalog.schema` 标识符等);基类
`AttachMetadata` 就是 `transaction.ExecuteRaw(query)`
(`src/storage/ducklake_metadata_manager.cpp:161-165`),quack 后端则用独立 Connection 并对
连接类错误重试 5 次(`src/metadata_manager/quack_metadata_manager.cpp:34-51`)。

`GetAttachOptions()`(`src/storage/ducklake_initializer.cpp:25-62`)拼出括号选项:
显式 access mode → `READ_ONLY`/`READ_WRITE`;每个 `metadata_parameters` 项 → `key value`
(如 `TYPE postgres`);metadata_type 为空或 `duckdb` → 追加 `STORAGE_VERSION 'latest'`;
`hide_metadata_catalog` → `HIDDEN true`(所以默认元数据库对 `SHOW DATABASES` 不可见)。

ATTACH 成功后立即 `transaction.Query("FROM duckdb_secrets()")`(`:77`)——注释明言是
secret 初始化 bug 的 work-around(强制加载全部 secret)。

### 3.4 metadata_schema 与默认版本

`src/storage/ducklake_initializer.cpp:79-95`:`metadata_schema` 为空时取元数据库的默认
schema(`DuckLakeTransaction::GetDefaultSchemaName`,
`src/storage/ducklake_transaction.cpp:1529-1534`,即 `metadb->GetCatalog().GetDefaultSchema()`;
DuckDB 是 `main`,Postgres 是 `public`),并记录 `has_explicit_schema` 用于新建分支决定是否
`CREATE SCHEMA`。`ducklake_version` 仍为 UNSET 时读 setting `ducklake_default_version`
(同样要求 ≥ '1.0')。

### 3.5 MetadataExists 分支

`src/storage/ducklake_initializer.cpp:102-111`:`MetadataExists()` 直接探测已知元数据表
而非扫 `duckdb_tables()`(注释:避免一个损坏的 ducklake catalog 阻塞其它库初始化)。基类实现
(`src/storage/ducklake_metadata_manager.cpp:167-183`)执行
`SELECT NULL FROM {METADATA_CATALOG}.ducklake_metadata LIMIT 1`,**捕获 CATALOG 类异常视为
"全新 DuckLake"**,其他错误向上抛。quack 后端改查 `information_schema.tables`
(`src/metadata_manager/quack_metadata_manager.cpp:62-65,139-150`)。

- 存在 → `LoadExistingDuckLake(transaction)`;
- 不存在且 `create_if_not_exists == false` → 抛 `InvalidInputException`;
- 否则 → `InitializeNewDuckLake(transaction, has_explicit_schema)`。

分支返回后 `Initialize()` 特意**重新取一次** `transaction.GetMetadataManager()`(`:112-115`,
注释说明:两个分支都可能经 `SetVersionedMetadataManager` 换掉 manager,函数开头拿的引用
已悬空)。

### 3.6 LoadExistingDuckLake:版本解析与迁移链

`src/storage/ducklake_initializer.cpp:172-267`。`metadata_manager.LoadDuckLake()` 读回
`ducklake_metadata` 的全部 tag(存储格式见 [METADATA_SCHEMA_DESIGN.md](METADATA_SCHEMA_DESIGN.md)),
逐 tag 处理:

- **`version`**:`ResolveTargetVersion`(`:269-287`)决定目标版本——用户 pin 了用 pin 的;
  否则 `automatic_migration` 开了取 `DUCKLAKE_LATEST_VERSION`;否则 catalog 版本 ≥ V1_0 就
  原地保持,pre-1.0 一律要求显式开 `AUTOMATIC_MIGRATION`。然后:
  - catalog 比目标新 → 报错(禁止 downgrade,`:181-187`);
  - catalog 比目标老且未开 automatic_migration → 报错(`:188-193`);
  - 顺序执行迁移链 `MigrateV01 → MigrateV02 → MigrateV03 → MigrateV04 → MigrateV10`
    (`:194-225`,V0_3_DEV1/V0_4_DEV1 走带 bool 参数的对应迁移;迁移 SQL 细节归
    [METADATA_MANAGER_DESIGN.md](METADATA_MANAGER_DESIGN.md)),到达 `target_version` 即停
    (`:218-221` 的 `continue`);
  - 版本枚举:`DuckLakeVersion{UNSET, V0_1, V0_2, V0_3_DEV1, V0_3, V0_4_DEV1, V0_4, V1_0, V1_1_DEV_1}`,
    `DUCKLAKE_LATEST_VERSION = V1_1_DEV_1`(`src/include/common/ducklake_version.hpp:15-27`)。
- **`data_path`**:用户没给则 `LoadPath(tag.value)` 采纳并重跑 `InitializeDataPath()`;给了
  则要求 `StorePath(options.data_path) == tag.value`,不一致且未设 `override_data_path` 直接
  抛 `InvalidConfigurationException`(`:232-245`)。
- **`encrypted`**:`"true"/"false"` → `catalog.SetEncryption(...)`(`:246-254`)。
- 所有 tag(含上述)统一落 `options.config_options[tag.key] = tag.value`(`:255`)——这就是
  GLOBAL 作用域配置的加载点;随后 `metadata.schema_settings` / `metadata.table_settings`
  分别灌入 `options.schema_options[schema_id]` / `options.table_options[table_id]`(`:257-262`),
  构成第七节的三级配置。
- 最后按 resolved_version 调 `SetVersionedMetadataManager`(`:264-266`)。

### 3.7 InitializeNewDuckLake

`src/storage/ducklake_initializer.cpp:147-170`:

- `data_path` 为空时,仅当元数据库是 DuckDB 原生 catalog(`IsDuckCatalog()`)才允许兜底:
  取其 DB 文件路径加 `.files` 作为默认 data path 并重跑 `InitializeDataPath()`;否则报错要求
  显式 `DATA_PATH`(`:148-159`)。
- 版本取 `ducklake_version`(UNSET 则 `DUCKLAKE_LATEST_VERSION`),先
  `SetVersionedMetadataManager`,再 `metadata_manager.InitializeDuckLake(has_explicit_schema,
  catalog.Encryption())` 建全套 `ducklake_*` 表并写初始行(建表语句归
  [METADATA_MANAGER_DESIGN.md](METADATA_MANAGER_DESIGN.md);`has_explicit_schema` 决定是否先
  `CREATE SCHEMA IF NOT EXISTS`,见 `src/storage/ducklake_metadata_manager.cpp:185-190`)。
- 加密 AUTOMATIC → 默认落 UNENCRYPTED(`:166-169`)。`SetEncryption` 本身
  (`src/storage/ducklake_catalog.cpp:864-883`)只允许从 AUTOMATIC 单向收敛,两个确定态互改
  都抛错。

### 3.8 SetVersionedMetadataManager

`src/storage/ducklake_initializer.cpp:289-308`:V1_0 是基类原生语义,no-op;V1_1_DEV_1 则按
当前 manager 的动态类型(`dynamic_cast` Postgres/SQLite,否则基类)实例化模板
`DuckLakeMetadataManagerV1_1<Base>` 并 `transaction.SetMetadataManager(...)` 换入。也就是说
**版本差异以 mixin 模板叠在后端 manager 之上**,而后端选择本身发生在
`DuckLakeTransaction` 构造时:`DuckLakeMetadataManager::Create`
(`src/storage/ducklake_metadata_manager.cpp:59-72`)按 `DuckLakeCatalog::MetadataType()` 查
静态注册表 `metadata_managers`(`:44-47`,内置 `postgres[_scanner]`/`quack[_scanner]`/
`sqlite[_scanner]` 三组别名,支持 `Register` 动态扩展),没命中则用基类(DuckDB 后端)。
`metadata_type` 的判定在 `DuckLakeCatalog` 构造函数(`src/storage/ducklake_catalog.cpp:188-201`):
优先 `metadata_parameters["type"]`,否则 `DBPathAndType::ExtractExtensionPrefix` 从
`metadata_path` 连接串前缀(如 `postgres:...`、`sqlite:...`)提取。

### 3.9 ProbeServerCapabilities(★)

`Initialize()` 尾部对(可能已被替换的)manager 调 `ProbeServerCapabilities()` +
`ClearCache()`(`src/storage/ducklake_initializer.cpp:115-118`),**每次 attach 只做一次**。

基类 `ProbeServerCapabilities` 是空实现(`src/include/storage/ducklake_metadata_manager.hpp:133-134`),
Postgres/SQLite 均不覆写;当前唯一实现在 quack 后端
(`src/metadata_manager/quack_metadata_manager.cpp:72-84`),判定条件为:

```cpp
string probe = "SELECT 1 FROM duckdb_functions() WHERE function_name = 'ducklake_commit' LIMIT 1";
auto result = Query(probe);
if (!result || result->HasError()) { return; }          // 探测失败静默忽略
auto chunk = result->Fetch();
if (chunk && chunk->size() > 0) {
    transaction.GetCatalog().SetRetrialsServerSide(true);
}
```

即:向 metadata server(远端 DuckDB)查 `duckdb_functions()` 里是否存在 `ducklake_commit`
函数——存在说明 server 侧也装了 ducklake 扩展,可以把 commit 重试循环搬到 server 执行,于是置
`DuckLakeCatalog::retrials_server_side = true`(`src/include/storage/ducklake_catalog.hpp:226-232`)。
该 flag 后续经 `ExecuteRetrialsServerSide()` 影响
`CanSkipSnapshotFetch`/`FlushChangesServerSide`(`src/metadata_manager/quack_metadata_manager.cpp:94-137`),
协议细节见 [COMMIT_PROTOCOL_DESIGN.md](COMMIT_PROTOCOL_DESIGN.md)。`ClearCache()` 基类同样为空
(hpp `:145-146`),quack 实现为 `CALL quack_clear_cache()`。

### 3.10 AT 子句快照校验

`src/storage/ducklake_initializer.cpp:119-122`:若 `options.at_clause` 非空,attach 末尾主动
`transaction.GetSnapshot()` 一次——`DuckLakeTransaction::GetSnapshot()`
(`src/storage/ducklake_transaction.cpp:1536-1548`)看到 `CatalogSnapshot()` 非空会走
`GetSnapshot(at_clause)`(`:1550-1571`):以 `{"version": v}` / `{"timestamp": t}` 的 STRUCT
Value 为 key 查询 `snapshot_cache`,miss 则让 metadata manager 解析快照。快照不存在在此刻就
报错,而不是等第一条查询。`DuckLakeSnapshot` 本体
(`src/include/common/ducklake_snapshot.hpp:18-36`):

```cpp
struct DuckLakeSnapshot {
	idx_t snapshot_id;       // 快照 id
	idx_t schema_version;    // catalog/schema 版本(schema 缓存的 key)
	idx_t next_catalog_id;   // 下一个可用 catalog 对象 id(schema/table/view/macro 共用序列)
	idx_t next_file_id;      // 下一个可用 data file id(也用作 stats 缓存 key 的一部分)
};
```

## 四、DuckLakeCatalog 核心

### 4.1 关键成员

`src/include/storage/ducklake_catalog.hpp:286-319`(私有段,逐字段):

```cpp
mutex name_maps_lock;
DuckLakeNameMapSet name_maps;            // mapping_id → name map(add_files 列名映射,惰性增量加载)
optional_idx loaded_name_map_index;      // 已加载 name map 的水位(用 next_file_id 做单调判断)
mutable mutex config_lock;               // 三级配置的锁
DuckLakeOptions options;                 // attach 选项 + 三级配置的常驻存放处
string separator = "/";                  // data path 分隔符(InitializeDataPath 写入)
atomic<idx_t> last_uncommitted_catalog_version;  // 未提交 catalog 变更的版本号发生器,
                                         // 初值 TRANSACTION_ID_START(ducklake_catalog.cpp:189)
string metadata_type;                    // 元数据后端类型("", "duckdb", "postgres", "sqlite", "quack"...)
string instance_id;                      // 每次 attach 随机 UUID,用于隔离 ObjectCache key
bool initialized = false;                // FinalizeLoad 完成标志(LookupSchema/ScanSchemas 的门闩)
bool retrials_server_side = false;       // 3.9 探测结果
mutex inlined_deletion_cache_lock;       // ↓ inlined deletion 表存在性缓存
unordered_set<idx_t> inlined_deletion_exists;        // 已知存在(永不失效)
unordered_map<idx_t, idx_t> inlined_deletion_not_exists; // 已知不存在 + 检查时的 snapshot_id 水位
mutable mutex commit_lock;
optional_idx last_committed_snapshot;    // 本进程最近一次成功 commit 的 snapshot id(FlushChanges 时设置)
QueryCallback query_callback;            // 元数据查询的可注入观测回调(测试/instrument 用)
```

`last_committed_snapshot` 经 `SetCommittedSnapshotId`/`GetLastCommittedSnapshotId`
(hpp `:221-240`)暴露给 `ducklake_last_committed_snapshot()` 表函数;
`GetNewUncommittedCatalogVersion()`(hpp `:217-219`)给 transaction-local DDL 发放递增
catalog version,供 DuckDB 的 plan cache 失效判断(`GetCatalogVersion`,
`src/storage/ducklake_catalog.cpp:925-927`,委托给事务)。

### 4.2 schema 缓存:schema_version → 不可变 DuckLakeCatalogSet

读路径统一收敛到 `GetSchemaForSnapshot`(`src/storage/ducklake_catalog.cpp:362-366`):

```cpp
DuckLakeCatalogSet &DuckLakeCatalog::GetSchemaForSnapshot(DuckLakeTransaction &transaction, DuckLakeSnapshot snapshot) {
	auto entry = GetSchemaCacheEntry(transaction, snapshot);
	PinSchemaForQuery(transaction, entry);
	return entry->catalog_set;
}
```

`GetSchemaCacheEntry`(`:348-360`)以 `SchemaCacheKey(snapshot.schema_version)` 查 DuckDB
instance 级 `ObjectCache`(`GetObjectCacheInstance` = `GetDatabase().GetObjectCache()`,
`:1095-1097`);miss 则 `LoadSchemaForSnapshot` 全量物化(见 4.5)并 `cache.Put`。缓存条目
`DuckLakeSchemaCacheEntry`(`src/include/storage/ducklake_catalog.hpp:53-67`)把
`unique_ptr<DuckLakeCatalogSet>` 解引用 move 成 by-value 成员,并实现
`GetEstimatedCacheMemory()`(`src/storage/ducklake_catalog.cpp:162-164` →
`EstimateCatalogSetMemory` `:133-152` 递归估算 entry 内存)供 ObjectCache 记账/逐出。

key 一致性依赖一个前提:**同一 `schema_version` 的 catalog 内容不可变**——任何 DDL commit 都会
产生新的 `schema_version`(见 [COMMIT_PROTOCOL_DESIGN.md](COMMIT_PROTOCOL_DESIGN.md)),因此
cache 不需要细粒度失效,只在少数破坏该前提的场景显式 `Delete`(见 4.4)。

### 4.3 cache key 构造(★)

`src/storage/ducklake_catalog.cpp:1074-1093`:

```cpp
StatsCacheKey:    "ducklake:%s:%s:%s:stats:%llu:table:%llu"  // GetName(), MetadataPath(), instance_id, next_file_id, table_id
SchemaCacheKey:   "ducklake:%s:%s:%s:schema:%llu"            // GetName(), MetadataPath(), instance_id, schema_version
SchemaPinStateKey:"ducklake_schema_pin:%s:%s:%s"             // GetName(), MetadataPath(), instance_id
```

三段限定:catalog 名 + 元数据路径 + **per-attach 随机 `instance_id`**
(ctor `src/storage/ducklake_catalog.cpp:190` `UUID::ToString(UUID::GenerateRandomUUID())`)。
instance_id 的存在意味着 DETACH 后重新 ATTACH 同一个 lake **不会**命中旧条目(防外部写者
造成的陈旧 schema),代价是旧条目要等 ObjectCache 逐出。stats 缓存以
`<next_file_id, table_id>` 为键(文件集合变化 ⇒ next_file_id 变化 ⇒ 自然换 key),
`GetTableStats`(`:793-823`)用 shared_ptr aliasing 把 `DuckLakeTableStats` 借给调用方。

### 4.4 失效时机

`InvalidateSchemaCache(schema_version)` / `InvalidateTableStatsCache(next_file_id, table_id)`
(`src/storage/ducklake_catalog.cpp:1083-1089`)就是 `ObjectCache::Delete`。调用点:

- **commit 路径**:`DuckLakeTransaction::RunCommitLoop` 的 commit context 回调
  (`src/storage/ducklake_transaction.cpp:1457-1459`)——本事务带 DDL/inlined-data 变更落盘后,
  把可能被自己"预热"过的 schema_version 条目删掉;
- **flush inlined data 后清理被取代的 inlined 表**:
  `DuckLakeTransaction::DropEmptySupersededInlinedTablesClientSide`
  (`src/storage/ducklake_transaction.cpp:1339-1341`)及
  `DuckLakeMetadataManager::DropEmptySupersededInlinedTables`
  (`src/storage/ducklake_metadata_manager.cpp:5230-5239`,DROP 后把
  `ducklake_snapshot` 里**所有** distinct schema_version 逐一失效——因为 inlined 表名缓存在
  table entry 里,属于"同 schema_version 内容被改"的例外);
- **expire_snapshots**:`src/functions/ducklake_expire_snapshots.cpp:114-117` 把被删快照的
  schema_version 失效;同文件路径上 `ExpireSnapshots` 也会按 `<next_file_id, table_id>` 清
  stats(`src/storage/ducklake_metadata_manager.cpp:5182-5187`)。

### 4.5 LoadSchemaForSnapshot:全量物化

`src/storage/ducklake_catalog.cpp:498-682`。一次性调
`metadata_manager.GetCatalogForSnapshot(snapshot)`(SQL 细节归
[METADATA_MANAGER_DESIGN.md](METADATA_MANAGER_DESIGN.md))拿回 schemas/tables/views/macros/
partitions/sorts 的扁平描述,然后:

1. 每个 schema → `DuckLakeSchemaEntry`,塞进 `ducklake_entries_map_t`(name → entry)并构造
   `DuckLakeCatalogSet`(`:503-511`);
2. 每个 table:`TransformColumnType`(`:381-442`)把元数据列描述递归转成
   `DuckLakeFieldId` 树(struct/list/map 子列、initial_default、default literal/expression),
   收集 NOT NULL 列建 `NotNullConstraint`,构造 `DuckLakeTableEntry` 后
   `schema_set->AddEntry(schema_entry, table.id, ...)`(`:514-564`);
3. view → `DuckLakeViewEntry`(`:567-588`);macro → `CreateMacroInfoFromDucklake`(`:444-496`,
   scalar 走表达式 parse、table macro 走 SELECT parse,含命名参数默认值)→
   `DuckLakeScalarMacroEntry`/`DuckLakeTableMacroEntry`(`:591-611`);
4. partition 描述 → `DuckLakePartition`(transform 解析:year/month/day/hour/identity/
   `bucket(N)`,`:614-657`)、sort 描述 → `DuckLakeSort`(`:660-679`),分别
   `SetPartitionData`/`SetSortData` 挂到对应 table entry。

物化结果是纯内存对象图,后续查询不再回元数据库(直到换 schema_version 或被失效)。

### 4.6 query 级 pin:DuckLakeSchemaPinState

问题:binder/planner 拿到的是 `DuckLakeCatalogSet` 内 entry 的裸引用,而 ObjectCache 条目可能
被 4.4 的失效或内存逐出释放。解法(`src/include/storage/ducklake_catalog.hpp:69-79` +
`src/storage/ducklake_catalog.cpp:166-176,368-379`):

```cpp
class DuckLakeSchemaPinState : public ClientContextState {
	void QueryEnd(ClientContext &context) override;   // pins.clear()
	void Pin(shared_ptr<DuckLakeSchemaCacheEntry> entry);
	mutex lock;
	unordered_map<DuckLakeSchemaCacheEntry *, shared_ptr<DuckLakeSchemaCacheEntry>> pins;
};
```

`PinSchemaForQuery` 通过 `transaction.context.lock()` 拿 ClientContext,在其
`registered_state` 上 `GetOrCreate<DuckLakeSchemaPinState>(SchemaPinStateKey())`,把
shared_ptr 按裸指针去重存进 `pins`。`QueryEnd` 是 `ClientContextState` 的标准回调,query 结束
统一放手。于是 entry 生命周期 = max(ObjectCache 持有期, 当前 query)。一个 query 内跨多个
snapshot(AT 子句)会 pin 多份。注意 pin 的粒度是 query 而非 transaction——名字里
"guarantee memory safety before transaction finishes" 指配合事务自身对 snapshot 的缓存,实际
容器在 QueryEnd 清空。

### 4.7 Catalog API 面

- `LookupSchema`(`src/storage/ducklake_catalog.cpp:825-862`):未初始化时按 `if_not_found`
  抛错/返回 null;无 AT 子句先查事务本地新建 schema(`GetTransactionLocalSchemas`,归
  [TRANSACTION_DESIGN.md](TRANSACTION_DESIGN.md)),再
  `GetSnapshot(at_clause)` → `GetSchemaForSnapshot` 查不可变集,最后过滤
  `duck_transaction.IsDeleted(...)`(事务本地 DROP)。
- `ScanSchemas`(`:295-315`)同构:本地集 + 快照集 − 本地已删。
- `CreateSchema`(`:257-282`):冲突处理后用事务本地 id
  (`GetLocalCatalogId()`,从 `TRANSACTION_LOCAL_ID_START = 2^63` 起,
  `src/include/common/index.hpp:18`)+ 新 UUID 构造 entry,
  `data_path = DataPath() + GeneratePathFromName(uuid, name)`——名字纯
  `[A-Za-z0-9_-]` 用名字当子目录,否则用 UUID(`:236-255`);entry 交给
  `duck_transaction.CreateEntry(...)`(commit 时才落元数据)。
- `GetEntryById(SchemaIndex/TableIndex)`(`:317-335`):先事务本地,再快照集的 id map。
- DML/DDL planning hook(`PlanInsert/PlanDelete/PlanUpdate/PlanMergeInto` 等,hpp
  `:147-162`)归 [DML_DESIGN.md](DML_DESIGN.md);索引一律
  `NotImplementedException`(`:885-889,1044-1049`)。

## 五、Catalog Entry 体系

### 5.1 DuckLakeCatalogSet

`src/include/storage/ducklake_catalog_set.hpp:26-62`,无锁(注释:对给定 snapshot 恒定):

```cpp
ducklake_entries_map_t catalog_entries;                       // case-insensitive name → unique_ptr<CatalogEntry>
map<SchemaIndex, reference<DuckLakeSchemaEntry>> schema_entry_map;  // schema id → entry
map<TableIndex, reference<CatalogEntry>> table_entry_map;     // table/view id → entry(跨 schema 全局)
map<MacroIndex, reference<CatalogEntry>> macro_entry_map;     // macro id → entry
```

同一个类型有两种用法:作 schema 容器(顶层,`catalog_entries` 存 schema)和作
schema 内对象容器(`DuckLakeSchemaEntry` 的成员)。顶层 set 的
`AddEntry(schema, TableIndex/MacroIndex id, entry)`
(`src/storage/ducklake_catalog_set.cpp:60-70`)在登记 id map 的同时把所有权转交给
schema entry。`CreateEntry`(`:18-25`)支持同名替换并用 `SetChild` 串住旧 entry
(事务本地 RENAME/REPLACE 链用)。

### 5.2 DuckLakeSchemaEntry

`src/include/storage/ducklake_schema_entry.hpp:18-83`。私有字段:

```cpp
SchemaIndex schema_id;        // catalog 全局 id(事务本地的 ≥ 2^63)
string schema_uuid;
string data_path;             // 本 schema 数据目录(DataPath() + name|uuid + sep)
DuckLakeCatalogSet tables;          // 表 + 视图共用一个 set
DuckLakeCatalogSet scalar_macros;
DuckLakeCatalogSet table_macros;
mutex default_function_lock;
case_insensitive_map_t<unique_ptr<CatalogEntry>> default_function_map;  // 内置 table macro 惰性实例化
```

要点:

- `CatalogTypeIsSupported`(`src/storage/ducklake_schema_entry.cpp:102-114`)只放行
  TABLE/VIEW/SCALAR_FUNCTION/TABLE_FUNCTION/TABLE_MACRO/MACRO;sequence/type/index 等
  Create* 全部抛 `NotImplementedException`。
- `LookupEntry`(`:343-371`):TABLE_FUNCTION 先试 `TryLoadBuiltInFunction`(见 8.4);随后
  事务本地 entry 优先,再查不可变 set,最后过滤 `IsDeleted/IsRenamed`。
- `CreateTable`(`:92-100`):生成 table UUID,
  `table_data_path = schema.DataPath() + GeneratePathFromName(uuid, table_name)`,即数据目录
  层级 `data_path/<schema>/<table>/`。
- `TryDropSchema`(`:416` 起)在 DROP SCHEMA 时校验/级联内部对象。

### 5.3 DuckLakeTableEntry

`src/include/storage/ducklake_table_entry.hpp:35-190`,私有字段(`:178-190`):

```cpp
TableIndex table_id;                 // catalog 全局表 id(事务本地新表 ≥ 2^63)
string table_uuid;                   // 稳定 UUID(RENAME 不变;数据文件归属/路径生成用)
string data_path;                    // 本表数据目录
shared_ptr<DuckLakeFieldData> field_data;   // field id 树(第六节);ALTER 链上的多版本 entry 共享
optional_idx next_column_id;         // 下一个可用 field id(惰性:RequireNextColumnId 时才向元数据要)
vector<DuckLakeInlinedTableInfo> inlined_data_tables;  // 该表的 inlined-data 物理表清单(08 篇)
LocalChange local_change;            // 事务本地变更类型(NONE = 已提交 entry;02 篇)
unique_ptr<DuckLakePartition> partition_data;  // partition key(transform + field id 列表)
unique_ptr<DuckLakeSort> sort_data;            // sort key(表达式 + dialect + 方向)
unique_ptr<ColumnChangeInfo> changed_fields;   // 仅 REMOVE/CHANGE TYPE 等列变更的 ALTER 副本上有
```

公有面分三类:取数(`GetTableId/GetTableUUID/GetFieldData/GetPartitionData/GetSortData/
GetInlinedDataTables`、`GetFieldId` 的多个重载——按物理列序、按列名路径、按 FieldIndex);
DuckDB hook(`GetScanFunction`/`GetStatistics`/`GetStorageInfo`/`GetVirtualColumns`/
`GetRowIdColumns`,归 [SCAN_DESIGN.md](SCAN_DESIGN.md));以及一整组 `AlterTable` 私有重载 +
"从 ALTER 构造新 entry"的拷贝构造族(`:159-176`)——DuckLake 的 ALTER 不就地改 entry,而是
按 copy-on-write 派生带 `LocalChange` 标记的新 entry,提交时翻译成元数据 SQL(07 篇)。

### 5.4 DuckLakeViewEntry

`src/include/storage/ducklake_view_entry.hpp:21-65`。字段:`mutable mutex lock`、
`TableIndex view_id`(与表共享 id 空间和 `table_entry_map`)、`string view_uuid`、
`string query_sql`、`LocalChange local_change`。视图 SQL 以**未解析文本**存储,其中 catalog
名抽象为 `{DUCKLAKE_CATALOG}.` 占位:`ParseSelectStatement`
(`src/storage/ducklake_view_entry.cpp:87-97`)在首次 `GetQuery()`(`:99-106`,持锁惰性 parse)
时用 `DuckLakeUtil::ReplaceSkippingQuotes` 替换为当前 attach 名再 parse——同一个 lake 被以
不同名字 attach 时视图仍可解析。`ToSQL()`(`:63-77`)同样做替换。`BindView`(`:112-119`)
失败时回退 `UpdateBinding({}, {})` 而不是让 entry 留在半绑定状态。

### 5.5 macro entry

`src/include/storage/ducklake_macro_entry.hpp:23-49`:`DuckLakeScalarMacroEntry` /
`DuckLakeTableMacroEntry` 仅在 DuckDB 对应 entry 上附加一个 `MacroIndex index`(persist 的
macro id)。多实现(overload)宏由 `CreateMacroInfoFromDucklake`
(`src/storage/ducklake_catalog.cpp:444-496`)从元数据重建。

## 六、DuckLakeFieldData 与 field id

### 6.1 数据结构

schema evolution 的根基:列的身份不是名字也不是位置,而是持久化的 **field id**。
`src/include/storage/ducklake_field_data.hpp`:

```cpp
struct DuckLakeColumnData {            // hpp:24-38
	FieldIndex id;                     // 持久 field id
	Value initial_default;             // "旧文件没有该列时读出的值"(initial-default,写定即不变)
	unique_ptr<ParsedExpression> default_value;  // INSERT 缺省表达式(可被 SET DEFAULT 改)
};

class DuckLakeFieldId {                // hpp:40-93
	DuckLakeColumnData column_data;
	string name;
	LogicalType type;
	vector<unique_ptr<DuckLakeFieldId>> children;   // struct 成员 / list element / map key+value
	case_insensitive_map_t<idx_t> child_map;        // 子名 → children 下标(重名构造时报错)
	optional_ptr<DuckLakeFieldId> parent;
};

class DuckLakeFieldData {              // hpp:95-131
	vector<unique_ptr<DuckLakeFieldId>> field_ids;                       // 顶层列,按物理列序
	map<FieldIndex, const_reference<DuckLakeFieldId>> field_references;  // 任意深度 field id → 节点
};
```

`Add`(`src/storage/ducklake_field_data.cpp:9-22`)迭代展开整棵子树,把每个节点登进
`field_references`,因此 `GetByFieldIndex` 对嵌套字段 O(log n) 直达。
`GetByNames`(`:373-397`)按列名路径下钻,遇到 VARIANT 类型提前停在 variant 列并回填
`name_offset`(variant 内部路径不消费 field id)。

### 6.2 field id 分配与嵌套编号

- **建表**:`DuckLakeFieldData::FromColumns(columns)`(`:135-148`)从 `column_id = 1` 起,对
  每个顶层列调 `DuckLakeFieldId::FieldIdFromColumn` → `FieldIdFromType`(`:73-120`)。编号是
  **前序(parent 先于 children)、深度优先、跨列连续**:
  `a INT, b STRUCT(x INT, y INT), c INT` → a=1, b=2, b.x=3, b.y=4, c=5。
  STRUCT 按成员序递归;LIST/ARRAY 生成单子节点 `element`;MAP 生成 `key`、`value` 两个
  子节点——这些隐式子字段同样占用 field id。嵌套类型不允许带 default(`:80-110` 各分支抛
  `NotImplementedException`)。分配完后 `next_column_id` = 用过的最大 id + 1,持久化到元数据
  (`ducklake_table` 的 next column id,见 [METADATA_SCHEMA_DESIGN.md](METADATA_SCHEMA_DESIGN.md))。
- **加载**:`TransformColumnType`(`src/storage/ducklake_catalog.cpp:381-442`)不重新分配,
  直接采用元数据里存的 id(`col_data.id = col.id`)重建同构树。
- **ADD COLUMN / 嵌套 evolution**:`DuckLakeFieldData::AddColumn`(`:305-314`)以
  `next_column_id` 续编;`AddField/RemoveField/RenameField`
  (`src/storage/ducklake_field_data.cpp:192-288`)沿列名路径 copy-on-write 重建受影响的
  spine,未触及的兄弟子树原样 `Copy()`,叶子操作分别追加/跳过/换名。RemoveField 对
  MAP/LIST 的直接子字段明确报错(不是 struct 不能 drop field,`:232-235`)。

### 6.3 不变式

`DuckLakeFieldData` 禁拷贝、可移动(hpp `:98-103`);table entry 间通过
`shared_ptr<DuckLakeFieldData>` 共享,任何列变更都会派生全新 `DuckLakeFieldData`
(`RenameColumn/DropColumn/AddColumn/SetDefault`,cpp `:290-347` 全是重建式),从而旧
snapshot 的 catalog set 与新 entry 互不干扰——与 4.2 的"不可变 catalog set"是同一设计取向。

## 七、配置作用域解析(TABLE > SCHEMA > GLOBAL)

### 7.1 读取链

存放处即 `DuckLakeOptions` 的三个 map(2.2);装载点是 3.6 的 LoadExistingDuckLake 与运行期的
`SetConfigOption`(`src/storage/ducklake_catalog.cpp:929-945`,按 option 携带的
table_id/schema_id/全局三选一写入,持 `config_lock`;它的上游 `ducklake_set_option` 表函数归
[TABLE_FUNCTIONS_DESIGN.md](TABLE_FUNCTIONS_DESIGN.md),持久化表归
[METADATA_SCHEMA_DESIGN.md](METADATA_SCHEMA_DESIGN.md))。

读取链(`src/storage/ducklake_catalog.cpp:947-996`):

```cpp
TryGetConfigOption(option, result, schema_id, table_id)
  ├─ TryGetScopedConfigOption(...)        // :947-974
  │    ├─ table_id 有效 → options.table_options[table_id][option]   // TABLE 最优先
  │    └─ schema_id 有效 → options.schema_options[schema_id][option] // 其次 SCHEMA
  └─ options.config_options[option]       // 最后 GLOBAL(:976-989)
```

模板包装 `GetConfigOption<T>(option, schema_id, table_id, default_value)`
(hpp `:128-135`)做 `Value(value_str).GetValue<T>()` 转换;
`TryGetConfigOption(option, result, DuckLakeTableEntry&)`(`:991-996`)从 entry 反查
schema_id/table_id 后走同一条链。消费方示例(均在 hpp/cpp 内):
`IsCommitInfoRequired`(`require_commit_message`)、`UseHiveFilePattern`、
`WriteDeletionVectors`、`DataInliningRowLimit`、`GetTargetFileSize`。

### 7.2 与 DuckDB setting 的合并次序(两种且方向相反)

- `DataInliningRowLimit(context, ...)`(`:1002-1014`):**catalog 三级配置优先**,都没有才读
  setting `ducklake_default_data_inlining_row_limit`,再兜底 10。
- `GetTargetFileSize(context, ...)`(`:1016-1023`):**setting `ducklake_target_file_size`
  非空时直接覆盖**,catalog 配置(`target_file_size`,默认 `DEFAULT_TARGET_FILE_SIZE = 1<<29`,
  hpp `:86`)反而是回退。

读代码时别假设统一方向,二者语义不同:前者 setting 是"默认值",后者 setting 是
"session 级强制 override"。

## 八、secret 与杂项

### 8.1 ducklake secret

`src/storage/ducklake_secret.cpp`。`GetSecretType()`(`:32-38`):type 名 `ducklake`、
provider `config`、以 `KeyValueSecret` 反序列化。`GetFunction()`(`:40-50`)声明
`CREATE SECRET` 的命名参数:`data_path`/`metadata_schema`/`metadata_catalog`/`metadata_path`
(必填,`:9-11` 校验)/`metadata_parameters`(MAP)/`encrypted`/`ducklake_version`——是
`HandleDuckLakeOption` 支持集的子集(例如 `snapshot_version` 不能进 secret)。
`GetSecret`(`:52-65`)依次查 `memory`、`local_file` 两个 secret storage。secret 的全部 kv
在 attach 时统一回灌 `HandleDuckLakeOption`(2.1)。

### 8.2 data path 的扩展自动加载

`src/storage/ducklake_autoload_helper.cpp:19-47`:`CheckAndAutoloadedRequiredExtension` 按
DuckDB 内置 `EXTENSION_FILE_PREFIXES` 表匹配 data_path 前缀(`s3://`→httpfs 之类),已加载
则过;不能 autoload 或 `autoload_known_extensions` 关闭则抛 `MissingExtensionException`
(带安装提示),否则 `ExtensionHelper::AutoLoadExtension` 并复核。文件头注释自承是
duckdb 1.3.0 `FileSystem::GlobFiles` 逻辑的拷贝(FIXME 等上游 API)。

### 8.3 元数据查询日志

`DuckLakeMetadataLogType`(`src/include/storage/ducklake_log_type.hpp:15-24` /
`src/storage/ducklake_log_type.cpp`):名为 `DuckLakeMetadata`、级别 LOG_DEBUG 的结构化
log type,payload `{catalog, query, elapsed_ms}`。发射点在
`DuckLakeTransaction::ExecuteRaw`(`src/storage/ducklake_transaction.cpp:1505-1518`):每条
元数据 SQL 计时后 `DUCKDB_LOG(...)`,并回调 `DuckLakeCatalog::query_callback`(4.1)。开
`SET logging_level='debug'` 即可观测全部元数据流量,是排查 attach/commit 行为最直接的探针。

### 8.4 内置 table macro(default functions)

`src/storage/ducklake_default_functions.cpp:10-24` 的静态表 `ducklake_table_macros` 把
`snapshots()`/`table_info()`/`set_option(...)`/`set_commit_message(...)`/`options()`/
`settings()`/`current_snapshot()`/`last_committed_snapshot()`/`merge_adjacent_files()`/
`table_changes(...)`/`table_deletions(...)`/`table_insertions(...)` 定义为指向全局
`ducklake_*` 表函数的 macro 模板,`{CATALOG}`/`{SCHEMA}` 在
`LoadBuiltInFunction`(`:27-38`)实例化时替换成当前 catalog/schema 名。
`TryLoadBuiltInFunction`(`:40-52`)由 `LookupEntry` 的 TABLE_FUNCTION 分支触发(5.2),按名
惰性构造并缓存在 `default_function_map`——因此 `FROM my_lake.snapshots()` 不需要任何
持久化对象。注意匹配只看函数名,任意 schema 下都能解析。函数本体语义归
[TABLE_FUNCTIONS_DESIGN.md](TABLE_FUNCTIONS_DESIGN.md)。

## 九、DETACH 与缓存生命周期

`DuckLakeCatalog::OnDetach`(`src/storage/ducklake_catalog.cpp:919-923`):

```cpp
void DuckLakeCatalog::OnDetach(ClientContext &context) {
	auto &db_manager = DatabaseManager::Get(context);
	db_manager.DetachDatabase(context, MetadataDatabaseName(), OnEntryNotFound::RETURN_NULL);
}
```

唯一职责是把隐藏的元数据库一并 DETACH(`RETURN_NULL`:元数据库已被手工 detach 也不报错)。
ObjectCache 中的 schema/stats 条目**不会**在此清理——但由于 cache key 含 per-attach 的
`instance_id`(4.3),这些条目自此不可达,成为纯粹的待逐出冷数据;重新 ATTACH 走全新
instance_id,从元数据库重建一切。这是"宁可重读元数据,不冒陈旧缓存风险"的有意取舍:DuckLake
的元数据真相永远在 metadata db,本地一切(catalog set、stats、name maps、inlined-deletion
存在性)都只是带水位/带版本 key 的缓存。

附:析构函数 `~DuckLakeCatalog()` 为空(`:203-204`);`InMemory()` 恒 false、
`GetDBPath()` 返回 `metadata_path`(`:903-909`);`SupportsTimeTravel()` 恒 true
(hpp `:179-181`),配合 binder 的 AT 子句进入 4.2 的多版本 schema 缓存通道。
