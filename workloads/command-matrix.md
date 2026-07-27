# 命令与业务模式清单

用于指导阶段 1(兼容性)与阶段 3(性能)的测试设计。由于当前无法直接拿到云上生产命令使用日志,采用"标准命令全集抽样 + 常见业务模式"的方式覆盖,后续如能拿到真实采样数据应替换/校准本清单。

## 核心数据结构与命令组

| 分类 | 代表命令 | 备注 |
|---|---|---|
| String | SET/GET/INCR/APPEND/GETRANGE/SETEX | 最高频,含 TTL 变体 |
| Hash | HSET/HGET/HDEL/HGETALL/HINCRBY | 9.0 新增字段级 TTL: HSETEX/HGETEX/HTTL/HPERSIST 需专项验证 |
| List | LPUSH/RPUSH/LPOP/BRPOP/LRANGE | 队列类业务 |
| Set | SADD/SMEMBERS/SINTER/SPOP | 去重/标签场景 |
| Sorted Set | ZADD/ZRANGE/ZINCRBY/ZRANGEBYSCORE | 排行榜场景 |
| 事务/脚本 | MULTI/EXEC/WATCH, EVAL/EVALSHA, FUNCTION | 需重点验证行为一致性 |
| 过期 | EXPIRE/TTL/PERSIST/OBJECT ENCODING | 编码转换阈值需对比 |
| 发布订阅 | PUBLISH/SUBSCRIBE/PSUBSCRIBE | keyspace notification 联动 |
| 连接/权限 | AUTH/ACL SETUSER/ACL GETUSER | Valkey 9.0 AUTH 校验顺序变更,需专项验证 |
| 集群 | CLUSTER SHARDS/SLOTS/NODES/INFO | 9.1 新增 AZ 字段,需评估解析工具兼容性 |
| 持久化 | BGSAVE/BGREWRITEAOF/DEBUG RELOAD | 用于 fork/COW 测试 |
| 新增命令(9.x) | DELIFEQ, SHUTDOWN SAFE, HGETDEL, MSETEX | 需确认是否与现有客户端库版本兼容(新命令不影响旧客户端,但需要文档记录) |

## 常见业务模式(映射到测试场景)

1. **缓存**:GET/SET + TTL,高读写比(9:1),中等 value 大小(100B-10KB)
2. **分布式锁**:SET NX EX + Lua 释放脚本,验证 DELIFEQ 是否可替代旧的 CAS 释放模式
3. **计数器**:INCR/INCRBY 高并发写
4. **排行榜**:ZADD/ZRANGE/ZRANK,大 Sorted Set(10万+ member)
5. **消息队列**:LPUSH/BRPOP 或 Stream(XADD/XREAD/XACK)
6. **会话/多字段对象存储**:HSET/HGETALL,重点验证 9.0 hash field TTL 新特性
7. **发布订阅通知**:PUBLISH/SUBSCRIBE,验证集群模式下跨 slot 广播行为

## 已知需要重点验证的行为差异(来自调研,阶段1需逐条实测确认)

- AUTH 校验顺序变化:未认证客户端现在总是收到 NOAUTH,而不是 command-not-found/wrong-arity —— 影响依赖报错类型做命令探测的客户端代码
- MULTI/EXEC 内错误信息包含完整命令名(如 `OBJECT ENCODING` 而非 `OBJECT`)—— 影响做精确字符串匹配的测试/监控代码
- 25 个此前被弃用的命令恢复推荐使用状态 —— 需要列出具体清单并确认云上是否有历史遗留依赖
- HSETEX FXX 语义修正(不会对不存在字段做创建)—— 若业务用了 RC 版本行为需重新验证
- 9.0 版本 cluster-enabled 下新增多数据库支持(需要显式开启)—— 评估现有单 DB 假设是否受影响
