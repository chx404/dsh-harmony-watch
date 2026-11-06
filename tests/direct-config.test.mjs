import test from 'node:test'
import assert from 'node:assert/strict'
import { createServer, request as httpRequest } from 'node:http'
import { once } from 'node:events'
import { readFile } from 'node:fs/promises'
import ts from 'typescript'
import { createDirectProvision, PROVISION_TTL_MS, PROVISION_MAX_TICKETS, PROVISION_BODY_LIMIT } from '../host/watch-direct-config.mjs'

const ROOT = '/api/direct-provision'
const TOKEN = 'paired-host-token-not-a-browser-credential'
const KEY = 'sk-private-direct-config-key-never-in-normal-state'
const CONFIG = { baseUrl: 'https://api.example.test/v1', apiKey: KEY, model: 'my-model', protocol: 'chat' }

async function fixture(t, options = {}) {
  let token = TOKEN
  const bridge = createDirectProvision({ getToken: () => token, ...options })
  const server = createServer((req, res) => {
    const url = new URL(req.url, 'http://unused.invalid')
    if (bridge.matches(url.pathname)) void bridge.handle(req, res, url)
    else { res.writeHead(404); res.end() }
  })
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  const base = `http://127.0.0.1:${server.address().port}`
  t.after(async () => {
    bridge.dispose()
    server.closeAllConnections()
    await new Promise(resolve => server.close(resolve))
  })
  const call = async (path, { method = 'POST', value = {}, auth = TOKEN, origin, headers = {}, raw } = {}) => {
    const response = await fetch(base + path, {
      method,
      headers: {
        'content-type': 'application/json',
        ...(auth ? { 'x-dsh-watch-token': auth } : {}),
        ...(origin !== undefined ? { origin } : {}), ...headers,
      },
      ...(method === 'GET' || method === 'HEAD' ? {} : { body: raw ?? JSON.stringify(value) }),
    })
    const text = await response.text()
    let json
    try { json = JSON.parse(text) } catch { /* 页面不是 JSON */ }
    return { status: response.status, headers: response.headers, text, json }
  }
  return {
    base, call, bridge, server,
    setToken(value) { token = value },
    async start() {
      const result = await call(ROOT + '/start')
      assert.equal(result.status, 201)
      return result.json
    },
    submit(id, config = CONFIG, overrides = {}) { return call(ROOT + '/submit', { auth: '', origin: base, value: { id, ...config }, ...overrides }) },
    poll(id, auth = TOKEN) { return call(ROOT + '/poll', { value: { id }, auth }) },
    cancel(id, auth = TOKEN) { return call(ROOT, { method: 'DELETE', value: { id }, auth }) },
  }
}

function noCors(result) {
  assert.equal(result.headers.has('access-control-allow-origin'), false)
  assert.match(result.headers.get('cache-control'), /no-store/)
  assert.equal(result.headers.get('referrer-policy'), 'no-referrer')
}

function chunked(base, path, chunks, headers = {}) {
  return new Promise((resolve, reject) => {
    const req = httpRequest(base + path, { method: 'POST', headers: { 'content-type': 'application/json', ...headers } }, res => {
      const result = []
      res.on('data', chunk => result.push(chunk))
      res.on('end', () => resolve({ status: res.statusCode, text: Buffer.concat(result).toString() }))
    })
    req.on('error', reject)
    for (const chunk of chunks) req.write(chunk)
    req.end()
  })
}

test('真实 HTTP：所有设备操作只接受现有 token 头，禁止 query/Bearer', async t => {
  const f = await fixture(t)
  assert.equal((await f.call(ROOT + '/start', { auth: '' })).status, 401)
  assert.equal((await f.call(ROOT + '/start', { auth: 'wrong' })).status, 401)
  assert.equal((await f.call(ROOT + '/start', { auth: '', headers: { authorization: `Bearer ${TOKEN}` } })).status, 401)
  assert.equal((await f.call(ROOT + '/start?token=' + TOKEN, { auth: '' })).status, 400)
  const ticket = await f.start()
  assert.equal((await f.poll(ticket.id, '')).status, 401)
  assert.equal((await f.cancel(ticket.id, 'wrong')).status, 401)
  assert.equal((await f.poll(ticket.id)).json.status, 'pending')
  assert.equal((await f.cancel(ticket.id)).json.status, 'cancelled')
  assert.equal((await f.poll(ticket.id)).status, 404)
})

test('随机票据 32 字节、5 分钟、fragment，相对路径不信 Host 头', async t => {
  const f = await fixture(t)
  const before = Date.now()
  const first = await f.call(ROOT + '/start', { headers: { host: 'attacker.invalid' } })
  assert.equal(first.status, 201)
  const a = first.json
  const b = await f.start()
  assert.equal(Buffer.from(a.id, 'base64url').length, 32)
  assert.notEqual(a.id, b.id)
  assert.equal(a.pagePath, '/configure#' + a.id)
  assert.ok(a.expiresAt >= before + PROVISION_TTL_MS)
  assert.ok(a.expiresAt <= Date.now() + PROVISION_TTL_MS)
  assert.doesNotMatch(first.text, /attacker|apiKey|paired-host/)
  noCors(first)
})

test('手机页无令牌/Key回显，禁缓存/Referrer/外部资源，无 CORS 预检放行', async t => {
  const f = await fixture(t)
  const page = await f.call('/configure', { method: 'GET', auth: '' })
  assert.equal(page.status, 200)
  noCors(page)
  assert.equal(page.headers.get('x-frame-options'), 'DENY')
  const csp = page.headers.get('content-security-policy')
  assert.match(csp, /default-src 'none'/)
  assert.match(csp, /connect-src 'self'/)
  assert.match(csp, /form-action 'none'/)
  assert.match(csp, /script-src 'nonce-/)
  assert.doesNotMatch(csp, /unsafe-inline|https:/)
  assert.match(page.text, /type="password"/)
  assert.match(page.text, /history\.replaceState/)
  assert.match(page.text, /HTTP.*窃听|窃听.*HTTP/)
  assert.match(page.text, /手动保存/)
  assert.doesNotMatch(page.text, new RegExp(TOKEN + '|' + KEY))
  assert.doesNotMatch(page.text, /(?:src|href)="https?:/)
  const preflight = await f.call(ROOT + '/submit', { method: 'OPTIONS', auth: '', origin: f.base })
  assert.equal(preflight.status, 405)
  noCors(preflight)
  assert.equal((await f.call('/configure?ticket=bad', { method: 'GET', auth: '' })).status, 400)
})

test('仅票据提交、无长期token，重复提交封闭、鉴权一次消费并发安全', async t => {
  const f = await fixture(t)
  const { id } = await f.start()
  assert.deepEqual((await f.poll(id)).json, { status: 'pending' })
  const submitted = await f.submit(id)
  assert.equal(submitted.status, 200)
  assert.deepEqual(submitted.json, { ok: true })
  assert.doesNotMatch(submitted.text, new RegExp(KEY + '|apiKey|my-model'))
  assert.equal((await f.submit(id, { ...CONFIG, apiKey: 'replacement' })).status, 409)
  assert.equal((await f.poll(id, '')).status, 401)
  const results = await Promise.all([f.poll(id), f.poll(id)])
  assert.deepEqual(results.map(x => x.status).sort(), [200, 404])
  const received = results.find(x => x.status === 200)
  assert.deepEqual(received.json, { status: 'ready', config: CONFIG })
  noCors(received)
  assert.equal((await f.submit(id)).status, 404)
  assert.equal((await f.poll(id)).status, 404)
  assert.equal((await f.cancel(id)).status, 404)
})

test('恶意/空 Origin、跨站 Fetch Metadata 和非 JSON 均不消耗票据', async t => {
  const f = await fixture(t)
  const { id } = await f.start()
  for (const origin of [undefined, 'null', 'https://evil.test', f.base.replace('http:', 'https:'), f.base + '.evil.test', f.base + '/path']) {
    const rejected = await f.submit(id, CONFIG, { origin })
    assert.equal(rejected.status, 403, String(origin))
    noCors(rejected)
    assert.doesNotMatch(rejected.text, new RegExp(KEY))
  }
  assert.equal((await f.submit(id, CONFIG, { headers: { 'sec-fetch-site': 'cross-site' } })).status, 403)
  assert.equal((await f.call(ROOT + '/start', { origin: 'https://evil.test' })).status, 403)
  assert.equal((await f.submit(id, CONFIG, { headers: { 'content-type': 'text/plain' } })).status, 415)
  assert.equal((await f.submit(id, CONFIG, { raw: '{' })).status, 400)
  assert.equal((await f.poll(id)).json.status, 'pending')
  assert.equal((await f.submit(id, CONFIG, { headers: { 'sec-fetch-site': 'same-origin' } })).status, 200)
})

test('显式 HTTPS 反代 origin 可用，不信任 X-Forwarded-Host', async t => {
  const f = await fixture(t, { publicOrigin: 'https://trusted-proxy.example/' })
  const { id } = await f.start()
  assert.equal((await f.submit(id, CONFIG, { origin: 'https://evil.example', headers: { 'x-forwarded-host': 'evil.example' } })).status, 403)
  assert.equal((await f.submit(id, CONFIG, { origin: 'https://trusted-proxy.example' })).status, 200)
})

test('宿主动态 HTTPS 隧道 Origin 可用，轮换后旧地址失效，固定反代仍认可', async t => {
  let tunnel = ''
  const f = await fixture(t, { publicOrigin: 'https://fixed.example', getPublicOrigin: () => tunnel })
  const a = await f.start()
  assert.equal((await f.submit(a.id, CONFIG, { origin: 'https://quick.example' })).status, 403)
  tunnel = 'https://quick.example/some-path'
  assert.equal((await f.submit(a.id, CONFIG, { origin: 'https://quick.example' })).status, 200)
  const b = await f.start()
  tunnel = 'https://new-quick.example'
  assert.equal((await f.submit(b.id, CONFIG, { origin: 'https://quick.example' })).status, 403)
  assert.equal((await f.submit(b.id, CONFIG, { origin: 'https://new-quick.example' })).status, 200)
  const c = await f.start()
  assert.equal((await f.submit(c.id, CONFIG, { origin: 'https://fixed.example' })).status, 200)
  const d = await f.start()
  tunnel = 'http://insecure.example'
  assert.equal((await f.submit(d.id, CONFIG, { origin: 'http://insecure.example' })).status, 403)
})

test('TLS API endpoint/字段校验：拒绝 URL 内令牌、控制字符和未知协议', async t => {
  const f = await fixture(t)
  const { id } = await f.start()
  for (const patch of [
    { baseUrl: 'http://api.example/v1' }, { baseUrl: 'https://user:secret@api.example/v1' },
    { baseUrl: 'https://api.example/v1?api_key=url-secret' }, { baseUrl: 'https://api.example/v1#token' },
    { baseUrl: 'https://api.example/v1?' }, { baseUrl: 'https://api.example/v1#' },
    { apiKey: '' }, { apiKey: 'private\r\nheader' }, { model: '' }, { model: 'x'.repeat(257) },
    { protocol: 'unknown' }, { protocol: null }, { apiKey: ['secret'] },
  ]) {
    const response = await f.submit(id, { ...CONFIG, ...patch })
    assert.equal(response.status, 400, JSON.stringify(patch))
    assert.doesNotMatch(response.text, /url-secret|private|api\.example|unknown/)
  }
  assert.equal((await f.poll(id)).json.status, 'pending')
  assert.equal((await f.submit(id, { ...CONFIG, protocol: 'responses' })).status, 200)
  assert.equal((await f.poll(id)).json.config.protocol, 'responses')
})

test('真实 HTTP body 限制覆盖 Content-Length 与 chunked，不回显超限秘密', async t => {
  const f = await fixture(t)
  const { id } = await f.start()
  const huge = KEY.repeat(Math.ceil(PROVISION_BODY_LIMIT / KEY.length) + 10)
  const tooLarge = await f.submit(id, CONFIG, { raw: JSON.stringify({ id, ...CONFIG, apiKey: huge }) })
  assert.equal(tooLarge.status, 413)
  assert.doesNotMatch(tooLarge.text, new RegExp(KEY))
  const streamed = await chunked(f.base, ROOT + '/submit', ['{"id":"' + id + '","apiKey":"', huge, '"}'], { origin: f.base })
  assert.equal(streamed.status, 413)
  assert.doesNotMatch(streamed.text, new RegExp(KEY))
  assert.equal((await f.poll(id)).json.status, 'pending')
})

test('票据有上限，恰满 5 分钟即失效，过期清理释放容量', async t => {
  let time = 1_700_000_000_000
  const f = await fixture(t, { now: () => time })
  const tickets = []
  for (let i = 0; i < PROVISION_MAX_TICKETS; i++) tickets.push(await f.start())
  assert.equal((await f.call(ROOT + '/start')).status, 429)
  assert.equal((await f.submit(tickets[0].id)).status, 200)
  time += PROVISION_TTL_MS - 1
  assert.equal((await f.poll(tickets[1].id)).json.status, 'pending')
  time += 1
  assert.equal((await f.poll(tickets[0].id)).status, 404)
  assert.equal((await f.submit(tickets[1].id)).status, 404)
  assert.equal((await f.poll(tickets[1].id)).status, 404)
  assert.equal((await f.call(ROOT + '/start')).status, 201)
})

test('票据绑定创建 token；取消/卸载后不能领取秘密', async t => {
  const f = await fixture(t)
  const a = await f.start()
  await f.submit(a.id)
  f.setToken('rotated-host-token')
  assert.equal((await f.poll(a.id)).status, 401)
  assert.equal((await f.poll(a.id, 'rotated-host-token')).status, 403)
  assert.equal((await f.cancel(a.id, 'rotated-host-token')).status, 403)
  f.setToken(TOKEN)
  assert.equal((await f.cancel(a.id)).status, 200)
  assert.equal((await f.poll(a.id)).status, 404)
  const b = await f.start()
  await f.submit(b.id)
  f.bridge.dispose()
  const afterDispose = await f.poll(b.id)
  assert.equal(afterDispose.status, 503)
  assert.doesNotMatch(afterDispose.text, new RegExp(KEY))
})

// 不构建 HAP，只将纯请求 helper 转译到测试沙箱，使用真实 HTTP 适配器。
const helperSource = await readFile(new URL('../watch-app/entry/src/main/ets/common/DirectProvision.ets', import.meta.url), 'utf8')
const helperJs = ts.transpileModule(helperSource, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText
function watchHelper(adapter) {
  const module = { exports: {} }
  new Function('module', 'exports', 'require', helperJs)(module, module.exports, name => {
    assert.equal(name, '@ohos.net.http')
    return { default: adapter }
  })
  return module.exports
}

test('手表 helper 与真实配置端点契约一致，只交还待核对草稿', async t => {
  const f = await fixture(t)
  let destroyed = 0
  const helper = watchHelper({
    RequestMethod: { POST: 'POST', DELETE: 'DELETE' }, HttpDataType: { STRING: 'string' },
    createHttp: () => ({
      async request(url, options) {
        assert.equal(new URL(url).origin, f.base)
        const response = await fetch(url, { method: options.method, headers: options.header, body: options.extraData })
        return { responseCode: response.status, result: await response.text() }
      },
      destroy() { destroyed++ },
    }),
  })
  const ticket = await helper.startDirectProvision(f.base, TOKEN)
  assert.equal(ticket.pagePath, '/configure#' + ticket.id)
  assert.deepEqual(await helper.pollDirectProvision(f.base, TOKEN, ticket.id), { status: 'pending' })
  await f.submit(ticket.id)
  assert.deepEqual(await helper.pollDirectProvision(f.base, TOKEN, ticket.id), { status: 'ready', config: CONFIG })
  assert.deepEqual(await helper.pollDirectProvision(f.base, TOKEN, ticket.id), { status: 'expired' })
  const another = await helper.startDirectProvision(f.base, TOKEN)
  await helper.cancelDirectProvision(f.base, TOKEN, another.id)
  assert.equal((await f.poll(another.id)).status, 404)
  assert.equal(destroyed, 6)
})

test('手表 helper 检查 HTTP 状态、异常成功响应及旧宿主提示', async () => {
  for (const code of [404, 405, 501, 200]) {
    const helper = watchHelper({ RequestMethod: { POST: 'POST' }, HttpDataType: { STRING: 'string' }, createHttp: () => ({
      request: async () => ({ responseCode: code, result: code === 200 ? '<html>old host</html>' : '{}' }), destroy() {},
    }) })
    await assert.rejects(helper.startDirectProvision('http://127.0.0.1:8765', TOKEN), /需更新并重启宿主/)
  }
  const helper = watchHelper({ RequestMethod: { POST: 'POST' }, HttpDataType: { STRING: 'string' }, createHttp: () => ({
    request: async () => ({ responseCode: 401, result: '{"id":"fake-success"}' }), destroy() {},
  }) })
  await assert.rejects(helper.startDirectProvision('http://127.0.0.1:8765', TOKEN), /授权失败/)
})

test('真实完整宿主：独立 Key/票据不进入 state、SSE、诊断、日志，旧本机设置/配对页仍可用', async t => {
  const logs = []
  const log = console.log
  console.log = (...args) => { logs.push(args.join(' ')) }
  t.after(() => { console.log = log })
  const reserve = createServer()
  reserve.listen(0, '127.0.0.1')
  await once(reserve, 'listening')
  const port = reserve.address().port
  await new Promise(resolve => reserve.close(resolve))
  const cleanups = []
  let onListening
  const listening = new Promise(resolve => { onListening = resolve })
  console.log = (...args) => { logs.push(args.join(' ')); if (args.join(' ').includes('监听 http://')) onListening() }
  const { apply } = await import('../host/index.js')
  apply({ get() { return undefined }, on() {}, effect(fn) { cleanups.push(fn()) } }, {
    port, bind: '127.0.0.1', token: TOKEN, discovery: false, tunnel: 'off', remoteUrl: 'https://host.example.test',
  })
  t.after(() => { for (const cleanup of cleanups.reverse()) cleanup?.() })
  await listening
  const base = `http://127.0.0.1:${port}`
  const headers = { 'x-dsh-watch-token': TOKEN, 'content-type': 'application/json' }
  const created = await fetch(base + ROOT + '/start', { method: 'POST', headers, body: '{}' })
  assert.equal(created.status, 201)
  const ticket = await created.json()
  const submitted = await fetch(base + ROOT + '/submit', { method: 'POST', headers: { 'content-type': 'application/json', origin: base }, body: JSON.stringify({ id: ticket.id, ...CONFIG }) })
  assert.equal(submitted.status, 200)
  assert.equal(submitted.headers.has('access-control-allow-origin'), false)
  for (const path of ['/api/state', '/api/local-status', '/api/sessions', '/', '/pair']) {
    const response = await fetch(base + path, { headers })
    assert.equal(response.status, 200, path)
    const text = await response.text()
    assert.equal(text.includes(KEY), false, path)
    assert.equal(text.includes(ticket.id), false, path)
  }
  const controller = new AbortController()
  const stream = await fetch(base + '/api/events', { headers, signal: controller.signal })
  assert.equal(stream.status, 200)
  const reader = stream.body.getReader()
  const first = await reader.read()
  const sse = new TextDecoder().decode(first.value)
  assert.equal(sse.includes(KEY), false)
  assert.equal(sse.includes(ticket.id), false)
  await reader.cancel()
  controller.abort()
  assert.equal(logs.join('\n').includes(KEY), false)
  assert.equal(logs.join('\n').includes(ticket.id), false)
  const consumed = await fetch(base + ROOT + '/poll', { method: 'POST', headers, body: JSON.stringify({ id: ticket.id }) })
  assert.equal(consumed.status, 200)
  assert.deepEqual((await consumed.json()).config, CONFIG)
})
