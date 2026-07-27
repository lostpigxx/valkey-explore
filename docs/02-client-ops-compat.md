# 阶段2报告:客户端与运维接口兼容性验证

测试环境:redis:7.2.6(端口 35000)、valkey/valkey:9.0.5(端口 35001)、valkey/valkey:9.1.1(用于日志/CLUSTER SHARDS 专项对比),本地 Docker(OrbStack),host network 模式。

## 1. 客户端库冒烟测试 —— ✅ 全部通过

覆盖云上用户最常用的 4 种客户端库,统一测试项:PING、GET/SET、HSET/HGETALL、Pipeline、INFO 解析。

| 客户端 | 语言 | 版本 | Redis 7.2 | Valkey 9.0 |
|---|---|---|---|---|
| redis-py | Python | 7.0.1 | ✅ 10/10 (RESP2+RESP3) | ✅ 10/10 (RESP2+RESP3) |
| ioredis | Node.js | ^5.11 | ✅ 5/5 | ✅ 5/5 |
| go-redis/v9 | Go | v9.7.0 | ✅ 7/7 | ✅ 7/7 |
| Jedis | Java | 5.2.0 | ✅ 5/5 | ✅ 5/5 |

结论:**主流客户端库无需任何改造即可无缝切换到 Valkey 9.0**,RESP2/RESP3 协议层、连接建立、pipeline、常规命令行为完全一致。未发现协议解析层面的兼容性问题。

脚本位置:`scripts/clients/python_smoke.py`、`scripts/clients/node/ioredis_smoke.js`、`scripts/clients/go/main.go`、`scripts/clients/java/JedisSmoke.java`(Java 依赖需先执行 `scripts/clients/java/fetch_deps.sh` 拉取 jar 包,未纳入 git)。

## 2. INFO 输出差异 —— ⚠️ 发现一个需要关注的字段重命名

对比 `INFO server` 段:

| 字段 | Redis 7.2 | Valkey 9.0 | 说明 |
|---|---|---|---|
| `redis_mode` | `standalone` | **不存在** | **重命名为 `server_mode`,无兼容别名** |
| `server_mode` | 不存在 | `standalone` | 新字段,承担原 `redis_mode` 的语义 |
| `redis_version` | `7.2.6` | `7.2.4`(伪装值,兼容旧客户端版本探测) | Valkey 保留此字段并填充一个兼容性版本号,而非移除 |
| `valkey_version` | 不存在 | `9.0.5` | 新增,真实版本号 |
| `server_name` | 不存在 | `valkey` | 新增,可用于区分引擎类型 |
| `availability_zone` | 不存在 | 空字符串(未配置时) | 新增,对应新 `availability-zone` 配置项 |

**风险点(高优先级)**:如果云平台自研监控/巡检工具通过解析 `INFO server` 里的 `redis_mode` 字段判断实例是 standalone/cluster/sentinel 模式,升级到 Valkey 后该字段**消失**(不是变了取值,而是键本身不存在),会导致此类工具解析失败或误判。**建议**:工具改造时优先判断 `server_mode`,若为空则回退读取 `redis_mode`,以同时兼容两种引擎。

另外发现 `redis_version` 字段在 Valkey 中被**保留并填充一个固定兼容版本号(7.2.4)**而非移除或替换为真实版本——这是 Valkey 官方有意设计的"版本探测兼容性"机制,目的是让只认 `redis_version` 字段的旧客户端/工具不会因为字段消失而报错,只会认为连的是一个较低版本的 Redis。**这跟 `redis_mode` 字段的处理方式不一致**(一个保留兼容、一个直接改名不留兼容别名),提示 Valkey 对不同字段的兼容性策略并不统一,不能一概而论假设"重要字段都会保留兼容名"。

## 3. CONFIG GET 输出差异

- 总配置项数量:Redis 7.2 有 390 项,Valkey 9.0 有 470 项(净增 80,含新增/改名各类)。
- **两项在 Valkey 9.0 中被移除**(`CONFIG GET` 查不到,`CONFIG SET` 报 `ERR Unknown option`):
  - `dynamic-hz`
  - `io-threads-do-reads`
  
  若云上有客户在初始化脚本/配置模板中显式设置这两项,升级后**该 SET 调用会直接报错**,需要在迁移工具中做兼容处理(检测引擎类型后跳过这两个已废弃参数)。
- **新增 42 项配置**,其中与运维强相关、值得关注的包括:
  - `availability-zone` —— 云原生多可用区部署会用到,建议纳入云平台的实例元数据管理
  - `log-format` / `log-timestamp-format` —— 见下节日志格式变化
  - `commandlog-*` 系列(6项)—— 新的慢日志/大 reply/大 request 分类记录机制,与传统 `slowlog-*` 并存(见第5节)
  - `cluster-slot-stats-enabled`、`cluster-manual-failover-timeout`、`cluster-blacklist-ttl` —— 集群运维细粒度控制,阶段5大规模集群测试中需要关注
  - `dual-channel-replication-enabled` —— 新复制机制开关,阶段3/4性能与稳定性测试需要覆盖
  - `extended-redis-compatibility` —— 名称暗示存在"扩展兼容模式"开关,需要在阶段3之前专项调研其具体作用(是否能进一步降低行为差异)
  - `rdma-*` / `mptcp` / `repl-mptcp` —— 新传输层特性,本次评估范围外(标准 TCP 场景已覆盖)
- 常规业务相关配置(如 `maxmemory-policy`)取值、行为完全一致,未发现语义变化。

## 4. 日志格式差异

- **默认文本日志格式**:Redis 7.2 与 Valkey 9.0/9.1 启动日志格式高度一致(时间戳格式、角色标记 `M`/`C`、日志级别符号 `*`/`#` 等均相同),仅品牌字样从 "Redis" 变为 "Valkey"。**不会破坏基于正则解析默认文本日志的现有工具。**
- **Valkey 9.1 新增 JSON 日志格式**(实测确认,通过 `--log-format json` 启用,默认不开启):
  ```json
  {"pid":1,"role":"primary","timestamp":"27 Jul 2026 01:46:25.363","level":"notice","message":"Valkey is starting oO0OoO0OoO0Oo"}
  ```
  字段包括 `pid`、`role`(注意:用 `primary` 而非 `master`,体现 Valkey 去 master/slave 术语的命名规范)、`timestamp`、`level`、`message`。
  
  **结论**:该特性是**opt-in(需显式配置 `log-format json` 或 `--log-format json`)**,默认场景不受影响,不构成兼容性风险。但如果云平台后续想统一采集结构化日志,可以主动利用此特性替代正则解析文本日志,是一个可选的运维体验提升项,而非升级阻塞项。

## 5. SLOWLOG 兼容性与新 COMMANDLOG 机制

- `SLOWLOG GET`/`SLOWLOG RESET`、`slowlog-log-slower-than`、`slowlog-max-len` 配置在 Valkey 9.0 中**保持完全兼容**,行为未变。
- Valkey 新增一套独立的 `commandlog-*` 配置(`commandlog-execution-slower-than`、`commandlog-large-reply-max-len`、`commandlog-large-request-max-len` 等)以及对应的 `COMMANDLOG` 命令族,是比 SLOWLOG 更细分的记录机制(区分慢执行、大 reply、大 request 三类),与 SLOWLOG **并存而非替代**。
- **影响评估**:现有依赖 SLOWLOG 的慢查询采集工具无需任何改造即可继续工作;若想利用新的大 reply/大 request 检测能力,是可选的能力增强,不在本次兼容性验证的阻塞项范围内。

## 6. CLUSTER SHARDS 输出差异 —— ⚠️ Valkey 9.1 新增顶层 shard-id 字段

测试方法:分别创建 Redis 7.2、Valkey 9.0、Valkey 9.1 三个单节点自赋值全部 16384 slots 的最小化集群,对比 `CLUSTER SHARDS` 的 RESP 结构(`--no-raw` 模式检查嵌套层级,而非仅看渲染后的文本)。

- **Redis 7.2 与 Valkey 9.0**:结构完全一致,每个 shard 元素是 4 项数组:`["slots", [start, end], "nodes", [ {node字段...} ]]`。
- **Valkey 9.1**:每个 shard 元素变为 **6 项数组**,在 `nodes` 之后新增一组 `"id"` + shard-id 字符串:`["slots", [...], "nodes", [...], "id", "<shard-id>"]`。

  排查确认这**不是数据异常或残留状态**——`shard-id` 本身是 Redis Cluster 协议早已存在的概念(在 `nodes.conf` 的节点行中以 `shard-id=<40位hex>` 形式存在,Redis 7.2 和 Valkey 9.0 的 `nodes.conf` 中也都有此字段),只是 Valkey 9.1 之前该字段没有通过 `CLUSTER SHARDS` 命令直接暴露给客户端(此前需要对每个节点单独调用 `CLUSTER MYSHARDID` 才能拿到)。9.1 版本把它提升为 `CLUSTER SHARDS` 顶层返回的一部分,减少了客户端/控制面获取 shard-id 的调用次数。

  **风险点**:如果云平台自研的集群拓扑采集工具是**按数组下标位置**解析 `CLUSTER SHARDS` 的原始 RESP 数组(而非按 map/字典方式取 key),从 Redis 7.2/Valkey 9.0 升级到 Valkey 9.1 时,数组长度从 4 变为 6,**按位置解析的代码会出现越界或取值错位**。用 map/字典方式解析(先转成 `{"slots":..., "nodes":..., "id":...}` 再取值)的工具不受影响。建议在阶段2最终建议中明确提示:升级前排查内部工具对 `CLUSTER SHARDS`/`CLUSTER SLOTS` 等数组型返回值的解析方式。

## 7. Go / Java 客户端环境说明(本地 arm64 环境注意事项)

在 Apple Silicon (arm64) 环境下拉取以下常见基础镜像失败,记录供后续复现参考:
- `golang:1.22-alpine`(默认 tag)首次拉取失败,重试后成功(网络抖动,非架构问题)
- `eclipse-temurin:17-jdk-alpine` 拉取失败:`no matching manifest for linux/arm64/v8`(该 alpine 变体缺少 arm64 构建),改用 `eclipse-temurin:17-jammy`(Ubuntu 基础,含 arm64 构建)后成功

不影响结论有效性,仅作为环境搭建注意事项记录。

## 阶段2结论汇总

| 维度 | 结论 | 风险等级 |
|---|---|---|
| 客户端库兼容性(Python/Node/Go/Java) | 完全兼容,无需改造 | 无风险 |
| `INFO` 字段:`redis_mode`→`server_mode` | 无兼容别名,依赖此字段的监控/巡检工具会解析失败 | **中高风险,需改造** |
| `INFO` 字段:`redis_version` | 保留并填充兼容版本号,行为符合预期 | 无风险 |
| `CONFIG GET/SET`:`dynamic-hz`/`io-threads-do-reads` | 已移除,显式 SET 会报错 | 低风险(仅影响显式配置这两项的初始化脚本) |
| 日志格式(默认文本) | 与 Redis 7.2 高度一致 | 无风险 |
| 日志格式(Valkey 9.1 JSON,opt-in) | 默认不开启,不影响现状;可选能力增强 | 无风险 |
| SLOWLOG 命令与配置 | 完全兼容,新 COMMANDLOG 机制并存不冲突 | 无风险 |
| `CLUSTER SHARDS` 输出结构(Valkey 9.1) | 新增顶层 shard-id,数组长度变化,按位置解析的工具需改造 | **中风险,需改造(仅影响 9.1+ 且用位置解析的工具)** |

**行动建议**:云平台在升级前应重点排查两类自研工具——(1)解析 `INFO` 字段判断实例角色/模式的监控组件,需要增加对 `server_mode` 的兼容读取;(2)解析 `CLUSTER SHARDS`/类似数组型集群拓扑接口的工具,需要确认使用的是按 key 取值而非按下标取值的方式。这两类是本阶段发现的、区别于"业务代码兼容性"之外的**运维基础设施侧兼容性风险**,应纳入迁移检查清单(checklist)首位。
