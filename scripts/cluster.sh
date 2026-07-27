#!/usr/bin/env bash
# 批量创建/销毁/管理 Redis 7.2 或 Valkey 9.x 集群节点(单机 Docker host network 模式)
#
# 用法:
#   ./cluster.sh create <engine: redis|valkey> <prefix> <node_count> [base_port]
#   ./cluster.sh join   <prefix> <node_count> <replicas_per_master> [base_port]
#   ./cluster.sh status <prefix>
#   ./cluster.sh destroy <prefix>
#
# 说明:
#   - 使用 --network host,每个节点占用 base_port+i (client) 与 base_port+i+10000 (cluster bus)
#   - 节点容器名: ve-<prefix>-<index 四位数>
#   - 数据目录: .data/<prefix>/<index>/  (不入库)

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
  grep '^#' "$0" | sed 's/^#//'
  exit 1
}

cmd_create() {
  local engine="$1" prefix="$2" count="$3" base_port="${4:-30000}"
  local image binary
  case "$engine" in
    redis)  image="$REDIS_IMAGE"; binary="redis-server" ;;
    valkey) image="$VALKEY_IMAGE"; binary="valkey-server" ;;
    *) echo "unknown engine: $engine (use redis|valkey)"; exit 1 ;;
  esac

  log "creating $count $engine nodes (prefix=$prefix, base_port=$base_port, image=$image)"

  for i in $(seq 0 $((count - 1))); do
    local idx port busport name datadir
    idx=$(printf "%04d" "$i")
    port=$((base_port + i))
    busport=$((port + 10000))
    name="ve-${prefix}-${idx}"
    datadir="${DATA_ROOT}/${prefix}/${idx}"

    if container_exists "$name"; then
      log "  skip $name (already exists)"
      continue
    fi

    ensure_data_dir "$datadir"
    cat > "${datadir}/node.conf" <<EOF
port ${port}
cluster-enabled yes
cluster-config-file nodes.conf
cluster-node-timeout 5000
cluster-port ${busport}
appendonly no
save ""
daemonize no
protected-mode no
dir /data
logfile ""
EOF

    docker run -d \
      --name "$name" \
      --network host \
      -v "${datadir}:/data" \
      "$image" \
      "$binary" /data/node.conf > /dev/null

    if [ $(( (i + 1) % 50 )) -eq 0 ]; then
      log "  started $((i + 1))/$count nodes"
    fi
  done
  log "done. created $count nodes: ${prefix}"
}

cmd_status() {
  local prefix="$1"
  local total running
  total=$(docker ps -a --format '{{.Names}}' | grep -c "^ve-${prefix}-" || true)
  running=$(docker ps --format '{{.Names}}' | grep -c "^ve-${prefix}-" || true)
  echo "prefix=${prefix} total=${total} running=${running}"
  docker ps -a --format '{{.Names}}\t{{.Status}}' | grep "^ve-${prefix}-" | sort || true
}

cmd_destroy() {
  local prefix="$1"
  local names
  names=$(docker ps -a --format '{{.Names}}' | grep "^ve-${prefix}-" || true)
  if [ -z "$names" ]; then
    log "no containers found for prefix=${prefix}"
    return
  fi
  log "removing $(echo "$names" | wc -l | tr -d ' ') containers for prefix=${prefix}"
  echo "$names" | xargs -P 16 -I{} docker rm -f {} > /dev/null
  rm -rf "${DATA_ROOT:?}/${prefix}"
  log "destroyed prefix=${prefix}"
}

main() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    create)  cmd_create "$@" ;;
    status)  cmd_status "$@" ;;
    destroy) cmd_destroy "$@" ;;
    *) usage ;;
  esac
}

main "$@"
