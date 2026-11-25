import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';
const source = fs.readFileSync(new URL('../watch-app/entry/src/main/ets/common/WatchProvisionProtocol.ets', import.meta.url), 'utf8');
const js = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ES2020 } }).outputText;
const { WatchHttpParser, WatchProvisionProtocol, decodeWatchUtf8 } = await import('data:text/javascript;base64,' + Buffer.from(js).toString('base64'));
const token = 'a'.repeat(43);
const origin = 'http://192.168.3.99:43210';
const config = { baseUrl: 'https://api.example.com/v1', model: '模型😀', apiKey: 'secret-key-never-echo', protocol: 'chat' };
const clock = { now: 1000 };
const validate = c => {
  if (!c.baseUrl.startsWith('https://') || !c.apiKey || !c.model || !['chat', 'responses'].includes(c.protocol)) throw Error('do not echo ' + c.apiKey);
  return { ...c };
};
const protocol = () => new WatchProvisionProtocol(token, origin, clock.now + 300000, validate, () => clock.now);
const request = (body = { ticket: token, ...config }, extra = {}) => ({ method: 'POST', path: '/submit', headers: { host: '192.168.3.99:43210', origin, 'content-type': 'application/json' }, body: JSON.stringify(body), ...extra });
const raw = (body = JSON.stringify({ ticket: token, ...config }), headers = '') => Buffer.from('POST /submit HTTP/1.1\r\nHost: 192.168.3.99:43210\r\nOrigin: ' + origin + '\r\nContent-Type: application/json\r\nContent-Length: ' + Buffer.byteLength(body) + '\r\n' + headers + '\r\n' + body);

for (const chunkSize of [1, 2, 3, 7, 4096]) test('fragmented Unicode POST assembles with chunk size ' + chunkSize, () => {
  const parser = new WatchHttpParser(); const bytes = raw(); let result;
  for (let i = 0; i < bytes.length; i += chunkSize) result = parser.push(bytes.subarray(i, i + chunkSize));
  assert.equal(result.method, 'POST'); assert.equal(result.path, '/submit'); assert.equal(JSON.parse(result.body).model, config.model);
  const p = protocol(); const response = p.handle(result); assert.equal(response.status, 200); assert.deepEqual(p.takeConfig(), config); assert.equal(p.takeConfig(), undefined);
  assert.throws(() => parser.push(Buffer.from('x')));
});

test('header names case insensitive and body length counts bytes, not characters', () => {
  const bytes = raw().toString().replace('Content-Length:', 'cOnTeNt-LeNgTh:');
  const result = new WatchHttpParser().push(Buffer.from(bytes)); assert.equal(result.headers['content-type'], 'application/json');
  assert.deepEqual(JSON.parse(result.body), { ticket: token, ...config });
});

for (const [name, bytes] of [
  ['duplicate host', raw(undefined, 'HOST: evil.example\r\n')],
  ['duplicate length', raw(undefined, 'Content-Length: 1\r\n')],
  ['chunked', raw(undefined, 'Transfer-Encoding: chunked\r\n')],
  ['folded header', raw(undefined, ' folded: illegal\r\n')],
  ['invalid length', Buffer.from('POST /submit HTTP/1.1\r\nHost: x\r\nContent-Length: -1\r\n\r\n')],
  ['huge length', Buffer.from('POST /submit HTTP/1.1\r\nHost: x\r\nContent-Length: 16385\r\n\r\n')],
  ['scientific length', Buffer.from('POST /submit HTTP/1.1\r\nHost: x\r\nContent-Length: 1e2\r\n\r\n')],
  ['missing POST length', Buffer.from('POST /submit HTTP/1.1\r\nHost: x\r\n\r\n')],
  ['GET with body', Buffer.from('GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\n\r\na')],
  ['pipelined', Buffer.concat([raw(), Buffer.from('GET / HTTP/1.1\r\nHost: x\r\n\r\n')])],
  ['oversized headers', Buffer.from('GET / HTTP/1.1\r\nX: ' + 'a'.repeat(8192) + '\r\n\r\n')],
  ['oversized total', Buffer.alloc(24577, 97)],
  ['HTTP/2 line', Buffer.from('GET / HTTP/2.0\r\nHost: x\r\n\r\n')],
  ['absolute URL', Buffer.from('GET http://evil.example/ HTTP/1.1\r\nHost: x\r\n\r\n')],
  ['header injection', raw(undefined, 'X-Tag: a\nInjected: y\r\n')],
  ['prototype', raw(undefined, '__proto__: x\r\n')]
]) test('HTTP parser rejects ' + name, () => {
  const parser = new WatchHttpParser(); assert.throws(() => parser.push(bytes)); assert.throws(() => parser.push(raw()));
});

test('truncated request waits for remaining bytes', () => {
  const parser = new WatchHttpParser(); const bytes = raw(); assert.equal(parser.push(bytes.subarray(0, bytes.length - 1)), undefined);
  assert.equal(JSON.parse(parser.push(bytes.subarray(bytes.length - 1)).body).apiKey, config.apiKey);
});

for (const invalid of [[0xc0,0xaf], [0xe0,0x80,0x80], [0xed,0xa0,0x80], [0xf4,0x90,0x80,0x80], [0xff], [0xe2,0x82], [0x80]]) test('strict UTF-8 rejects ' + invalid.join(','), () => assert.throws(() => decodeWatchUtf8(new Uint8Array(invalid))));

test('UTF-8 matches platform decoder for ASCII, CJK and Unicode non-BMP', () => {
  for (const str of ['', 'abc\r\n', '中文配置😀🚀', '\u0000\u007f\u0080\u07ff\u0800\ud7ff\ue000\uffff', '\u{10000}\u{10ffff}']) assert.equal(decodeWatchUtf8(Buffer.from(str)), str);
});

test('valid token submits once, returns no credentials and cannot replay after take', () => {
  const p = protocol(); const reply = p.handle(request()); assert.deepEqual(JSON.parse(reply.body), { ok: true });
  assert.doesNotMatch(reply.body, /secret|apiKey|ticket|model/); assert.deepEqual(p.takeConfig(), config);
  assert.equal(p.handle(request({ ...config, ticket: token, apiKey: 'replacement' })).status, 409); assert.equal(p.takeConfig(), undefined);
});

for (const [name, headers] of [
  ['bad Host', { host: 'evil.example', origin, 'content-type': 'application/json' }],
  ['bad Origin', { host: '192.168.3.99:43210', origin: 'https://evil.example', 'content-type': 'application/json' }],
  ['missing Origin', { host: '192.168.3.99:43210', 'content-type': 'application/json' }],
  ['simple cross-origin form', { host: '192.168.3.99:43210', origin, 'content-type': 'text/plain' }],
  ['cross-site fetch', { host: '192.168.3.99:43210', origin, 'content-type': 'application/json', 'sec-fetch-site': 'cross-site' }]
]) test('rejects ' + name + ' without consuming valid ticket', () => {
  const p = protocol(); assert.equal(p.handle(request(undefined, { headers })).status, 403); assert.equal(p.takeConfig(), undefined); assert.equal(p.handle(request()).status, 200);
});

test('eight wrong tickets lock session without echoing candidates or credentials', () => {
  const p = protocol(); for (let i=0;i<8;i++) { const reply = p.handle(request({ ...config, ticket: 'b'.repeat(43) })); assert.equal(reply.status,403); assert.doesNotMatch(reply.body,/secret-key|bbbb/); }
  assert.equal(p.handle(request()).status,429); assert.equal(p.takeConfig(),undefined);
});

test('malformed, scalar and invalid config requests are generic and can retry', () => {
  const p = protocol();
  for (const body of ['{', 'null', '[]', '1', '"text"']) assert.equal(p.handle(request(undefined, { body })).status,400);
  for (const bad of [{ ...config, apiKey: '' }, { ...config, baseUrl: 'http://no-tls.example' }, { ...config, model: '' }, { ...config, protocol: 'evil' }, { ...config, apiKey: 123 }]) {
    const reply = p.handle(request({ ...bad, ticket: token })); assert.equal(reply.status,400); assert.doesNotMatch(reply.body,/secret-key-never-echo|do not echo/);
  }
  assert.equal(p.handle(request()).status,200);
});

test('expiry and dispose clear pending key and permanently reject submission', () => {
  const p = protocol(); p.handle(request()); p.dispose(); assert.equal(p.takeConfig(),undefined); assert.equal(p.handle(request()).status,410);
  const now = clock.now; const expiring = protocol(); expiring.handle(request()); clock.now += 300000;
  assert.equal(expiring.handle(request()).status,410); assert.equal(expiring.takeConfig(),undefined); clock.now=now;
});

test('page has no external assets, contains no ticket/credentials and uses fragment-only self POST', () => {
  const p=protocol(); const reply=p.handle({ method:'GET', path:'/', headers:{host:'192.168.3.99:43210'}, body:'' });
  assert.equal(reply.status,200); assert.match(reply.contentType,/text\/html/); assert.doesNotMatch(reply.body,new RegExp(token)); assert.doesNotMatch(reply.body,/secret-key-never-echo|<script[^>]+src=|<link[^>]+href=/);
  assert.match(reply.body,/location\.hash/); assert.match(reply.body,/history\.replaceState/); assert.match(reply.body,/fetch\('\/submit'/); assert.match(reply.body,/type="password"/); assert.match(reply.body,/同一 Wi-Fi/); assert.match(reply.body,/HTTP/);
  assert.equal(p.handle({method:'GET',path:'/',headers:{host:'evil.example'},body:''}).status,403);
  assert.equal(p.handle({method:'OPTIONS',path:'/submit',headers:{host:'192.168.3.99:43210'},body:''}).status,404);
});

test('constructor rejects weak ticket, malformed IP or port, and unbounded lifetime', () => {
  for(const [key,url,expires] of [['short',origin,clock.now+10],[token,'http://evil.example:80',clock.now+10],[token,'http://999.168.3.99:80',clock.now+10],[token,'http://192.168.3.99:0',clock.now+10],[token,'http://192.168.3.99:65536',clock.now+10],[token,origin+'/',clock.now+10],[token,origin,clock.now],[token,origin,clock.now+300001]]) assert.throws(()=>new WatchProvisionProtocol(key,url,expires,validate,()=>clock.now));
});

test('QR scanner navigation from another site can open static form, not submit cross-site', () => {
  const p=protocol();assert.equal(p.handle({method:'GET',path:'/',headers:{host:'192.168.3.99:43210','sec-fetch-site':'cross-site'},body:''}).status,200);
  const r=request();r.headers['sec-fetch-site']='cross-site';assert.equal(p.handle(r).status,403);
});

test('raw CR/control characters cannot be hidden by header whitespace trimming', () => {
  for(const bad of ['X-Test: \u000bhello\r\n','X-Test: hello\r\r\n','X-Test: \u007f\r\n'])assert.throws(()=>new WatchHttpParser().push(raw(undefined,bad)));
});

test('actual phone-page script sends only to watch, clears fragment and key after success', async () => {
  const p=protocol();const page=p.handle({method:'GET',path:'/',headers:{host:'192.168.3.99:43210'},body:''}).body;
  const script=/<script>([\s\S]*?)<\/script>/.exec(page)[1];
  const listeners={},fields={};for(const name of ['form','status','send','key','base','model','protocol'])fields[name]={value:'',hidden:false,disabled:false,textContent:'',addEventListener(event,fn){listeners[event]=fn;}};
  Object.assign(fields.base,{value:config.baseUrl});fields.model.value=config.model;fields.key.value=config.apiKey;fields.protocol.value=config.protocol;
  const calls=[],history=[];
  new vm.Script(script).runInNewContext({document:{getElementById:id=>fields[id]},location:{hash:'#'+token,pathname:'/'},history:{replaceState(...args){history.push(args);}},window:{addEventListener(event,fn){listeners[event]=fn;}},AbortSignal:{timeout(){return {}; }},fetch:async(url,options)=>{calls.push({url,options});const reply=p.handle(request(JSON.parse(options.body)));return {ok:reply.status===200,status:reply.status,json:async()=>JSON.parse(reply.body)};}});
  assert.deepEqual(history[0],[null,'','/']);await listeners.submit({preventDefault(){}});
  assert.equal(calls.length,1);assert.equal(calls[0].url,'/submit');assert.equal(calls[0].options.credentials,'omit');assert.equal(calls[0].options.referrerPolicy,'no-referrer');assert.equal(fields.key.value,'');assert.equal(fields.form.hidden,true);assert.match(fields.status.textContent,/手表核对/);assert.deepEqual(p.takeConfig(),config);
  await listeners.submit({preventDefault(){}});assert.equal(calls.length,1);
});
