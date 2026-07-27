#!/usr/bin/env bash
# 拉取 Jedis 及其依赖 jar 到 lib/ (未纳入 git,运行本脚本重新生成)
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p lib
BASE=https://repo1.maven.org/maven2
JEDIS_VER=5.2.0
POOL_VER=2.12.0
SLF4J_VER=2.0.13
GSON_VER=2.10.1

curl -sL -o lib/jedis.jar "$BASE/redis/clients/jedis/$JEDIS_VER/jedis-$JEDIS_VER.jar"
curl -sL -o lib/commons-pool2.jar "$BASE/org/apache/commons/commons-pool2/$POOL_VER/commons-pool2-$POOL_VER.jar"
curl -sL -o lib/slf4j-api.jar "$BASE/org/slf4j/slf4j-api/$SLF4J_VER/slf4j-api-$SLF4J_VER.jar"
curl -sL -o lib/slf4j-simple.jar "$BASE/org/slf4j/slf4j-simple/$SLF4J_VER/slf4j-simple-$SLF4J_VER.jar"
curl -sL -o lib/gson.jar "$BASE/com/google/code/gson/gson/$GSON_VER/gson-$GSON_VER.jar"

echo "done: $(ls lib | wc -l | tr -d ' ') jars in lib/"
