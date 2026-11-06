import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import ts from 'typescript';

// Defaults to the repository copy; use the staging ArkTS source before parent sync.
const sourcePath = process.env.CHAT_IMMERSION_SOURCE ||
  new URL('../watch-app/entry/src/main/ets/common/ChatImmersion.ets', import.meta.url);
const source = await readFile(sourcePath, 'utf8');
const transpiled = ts.transpileModule(source, {
  fileName: 'ChatImmersion.ts',
  reportDiagnostics: true,
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
});
assert.deepEqual((transpiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error), []);
const module = { exports: {} };
new Function('module', 'exports', transpiled.outputText)(module, module.exports);
const { ChatChromeController } = module.exports;

function setup() {
  const changes = [];
  const chrome = new ChatChromeController(hidden => changes.push(hidden));
  return { chrome, changes };
}
function drag(chrome) {
  chrome.touchStart(100, 100);
  chrome.touchMove(100, 112);
}

test('初始可见，按下、单击与未按下的 MOVE 均不隐藏', () => {
  const { chrome, changes } = setup();
  assert.equal(chrome.isHidden(), false);
  chrome.touchMove(0, 100);
  chrome.touchStart(10, 20);
  assert.equal(chrome.isHidden(), false);
  chrome.touchEnd();
  chrome.touchEnd();
  chrome.crownEnd();
  assert.deepEqual(changes, []);
});

test('默认纵向阈值包含 6，按起点累计位移而非单帧位移', () => {
  const { chrome, changes } = setup();
  chrome.touchStart(50, 100);
  for (const y of [101, 103, 105.999]) chrome.touchMove(50, y);
  assert.equal(chrome.isHidden(), false);
  chrome.touchMove(50, 106);
  assert.equal(chrome.isHidden(), true);
  assert.deepEqual(changes, [true]);
});

test('自定义纵向阈值生效，两个纵向方向都能触发', () => {
  for (const direction of [-1, 1]) {
    const { chrome, changes } = setup();
    chrome.touchStart(20, 50);
    chrome.touchMove(20, 50 + direction * 11, 12);
    assert.equal(chrome.isHidden(), false);
    chrome.touchMove(20, 50 + direction * 12, 12);
    assert.equal(chrome.isHidden(), true);
    chrome.touchEnd();
    assert.deepEqual(changes, [true, false]);
  }
});

test('横向 Swiper 与 1.2 倍边界斜拖不隐藏', () => {
  for (const [dx, dy] of [[100, 0], [-100, 12], [100, 100], [10, 12], [-10, -12]]) {
    const { chrome, changes } = setup();
    chrome.touchStart(30, 40);
    chrome.touchMove(30 + dx, 40 + dy);
    assert.equal(chrome.isHidden(), false);
    chrome.touchEnd();
    assert.deepEqual(changes, []);
  }
  const { chrome } = setup();
  chrome.touchStart(30, 40);
  chrome.touchMove(40, 52.01);
  assert.equal(chrome.isHidden(), true);
});

test('drag 中重复 MOVE、反向纵滚及回到起点保持隐藏，只回调一次', () => {
  const { chrome, changes } = setup();
  drag(chrome);
  for (const [x, y] of [[100, 120], [100, 101], [100, 70], [100, 100], [200, 100]]) {
    chrome.touchMove(x, y);
    assert.equal(chrome.isHidden(), true);
  }
  assert.deepEqual(changes, [true]);
  chrome.touchEnd();
  assert.deepEqual(changes, [true, false]);
});

for (const event of ['UP', 'Cancel']) {
  test(`${event} 由父层映射 touchEnd，松手立即恢复且惯性迟 MOVE 无效`, () => {
    const { chrome, changes } = setup();
    drag(chrome);
    chrome.touchEnd();
    assert.equal(chrome.isHidden(), false);
    chrome.touchMove(100, 200);
    chrome.touchMove(100, -200);
    chrome.touchEnd();
    assert.deepEqual(changes, [true, false]);
  });
}

test('END 后新的按下必须重新越过阈值，旧位移不沿用', () => {
  const { chrome, changes } = setup();
  drag(chrome);
  chrome.touchEnd();
  chrome.touchStart(400, 500);
  chrome.touchMove(400, 505);
  assert.equal(chrome.isHidden(), false);
  chrome.touchEnd();
  assert.deepEqual(changes, [true, false]);
});

test('表冠 UPDATE 隐藏，重复 UPDATE 不反复回调，END 恢复', () => {
  const { chrome, changes } = setup();
  for (let i = 0; i < 20; i++) chrome.crownUpdate();
  assert.equal(chrome.isHidden(), true);
  assert.deepEqual(changes, [true]);
  chrome.crownEnd();
  chrome.crownEnd();
  assert.equal(chrome.isHidden(), false);
  assert.deepEqual(changes, [true, false]);
});

test('手指与表冠相交：先松手仍隐藏，表冠结束后恢复', () => {
  const { chrome, changes } = setup();
  drag(chrome);
  chrome.crownUpdate();
  chrome.touchEnd();
  assert.equal(chrome.isHidden(), true);
  assert.deepEqual(changes, [true]);
  chrome.crownEnd();
  assert.deepEqual(changes, [true, false]);
});

test('手指与表冠相交：表冠先结束仍隐藏，手指结束后恢复', () => {
  const { chrome, changes } = setup();
  drag(chrome);
  chrome.crownUpdate();
  chrome.crownEnd();
  assert.equal(chrome.isHidden(), true);
  chrome.touchEnd();
  assert.deepEqual(changes, [true, false]);
});

test('touchStart 接管清除旧表冠，迟 crownEnd 不打断新的拖动', () => {
  const { chrome, changes } = setup();
  chrome.crownUpdate();
  chrome.touchStart(100, 100);
  assert.equal(chrome.isHidden(), false);
  chrome.touchMove(100, 112);
  chrome.crownEnd();
  assert.equal(chrome.isHidden(), true);
  chrome.touchEnd();
  assert.deepEqual(changes, [true, false, true, false]);
});

test('仅按下未拖动不算活动隐藏源，期间新表冠结束即可恢复', () => {
  const { chrome, changes } = setup();
  chrome.touchStart(0, 0);
  chrome.crownUpdate();
  chrome.crownEnd();
  assert.equal(chrome.isHidden(), false);
  chrome.touchEnd();
  assert.deepEqual(changes, [true, false]);
});

test('新的 touchStart 清旧 drag，不能沿用上一轮的隐藏或起点', () => {
  const { chrome, changes } = setup();
  drag(chrome);
  chrome.touchStart(500, 600);
  assert.equal(chrome.isHidden(), false);
  chrome.touchMove(501, 605);
  chrome.touchEnd();
  assert.deepEqual(changes, [true, false]);
});

test('reset 清所有源并恢复，迟 MOVE/END 不会再次隐藏', () => {
  const { chrome, changes } = setup();
  drag(chrome);
  chrome.crownUpdate();
  chrome.reset();
  assert.equal(chrome.isHidden(), false);
  chrome.touchMove(100, 500);
  chrome.crownEnd();
  chrome.touchEnd();
  chrome.reset();
  assert.deepEqual(changes, [true, false]);
  drag(chrome);
  chrome.touchEnd();
  chrome.crownUpdate();
  chrome.crownEnd();
  assert.deepEqual(changes, [true, false, true, false, true, false]);
});

test('可见时 reset 不回调，也取消尚未越阈值的按下', () => {
  const { chrome, changes } = setup();
  chrome.touchStart(0, 0);
  chrome.reset();
  chrome.touchMove(0, 50);
  chrome.touchEnd();
  assert.equal(chrome.isHidden(), false);
  assert.deepEqual(changes, []);
});

// Static wiring checks follow the same source tree as CHAT_IMMERSION_SOURCE.
const indexPath = process.env.CHAT_IMMERSION_SOURCE ?
  resolve(dirname(process.env.CHAT_IMMERSION_SOURCE), '../pages/Index.ets') :
  new URL('../watch-app/entry/src/main/ets/pages/Index.ets', import.meta.url);
const page = await readFile(indexPath, 'utf8');
function method(name) {
  const start = page.indexOf(`private ${name}(`);
  assert.ok(start >= 0, `missing Index method ${name}`);
  const end = page.indexOf('\n  private ', start + 1);
  return page.slice(start, end < 0 ? undefined : end);
}

test('Index 按下/MOVE/UP/Cancel 接真实控制器，松手不受页面或 touches 数组拦截', () => {
  assert.match(page, /import \{ ChatChromeController \} from '\.\.\/common\/ChatImmersion'/);
  assert.match(page, /new ChatChromeController\(\(hidden: boolean\) => \{ this\.animateChatChrome\(hidden\); \}\)/);
  const touch = method('handleChatTouch');
  assert.match(touch, /TouchType\.Up\s*\|\|\s*event\.type === TouchType\.Cancel\)\s*\{ this\.chatChrome\.touchEnd\(\); return; \}/);
  assert.ok(touch.indexOf('this.chatChrome.touchEnd()') < touch.indexOf('!this.canImmerseChat()'));
  assert.match(touch, /TouchType\.Down[\s\S]*this\.chatChrome\.touchStart\(point\.x, point\.y\)/);
  assert.match(touch, /TouchType\.Move[\s\S]*this\.chatChrome\.touchMove\(point\.x, point\.y, this\.px\(6\)\)/);
  assert.match(page, /\.onTouch\(\(event: TouchEvent\) => \{ this\.handleChatTouch\(event\); \}\)/);
});

test('Index 只接受聊天页非零表冠 UPDATE，END 与 quiet timer 均恢复', () => {
  const allowed = method('canImmerseChat');
  assert.match(allowed, /this\.view === 'main' && this\.pageIndex === 1/);
  for (const guard of ['!this.showPrompt', '!this.showModels', '!this.showGuide', 'this.pageVisible']) {
    assert.ok(allowed.includes(guard), `missing guard ${guard}`);
  }
  const crown = method('handleChatCrown');
  assert.match(crown, /CrownAction\.END\)\s*\{ this\.finishChatCrown\(\); return; \}/);
  assert.match(crown, /event\.action !== CrownAction\.UPDATE \|\| event\.degree === 0 \|\| !this\.canImmerseChat\(\)/);
  assert.ok(crown.indexOf('event.action !== CrownAction.UPDATE') < crown.indexOf('this.chatChrome.crownUpdate()'));
  assert.match(crown, /setTimeout\([\s\S]*this\.chatChrome\.crownEnd\(\)/);
  assert.match(method('finishChatCrown'), /clearTimeout[\s\S]*this\.chatChrome\.crownEnd\(\)/);
  assert.match(method('resetChatChrome'), /clearTimeout[\s\S]*this\.chatChrome\.reset\(\)/);
  assert.match(method('handleCrown'), /target === this\.scroller\)\s*\{ this\.handleChatCrown\(event\); \}/);
});

test('Index 上下控件仅独立淡出平移，List 不随隐藏改尺寸，滚动与 Swiper 不触发隐藏', () => {
  assert.match(page, /\.height\('100%'\)\s*\.contentStartOffset\(this\.px\(48\)\)/);
  assert.match(page, /\.contentEndOffset\(this\.px\(this\.pending\.length > 0 \? 90 : 64\)\)/);
  assert.match(page, /\.id\('chat-header'\)[\s\S]*?\.opacity\(1 - this\.chatChromeProgress\)\s*\.translate\(\{ y: -this\.px\(\d+\) \* this\.chatChromeProgress \}\)/);
  assert.match(page, /\.id\('chat-footer'\)[\s\S]*?\.opacity\(1 - this\.chatChromeProgress\)\s*\.translate\(\{ y: this\.px\(\d+\) \* this\.chatChromeProgress \}\)/);
  assert.equal((page.match(/\.hitTestBehavior\(this\.chatChromeHidden \? HitTestMode\.None : HitTestMode\.Default\)/g) || []).length, 2);
  assert.doesNotMatch(page, /\.(?:height|padding|margin|contentStartOffset|contentEndOffset)\([^\n]*(?:chatChromeHidden|chatChromeProgress)/);
  assert.match(page, /\.onScroll\(\(offset: number, _state: ScrollState\) => \{ this\.scrollY = offset; this\.measureChatStart\(\); \}\)/);
  const swiperStart = page.indexOf('Swiper(this.swiper)');
  assert.ok(swiperStart >= 0);
  const swiperEnd = page.indexOf('.layoutWeight(1)', swiperStart);
  assert.ok(swiperEnd > swiperStart);
  assert.doesNotMatch(page.slice(swiperStart, swiperEnd), /chatChrome\.(?:touchStart|touchMove|crownUpdate)|handleChatTouch|handleChatCrown/);
});

test('模块不依赖 timer、动画或 UI API，程序滚动无状态机入口', () => {
  assert.doesNotMatch(source, /\b(?:import|setTimeout|clearTimeout|setInterval|clearInterval|animateTo|Scroller|onScroll)\b/);
  assert.deepEqual(Object.getOwnPropertyNames(ChatChromeController.prototype)
    .filter(name => name !== 'constructor' && name !== 'syncHidden').sort(),
  ['touchStart', 'touchMove', 'touchEnd', 'crownUpdate', 'crownEnd', 'reset', 'isHidden'].sort());
});
