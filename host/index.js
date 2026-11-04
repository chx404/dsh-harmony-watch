/**
 * dsh-watch — Host 半边：把手表 / 手机浏览器接到这台电脑上的 DeepSeek Harness。
 *
 * 能力：
 *   1. 自己起一个极小的 HTTP 服务（默认 0.0.0.0:8765），供手表 App / 浏览器访问；
 *   2. `GET /api/events` 是 SSE 实时流：把模型的工具动作、回复、审批请求推给手表；
 *   3. `POST /api/prompt`：把手表发来的指令塞进当前会话（运行中默认 steer，空闲 followup）；
 *   4. `POST /api/approval`：手表上点「允许 / 拒绝」，直接成为 `approval/request`
 *      waterfall 的最外层应答者（`prepend: true`，因此先于 Web UI 的内置通道）；
 *   5. `GET /api/state` / `/api/sessions`：状态、会话列表；冷会话可按需 resume。
 *
 * 设计约束：
 *   - 不 import 任何 `@deepseek-ai/*` 包（插件可能被 link 到 profile 外，裸包名解析不可靠），
 *     只依赖 Node 内建模块；需要上游语义的地方在这里就地重写（见 installSelection）。
 *   - 审批是 fail-closed：手表不在线 / 超时 → 交还给下一条应答者（Web UI）。
 */
import { createServer } from 'node:http'
import { randomBytes, randomUUID } from 'node:crypto'
import { spawn, spawnSync } from 'node:child_process'
import { createSocket } from 'node:dgram'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { homedir, hostname, networkInterfaces } from 'node:os'
import { join } from 'node:path'
import { messageBody, messageImages, argumentsBody, publicEvent } from './watch-event-text.mjs'
import { createWatchModelControl } from './watch-model-control.mjs'
import { ensureBinary, binaryPath, findFrpc } from './watch-tunnel-bin.mjs'

export const name = 'dsh-harmony-watch'

const VERSION = '2.0.1'
const RING_MAX = 400
const TOKEN_HEADER = 'x-dsh-watch-token'

const DEFAULT_CFG = {
  /** 监听端口。 */
  port: 8765,
  /** 监听地址：'0.0.0.0' 局域网可达；'127.0.0.1' 仅配合 adb reverse 调试。 */
  bind: '0.0.0.0',
  /** 配对令牌；留空则自动生成并持久化到 $DSH_HOME/dsh-watch.json。 */
  token: '',
  /** 'watch' = 手表在线时由手表审批；'off' = 只旁观，审批仍走 Web UI。 */
  approvalMode: 'watch',
  /** 手表审批超时（毫秒）；超时后交还 Web UI，避免卡住回合。 */
  approvalTimeoutMs: 60000,
  /** 新建会话时使用的默认工作目录；留空取主进程 cwd。 */
  defaultCwd: '',
  /** 事件流里单条文本的最大长度。 */
  maxText: 400,
  /** 是否在局域网里广播自己，让手表自动发现（UDP）。 */
  discovery: true,
  /** 发现用的 UDP 端口。 */
  discoveryPort: 8766,
  /** 6 位配对码的有效期（毫秒）。 */
  pairingTtlMs: 600000,
  /**
   * 外网访问：'off' 只用局域网；'ssh' 用系统 ssh 跑一条反向隧道
   * （localhost.run，免账号，命令：ssh -R 80:127.0.0.1:8765 nokey@localhost.run）；
   * 'cloudflared' 用本机已装的 cloudflared 起 quick tunnel。
   */
  tunnel: 'off',
  /** 自己已有隧道/反代时直接填对外地址（https://xxx），优先级最高。 */
  remoteUrl: '',
  /** ssh 隧道目标（默认 localhost.run；换 pinggy：a.pinggy.io:443）。 */
  tunnelHost: 'localhost.run',
  tunnelPort: 22,
  tunnelUser: 'nokey',
  /** Cloudflare 固定隧道 token；填了就优先用它，地址用 remoteUrl 指定。 */
  tunnelToken: '',
  /** frp 服务端；填了 frpServer 且没有可用 cloudflared 时走 frp。 */
  frpServer: '',
  frpServerPort: 7000,
  frpToken: '',
  frpRemotePort: 0,
}

const MIME = {
  html: 'text/html; charset=utf-8',
  json: 'application/json; charset=utf-8',
  js: 'text/javascript; charset=utf-8',
  css: 'text/css; charset=utf-8',
  plain: 'text/plain; charset=utf-8',
}

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

function dshHome() {
  const env = process.env.DSH_HOME
  return env && env.trim() !== '' ? env : join(homedir(), '.dsh')
}

function clip(text, max) {
  const s = String(text ?? '')
  return s.length <= max ? s : s.slice(0, max - 1) + '…'
}

function oneLine(text) {
  return String(text ?? '').replace(/\s+/g, ' ').trim()
}

function nowMs() {
  return Date.now()
}

function readJsonFile(file) {
  try {
    return JSON.parse(readFileSync(file, 'utf8'))
  } catch {
    return undefined
  }
}

function writeJsonFile(file, value) {
  try {
    mkdirSync(join(file, '..'), { recursive: true })
  } catch {
    /* 目录已存在 */
  }
  writeFileSync(file, JSON.stringify(value, null, 2), 'utf8')
}

/** 从工具原始参数 JSON 里挑出最像「这一步在干什么」的那段。 */
function summarizeToolArgs(toolName, raw, max = 160) {
  if (typeof raw !== 'string' || raw === '') return ''
  let args
  try {
    args = JSON.parse(raw)
  } catch {
    return clip(oneLine(raw), max)
  }
  if (args === null || typeof args !== 'object') return clip(oneLine(String(args)), max)

  const pick = (key) => (typeof args[key] === 'string' ? args[key] : undefined)
  const command = pick('command') ?? pick('cmd')
  if (command) return clip(oneLine(command), max)
  const path = pick('file_path') ?? pick('path') ?? pick('filePath') ?? pick('target')
  if (path) return clip(oneLine(path), max)
  const pattern = pick('pattern') ?? pick('query') ?? pick('regex') ?? pick('search')
  if (pattern) return clip(oneLine(pattern), max)
  const free = pick('task') ?? pick('prompt') ?? pick('description') ?? pick('question') ?? pick('text')
  if (free) return clip(oneLine(free), max)
  // 兜底：拼接前几个标量字段
  const parts = []
  for (const [k, v] of Object.entries(args)) {
    if (typeof v === 'string') parts.push(`${k}=${oneLine(v)}`)
    else if (typeof v === 'number' || typeof v === 'boolean') parts.push(`${k}=${v}`)
    if (parts.length >= 3) break
  }
  return clip(parts.join(' ') || oneLine(raw), max)
}

/** 从一个 tool/result 事件里抽出可展示的短文本。 */
function summarizeToolResult(message, max = 200) {
  const blocks = message?.content
  if (!Array.isArray(blocks)) return ''
  const texts = []
  for (const block of blocks) {
    if (!block || typeof block !== 'object') continue
    if (block.type === 'text' && typeof block.text === 'string') texts.push(block.text)
    else if (block.type === 'tool-result' && Array.isArray(block.content)) {
      for (const inner of block.content) {
        if (inner && inner.type === 'text' && typeof inner.text === 'string') texts.push(inner.text)
      }
    }
  }
  return clip(oneLine(texts.join(' ')), max)
}

/** 从消息内容里抽文本（assistant/message、user/message）。 */
function messageText(message, max = 400) {
  const blocks = message?.content
  if (!Array.isArray(blocks)) return ''
  const out = []
  for (const block of blocks) {
    if (block && block.type === 'text' && typeof block.text === 'string') out.push(block.text)
  }
  return clip(oneLine(out.join(' ')), max)
}

/** 上游 dsh-agent/model-selection 的同构实现：把选区挂到 agent 的 prompt 组装与请求路由上。 */
function installSelection(agentCtx, selection) {
  agentCtx.on('system-prompt/assemble', async (_assembly, _context, next) => {
    const selected = selection.current
    const assembled = await next()
    selection.assembled = selected
    if (selected === undefined) return assembled
    return {
      ...assembled,
      variables: { ...assembled.variables, provider: selected.provider, model: selected.model },
    }
  })
  agentCtx.on('agent/request', async (_payload, next) => {
    const resolved = await next()
    const selected = selection.assembled
    if (selected === undefined) return resolved
    const { reasoningEffort: _inherited, ...rest } = resolved
    return {
      ...rest,
      provider: selected.provider,
      model: selected.model,
      ...(selected.reasoningEffort === undefined ? {} : { reasoningEffort: selected.reasoningEffort }),
    }
  })
}

// ---------------------------------------------------------------------------
// 插件主体
// ---------------------------------------------------------------------------

export function apply(ctx, config) {
  const cfg = { ...DEFAULT_CFG, ...(config || {}) }
  const modelControl = createWatchModelControl(ctx)
  const settingsFile = join(dshHome(), 'dsh-watch.json')
  const stored = readJsonFile(settingsFile) || {}

  const settings = {
    token: String(cfg.token || stored.token || '').trim(),
  }
  if (!settings.token) {
    settings.token = randomBytes(12).toString('base64url')
    writeJsonFile(settingsFile, { ...stored, token: settings.token })
  }

  const log = (...args) => console.log('[dsh-watch]', ...args)
  const warn = (...args) => console.warn('[dsh-watch]', ...args)

  // ---- 运行时状态 ---------------------------------------------------------
  const state = {
    seq: 0,
    events: [], // {seq,t,sessionId,kind,text,...}
    sessions: new Map(), // id -> {id,title,cwd,live,running,lastAt}
    selectedId: null,
    pending: new Map(), // approvalId -> {id,sessionId,tool,reason,preview,expiresAt,resolve,timer}
    subscribers: new Set(), // {res,sessionId}
    handles: new Map(), // sessionId -> AgentHandle（本插件 resume/create 出来的）
  }

  const maxText = Number(cfg.maxText) || 400

  // ---- 配对码 -------------------------------------------------------------
  // 6 位一次性配对码，只在电脑本机页面（/pair）和启动日志里露出，
  // 手表用它换长期 token —— 用户不用在表上敲 60 位令牌。
  const pairState = {
    code: '',
    expiresAt: 0,
    attempts: new Map(), // ip -> {count, resetAt}
  }

  function newPairCode() {
    return String(Math.floor(100000 + Math.random() * 900000))
  }

  function rotatePairCode(reason) {
    pairState.code = newPairCode()
    pairState.expiresAt = nowMs() + Math.max(60000, Number(cfg.pairingTtlMs) || 600000)
    pairState.attempts.clear()
    const minutes = Math.round((pairState.expiresAt - nowMs()) / 60000)
    log(`配对码 ${pairState.code}（${minutes} 分钟内有效；电脑上打开 /pair 查看）${reason ? ' · ' + reason : ''}`)
    return pairState.code
  }

  function pairCodeUsable() {
    if (!pairState.code) return false
    if (nowMs() > pairState.expiresAt) return false
    return true
  }

  function currentPairCode(reason) {
    if (!pairCodeUsable()) rotatePairCode(reason || 'expired')
    return pairState.code
  }

  function lanAddresses() {
    const out = []
    try {
      const interfaces = networkInterfaces()
      for (const [name, list] of Object.entries(interfaces)) {
        for (const item of list || []) {
          if (item.family !== 'IPv4' || item.internal) continue
          if (item.address.startsWith('169.254.')) continue
          out.push({ name, address: item.address })
        }
      }
    } catch {
      /* ignore */
    }
    return out
  }

  function isLoopback(req) {
    const remote = req.socket?.remoteAddress ?? ''
    return remote === '127.0.0.1' || remote === '::1' || remote === '::ffff:127.0.0.1'
  }

  /** 电脑本机可见的配对页：6 位码 + 局域网地址 + 步骤说明。 */
  function pairPageHtml() {
    const code = currentPairCode('view')
    const minutes = Math.max(0, Math.round((pairState.expiresAt - nowMs()) / 60000))
    const addresses = lanAddresses()
    const addressItems = addresses.length
      ? addresses
          .map(
            (item) =>
              `<li><code>${item.address}:${boundPort}</code><span class="muted">${item.name}</span></li>`,
          )
          .join('')
      : '<li class="muted">没有检测到局域网 IPv4（先连上 WiFi/网线）</li>'
    return `<!doctype html>
<html lang="zh"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>DSH Watch 配对</title>
<style>
:root{color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;background:#0b0d12;color:#e8ecf4;font:15px/1.6 -apple-system,"Segoe UI",system-ui,sans-serif}
main{max-width:640px;margin:0 auto;padding:28px 20px 60px}
h1{font-size:20px;margin:0 0 4px}
.muted{color:#8794ac;font-size:13px}
.code{display:flex;gap:10px;margin:18px 0 6px}
.code span{flex:1;text-align:center;background:#131826;border:1px solid #243149;border-radius:14px;padding:14px 0;font:700 34px/1 ui-monospace,monospace;letter-spacing:2px}
ol{padding-left:20px}
li{margin:4px 0}
ul{list-style:none;padding:0;margin:6px 0 0}
ul li{display:flex;justify-content:space-between;gap:10px;background:#131826;border:1px solid #243149;border-radius:10px;padding:8px 12px;margin:6px 0}
code{background:#1b2334;border-radius:6px;padding:1px 6px;font-size:13px}
.panel{background:#111726;border:1px solid #243149;border-radius:14px;padding:14px 16px;margin:14px 0}
.hint{color:#ffc178}
</style></head><body><main>
<h1>用手机/手表连这台电脑</h1>
<p class="muted">这个页面只在电脑本机可见；配对码等于一次性钥匙，别截图外发。</p>
<div class="code">${code.split('').map((d) => `<span>${d}</span>`).join('')}</div>
<p class="muted">还有 ${minutes} 分钟有效 · 每配对成功一次会自动换新码</p>

<div class="panel">
  <b>手表上怎么操作</b>
  <ol>
    <li>打开 <b>DSH Watch</b>，首次进入先选圆屏/方屏；</li>
    <li>在「发现电脑」里点这台电脑（<b>${hostname()}</b>）；</li>
    <li>输入上面 6 位配对码 → 自动连接。</li>
  </ol>
  <p class="muted">手表搜不到时：点「手动输入」，服务器填下面列表里的地址，令牌填 6 位码即可。</p>
</div>

<div class="panel">
  <b>这台电脑的局域网地址</b>
  <ul>${addressItems}</ul>
</div>

<div class="panel">
  <b>旧版 App / 手动配对</b>
  <p class="muted">令牌：<code>${settings.token}</code></p>
  <p class="muted">服务器：<code>${(addresses[0]?.address ?? '127.0.0.1') + ':' + boundPort}</code></p>
</div>
${(typeof tunnelState !== 'undefined' && tunnelState.url)
    ? `<div class="panel">
  <b>外网地址（离开局域网时用这个）</b>
  <p><code>${tunnelState.url}</code></p>
  <p class="muted">手表「连接电脑 → 手动输入」里服务器填这个地址，配对码照常 6 位；
  或先在局域网里连一次，手表会自动记住。免费隧道每次重启电脑会换地址。</p>
</div>`
    : ''}
</main></body></html>`
  }

  // ---- 外网隧道 -----------------------------------------------------------
  // 只在「局域网连不上」时用到：手表会从 /api/state 学到这个地址，联网后自动切换。
  const tunnelState = {
    url: '',
    child: undefined,
    restarts: 0,
    timer: undefined,
    /** 'off' | 'ssh' | 'cloudflared' | 'file' | 'remoteUrl' */
    source: String(cfg.remoteUrl ? 'remoteUrl' : cfg.tunnel || 'off'),
    /** 最近一次隧道输出（前 200 字），出问题时可以从 /api/local-status 看到 */
    lastOutput: '',
    error: '',
    fileTimer: undefined,
    /** ssh 远程转发端口（默认 80；冲突时换随机端口） */
    remotePort: 80,
    usedPorts: undefined,
  }

  /** 外部手动隧道（tools/tunnel.ps1）会把地址写进这个文件，插件直接读。 */
  const remoteFilePath = join(homedir(), '.dsh', 'dsh-watch-remote.txt')

  /** 去掉终端 ANSI 转义，方便把隧道输出塞进状态接口。 */
  function stripAnsi(text) {
    return String(text).replace(
      /[\u001b\u009b][[\]()#;?]*(?:[0-9]{1,4}(?:;[0-9]{0,4})*)?[0-9A-ORZcf-nqry=><]/g,
      ' ',
    )
  }

  /**
   * sshd 拒绝反向转发时的报错（旧会话没被服务端回收，端口仍被占用）。
   * 做法参考 @restregular/dsh-pocket 的 tunnel.js。
   */
  const SSH_FORWARD_CONFLICT = /remote port forwarding failed|address already in use|cannot listen to (?:remote )?port/iu

  /** 端口冲突时换一个随机的远程回环端口重试。 */
  function randomRemotePort() {
    const used = tunnelState.usedPorts || new Set()
    for (let attempt = 0; attempt < 16; attempt += 1) {
      const candidate = 20000 + Math.floor(Math.random() * 40000)
      if (!used.has(candidate)) {
        used.add(candidate)
        tunnelState.usedPorts = used
        return candidate
      }
    }
    return 20000 + (used.size % 40000)
  }

  function readRemoteFile() {
    try {
      const text = readFileSync(remoteFilePath, 'utf8').trim()
      const first = text.split(/\r?\n/)[0] || ''
      if (/^https?:\/\//i.test(first)) return first.trim()
    } catch {
      /* 文件不存在就算了 */
    }
    return ''
  }

  function watchRemoteFile() {
    if (cfg.remoteUrl) return
    const poll = () => {
      const url = readRemoteFile()
      if (url && url !== tunnelState.url) {
        tunnelState.source = 'file'
        setRemoteUrl(url, '外部隧道文件')
      }
    }
    poll()
    tunnelState.fileTimer = setInterval(poll, 10000)
    if (tunnelState.fileTimer.unref) tunnelState.fileTimer.unref()
  }

  /**
   * 从隧道程序的输出里认出「对外地址」。
   *
   * 参考 @restregular/dsh-pocket 的做法：只认已知隧道服务的域名白名单。
   * localhost.run 会先打印 https://admin.localhost.run 这类文档链接，
   * 用白名单（lhr.life / trycloudflare.com / loca.lt …）就天然把它们排除了。
   */
  const KNOWN_TUNNEL_URL =
    /https:\/\/[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?\.(?:trycloudflare\.com|loca\.lt|lhr\.life|localhost\.run|serveo\.net|ngrok\.io|ngrok-free\.app|ngrok-free\.dev|devtunnels\.ms)(?::\d+)?\/?[^\s"'<>]*/u

  /** 导出的纯函数，方便离线测试（喂真实 ssh 输出验证解析）。 */
  function parseTunnelUrl(text) {
    const value = String(text)
    const tagged = value.match(/tunneled with tls termination,?\s*(https:\/\/[^\s"']+)/i)
    if (tagged) {
      const candidate = tagged[1].replace(/[\u001b\u009b][[\]()#;?]*(?:[0-9]{1,4}(?:;[0-9]{0,4})*)?[0-9A-ORZcf-nqry=><]/g, '')
      if (KNOWN_TUNNEL_URL.test(candidate)) return candidate.replace(/[),.;]+$/, '')
    }
    const hit = value.match(KNOWN_TUNNEL_URL)
    return hit ? hit[0].replace(/[),.;]+$/, '') : ''
  }

  function extractRemoteUrl(text) {
    return parseTunnelUrl(text)
  }

  function setRemoteUrl(url, reason) {
    const clean = String(url || '').trim().replace(/\/+$/, '')
    if (clean === tunnelState.url) return
    tunnelState.url = clean
    if (clean) log(`外网地址：${clean}（${reason}）—— 手表离开局域网会自动切换到它`)
    else log('外网地址已清空')
  }

  /**
   * 找 cloudflared 可执行文件：
   * 1) 配置里的 cloudflaredPath；
   * 2) ~/.dsh/dsh-watch-bin/cloudflared(.exe)（从 npm 的 agentroam-cloudflared-win32-x64 复用）；
   * 3) PATH 里的 cloudflared。
   * 返回空字符串表示没装。
   */
  function findCloudflared() {
    const exe = process.platform === 'win32' ? 'cloudflared.exe' : 'cloudflared'
    const candidates = [
      cfg.cloudflaredPath && String(cfg.cloudflaredPath),
      join(homedir(), '.dsh', 'dsh-watch-bin', exe),
      join(homedir(), '.dsh', 'dsh-watch-bin', 'cloudflared.exe'),
    ].filter(Boolean)
    for (const candidate of candidates) {
      try {
        if (existsSync(candidate)) return candidate
      } catch {
        /* ignore */
      }
    }
    // 交给系统 PATH
    try {
      const probe = spawnSync(process.platform === 'win32' ? 'where.exe' : 'which', ['cloudflared'], {
        encoding: 'utf8',
        windowsHide: true,
      })
      const line = String(probe.stdout || '')
        .split(/\r?\n/)
        .map((item) => item.trim())
        .find((item) => item && !/\.ps1$/i.test(item))
      if (line) return line
    } catch {
      /* ignore */
    }
    return ''
  }

  async function startTunnel(port) {
    if (cfg.remoteUrl) {
      setRemoteUrl(cfg.remoteUrl, '配置里写死的 remoteUrl')
    }
    let mode = String(cfg.tunnel || 'off')
    if (mode === 'off' || mode === '') return

    // 启动前把二进制备好；auto 顺序：固定隧道 > quick tunnel > frp > ssh。
    if (mode === 'auto') {
      if (String(cfg.tunnelToken || '').trim() !== '') {
        mode = 'cloudflared-token'
      } else if (String(cfg.frpServer || '').trim() !== '') {
        mode = 'frp'
      } else {
        const bin = findCloudflared() || await ensureBinary('cloudflared', log)
        mode = bin ? 'cloudflared' : 'ssh'
      }
      log(`tunnel=auto → 使用 ${mode}`)
    }
    if (mode === 'cloudflared' && !findCloudflared()) {
      const bin = await ensureBinary('cloudflared', log)
      if (!bin) {
        warn('cloudflared 不可用，外网隧道保持关闭')
        return
      }
    }

    // 有些运行环境（沙箱）禁止创建子进程；失败只记日志，不影响插件本体。
    let child
    let remotePort = tunnelState.remotePort
    try {
      if (mode === 'ssh') {
        const target = `${cfg.tunnelUser || 'nokey'}@${cfg.tunnelHost || 'localhost.run'}`
        const sshArgs = [
          '-o', 'StrictHostKeyChecking=no',
          '-o', 'UserKnownHostsFile=' + (process.platform === 'win32' ? 'NUL' : '/dev/null'),
          '-o', 'ServerAliveInterval=30',
          '-o', 'ExitOnForwardFailure=yes',
          '-o', 'ConnectTimeout=10',
          '-o', 'BatchMode=yes',
          '-R', `${remotePort}:127.0.0.1:${port}`,
          '-p', String(Number(cfg.tunnelPort) || 22),
          target,
        ]
        log(`启动外网隧道：ssh ${sshArgs.join(' ')}`)
        child = spawn('ssh', sshArgs, { stdio: ['ignore', 'pipe', 'pipe'] })
        const warnTimer = setTimeout(() => {
          if (!tunnelState.url) {
            warn('外网隧道 25 秒内没有拿到地址：检查这台电脑能否 ssh 出网（22 端口），或改用 remoteUrl 手动填隧道地址')
          }
        }, 25000)
        if (warnTimer.unref) warnTimer.unref()
        child.once('exit', () => clearTimeout(warnTimer))
      } else if (mode === 'cloudflared-token') {
        const binary = findCloudflared() || await ensureBinary('cloudflared', log)
        if (!binary) {
          warn('固定隧道需要 cloudflared，但当前下载失败')
          return
        }
        log('启动 Cloudflare 固定隧道（token 模式）')
        child = spawn(binary, ['tunnel', '--no-autoupdate', 'run', '--token', String(cfg.tunnelToken).trim()], {
          stdio: ['ignore', 'pipe', 'pipe'],
        })
      } else if (mode === 'frp') {
        const binary = findFrpc()
        if (!binary) {
          warn('未找到 frpc：把它放到 ~/.dsh/dsh-watch-bin/ 或加入 PATH')
          return
        }
        const remotePort = Number(cfg.frpRemotePort) || (6000 + (port % 1000))
        const toml = [
          `serverAddr = ${JSON.stringify(String(cfg.frpServer))}`,
          `serverPort = ${Number(cfg.frpServerPort) || 7000}`,
          '',
          String(cfg.frpToken || '') === '' ? '' : `auth.token = ${JSON.stringify(String(cfg.frpToken))}`,
          '[[proxies]]',
          'name = "dsh-watch"',
          'type = "tcp"',
          'localIP = "127.0.0.1"',
          `localPort = ${port}`,
          `remotePort = ${remotePort}`,
          '',
        ].join('\n')
        const configPath = join(dshHome(), 'dsh-watch-frpc.toml')
        try {
          writeFileSync(configPath, toml, 'utf8')
        } catch (error) {
          warn('写入 frpc 配置失败:', error && error.message)
          return
        }
        log(`启动 frp 隧道：${binary} -c ${configPath}（远程端口 ${remotePort}）`)
        child = spawn(binary, ['-c', configPath], { stdio: ['ignore', 'pipe', 'pipe'] })
      } else if (mode === 'cloudflared') {
        const binary = findCloudflared() || String(cfg.cloudflaredPath || 'cloudflared')
        log(`启动外网隧道：${binary} tunnel --url http://127.0.0.1:${port}`)
        child = spawn(binary, ['tunnel', '--url', `http://127.0.0.1:${port}`, '--no-autoupdate'], {
          stdio: ['ignore', 'pipe', 'pipe'],
        })
      } else {
        warn(`未知的 tunnel 配置：${mode}（支持 off / ssh / cloudflared / cloudflared-token / frp）`)
        return
      }
    } catch (error) {
      tunnelState.error = String((error && error.message) || error)
      warn('外网隧道启动失败（当前运行环境可能禁止创建子进程）:', tunnelState.error)
      return
    }

    tunnelState.child = child
    tunnelState.error = ''
    let buffered = ''
    const onData = (chunk) => {
      const text = chunk.toString('utf8')
      buffered += text
      // 先解析再截断：ssh 一次可能吐出 8 KB（含二维码 ANSI），
      // 先截断会把含地址的那一段切掉——这是之前的坑。
      const url = extractRemoteUrl(buffered)
      if (url && !tunnelState.url) {
        setRemoteUrl(url, mode === 'ssh' ? 'ssh 反向隧道' : (mode === 'frp' ? 'frp 隧道' : 'cloudflared 快速隧道'))
      }
      // 远程转发端口被服务端占用（旧会话没回收）：换随机端口重连。
      if (mode === 'ssh' && !tunnelState.url && SSH_FORWARD_CONFLICT.test(buffered)) {
        buffered = ''
        tunnelState.restarts += 1
        const next = randomRemotePort()
        tunnelState.remotePort = next
        tunnelState.error = '远程转发端口被占用，换端口重试'
        warn(`ssh 远程转发端口 ${remotePort} 被占用，改用 ${next} 重试`)
        try {
          child.kill()
        } catch {
          /* ignore */
        }
        return
      }
      tunnelState.lastOutput = stripAnsi(buffered).replace(/\s+/g, ' ').slice(-300)
      if (buffered.length > 32000) buffered = buffered.slice(-16000)
    }
    child.stdout?.on('data', onData)
    child.stderr?.on('data', onData)
    child.on('error', (error) => {
      tunnelState.error = String((error && error.message) || error)
      warn('外网隧道启动失败（先装好工具或改配置）:', tunnelState.error)
    })
    child.on('exit', (code) => {
      tunnelState.child = undefined
      if (code === 0 || !cfg.tunnel) return
      tunnelState.error = `隧道进程退出（code ${code}）`
      tunnelState.restarts += 1
      const delay = Math.min(30000, 2500 * tunnelState.restarts)
      warn(`外网隧道断开（code ${code}），${Math.round(delay / 1000)}s 后重试`)
      tunnelState.timer = setTimeout(() => startTunnel(port), delay)
      if (tunnelState.timer.unref) tunnelState.timer.unref()
    })
  }

  function stopTunnel() {
    if (tunnelState.timer) clearTimeout(tunnelState.timer)
    if (tunnelState.fileTimer) clearInterval(tunnelState.fileTimer)
    const child = tunnelState.child
    tunnelState.child = undefined
    if (child) {
      try {
        child.kill()
      } catch {
        /* ignore */
      }
    }
  }

  // ---- 局域网广播发现 -----------------------------------------------------
  let discoverySocket
  function startDiscovery(port) {
    if (cfg.discovery === false) return
    const listenPort = Math.max(1, Number(cfg.discoveryPort) || 8766)
    try {
      discoverySocket = createSocket({ type: 'udp4', reuseAddr: true })
      discoverySocket.on('error', (error) => {
        warn(`发现广播不可用（UDP ${listenPort}）:`, error && error.message)
        try {
          discoverySocket.close()
        } catch {
          /* ignore */
        }
        discoverySocket = undefined
      })
      discoverySocket.on('message', (message, rinfo) => {
        const text = message.toString('utf8').trim()
        if (text !== 'DSHWATCH_DISCOVER' && !text.startsWith('{"t":"discover"')) return
        const payload = JSON.stringify({
          t: 'dshwatch',
          name: hostname(),
          version: VERSION,
          port,
          pairing: pairCodeUsable(),
          sessions: state.sessions.size,
          running: [...state.sessions.values()].some((item) => item.running),
        })
        try {
          discoverySocket.send(payload, rinfo.port, rinfo.address)
        } catch (error) {
          warn('发现应答发送失败:', error && error.message)
        }
      })
      discoverySocket.on('listening', () => {
        log(`局域网发现已开启（UDP ${listenPort}）`)
      })
      discoverySocket.bind(listenPort, '0.0.0.0')
    } catch (error) {
      warn('发现广播启动失败:', error && error.message)
      discoverySocket = undefined
    }
  }

  /** 取会话事件日志；不同版本的 Session 可能没有 events 或不是数组，别让监控插件炸掉。 */
  function eventsOf(session) {
    const list = session && session.events
    return Array.isArray(list) ? list : []
  }

  function sessionMeta(session) {
    if (!session || session.id === undefined) {
      // 返回一个临时对象，调用方照常读写但不会进状态表。
      return { id: '', title: '', cwd: '', live: false, running: false, lastAt: 0 }
    }
    let entry = state.sessions.get(session.id)
    if (!entry) {
      entry = {
        id: session.id,
        title: '',
        cwd: session.header?.cwd ?? '',
        live: true,
        running: false,
        lastAt: 0,
      }
      state.sessions.set(session.id, entry)
    }
    entry.live = true
    entry.cwd = session.header?.cwd ?? entry.cwd
    return entry
  }

  function titleOf(session) {
    try {
      const svc = ctx.get('sessionTitle')
      const snap = svc?.get?.(session)
      if (snap?.title) return snap.title
    } catch {
      /* 没有标题服务就用兜底 */
    }
    const titleEvents = eventsOf(session)
    for (let i = titleEvents.length - 1; i >= 0; i -= 1) {
      const ev = titleEvents[i]
      if (ev.type === 'user/message' && ev.data?.source?.kind === 'user') {
        const t = messageText(ev.data, 60)
        if (t) return t
      }
    }
    return session.id
  }

  // ---- 事件归一化 ---------------------------------------------------------
  function push(event) {
    state.seq += 1
    const item = { seq: state.seq, t: nowMs(), ...event }
    state.events.push(item)
    if (state.events.length > RING_MAX) state.events.splice(0, state.events.length - RING_MAX)
    broadcast(item)
    return item
  }

  function normalize(session, ev) {
    const sessionId = session.id
    if (ev.type === 'user/message') {
      if (ev.data?.source?.kind !== 'user') return undefined
      const text = messageBody(ev.data)
      const images = messageImages(ev.data)
      if (!text && images.length === 0) return undefined
      return { sessionId, kind: 'user', text, images }
    }
    if (ev.type === 'assistant/message') {
      const text = messageBody(ev.data?.message)
      const images = messageImages(ev.data?.message)
      if (!text && images.length === 0) return undefined
      return { sessionId, kind: 'assistant', text, images }
    }
    if (ev.type === 'tool/call') {
      const preview = summarizeToolArgs(ev.data?.name, ev.data?.arguments, 180)
      return {
        sessionId,
        kind: 'tool',
        name: String(ev.data?.name ?? 'tool'),
        tool: String(ev.data?.name ?? 'tool'),
        callId: String(ev.data?.callId ?? ''),
        text: preview,
        detail: argumentsBody(ev.data?.arguments),
        status: 'running',
      }
    }
    if (ev.type === 'tool/result') {
      const message = ev.data?.message
      const callId = String(message?.source?.callId ?? (message?.content?.[0]?.toolCallId ?? ''))
      const failed = ev.data?.error !== undefined
      const text = summarizeToolResult(message, 200)
      return {
        sessionId,
        kind: 'tool-result',
        callId,
        ok: !failed,
        text: failed ? `${ev.data?.error?.name ?? 'error'}: ${ev.data?.error?.code ?? ''}` : text,
        detail: messageBody(message) || (failed ? String(ev.data?.error?.message ?? text) : text),
      }
    }
    if (ev.type === 'turn/start') return { sessionId, kind: 'turn', running: true }
    if (ev.type === 'turn/end') {
      return { sessionId, kind: 'turn', running: false, reason: String(ev.data?.reason?.kind ?? '') }
    }
    if (ev.type === 'approval/asked') {
      return {
        sessionId,
        kind: 'approval-asked',
        approvalId: String(ev.data?.id ?? ''),
        tool: String(ev.data?.toolName ?? ''),
        reason: oneLine(ev.data?.reason ?? ''),
      }
    }
    if (ev.type === 'approval/decided') {
      return {
        sessionId,
        kind: 'approval-decided',
        approvalId: String(ev.data?.id ?? ''),
        outcome: String(ev.data?.outcome ?? ''),
      }
    }
    return undefined
  }

  function onSessionEvent(session, ev) {
    const entry = sessionMeta(session)
    entry.lastAt = nowMs()
    if (!state.selectedId) state.selectedId = session.id

    // 会话标题是后生成的（首轮提示后才有），单独一条标题事件推给手表。
    if (ev.type === 'session/title') {
      const title = String(ev.data?.title ?? '').trim()
      if (title && title !== entry.title) {
        entry.title = title
        if (session.id === state.selectedId) push({ sessionId: session.id, kind: 'title', text: title })
      }
      return
    }

    const norm = normalize(session, ev)
    if (!norm) return
    // 只有被选中的会话把细节推给手表；其它会话只维护状态，避免噪音。
    if (session.id !== state.selectedId) return
    push(norm)
  }

  function replaySelected(limit = 30) {
    const id = state.selectedId
    if (!id) return
    const agent = ctx.get('agents')?.get(id)
    const session = agent?.session ?? ctx.get('sessions')?.get(id)
    if (!session) return
    const slice = eventsOf(session).slice(-limit)
    for (const ev of slice) {
      const norm = normalize(session, ev)
      if (norm) {
        state.seq += 1
        state.events.push({ seq: state.seq, t: nowMs(), replay: true, ...norm })
      }
    }
    if (state.events.length > RING_MAX) state.events.splice(0, state.events.length - RING_MAX)
  }

  // ---- SSE ----------------------------------------------------------------
  function broadcast(item) {
    if (state.subscribers.size === 0) return
    const frame =
      `id: ${item.seq}\n` +
      `event: ev\n` +
      `data: ${JSON.stringify(publicEvent(item))}\n\n`
    for (const sub of [...state.subscribers]) {
      if (sub.sessionId && sub.sessionId !== item.sessionId && item.sessionId) continue
      try {
        sub.res.write(frame)
      } catch {
        state.subscribers.delete(sub)
      }
    }
  }

  function broadcastRaw(eventName, payload, id) {
    const frame =
      (id === undefined ? '' : `id: ${id}\n`) +
      `event: ${eventName}\n` +
      `data: ${JSON.stringify(payload)}\n\n`
    for (const sub of [...state.subscribers]) {
      try {
        sub.res.write(frame)
      } catch {
        state.subscribers.delete(sub)
      }
    }
  }

  // ---- 审批 ---------------------------------------------------------------
  /**
   * 找出本次 ask 对应的 `approval/asked` 审计 id（用于日志/前端关联）。
   *
   * 与 dsh-host-apiproxy 的思路一致：从日志尾部找「最新、未 decided、未被其它 pending 认领」的
   * asked 事件。放宽了两处，避免版本差异导致审批被静默地交给不存在的 Web UI：
   *   1) 优先按 callId 精确配对，配不上再接受「任意 callId」的未决 asked；
   *   2) 仍找不到就返回 undefined，由调用方用临时 id 继续处理（审计 id 只影响日志可读性）。
   */
  function correlateApprovalId(req) {
    const events = eventsOf(req.agent?.session)
    const claimed = new Set()
    for (const entry of state.pending.values()) claimed.add(entry.approvalId)
    const decided = new Set()
    let looseCandidate
    for (let i = events.length - 1; i >= 0; i -= 1) {
      const ev = events[i]
      if (ev.type === 'approval/decided') {
        decided.add(ev.data?.id)
        continue
      }
      if (ev.type !== 'approval/asked') continue
      const id = ev.data?.id
      if (id === undefined || decided.has(id) || claimed.has(id)) continue
      if ((req.callId ?? null) === (ev.data?.callId ?? null)) return String(id)
      if (looseCandidate === undefined) looseCandidate = String(id)
    }
    if (looseCandidate !== undefined) {
      warn('approval/asked 的 callId 与请求不一致，按时间最近的未决审批处理')
      return looseCandidate
    }
    return undefined
  }

  /**
   * 审批卡片上的「要执行什么」摘要。
   * 优先按 callId 精确找 tool/call；沙箱升权这类 ask 可能不带 callId，
   * 就退回「该工具最近一次还没有 results 的调用」，手表上照样能看到命令。
   */
  function approvalPreview(session, callId, toolName) {
    if (!session) return ''
    const list = eventsOf(session)
    if (callId) {
      for (let i = list.length - 1; i >= 0; i -= 1) {
        const ev = list[i]
        if (ev.type === 'tool/call' && String(ev.data?.callId) === String(callId)) {
          return `${ev.data?.name}: ${summarizeToolArgs(ev.data?.name, ev.data?.arguments, 180)}`
        }
      }
    }
    const answered = new Set()
    for (const ev of list) {
      if (ev.type !== 'tool/result') continue
      const id = ev.data?.message?.source?.callId ?? ev.data?.message?.content?.[0]?.toolCallId
      if (id !== undefined) answered.add(String(id))
    }
    for (let i = list.length - 1; i >= 0; i -= 1) {
      const ev = list[i]
      if (ev.type !== 'tool/call') continue
      if (toolName && ev.data?.name !== toolName) continue
      if (answered.has(String(ev.data?.callId))) continue
      return `${ev.data?.name}: ${summarizeToolArgs(ev.data?.name, ev.data?.arguments, 180)}`
    }
    return ''
  }

  function settleApproval(id, outcome) {
    const entry = state.pending.get(id)
    if (!entry) return false
    state.pending.delete(id)
    if (entry.timer) clearTimeout(entry.timer)
    try {
      entry.settle(outcome)
    } catch (error) {
      warn('审批结算失败', error && error.message)
    }
    broadcastRaw('approval-resolved', { id, outcome, tool: entry.tool })
    push({ sessionId: entry.sessionId, kind: 'approval-done', approvalId: id, outcome })
    log(`审批 ${id} → ${outcome}`)
    return true
  }

  ctx.on(
    'approval/request',
    (req, next) => {
      // 既不看、也不抢：交给下一条应答者（Web UI）。
      if (String(cfg.approvalMode) !== 'watch') return next()

      try {
        const agent = req.agent
        const session = agent?.session
        if (!session) return next()

        // 关联不到审计 id 也没关系：这只是日志可读性，不影响「谁来决定」。
        const correlated = correlateApprovalId(req)
        const approvalId = correlated !== undefined ? correlated : `local-${randomUUID()}`
        const preview = approvalPreview(session, req.callId, String(req.toolName ?? ''))
        const tool = String(req.toolName ?? '')
        const reason = oneLine(req.reason ?? '')
        const timeoutMs = Math.max(5000, Number(cfg.approvalTimeoutMs) || 60000)

        // 没有手表连着 → 不拦，Web UI 照常弹窗。
        if (state.subscribers.size === 0) {
          push({ sessionId: session.id, kind: 'approval-missed', tool, reason, text: '手表未连接，转交 Web UI' })
          return next()
        }

        log(`审批请求 ${tool}（${approvalId}${correlated === undefined ? '，审计 id 未匹配' : ''}）转发给手表`)
        push({ sessionId: session.id, kind: 'approval', approvalId, tool, reason, text: preview, timeoutMs })
        broadcastRaw('approval', {
          id: approvalId,
          tool,
          reason,
          preview,
          expiresAt: nowMs() + timeoutMs,
          timeoutMs,
        })

        return new Promise((resolve) => {
          const entry = {
            approvalId,
            sessionId: session.id,
            tool,
            reason,
            preview,
            expiresAt: nowMs() + timeoutMs,
            timer: undefined,
            /** 手表给出结论。 */
            settle: (outcome) => {
              if (outcome === 'allow') resolve('allowed-once')
              else if (outcome === 'deny') resolve('rejected')
              else if (outcome === 'cancelled') resolve('cancelled')
              else {
                // 超时：交还下一条应答者（通常是 Web UI），由它决定。
                Promise.resolve(next()).then(resolve, () => resolve('unavailable'))
              }
            },
          }
          entry.timer = setTimeout(() => {
            if (!state.pending.has(approvalId)) return
            log(`审批 ${approvalId} 超时，交还 Web UI`)
            settleApproval(approvalId, 'timeout')
          }, timeoutMs)
          state.pending.set(approvalId, entry)

          // 回合被取消/中止 → 立刻撤卡。
          req.signal?.addEventListener(
            'abort',
            () => {
              if (!state.pending.has(approvalId)) return
              settleApproval(approvalId, 'cancelled')
            },
            { once: true },
          )
        })
      } catch (error) {
        warn('审批处理失败，交还下一条应答者:', error && error.message)
        return next()
      }
    },
    { prepend: true },
  )

  // ---- 会话 / Agent -------------------------------------------------------
  function defaultSelection() {
    try {
      const sel = ctx.get('agentDefaultModel')?.currentSelection?.()
      if (sel?.provider && sel?.model) return sel
    } catch {
      /* 没有默认模型服务 */
    }
    return undefined
  }

  function selectionFor(agent) {
    return {
      get current() {
        // setup 的第二参数才是 Agent。agentCtx 是严格 DI 上下文，
        // 访问未声明的 agentCtx.agent 会在首轮组装提示词时直接抛错。
        const logged = agent?.session?.requestHeader?.()?.config
        if (logged?.provider && logged?.model) {
          return {
            provider: logged.provider,
            model: logged.model,
            ...(logged.reasoningEffort === undefined ? {} : { reasoningEffort: logged.reasoningEffort }),
          }
        }
        return defaultSelection()
      },
      assembled: undefined,
    }
  }

  function configureSelection(agentCtx, agent, control) {
    // 网页和手表共用同一份会话模型选区，不能再叠一层路由覆盖。
    // control 显式传入：单测会单独 eval 这段代码，不能依赖外层闭包。
    if (!control || !control.mount(agent)) installSelection(agentCtx, selectionFor(agent))
  }

  async function composeSetup(control) {
    const presets = (() => {
      try {
        return ctx.get('agentPresets')
      } catch {
        return undefined
      }
    })()
    if (!presets) {
      return { setup: (agentCtx, agent) => configureSelection(agentCtx, agent, control) }
    }
    let resolved
    try {
      resolved = await presets.resolve(undefined)
    } catch (error) {
      warn('agentPresets 解析失败，按无预设组合处理', error && error.message)
      return { setup: (agentCtx, agent) => configureSelection(agentCtx, agent, control) }
    }
    return {
      presetId: resolved.id,
      setup: async (agentCtx, agent) => {
        configureSelection(agentCtx, agent, control)
        await presets.mount(agentCtx, resolved.id)
      },
    }
  }

  function agentOptionsFromPreset() {
    const sel = defaultSelection()
    return sel ? { provider: sel.provider, model: sel.model } : undefined
  }

  async function createAgent(cwd) {
    const agents = ctx.get('agents')
    if (!agents) throw new Error('agents 服务不可用')
    const composition = await composeSetup(modelControl)
    const sessionId = `session-${randomUUID()}`
    const handle = await agents.create({
      sessionId,
      meta: {
        cwd,
        ...(composition.presetId === undefined ? {} : { agentPreset: composition.presetId }),
      },
      ...(agentOptionsFromPreset() === undefined ? {} : { agentOptions: agentOptionsFromPreset() }),
      setup: composition.setup,
    })
    state.handles.set(sessionId, handle)
    sessionMeta(handle.agent.session)
    log('新建会话', sessionId, '于', cwd)
    return handle.agent
  }

  async function resumeAgent(sessionId) {
    const agents = ctx.get('agents')
    if (!agents) throw new Error('agents 服务不可用')
    const composition = await composeSetup(modelControl)
    const handle = await agents.resume({
      resumeSessionId: sessionId,
      ...(agentOptionsFromPreset() === undefined ? {} : { agentOptions: agentOptionsFromPreset() }),
      setup: composition.setup,
    })
    state.handles.set(sessionId, handle)
    sessionMeta(handle.agent.session)
    log('恢复会话', sessionId)
    return handle.agent
  }

  async function persistedSessions(limit = 20) {
    const persistence = (() => {
      try {
        return ctx.get('sessionPersistence')
      } catch {
        return undefined
      }
    })()
    if (!persistence) return []
    let headers = []
    try {
      headers = await persistence.list()
    } catch (error) {
      warn('列出持久化会话失败', error && error.message)
      return []
    }
    headers.sort((a, b) => Number(b.createdAt ?? 0) - Number(a.createdAt ?? 0))
    return headers.slice(0, limit).map((header) => ({
      id: header.id,
      cwd: header.cwd ?? '',
      lastAt: Number(header.createdAt ?? 0),
      live: state.sessions.get(header.id)?.live === true,
      running: state.sessions.get(header.id)?.running === true,
      title: state.sessions.get(header.id)?.title || '',
    }))
  }

  async function listSessions(includePersisted) {
    const agents = ctx.get('agents')
    const live = []
    for (const agent of agents?.list?.() ?? []) {
      const entry = sessionMeta(agent.session)
      if (!entry.title) entry.title = titleOf(agent.session)
      live.push({
        id: agent.id,
        title: entry.title,
        cwd: entry.cwd,
        running: agent.status === 'running',
        live: true,
        lastAt: entry.lastAt,
      })
      entry.running = agent.status === 'running'
    }
    if (!includePersisted) return live
    const persisted = await persistedSessions(20)
    const seen = new Set(live.map((item) => item.id))
    return [...live, ...persisted.filter((item) => !seen.has(item.id))]
  }

  async function ensureAgent(sessionId) {
    const agents = ctx.get('agents')
    if (!agents) throw new Error('agents 服务不可用')
    const wanted = sessionId || state.selectedId
    if (wanted) {
      const live = agents.get(wanted)
      if (live) return live
      const attached = ctx.get('sessions')?.get(wanted)
      if (attached && state.handles.has(wanted)) return agents.get(wanted) ?? (await resumeAgent(wanted))
      const headers = await persistedSessions(50)
      if (headers.some((header) => header.id === wanted)) return resumeAgent(wanted)
      warn('未知会话，改为当前/新建', wanted)
    }
    const recent = agents.roots?.() ?? agents.list?.() ?? []
    if (recent.length > 0) {
      let best = recent[0]
      let bestAt = state.sessions.get(best.id)?.lastAt ?? 0
      for (const agent of recent) {
        const at = state.sessions.get(agent.id)?.lastAt ?? 0
        if (at >= bestAt) {
          best = agent
          bestAt = at
        }
      }
      state.selectedId = best.id
      return best
    }
    const headers = await persistedSessions(1)
    if (headers.length > 0) return resumeAgent(headers[0].id)
    return createAgent(String(cfg.defaultCwd || process.cwd()))
  }

  function makeUserMessage(text) {
    return {
      id: randomUUID(),
      role: 'user',
      content: [{ type: 'text', text: String(text) }],
      source: { kind: 'user' },
    }
  }

  async function sendPrompt({ text, sessionId, mode }) {
    const clean = String(text ?? '').trim()
    if (!clean) throw new Error('指令为空')
    const agent = await ensureAgent(sessionId)
    const message = makeUserMessage(clean)
    const running = agent.status === 'running'
    const chosen = mode === 'steer' || mode === 'followup' ? mode : running ? 'steer' : 'followup'
    if (chosen === 'steer') agent.steer(message)
    else agent.followup(message)
    state.selectedId = agent.id
    push({ sessionId: agent.id, kind: 'user', text: clean, fromWatch: true })
    log(`收到手表指令（${chosen}）`, clip(clean, 80))
    return { sessionId: agent.id, mode: chosen }
  }

  // ---- 生命周期订阅 -------------------------------------------------------
  // 监控插件绝不能把宿主搞挂：监听器里的异常就地吞掉 + 记一行日志。
  function guard(label, handler) {
    return (...args) => {
      try {
        const result = handler(...args)
        if (result && typeof result.then === 'function') {
          result.catch((error) => warn(`${label} 失败:`, error && error.message))
        }
        return result
      } catch (error) {
        warn(`${label} 失败:`, error && error.message)
        return undefined
      }
    }
  }

  ctx.on(
    'agent/created',
    guard('agent/created', ({ agent }) => {
      if (!agent || !agent.session) return
      const entry = sessionMeta(agent.session)
      if (!entry.title) entry.title = titleOf(agent.session)
      if (!state.selectedId) {
        state.selectedId = agent.id
        replaySelected()
      }
      push({ sessionId: agent.id, kind: 'info', text: `会话已打开：${entry.title}` })
    }),
  )

  ctx.on(
    'agent/status',
    guard('agent/status', ({ agent, status }) => {
      if (!agent || !agent.session) return
      const entry = sessionMeta(agent.session)
      entry.running = status === 'running'
      if (agent.id === state.selectedId) push({ sessionId: agent.id, kind: 'status', running: status === 'running' })
    }),
  )

  ctx.on(
    'agent/disposed',
    guard('agent/disposed', ({ agent }) => {
      if (!agent) return
      const entry = state.sessions.get(agent.id)
      if (entry) {
        entry.live = false
        entry.running = false
      }
      state.handles.delete(agent.id)
      push({ sessionId: agent.id, kind: 'info', text: '会话已关闭' })
    }),
  )

  ctx.on('session/event', guard('session/event', onSessionEvent))

  // 启动时把已经在跑的会话收进状态表。
  for (const agent of ctx.get('agents')?.list?.() ?? []) {
    const entry = sessionMeta(agent.session)
    entry.title = titleOf(agent.session)
    entry.running = agent.status === 'running'
    entry.lastAt = nowMs()
    if (!state.selectedId) state.selectedId = agent.id
  }
  if (state.selectedId) replaySelected()

  // ---- HTTP ---------------------------------------------------------------
  function sendJson(res, status, value) {
    const body = JSON.stringify(value)
    res.writeHead(status, {
      'Content-Type': MIME.json,
      'Cache-Control': 'no-store',
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Headers': `content-type, ${TOKEN_HEADER}`,
    })
    res.end(body)
  }

  function readBody(req) {
    return new Promise((resolve, reject) => {
      // 必须按字节收集再整体解码：逐块 toString() 会把跨块的多字节中文劈成乱码。
      const chunks = []
      let total = 0
      req.on('data', (chunk) => {
        chunks.push(chunk)
        total += chunk.length
        if (total > 256 * 1024) {
          reject(new Error('请求体过大'))
          req.destroy()
        }
      })
      req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
      req.on('error', reject)
    })
  }

  function tokenFrom(req, url) {
    const header = req.headers[TOKEN_HEADER]
    if (typeof header === 'string' && header !== '') return header
    const auth = req.headers.authorization
    if (typeof auth === 'string' && auth.startsWith('Bearer ')) return auth.slice(7)
    return url.searchParams.get('token') ?? ''
  }

  /** 把局域网地址排成「手表最可能连得上的顺序」：与对方同网段的排前面，VPN/虚拟网卡排后面。 */
  function orderedAddresses(clientIp) {
    const virtualHint = /vpn|radmin|vmware|virtual|vethernet|tap|tun|zerotier|tailscale|wg/i
    const items = lanAddresses().map((item) => ({ ...item, port: boundPort }))
    const subnet = (ip) => ip.split('.').slice(0, 3).join('.')
    const clientSubnet = clientIp && /^\d+\.\d+\.\d+\.\d+$/.test(clientIp) ? subnet(clientIp) : ''
    return items.sort((a, b) => {
      const score = (item) => {
        let value = 0
        if (clientSubnet && subnet(item.address) === clientSubnet) value += 100
        if (virtualHint.test(item.name || '')) value -= 50
        if (item.address.startsWith('169.254.')) value -= 100
        return value
      }
      return score(b) - score(a)
    })
  }

  function snapshot() {
    const agents = ctx.get('agents')
    let selected = null
    const id = state.selectedId
    if (id) {
      const entry = state.sessions.get(id)
      const agent = agents?.get?.(id)
      // 标题可能晚于创建才生成（sessionTitle 服务），每次快照都重新取一次。
      let title = entry?.title ?? ''
      if (agent?.session) {
        const live = titleOf(agent.session)
        if (live) {
          title = live
          if (entry) entry.title = live
        }
      }
      selected = {
        id,
        title: title || id,
        cwd: entry?.cwd ?? '',
        running: agent ? agent.status === 'running' : entry?.running === true,
        live: agent !== undefined,
      }
    }
    return {
      ok: true,
      name: name,
      version: VERSION,
      now: nowMs(),
      /** 外网地址（配了隧道才有）：手表离开局域网时自动切到它。 */
      remote: tunnelState.url,
      lan: lanAddresses().map((item) => `${item.address}:${boundPort}`),
      selected,
      selection: modelControl.current(id ? agents?.get?.(id) : undefined),
      sessions: [...state.sessions.values()].map((item) => ({ ...item })),
      pending: [...state.pending.values()].map((item) => ({
        id: item.approvalId,
        tool: item.tool,
        reason: item.reason,
        preview: item.preview,
        expiresAt: item.expiresAt,
      })),
      lastSeq: state.seq,
      events: state.events.slice(-40).map(publicEvent),
    }
  }

  async function handleApi(req, res, url) {
    const path = url.pathname
    if (path === '/api/ping') {
      return sendJson(res, 200, { ok: true, name, version: VERSION })
    }

    // 配对：手表拿 6 位码换长期 token（不需要预置令牌，但要限速）。
    if (req.method === 'POST' && path === '/api/pair') {
      const remote = req.socket?.remoteAddress ?? 'unknown'
      const bucket = pairState.attempts.get(remote) ?? { count: 0, resetAt: nowMs() + 60000 }
      if (nowMs() > bucket.resetAt) {
        bucket.count = 0
        bucket.resetAt = nowMs() + 60000
      }
      bucket.count += 1
      pairState.attempts.set(remote, bucket)
      if (bucket.count > 8) {
        return sendJson(res, 429, { ok: false, error: '尝试太频繁，等一分钟再试' })
      }
      let body = {}
      try {
        const raw = await readBody(req)
        body = raw ? JSON.parse(raw) : {}
      } catch {
        return sendJson(res, 400, { ok: false, error: '无效请求体' })
      }
      const code = String(body.code ?? '').trim()
      if (!pairCodeUsable()) {
        return sendJson(res, 410, { ok: false, error: '配对码已过期，电脑上打开 /pair 看新的' })
      }
      if (code !== pairState.code) {
        return sendJson(res, 401, { ok: false, error: '配对码不对' })
      }
      // 一次性：换成功就立刻换新码，旧 token 继续有效。
      const issued = settings.token
      rotatePairCode('paired')
      log(`配对成功（${remote}），已下发令牌`)
      return sendJson(res, 200, {
        ok: true,
        token: issued,
        host: hostname(),
        port: boundPort,
        // 手表拿到后就有一组候选地址：某个连不上会自动换下一个（VPN 网段排后面）。
        addresses: orderedAddresses(remote).map((item) => `${item.address}:${item.port}`),
      })
    }

    // 本机浏览器（桌面端设置页）用的状态接口：不含令牌、不含配对码，只给「插件活着吗 / 在哪」。
    if (req.method === 'GET' && path === '/api/local-status') {
      if (!isLoopback(req)) return sendJson(res, 403, { ok: false, error: 'loopback only' })
      return sendJson(res, 200, {
        ok: true,
        name,
        version: VERSION,
        host: hostname(),
        port: boundPort,
        remote: tunnelState.url,
        // 隧道诊断：出问题时看这几个字段就知道卡在哪一步
        tunnel: {
          configured: String(cfg.tunnel || 'off'),
          source: tunnelState.source,
          running: Boolean(tunnelState.child),
          restarts: tunnelState.restarts,
          remoteFile: remoteFilePath,
          error: tunnelState.error,
          lastOutput: tunnelState.lastOutput,
        },
        addresses: orderedAddresses('127.0.0.1').map((item) => `${item.address}:${item.port}`),
        devices: state.subscribers.size,
        sessions: state.sessions.size,
        running: [...state.sessions.values()].some((item) => item.running),
        approvalMode: String(cfg.approvalMode),
      })
    }

    // 已配对设备查当前配对码（给内置网页客户端显示，方便再配一台）
    if (req.method === 'GET' && path === '/api/pairing') {
      const token = tokenFrom(req, url)
      if (token !== settings.token) return sendJson(res, 401, { ok: false, error: 'unauthorized' })
      return sendJson(res, 200, {
        ok: true,
        code: currentPairCode('view'),
        expiresAt: pairState.expiresAt,
        addresses: lanAddresses(),
        host: hostname(),
        port: boundPort,
      })
    }

    const token = tokenFrom(req, url)
    if (token !== settings.token) {
      return sendJson(res, 401, { ok: false, error: 'unauthorized' })
    }

    if (req.method === 'GET' && path === '/api/state') {
      return sendJson(res, 200, snapshot())
    }

    if (req.method === 'GET' && path === '/api/models') {
      try {
        const sessionId = url.searchParams.get('sessionId') || state.selectedId
        const agent = sessionId ? ctx.get('agents')?.get?.(sessionId) : undefined
        const catalog = await modelControl.catalog(agent)
        return sendJson(res, 200, { ok: true, sessionId, ...catalog })
      } catch (error) {
        return sendJson(res, 503, { ok: false, error: String(error.message || error) })
      }
    }

    if (req.method === 'GET' && path === '/api/event-detail') {
      const seq = Number(url.searchParams.get('seq'))
      const timestamp = Number(url.searchParams.get('t'))
      const sessionId = url.searchParams.get('sessionId')
      const event = state.events.find(item => item.seq === seq && item.sessionId === sessionId && item.t === timestamp)
      if (!event) return sendJson(res, 404, { ok: false, error: '该运行记录已不在缓存中，请重新打开会话。' })
      return sendJson(res, 200, { ok: true, sessionId, seq, text: event.detail ?? event.text ?? '' })
    }

    if (req.method === 'GET' && path === '/api/image') {
      const seq = Number(url.searchParams.get('seq'))
      const sessionId = url.searchParams.get('sessionId') ?? ''
      const index = Number(url.searchParams.get('i') ?? 0)
      const event = state.events.find(item => item.seq === seq && item.sessionId === sessionId)
      const ref = Array.isArray(event?.images) ? event.images[index] : undefined
      if (!ref) return sendJson(res, 404, { ok: false, error: '图片不在缓存里' })
      let file = ''
      try {
        file = ctx.get('attachment')?.imageHostPath?.(ref) ?? ''
      } catch {
        file = ''
      }
      if (!file || !existsSync(file)) return sendJson(res, 404, { ok: false, error: '原图已不可用' })
      let data
      try {
        data = readFileSync(file)
      } catch {
        return sendJson(res, 500, { ok: false, error: '读取失败' })
      }
      res.writeHead(200, {
        'Content-Type': ref.mediaType || 'application/octet-stream',
        'Content-Length': data.length,
        'Cache-Control': 'private, max-age=600',
      })
      res.end(data)
      return undefined
    }

    if (req.method === 'GET' && path === '/api/sessions') {
      const all = url.searchParams.get('all') === '1'
      const sessions = await listSessions(all)
      return sendJson(res, 200, { ok: true, selectedId: state.selectedId, sessions })
    }

    if (req.method === 'GET' && path === '/api/events') {
      const since = Number(url.searchParams.get('since') ?? -1)
      res.writeHead(200, {
        'Content-Type': 'text/event-stream; charset=utf-8',
        'Cache-Control': 'no-store, no-transform',
        Connection: 'keep-alive',
        'X-Accel-Buffering': 'no',
        'Access-Control-Allow-Origin': '*',
      })
      res.write(': dsh-watch stream\n\n')
      res.write(`event: hello\ndata: ${JSON.stringify({ version: VERSION, lastSeq: state.seq, selectedId: state.selectedId })}\n\n`)
      const replayFrom = Number.isFinite(since) && since >= 0 ? since : Math.max(0, state.seq - 25)
      for (const item of state.events) {
        if (item.seq > replayFrom) {
          res.write(`id: ${item.seq}\nevent: ev\ndata: ${JSON.stringify(publicEvent(item))}\n\n`)
        }
      }
      for (const pending of state.pending.values()) {
        res.write(
          `event: approval\ndata: ${JSON.stringify({
            id: pending.approvalId,
            tool: pending.tool,
            reason: pending.reason,
            preview: pending.preview,
            expiresAt: pending.expiresAt,
            timeoutMs: Math.max(0, pending.expiresAt - nowMs()),
          })}\n\n`,
        )
      }
      const sub = { res, sessionId: null }
      state.subscribers.add(sub)
      // 心跳必须够大：Cloudflare / nginx 这类反代会把小 chunk 攒在缓冲里，
      // 只发 ': ping\n\n' 时对端要等很久才收到，客户端就会读超时重连。
      const PAD = ': ping ' + 'x'.repeat(1800) + '\n\n'
      let alive = true
      const cleanup = () => {
        if (!alive) return
        alive = false
        clearInterval(heartbeat)
        state.subscribers.delete(sub)
        log('SSE 断开，剩余订阅者', state.subscribers.size)
      }
      const heartbeat = setInterval(() => {
        try {
          res.write(PAD)
        } catch {
          cleanup()
        }
      }, 15000)
      req.on('close', cleanup)
      res.on('close', cleanup)
      res.on('error', cleanup)
      log('SSE 已连接，订阅者', state.subscribers.size)
      return undefined
    }

    if (req.method === 'POST') {
      let body = {}
      try {
        const raw = await readBody(req)
        body = raw ? JSON.parse(raw) : {}
      } catch (error) {
        return sendJson(res, 400, { ok: false, error: `无效请求体: ${error.message}` })
      }

      if (path === '/api/model') {
        const sessionId = typeof body.sessionId === 'string' ? body.sessionId : ''
        if (!sessionId) return sendJson(res, 400, { ok: false, error: '请选择当前会话后再切换模型。' })
        try {
          const agent = ctx.get('agents')?.get?.(sessionId) ?? await resumeAgent(sessionId)
          const result = await modelControl.select(agent, { provider: body.provider, model: body.model })
          return sendJson(res, 200, { ok: true, sessionId, ...result })
        } catch (error) {
          return sendJson(res, error.code === 'model-control/invalid' ? 400 : 409,
            { ok: false, error: String(error.message || error) })
        }
      }

      if (path === '/api/prompt') {
        try {
          const result = await sendPrompt({
            text: body.text,
            sessionId: body.sessionId,
            mode: body.mode,
          })
          return sendJson(res, 200, { ok: true, ...result })
        } catch (error) {
          return sendJson(res, 500, { ok: false, error: String(error.message || error) })
        }
      }

      if (path === '/api/approval') {
        const id = String(body.id ?? '')
        const decision = String(body.decision ?? '')
        if (decision !== 'allow' && decision !== 'deny') {
          return sendJson(res, 400, { ok: false, error: 'decision 必须是 allow / deny' })
        }
        const ok = settleApproval(id, decision)
        return sendJson(res, ok ? 200 : 404, { ok, id, decision })
      }

      if (path === '/api/select') {
        const sessionId = String(body.sessionId ?? '')
        if (!sessionId) return sendJson(res, 400, { ok: false, error: '缺少 sessionId' })
        state.selectedId = sessionId
        state.events = []
        state.seq = 0
        const live = ctx.get('agents')?.get?.(sessionId)
        if (live) {
          const entry = sessionMeta(live.session)
          entry.title = entry.title || titleOf(live.session)
          replaySelected()
        } else {
          try {
            const agent = await resumeAgent(sessionId)
            const entry = sessionMeta(agent.session)
            entry.title = entry.title || titleOf(agent.session)
            replaySelected()
          } catch (error) {
            return sendJson(res, 404, { ok: false, error: `会话不可用: ${error.message}` })
          }
        }
        broadcastRaw('selected', { sessionId })
        return sendJson(res, 200, { ok: true, sessionId })
      }

      if (path === '/api/new') {
        try {
          const agent = await createAgent(String(body.cwd || cfg.defaultCwd || process.cwd()))
          state.selectedId = agent.id
          state.events = []
          state.seq = 0
          const entry = sessionMeta(agent.session)
          entry.title = entry.title || titleOf(agent.session)
          broadcastRaw('selected', { sessionId: agent.id })
          return sendJson(res, 200, { ok: true, sessionId: agent.id, title: entry.title })
        } catch (error) {
          return sendJson(res, 500, { ok: false, error: String(error.message || error) })
        }
      }

      if (path === '/api/cancel') {
        try {
          const agent = await ensureAgent(body.sessionId)
          agent.cancel({ kind: 'user' })
          push({ sessionId: agent.id, kind: 'info', text: '已请求停止当前回合（手表）' })
          return sendJson(res, 200, { ok: true, sessionId: agent.id })
        } catch (error) {
          return sendJson(res, 500, { ok: false, error: String(error.message || error) })
        }
      }
    }

    return sendJson(res, 404, { ok: false, error: 'not found' })
  }

  const server = createServer((req, res) => {
    const url = new URL(req.url || '/', 'http://localhost')
    if (req.method === 'OPTIONS') {
      res.writeHead(204, {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': `content-type, ${TOKEN_HEADER}`,
        'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
      })
      res.end()
      return
    }
    if (url.pathname === '/' || url.pathname === '/index.html') {
      res.writeHead(200, { 'Content-Type': MIME.html, 'Cache-Control': 'no-store' })
      res.end(HTML_CLIENT)
      return
    }
    // 配对页只在电脑本机可见（局域网请求一律 403），配对码不会泄露给同网段。
    if (url.pathname === '/pair') {
      if (!isLoopback(req)) {
        res.writeHead(403, { 'Content-Type': MIME.plain })
        res.end('这个页面只能在电脑本机打开：http://127.0.0.1:8765/pair\n')
        return
      }
      res.writeHead(200, { 'Content-Type': MIME.html, 'Cache-Control': 'no-store' })
      res.end(pairPageHtml())
      return
    }
    Promise.resolve(handleApi(req, res, url)).catch((error) => {
      warn('请求处理失败', error && error.message)
      if (!res.headersSent) sendJson(res, 500, { ok: false, error: String(error?.message ?? error) })
      else res.end()
    })
  })

  let boundPort = 0
  const wantedPort = Math.max(1, Number(cfg.port) || 8765)
  const bindHost = String(cfg.bind || '0.0.0.0')
  let attempt = 0
  server.on('error', (error) => {
    if (error && error.code === 'EADDRINUSE' && attempt < 10) {
      attempt += 1
      warn(`端口 ${wantedPort + attempt - 1} 被占用，尝试 ${wantedPort + attempt}`)
      setTimeout(() => server.listen(wantedPort + attempt, bindHost), 150)
      return
    }
    warn('HTTP 服务失败', error && error.message)
  })
  server.on('listening', () => {
    boundPort = server.address()?.port ?? wantedPort
    log(`监听 http://${bindHost}:${boundPort} （令牌 ${settings.token}）`)
    log(`手表配对：电脑上打开 http://127.0.0.1:${boundPort}/pair 查看 6 位配对码`)
    startDiscovery(boundPort)
    startTunnel(boundPort).catch((error) => warn('外网隧道启动异常:', error && error.message))
    watchRemoteFile()
  })
  server.listen(wantedPort, bindHost)

  // 启动就生成一个配对码，用户随时可以去 /pair 看。
  rotatePairCode('startup')

  ctx.effect(() => () => {
    log('插件卸载，关闭 HTTP 与订阅')
    for (const sub of state.subscribers) {
      try {
        sub.res.end()
      } catch {
        /* ignore */
      }
    }
    state.subscribers.clear()
    for (const entry of state.pending.values()) {
      if (entry.timer) clearTimeout(entry.timer)
    }
    state.pending.clear()
    server.close()
    stopTunnel()
    if (discoverySocket) {
      try {
        discoverySocket.close()
      } catch {
        /* ignore */
      }
      discoverySocket = undefined
    }
    for (const handle of state.handles.values()) {
      Promise.resolve(handle.dispose?.()).catch(() => {})
    }
    state.handles.clear()
  }, 'dsh-watch: http server')
}

// ---------------------------------------------------------------------------
// 内置网页客户端（手表之外的兜底：电脑浏览器 / 手机浏览器 / 自测）
// ---------------------------------------------------------------------------
const HTML_CLIENT = `<!doctype html>
<html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>dsh-watch</title>
<style>
:root{color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;font:14px/1.5 -apple-system,"Segoe UI",system-ui,sans-serif;background:#0b0d12;color:#e8ecf4}
header{display:flex;gap:8px;align-items:center;padding:10px 14px;border-bottom:1px solid #1c2333;position:sticky;top:0;background:#0b0d12}
#dot{width:9px;height:9px;border-radius:50%;background:#555;flex:none}
#dot.on{background:#3ddc84}
#dot.busy{background:#ffb020}
#title{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-weight:600}
button{font:inherit;background:#1b2334;color:#e8ecf4;border:1px solid #2a3752;border-radius:9px;padding:7px 11px;cursor:pointer}
button.primary{background:#2b6cf6;border-color:#2b6cf6}
button.ok{background:#1f8f4e;border-color:#1f8f4e}
button.no{background:#8f2431;border-color:#8f2431}
main{padding:10px 14px 120px;max-width:780px;margin:0 auto}
.ev{display:flex;gap:8px;padding:6px 0;border-bottom:1px dashed #171e2c;font-size:13px}
.ev .k{flex:none;font-size:11px;padding:1px 6px;border-radius:6px;background:#1b2334;color:#9fb0cc;height:20px;line-height:18px}
.ev .t{white-space:pre-wrap;word-break:break-word}
.k-user{background:#20304d!important;color:#9fc3ff!important}
.k-assistant{background:#132a20!important;color:#7fe0a8!important}
.k-tool{background:#2b2338!important;color:#c9a7ff!important}
.k-tool-result{background:#1f2a33!important;color:#8fd3ff!important}
.k-approval{background:#3a2412!important;color:#ffc178!important}
.card{position:fixed;left:0;right:0;bottom:0;background:#111726;border-top:1px solid #2a3752;padding:12px 14px;display:flex;gap:8px}
.card input{flex:1;background:#0b0d12;border:1px solid #2a3752;border-radius:9px;color:#e8ecf4;padding:9px 11px;font:inherit}
#approvals{max-width:780px;margin:0 auto}
.approval{border:1px solid #6b4a1f;background:#1d1509;border-radius:10px;padding:10px;margin:8px 0}
.approval .row{display:flex;gap:8px;align-items:center;margin-top:8px}
.pill{font-size:11px;color:#ffc178;border:1px solid #6b4a1f;border-radius:20px;padding:1px 8px}
#login{max-width:420px;margin:60px auto;padding:0 14px}
#login input{width:100%;background:#0b0d12;border:1px solid #2a3752;border-radius:9px;color:#e8ecf4;padding:10px;margin-bottom:8px}
.hint{color:#7c8aa5;font-size:12px}
</style></head>
<body>
<div id="login">
  <h3 style="margin:0 0 10px">dsh-watch 配对</h3>
  <input id="tok" placeholder="配对令牌（$DSH_HOME/dsh-watch.json）" autocomplete="off">
  <button class="primary" style="width:100%" onclick="saveToken()">连接</button>
  <p class="hint">令牌在电脑上：<code>~\\.dsh\\dsh-watch.json</code> 的 <code>token</code> 字段。</p>
</div>
<div id="app" hidden>
  <header>
    <span id="dot"></span><span id="title">未连接</span>
    <button onclick="window.open('/pair','_blank')">配对码</button>
    <button onclick="newSession()">新会话</button>
    <button onclick="cancelTurn()">停</button>
    <button onclick="logout()">×</button>
  </header>
  <main><div id="approvals"></div><div id="log"></div></main>
  <div class="card">
    <input id="text" placeholder="给电脑上的 DSH 发指令…" onkeydown="if(event.key==='Enter')send()">
    <button class="primary" onclick="send()">发送</button>
    <button onclick="steer()">插入</button>
  </div>
</div>
<script>
const $ = (s) => document.querySelector(s);
let token = localStorage.getItem('dshwatch') || '';
let es = null, lastTitle = '', approvals = new Map();

function h(html){const d=document.createElement('div');d.innerHTML=html;return d.firstElementChild}
function esc(s){return String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
function saveToken(){token=$('#tok').value.trim();localStorage.setItem('dshwatch',token);location.reload()}
function logout(){localStorage.removeItem('dshwatch');location.reload()}
function auth(){return {'x-dsh-watch-token':token,'content-type':'application/json'}}
function api(path,opt){opt=opt||{};opt.headers=auth();return fetch(path,opt).then(async r=>{const j=await r.json().catch(()=>({}));if(!r.ok)throw new Error(j.error||('HTTP '+r.status));return j})}

function addEvent(e){
  const k=e.kind||'ev';
  let label={user:'你',assistant:'模型',tool:'工具','tool-result':'结果',turn:'回合',status:'状态',info:'信息','approval':'审批','approval-done':'审批'}[k]||k;
  let text=e.text||'';
  if(k==='tool')text=(e.name||'tool')+' · '+text;
  if(k==='tool-result')text=(e.ok===false?'✗ ':'✓ ')+text;
  if(k==='turn')text=e.running?'回合开始':'回合结束 '+(e.reason||'');
  if(k==='status')text=e.running?'运行中':'空闲';
  if(k==='approval')text=(e.tool||'')+' '+(e.reason||'')+' '+(e.text||'');
  if(k==='approval-done')text=e.outcome;
  const row=h('<div class="ev"><span class="k k-'+esc(k)+'">'+esc(label)+'</span><span class="t">'+esc(text)+'</span></div>');
  $('#log').appendChild(row);
  while($('#log').children.length>300)$('#log').removeChild($('#log').firstChild);
  row.scrollIntoView({block:'end'});
}
function renderApproval(a){
  if(approvals.has(a.id))return;
  approvals.set(a.id,true);
  const box=h('<div class="approval" id="ap-'+esc(a.id)+'"><div><span class="pill">需要审批</span> <b>'+esc(a.tool||'tool')+'</b></div>'+
    '<div class="hint">'+esc(a.reason||'')+'</div><div style="font-family:ui-monospace,monospace;font-size:12px;margin-top:6px">'+esc(a.preview||'')+'</div>'+
    '<div class="row"><button class="ok" onclick="decide(\\''+esc(a.id)+'\\',\\'allow\\')">允许</button>'+
    '<button class="no" onclick="decide(\\''+esc(a.id)+'\\',\\'deny\\')">拒绝</button>'+
    '<span class="hint" id="cnt-'+esc(a.id)+'"></span></div></div>');
  $('#approvals').appendChild(box);
  const expire=a.expiresAt||Date.now()+60000;
  const timer=setInterval(()=>{const left=Math.max(0,Math.round((expire-Date.now())/1000));const el=document.getElementById('cnt-'+a.id);if(el)el.textContent=left+'s 后转交 Web UI';if(left<=0){clearInterval(timer);removeApproval(a.id)}},1000);
}
function removeApproval(id){approvals.delete(id);const el=document.getElementById('ap-'+id);if(el)el.remove()}
function decide(id,d){api('/api/approval',{method:'POST',body:JSON.stringify({id,decision:d})}).finally(()=>removeApproval(id))}
function send(){const t=$('#text').value.trim();if(!t)return;api('/api/prompt',{method:'POST',body:JSON.stringify({text:t})}).then(()=>{$('#text').value=''}).catch(e=>alert(e.message))}
function steer(){const t=$('#text').value.trim();if(!t)return;api('/api/prompt',{method:'POST',body:JSON.stringify({text:t,mode:'steer'})}).then(()=>{$('#text').value=''}).catch(e=>alert(e.message))}
function newSession(){api('/api/new',{method:'POST',body:'{}'}).then(()=>refresh()).catch(e=>alert(e.message))}
function cancelTurn(){api('/api/cancel',{method:'POST',body:'{}'}).catch(e=>alert(e.message))}

function refresh(){
  return api('/api/state').then(s=>{
    const sel=s.selected;
    $('#dot').className=sel&&sel.running?'busy':(es?'on':'');
    const t=sel?(sel.title||sel.id):'无活动会话';
    if(t!==lastTitle){$('#title').textContent=t;lastTitle=t}
    $('#log').innerHTML='';
    (s.events||[]).forEach(addEvent);
    (s.pending||[]).forEach(renderApproval);
  }).catch(e=>{$('#title').textContent='连接失败: '+e.message;$('#dot').className=''})
}

function connect(){
  if(es)es.close();
  es=new EventSource('/api/events?token='+encodeURIComponent(token));
  es.addEventListener('hello',()=>{$('#dot').className='on';refresh()});
  es.addEventListener('ev',ev=>{const d=JSON.parse(ev.data);addEvent(d);
    if(d.kind==='status'){$('#dot').className=d.running?'busy':'on'}
    if(d.kind==='tool'){$('#dot').className='busy'}});
  es.addEventListener('approval',ev=>renderApproval(JSON.parse(ev.data)));
  es.addEventListener('approval-resolved',ev=>{const d=JSON.parse(ev.data);removeApproval(d.id)});
  es.addEventListener('selected',()=>refresh());
  es.onerror=()=>{$('#dot').className=''};
}
if(token){$('#login').hidden=true;$('#app').hidden=false;refresh();connect();setInterval(refresh,20000)}
</script>
</body></html>`
