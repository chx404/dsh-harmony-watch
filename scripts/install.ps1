# dsh-watch 一键安装（Windows / PowerShell）
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$profileName = if ($args.Count -ge 1) { $args[0] } else { 'web' }

if (-not (Get-Command dsh -ErrorAction SilentlyContinue)) {
  Write-Error '没找到 dsh 命令。先安装 DeepSeek Harness，或把 dsh 加进 PATH。'
  exit 1
}

Write-Host "== 安装插件到 profile: $profileName"
dsh plugin --profile $profileName add "link:$root\host"

Write-Host '== 准备 cloudflared（失败不影响局域网使用）'
try {
  $module = Join-Path $root 'host\watch-tunnel-bin.mjs'
  $script = "const { ensureBinary } = await import('file://' + process.argv[1].replace(/\\/g,'/'));" +
            "const bin = await ensureBinary('cloudflared', (line) => console.log(line));" +
            "console.log(bin ? ('cloudflared: ' + bin) : 'cloudflared 未就绪，先只用局域网')"
  node --input-type=module -e $script $module
} catch {
  Write-Warning "cloudflared 准备失败：$_"
}

Write-Host @'

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
'@
