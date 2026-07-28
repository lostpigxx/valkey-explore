#!/usr/bin/env bash
# 阶段4: 内存碎片率 soak test(压缩加速版,非真实24-48h挂钟时间)
# 通过持续的 变长value写入 + 随机删除 + 过期 混合负载,加速诱导内存碎片,
# 定期采样 mem_fragmentation_ratio / used_memory / used_memory_rss。
# 用法: ./soak_test.sh <engine: redis|valkey> <port> <duration_sec> <sample_interval_sec> <outfile>
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

engine="$1"; port="$2"; duration="$3"; interval="$4"; outfile="$5"
case "$engine" in
  redis)  image="$REDIS_IMAGE"; cli="redis-cli" ;;
  valkey) image="$VALKEY_IMAGE"; cli="valkey-cli" ;;
esac

echo "elapsed_sec,used_memory,used_memory_rss,mem_fragmentation_ratio,dbsize" > "$outfile"

churn_batch() {
  # 每轮:写入一批变长 value(64B~64KB 交替,制造碎片友好的分配模式),
  # 删除一批旧 key,对一部分 key 设置短 TTL 制造被动过期
  docker exec "$engine_container" "$cli" -p "$port" --no-raw eval "
    for i=1,3000 do
      local sz = (i % 20 == 0) and 65536 or ((i % 5 == 0) and 8192 or 64)
      redis.call('SET', 'churn:'..(i % 50000), string.rep('x', sz))
    end
    for i=1,800 do
      redis.call('DEL', 'churn:'..math.random(0,50000))
    end
    for i=1,500 do
      redis.call('EXPIRE', 'churn:'..math.random(0,50000), 1)
    end
    return 'ok'
  " 0 >/dev/null 2>&1 || true
}

engine_container=$([ "$engine" = redis ] && echo ve-stab-redis || echo ve-stab-valkey)

start_ts=0
elapsed=0
while [ "$elapsed" -lt "$duration" ]; do
  churn_batch
  used_memory=$(docker exec "$engine_container" "$cli" -p "$port" info memory | grep "^used_memory:" | tr -d '\r' | cut -d: -f2)
  used_memory_rss=$(docker exec "$engine_container" "$cli" -p "$port" info memory | grep "^used_memory_rss:" | tr -d '\r' | cut -d: -f2)
  frag=$(docker exec "$engine_container" "$cli" -p "$port" info memory | grep "^mem_fragmentation_ratio:" | tr -d '\r' | cut -d: -f2)
  dbsize=$(docker exec "$engine_container" "$cli" -p "$port" dbsize | tr -d '\r')
  echo "${elapsed},${used_memory},${used_memory_rss},${frag},${dbsize}" >> "$outfile"
  log "[$engine] elapsed=${elapsed}s used_memory=${used_memory} rss=${used_memory_rss} frag=${frag} dbsize=${dbsize}"
  sleep "$interval"
  elapsed=$((elapsed + interval))
done

log "[$engine] soak test done, results in $outfile"
