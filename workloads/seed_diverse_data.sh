#!/usr/bin/env bash
# 向指定实例写入覆盖各数据类型/编码/TTL的多样化数据，用于兼容性对比
# 用法: ./seed_diverse_data.sh <engine: redis|valkey> <port>

set -euo pipefail
engine="$1"; port="$2"

case "$engine" in
  redis)  image="redis:7.2.6"; cli="redis-cli" ;;
  valkey) image="${VALKEY_IMAGE:-valkey/valkey:9.0}"; cli="valkey-cli" ;;
  *) echo "unknown engine"; exit 1 ;;
esac

echo "seeding diverse dataset into port ${port} (${engine})..."

{
  # --- String: 触发 int/embstr/raw 编码 ---
  echo "set str:int 12345"
  echo "set str:embstr short"
  echo "set str:raw $(python3 -c 'print("x"*100)')"
  echo "setex str:ttl 3600 expiringvalue"
  echo "append str:append part1"
  echo "append str:append part2"

  # --- Hash: 小 hash (listpack) 与大 hash (hashtable, 阈值默认512条) ---
  for i in $(seq 1 5); do echo "hset hash:small field$i value$i"; done
  for i in $(seq 1 600); do echo "hset hash:large field$i value$i"; done
  echo "hset hash:ttlfields f1 v1 f2 v2"
  if [ "$engine" = "valkey" ]; then
    echo "hexpire hash:ttlfields 3600 FIELDS 1 f1"
  fi

  # --- List: 小 list (listpack) 与大 list (quicklist, 按8KB字节阈值转换, 需大value触发) ---
  for i in $(seq 1 5); do echo "rpush list:small item$i"; done
  for i in $(seq 1 200); do echo "rpush list:large $(python3 -c 'print("v"*100)')$i"; done

  # --- Set: intset / listpack / hashtable 编码 ---
  for i in $(seq 1 5); do echo "sadd set:intset $i"; done
  for i in $(seq 1 5); do echo "sadd set:small member$i"; done
  for i in $(seq 1 200); do echo "sadd set:large member$i"; done

  # --- Sorted Set: 小 (listpack) 与大 (skiplist) ---
  for i in $(seq 1 5); do echo "zadd zset:small $i member$i"; done
  for i in $(seq 1 200); do echo "zadd zset:large $i member$i"; done

  # --- Stream ---
  echo "xadd stream:events * field1 value1"
  echo "xadd stream:events * field1 value2"

  # --- Expire on various types ---
  echo "expire hash:small 7200"
  echo "expire list:small 7200"

  # --- Bitmap / HyperLogLog ---
  echo "setbit bitmap:test 7 1"
  echo "pfadd hll:test a b c d e"
} | docker run --rm -i --network host "$image" "$cli" -p "$port" --pipe

echo "seed complete. dbsize:"
docker run --rm --network host "$image" "$cli" -p "$port" dbsize
