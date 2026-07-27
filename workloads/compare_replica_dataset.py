#!/usr/bin/env python3
"""对比 Redis Cluster 某个主节点与其对应副本节点(可能是异构 Valkey)之间的数据是否一致。
发送 READONLY 让副本节点接受本地读取而非返回 MOVED。

用法: python3 compare_replica_dataset.py <master_host> <master_port> <replica_host> <replica_port>
"""
import sys
import redis


def dump_value(r, key):
    t = r.type(key)
    if t in (b"string", "string"):
        return ("string", r.get(key))
    if t in (b"hash", "hash"):
        return ("hash", dict(sorted(r.hgetall(key).items())))
    if t in (b"list", "list"):
        return ("list", r.lrange(key, 0, -1))
    if t in (b"set", "set"):
        return ("set", sorted(r.smembers(key)))
    if t in (b"zset", "zset"):
        return ("zset", r.zrange(key, 0, -1, withscores=True))
    return (str(t), None)


def snapshot(host, port, readonly=False):
    r = redis.Redis(host=host, port=port, decode_responses=False)
    if readonly:
        r.execute_command("READONLY")
    keys = sorted(r.keys("*"))
    return {k: dump_value(r, k) for k in keys}


def main():
    if len(sys.argv) != 5:
        print(__doc__)
        sys.exit(1)
    mh, mp, rh, rp = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])

    sm = snapshot(mh, mp, readonly=False)
    sr = snapshot(rh, rp, readonly=True)

    km, kr = set(sm.keys()), set(sr.keys())
    only_m = km - kr
    only_r = kr - km
    common = km & kr
    mismatches = [k for k in common if sm[k] != sr[k]]

    print(f"master({mh}:{mp}) keys: {len(km)}, replica({rh}:{rp}) keys: {len(kr)}")
    print(f"only in master: {sorted(only_m)}")
    print(f"only in replica: {sorted(only_r)}")
    print(f"value mismatches: {len(mismatches)}")
    for k in mismatches:
        print(f"  {k}: master={sm[k]!r} replica={sr[k]!r}")

    ok = not only_m and not only_r and not mismatches
    print("RESULT:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
