import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';

const root = '../watch-app/entry/src/main/ets/common/';
const source = await readFile(new URL(root + 'LocalSessions.ets', import.meta.url), 'utf8');
const directSource = await readFile(new URL(root + 'DirectApi.ets', import.meta.url), 'utf8');
function transpile(text) {
  const result = ts.transpileModule(text, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }, reportDiagnostics: true
  });
  assert.deepEqual(result.diagnostics?.filter(d => d.category === ts.DiagnosticCategory.Error), []);
  return result.outputText;
}
const js = transpile(source), directJs = transpile(directSource);
const STORE = 'dsh_local_sessions_v1', KEY = 'snapshot';
const config = (changes = {}) => ({ baseUrl: 'https://api.example.com/v1', apiKey: 'sk-private-test-only', model: 'test-model', protocol: 'chat', ...changes });
const pair = (text = 'question', answer = 'answer') => [{ role: 'user', content: text }, { role: 'assistant', content: answer }];
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };

function environment() {
  const disk = new Map(), caches = new Map(), writes = [], events = [], opened = [];
  const state = { failPut: 0, failFlush: 0, failRead: 0, failEvict: 0, activeWrites: 0, maxActiveWrites: 0, gate: undefined };
  function diskStore(name) { if (!disk.has(name)) disk.set(name, new Map()); return disk.get(name); }
  const preferences = {
    async getPreferences(_context, name) {
      opened.push(name);
      if (!caches.has(name)) caches.set(name, new Map(diskStore(name)));
      const values = caches.get(name);
      return {
        async has(key) { return values.has(key); },
        async get(key, fallback) {
          if (state.failRead-- > 0) throw Error('native private error ' + config().apiKey);
          return values.has(key) ? values.get(key) : fallback;
        },
        async put(key, value) {
          events.push('put:start'); state.activeWrites++;
          state.maxActiveWrites = Math.max(state.maxActiveWrites, state.activeWrites);
          if (state.gate) { const gate = state.gate; state.gate = undefined; gate.started.resolve(); await gate.release.promise; }
          state.activeWrites--; events.push('put:end');
          if (state.failPut-- > 0) throw Error('put failed ' + config().apiKey);
          writes.push({ name, key, value }); values.set(key, value);
        },
        async flush() {
          events.push('flush');
          if (state.failFlush-- > 0) throw Error('flush failed ' + config().apiKey);
          disk.set(name, new Map(values));
        }
      };
    },
    async removePreferencesFromCache(_context, name) {
      if (state.failEvict-- > 0) throw Error('evict failed');
      caches.delete(name); events.push('evict');
    }
  };
  const util = { TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } } };
  const dependencies = { '@ohos.data.preferences': preferences, '@ohos.util': util, '@ohos.url': { URL }, '@ohos.net.http': {}, '@ohos.security.huks': {}, '@ohos.security.cryptoFramework': {} };
  function evaluate(code, direct) {
    const module = { exports: {} };
    new Function('module', 'exports', 'require', code)(module, module.exports, name => {
      if (name === './DirectApi') return direct;
      assert.ok(dependencies[name], 'unexpected dependency: ' + name);
      return { default: dependencies[name] };
    });
    return module.exports;
  }
  function load() { const direct = evaluate(directJs); return evaluate(js, direct); }
  function seed(value) { diskStore(STORE).set(KEY, typeof value === 'string' ? value : JSON.stringify(value)); caches.delete(STORE); }
  const api = load();
  return { api, load, disk, writes, events, state, opened, seed, diskStore,
    store: () => new api.LocalSessionStore({}),
    restart() { caches.clear(); return new (load().LocalSessionStore)({}); },
    raw() { return diskStore(STORE).get(KEY); }
  };
}

function storedSession(changes = {}) {
  return { id: 'local-fixture', title: 'question', ...config(), createdAt: 1000, updatedAt: 2000, messages: pair(), draft: '', ...changes };
}
function envelope(sessions, selectedId = sessions[0]?.id ?? '') { return { version: 1, sessions, selectedId }; }

function assertNoApiKey(value) {
  assert.ok(!JSON.stringify(value).includes(config().apiKey));
  if (value && typeof value === 'object') {
    assert.ok(!Object.hasOwn(value, 'apiKey'));
    for (const child of Object.values(value)) assertNoApiKey(child);
  }
}

test('新存储为空；新建规范化白名单绑定，不保存config/apiKey，使用独立文件', async () => {
  const env = environment(), store = env.store();
  assert.deepEqual(await store.load(), { sessions: [], selectedId: '' });
  env.diskStore('dsh_direct_api_secure_v1').set('sealed', 'existing-secret-ciphertext');
  env.diskStore('dsh_cache').set('chat', 'host-history');
  const session = await store.create(config({ baseUrl: 'https://API.example.com/v1/responses/', model: ' test-model ', ignored: 'extra', toJSON() { throw Error('must not serialize config'); } }));
  assert.match(session.id, /^local-/); assert.equal(session.baseUrl, 'https://api.example.com/v1');
  assert.equal(session.model, 'test-model'); assert.equal(session.protocol, 'chat');
  assert.equal(session.title, '新对话'); assert.equal(store.currentId(), session.id);
  for (const write of env.writes) {
    assert.equal(write.name, STORE); assert.equal(write.key, KEY);
    assertNoApiKey(JSON.parse(write.value)); assert.ok(!write.value.includes('ignored'));
  }
  assert.deepEqual(env.opened.filter(name => name !== STORE), []);
  await store.remove(session.id);
  assert.equal(env.diskStore('dsh_direct_api_secure_v1').get('sealed'), 'existing-secret-ciphertext');
  assert.equal(env.diskStore('dsh_cache').get('chat'), 'host-history');
  assert.deepEqual(await env.restart().load(), { sessions: [], selectedId: '' });
});

test('进程重启恢复多会话、完整历史、草稿、选中项与各自绑定', async () => {
  const env = environment(), store = env.store();
  const a = await store.create(config()); a.messages = pair('first question', 'first answer'); a.draft = 'pending A'; await store.save(a);
  const b = await store.create(config({ baseUrl: 'https://other.example/v2', model: 'other-model', protocol: 'responses' }));
  b.messages = pair('other question', 'other answer'); b.draft = 'pending B'; await store.save(b);
  await store.select(a.id);
  const restart = env.restart(), result = await restart.load();
  assert.equal(result.selectedId, a.id); assert.equal(restart.currentId(), a.id);
  assert.deepEqual(result.sessions.map(s => [s.draft, s.messages[0].content]), [['pending A', 'first question'], ['pending B', 'other question']]);
  assert.equal(result.sessions[1].protocol, 'responses'); assert.equal(result.sessions[1].model, 'other-model');
  assert.equal(result.sessions[0].title, 'first question');
  assertNoApiKey(JSON.parse(env.raw()));
});

test('先写草稿，失败/中断重启可重试；成功提交pair清草稿且不串会话', async () => {
  const env = environment(), store = env.store();
  const a = await store.create(config()), b = await store.create(config());
  a.draft = 'retry this'; await store.save(a);
  assert.equal(store.currentId(), b.id);
  b.draft = 'other draft'; await store.save(b);
  await store.select(a.id);
  assert.deepEqual((await env.restart().load()).sessions.map(s => s.draft), ['retry this', 'other draft']);
  a.messages = pair(a.draft, 'completed'); a.draft = ''; await store.save(a);
  assert.deepEqual(store.list().map(s => s.draft), ['', 'other draft']);
  assert.equal(store.list()[0].messages.length, 2); assert.equal(store.list()[1].messages.length, 0);
});

test('所有返回值均深拷贝，外部mutation不能绕过save且不改变持久化内容', async () => {
  const env = environment(), store = env.store(), original = await store.create(config());
  original.messages = pair(); await store.save(original);
  const baseline = store.list(), raw = env.raw();
  original.draft = 'mutated'; original.messages[0].content = 'mutated';
  const loaded = await store.load(); loaded.sessions[0].messages[0].content = 'bad'; loaded.sessions.length = 0;
  const selected = await store.select(original.id); selected.draft = 'bad'; selected.messages.length = 0;
  const listed = store.list(); listed[0].messages[0].role = 'system'; listed[0].baseUrl = 'https://evil.example'; listed.push(listed[0]);
  assert.deepEqual(store.list(), baseline); assert.equal(env.raw(), raw);
});

test('并发写按调用顺序串行，输入立刻快照，慢写不会覆盖快写', async () => {
  const env = environment(), store = env.store(), initial = await store.create(config());
  const gate = { started: deferred(), release: deferred() }; env.state.gate = gate;
  const a = { ...initial, draft: 'first' }, b = { ...initial, draft: 'second' };
  const first = store.save(a); await gate.started.promise;
  const second = store.save(b); b.draft = 'external mutation after save';
  assert.equal(store.list()[0].draft, ''); assert.equal(env.state.maxActiveWrites, 1);
  gate.release.resolve(); await Promise.all([first, second]);
  assert.equal(store.list()[0].draft, 'second'); assert.equal(env.state.maxActiveWrites, 1);
  assert.equal((await env.restart().load()).sessions[0].draft, 'second');
});

test('多个store实例共享串行队列并读取最新快照，不丢失其他实例会话', async () => {
  const env = environment(), a = env.store(), b = env.store();
  const [one, two] = await Promise.all([a.create(config()), b.create(config())]);
  assert.notEqual(one.id, two.id);
  one.draft = 'A'; two.draft = 'B';
  await Promise.all([a.save(one), b.save(two)]);
  const loaded = await a.load(); assert.equal(loaded.sessions.length, 2);
  assert.deepEqual(loaded.sessions.map(s => s.draft), ['A', 'B']);
});

test('flush失败不发布内存，丢弃未提交Prefs缓存，load可恢复旧快照并重试', async () => {
  const env = environment(), store = env.store(), session = await store.create(config());
  const before = store.list(), raw = env.raw(); session.draft = 'not committed';
  env.state.failFlush = 1;
  await assert.rejects(store.save(session), e => /保存失败/.test(e.message) && !e.message.includes(config().apiKey));
  assert.deepEqual(store.list(), before); assert.equal(env.raw(), raw); assert.ok(env.events.includes('evict'));
  assert.deepEqual((await store.load()).sessions, before);
  await store.save(session); assert.equal(store.list()[0].draft, 'not committed');
  assert.equal((await env.restart().load()).sessions[0].draft, 'not committed');
});

test('put失败/缓存驱逐失败不会污染内存或毒化队列；load重试恢复', async () => {
  const env = environment(), store = env.store(), session = await store.create(config());
  const before = store.list(); session.draft = 'pending';
  env.state.failPut = 1; env.state.failEvict = 2;
  await assert.rejects(store.save(session), /保存失败/); assert.deepEqual(store.list(), before);
  await assert.rejects(store.load(), /读取失败/); assert.deepEqual(store.list(), before);
  assert.deepEqual((await store.load()).sessions, before);
  await store.save(session); assert.equal(store.list()[0].draft, 'pending');
});

test('失败的select/remove/create均不改变内存与selected，后续操作仍可成功', async () => {
  const env = environment(), store = env.store(), a = await store.create(config()), b = await store.create(config());
  const before = store.list();
  for (const action of [() => store.select(a.id), () => store.remove(b.id), () => store.create(config())]) {
    env.state.failFlush = 1; await assert.rejects(action(), /保存失败/);
    assert.deepEqual(store.list(), before); assert.equal(store.currentId(), b.id);
  }
  await store.select(a.id); assert.equal(store.currentId(), a.id);
});

test('主快照损坏明确报错、不自动覆盖，已有内存保持，所有mutation都拒绝损坏源', async () => {
  const env = environment(), store = env.store(), session = await store.create(config()), before = store.list();
  for (const bad of ['', '{broken', 'null', '[]', '42', '{}', '{"version":2,"sessions":[],"selectedId":""}', '{"version":1,"sessions":{},"selectedId":""}', '{"version":1,"sessions":[],"selectedId":9}']) {
    env.seed(bad); const count = env.writes.length;
    for (const action of [() => store.load(), () => store.create(config()), () => store.save(session), () => store.remove(session.id)]) {
      await assert.rejects(action(), /损坏/);
      assert.equal(env.raw(), bad); assert.equal(env.writes.length, count); assert.deepEqual(store.list(), before);
    }
  }
  env.diskStore(STORE).set(KEY, 23); // preferences scalar is not a JSON snapshot
  await assert.rejects(store.load(), /损坏/);
});

test('坏会话、重复ID和未知字段隔离；有效会话保留，未知role只剔除坏pair，不写回源', async () => {
  const env = environment(), valid = storedSession({ apiKey: config().apiKey, config: config(), secretExtra: true });
  valid.messages = [...pair(), { role: 'system', content: 'inject' }, { role: 'assistant', content: 'bad pair' }, ...pair('later', 'valid')];
  const bad = [null, [], 1, { ...valid, id: 'dsh-session' }, { ...valid, id: 'local-bad-id', draft: 4 },
    { ...valid, id: 'local-proto', protocol: 'unknown' }, { ...valid, id: 'local-date', createdAt: 'yesterday' },
    { ...valid, id: 'local-neg', createdAt: -1 }, { ...valid, id: 'local-back', updatedAt: 0 },
    { ...valid, id: 'local-model', model: {} }, { ...valid, id: 'local-draft', draft: null },
    { ...valid, id: 'local-messages', messages: {} }, { ...valid, id: 'local-title', title: {} },
    { ...valid, id: 'local-endpoint', baseUrl: 'https://u:p@api.example.com' }];
  env.seed(envelope([valid, ...bad, { ...valid, draft: 'duplicate must not replace first' }], 'local-missing'));
  const raw = env.raw(), store = env.store(), snapshot = await store.load();
  assert.equal(snapshot.sessions.length, 1); assert.equal(snapshot.selectedId, valid.id);
  assert.deepEqual(snapshot.sessions[0].messages, [...pair(), ...pair('later', 'valid')]);
  assertNoApiKey(snapshot); assert.equal(env.raw(), raw); assert.equal(env.writes.length, 0);
  await store.save(snapshot.sessions[0]); assertNoApiKey(JSON.parse(env.raw()));
});

test('所有会话均坏时主存报错，而不是视作空库覆盖', async () => {
  const env = environment(); env.seed(envelope([{ id: 'broken' }]));
  const raw = env.raw(), store = env.store();
  await assert.rejects(store.load(), /没有有效会话/);
  await assert.rejects(store.create(config()), /没有有效会话/);
  assert.equal(env.raw(), raw); assert.equal(env.writes.length, 0);
});

test('save拒绝新造ID、改变binding/createdAt，规范化等价地址可接受', async () => {
  const env = environment(), store = env.store(), session = await store.create(config());
  for (const changes of [{ id: 'local-forged' }, { baseUrl: 'https://other.example/v1' }, { model: 'new-model' }, { protocol: 'responses' }, { createdAt: session.createdAt - 1 }]) {
    const raw = env.raw(); await assert.rejects(store.save({ ...session, ...changes })); assert.equal(env.raw(), raw);
  }
  await store.save({ ...session, baseUrl: session.baseUrl + '/chat/completions', model: ' test-model ' });
  assert.equal(store.list()[0].baseUrl, session.baseUrl);
  await assert.rejects(store.select('local-missing'), /不存在/); await assert.rejects(store.remove('local-missing'), /不存在/);
});

test('save仅接收完整成功pair，非法role/内容/孤立消息/类型或超长draft均拒绝', async () => {
  const env = environment(), store = env.store(), session = await store.create(config()), before = env.raw();
  for (const messages of [[{ role: 'user', content: 'unfinished' }], pair('', 'answer'), pair('question', ' '),
    [{ role: 'assistant', content: 'wrong' }, { role: 'user', content: 'wrong' }],
    [{ role: 'system', content: 'bad' }, { role: 'assistant', content: 'bad' }],
    [{ role: 'user', content: {} }, { role: 'assistant', content: 'bad' }], [null, null], pair('x'.repeat(2001)), pair('ok', 'x'.repeat(12001))]) {
    await assert.rejects(store.save({ ...session, messages }), /完整成功/); assert.equal(env.raw(), before);
  }
  for (const draft of [null, 9, {}, 'x'.repeat(2001)]) await assert.rejects(store.save({ ...session, draft }), /字段无效/);
  await store.save({ ...session, draft: 'x'.repeat(2000) }); assert.equal(store.list()[0].draft.length, 2000);
});

test('标题取首条用户简短文字；历史保留最近100条完整pair，不改变调用者且标题稳定', async () => {
  const env = environment(), store = env.store(), session = await store.create(config());
  session.messages = Array.from({ length: 60 }, (_, i) => pair(i === 0 ? '  first\n question  ' : 'q' + i, 'a' + i)).flat();
  await store.save(session);
  const saved = store.list()[0]; assert.equal(saved.title, 'first question');
  assert.equal(saved.messages.length, 100); assert.equal(saved.messages[0].content, 'q10');
  assert.equal(session.messages.length, 120);
  saved.messages.push(...pair('next', 'next answer')); await store.save(saved);
  assert.equal(store.list()[0].messages[0].content, 'q11'); assert.equal(store.list()[0].title, 'first question');
  assert.match(env.api.LOCAL_SESSION_HISTORY_NOTICE, /100/);
  const long = await store.create(config()); long.messages = pair('x'.repeat(80)); await store.save(long);
  assert.equal(store.list()[1].title.length, 32);
});

test('load同样仅保留最近100条完整pair，异常消息不被静默写入主存', async () => {
  const env = environment(), session = storedSession();
  session.messages = [...Array.from({ length: 70 }, (_, i) => pair('q' + i, 'a' + i)).flat(), { role: 'user', content: 'partial' }];
  env.seed(envelope([session])); const store = env.store();
  const loaded = await store.load(); assert.equal(loaded.sessions[0].messages.length, 100);
  assert.equal(loaded.sessions[0].messages[0].content, 'q20'); assert.equal(env.writes.length, 0);
});

test('30会话上限明确拒绝，不丢其他会话；删除释放额度且恢复选中', async () => {
  const env = environment(), store = env.store();
  await store.load();
  const sessions = [];
  for (let i = 0; i < 30; i++) sessions.push(await store.create(config()));
  const raw = env.raw(), before = store.list(); await assert.rejects(store.create(config()), /30.*上限/);
  assert.equal(env.raw(), raw); assert.deepEqual(store.list(), before);
  await store.remove(sessions[29].id); assert.equal(store.currentId(), sessions[28].id);
  await store.remove(sessions[0].id); assert.equal(store.currentId(), sessions[28].id);
  await store.create(config()); assert.equal(store.list().length, 29);
  assert.equal((await env.restart().load()).selectedId, store.currentId());
});

test('总4MiB按UTF-8字节限制；超限拒绝而不丢会话，缩小后可重试', async () => {
  const env = environment(), store = env.store();
  const large = Array.from({ length: 40 }, () => pair('中'.repeat(2000), '文'.repeat(12000))).flat();
  for (let i = 0; i < 2; i++) { const session = await store.create(config()); session.messages = large; await store.save(session); }
  const third = await store.create(config()), raw = env.raw(), before = store.list(); third.messages = large;
  assert.ok(Buffer.byteLength(raw, 'utf8') < env.api.LOCAL_SESSION_MAX_BYTES);
  await assert.rejects(store.save(third), /4 MiB/);
  assert.equal(env.raw(), raw); assert.deepEqual(store.list(), before);
  third.messages = pair('small', 'small'); await store.save(third); assert.equal(store.list().length, 3);
});

test('超大/超会话数主存明确拒绝，不自动覆盖用户数据', async () => {
  const env = environment(), store = env.store();
  env.seed(' '.repeat(env.api.LOCAL_SESSION_MAX_BYTES + 1));
  await assert.rejects(store.load(), /4 MiB/); assert.equal(env.writes.length, 0);
  env.seed(envelope(Array.from({ length: 31 }, (_, i) => storedSession({ id: 'local-' + i }))));
  await assert.rejects(store.load(), /30.*上限/); assert.equal(env.writes.length, 0);
});

test('入口和错误不泄漏Key，不依赖网络，也明确明文本地存储说明', async () => {
  const env = environment(), store = env.store();
  for (const changes of [{ apiKey: '' }, { protocol: 'bad' }, { baseUrl: 'http://bad.example' }]) await assert.rejects(store.create(config(changes)));
  assert.equal(env.writes.length, 0);
  assert.doesNotMatch(source, /console\.|hilog\.|from ['"]\.\/Net|@ohos\.net\./);
  assert.match(env.api.LOCAL_SESSION_STORAGE_NOTICE, /明文.*不是加密聊天记录/);
  const session = await store.create(config()); env.state.failRead = 1;
  await assert.rejects(store.save(session), e => /读取失败/.test(e.message) && !e.message.includes(config().apiKey));
  assertNoApiKey(JSON.parse(env.raw()));
});
