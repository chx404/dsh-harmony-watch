// 隧道二进制的平台查找与自动下载。只写 ~/.dsh/dsh-watch-bin，不碰系统目录。
import { existsSync, mkdirSync, writeFileSync, chmodSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { spawnSync } from 'node:child_process'

const binDir = () => join(homedir(), '.dsh', 'dsh-watch-bin')

const platform = () => {
  if (process.platform === 'win32') return 'windows'
  if (process.platform === 'darwin') return 'darwin'
  return 'linux'
}

const arch = () => (process.arch === 'arm64' ? 'arm64' : 'amd64')

export function binaryPath(kind) {
  const name = kind === 'frpc' ? (process.platform === 'win32' ? 'frpc.exe' : 'frpc') : (process.platform === 'win32' ? 'cloudflared.exe' : 'cloudflared')
  const candidate = join(binDir(), name)
  return existsSync(candidate) ? candidate : ''
}

function sources(kind) {
  const os = platform()
  const cpu = arch()
  if (kind === 'cloudflared') {
    const asset = `cloudflared-${os === 'darwin' ? 'darwin' : os}-${cpu}`
    const path = `cloudflare/cloudflared/releases/latest/download/${asset}`
    return [
      `https://github.com/${path}`,
      `https://ghfast.top/https://github.com/${path}`,
    ]
  }
  return []
}

async function download(url, timeoutMs = 120000) {
  const res = await fetch(url, { redirect: 'follow', signal: AbortSignal.timeout(timeoutMs) })
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return Buffer.from(await res.arrayBuffer())
}

/** 确保二进制可用：已存在直接返回；否则尝试下载。失败返回空字符串，由调用方降级。 */
export async function ensureBinary(kind, log = () => {}) {
  const existing = binaryPath(kind)
  if (existing) return existing
  const urls = sources(kind)
  if (urls.length === 0) return ''
  mkdirSync(binDir(), { recursive: true })
  const target = join(binDir(), process.platform === 'win32' ? `${kind}.exe` : kind)
  for (const url of urls) {
    try {
      log(`下载 ${kind}：${url}`)
      const blob = await download(url)
      if (blob.length < 1024 * 1024) throw new Error('文件过小')
      writeFileSync(target, blob)
      if (process.platform !== 'win32') chmodSync(target, 0o755)
      log(`${kind} 已就绪：${target}`)
      return target
    } catch (error) {
      log(`${kind} 下载失败：${error.message}`)
    }
  }
  return ''
}

/** frpc 用系统里已有的；没有就让用户自己放。frp 版本碎片化，暂不自动下载。 */
export function findFrpc() {
  const local = binaryPath('frpc')
  if (local) return local
  try {
    const probe = spawnSync(process.platform === 'win32' ? 'where.exe' : 'which', ['frpc'], {
      encoding: 'utf8', windowsHide: true,
    })
    const line = String(probe.stdout || '').split(/\r?\n/).map(s => s.trim()).find(Boolean)
    return line || ''
  } catch {
    return ''
  }
}
