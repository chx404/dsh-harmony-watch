import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';

const common = process.env.CROWN_COMMON_DIR || '../watch-app/entry/src/main/ets/common/';
const source = await readFile(new URL(common + 'CrownMenu.ets', import.meta.url), 'utf8');
const geometry = await readFile(new URL(common + 'CrownGeometry.ets', import.meta.url), 'utf8');
const compile = text => ts.transpileModule(text, {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
}).outputText;
const dataSourceCode = source.slice(source.indexOf('class CrownMenuDataSource'), source.indexOf('@Component'));
const DataSource = new Function(`${compile(dataSourceCode)}\nreturn CrownMenuDataSource;`)();
const geometryModule = { exports: {} };
new Function('module', 'exports', compile(geometry))(geometryModule, geometryModule.exports);
const { crownItemScale, crownContentInset, crownMeasuredScale } = geometryModule.exports;
const item = index => ({ key: `session-${index}`, title: `会话 ${index}`, caption: '本地 · 2 条消息', symbol: '聊' });
function extract(name) {
  const start = source.search(new RegExp(`^  (?:private )?${name}\\(`, 'm'));
  assert.notEqual(start, -1);
  const end = source.indexOf('\n  }', start);
  assert.notEqual(end, -1);
  return source.slice(start, end + 4);
}
const Controller = new Function('crownItemScale', 'crownMeasuredScale', `${compile(`class Controller {\n${['aboutToAppear', 'itemsChanged', 'u', 'itemScale'].map(extract).join('\n')}\n}`)}\nreturn Controller;`)(crownItemScale, crownMeasuredScale);

test('数据源支持 500 会话，按索引取数据且不复制渲染全部行', () => {
  const data = new DataSource();
  const items = Array.from({ length: 500 }, (_, index) => item(index));
  data.set(items);
  assert.equal(data.totalCount(), 500);
  assert.deepEqual(data.getData(0), item(0));
  assert.deepEqual(data.getData(499), item(499));
  items.push(item(500));
  assert.equal(data.totalCount(), 500);
});

test('数据源重载通知只发一次，重复注册、未知注销与注销后重载安全', () => {
  const data = new DataSource();
  let count = 0;
  const listener = { onDataReloaded() { count++; } };
  data.registerDataChangeListener(listener);
  data.registerDataChangeListener(listener);
  data.unregisterDataChangeListener({ onDataReloaded() { assert.fail('unregistered'); } });
  data.set([item(0)]);
  assert.equal(count, 1);
  data.unregisterDataChangeListener(listener);
  data.set([]);
  assert.equal(count, 1);
  assert.equal(data.totalCount(), 0);
});

test('懒加载 key 绑定本轮索引与版本，重排和同 key 改名不会复用旧闭包', () => {
  const data = new DataSource();
  data.set([item(0), item(1)]);
  const oldKeys = [data.key(data.getData(0), 0), data.key(data.getData(1), 1)];
  data.set([{ ...item(1), title: '新标题' }, item(0)]);
  assert.equal(data.getData(0).key, 'session-1');
  assert.equal(data.getData(0).title, '新标题');
  assert.notEqual(data.key(data.getData(0), 0), oldKeys[1]);
  assert.notEqual(data.key(data.getData(1), 1), oldKeys[0]);
  assert.notEqual(data.key(data.getData(0), 0), data.key(data.getData(0), 1));
});

test('aboutToAppear 初始化源；itemsChanged 只重载数据，不换 Scroller 或滚动位置', () => {
  const data = new DataSource();
  const scroller = new Proxy({}, { get() { assert.fail('data reload must never scroll'); } });
  const controller = Object.assign(new Controller(), {
    itemSource: data, items: [item(0)], scroller,
    screenWidth: 233, scrollOffset: 360, viewport: 178
  });
  controller.aboutToAppear();
  assert.equal(data.totalCount(), 1);
  controller.items = Array.from({ length: 500 }, (_, index) => item(index));
  controller.itemsChanged();
  assert.equal(data.totalCount(), 500);
  assert.equal(controller.itemSource, data);
  assert.equal(controller.scroller, scroller);
  assert.equal(controller.scrollOffset, 360);
  assert.equal(controller.viewport, 178);
});

test('第 499 行仍按真实索引连续缩放，固定 64 行高、8 间距及首尾 inset', () => {
  for (const factor of [0.8, 1, 1.6]) {
    const viewport = 178 * factor;
    const controller = Object.assign(new Controller(), {
      screenWidth: 233 * factor, viewport, scrollOffset: 499 * 72 * factor, elasticStretch: 0, nativeOrigin: 0
    });
    controller.scroller = { getItemRect(index) { return { y: (viewport - 64 * factor) / 2 + index * 72 * factor - controller.scrollOffset, height: 64 * factor }; } };
    assert.equal(controller.itemScale(499), 1);
    assert.ok(controller.itemScale(498) < 1);
    const expectedInset = (viewport - 64 * factor) / 2;
    assert.equal(crownContentInset(viewport, 64 * factor), expectedInset);
    controller.scrollOffset -= 0.1;
    assert.ok(controller.itemScale(499) > 0.999);
  }
});

test('List 懒渲染与表冠安全契约：缓存两行、中心对齐、绝对 offset、原圆屏留白', () => {
  assert.match(source, /List\(\{ space: this.u\(8\), scroller: this.scroller \}\)/);
  assert.match(source, /LazyForEach\(this.itemSource, \(item: CrownMenuItem, index: number\)/);
  assert.match(source, /ListItem\(\)/);
  assert.match(source, /\(item: CrownMenuItem, index: number\) => this.itemSource.key\(item, index\)/);
  assert.match(source, /\.height\(this.u\(64\)\)/);
  assert.match(source, /\.contentStartOffset\(crownContentInset\(this.viewport, this.u\(64\)\)\)/);
  assert.match(source, /\.contentEndOffset\(crownContentInset\(this.viewport, this.u\(64\)\)\)/);
  assert.match(source, /\.cachedCount\(2\)/);
  assert.match(source, /\.alignListItem\(ListItemAlign.Center\)/);
  assert.match(source, /const offset: number = this.scroller.currentOffset\(\).yOffset/);
  assert.match(source, /this.scrollOffset = offset/);
  assert.match(source, /getItemRect\(index\)/);
  assert.match(source, /\.onDigitalCrown/);
  assert.match(source, /requestFocus\(this.focusId\)/);
  assert.match(source, /\.padding\(\{ top: this.u\(22\) \}\)/);
  assert.doesNotMatch(source, /\bScroll\(|\bForEach\(/);
});

test('标题透明悬浮于全高 List，圆屏安全顶部只属于 header 且不拦截触摸', () => {
  assert.match(source, /Stack\(\{ alignContent: Alignment.Top \}\)/);
  const listStart = source.indexOf('List({ space:');
  const headerStart = source.indexOf('      Column() {', source.indexOf('.onDigitalCrown'));
  assert.ok(headerStart > listStart, 'header overlays list in stack order');
  const list = source.slice(listStart, headerStart);
  const header = source.slice(headerStart);
  assert.match(list, /\.height\('100%'\)/);
  assert.doesNotMatch(list, /\.padding\(\{ top:|\.layoutWeight\(1\)\s*\.width\('100%'\)/);
  assert.match(header, /\.padding\(\{ top: this.u\(22\) \}\)/);
  assert.match(header, /\.fontSize\(this.u\(14\)\)/);
  assert.match(header, /\.hitTestBehavior\(HitTestMode.None\)/);
  assert.doesNotMatch(header, /backgroundColor|backgroundBlur|backdropBlur/);
});

test('没有默认提示或任何返回按钮，兼容旧属性但不渲染空 subtitle', () => {
  assert.match(source, /@Prop showBack: boolean = false/);
  assert.match(source, /@Prop @Watch\('itemsChanged'\) items: CrownMenuItem\[\]/);
  assert.match(source, /onBack: \(\) => void/);
  assert.doesNotMatch(source, /\bButton\(|this.onBack\(\)|if \(this.showBack\)|转动表冠|居中放大|‹ 返回/);
  assert.match(source, /\.textAlign\(TextAlign.Center\)/);
  assert.match(source, /@Prop subtitle: string = ''/);
  assert.match(source, /if \(this.subtitle.length > 0\) \{\s*Text\(this.subtitle\)/);
  assert.match(source, /@Prop focusId: string/);
  assert.match(source, /onAction: \(key: string\) => void/);
});

test('表冠 BEGIN UPDATE END 驱动共享弹性，不重起动画，触摸与离场清理', () => {
  assert.match(source, /import \{ CrownElastic \} from '.\/CrownElastic'/);
  assert.match(source, /CrownAction.BEGIN[\s\S]*this.elastic.begin\(\)/);
  assert.match(source, /CrownAction.UPDATE[\s\S]*this.elastic.update\(/);
  assert.match(source, /CrownAction.END[\s\S]*this.elastic.end\(\)/);
  assert.match(source, /\.scrollTo\(\{ xOffset: 0, yOffset: target, animation: false \}\)/);
  assert.match(source, /TouchType.Down[\s\S]*this.elastic.cancel\(\)/);
  assert.match(source, /aboutToDisappear\(\): void \{\s*this.elastic.cancel\(\)/);
  assert.match(source, /\.translate\(\{ y: this.elasticStretch \}\)/);
  assert.match(source, /this.scrollOffset - this.nativeOrigin - this.elasticStretch/);
  assert.match(source, /crownMeasuredScale\(rect.y, rect.height/);
  assert.doesNotMatch(source, /animateTo|setInterval|setTimeout|scrollBy\(/);
});
