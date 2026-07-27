# 阶段1报告:Redis 7.2 → Valkey 9.x 兼容性验证

测试环境:redis:7.2.6, valkey/valkey:9.0 (9.0.5), 本地 Docker(OrbStack), 单机 host network 模式。

## 1. RDB 加载兼容性 —— ✅ 通过

- 构造覆盖 9 种典型编码(string int/embstr/raw、hash listpack/hashtable、list listpack/quicklist、set intset/listpack/hashtable、zset listpack/skiplist)+ stream + bitmap + HLL 的多样化数据集(共 18 个顶层 key)。
- Redis 7.2.6 执行 BGSAVE 生成 RDB,直接被 Valkey 9.0.5 加载。
- Valkey 启动日志明确识别 `Loading RDB produced by Redis version 7.2.6`,`keys loaded: 18, keys expired: 0`。
- 用 `workloads/compare_dataset.py` 做全量 key 逐一比对(类型、值、TTL 存在性):**0 mismatch,RESULT: PASS**。
- 9 种 object encoding 加载后两侧完全一致(如 hash:large 均为 hashtable、zset:large 均为 skiplist)。

结论:**Redis OSS 7.2 生成的 RDB 文件可被 Valkey 9.0 无损、无编码差异地直接加载**,与官方文档声明的兼容性边界(仅支持 ≤7.2,不支持 CE 7.4+)一致。

## 2. 复制迁移(REPLICAOF)—— ✅ 通过,可支撑近零停机迁移

场景:Valkey 9.0 作为运行中 Redis 7.2 主库的复制副本,期间持续写入模拟真实业务流量。

- `REPLICAOF <redis-host> <port>` 后,Valkey 日志显示完整流程:`Full resync from primary` → 流式接收 RDB → `Loading RDB produced by Redis version 7.2.6` → `PRIMARY <-> REPLICA sync: Finished with success`。
- 全量同步完成后 `master_link_status:up`,持续接收增量写入(约 25 秒、约 900 次写入的模拟负载)。
- 写入结束后源库与副本的计数器（INCR 累加值）、dbsize 完全一致(906 / 925)。
- 全量数据比对(`compare_dataset.py`):**0 mismatch,RESULT: PASS**。
- `REPLICAOF NO ONE` 执行后角色立即切换为 `role:master`,promote 后可正常写入(验证 `post_promote_test` key 写入成功)。

结论:**REPLICAOF 路径可行**,是实现单机/主从架构近零停机迁移的可靠方案。生产落地建议:promote 前对写入进行短暂静默(应用层或负载均衡层拦截写请求几秒),避免 promote 瞬间的极小窗口内新写入丢失;监控 `master_link_status` 和复制 offset 差值判断是否追平。

## 3. 集群模式滚动升级路径 —— ✅ 通过,是本次验证中最重要的发现

场景:模拟云上真实的集群滚动升级操作——3 主 Redis 7.2 集群,逐分片挂载 Valkey 9.0 副本,验证后逐分片 failover 到 Valkey,最后摘除原 Redis 节点。

步骤与结果:
1. 创建 3 主 0 从 Redis 7.2 集群(16384 slots 均分),写入测试数据。
2. 启动 3 个全新 Valkey 9.0 节点,通过 `valkey-cli --cluster add-node ... --cluster-slave --cluster-master-id <redis主节点ID>` 分别挂载为 3 个 Redis 主节点的副本。**关键发现:Valkey 节点可以直接通过 CLUSTER MEET 加入 Redis 7.2 的集群总线(cluster bus),说明两者不仅复制协议兼容,gossip/集群拓扑协议也互通。**
3. 用 READONLY 模式验证每个 Valkey 副本与其 Redis 主节点数据完全一致(3 个分片分别 19/16/15 个 key,0 mismatch)。
4. 对 3 个 Valkey 副本依次执行 `CLUSTER FAILOVER`,全部无损切换为主节点,**slots 分配完全未变**,原 Redis 节点自动降级为副本。
5. 验证切换后集群 `cluster_state:ok`,可正常写入。
6. 用 `valkey-cli --cluster del-node` 摘除全部 3 个原 Redis 节点。
7. 最终集群变为纯 Valkey 9.0 三主集群,16384 slots 完整覆盖,`dbsize` 及关键 key 数据核对无误。

结论:**存量 Redis 7.2 集群可以在不停服、不做全量数据搬迁的情况下,通过"逐分片加副本→failover→摘旧节点"的标准 Redis Cluster 运维手法完成引擎替换**,这是能够对云上用户承诺"无损滚动升级"的技术基础。风险点:failover 瞬间仍有毫秒级客户端重连/短暂只读窗口,建议客户端配置合理的重试策略;单分片 failover 之间建议有间隔以观察集群健康状态。

## 4. 行为差异验证

| 差异点 | 预期(调研阶段) | 实测结果 | 影响 |
|---|---|---|---|
| AUTH 校验顺序 | Valkey 9.0 未认证时统一返回 NOAUTH,不再区分命令是否存在 | ✅ 复现:Redis 7.2 对未认证的不存在命令返回 `unknown command`,Valkey 9.0 返回 `NOAUTH Authentication required.` | 依赖"用报错类型探测命令是否存在"的客户端逻辑(常见于旧版本探测/兼容性判断代码)在未认证连接上行为会变化。需要排查云上是否有此类探测逻辑(常见于连接池预热、版本嗅探脚本) |
| MULTI/EXEC 错误信息包含完整命令名 | 如 `OBJECT ENCODING` 而非 `OBJECT` | 未复现明显差异:测试的 OBJECT 子命令错误、SET 参数错误两个场景中,Redis 7.2 与 Valkey 9.0 报错文本完全一致(均已是 `object|encoding` 格式) | 该差异可能存在于 Valkey 8.x 内部版本迭代中,7.2→9.0 直接跳跃未观察到此问题。不构成阻塞项,但建议在阶段2/3做更大范围的错误信息回归测试 |
| Lua EVAL / ACL | 应保持兼容 | ✅ 两侧行为、输出格式完全一致 | 无影响 |
| 新增命令 HEXPIRE/HTTL/DELIFEQ 等 | 增量能力,不影响旧客户端 | ✅ 确认 Redis 7.2 无这些命令(`unknown command`),Valkey 9.0 正常支持 | 纯增量,不构成兼容性风险;可作为迁移后的业务侧增强能力介绍给用户(如用 DELIFEQ 简化分布式锁释放逻辑) |

## 5. 模块能力盘点(基于 `valkey/valkey-bundle:9.0` 镜像实测)

镜像启动即自动加载 4 个模块:`json`、`search`、`bf`(bloom)、`ldap`。

### ValkeyJSON —— ✅ 与 RedisJSON 兼容性符合预期
- `JSON.SET`/`JSON.GET`(含 JSONPath 取值 `$.tags[0]`)功能正常。
- `TYPE doc` 返回 `ReJSON-RL` —— 与 RedisJSON 使用完全相同的内部类型名,印证官方"RDB 兼容"声明,意味着现有 RedisJSON 数据可直接被 ValkeyJSON 加载,反之亦然,风险较低。

### valkey-bloom —— ✅ 基本功能正常
- `BF.ADD`/`BF.EXISTS` 行为符合预期(添加后存在返回1,未添加成员返回0)。

### valkey-search —— ⚠️ 重要发现:能力定位与 RediSearch 不同,不是通用全文检索替代品
- 尝试创建纯 TAG/TEXT 字段索引(`FT.CREATE ... SCHEMA $.name AS name TEXT`)**直接报错** `Invalid field type`,进一步用 TAG 类型也报错 `At least one attribute must be indexed as a vector`。
- 只有当 schema 中包含至少一个 `VECTOR` 类型字段时才能创建索引成功(实测 `FT.CREATE vecidx ON HASH ... SCHEMA embedding VECTOR FLAT 6 TYPE FLOAT32 DIM 4 DISTANCE_METRIC L2` 成功)。
- **结论:valkey-search 当前版本本质是"向量检索引擎",强制要求向量字段,并非 RediSearch 那种通用全文/结构化检索引擎的直接替代。** 如果云上用户使用 RediSearch 做纯文本全文检索、TAG 过滤、数值范围查询等**不涉及向量**的场景,valkey-search 目前无法承接,这是比原先调研判断("QPS 落后27%")更严重的能力缺口——不是"慢",而是"当前版本做不到"。需要在最终报告中明确标注为高优先级风险项。

### RedisTimeSeries —— ❌ 确认无替代
- 未在 bundle 镜像中发现对应模块,与调研结论一致。若云上有 TimeSeries 用户,需业务侧改造。

### ldap 模块
- 属于企业认证集成能力,非 Redis 原生能力,不涉及兼容性问题,只是新增能力。

## 阶段1风险分级(定稿)

- **可直接升级**:仅使用标准数据结构命令、无 Redis Stack 模块依赖、不依赖未认证连接报错类型做探测逻辑的用户 —— 数据迁移路径(单机 REPLICAOF 或集群滚动升级)均已验证可行且无损。这应是云上绝大多数用户的画像。
- **需业务侧改造**:
  - 依赖 RedisTimeSeries 的用户(无替代模块,需自建方案)
  - 依赖 RediSearch 做**纯文本/TAG/数值范围检索**(不涉及向量)的用户 —— valkey-search 当前强制要求向量字段,无法直接承接,需评估是否有替代检索方案或继续依赖 Redis 侧能力
  - 连接池/版本探测逻辑依赖未认证连接报错类型判断的用户(NOAUTH 行为变化)
- **可评估后决定**:使用 RediSearch 向量检索场景的用户,valkey-search 功能可用但性能落后约 27%(引用官方数据,待阶段3实测校准),需结合延迟敏感度评估。
- **暂不建议升级**:当前未发现"完全不可迁移"的场景,所有已识别风险均可通过用户侧适配、业务重构或保留 Redis 侧能力(如仅 TimeSeries/全文检索场景暂缓迁移)缓解,不构成"全量用户不可迁移"的结论。
