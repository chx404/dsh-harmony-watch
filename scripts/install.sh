#!/usr/bin/env bash
# dsh-watch 一键安装：装插件、备好 cloudflared、提示重启。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PROFILE="${1:-web}"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"

if ! command -v dsh >/dev/null 2>&1; then
  echo "没找到 dsh 命令。先安装 DeepSeek Harness，或把 dsh 加进 PATH。" >&2
  exit 1
fi

echo "== 安装插件到 profile: $PROFILE"
dsh plugin --profile "$PROFILE" add "link:$ROOT/host"

echo "== 准备 cloudflared（失败不影响局域网使用）"
node --input-type=module - "$ROOT" <<'JS' || true
const { ensureBinary } = await import(process.argv[2] + '/host/watch-tunnel-bin.mjs')
const bin = await ensureBinary('cloudflared', (line) => console.log(line))
console.log(bin ? `cloudflared: ${bin}` : 'cloudflared 未就绪，先只用局域网')
JS

cat <<'TIP'

== 完成

1. 重启 DSH（桌面端退出重开；命令行重启 dsh web）
2. 启动日志里会打印 6 位配对码和外网地址
3. 手表填地址 + 配对码

想固定外网地址：在 profile 的 cordis.patch.yml 里给 dsh-watch 配
  tunnel: cloudflared-token
  tunnelToken: <Cloudflare 隧道 token>
  remoteUrl: https://你的域名
或改用 frp：
  tunnel: frp
  frpServer: 你的服务器
  frpRemotePort: 6000
  remoteUrl: http://你的服务器:6000
TIP
