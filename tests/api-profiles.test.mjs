import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomBytes, createCipheriv, createDecipheriv } from 'node:crypto';
import ts from 'typescript';

// Parent syncs the build source into watch-app. Override to test the owned build source directly.
const sourcePath = process.env.API_PROFILE_SOURCE ? resolve(process.env.API_PROFILE_SOURCE) :
  fileURLToPath(new URL('../watch-app/entry/src/main/ets/common/ApiProfiles.ets', import.meta.url));
const source = await readFile(sourcePath, 'utf8');
const directSource = await readFile(join(dirname(sourcePath), 'DirectApi.ets'), 'utf8');
function transpile(text) {
  const result = ts.transpileModule(text, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }, reportDiagnostics: true
  });
  assert.deepEqual(result.diagnostics?.filter(d => d.category === ts.DiagnosticCategory.Error), []);
  return result.outputText;
}
const js = transpile(source), directJs = transpile(directSource);
const STORE = 'dsh_api_profiles_v1', LEGACY = 'dsh_direct_api_secure_v1', KEY = 'snapshot';
const config = (changes = {}) => ({ baseUrl: 'https://api.example.com/v1', apiKey: 'sk-private-test-only', model: 'test-model', protocol: 'chat', ...changes });
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
const fixture = (changes = {}) => ({ ...config(), id: 'api-fixture', name: 'Fixture', ...changes });
const envelope = (profiles, selectedId = profiles[0]?.id ?? '', changes = {}) => ({ version: 1, profiles, selectedId, ...changes });

function environment() {
  const disk = new Map(), caches = new Map(), writes = [], events = [], logs = [], network = [];
  const state = { failPut: 0, failFlush: 0, failRead: 0, failHas: 0, failEvict: 0, failHuks: false, activeWrites: 0, maxActiveWrites: 0, gate: undefined, legacyLoads: 0 };
  const master = randomBytes(32), sessions = new Map(); let handle = 0;
  function diskStore(name) { if (!disk.has(name)) disk.set(name, new Map()); return disk.get(name); }
  const preferences = {
    async getPreferences(_context, name) {
      if (!caches.has(name)) caches.set(name, new Map(diskStore(name)));
      const values = caches.get(name);
      return {
        async has(key) { if (state.failHas-- > 0) throw Error('has ' + config().apiKey); return values.has(key); },
        async get(key, fallback) {
          if (name === LEGACY) state.legacyLoads++;
          if (state.failRead-- > 0) throw Error('read ' + config().apiKey);
          return values.has(key) ? values.get(key) : fallback;
        },
        async put(key, value) {
          events.push('put:start'); state.activeWrites++;
          state.maxActiveWrites = Math.max(state.maxActiveWrites, state.activeWrites);
          if (state.gate) { const gate = state.gate; state.gate = undefined; gate.started.resolve(); await gate.release.promise; }
          state.activeWrites--; events.push('put:end');
          // Simulate a native put that mutates its cache before rejecting, too.
          values.set(key, value);
          if (state.failPut-- > 0) throw Error('put ' + config().apiKey);
          writes.push({ name, key, value });
        },
        async flush() {
          events.push('flush');
          if (state.failFlush-- > 0) throw Error('flush ' + config().apiKey);
          disk.set(name, new Map(values));
        },
        async delete(key) { events.push('delete:' + name + ':' + key); values.delete(key); }
      };
    },
    async removePreferencesFromCache(_context, name) {
      if (state.failEvict-- > 0) throw Error('evict ' + config().apiKey);
      caches.delete(name); events.push('evict:' + name);
    }
  };
  const tags = { HUKS_TAG_ALGORITHM: 1, HUKS_TAG_KEY_SIZE: 2, HUKS_TAG_PURPOSE: 3, HUKS_TAG_BLOCK_MODE: 4, HUKS_TAG_PADDING: 5, HUKS_TAG_NONCE: 6, HUKS_TAG_ASSOCIATED_DATA: 7, HUKS_TAG_AE_TAG: 8 };
  const property = (options, tag) => options.properties.find(item => item.tag === tag)?.value;
  const huks = {
    HuksTag: tags, HuksKeyAlg: { HUKS_ALG_AES: 20 }, HuksKeySize: { HUKS_AES_KEY_SIZE_256: 256 },
    HuksKeyPurpose: { HUKS_KEY_PURPOSE_ENCRYPT: 1, HUKS_KEY_PURPOSE_DECRYPT: 2 },
    HuksCipherMode: { HUKS_MODE_GCM: 32 }, HuksKeyPadding: { HUKS_PADDING_NONE: 0 },
    async isKeyItemExist() { if (state.failHuks) throw Error('HUKS ' + config().apiKey); return true; },
    async initSession(_alias, options) { if (state.failHuks) throw Error('HUKS ' + config().apiKey); sessions.set(++handle, options); return { handle }; },
    async finishSession(handle, options) {
      const initial = sessions.get(handle); sessions.delete(handle);
      const decipher = createDecipheriv('aes-256-gcm', master, property(initial, tags.HUKS_TAG_NONCE));
      decipher.setAAD(property(initial, tags.HUKS_TAG_ASSOCIATED_DATA));
      decipher.setAuthTag(property(initial, tags.HUKS_TAG_AE_TAG));
      return { outData: new Uint8Array(Buffer.concat([decipher.update(options.inData), decipher.final()])) };
    },
    async abortSession(handle) { sessions.delete(handle); }
  };
  const util = {
    TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } },
    TextDecoder: class { decodeWithStream(bytes) { return new TextDecoder().decode(bytes); } },
    Base64Helper: class { encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); } decodeSync(text) { return new Uint8Array(Buffer.from(text, 'base64')); } }
  };
  const dependencies = { '@ohos.data.preferences': preferences, '@ohos.util': util, '@ohos.url': { URL }, '@ohos.net.http': {
    createHttp() { network.push('http'); throw Error('must not access network'); }
  }, '@ohos.security.huks': huks, '@ohos.security.cryptoFramework': {} };
  function evaluate(code, direct) {
    const module = { exports: {} };
    const log = (...args) => logs.push(args);
    new Function('module', 'exports', 'require', 'console', code)(module, module.exports, name => {
      if (name === './DirectApi') return direct;
      assert.ok(dependencies[name], 'unexpected dependency: ' + name);
      return { default: dependencies[name] };
    }, { log, error: log, warn: log, debug: log, info: log });
    return module.exports;
  }
  const direct = evaluate(directJs);
  function load() { return evaluate(js, direct); }
  const api = load();
  function seed(value) { diskStore(STORE).set(KEY, typeof value === 'string' ? value : JSON.stringify(value)); caches.delete(STORE); }
  function seedLegacy(value = config()) {
    const nonce = randomBytes(12), cipher = createCipheriv('aes-256-gcm', master, nonce);
    cipher.setAAD(Buffer.from('dsh-direct-api-v1'));
    const data = Buffer.concat([cipher.update(JSON.stringify(value)), cipher.final(), cipher.getAuthTag()]);
    const sealed = JSON.stringify({ version: 1, nonce: nonce.toString('base64'), data: data.toString('base64') });
    diskStore(LEGACY).set('sealed', sealed); caches.delete(LEGACY); return sealed;
  }
  return { api, direct, state, writes, events, logs, network, diskStore, seed, seedLegacy,
    store: () => new api.ApiProfileStore({}), raw: () => diskStore(STORE).get(KEY),
    restart() { caches.clear(); return new (load().ApiProfileStore)({}); }
  };
}

function safeFailure(pattern) {
  return error => { assert.match(error.message, pattern); assert.ok(!error.message.includes(config().apiKey)); return true; };
}

test('空库load只读；明文白名单单JSON位于新私有preferences，无旧数据删除', async () => {
  const env = environment(), store = env.store();
  assert.deepEqual(await store.load(), { profiles: [], selectedId: '', notice: env.api.API_PROFILE_STORAGE_NOTICE });
  assert.equal(env.writes.length, 0); assert.equal(store.active(), undefined);
  const profile = await store.upsert(config({ model: ' test-model ', baseUrl: 'https://API.example.com/v1/responses/', ignored: 'extra', toJSON() { throw Error('do not serialize caller'); } }));
  assert.match(profile.id, /^api-/); assert.equal(profile.name, 'test-model');
  assert.equal(profile.baseUrl, 'https://api.example.com/v1'); assert.equal(profile.model, 'test-model');
  const parsed = JSON.parse(env.raw()); assert.equal(parsed.profiles[0].apiKey, config().apiKey);
  assert.deepEqual(Object.keys(parsed.profiles[0]).sort(), ['apiKey', 'baseUrl', 'id', 'model', 'name', 'protocol']);
  assert.ok(!env.raw().includes('ignored')); assert.ok(!env.raw().includes('notice'));
  assert.ok(env.writes.every(w => w.name === STORE && w.key === KEY));
  assert.ok(!env.events.some(e => e.startsWith('delete:')));
  assert.match(env.api.API_PROFILE_STORAGE_NOTICE, /明文.*不加密/);
});

test('多配置选择重启；相同base/model不同Key无id永远新增；有id原位更新不覆盖其他', async () => {
  const env = environment(), store = env.store();
  const a = await store.upsert(config(), 'first');
  const b = await store.upsert(config({ apiKey: 'sk-other-key' }), 'second');
  assert.notEqual(a.id, b.id); assert.equal(store.active().id, b.id);
  await store.select(a.id);
  const updated = await store.upsert(config({ apiKey: 'sk-rotated', model: 'new-model', protocol: 'responses' }), 'edited', a.id);
  assert.equal(updated.id, a.id); assert.equal(store.active().id, a.id);
  assert.equal(store.list()[1].apiKey, 'sk-other-key'); assert.equal(store.list()[1].name, 'second');
  const restarted = env.restart(), snapshot = await restarted.load();
  assert.deepEqual(snapshot.profiles, store.list()); assert.equal(snapshot.selectedId, a.id);
  await assert.rejects(store.upsert(config(), '', 'api-missing'), /不存在/);
  await assert.rejects(store.select('api-missing'), /不存在/);
  await assert.rejects(store.remove('api-missing'), /不存在/);
});

test('明确delete只删一条；选中其他条目不变，删成空snapshot不会复活旧sealed', async () => {
  const env = environment(), sealed = env.seedLegacy(), store = env.store();
  const migrated = (await store.load()).profiles[0];
  const a = await store.upsert(config({ apiKey: 'sk-new' }), 'new');
  await store.remove(migrated.id); assert.equal(store.list().length, 1); assert.equal(store.active().id, a.id);
  assert.equal(env.diskStore(LEGACY).get('sealed'), sealed);
  await store.remove(a.id); assert.deepEqual(store.list(), []); assert.equal(store.active(), undefined);
  const reads = env.state.legacyLoads;
  assert.deepEqual((await env.restart().load()).profiles, []);
  assert.equal(env.state.legacyLoads, reads); assert.equal(env.diskStore(LEGACY).get('sealed'), sealed);
});

test('返回值及入参均复制，外部修改Key不能绕过save；load/list/active/select/upsert均隔离', async () => {
  const env = environment(), store = env.store(), input = config();
  const a = await store.upsert(input); input.apiKey = 'bad';
  const baseline = store.list(), raw = env.raw();
  a.apiKey = 'bad'; const loaded = await store.load(); loaded.profiles[0].apiKey = 'bad'; loaded.profiles.length = 0;
  const selected = await store.select(a.id); selected.apiKey = 'bad';
  store.active().apiKey = 'bad'; const listed = store.list(); listed[0].apiKey = 'bad'; listed.length = 0;
  assert.deepEqual(store.list(), baseline); assert.equal(env.raw(), raw);
});

test('多个实例全局串行且每次读取最新；慢写不盖快写，等待队列期间入参快照稳定', async () => {
  const env = environment(), a = env.store(), b = env.store();
  const initial = await a.upsert(config());
  const gate = { started: deferred(), release: deferred() }; env.state.gate = gate;
  const first = a.upsert(config({ apiKey: 'sk-A' }), 'A', initial.id); await gate.started.promise;
  const input = config({ apiKey: 'sk-B' }); const second = b.upsert(input, 'B'); input.apiKey = 'mutated';
  const third = a.upsert(config({ apiKey: 'sk-C' }), 'C', initial.id);
  assert.equal(a.active().apiKey, config().apiKey); gate.release.resolve();
  await Promise.all([first, second, third]);
  const result = await a.load();
  assert.equal(env.state.maxActiveWrites, 1); assert.equal(result.profiles.length, 2);
  assert.equal(result.profiles[0].apiKey, 'sk-C'); assert.equal(result.profiles[1].apiKey, 'sk-B');
  assert.equal(result.selectedId, result.profiles[1].id);
});

test('flush失败保旧内存和磁盘，清未提交缓存；读盘重试、队列均可继续', async () => {
  const env = environment(), store = env.store(), a = await store.upsert(config());
  const before = store.list(), raw = env.raw(); env.state.failFlush = 1;
  await assert.rejects(store.upsert(config({ apiKey: 'sk-retry' }), 'retry', a.id), safeFailure(/保存失败/));
  assert.deepEqual(store.list(), before); assert.equal(env.raw(), raw);
  assert.ok(env.events.includes('evict:' + STORE)); assert.deepEqual((await store.load()).profiles, before);
  await store.upsert(config({ apiKey: 'sk-retry' }), 'retry', a.id);
  assert.equal((await env.restart().load()).profiles[0].apiKey, 'sk-retry');
});

test('put已污染缓存后失败、evict失败不发布；多次load驱逐重试保全部原Key', async () => {
  const env = environment(), store = env.store(), a = await store.upsert(config());
  const raw = env.raw(), before = store.list(); env.state.failPut = 1; env.state.failEvict = 2;
  await assert.rejects(store.upsert(config({ apiKey: 'sk-no-commit' }), '', a.id), safeFailure(/保存失败/));
  assert.deepEqual(store.list(), before); assert.equal(env.raw(), raw);
  await assert.rejects(store.load(), safeFailure(/读取失败/));
  assert.deepEqual((await store.load()).profiles, before);
  await store.upsert(config({ apiKey: 'sk-retry' }), '', a.id); assert.equal(store.active().apiKey, 'sk-retry');
});

test('select/remove/新增flush失败均不发布空快照或改变选中，失败后仍可重试', async () => {
  const env = environment(), store = env.store(), a = await store.upsert(config()), b = await store.upsert(config({ apiKey: 'sk-B' }));
  const before = store.list(), raw = env.raw();
  for (const action of [() => store.select(a.id), () => store.remove(b.id), () => store.upsert(config())]) {
    env.state.failFlush = 1; await assert.rejects(action(), safeFailure(/保存失败/));
    assert.deepEqual(store.list(), before); assert.equal(store.active().id, b.id); assert.equal(env.raw(), raw);
  }
  await store.remove(a.id); assert.equal(store.list().length, 1); assert.equal(store.active().id, b.id);
});

test('坏JSON/无效条目/重复ID/选中损坏全部明确throw，不自动清空或写回，也不尝试旧迁移', async () => {
  const env = environment(), store = env.store(), a = await store.upsert(config()), before = store.list();
  env.seedLegacy();
  const bad = ['', '{broken', 'null', '[]', '42', '{}', JSON.stringify(envelope([fixture({ apiKey: '' })])),
    JSON.stringify(envelope([fixture(), fixture()])), JSON.stringify(envelope([null])),
    JSON.stringify(envelope([fixture()], 'api-missing')), JSON.stringify(envelope([], 'api-invalid')),
    JSON.stringify(envelope([], '', { version: 2 })), JSON.stringify(envelope([], '', { legacyPending: 'yes' }))];
  for (const raw of bad) {
    env.seed(raw); const count = env.writes.length, reads = env.state.legacyLoads;
    for (const action of [() => store.load(), () => store.upsert(config()), () => store.remove(a.id), () => store.select(a.id)]) {
      await assert.rejects(action(), /损坏/); assert.equal(env.raw(), raw);
      assert.equal(env.writes.length, count); assert.equal(env.state.legacyLoads, reads); assert.deepEqual(store.list(), before);
    }
  }
  env.diskStore(STORE).set(KEY, 23); await assert.rejects(store.load(), /损坏/);
});

test('未知字段仅白名单读取，load只读，mutation不重新写入额外Key字段', async () => {
  const env = environment(); env.seed(envelope([fixture({ extra: config(), toJSONLeak: 'ignored' })], 'api-fixture', { unexpected: 'ignore' }));
  const raw = env.raw(), store = env.store(); const loaded = await store.load();
  assert.equal(env.raw(), raw); assert.equal(env.writes.length, 0); assert.ok(!('extra' in loaded.profiles[0]));
  await store.select('api-fixture'); assert.ok(!env.raw().includes('unexpected')); assert.ok(!env.raw().includes('toJSONLeak'));
});

test('旧HUKS解密成功导入单条并flush，sealed逐字保留；后续不重复迁移', async () => {
  const env = environment(), sealed = env.seedLegacy(), store = env.store();
  const result = await store.load(); assert.equal(result.profiles.length, 1); assert.equal(result.profiles[0].apiKey, config().apiKey);
  assert.equal(result.selectedId, result.profiles[0].id); assert.match(result.notice, /旧加密副本仍保留/);
  assert.equal(env.diskStore(LEGACY).get('sealed'), sealed); assert.equal(JSON.parse(env.raw()).legacyPending, false);
  const reads = env.state.legacyLoads; assert.equal((await env.restart().load()).profiles.length, 1); assert.equal(env.state.legacyLoads, reads);
  assert.ok(!env.events.some(e => e.startsWith('delete:'))); assert.ok(env.writes.every(w => w.name === STORE));
});

test('旧迁移flush失败不发布、保sealed且无新snapshot，之后重试可迁移', async () => {
  const env = environment(), sealed = env.seedLegacy(), store = env.store(); env.state.failFlush = 1;
  await assert.rejects(store.load(), safeFailure(/保存失败/)); assert.deepEqual(store.list(), []);
  assert.equal(env.raw(), undefined); assert.equal(env.diskStore(LEGACY).get('sealed'), sealed);
  assert.equal((await store.load()).profiles[0].apiKey, config().apiKey);
});

test('HUKS不可用/坏sealed与真正未配置区分；迁移失败只读保原并给明确notice', async () => {
  for (const broken of [false, true]) {
    const env = environment(), sealed = broken ? '{broken ciphertext' : env.seedLegacy();
    if (broken) env.diskStore(LEGACY).set('sealed', sealed); else env.state.failHuks = true;
    const result = await env.store().load(); assert.deepEqual(result.profiles, []); assert.match(result.notice, /迁移未完成.*仍保留.*可继续新增/);
    assert.equal(env.raw(), undefined); assert.equal(env.writes.length, 0); assert.equal(env.diskStore(LEGACY).get('sealed'), sealed);
  }
  const empty = environment(); assert.doesNotMatch((await empty.store().load()).notice, /迁移未完成/);
  const inaccessible = environment(); inaccessible.state.failHas = 2;
  await assert.rejects(inaccessible.store().load(), safeFailure(/读取失败/));
});

test('迁移失败允许新增，legacyPending保留；恢复解密后追加旧Key且不覆盖新增Key/选中', async () => {
  const env = environment(), sealed = env.seedLegacy(); env.state.failHuks = true;
  const store = env.store(), fresh = await store.upsert(config({ apiKey: 'sk-fresh' }), 'Fresh');
  assert.equal(JSON.parse(env.raw()).legacyPending, true); assert.equal(store.active().id, fresh.id);
  const failed = await env.restart().load(); assert.equal(failed.profiles[0].apiKey, 'sk-fresh'); assert.match(failed.notice, /迁移未完成/);
  env.state.failHuks = false; const restored = await store.load();
  assert.deepEqual(restored.profiles.map(p => p.apiKey), ['sk-fresh', config().apiKey]); assert.equal(restored.selectedId, fresh.id);
  assert.equal(JSON.parse(env.raw()).legacyPending, false); assert.equal(env.diskStore(LEGACY).get('sealed'), sealed);
  assert.equal((await env.restart().load()).profiles.length, 2);
});

test('pending迁移时显式删除到空终止复活，旧sealed仍保留', async () => {
  const env = environment(), sealed = env.seedLegacy(); env.state.failHuks = true;
  const store = env.store(), fresh = await store.upsert(config({ apiKey: 'sk-fresh' })); await store.remove(fresh.id);
  assert.equal(JSON.parse(env.raw()).legacyPending, false); env.state.failHuks = false;
  assert.deepEqual((await env.restart().load()).profiles, []); assert.equal(env.diskStore(LEGACY).get('sealed'), sealed);
});

test('旧单session fallback配置可导入，迁移代码不调用旧clear/save', async () => {
  const env = environment(); env.state.failHuks = true;
  await new env.direct.DirectConfigStore({}).save(config()); // Arrange old process-only fallback.
  env.events.length = 0; env.writes.length = 0;
  const store = env.store(), loaded = await store.load(); assert.equal(loaded.profiles[0].apiKey, config().apiKey);
  assert.equal(JSON.parse(env.raw()).profiles[0].apiKey, config().apiKey);
  assert.ok(!env.events.some(e => e.startsWith('delete:'))); assert.ok(env.writes.every(w => w.name === STORE));
  assert.doesNotMatch(source, /\.clear\s*\(|\.delete\s*\(|\.save\s*\(/);
});

test('30配置上限拒绝而不丢Key，删除释放名额；超大快照和超过30主存同样拒绝', async () => {
  const env = environment(), store = env.store(), profiles = [];
  for (let i = 0; i < 30; i++) profiles.push(await store.upsert(config({ apiKey: 'sk-' + i })));
  const raw = env.raw(), before = store.list(); await assert.rejects(store.upsert(config()), /30.*上限/);
  assert.equal(env.raw(), raw); assert.deepEqual(store.list(), before);
  await store.upsert(config({ apiKey: 'sk-rotated' }), 'updated', profiles[0].id); assert.equal(store.list().length, 30);
  await store.remove(profiles[0].id); await store.upsert(config()); assert.equal(store.list().length, 30);
  env.seed(' '.repeat(env.api.API_PROFILE_MAX_BYTES + 1)); await assert.rejects(store.load(), /1 MiB/);
  env.seed(envelope(Array.from({ length: 31 }, (_, i) => fixture({ id: 'api-' + i })))); await assert.rejects(store.load(), /30.*上限/);
});

test('1MiB限制按UTF8字节计；超大旧快照拒绝且保留，合法大字段可以重读', async () => {
  const env = environment(), store = env.store();
  const large = config({ apiKey: '密'.repeat(8192), baseUrl: 'https://example.com/' + 'x'.repeat(2000) });
  for (let i = 0; i < 30; i++) await store.upsert(large);
  const baseline = store.list(); assert.equal((await store.load()).profiles.length, 30);
  assert.ok(Buffer.byteLength(env.raw(), 'utf8') <= env.api.API_PROFILE_MAX_BYTES);
  // Per-field caps currently make valid writes smaller than 1MiB; an externally
  // supplied large snapshot still must be measured by bytes, not JS string length.
  const oversized = JSON.stringify(envelope([fixture()], 'api-fixture', { extra: '密'.repeat(350000) }));
  assert.ok(oversized.length < env.api.API_PROFILE_MAX_BYTES); assert.ok(Buffer.byteLength(oversized) > env.api.API_PROFILE_MAX_BYTES);
  env.seed(oversized); const count = env.writes.length;
  await assert.rejects(store.load(), /1 MiB/); await assert.rejects(store.upsert(config()), /1 MiB/);
  assert.equal(env.raw(), oversized); assert.equal(env.writes.length, count); assert.deepEqual(store.list(), baseline);
  env.seed(envelope([fixture()])); await store.upsert(config()); assert.equal(store.list().length, 2);
});

test('Unicode路径规范化后超长须保存前拒绝，不得写出下次无法读取的快照', async () => {
  const env = environment(), store = env.store(); await store.upsert(config()); const raw = env.raw();
  await assert.rejects(store.upsert(config({ baseUrl: 'https://example.com/' + '路'.repeat(2000) })), /API 地址/);
  assert.equal(env.raw(), raw); assert.equal((await store.load()).profiles.length, 1);
});

test('不泄露Key到日志/网络/异常/notice，Key只明文进入新store而不进入URL和事件流', async () => {
  const env = environment(), store = env.store();
  for (const changes of [{ apiKey: '' }, { protocol: 'bad' }, { baseUrl: 'http://bad.example' }, { model: 4 }]) {
    await assert.rejects(store.upsert(config(changes)), error => !error.message.includes(config().apiKey));
  }
  const a = await store.upsert(config()); env.state.failRead = 1;
  await assert.rejects(store.upsert(config(), '', a.id), safeFailure(/读取失败/));
  const snapshot = await store.load(); assert.ok(!snapshot.notice.includes(config().apiKey));
  assert.deepEqual(env.logs, []); assert.deepEqual(env.network, []); assert.ok(!JSON.stringify(env.events).includes(config().apiKey));
  assert.ok(env.writes.every(w => w.name === STORE && w.key === KEY));
  assert.doesNotMatch(source, /console\.|hilog\.|from ['"]\.\/Net|@ohos\.net\./);
  assert.ok(!store.active().baseUrl.includes(config().apiKey));
});
