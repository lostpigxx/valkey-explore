// go-redis 客户端冒烟测试: 连接、pipeline、基本命令
// 用法: go run main.go <port> <label>
package main

import (
	"context"
	"fmt"
	"os"
	"strconv"

	"github.com/redis/go-redis/v9"
)

var ctx = context.Background()

type result struct {
	name string
	ok   bool
}

var results []result

func check(name string, cond bool) {
	results = append(results, result{name, cond})
	status := "FAIL"
	if cond {
		status = "OK"
	}
	fmt.Printf("  [%s] %s\n", status, name)
}

func main() {
	port, _ := strconv.Atoi(os.Args[1])
	label := strconv.Itoa(port)
	if len(os.Args) > 2 {
		label = os.Args[2]
	}
	fmt.Printf("=== go-redis smoke test against port %d (%s) ===\n", port, label)

	rdb := redis.NewClient(&redis.Options{
		Addr: fmt.Sprintf("127.0.0.1:%d", port),
	})
	defer rdb.Close()

	pong, err := rdb.Ping(ctx).Result()
	check("ping", err == nil && pong == "PONG")

	err = rdb.Set(ctx, "smoke:str", "hello", 0).Err()
	check("set", err == nil)
	val, err := rdb.Get(ctx, "smoke:str").Result()
	check("get", err == nil && val == "hello")

	err = rdb.HSet(ctx, "smoke:hash", map[string]interface{}{"a": "1", "b": "2"}).Err()
	check("hset", err == nil)
	hash, err := rdb.HGetAll(ctx, "smoke:hash").Result()
	check("hgetall", err == nil && hash["a"] == "1" && hash["b"] == "2")

	pipe := rdb.Pipeline()
	pipe.Set(ctx, "smoke:pipe1", "v1", 0)
	pipe.Set(ctx, "smoke:pipe2", "v2", 0)
	getCmd := pipe.Get(ctx, "smoke:pipe1")
	_, err = pipe.Exec(ctx)
	check("pipeline", err == nil && getCmd.Val() == "v1")

	info, err := rdb.Info(ctx).Result()
	check("info parses", err == nil && (contains(info, "redis_version") || contains(info, "valkey_version")))

	rdb.FlushAll(ctx)

	failed := 0
	for _, r := range results {
		if !r.ok {
			failed++
		}
	}
	fmt.Printf("total: %d, failed: %d\n", len(results), failed)
	if failed > 0 {
		os.Exit(1)
	}
}

func contains(haystack, needle string) bool {
	return len(haystack) >= len(needle) && (func() bool {
		for i := 0; i+len(needle) <= len(haystack); i++ {
			if haystack[i:i+len(needle)] == needle {
				return true
			}
		}
		return false
	})()
}
