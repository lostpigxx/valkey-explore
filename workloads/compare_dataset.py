#!/usr/bin/env python3
"""对比两个 Redis 协议兼容实例上的全量数据集是否一致(用于 RDB 加载兼容性验证)。

用法: python3 compare_dataset.py <host1> <port1> <host2> <port2>
依赖: pip install redis (若无则报错提示改用 docker exec 方案)
"""
import sys

try:
    import redis
except ImportError:
    print("需要 redis-py: pip3 install redis", file=sys.stderr)
    sys.exit(2)


def dump_value(r, key):
    t = r.type(key)
    if t == b"string" or t == "string":
        return ("string", r.get(key))
    if t in (b"hash", "hash"):
        return ("hash", dict(sorted(r.hgetall(key).items())))
    if t in (b"list", "list"):
        return ("list", r.lrange(key, 0, -1))
    if t in (b"set", "set"):
        return ("set", sorted(r.smembers(key)))
    if t in (b"zset", "zset"):
        return ("zset", r.zrange(key, 0, -1, withscores=True))
    if t in (b"stream", "stream"):
        return ("stream", r.xrange(key))
    return (str(t), None)


def snapshot(host, port):
    r = redis.Redis(host=host, port=port, decode_responses=False)
    keys = sorted(r.keys("*"))
    data = {}
    for k in keys:
        ttl = r.ttl(k)
        data[k] = {
            "value": dump_value(r, k),
            "has_ttl": ttl > 0,
        }
    return data


def main():
    if len(sys.argv) != 5:
        print(__doc__)
        sys.exit(1)
    h1, p1, h2, p2 = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])

    s1 = snapshot(h1, p1)
    s2 = snapshot(h2, p2)

    keys1, keys2 = set(s1.keys()), set(s2.keys())
    only1 = keys1 - keys2
    only2 = keys2 - keys1
    common = keys1 & keys2

    mismatches = []
    for k in sorted(common):
        if s1[k]["value"] != s2[k]["value"]:
            mismatches.append((k, s1[k]["value"], s2[k]["value"]))

    ttl_mismatches = [k for k in common if s1[k]["has_ttl"] != s2[k]["has_ttl"]]

    print(f"source keys: {len(keys1)}, target keys: {len(keys2)}")
    print(f"only in source: {sorted(only1)}")
    print(f"only in target: {sorted(only2)}")
    print(f"value mismatches: {len(mismatches)}")
    for k, v1, v2 in mismatches:
        print(f"  {k}: source={v1!r} target={v2!r}")
    print(f"ttl presence mismatches: {ttl_mismatches}")

    ok = not only1 and not only2 and not mismatches and not ttl_mismatches
    print("RESULT:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
