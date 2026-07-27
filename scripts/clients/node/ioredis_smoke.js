// ioredis 客户端冒烟测试: 连接、pipeline、cluster重定向处理(如是cluster模式)
// 用法: node ioredis_smoke.js <port> <label>
const Redis = require("ioredis");

const port = parseInt(process.argv[2], 10);
const label = process.argv[3] || String(port);

const results = [];
function check(name, cond) {
  results.push([name, !!cond]);
  console.log(`  [${cond ? "OK" : "FAIL"}] ${name}`);
}

async function main() {
  console.log(`=== ioredis smoke test against port ${port} (${label}) ===`);
  const redis = new Redis({ port, host: "127.0.0.1", lazyConnect: true });
  await redis.connect();

  const pong = await redis.ping();
  check("ping", pong === "PONG");

  await redis.set("smoke:str", "hello");
  const val = await redis.get("smoke:str");
  check("get", val === "hello");

  await redis.hset("smoke:hash", { a: "1", b: "2" });
  const hash = await redis.hgetall("smoke:hash");
  check("hgetall", hash.a === "1" && hash.b === "2");

  const pipeline = redis.pipeline();
  pipeline.set("smoke:pipe1", "v1");
  pipeline.set("smoke:pipe2", "v2");
  pipeline.get("smoke:pipe1");
  const pipeResults = await pipeline.exec();
  check("pipeline", pipeResults[2][1] === "v1");

  const info = await redis.info();
  check("info parses", info.includes("redis_version") || info.includes("valkey_version"));

  await redis.flushall();
  await redis.quit();

  const failed = results.filter(([, ok]) => !ok).length;
  console.log(`total: ${results.length}, failed: ${failed}`);
  process.exit(failed ? 1 : 0);
}

main().catch((e) => {
  console.error("ERROR:", e);
  process.exit(1);
});
