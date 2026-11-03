#!/usr/bin/env node
// 桌面端安装前的静态自检：只读检查，不改系统。
import { existsSync, readFileSync } from 'node:fs'
import { homedir, networkInterfaces } from 'node:os'
import { join } from 'node:path'
import { spawnSync } from 'node:child_process'

const line = (ok, text) => console.log(`${ok ? '✓' : '✗'} ${text}`)
const major = Number(process.versions.node.split('.')[0])
line(major >= 20, `Node ${process.versions.node}（需要 >= 20）`)
console.log(`  平台 ${process.platform} / ${process.arch}`)

const dsh = spawnSync(process.platform === 'win32' ? 'where.exe' : 'which', ['dsh'], { encoding: 'utf8' })
line(dsh.status === 0, 'dsh 命令可用' + (dsh.status === 0 ? `：${String(dsh.stdout).trim().split(/\r?\n/)[0]}` : '（没找到，先装 DeepSeek Harness）'))

const profile = process.argv[2] || 'web'
const pkgPath = join(homedir(), '.dsh', 'profiles', profile, 'package.json')
if (existsSync(pkgPath)) {
  const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'))
  const bundles = pkg?.dsh?.profile?.bundles ?? []
  line(bundles.includes('dsh-harmony-watch'), `profile "${profile}" 已登记插件`)
} else {
  line(false, `找不到 profile "${profile}"（${pkgPath}）`)
}

const bin = join(homedir(), '.dsh', 'dsh-watch-bin', process.platform === 'win32' ? 'cloudflared.exe' : 'cloudflared')
line(existsSync(bin), existsSync(bin) ? `cloudflared 已就绪：${bin}` : 'cloudflared 未就绪，首次启动插件时会尝试下载')

const nets = networkInterfaces()
const addrs = Object.values(nets).flat().filter(n => n && n.family === 'IPv4' && !n.internal).map(n => n.address)
line(addrs.length > 0, `局域网地址：${addrs.join(', ') || '无'}`)

console.log('\n下一步：')
console.log(`  1. ./scripts/install.sh ${profile}`)
console.log('  2. 重启 DSH')
console.log('  3. 浏览器打开 http://127.0.0.1:8765/pair 查看配对码')
console.log('\n注意：Windows 首次启动可能弹防火墙，需要放行 8765。')
