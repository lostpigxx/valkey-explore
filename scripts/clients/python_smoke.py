#!/usr/bin/env python3
"""redis-py 客户端冒烟测试: 连接、RESP2/RESP3、pipeline、基本命令
用法: python3 python_smoke.py <port> [label]
"""
import sys
import redis

port = int(sys.argv[1])
label = sys.argv[2] if len(sys.argv) > 2 else str(port)

results = []


def check(name, cond):
    results.append((name, bool(cond)))
    print(f"  [{'OK' if cond else 'FAIL'}] {name}")


print(f"=== redis-py smoke test against port {port} ({label}) ===")

for protocol in (2, 3):
    print(f"-- RESP{protocol} --")
    r = redis.Redis(host="127.0.0.1", port=port, protocol=protocol, decode_responses=True)
    check(f"resp{protocol} ping", r.ping() is True)
    r.set("smoke:str", "hello")
    check(f"resp{protocol} get", r.get("smoke:str") == "hello")
    r.hset("smoke:hash", mapping={"a": "1", "b": "2"})
    check(f"resp{protocol} hgetall", r.hgetall("smoke:hash") == {"a": "1", "b": "2"})

    pipe = r.pipeline()
    pipe.set("smoke:pipe1", "v1")
    pipe.set("smoke:pipe2", "v2")
    pipe.get("smoke:pipe1")
    pipe_results = pipe.execute()
    check(f"resp{protocol} pipeline", pipe_results == [True, True, "v1"])

    info = r.info()
    check(f"resp{protocol} info parses", isinstance(info, dict) and "redis_version" in info or "valkey_version" in info)

    r.flushall()

n_fail = sum(1 for _, ok in results if not ok)
print(f"total: {len(results)}, failed: {n_fail}")
sys.exit(1 if n_fail else 0)
