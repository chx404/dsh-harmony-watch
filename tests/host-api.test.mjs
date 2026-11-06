// 接口级回归：用假上下文启动宿主，验证鉴权、脱敏与失效关闭。
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { EventEmitter } from 'node:events';

process.env.DSH_HOME = mkdtempSync(join(tmpdir(), 'dsh-watch-api-'));
const PORT = 18791;

class FakeCtx {
  constructor() {
    this.emitter = new EventEmitter();
    this.services = new Map();
  }
  on(name, callback) { this.emitter.on(name, callback); return () => this.emitter.off(name, callback); }
  get(name) { return this.services.get(name); }
  effect(fn) { return fn(); }
}

const ctx = new FakeCtx();
const plugin = await import('../host/index.js');
plugin.apply(ctx, {
  port: PORT, bind: '127.0.0.1', token: 'api-test-token',
  discovery: false, pairingTtlMs: 60000,
});
await new Promise(resolve => setTimeout(resolve, 300));

const base = `http://127.0.0.1:${PORT}`;
const auth = { 'x-dsh-watch-token': 'api-test-token' };
const get = async (path, headers = auth) => {
  const res = await fetch(base + path, { headers });
  return { status: res.status, body: await res.json().catch(() => ({})) };
};

test('未授权模型目录返回 401', async () => {
  const { status } = await get('/api/models', {});
  assert.equal(status, 401);
});

test('无会话控制器时模型目录明确 fail-closed', async () => {
  const { status, body } = await get('/api/models?sessionId=session-x');
  assert.equal(status, 503);
  assert.equal(body.ok, false);
  assert.match(String(body.error), /不支持|不可用|会话/);
});

test('详情请求找不到事件时返回 404', async () => {
  const { status, body } = await get('/api/event-detail?sessionId=missing&seq=1&t=1');
  assert.equal(status, 404);
  assert.equal(body.ok, false);
});

test('状态快照不泄露工具详情正文', async () => {
  const { status, body } = await get('/api/state');
  assert.equal(status, 200);
  assert.ok(Array.isArray(body.events));
  for (const ev of body.events) {
    assert.equal('detail' in ev, false);
  }
});

test('模型切换缺少会话时返回 400', async () => {
  const res = await fetch(base + '/api/model', {
    method: 'POST', headers: { ...auth, 'content-type': 'application/json' },
    body: JSON.stringify({ provider: 'p', model: 'm' }),
  });
  assert.equal(res.status, 400);
});

test('图片接口：未授权 401，未知事件 404', async () => {
  const unauth = await get('/api/image?sessionId=x&seq=1&i=0', {});
  assert.equal(unauth.status, 401);
  const missing = await get('/api/image?sessionId=x&seq=1&i=0');
  assert.equal(missing.status, 404);
  assert.equal(missing.body.ok, false);
});

// 插件没有暴露关闭钩子；接口断言全部结束后主动收尾，避免端口挂住事件循环。
test.after(() => {
  setTimeout(() => process.exit(0), 30);
});
