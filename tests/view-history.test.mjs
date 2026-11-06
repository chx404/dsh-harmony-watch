import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';
const common = new URL('../watch-app/entry/src/main/ets/common/', import.meta.url);
const source = await readFile(new URL('ViewHistory.ets', common), 'utf8');
const module = { exports: {} };
new Function('module', 'exports', ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText)(module, module.exports);
const { ViewHistory, isWatchBackSwipe } = module.exports;
const at = (view, page = 1) => ({ view, page });

test('菜单进入设置/诊断后逐级回来源，而不是一律主聊天', () => {
  const h = new ViewHistory();
  h.record(at('main', 0), at('settings'));
  h.record(at('settings'), at('diagnostics'));
  assert.deepEqual(h.pop(), at('settings'));
  assert.deepEqual(h.pop(), at('main', 0));
  assert.equal(h.pop(), undefined);
});
test('会话切入主聊天后可以回列表，再回原菜单', () => {
  const h = new ViewHistory();
  h.record(at('main', 0), at('sessions'));
  h.record(at('sessions'), at('main', 1));
  assert.deepEqual(h.pop(), at('sessions'));
  assert.deepEqual(h.pop(), at('main', 0));
});
test('相同页面不堆栈，横向页区分，历史有界且拷贝不可污染', () => {
  const h = new ViewHistory();
  h.record(at('settings'), at('settings', 2)); assert.equal(h.size(), 0);
  const location = at('main', 2); h.record(location, at('sessions')); location.page = 0;
  assert.deepEqual(h.pop(), at('main', 2));
  for (let i = 0; i < 70; i++) h.record(at('p' + i), at('p' + (i + 1)));
  assert.equal(h.size(), 32); h.clear(); assert.equal(h.size(), 0);
});
test('右滑阈值按屏幕缩放；左边缘、纵滑、左滑和编辑光标不抢', () => {
  assert.equal(isWatchBackSwipe(80, 70, 5, 233, false), true);
  for (const input of [[5, 100, 0, 233, false], [80, -70, 0, 233, false], [80, 49, 0, 233, false], [80, 70, 50, 233, false], [80, 70, 0, 233, true]]) {
    assert.equal(isWatchBackSwipe(...input), false);
  }
  assert.equal(isWatchBackSwipe(40, 35, 3, 116.5, false), true);
});

const page = await readFile(new URL('../watch-app/entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
function extract(name) {
  const match = new RegExp('\\n  (?:private )?(?:async )?' + name + '\\(').exec(page);
  assert.ok(match, name);
  const start = match.index + 1, body = page.indexOf('{', start);
  let depth = 0, quote = '', line = false, block = false;
  for (let i = body; i < page.length; i++) {
    const c = page[i], n = page[i + 1];
    if (line) { if (c === '\n') line = false; continue; }
    if (block) { if (c === '*' && n === '/') { block = false; i++; } continue; }
    if (quote) { if (c === '\\') i++; else if (c === quote) quote = ''; continue; }
    if (c === '/' && n === '/') { line = true; i++; continue; }
    if (c === '/' && n === '*') { block = true; i++; continue; }
    if (c === "'" || c === '"' || c === '`') { quote = c; continue; }
    if (c === '{') depth++;
    if (c === '}' && --depth === 0) return page.slice(start, i + 1);
  }
  throw Error('unclosed ' + name);
}
const js = ts.transpileModule(`class Harness { ${['requestBack', 'backScene', 'restoreLocation', 'animateReturn', 'isBackSurface', 'onBackPress'].map(extract).join('\n')} }`, { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText;
function fixture() {
  let now = 1000; const calls = [];
  const Harness = new Function('Date', 'animateTo', 'Curve', js + ';return Harness;')({ now: () => now },
    (options, action) => { calls.push('animate:' + options.duration); action(); options.onFinish?.(); },
    { EaseIn: 'in', EaseOut: 'out' });
  const h = new Harness();
  Object.assign(h, { bootReady: true, lastBackAt: 0, editingInput: false, showPrompt: false, showModels: false, showGuide: false,
    localBackRequest: 0, view: 'settings', token: 'paired', chatKind: 'dsh', viewHistory: new ViewHistory(),
    resetChatChrome() {}, px: value => value, resetCrown() { calls.push('reset'); }, focusLocation() {}, swiper: { changeIndex(i, animation) { calls.push([i, animation]); } },
    closePrompt() { this.showPrompt = false; calls.push('prompt'); }, closeModels() { this.showModels = false; calls.push('models'); },
    finishGuide() { this.showGuide = false; calls.push('guide'); }, flushLocalDraft: async () => {},
    getUIContext: () => ({ getFocusController: () => ({ clearFocus() { calls.push('blur'); } }) }), toast() {} });
  return { h, calls, advance: () => { now += 400; } };
}
test('系统返回恢复菜单初始页和白条位置，不重建成聊天页', () => {
  const { h } = fixture(); h.viewHistory.record(at('main', 0), at('settings'));
  assert.equal(h.onBackPress(), true);
  assert.equal(h.view, 'main'); assert.equal(h.pageIndex, 0); assert.equal(h.swiperInitialIndex, 0); assert.equal(h.slidePos, 0);
  assert.equal(h.sceneX, 0); assert.equal(h.sceneOpacity, 1); assert.equal(h.returnAnimating, false);
});
test('边缘系统back与页内手势重复到达只pop一次', () => {
  const { h, advance } = fixture(); h.viewHistory.record(at('main', 0), at('settings')); h.viewHistory.record(at('settings'), at('diagnostics')); h.view = 'diagnostics';
  h.requestBack(); h.requestBack(); assert.equal(h.view, 'settings'); assert.equal(h.viewHistory.size(), 1);
  advance(); h.requestBack(); assert.equal(h.view, 'main'); assert.equal(h.pageIndex, 0);
});
test('API扫码等内部页面先由子组件消费，不提前pop父页面', () => {
  const { h } = fixture(); h.view = 'local'; h.viewHistory.record(at('sessions'), at('local'));
  h.requestBack(); assert.equal(h.localBackRequest, 1); assert.equal(h.view, 'local'); assert.equal(h.viewHistory.size(), 1);
  h.backScene(); assert.equal(h.view, 'sessions');
});
test('键盘编辑和弹层先退出，根页面才允许系统退出App', () => {
  const { h, calls, advance } = fixture(); h.editingInput = true;
  h.requestBack(); assert.ok(calls.includes('blur')); assert.equal(h.view, 'settings');
  advance(); h.showPrompt = true; h.requestBack(); assert.equal(h.showPrompt, false); assert.equal(h.view, 'settings');
  advance(); h.view = 'main'; assert.equal(h.requestBack(), false);
});
test('页面无返回按钮，主导航和输入编辑保护完整接线', async () => {
  const local = await readFile(new URL('LocalChat.ets', common), 'utf8');
  const menu = await readFile(new URL('CrownMenu.ets', common), 'utf8');
  for (const code of [page, local, menu]) assert.doesNotMatch(code, /(?:Text|Button)\('(?:‹ )?返回'/);
  assert.match(page, /\.index\(this.swiperInitialIndex\)/);
  assert.match(page, /onBackPress\(\)/); assert.match(page, /isWatchBackSwipe\(/);
  assert.match(page, /backRequest: this.localBackRequest/); assert.match(page, /onEditingChanged:/);
  assert.match(page, /if \(newApproval && this.view !== 'approval'/, '同一待审批不能在返回后每次轮询又强制打开');
  assert.match(page, /pend.length === 0 && this.view === 'approval'\) \{\s*this.backScene\(\)/);
  assert.match(menu, /hitTestBehavior\(HitTestMode.None\)/);
  assert.doesNotMatch(menu, /转动表冠，居中放大/);
});
