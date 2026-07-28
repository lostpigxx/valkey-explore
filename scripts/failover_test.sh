#!/usr/bin/env bash
# 阶段4: 故障注入 - kill 主节点,测量 failover 触发与完成时间、数据一致性
# 用法: ./failover_test.sh <engine: redis|valkey> <prefix> <base_port> <node_count>
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

engine="$1"; prefix="$2"; base_port="$3"; count="$4"
case "$engine" in
  redis)  image="$REDIS_IMAGE"; cli="redis-cli" ;;
  valkey) image="$VALKEY_IMAGE"; cli="valkey-cli" ;;
esac

cli_exec() {
  local port="$1"; shift
  docker run --rm --network host "$image" "$cli" -p "$port" "$@"
}

# 找到第一个 master 及其对应端口、以及它负责的一个 slot 范围内的 key 做写入基线
log "discovering cluster topology..."
nodes_out=$(cli_exec "$base_port" cluster nodes)
echo "$nodes_out"

master_id=""
master_port=""
replica_port=""
while IFS= read -r line; do
  flags=$(echo "$line" | awk '{print $3}')
  echo "$flags" | grep -q "master" || continue
  echo "$flags" | grep -q "fail" && continue
  cand_id=$(echo "$line" | awk '{print $1}')
  cand_addr=$(echo "$line" | awk '{print $2}' | cut -d'@' -f1)
  cand_port="${cand_addr##*:}"
  replica_line=$(echo "$nodes_out" | grep "slave" | grep "$cand_id" || true)
  if [ -n "$replica_line" ]; then
    master_id="$cand_id"
    master_port="$cand_port"
    replica_addr=$(echo "$replica_line" | awk '{print $2}' | cut -d'@' -f1)
    replica_port="${replica_addr##*:}"
    break
  fi
done <<< "$nodes_out"

if [ -z "$master_id" ]; then
  echo "no master with a live replica found, aborting"
  exit 1
fi

log "target master: id=$master_id port=$master_port; its replica: port=$replica_port"

# 找到该 master 对应的容器名(通过端口反查)
idx=$(( master_port - base_port ))
idx4=$(printf "%04d" "$idx")
master_container="ve-${prefix}-${idx4}"
log "master container: $master_container"

# 写入基线数据(用 -c 让 redis-cli/valkey-cli 自动重定向到正确 slot)
test_key="failover-test-key-$$"
cli_exec "$master_port" -c set "$test_key" "before-failover" >/dev/null
val_before=$(cli_exec "$master_port" -c get "$test_key")
log "baseline write ok: $test_key = $val_before"

# 记录 kill 前该 replica 的角色状态
log "replica role before kill: $(cli_exec "$replica_port" role | head -n1)"

kill_ts=$(now_ms)
log "killing master container $master_container at $kill_ts"
docker kill -s SIGKILL "$master_container" >/dev/null

# 轮询 replica,直到其 role 变为 master(完成 failover)
promoted_ts=""
for i in $(seq 1 60); do
  role=$(cli_exec "$replica_port" role 2>/dev/null | head -n1 || echo "unknown")
  if [ "$role" = "master" ]; then
    promoted_ts=$(now_ms)
    log "replica promoted to master at $promoted_ts (poll #$i, role=$role)"
    break
  fi
  sleep 0.2
done

if [ -z "$promoted_ts" ]; then
  echo "FAILOVER DID NOT COMPLETE within timeout"
  exit 1
fi

# 计算耗时(python 处理毫秒时间戳差)
python3 -c "
from datetime import datetime
fmt = '%Y-%m-%d %H:%M:%S.%f'
t1 = datetime.strptime('$kill_ts', fmt)
t2 = datetime.strptime('$promoted_ts', fmt)
print(f'failover duration: {(t2-t1).total_seconds():.3f}s')
"

# 验证数据一致性:新 master (原 replica) 上能否读到 kill 前写入的值
val_after=$(cli_exec "$replica_port" -c get "$test_key" 2>/dev/null || echo "ERROR")
log "value on promoted node: $val_after (expected: $val_before)"
if [ "$val_after" = "$val_before" ]; then
  log "DATA CONSISTENCY: OK (no data loss for this key)"
else
  log "DATA CONSISTENCY: MISMATCH!"
fi

# 验证集群整体状态恢复
log "cluster_state after failover:"
cli_exec "$replica_port" cluster info | grep cluster_state

log "cluster nodes after failover:"
cli_exec "$replica_port" cluster nodes
