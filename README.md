# Redis 7.2 → Valkey 9.x 升级可行性验证

## Context

作为 Redis 7.2 云托管服务提供商,需要评估引入 Valkey 9.x 后能否让现存用户"无损"升级。这不是一次性技术选型,而是关系到能否对外承诺一个安全的迁移路径的决策依据,因此验证需要动手实测、有可复现的证据链,而不是停留在文档调研。

验证方式:以实测为主、文档/社区数据为辅证;硬件资源为一台 64GB 内存的 MacBook Pro(本地 Docker/OrbStack);周期 1-2 个月,做较全面的验证。本轮**不评估 License 维度**,只聚焦技术可行性。

背景调研已确认几个关键事实,直接决定了测试设计:

- **RDB/AOF 兼容边界明确**:Valkey 只兼容 Redis OSS ≤7.2 的数据文件格式;Redis CE 7.4+ 之后两个项目格式分叉,不兼容。这正好对应我们"从 7.2 升级"的场景,是有利条件,但也意味着这是"华山一条路"——一旦上了 Valkey,不能反向回退到用 Redis 7.4+ 的工具链。
- **复制协议兼容**:Valkey 可作为 Redis 7.2 主库的复制副本(REPLICAOF),这是实现零/近零停机迁移的官方推荐路径,需要重点验证。
- **模块生态不是简单的"能不能加载"**:核心 Module API 兼容,但 RedisJSON→ValkeyJSON 是明确对齐(API+RDB 兼容);RediSearch/RedisBloom/RedisTimeSeries 是独立实现,能力和行为可能有 gap(如 TimeSeries 目前无对应 BSD 模块,search 向量检索性能落后约 27%)。这直接影响"能否 100% 支持现有用户"的结论——如果有用户在用这些模块,答案可能是"部分支持,需要用户侧改造"。
- **大规模集群**:Valkey 9.0 官方在 2000 节点/1B RPS 场景做过验证(radix tree 优化 failure report 处理、新的轻量 gossip header),这些是我们无法在本地复现的真实分布式基准。本地 Docker 只能验证拓扑/协议层行为(gossip 收敛、resharding、故障探测),不能验证 1000+ 节点下的真实吞吐延迟——这个边界必须在报告里写清楚,避免结论被误读。
- **稳定性/性能**:Valkey 9.0 的 I/O 多线程、SIMD 加速、fork COW 优化、atomic slot migration 都是可实测的具体改动点,不是空泛的"据说更快"。

## 验证维度(在原始 5 点基础上补充 4 点)

1. 超大规模集群拓扑行为(本地 Docker 复现能力范围内)
2. 对 Redis 7.2 的兼容程度(能否无损升级)
3. 性能是否有优势
4. 稳定性(fork、内存利用率、故障恢复)
5. Module 能力对等性
6. **【新增】客户端库兼容性**——用户的应用不会重新连 Valkey,他们用的是 Jedis/Lettuce/redis-py/go-redis/ioredis 等客户端,RESP2/RESP3、cluster 模式下的行为需要实测,而不是假设"协议兼容=客户端兼容"
7. **【新增】运维可观测性接口兼容性**——如果云平台有自研的监控采集(解析 INFO/CONFIG GET 输出)、慢日志采集、备份工具,Valkey 的字段变化(9.1 引入 JSON 日志、CLUSTER SHARDS 新增 AZ 字段等)可能直接breaking这些工具
8. **【新增】迁移路径与回滚风险**——验证 REPLICAOF 迁移的实际操作细节、失败场景下如何回退,这是能否承诺"无损"给用户的关键落地环节
9. **【新增】行为差异清单**——Valkey 9.0 有意为之的行为变更(如 AUTH 校验顺序、错误信息格式变化),这些不是 bug,但可能让依赖特定报错字符串/命令探测逻辑的用户代码出问题

## 测试环境搭建

```
valkey_explore/
├── docker/            # redis7.2 / valkey9.x 镜像与 compose/生成脚本
├── scripts/           # 集群生成、故障注入、benchmark 驱动脚本
├── workloads/         # 测试数据集与命令矩阵
├── results/           # 各阶段原始数据、benchmark 输出
└── docs/              # 各阶段结论报告、最终决策建议
```

工具选型:
- 性能压测: `valkey-benchmark` / `redis-benchmark` + `memtier_benchmark`(更贴近真实读写混合场景)
- 集群生成: 用脚本批量启停容器 + `valkey-cli --cluster create`,不手写 docker-compose(500+ service 不可维护)
- 故障注入: 直接 `docker kill`/`SIGSTOP` 模拟节点失效;`tc netem` 或 `pumba` 模拟网络分区/延迟
- 客户端兼容性: 针对每种客户端语言写最小连接/pipeline/cluster 冒烟测试脚本
- 本地容器运行时使用 OrbStack

大规模拓扑测试的资源预期:单个 valkey-server 空载 RSS 约 3-5MB,叠加容器命名空间开销,预计 64GB 机器上可稳定跑到 300-500 个节点(先从 100 起步验证脚本可用性,再逐步扩容,观察宿主机 CPU/内存拐点)。**明确边界**:此规模只用于验证拓扑/协议正确性(gossip 收敛时间、resharding 正确性、故障探测与 failover 触发),不用于采集吞吐/延迟数据(容器间共享宿主机资源,数据不可信);1000+ 节点的真实性能结论引用 Valkey 官方 1B RPS 博客的公开数据作为佐证,并在报告中如实注明这是引用而非本项目实测。

## 分阶段计划

### 阶段 0:环境准备(约 3-4 天)
- 拉取 Redis 7.2.x 与 Valkey 9.0.x/9.1.x 镜像,固定版本号
- 编写集群生成脚本(参数化节点数)、benchmark 驱动脚本、故障注入脚本
- 整理"用户常用命令/数据结构分布"清单(标准命令全集 + 常见业务模式:缓存、队列、计数器、排行榜、分布式锁、pub/sub),作为后续兼容性测试和 benchmark workload 设计的依据

### 阶段 1:兼容性验证——能否无损升级(约 1.5 周)
- **数据加载**:Redis 7.2 生成的 RDB/AOF 直接被 Valkey 9.x 加载,校验数据完整性(全量 key 对比、数据结构/编码对比)
- **复制迁移演练**:Valkey 9.x 作为 Redis 7.2 主库的 REPLICAOF 副本,验证全量同步、增量复制、`REPLICAOF NO ONE` promote 的完整流程,记录耗时和期间的数据一致性;同时验证集群模式下"逐分片加入 Valkey 副本→promote→摘除 Redis 节点"的滚动升级路径
- **命令与协议矩阵**:按阶段 0 整理的命令清单逐一验证行为一致性,重点覆盖事务(MULTI/EXEC)、Lua/Function、ACL、keyspace notification、过期策略
- **行为差异清单**:记录 Valkey 9.0 已知的有意行为变更(AUTH 顺序、错误信息格式、命令弃用恢复列表等),评估对现有用户代码的潜在影响面
- **模块依赖盘点**:对 RedisJSON/RediSearch/RedisBloom/RedisTimeSeries 场景实测 ValkeyJSON/valkey-search/valkey-bloom 的 API 和 RDB 兼容性,明确指出无对应替代的能力缺口(如 TimeSeries)
- 产出:`docs/01-compatibility-report.md`,含兼容性矩阵、差异清单、模块能力缺口、风险分级(可直接升级 / 需业务侧改造 / 暂不可升级)

### 阶段 2:客户端与运维接口兼容性(约 3-4 天)
- 选取主流客户端库(Jedis/Lettuce、redis-py、go-redis、ioredis)做连接、RESP2/RESP3、pipeline、cluster 重定向的冒烟测试
- 对比 `INFO`、`CONFIG GET`、日志格式(9.1 JSON 日志)、`CLUSTER SHARDS/SLOTS` 输出差异,评估对自研监控/备份/慢日志工具的影响
- 产出:`docs/02-client-ops-compat.md`

### 阶段 3:性能基准测试(约 1.5 周)
- 单机与主从模式下,Redis 7.2 vs Valkey 9.x 对比:不同 value 大小、pipeline 深度、读写混合比例下的吞吐与延迟(p50/p95/p99)
- I/O 多线程效果:对比不同 `io-threads` 配置下的吞吐提升
- 复制延迟与全量同步耗时对比
- 产出:`docs/03-performance-report.md`,给出具体倍数/百分比结论,而非定性描述

### 阶段 4:稳定性与资源画像(约 1 周)
- fork/BGSAVE 开销对比:不同数据集大小下的 fork 耗时、COW 内存增长曲线
- 24-48 小时 soak test:观察内存碎片率(`mem_fragmentation_ratio`)、内存利用率趋势、主动碎片整理效果
- 故障注入:kill 主节点观察 failover 触发与完成时间、数据一致性;网络分区场景下的脑裂防护行为
- 产出:`docs/04-stability-report.md`

### 阶段 5:大规模集群拓扑验证(约 1 周)
- 从 100 节点起步验证脚本,逐步扩容到本机可承受的上限(预期 300-500)
- 验证 gossip 收敛时间、resharding/atomic slot migration 正确性、批量故障场景下的 failure report 处理与恢复时间
- 明确记录本地测试的规模边界,并引用官方 2000 节点/1B RPS 报告作为超出本地能力范围的佐证
- 产出:`docs/05-large-cluster-report.md`

### 阶段 6:汇总与决策建议(约 3-4 天)
- 汇总 9 个维度的结论,形成一张总览表(维度 / 结论 / 风险等级 / 证据来源)
- 给出"能否 100% 支持现有用户升级"的明确结论:哪些用户画像可以直接升级(无模块依赖、标准命令使用)、哪些需要额外改造(模块依赖、依赖特定错误信息的代码)、哪些暂不建议
- 给出推荐的迁移路径(基于阶段 1 验证过的 REPLICAOF 滚动升级方案)、回滚预案、灰度策略建议
- 产出:`docs/06-final-recommendation.md`

## 验证方式

每个阶段产出必须包含:可复现的脚本/命令、原始数据(而非仅结论)、明确的"验证边界"说明(哪些结论是本地实测,哪些是引用第三方数据)。最终决策文档面向管理层/架构评审,需要能独立支撑"是否引入 Valkey"的决策,而不需要依赖对本项目过程的信任。
