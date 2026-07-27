#!/usr/bin/env bash
# 故障注入工具: kill/pause/resume 指定前缀集群里的若干节点,并记录时间戳,
# 用于配合 cluster.sh status 及 valkey-cli cluster info 观察 failover 恢复时间。
#
# 用法:
#   ./fault_inject.sh kill    <prefix> <n>        # SIGKILL 掉 n 个随机主节点容器(按名称排序取前n个,便于复现)
#   ./fault_inject.sh pause   <prefix> <n>         # SIGSTOP 模拟假死
#   ./fault_inject.sh resume  <prefix> <n>         # SIGCONT 恢复
#   ./fault_inject.sh kill-named <name1> <name2> ...

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

pick_containers() {
  local prefix="$1" n="$2"
  docker ps --format '{{.Names}}' | grep "^ve-${prefix}-" | sort | head -n "$n"
}

cmd_kill() {
  local prefix="$1" n="$2"
  local targets
  targets=$(pick_containers "$prefix" "$n")
  log "killing $n nodes: $(echo "$targets" | tr '\n' ' ')"
  echo "$targets" | xargs -P 16 -I{} docker kill -s SIGKILL {} > /dev/null
  log "kill issued at $(now_ms)"
}

cmd_pause() {
  local prefix="$1" n="$2"
  local targets
  targets=$(pick_containers "$prefix" "$n")
  log "pausing $n nodes: $(echo "$targets" | tr '\n' ' ')"
  echo "$targets" | xargs -P 16 -I{} docker kill -s SIGSTOP {} > /dev/null
  log "pause issued at $(now_ms)"
}

cmd_resume() {
  local prefix="$1" n="$2"
  local targets
  targets=$(pick_containers "$prefix" "$n")
  log "resuming $n nodes: $(echo "$targets" | tr '\n' ' ')"
  echo "$targets" | xargs -P 16 -I{} docker kill -s SIGCONT {} > /dev/null
  log "resume issued at $(now_ms)"
}

cmd_kill_named() {
  log "killing named containers: $*"
  docker kill -s SIGKILL "$@" > /dev/null
  log "kill issued at $(now_ms)"
}

main() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    kill)       cmd_kill "$@" ;;
    pause)      cmd_pause "$@" ;;
    resume)     cmd_resume "$@" ;;
    kill-named) cmd_kill_named "$@" ;;
    *) echo "usage: kill|pause|resume <prefix> <n> | kill-named <names...>"; exit 1 ;;
  esac
}

main "$@"
