import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';

const page = await readFile(new URL('../watch-app/entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');

// 运行生产 Index 的方法，不复写模式切换/编辑框同步逻辑；系统与控制器由窄接口替身提供。
function extractMethod(name) {
  const matcher = new RegExp('\\n  (?:private )?(?:async )?' + name + '\\(');
  const match = matcher.exec(page);
  assert.ok(match, `Index method missing: ${name}`);
  const start = match.index + 1;
  const body = page.indexOf('{', start);
  let depth = 0, quote = '', lineComment = false, blockComment = false;
  for (let i = body; i < page.length; i++) {
    const c = page[i], next = page[i + 1];
    if (lineComment) { if (c === '\n') lineComment = false; continue; }
    if (blockComment) { if (c === '*' && next === '/') { blockComment = false; i++; } continue; }
    if (quote) { if (c === '\\') i++; else if (c === quote) quote = ''; continue; }
    if (c === '/' && next === '/') { lineComment = true; i++; continue; }
    if (c === '/' && next === '*') { blockComment = true; i++; continue; }
    if (c === "'" || c === '"' || c === '`') { quote = c; continue; }
    if (c === '{') depth++;
    if (c === '}' && --depth === 0) return page.slice(start, i + 1);
  }
  throw new Error(`Unclosed method ${name}`);
}
const methods = [
  'syncLocalView', 'updatePicker', 'flushLocalDraft', 'changeComposer', 'useDsh',
  'chatEvents', 'chatEventKey', 'chatTitle', 'modelCaption', 'onPageHide', 'configuredLocal',
  'doSend', 'sendPreset', 'pickSession'
].map(extractMethod).join('\n');
const js = ts.transpileModule(`class Harness { ${methods} }`, {
  compilerOptions: { target: ts.ScriptTarget.ES2020 }
}).outputText;

function fixture() {
  const calls = { saved: [], toasts: [], sentLocal: 0, sentDsh: [], main: [], newDsh: 0, cancels: 0, pendingWrites: [] };
  let nextTimer = 0;
  const timers = new Map();
  const Harness = new Function('visibleFeedEvents', 'sendPrompt', 'setTimeout', 'clearTimeout', js + '; return Harness;')(
    events => events.filter(item => item.kind !== 'hidden'),
    async (base, token, text, mode) => { calls.sentDsh.push({ base, token, text, mode }); return { ok: true }; },
    callback => { const id = ++nextTimer; timers.set(id, callback); return id; },
    id => timers.delete(id)
  );
  const h = new Harness();
  const state = { busy: false, unsaved: false, notice: '', draftGate: null,
    session: { id: 'local-a', title: '本地标题', baseUrl: 'https://api.test/v1', model: 'api-model', protocol: 'chat', createdAt: 1, updatedAt: 1, messages: [], draft: '' } };
  const controller = {
    current: () => structuredClone(state.session),
    sessions: () => [structuredClone(state.session)],
    isBusy: () => state.busy,
    status: () => state.notice,
    profiles: () => [], activeProfileId: () => '',
    hasUnsavedReply: () => state.unsaved,
    events: () => [{ seq: 1, sessionId: state.session.id, kind: 'assistant', text: 'only-local' }],
    async saveDraft(text) {
      calls.saved.push({ id: state.session.id, text });
      const operation = (async () => { if (state.draftGate) await state.draftGate; state.session.draft = text; })();
      calls.pendingWrites.push(operation);
      await operation;
    },
    cancel() {
      calls.cancels++;
      if (state.busy) state.notice = '已停止，输入保留在本地草稿；可编辑后重试';
      state.busy = false;
      h.syncLocalView();
    },
    async configured(config) {
      state.session = { ...state.session, id: 'local-configured', model: config.model, draft: '已存草稿' };
      h.syncLocalView();
    }
  };
  Object.assign(h, {
    chatKind: 'local', view: 'main', showPrompt: false, showModels: false, localBusy: false,
    localUnsaved: false, localId: 'local-a', localTitle: '本地标题', localModel: 'api-model',
    localNotice: '', localEvents: [], localSessions: [], sessions: [], pickerItems: [],
    currentSessionId: 'remote-a', localDraftTimer: -1, localUiEpoch: 0,
    promptText: '', dshDraft: 'DSH草稿', token: 'paired', server: 'http://host',
    localController: controller, stopArmed: false,
    toast(text) { calls.toasts.push(text); }, scrollToBottom() {},
    resetChatChrome() {}, resetCrown() {}, requestDelay() {}, rememberChatKind() {}, closePrompt() { this.showPrompt = false; },
    switchView(view) { this.view = view; }, goPage(index) { this.view = 'main'; calls.main.push(index); },
    async sendLocal() { calls.sentLocal++; }, async doNew() { calls.newDsh++; }
  });
  return { h, state, calls, timers, controller };
}

test('本地历史裁剪复用序号时，气泡Key仍跟随内容更新', () => {
  const { h } = fixture();
  const before = { sessionId: 'local-a', seq: 1, kind: 'user', text: '被裁掉的最旧消息' };
  const after = { ...before, text: '裁剪后排在首位的新消息' };
  assert.notEqual(h.chatEventKey(before), h.chatEventKey(after));
  assert.equal(h.chatEventKey(before), h.chatEventKey({ ...before }));
  assert.notEqual(h.chatEventKey(before), h.chatEventKey({ ...before, sessionId: 'remote-a' }));
});

for (const action of ['background', 'switch-dsh']) {
  test(`首次草稿慢flush期间取消再${action}：保留编辑缓冲，不把新输入覆盖为空`, async () => {
    const { h, state, calls, controller } = fixture();
    const input = '这条输入尚在首次草稿落盘中';
    let finishFirst;
    state.draftGate = new Promise(resolve => { finishFirst = resolve; });
    state.busy = true; state.notice = '正在直连 API…';
    h.localBusy = true; h.promptText = input;
    // 与 LocalChatController.send 的草稿 put+flush 未结束时完全一致：store.current 仍是旧草稿。
    assert.equal(controller.current().draft, '');
    let switching;
    if (action === 'background') h.onPageHide();
    else { controller.cancel(); switching = h.useDsh(); }
    assert.equal(h.promptText, input, '取消的 busy->idle 不得用未提交存储覆盖输入框');
    assert.equal(calls.saved[0].text, input, '后台/切换排队保存必须写新输入');
    state.session.draft = input;
    finishFirst();
    await Promise.all(calls.pendingWrites);
    if (switching) await switching;
    assert.equal(state.session.draft, input, '后续保存不得覆盖首次新草稿');
    if (action === 'switch-dsh') { assert.equal(h.chatKind, 'dsh'); assert.equal(h.promptText, 'DSH草稿'); }
  });
}

test('失败或取消回到idle保留输入，只有成功且无未保存回复才清理编辑框', () => {
  const { h, state } = fixture();
  for (const notice of ['API 请求失败', '已停止，输入保留在本地草稿']) {
    h.localBusy = true; h.promptText = '需要保留的输入'; state.busy = false; state.notice = notice; state.session.draft = '';
    h.syncLocalView(); assert.equal(h.promptText, '需要保留的输入');
  }
  h.localBusy = true; h.promptText = '已发送'; state.notice = '';
  h.syncLocalView(); assert.equal(h.promptText, '');
  h.localBusy = true; h.promptText = '未落盘回复的输入'; state.unsaved = true;
  h.syncLocalView(); assert.equal(h.promptText, '未落盘回复的输入');
});

test('编辑面板打开时后台回调不覆盖用户正在编辑的消息', () => {
  const { h, state } = fixture();
  h.showPrompt = true; h.localBusy = true; h.promptText = '正在编辑的新文本'; state.notice = ''; state.busy = false;
  h.syncLocalView(); assert.equal(h.promptText, '正在编辑的新文本');
});

test('主发送按钮与快捷指令按当前来源分流，local绝不调用DSH接口', async () => {
  const { h, calls } = fixture();
  h.promptText = 'local-input'; h.token = '';
  await h.doSend('followup'); await h.sendPreset('继续');
  assert.equal(calls.sentLocal, 2); assert.equal(calls.sentDsh.length, 0);
  h.chatKind = 'dsh'; h.token = 'paired'; h.promptText = 'dsh-input';
  await h.doSend('followup');
  assert.deepEqual(calls.sentDsh, [{ base: 'http://host', token: 'paired', text: 'dsh-input', mode: 'followup' }]);
  assert.equal(calls.sentLocal, 2);
});

test('主聊天事件/标题/模型按来源取值，DSH快照字段变化不混入本地消息', () => {
  const { h } = fixture();
  h.localEvents = [{ sessionId: 'local-a', kind: 'assistant', text: 'local-reply' }];
  h.events = [{ sessionId: 'remote-a', kind: 'assistant', text: 'dsh-reply' }, { kind: 'hidden' }];
  h.title = '远程标题'; h.selectionModel = 'remote-model';
  assert.equal(h.chatEvents()[0].text, 'local-reply'); assert.match(h.chatTitle(), /本地标题/); assert.match(h.modelCaption(), /api-model/);
  h.events[0].text = 'poll-replaced'; h.title = 'DSH轮询新标题';
  assert.equal(h.chatEvents()[0].text, 'local-reply'); assert.match(h.chatTitle(), /本地标题/);
  h.chatKind = 'dsh';
  assert.equal(h.chatEvents().length, 1); assert.equal(h.chatEvents()[0].text, 'poll-replaced'); assert.equal(h.chatTitle(), 'DSH轮询新标题');
});

test('统一会话列表同时包含两个来源与准确当前选中项', () => {
  const { h } = fixture();
  h.localSessions = [{ id: 'local-a', title: '本地标题', model: 'api-model', draft: '草稿' }];
  h.sessions = [{ id: 'remote-a', title: '远程标题', live: true, running: false }];
  h.updatePicker();
  assert.ok(h.pickerItems.some(item => item.key === 'api:local-a' && /本地 API.*草稿/.test(item.caption) && item.title.startsWith('✓')));
  assert.ok(h.pickerItems.some(item => item.key === 'dsh:remote-a' && item.caption.startsWith('DSH')));
  assert.ok(h.pickerItems.some(item => item.key === 'new-local'));
  assert.ok(h.pickerItems.some(item => item.key === 'new-dsh'));
  h.chatKind = 'dsh'; h.updatePicker();
  assert.ok(h.pickerItems.find(item => item.key === 'dsh:remote-a').title.startsWith('✓'));
  assert.ok(!h.pickerItems.find(item => item.key === 'api:local-a').title.startsWith('✓'));
});

test('配置保存回调进入统一主聊天，保留DSH编辑缓冲和新会话草稿', async () => {
  const { h, calls } = fixture();
  h.chatKind = 'dsh'; h.promptText = '原DSH未发送内容';
  await h.configuredLocal({ baseUrl: 'https://api.test/v1', apiKey: 'test-only-key', model: 'new-model', protocol: 'chat' });
  assert.equal(h.chatKind, 'local'); assert.equal(h.view, 'main'); assert.deepEqual(calls.main, [1]);
  assert.equal(h.promptText, '已存草稿'); assert.equal(h.dshDraft, '原DSH未发送内容'); assert.equal(h.localId, 'local-configured');
});

test('未存盘回复拦截切DSH，未配对新DSH不偷偷改变当前来源', async () => {
  const { h, calls } = fixture();
  h.localUnsaved = true;
  await assert.rejects(h.useDsh(), /先保存/);
  assert.equal(h.chatKind, 'local'); assert.equal(calls.cancels, 0); assert.equal(calls.saved.length, 0);
  h.localUnsaved = false; h.token = '';
  await h.pickSession('new-dsh');
  assert.equal(h.chatKind, 'local'); assert.equal(calls.newDsh, 0); assert.match(calls.toasts.at(-1), /先连接/);
});

test('UI将API设置与统一主聊天分离，会话选择器复用圆屏懒列表', () => {
  assert.match(page, /LocalChat\(\{[\s\S]*?settingsOnly: true/);
  assert.match(page, /onConfigured: \(config: DirectApiConfig\) => \{ this.configuredLocal\(config\)/);
  assert.match(page, /ForEach\(this.chatEvents\(\)/);
  assert.match(page, /Text\(this.chatTitle\(\)\)/);
  const sessions = page.slice(page.indexOf('  SessionsView()'));
  assert.match(sessions, /CrownMenu\(/); assert.match(sessions, /items: this.pickerItems/); assert.doesNotMatch(sessions, /showBack: true/);
  assert.match(page, /this.chatKind !== 'local'\) \{\s*this.switchView\('approval'\)/);
});
