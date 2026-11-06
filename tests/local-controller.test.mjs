import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';

const root = '../watch-app/entry/src/main/ets/common/';
async function compile(name) {
  const source = await readFile(new URL(root + name + '.ets', import.meta.url), 'utf8');
  const result = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }, reportDiagnostics: true
  });
  assert.deepEqual(result.diagnostics?.filter(item => item.category === ts.DiagnosticCategory.Error), []);
  return result.outputText;
}
const directJs = await compile('DirectApi');
const sessionsJs = await compile('LocalSessions');
const profilesJs = await compile('ApiProfiles');
const controllerJs = await compile('LocalChatController');
const STORE = 'dsh_local_sessions_v1', KEY = 'snapshot';
const config = (changes = {}) => ({ baseUrl: 'https://api.example.com/v1', apiKey: 'sk-controller-private', model: 'test-model', protocol: 'chat', ...changes });
const pair = (input, reply) => [{ role: 'user', content: input }, { role: 'assistant', content: reply }];
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };

function environment(credentials = config()) {
  const disk = new Map(), caches = new Map(), calls = [], clients = [], trace = [], configLoads = [];
  const state = { credentials, failFlush: 0, flushGate: undefined, loadGate: undefined, rejectOnCancel: false, changed: 0 };
  function values(name) { if (!disk.has(name)) disk.set(name, new Map()); return disk.get(name); }
  const preferences = {
    async getPreferences(_context, name) {
      if (!caches.has(name)) caches.set(name, new Map(values(name)));
      const cache = caches.get(name);
      return {
        async has(key) { return cache.has(key); },
        async get(key, fallback) {
          if (state.loadGate) { const gate = state.loadGate; state.loadGate = undefined; gate.started.resolve(); await gate.release.promise; }
          return cache.has(key) ? cache.get(key) : fallback;
        },
        async put(key, value) { trace.push({ kind: 'put', value }); cache.set(key, value); },
        async flush() {
          if (state.flushGate) { const gate = state.flushGate; state.flushGate = undefined; gate.started.resolve(); await gate.release.promise; }
          if (state.failFlush-- > 0) { trace.push({ kind: 'flush:failed' }); throw Error('disk unavailable'); }
          disk.set(name, new Map(cache)); trace.push({ kind: 'flush:success' });
        }
      };
    },
    async removePreferencesFromCache(_context, name) { caches.delete(name); trace.push({ kind: 'evict' }); }
  };
  const dependencies = {
    '@ohos.data.preferences': preferences,
    '@ohos.util': { TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } } },
    '@ohos.url': { URL }, '@ohos.net.http': {}, '@ohos.security.huks': {}, '@ohos.security.cryptoFramework': {}
  };
  function evaluate(js, local = {}) {
    const module = { exports: {} };
    new Function('module', 'exports', 'require', js)(module, module.exports, name => {
      if (Object.hasOwn(local, name)) return local[name];
      assert.ok(dependencies[name], 'unexpected dependency: ' + name);
      return { default: dependencies[name] };
    });
    return module.exports;
  }
  const actualDirect = evaluate(directJs);
  class DirectConfigStore {
    async load() {
      configLoads.push(true);
      return { config: state.credentials ? actualDirect.copyDirectConfig(state.credentials) : undefined,
        persistent: true, notice: state.credentials ? '' : '未配置；可手动输入，无需宿主' };
    }
  }
  class DirectApiClient {
    constructor() { this.pending = []; clients.push(this); }
    send(settings, history, input) {
      const body = JSON.parse(actualDirect.directRequestBody(settings, history, input));
      const call = { config: actualDirect.copyDirectConfig(settings), history: structuredClone(history), input, body, persisted: snapshot(), canceled: false, settled: false };
      const pending = new Promise((resolve, reject) => {
        call.resolve = text => { call.settled = true; resolve(text); };
        call.reject = error => { call.settled = true; reject(error); };
      });
      calls.push(call); this.pending.push(call); trace.push({ kind: 'network', input });
      return pending;
    }
    cancel() {
      for (const call of this.pending) {
        if (call.settled) continue;
        call.canceled = true;
        if (state.rejectOnCancel) call.reject(Error('已停止；该消息未加入历史'));
      }
    }
  }
  const direct = { ...actualDirect, DirectConfigStore, DirectApiClient };
  function app() {
    const sessions = evaluate(sessionsJs, { './DirectApi': direct });
    const profiles = evaluate(profilesJs, { './DirectApi': direct });
    const controller = evaluate(controllerJs, { './DirectApi': direct, './LocalSessions': sessions, './ApiProfiles': profiles });
    return { sessions, profiles, controller };
  }
  let modules = app();
  function controller() { return new modules.controller.LocalChatController({}, () => { state.changed++; }); }
  function snapshot() { const raw = values(STORE).get(KEY); return raw === undefined ? { sessions: [], selectedId: '' } : JSON.parse(raw); }
  async function seed(sessions, selectedId = sessions[0]?.id ?? '') {
    values(STORE).set(KEY, JSON.stringify({ version: 1, sessions, selectedId })); caches.delete(STORE);
  }
  async function waitForCall(index = calls.length) {
    // No timers/polling: bounded microtask draining only advances queued async storage work.
    for (let tick = 0; tick < 150 && calls.length <= index; tick++) await Promise.resolve();
    assert.ok(calls.length > index, 'expected API call ' + index);
    return calls[index];
  }
  return {
    state, disk, trace, calls, clients, configLoads, controller, snapshot, seed, waitForCall,
    restart() { caches.clear(); modules = app(); return controller(); },
    store: () => new modules.sessions.LocalSessionStore({}),
    profileStore: () => new modules.profiles.ApiProfileStore({}),
    profileSnapshot() { const raw = values('dsh_api_profiles_v1').get(KEY); return raw === undefined ? undefined : JSON.parse(raw); },
    session: (changes = {}) => ({ id: 'local-seeded', title: 'old question', baseUrl: config().baseUrl, model: config().model, protocol: config().protocol, createdAt: 100, updatedAt: 200, messages: pair('old question', 'old answer'), draft: '', ...changes })
  };
}

function bubbles(controller) { return controller.events().filter(event => event.kind === 'user' || event.kind === 'assistant').map(event => [event.kind, event.text]); }
async function open(env) { const controller = env.controller(); assert.equal(await controller.open(), true); return controller; }
async function complete(env, controller, input, answer) {
  const index = env.calls.length, pending = controller.send(input), call = await env.waitForCall(index);
  call.resolve(answer); await pending; return call;
}

test('initialize恢复重启选中项、完整100条历史、所属草稿与配置，重复初始化不重复载入', async () => {
  const env = environment();
  const one = env.session({ id: 'local-one', messages: Array.from({ length: 50 }, (_, i) => pair('q' + i, 'a' + i)).flat(), draft: 'retry one' });
  const two = env.session({ id: 'local-two', messages: pair('other question', 'other answer'), draft: 'retry two' });
  await env.seed([one, two], one.id);
  const controller = env.controller();
  await Promise.all([controller.initialize(), controller.initialize()]);
  assert.equal(controller.current().id, one.id); assert.equal(controller.current().draft, 'retry one');
  assert.equal(controller.current().messages.length, 100); assert.equal(bubbles(controller).length, 100);
  assert.match(controller.status(), /恢复/); assert.equal(controller.hasConfig(), true); assert.equal(env.configLoads.length, 1);
  await controller.initialize(); assert.equal(env.configLoads.length, 1);
  await controller.select(two.id);
  const restart = env.restart(); await restart.initialize();
  assert.equal(restart.current().id, two.id); assert.equal(restart.current().draft, 'retry two');
  assert.deepEqual(bubbles(restart), [['user', 'other question'], ['assistant', 'other answer']]);
});

test('无凭证也可恢复阅读本地历史；open不要求宿主且空库无配置不建会话', async () => {
  const env = environment(undefined); env.state.credentials = undefined;
  let controller = env.controller(); assert.equal(await controller.open(), false); assert.equal(controller.current(), undefined);
  await env.seed([env.session({ draft: 'saved offline' })]);
  controller = env.restart(); await controller.initialize();
  assert.equal(controller.hasConfig(), false); assert.equal(await controller.open(), true);
  assert.equal(controller.current().draft, 'saved offline'); assert.equal(bubbles(controller).length, 2);
  await assert.rejects(controller.send('new question'), /API Key/); assert.equal(env.calls.length, 0);
});

test('create/select保存每个会话完整history和草稿，配置绑定相互独立', async () => {
  const env = environment(), controller = await open(env), a = controller.current();
  await complete(env, controller, 'first question', 'first answer');
  await controller.saveDraft('draft A');
  await controller.create(); const b = controller.current(); assert.notEqual(b.id, a.id); assert.deepEqual(b.messages, []);
  await complete(env, controller, 'second question', 'second answer'); await controller.saveDraft('draft B');
  await controller.select(a.id); assert.equal(controller.current().draft, 'draft A');
  assert.deepEqual(bubbles(controller), [['user', 'first question'], ['assistant', 'first answer']]);
  await controller.select(b.id); assert.equal(controller.current().draft, 'draft B');
  assert.deepEqual(bubbles(controller), [['user', 'second question'], ['assistant', 'second answer']]);
  assert.equal(env.snapshot().selectedId, b.id); assert.equal(env.snapshot().sessions.length, 2);
});

test('成功先持久化完整pair清draft，后续API传历史，重启后仍携带上下文', async () => {
  const env = environment(), controller = await open(env);
  const first = await complete(env, controller, ' first ', 'answer one');
  assert.deepEqual(first.history, []); assert.equal(first.input, 'first');
  assert.deepEqual(controller.current().messages, pair('first', 'answer one')); assert.equal(controller.current().draft, '');
  assert.deepEqual(env.snapshot().sessions[0].messages, pair('first', 'answer one'));
  const second = await complete(env, controller, 'second', 'answer two');
  assert.deepEqual(second.body.messages, [...pair('first', 'answer one'), { role: 'user', content: 'second' }]);
  const restarted = env.restart(); await restarted.initialize();
  const third = await complete(env, restarted, 'third', 'answer three');
  assert.deepEqual(third.history, [...pair('first', 'answer one'), ...pair('second', 'answer two')]);
  assert.equal(restarted.current().messages.length, 6);
});

test('显示100条完整history，但真正请求体仍由DirectApi限制最近12条历史', async () => {
  const env = environment();
  await env.seed([env.session({ messages: Array.from({ length: 50 }, (_, i) => pair('q' + i, 'a' + i)).flat() })]);
  const controller = env.controller(); await controller.initialize(); assert.equal(bubbles(controller).length, 100);
  const call = await complete(env, controller, 'fresh', 'fresh answer');
  assert.equal(call.history.length, 100); assert.equal(call.body.messages.length, 13);
  assert.equal(call.body.messages[0].content, 'q44'); assert.equal(controller.current().messages.length, 100);
  assert.equal(controller.current().messages[0].content, 'q1');
});

test('草稿flush成功严格先于网络；写盘挂起时网络未开始', async () => {
  const env = environment(), controller = await open(env), gate = { started: deferred(), release: deferred() };
  env.state.flushGate = gate; const pending = controller.send('durable question'); await gate.started.promise;
  assert.equal(env.calls.length, 0); assert.equal(controller.isBusy(), true);
  assert.equal(env.snapshot().sessions[0].draft, '');
  gate.release.resolve(); const call = await env.waitForCall(0);
  assert.equal(call.persisted.sessions[0].draft, 'durable question'); assert.deepEqual(call.persisted.sessions[0].messages, []);
  const networkIndex = env.trace.findIndex(event => event.kind === 'network');
  assert.equal(env.trace[networkIndex - 1].kind, 'flush:success');
  call.resolve('durable answer'); await pending;
});

test('草稿落盘失败绝不发请求、无脏pair，解除busy后可重试', async () => {
  const env = environment(), controller = await open(env), before = env.snapshot(); env.state.failFlush = 1;
  await assert.rejects(controller.send('must persist first'), /保存失败/);
  assert.equal(env.calls.length, 0); assert.equal(controller.isBusy(), false); assert.equal(controller.hasUnsavedReply(), false);
  assert.deepEqual(env.snapshot(), before); assert.deepEqual(bubbles(controller), []);
  await complete(env, controller, 'must persist first', 'saved answer'); assert.equal(env.calls.length, 1);
});

test('API失败只留下本会话草稿，不提交失败消息pair，重启可重试', async () => {
  const env = environment(), controller = await open(env), pending = controller.send('retry failed');
  const rejected = assert.rejects(pending, /API unavailable/), call = await env.waitForCall(0);
  call.reject(Error('API unavailable')); await rejected;
  assert.equal(controller.isBusy(), false); assert.equal(controller.current().draft, 'retry failed'); assert.deepEqual(controller.current().messages, []);
  const restart = env.restart(); await restart.initialize(); assert.equal(restart.current().draft, 'retry failed');
  await complete(env, restart, 'retry failed', 'retried answer'); assert.equal(restart.current().messages.length, 2);
});

test('更换endpoint新建会话；选回旧会话使用原profile而不把旧history发到新endpoint', async () => {
  const env = environment(), controller = await open(env), a = controller.current();
  await complete(env, controller, 'private to A', 'answer A');
  await controller.configured(config({ baseUrl: 'https://other.example/v1', model: 'model-B', protocol: 'responses', apiKey: 'sk-B' }));
  const b = controller.current(); assert.notEqual(b.id, a.id); assert.deepEqual(b.messages, []);
  let call = await complete(env, controller, 'private to B', 'answer B');
  assert.equal(call.config.baseUrl, 'https://other.example/v1'); assert.equal(call.config.apiKey, 'sk-B'); assert.deepEqual(call.history, []); assert.ok(call.body.input);
  await controller.select(a.id); call = await complete(env, controller, 'continue A', 'answer A2');
  assert.equal(call.config.baseUrl, config().baseUrl); assert.equal(call.config.apiKey, config().apiKey);
  assert.deepEqual(call.history, pair('private to A', 'answer A')); assert.equal(controller.current().messages[0].content, 'private to A');
  assert.equal(controller.sessions().length, 2); assert.equal(controller.profiles().length, 2);
  assert.deepEqual(env.snapshot().sessions.find(item => item.id === b.id).messages, pair('private to B', 'answer B'));
});

test('同profile明确更新Key保留history；不同模型配置新建，旧会话仍用自身model/protocol和Key', async () => {
  const env = environment(), controller = await open(env), a = controller.current();
  await complete(env, controller, 'first', 'answer');
  const profiles = env.profileStore(); await profiles.upsert(config({ apiKey: 'new-key-only' }), '', a.profileId);
  await controller.reloadProfiles();
  assert.equal(controller.current().id, a.id); assert.equal(controller.sessions().length, 1);
  let call = await complete(env, controller, 'key rotated', 'second answer'); assert.equal(call.config.apiKey, 'new-key-only'); assert.equal(call.history.length, 2);
  await controller.configured(config({ model: 'model-v2', protocol: 'responses', apiKey: 'sk-model-v2' })); const b = controller.current(); assert.notEqual(b.id, a.id);
  await controller.select(a.id); call = await complete(env, controller, 'old model', 'old-model reply');
  assert.equal(call.config.model, 'test-model'); assert.equal(call.config.protocol, 'chat');
  assert.equal(call.history.length, 4); assert.equal(call.config.apiKey, 'new-key-only');
});

test('stop在草稿慢flush期间使请求失效，保留草稿且不启动网络', async () => {
  const env = environment(), controller = await open(env), gate = { started: deferred(), release: deferred() };
  env.state.flushGate = gate; const pending = controller.send('stopped before network'); await gate.started.promise;
  controller.cancel(); assert.equal(controller.isBusy(), false);
  gate.release.resolve(); await pending;
  assert.equal(env.calls.length, 0); assert.equal(controller.current().draft, 'stopped before network'); assert.deepEqual(controller.current().messages, []);
});

test('stop后迟回包不污染history；立即重试仅提交新一轮pair', async () => {
  const env = environment(), controller = await open(env);
  const first = controller.send('same question'), late = await env.waitForCall(0);
  controller.cancel(); assert.equal(late.canceled, true); assert.equal(controller.isBusy(), false);
  const second = controller.send('same question'), fresh = await env.waitForCall(1);
  late.resolve('late obsolete answer'); await first;
  assert.equal(controller.isBusy(), true); assert.deepEqual(controller.current().messages, []);
  fresh.resolve('fresh answer'); await second;
  assert.deepEqual(controller.current().messages, pair('same question', 'fresh answer')); assert.equal(controller.current().draft, '');
});

test('选择其他会话会取消原请求，旧回包不污染任一会话与selected', async () => {
  const env = environment(), controller = await open(env), a = controller.current();
  await controller.create(); const b = controller.current(); await controller.saveDraft('B draft'); await controller.select(a.id);
  const pending = controller.send('A pending'), late = await env.waitForCall(0);
  await controller.select(b.id); assert.equal(controller.current().id, b.id); assert.equal(controller.current().draft, 'B draft');
  late.resolve('late A answer'); await pending;
  assert.equal(controller.current().id, b.id); assert.equal(env.snapshot().selectedId, b.id);
  assert.deepEqual(controller.sessions().map(item => item.messages), [[], []]);
  assert.deepEqual(controller.sessions().map(item => item.draft), ['A pending', 'B draft']);
});

test('真实取消拒绝路径也不污染历史，清除凭证后仍保留本地会话', async () => {
  const env = environment(), controller = await open(env); env.state.rejectOnCancel = true;
  const pending = controller.send('keep draft'), rejected = assert.rejects(pending, /已停止/);
  await env.waitForCall(0); controller.credentialsCleared(); await rejected;
  assert.equal(controller.hasConfig(), false); assert.equal(controller.current().draft, 'keep draft');
  assert.deepEqual(controller.current().messages, []); assert.match(controller.status(), /配置已清除/);
  await assert.rejects(controller.send('blocked'), /API Key/); assert.equal(env.calls.length, 1);
});

test('回包落盘失败保留可见正文和hasUnsavedReply，retrySave只落盘不重发', async () => {
  const env = environment(), controller = await open(env), pending = controller.send('charged once');
  const rejected = assert.rejects(pending, /回复已收到但未存盘/), call = await env.waitForCall(0);
  env.state.failFlush = 1; call.resolve('valuable reply'); await rejected;
  assert.equal(controller.hasUnsavedReply(), true); assert.equal(controller.isBusy(), false);
  assert.deepEqual(controller.current().messages, []); assert.equal(controller.current().draft, 'charged once');
  assert.deepEqual(bubbles(controller), [['user', 'charged once'], ['assistant', 'valuable reply']]);
  const before = env.calls.length;
  await assert.rejects(controller.send('do not charge again'), /重试保存/);
  await assert.rejects(controller.create(), /重试保存/); await assert.rejects(controller.select(controller.current().id), /重试保存/);
  await assert.rejects(controller.removeCurrent(), /重试保存/);
  await controller.retrySave(); assert.equal(env.calls.length, before); assert.equal(controller.hasUnsavedReply(), false);
  assert.deepEqual(controller.current().messages, pair('charged once', 'valuable reply')); assert.equal(controller.current().draft, '');
  const restarted = env.restart(); await restarted.initialize(); assert.deepEqual(restarted.current().messages, pair('charged once', 'valuable reply'));
});

test('retrySave再次失败继续保留正文，最终成功不重发且下一次API接上成功pair', async () => {
  const env = environment(), controller = await open(env), pending = controller.send('one request');
  const rejected = assert.rejects(pending, /未存盘/), call = await env.waitForCall(0);
  env.state.failFlush = 1; call.resolve('reply once'); await rejected;
  env.state.failFlush = 1; await assert.rejects(controller.retrySave(), /保存失败/);
  assert.equal(controller.hasUnsavedReply(), true); assert.equal(controller.isBusy(), false); assert.equal(env.calls.length, 1);
  assert.deepEqual(bubbles(controller), [['user', 'one request'], ['assistant', 'reply once']]);
  await controller.retrySave(); assert.equal(controller.hasUnsavedReply(), false); assert.equal(env.calls.length, 1);
  const next = await complete(env, controller, 'follow-up', 'follow-up answer'); assert.deepEqual(next.history, pair('one request', 'reply once'));
});

test('保存回包期间拒绝切换/新建/发送，避免成功pair归入其他会话', async () => {
  const env = environment(), controller = await open(env), a = controller.current(); await controller.create(); const b = controller.current();
  await controller.select(a.id);
  const pending = controller.send('A question'), call = await env.waitForCall(0), gate = { started: deferred(), release: deferred() };
  env.state.flushGate = gate; call.resolve('A answer'); await gate.started.promise;
  assert.equal(controller.isBusy(), true);
  await assert.rejects(controller.select(b.id), /正在保存/); await assert.rejects(controller.create(), /正在保存/);
  await assert.rejects(controller.send('duplicate'), /等待/); await assert.rejects(controller.removeCurrent(), /正在保存/);
  gate.release.resolve(); await pending;
  assert.equal(controller.current().id, a.id); assert.deepEqual(controller.current().messages, pair('A question', 'A answer'));
  assert.deepEqual(controller.sessions().find(item => item.id === b.id).messages, []);
});

test('删除本地会话不清API配置；剩余选中项和历史能重启恢复', async () => {
  const env = environment(), controller = await open(env), a = controller.current();
  await complete(env, controller, 'A question', 'A answer'); await controller.create(); const b = controller.current();
  await controller.removeCurrent(); assert.equal(controller.current().id, a.id); assert.equal(controller.hasConfig(), true);
  assert.equal(controller.sessions().some(item => item.id === b.id), false);
  const restarted = env.restart(); await restarted.initialize(); assert.equal(restarted.current().id, a.id);
  assert.deepEqual(restarted.current().messages, pair('A question', 'A answer'));
  await restarted.removeCurrent(); assert.equal(restarted.current(), undefined); assert.equal(restarted.hasConfig(), true);
});

test('回包已进入慢落盘时stop仍等待保存锁完成，不丢成功pair且最终解锁', async () => {
  const env = environment(), controller = await open(env), pending = controller.send('already answered');
  const call = await env.waitForCall(0), gate = { started: deferred(), release: deferred() };
  env.state.flushGate = gate; call.resolve('already received'); await gate.started.promise;
  controller.cancel(); assert.equal(controller.isBusy(), true, '停止网络不应抢先释放正在进行的落盘锁');
  gate.release.resolve(); await pending;
  assert.equal(controller.isBusy(), false); assert.equal(controller.hasUnsavedReply(), false);
  assert.deepEqual(controller.current().messages, pair('already answered', 'already received'));
});

test('未保存回复可在清除凭证后retrySave，正文仍可见且不会触发网络', async () => {
  const env = environment(), controller = await open(env), pending = controller.send('save without key');
  const rejected = assert.rejects(pending, /未存盘/), call = await env.waitForCall(0);
  env.state.failFlush = 1; call.resolve('keep this answer'); await rejected;
  controller.credentialsCleared(); assert.equal(controller.hasConfig(), false); assert.equal(controller.hasUnsavedReply(), true);
  assert.deepEqual(bubbles(controller), [['user', 'save without key'], ['assistant', 'keep this answer']]);
  await controller.retrySave(); assert.equal(env.calls.length, 1); assert.equal(controller.hasUnsavedReply(), false);
  assert.deepEqual(controller.current().messages, pair('save without key', 'keep this answer'));
});

test('initialize主快照损坏时不覆盖数据，修复后同一controller可重新加载', async () => {
  const env = environment(); await env.seed([env.session()]);
  env.disk.get(STORE).set(KEY, '{broken'); const controller = env.controller();
  await assert.rejects(controller.initialize(), /损坏/); assert.equal(env.disk.get(STORE).get(KEY), '{broken');
  assert.equal(controller.current(), undefined); assert.equal(controller.sessions().length, 0);
  await env.seed([env.session({ draft: 'restored after repair' })]);
  await controller.initialize(); assert.equal(controller.current().draft, 'restored after repair');
  assert.equal(controller.hasConfig(), true);
});

test('旧请求迟回包finally不能清除新建会话正在落盘的writeBusy锁', async () => {
  const env = environment(), controller = await open(env);
  const pending = controller.send('obsolete'), late = await env.waitForCall(0);
  controller.cancel();
  const gate = { started: deferred(), release: deferred() }; env.state.flushGate = gate;
  const creating = controller.create(); await gate.started.promise;
  assert.equal(controller.isBusy(), true);
  try {
    late.resolve('obsolete answer'); await pending;
    assert.equal(controller.isBusy(), true, '旧send finally不得释放由create持有的保存锁');
  } finally {
    gate.release.resolve(); await creating;
  }
  assert.equal(controller.isBusy(), false); assert.deepEqual(controller.current().messages, []);
});

test('同base/model不同Key配置切换各自绑定，旧会话/Key保留且重启后不串账号', async () => {
  const env = environment(), controller = await open(env), a = controller.current();
  await complete(env, controller, 'account A question', 'account A answer');
  const profiles = env.profileStore(), bProfile = await profiles.upsert(config({ apiKey: 'sk-account-B' }), 'Account B');
  await controller.reloadProfiles(); await controller.useProfile(bProfile.id);
  const b = controller.current(); assert.notEqual(b.id, a.id); assert.notEqual(b.profileId, a.profileId);
  assert.equal(controller.profiles().length, 2); assert.equal(controller.sessions().length, 2);
  let call = await complete(env, controller, 'account B question', 'account B answer');
  assert.equal(call.config.apiKey, 'sk-account-B'); assert.deepEqual(call.history, []);
  await controller.select(a.id); call = await complete(env, controller, 'account A next', 'account A next answer');
  assert.equal(call.config.apiKey, config().apiKey); assert.deepEqual(call.history, pair('account A question', 'account A answer'));
  const restarted = env.restart(); await restarted.initialize(); await restarted.select(b.id);
  call = await complete(env, restarted, 'account B next', 'account B next answer');
  assert.equal(call.config.apiKey, 'sk-account-B'); assert.deepEqual(call.history, pair('account B question', 'account B answer'));
  assert.equal(restarted.profiles().length, 2); assert.equal(restarted.sessions().length, 2);
});

test('外部删除某profile不删除旧会话或其他Key，绑定失效时拒发而非误用当前账号', async () => {
  const env = environment(), controller = await open(env), a = controller.current();
  await complete(env, controller, 'A private', 'A private answer');
  const profiles = env.profileStore(), bProfile = await profiles.upsert(config({ apiKey: 'sk-account-B' }), 'Account B');
  await controller.reloadProfiles(); await controller.useProfile(bProfile.id); const b = controller.current();
  await profiles.remove(a.profileId); await controller.reloadProfiles();
  await controller.select(a.id);
  await assert.rejects(controller.send('do not leak'), /配置已删除/);
  assert.equal(env.calls.length, 1); assert.deepEqual(controller.current().messages, pair('A private', 'A private answer'));
  assert.equal(controller.sessions().length, 2); assert.equal(controller.profiles().length, 1);
  await controller.select(b.id); const call = await complete(env, controller, 'B still works', 'B reply'); assert.equal(call.config.apiKey, 'sk-account-B');
});

test('旧无profileId会话匹配唯一配置可发送，多套同绑定时拒绝猜Key，显式选择后只绑定此会话', async () => {
  const env = environment(); await env.seed([env.session()]);
  const controller = env.controller(); await controller.initialize();
  const profileStore = env.profileStore(), second = await profileStore.upsert(config({ apiKey: 'sk-second' }));
  await controller.reloadProfiles();
  await assert.rejects(controller.send('ambiguous'), /多套匹配配置/); assert.equal(env.calls.length, 0);
  await controller.useProfile(second.id); assert.equal(controller.current().id, 'local-seeded');
  assert.equal(controller.current().profileId, second.id); assert.equal(controller.sessions().length, 1);
  const call = await complete(env, controller, 'explicit account', 'explicit answer');
  assert.equal(call.config.apiKey, 'sk-second'); assert.deepEqual(call.history, pair('old question', 'old answer'));
});

test('profile地址或model原位变更不得向新绑定发旧history，选新profile会新建保留旧会话', async () => {
  const env = environment(), controller = await open(env), a = controller.current();
  await complete(env, controller, 'old confidential', 'old answer');
  const profiles = env.profileStore(); await profiles.upsert(config({ baseUrl: 'https://new.example/v1', model: 'new-model' }), '', a.profileId);
  await controller.reloadProfiles(); await assert.rejects(controller.send('blocked'), /地址或模型已修改/);
  assert.equal(env.calls.length, 1); await controller.useProfile(a.profileId);
  assert.notEqual(controller.current().id, a.id); assert.deepEqual(controller.current().messages, []);
  assert.equal(controller.sessions().length, 2); assert.deepEqual(controller.sessions().find(s => s.id === a.id).messages, pair('old confidential', 'old answer'));
});

test('切换profile取消旧请求，迟回包不污染新profile会话，也不会删旧草稿', async () => {
  const env = environment(), controller = await open(env), a = controller.current();
  const profiles = env.profileStore(), bProfile = await profiles.upsert(config({ apiKey: 'sk-B' })); await controller.reloadProfiles();
  const pending = controller.send('pending A'), late = await env.waitForCall(0);
  await controller.useProfile(bProfile.id); const b = controller.current();
  assert.equal(late.canceled, true); assert.notEqual(b.id, a.id);
  late.resolve('obsolete reply'); await pending;
  assert.equal(controller.current().id, b.id); assert.deepEqual(controller.current().messages, []);
  assert.equal(controller.sessions().find(s => s.id === a.id).draft, 'pending A'); assert.equal(controller.profiles().length, 2);
});

test('并发useProfile双击在慢select期间拒绝第二次，配置与新会话profileId始终一致', async () => {
  const env = environment(), controller = await open(env), a = controller.current(), profiles = env.profileStore();
  const b = await profiles.upsert(config({ apiKey: 'sk-B' }), 'B'), c = await profiles.upsert(config({ apiKey: 'sk-C' }), 'C');
  await controller.reloadProfiles(); const gate = { started: deferred(), release: deferred() }; env.state.flushGate = gate;
  const switching = controller.useProfile(b.id); await gate.started.promise;
  try {
    assert.equal(controller.isBusy(), true);
    await assert.rejects(controller.useProfile(c.id), /保存.*切换 API/);
    await assert.rejects(controller.create(), /正在保存/); await assert.rejects(controller.select(a.id), /正在保存/);
  } finally { gate.release.resolve(); await switching; }
  assert.equal(controller.isBusy(), false); assert.equal(controller.current().profileId, b.id);
  assert.equal(controller.activeProfileId(), b.id); assert.equal(env.profileSnapshot().selectedId, b.id);
  const call = await complete(env, controller, 'B request', 'B answer'); assert.equal(call.config.apiKey, 'sk-B');
  assert.equal(controller.profiles().length, 3); assert.equal(controller.sessions().length, 2);
});

test('未保存回复时useProfile拒绝且不改变选中Key，retrySave不重发再可切换', async () => {
  const env = environment(), controller = await open(env), a = controller.current(), profiles = env.profileStore();
  const b = await profiles.upsert(config({ apiKey: 'sk-B' })); await controller.reloadProfiles();
  const pending = controller.send('charged once'), rejected = assert.rejects(pending, /未存盘/), call = await env.waitForCall(0);
  env.state.failFlush = 1; call.resolve('valuable response'); await rejected;
  const selectedBefore = env.profileSnapshot().selectedId;
  await assert.rejects(controller.useProfile(b.id), /保存.*切换 API/);
  assert.equal(controller.current().id, a.id); assert.equal(env.profileSnapshot().selectedId, selectedBefore);
  assert.equal(controller.hasUnsavedReply(), true); assert.equal(env.calls.length, 1);
  await controller.retrySave(); await controller.useProfile(b.id);
  assert.equal(controller.current().profileId, b.id); assert.equal(env.calls.length, 1);
  assert.deepEqual(controller.sessions().find(s => s.id === a.id).messages, pair('charged once', 'valuable response'));
});

test('controller事件是独立本地气泡，返回副本不允许外部修改history，磁盘不含apiKey', async () => {
  const env = environment(), controller = await open(env); await complete(env, controller, 'local input', 'local answer');
  const session = controller.current(); session.messages[0].content = 'mutated';
  const list = controller.sessions(); list[0].messages.length = 0;
  assert.equal(controller.current().messages.length, 2); assert.equal(controller.current().messages[0].content, 'local input');
  const events = controller.events(); assert.deepEqual(events.map(item => item.kind), ['user', 'assistant']);
  assert.ok(events.every(item => item.sessionId.startsWith('local-'))); assert.ok(events.every(item => Number.isFinite(item.t)));
  assert.equal(JSON.stringify(env.snapshot()).includes(config().apiKey), false);
  for (const session of env.snapshot().sessions) assert.equal(Object.hasOwn(session, 'apiKey'), false);
});
