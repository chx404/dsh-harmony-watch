import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { randomBytes, createCipheriv, createDecipheriv } from 'node:crypto';
import ts from 'typescript';

const source = await readFile(new URL('../watch-app/entry/src/main/ets/common/DirectApi.ets', import.meta.url), 'utf8');
const localSource = await readFile(new URL('../watch-app/entry/src/main/ets/common/LocalChat.ets', import.meta.url), 'utf8');
const js = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }, reportDiagnostics: true
}).outputText;
const config = (overrides = {}) => ({ baseUrl: 'https://api.example.com/v1', apiKey: 'sk-private-test-only', model: 'test-model', protocol: 'chat', ...overrides });

function environment() {
  const calls = [], timers = new Map(), values = new Map(), sessions = new Map();
  let timerId = 0, sessionId = 0, generated = false;
  const master = randomBytes(32);
  const state = { unsupported: false, syncHttpError: false, destroyed: 0, writes: [], generated: 0 };
  const tags = { HUKS_TAG_ALGORITHM: 1, HUKS_TAG_KEY_SIZE: 2, HUKS_TAG_PURPOSE: 3, HUKS_TAG_BLOCK_MODE: 4, HUKS_TAG_PADDING: 5, HUKS_TAG_NONCE: 6, HUKS_TAG_ASSOCIATED_DATA: 7, HUKS_TAG_AE_TAG: 8 };
  const property = (options, tag) => options.properties.find(item => item.tag === tag)?.value;
  const huks = {
    HuksTag: tags, HuksKeyAlg: { HUKS_ALG_AES: 20 }, HuksKeySize: { HUKS_AES_KEY_SIZE_256: 256 },
    HuksKeyPurpose: { HUKS_KEY_PURPOSE_ENCRYPT: 1, HUKS_KEY_PURPOSE_DECRYPT: 2 },
    HuksCipherMode: { HUKS_MODE_GCM: 32 }, HuksKeyPadding: { HUKS_PADDING_NONE: 0 },
    async isKeyItemExist() { if (state.unsupported) throw Error('HUKS unavailable'); return generated; },
    async generateKeyItem() { generated = true; state.generated++; },
    async initSession(alias, options) { const handle = ++sessionId; sessions.set(handle, options); return { handle }; },
    async finishSession(handle, options) {
      const initial = sessions.get(handle); sessions.delete(handle);
      const nonce = property(initial, tags.HUKS_TAG_NONCE);
      const aad = property(initial, tags.HUKS_TAG_ASSOCIATED_DATA);
      if (property(initial, tags.HUKS_TAG_PURPOSE) === 1) {
        const cipher = createCipheriv('aes-256-gcm', master, nonce); cipher.setAAD(aad);
        return { outData: new Uint8Array(Buffer.concat([cipher.update(options.inData), cipher.final(), cipher.getAuthTag()])) };
      }
      const decipher = createDecipheriv('aes-256-gcm', master, nonce); decipher.setAAD(aad);
      decipher.setAuthTag(property(initial, tags.HUKS_TAG_AE_TAG));
      return { outData: new Uint8Array(Buffer.concat([decipher.update(options.inData), decipher.final()])) };
    },
    async abortSession(handle) { sessions.delete(handle); }
  };
  const prefs = {
    async get(key, fallback) { return values.get(key) ?? fallback; },
    async put(key, value) { state.writes.push({ key, value }); values.set(key, value); },
    async delete(key) { values.delete(key); }, async flush() {}
  };
  const http = {
    RequestMethod: { POST: 'POST' }, HttpDataType: { STRING: 0 },
    createHttp() {
      return {
        request(endpoint, options, callback) {
          if (state.syncHttpError) throw Error('native internal details sk-private-test-only');
          calls.push({ endpoint, options, callback });
        },
        destroy() { state.destroyed++; }
      };
    }
  };
  const util = {
    TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } },
    TextDecoder: class { decodeWithStream(data) { return new TextDecoder().decode(data); } },
    Base64Helper: class { encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); } decodeSync(text) { return new Uint8Array(Buffer.from(text, 'base64')); } }
  };
  const dependencies = {
    '@ohos.net.http': http, '@ohos.url': { URL }, '@ohos.data.preferences': { async getPreferences() { return prefs; } },
    '@ohos.security.huks': huks, '@ohos.security.cryptoFramework': { createRandom() { return { generateRandomSync(n) { return { data: new Uint8Array(randomBytes(n)) }; } }; } },
    '@ohos.util': util
  };
  function load() {
    const module = { exports: {} };
    new Function('module', 'exports', 'require', 'setTimeout', 'clearTimeout', js)(
      module, module.exports, name => {
        assert.ok(dependencies[name], `unexpected dependency: ${name}`); return { default: dependencies[name] };
      },
      (callback, delay) => { const id = ++timerId; timers.set(id, { callback, delay }); return id; },
      id => timers.delete(id)
    );
    return module.exports;
  }
  function reply(index = calls.length - 1, text = 'hello', status = 200) {
    calls[index].callback(null, { responseCode: status, result: JSON.stringify({ choices: [{ message: { role: 'assistant', content: text } }] }) });
  }
  return { api: load(), load, calls, timers, values, state, reply };
}

test('HTTPS API 根地址与完整 endpoint 均规范化且不重复后缀', () => {
  const { api } = environment();
  for (const suffix of ['', '/', '/chat/completions', '/responses/', '/responses/chat/completions']) {
    assert.equal(api.directEndpoint(config({ baseUrl: 'https://API.example.com/v1' + suffix })), 'https://api.example.com/v1/chat/completions');
    assert.equal(api.directEndpoint(config({ baseUrl: 'https://API.example.com/v1' + suffix, protocol: 'responses' })), 'https://api.example.com/v1/responses');
  }
});

test('拒绝 HTTP、内嵌凭证、空凭证@、query/hash、反斜杠与畸形 URL', () => {
  const { api } = environment();
  for (const baseUrl of ['http://api.example.com', 'https://u:p@api.example.com', 'https://@api.example.com', 'https://api.example.com?v=1', 'https://api.example.com#', 'https://api.example.com?', 'https://api.example.com\\evil', 'file:///tmp', 'https:///']) {
    assert.throws(() => api.directEndpoint(config({ baseUrl })), undefined, baseUrl);
  }
});

test('Key/model/protocol 校验阻止请求头注入，错误不回显 secret', () => {
  const { api } = environment();
  for (const changes of [{ apiKey: '' }, { apiKey: 'secret\r\nAuthorization:x' }, { apiKey: 'a b' }, { model: '' }, { model: 'bad\nmodel' }, { protocol: 'unknown' }]) {
    assert.throws(() => api.validateDirectConfig(config(changes)));
  }
  assert.equal(api.validateDirectConfig(config({ model: ' test-model ', apiKey: ' sk-private-test-only ' })).model, 'test-model');
});

test('chat/responses 请求只携带有界历史与一次当前消息，不含 Key', () => {
  const { api } = environment();
  const history = [{ role: 'user', content: 'old' }, { role: 'assistant', content: 'answer' }];
  const chat = JSON.parse(api.directRequestBody(config(), history, ' new '));
  assert.deepEqual(chat.messages.map(x => x.content), ['old', 'answer', 'new']);
  assert.equal(chat.stream, false); assert.ok(!JSON.stringify(chat).includes(config().apiKey));
  const responses = JSON.parse(api.directRequestBody(config({ protocol: 'responses' }), history, 'new'));
  assert.deepEqual(responses.input, chat.messages); assert.equal(responses.store, false); assert.equal(responses.stream, false);
  for (const text of ['', ' '.repeat(4), 'x'.repeat(2001)]) assert.throws(() => api.directRequestBody(config(), [], text));
});

test('解析两种非流式文本响应，忽略推理/工具输出并限制回复长度', () => {
  const { api } = environment();
  assert.equal(api.parseDirectReply('{"choices":[{"message":{"content":"chat reply"}}]}', 'chat'), 'chat reply');
  assert.equal(api.parseDirectReply(JSON.stringify({ output: [
    { type: 'reasoning', content: [{ type: 'output_text', text: 'private' }] },
    { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'hello' }, { type: 'output_text', text: ' world' }] }
  ] }), 'responses'), 'hello world');
  assert.equal(api.parseDirectReply('{"output_text":"compat reply"}', 'responses'), 'compat reply');
  assert.throws(() => api.parseDirectReply('{"status":"incomplete","output_text":"partial"}', 'responses'));
  for (const raw of ['null', '[]', '{broken', '{}']) assert.throws(() => api.parseDirectReply(raw, 'chat'));
  assert.ok(api.parseDirectReply(JSON.stringify({ output_text: 'x'.repeat(13000) }), 'responses').length < 12100);
});

test('历史只保留完整对，限制 12 条 / 24000 字，不改变原数组', () => {
  const { api } = environment();
  const history = Array.from({ length: 40 }, (_, i) => ({ role: i % 2 ? 'assistant' : 'user', content: 'x'.repeat(i % 2 ? 5000 : 1500) }));
  const bounded = api.boundedDirectHistory(history);
  assert.ok(bounded.length <= 12); assert.equal(bounded.length % 2, 0);
  assert.ok(bounded.reduce((sum, m) => sum + m.content.length, 0) <= 24000); assert.equal(history.length, 40);
  assert.deepEqual(api.boundedDirectHistory([{ role: 'user', content: 'uncommitted' }]), []);
});

test('独立 HTTP 只调用选定 API，Key 只在 Authorization；请求结束销毁', async () => {
  const env = environment(), client = new env.api.DirectApiClient();
  const pending = client.send(config(), [], 'hi');
  const call = env.calls[0];
  assert.equal(call.endpoint, 'https://api.example.com/v1/chat/completions');
  assert.equal(call.options.header.Authorization, 'Bearer ' + config().apiKey);
  assert.ok(!call.endpoint.includes(config().apiKey)); assert.ok(!call.options.extraData.includes(config().apiKey));
  assert.equal(call.options.usingCache, false); assert.equal(call.options.maxLimit, 262144);
  assert.equal(call.options.connectTimeout, 15000); assert.equal(call.options.readTimeout, 60000);
  env.reply(); assert.equal(await pending, 'hello'); assert.equal(env.state.destroyed, 1); assert.equal(env.timers.size, 0);
});

test('重复提交被拒绝；取消销毁且拒绝迟回包，立即重试不提交重复历史', async () => {
  const env = environment(), conversation = new env.api.DirectConversation();
  const first = conversation.send(config(), 'question');
  await assert.rejects(conversation.send(config(), 'duplicate'), /等待/); assert.equal(env.calls.length, 1);
  const rejected = assert.rejects(first, /停止/); conversation.cancel(); await rejected;
  assert.equal(env.state.destroyed, 1); assert.deepEqual(conversation.messages(), []);
  const retry = conversation.send(config(), 'question');
  env.reply(0, 'late reply'); assert.deepEqual(conversation.messages(), []);
  assert.deepEqual(JSON.parse(env.calls[1].options.extraData).messages, [{ role: 'user', content: 'question' }]);
  env.reply(1, 'fresh reply'); assert.equal(await retry, 'fresh reply');
  assert.deepEqual(conversation.messages().map(x => x.content), ['question', 'fresh reply']);
});

test('HTTP 失败、超时和同步异常不泄漏响应/Key，不污染历史，可重试', async () => {
  const env = environment(), conversation = new env.api.DirectConversation();
  const first = conversation.send(config(), 'question');
  const failure = assert.rejects(first, /鉴权失败/); env.reply(0, config().apiKey, 401); await failure;
  assert.deepEqual(conversation.messages(), []);
  const second = conversation.send(config(), 'question');
  const timeout = assert.rejects(second, /超时/);
  [...env.timers.values()][0].callback(); await timeout;
  assert.equal(env.timers.size, 0); assert.deepEqual(conversation.messages(), []);
  env.state.syncHttpError = true;
  await assert.rejects(conversation.send(config(), 'question'), error => !error.message.includes(config().apiKey) && /直连失败/.test(error.message));
  assert.equal(env.timers.size, 0); env.state.syncHttpError = false;
  const retry = conversation.send(config(), 'question'); env.reply(); await retry;
  assert.equal(conversation.messages().length, 2);
});

test('reset 清空历史且使旧请求失效；新 API 不继承旧对话', async () => {
  const env = environment(), conversation = new env.api.DirectConversation();
  const first = conversation.send(config(), 'first'); env.reply(); await first;
  const pending = conversation.send(config(), 'second');
  const stopped = assert.rejects(pending, /停止/); conversation.reset(); await stopped;
  const fresh = conversation.send(config({ baseUrl: 'https://new.example.com/v2' }), 'new');
  assert.equal(env.calls[2].endpoint, 'https://new.example.com/v2/chat/completions');
  assert.equal(JSON.parse(env.calls[2].options.extraData).messages.length, 1);
  env.reply(1, 'late'); env.reply(2, 'new answer'); await fresh;
  assert.deepEqual(conversation.messages().map(x => x.content), ['new', 'new answer']);
});

test('HUKS AES-GCM 加密整个配置，preferences 无明文，随机 nonce，重新加载可解密', async () => {
  const env = environment(), store = new env.api.DirectConfigStore({});
  const saved = await store.save(config()); assert.equal(saved.persistent, true);
  const first = JSON.parse(env.values.get('sealed'));
  for (const entry of env.state.writes) {
    assert.equal(entry.key, 'sealed');
    assert.ok(!entry.value.includes(config().apiKey)); assert.ok(!entry.value.includes(config().model)); assert.ok(!entry.value.includes(config().baseUrl));
  }
  assert.equal(Buffer.from(first.nonce, 'base64').length, 12);
  const reload = new (env.load().DirectConfigStore)({});
  assert.deepEqual((await reload.load()).config, config());
  await store.save(config()); assert.notEqual(JSON.parse(env.values.get('sealed')).nonce, first.nonce);
  assert.equal(env.state.generated, 1);
  await store.clear(); assert.equal(env.values.size, 0); assert.equal((await store.load()).config, undefined);
});

test('GCM 密文篡改无法恢复配置，不会明文降级', async () => {
  const env = environment(), store = new env.api.DirectConfigStore({});
  await store.save(config());
  const envelope = JSON.parse(env.values.get('sealed'));
  const bytes = Buffer.from(envelope.data, 'base64'); bytes[0] ^= 1; envelope.data = bytes.toString('base64');
  env.values.set('sealed', JSON.stringify(envelope));
  const loaded = await store.load(); assert.equal(loaded.config, undefined); assert.equal(loaded.persistent, false);
  assert.match(loaded.notice, /安全存储不可用或配置已失效/);
});

test('设备不支持 HUKS 时明确仅 App 进程内保存，退出进程不恢复，不写明文', async () => {
  const env = environment(); env.state.unsupported = true;
  const store = new env.api.DirectConfigStore({});
  const saved = await store.save(config()); assert.equal(saved.persistent, false); assert.match(saved.notice, /仅本次 App 进程保存/);
  assert.equal(env.values.size, 0); assert.equal(env.state.writes.length, 0);
  assert.deepEqual((await store.load()).config, config());
  assert.equal((await new (env.load().DirectConfigStore)({}).load()).config, undefined);
  await store.clear(); assert.equal((await store.load()).config, undefined);
});

test('二维码遵守真实 /configure#ticket 契约，仅含一次性随机票据', () => {
  const { api } = environment(), id = 'a'.repeat(43), now = 1000;
  const link = api.directProvisionQrLink('http://192.168.1.2:8765/', '/configure#' + id, id, now + 300000, now);
  assert.equal(link, 'http://192.168.1.2:8765/configure#' + id);
  assert.equal(new URL(link).search, ''); assert.equal(new URL(link).hash, '#' + id);
  assert.equal(api.normalizeDirectProvisionHost('192.168.1.2:8765/'), 'http://192.168.1.2:8765');
  for (const path of ['/configure', '/configure?token=long-term#' + id, '//evil.example/configure#' + id, '/configure#other', '/other#' + id]) {
    assert.throws(() => api.directProvisionQrLink('https://host.example', path, id, now + 10, now));
  }
  assert.throws(() => api.directProvisionQrLink('https://host.example', '/configure#' + id, id, now, now));
  for (const host of ['https://u:p@host.example', 'https://host.example/path', 'https://host.example?token=x', 'https://host.example#x']) {
    assert.throws(() => api.directProvisionQrLink(host, '/configure#' + id, id, now + 10, now));
  }
});

test('UI 接线安全：隐藏Key、后台/销毁停止、导入仅填草稿、手动保存清历史、圆屏和表冠', () => {
  assert.match(localSource, /\.type\(InputType.Password\)\.showPasswordIcon\(false\)\.showPassword\(false\)/);
  assert.match(localSource, /copyOption\(CopyOptions.None\)\.enableAutoFill\(false\)/);
  assert.match(localSource, /@StorageLink\('appInBackground'\) @Watch\('backgroundChanged'\)/);
  assert.match(localSource, /backgroundChanged\(\)[\s\S]*?this.stopProvision\(\);[\s\S]*?this.stopSend\(\);/);
  assert.match(localSource, /aboutToDisappear\(\)[\s\S]*?this.conversation.cancel\(\);[\s\S]*?this.stopProvision\(\);/);
  assert.match(localSource, /directProvisionQrLink\(base, ticket.pagePath, ticket.id, ticket.expiresAt\)/);
  assert.match(localSource, /this.fillDraft\(checked\);[\s\S]*?this.imported = true;[\s\S]*?尚未启用/);
  assert.match(localSource, /保存并新建/); assert.match(localSource, /this.conversation.reset\(\);/);
  assert.match(localSource, /Scroll\(this.settingsScroll\)/); assert.match(localSource, /\.onDigitalCrown/);
  assert.match(localSource, /requestFocus\('direct-crown-' \+ this.page\)/);
  assert.match(localSource, /仅配置时需宿主；聊天由手表直连/); assert.match(localSource, /同一可信 WiFi/);
  assert.doesNotMatch(source, /console\.|hilog\.|from ['"]\.\/Net/);
});
