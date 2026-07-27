// Jedis 客户端冒烟测试: 连接、pipeline、基本命令
// 用法: java -cp "lib/*:." JedisSmoke <port> <label>
import redis.clients.jedis.Jedis;
import redis.clients.jedis.Pipeline;
import redis.clients.jedis.Response;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

public class JedisSmoke {
    static int total = 0;
    static int failed = 0;

    static void check(String name, boolean cond) {
        total++;
        if (!cond) failed++;
        System.out.println("  [" + (cond ? "OK" : "FAIL") + "] " + name);
    }

    public static void main(String[] args) {
        int port = Integer.parseInt(args[0]);
        String label = args.length > 1 ? args[1] : String.valueOf(port);
        System.out.println("=== Jedis smoke test against port " + port + " (" + label + ") ===");

        try (Jedis jedis = new Jedis("127.0.0.1", port)) {
            check("ping", "PONG".equals(jedis.ping()));

            jedis.set("smoke:str", "hello");
            check("get", "hello".equals(jedis.get("smoke:str")));

            Map<String, String> hashData = new HashMap<>();
            hashData.put("a", "1");
            hashData.put("b", "2");
            jedis.hset("smoke:hash", hashData);
            Map<String, String> hash = jedis.hgetAll("smoke:hash");
            check("hgetall", "1".equals(hash.get("a")) && "2".equals(hash.get("b")));

            Pipeline pipe = jedis.pipelined();
            pipe.set("smoke:pipe1", "v1");
            pipe.set("smoke:pipe2", "v2");
            Response<String> getResp = pipe.get("smoke:pipe1");
            pipe.sync();
            check("pipeline", "v1".equals(getResp.get()));

            String info = jedis.info();
            check("info parses", info.contains("redis_version") || info.contains("valkey_version"));

            jedis.flushAll();
        } catch (Exception e) {
            System.out.println("ERROR: " + e);
            failed++;
        }

        System.out.println("total: " + total + ", failed: " + failed);
        System.exit(failed > 0 ? 1 : 0);
    }
}
