#!/usr/bin/env bash
# 用 --cluster create 把已经启动的独立节点组成一个 Valkey/Redis Cluster
#
# 用法: ./cluster_join.sh <engine: redis|valkey> <prefix> <node_count> <replicas_per_master> [base_port]
#
# 例: ./cluster_join.sh valkey vk100 100 1 30000
#   -> 100 个节点, 1 副本/主, 即 50 主 50 从

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

engine="$1"; prefix="$2"; count="$3"; replicas="$4"; base_port="${5:-30000}"

case "$engine" in
  redis)  cli_image="$REDIS_IMAGE"; cli_bin="redis-cli" ;;
  valkey) cli_image="$VALKEY_IMAGE"; cli_bin="valkey-cli" ;;
  *) echo "unknown engine: $engine"; exit 1 ;;
esac

addrs=()
for i in $(seq 0 $((count - 1))); do
  port=$((base_port + i))
  addrs+=("127.0.0.1:${port}")
done

log "waiting for all $count nodes to accept connections..."
for addr in "${addrs[@]}"; do
  port="${addr##*:}"
  for _ in $(seq 1 30); do
    if docker run --rm --network host "$cli_image" "$cli_bin" -p "$port" ping 2>/dev/null | grep -q PONG; then
      break
    fi
    sleep 0.5
  done
done
log "all nodes reachable, forming cluster (replicas=${replicas})..."

docker run --rm --network host "$cli_image" "$cli_bin" --cluster create \
  "${addrs[@]}" \
  --cluster-replicas "$replicas" \
  --cluster-yes

log "cluster formed. waiting for cluster_state:ok..."
for _ in $(seq 1 30); do
  state=$(docker run --rm --network host "$cli_image" "$cli_bin" -p "$base_port" cluster info | grep cluster_state || true)
  echo "$state"
  if echo "$state" | grep -q "cluster_state:ok"; then
    break
  fi
  sleep 1
done
