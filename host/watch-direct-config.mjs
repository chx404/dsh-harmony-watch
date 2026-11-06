import { createHash, randomBytes, timingSafeEqual } from 'node:crypto'

export const PROVISION_TTL_MS = 5 * 60 * 1000
export const PROVISION_MAX_TICKETS = 8
export const PROVISION_BODY_LIMIT = 16 * 1024
const ROOT = '/api/direct-provision'
const TOKEN_HEADER = 'x-dsh-watch-token'
const digest = value => createHash('sha256').update(value).digest()
const sameSecret = (a, b) => timingSafeEqual(digest(a), digest(b))

function headers(res, nonce = '') {
  res.setHeader('Cache-Control', 'no-store, max-age=0')
  res.setHeader('Pragma', 'no-cache')
  res.setHeader('Referrer-Policy', 'no-referrer')
  res.setHeader('X-Content-Type-Options', 'nosniff')
  res.setHeader('X-Frame-Options', 'DENY')
  res.setHeader('Content-Security-Policy', `default-src 'none'; script-src 'nonce-${nonce}'; style-src 'nonce-${nonce}'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; object-src 'none'`)
}

function json(res, status, value) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' })
  res.end(JSON.stringify(value))
}

function fail(status, message) {
  return Object.assign(new Error(message), { status })
}

async function body(req) {
  if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(req.headers['content-type'] || '')) {
    throw fail(415, '仅接受 application/json')
  }
  const length = req.headers['content-length']
  if (length && (!/^\d+$/.test(length) || Number(length) > PROVISION_BODY_LIMIT)) {
    req.resume()
    throw fail(413, '请求体过大')
  }
  return new Promise((resolve, reject) => {
    const chunks = []
    let size = 0
    let done = false
    const clear = () => { for (const chunk of chunks) chunk.fill(0); chunks.length = 0 }
    req.on('data', chunk => {
      if (done) return // 超限后只排空，不累积，也不强关连接以致 413 丢失。
      size += chunk.length
      if (size > PROVISION_BODY_LIMIT) {
        done = true
        clear()
        reject(fail(413, '请求体过大'))
      } else chunks.push(chunk)
    })
    req.on('end', () => {
      if (done) return
      done = true
      try {
        const value = JSON.parse(Buffer.concat(chunks).toString('utf8'))
        if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error()
        resolve(value)
      } catch { reject(fail(400, '无效 JSON 请求体')) }
      finally { clear() }
    })
    const broken = () => {
      if (done) return
      done = true
      clear()
      reject(fail(400, '请求中断'))
    }
    req.on('error', broken)
    req.on('aborted', broken)
  })
}

function validateConfig(value) {
  const text = (name, max) => {
    if (typeof value[name] !== 'string') throw fail(400, '配置字段无效')
    const result = value[name].trim()
    if (!result || result.length > max || /[\u0000-\u001f\u007f]/.test(result)) throw fail(400, '配置字段无效')
    return result
  }
  const baseUrl = text('baseUrl', 2048)
  let endpoint
  try { endpoint = new URL(baseUrl) } catch { throw fail(400, 'API 地址无效') }
  if (endpoint.protocol !== 'https:' || endpoint.username || endpoint.password || endpoint.search || endpoint.hash || baseUrl.includes('?') || baseUrl.includes('#')) {
    throw fail(400, 'API 地址必须使用 HTTPS，且不能带账号、密码、查询参数或片段')
  }
  const apiKey = text('apiKey', 8192)
  const model = text('model', 256)
  if (value.protocol !== 'chat' && value.protocol !== 'responses') throw fail(400, '协议无效')
  return { baseUrl: endpoint.href.replace(/\/$/, ''), apiKey, model, protocol: value.protocol }
}

/** 独立的短期交接通道；从不请求 API、不写磁盘、不接入 state/SSE/日志。 */
export function createDirectProvision({ getToken, publicOrigin = '', getPublicOrigin = () => '', now = Date.now }) {
  const tickets = new Map()
  let disposed = false
  function trustedOrigin(value) {
    try {
      const parsed = new URL(value)
      if (parsed.protocol === 'https:' && !parsed.username && !parsed.password) return parsed.origin
    } catch { /* 无外部反代地址 */ }
    return ''
  }
  const configuredOrigin = trustedOrigin(publicOrigin)

  function remove(id) {
    const entry = tickets.get(id)
    if (entry) {
      clearTimeout(entry.timer)
      entry.config = undefined
      tickets.delete(id)
    }
  }

  function sweep() {
    for (const [id, entry] of tickets) if (now() >= entry.expiresAt) remove(id)
  }

  function checkOrigin(req, required = false) {
    const origin = req.headers.origin
    if (!origin) {
      if (required || (req.headers['sec-fetch-site'] && req.headers['sec-fetch-site'] !== 'none')) throw fail(403, '拒绝跨站请求')
      return
    }
    let parsed
    try { parsed = new URL(origin) } catch { throw fail(403, '拒绝跨站请求') }
    // Host 仅用于同源比较，绝不用于生成扫码 URL；不信任转发头。
    // TLS 终止仅认可宿主配置或宿主实际生成的隧道地址，不能由请求头升级可信 origin。
    const scheme = req.socket.encrypted ? 'https:' : 'http:'
    const direct = parsed.protocol === scheme && parsed.host === req.headers.host
    const tunnelOrigin = trustedOrigin(getPublicOrigin())
    if (parsed.origin !== origin || (!direct && origin !== configuredOrigin && origin !== tunnelOrigin) || (req.headers['sec-fetch-site'] && req.headers['sec-fetch-site'] !== 'same-origin')) {
      throw fail(403, '拒绝跨站请求')
    }
  }

  function authenticate(req) {
    const token = req.headers[TOKEN_HEADER]
    const expected = getToken()
    // 本通道不接受 query token 或浏览器长期令牌。
    if (typeof token !== 'string' || !token || typeof expected !== 'string' || !expected || !sameSecret(token, expected)) throw fail(401, '未授权')
    return digest(token)
  }

  function lookup(id) {
    if (typeof id !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(id)) throw fail(404, '票据不存在或已失效')
    const entry = tickets.get(id)
    if (!entry) throw fail(404, '票据不存在或已失效')
    return entry
  }

  async function route(req, res, path) {
    if (disposed) throw fail(503, '配置服务已关闭')
    sweep()
    if (path === '/configure') {
      if (req.method !== 'GET') throw fail(405, '不支持此方法')
      const nonce = randomBytes(24).toString('base64')
      headers(res, nonce)
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' })
      res.end(page(nonce))
      return
    }
    checkOrigin(req, path === `${ROOT}/submit`)
    if (path === `${ROOT}/submit`) {
      if (req.method !== 'POST') throw fail(405, '不支持此方法')
      const value = await body(req)
      if (disposed) throw fail(503, '配置服务已关闭')
      sweep()
      const entry = lookup(value.id)
      if (entry.config) throw fail(409, '此票据已提交，不能重复提交')
      entry.config = validateConfig(value)
      json(res, 200, { ok: true })
      return
    }
    const owner = authenticate(req)
    if (path === `${ROOT}/start`) {
      if (req.method !== 'POST') throw fail(405, '不支持此方法')
      await body(req)
      if (disposed) throw fail(503, '配置服务已关闭')
      sweep()
      if (tickets.size >= PROVISION_MAX_TICKETS) throw fail(429, '临时票据已满，请先取消或等候过期')
      const id = randomBytes(32).toString('base64url')
      const expiresAt = now() + PROVISION_TTL_MS
      const timer = setTimeout(() => remove(id), PROVISION_TTL_MS)
      timer.unref?.()
      tickets.set(id, { owner, expiresAt, timer, config: undefined })
      json(res, 201, { id, pagePath: `/configure#${id}`, expiresAt })
      return
    }
    if ((path === `${ROOT}/poll` && req.method === 'POST') || (path === ROOT && req.method === 'DELETE')) {
      const value = await body(req)
      if (disposed) throw fail(503, '配置服务已关闭')
      sweep()
      const entry = lookup(value.id)
      if (!timingSafeEqual(owner, entry.owner)) throw fail(403, '票据不属于此设备')
      if (req.method === 'DELETE') {
        remove(value.id)
        json(res, 200, { status: 'cancelled' })
      } else if (!entry.config) {
        json(res, 200, { status: 'pending' })
      } else {
        const config = entry.config
        remove(value.id) // 在写响应前消费，断线也不能二次领取。
        json(res, 200, { status: 'ready', config })
      }
      return
    }
    throw fail(404, '配置接口不存在')
  }

  return {
    matches(path) { return path === '/configure' || path === ROOT || path.startsWith(`${ROOT}/`) },
    async handle(req, res, url) {
      headers(res)
      try {
        if (url.search) throw fail(400, '配置通道不接受查询参数')
        await route(req, res, url.pathname)
      } catch (error) {
        if (!res.headersSent) json(res, error.status || 500, { error: error.status ? error.message : '配置请求失败' })
        else res.end()
      }
    },
    dispose() {
      disposed = true
      for (const id of tickets.keys()) remove(id)
    },
  }
}

function page(nonce) {
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="no-referrer"><title>手表独立 API 配置</title>
<style nonce="${nonce}">:root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;background:#0b1418;color:#edf4f3;font:16px/1.6 system-ui,sans-serif}main{max-width:520px;margin:auto;padding:24px 18px}h1{font-size:24px}label{display:block;margin-top:18px}input,select,button{width:100%;font:inherit;padding:12px;border-radius:10px;border:1px solid #47636a;background:#142126;color:inherit}button{margin-top:24px;background:#ade9d9;color:#102d29;font-weight:bold}p{color:#b4c6c9}.warn{padding:12px;background:#382b16;color:#f5d49c;border-radius:10px}#status{white-space:pre-wrap}button:disabled{opacity:.55}</style></head><body><main>
<h1>给手表配置独立 API</h1><p>手机只提交配置，不测试或连接 API。提交后请回到手表，核对 API 地址，再手动保存。之后聊天由手表直连 API，不经过宿主。</p>
<p id="transport" class="warn"></p><p>临时链接仅 5 分钟有效，请勿转发。API Key 只在宿主内存短暂中转，领取、过期或取消后清除，不写入文件。</p>
<form id="form" autocomplete="off"><label for="preset">可选预设</label><select id="preset"><option value="">自定义</option><option value="deepseek">DeepSeek</option><option value="openai">OpenAI</option></select>
<label for="baseUrl">API 地址（HTTPS，无 URL 令牌）</label><input id="baseUrl" type="url" required maxlength="2048" placeholder="https://api.deepseek.com/v1" autocomplete="off" spellcheck="false">
<label for="apiKey">API Key</label><input id="apiKey" type="password" required maxlength="8192" autocomplete="new-password" spellcheck="false">
<label for="model">模型名</label><input id="model" required maxlength="256" placeholder="deepseek-chat" autocomplete="off" spellcheck="false">
<label for="protocol">协议</label><select id="protocol"><option value="chat">chat（Chat Completions）</option><option value="responses">responses（Responses API）</option></select>
<button id="submit" type="submit">仅提交配置到手表</button></form><p id="status" role="status" aria-live="polite"></p></main>
<script nonce="${nonce}">'use strict';
let id=location.hash.slice(1);history.replaceState(null,'',location.pathname);
const el=name=>document.getElementById(name);const form=el('form');
el('transport').textContent=location.protocol==='https:'?'当前配置页使用 HTTPS。仍请确认宿主地址可信，并在手表核对最终 API 地址。':'警告：当前配置页使用 HTTP，局域网内的 API Key 和配对连接可能被窃听或篡改。仅在可信网络使用，建议通过 HTTPS 反向代理打开此页。API 地址本身必须使用 HTTPS。';
if(!/^[A-Za-z0-9_-]{43}$/.test(id)){el('submit').disabled=true;el('status').textContent='临时链接无效，请在手表重新生成二维码。';}
el('preset').addEventListener('change',()=>{const p=el('preset').value;if(p==='deepseek'){el('baseUrl').value='https://api.deepseek.com/v1';el('model').value='deepseek-chat';el('protocol').value='chat';}if(p==='openai'){el('baseUrl').value='https://api.openai.com/v1';el('model').value='gpt-4.1-mini';el('protocol').value='responses';}});
form.addEventListener('submit',async event=>{event.preventDefault();if(!id)return;el('submit').disabled=true;el('status').textContent='正在提交配置…';try{const baseUrl=el('baseUrl').value.trim();const u=new URL(baseUrl);if(u.protocol!=='https:'||u.username||u.password||u.search||u.hash||baseUrl.includes('?')||baseUrl.includes('#'))throw new Error('API 地址必须使用 HTTPS，不能包含账号、密码、查询参数或片段。');const response=await fetch('/api/direct-provision/submit',{method:'POST',headers:{'Content-Type':'application/json'},cache:'no-store',credentials:'omit',referrerPolicy:'no-referrer',body:JSON.stringify({id,baseUrl,apiKey:el('apiKey').value,model:el('model').value,protocol:el('protocol').value})});if(!response.ok)throw new Error(response.status===404?'票据已失效，请在手表重新生成。':response.status===409?'已经提交过，请回到手表核对。':'提交未成功，请检查字段或重新生成票据。');el('apiKey').value='';id='';form.hidden=true;el('status').textContent='已提交。请在手表核对 API 地址后手动保存；此页不会测试 API。';}catch(error){el('status').textContent=error.message;el('submit').disabled=false;}});
addEventListener('pagehide',()=>{id='';el('apiKey').value='';});
</script></body></html>`
}
