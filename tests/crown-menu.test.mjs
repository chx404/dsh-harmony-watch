import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';
const common = process.env.CROWN_COMMON_DIR || '../watch-app/entry/src/main/ets/common/';
const source = await readFile(new URL(common + 'CrownGeometry.ets', import.meta.url), 'utf8');
const js = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText;
const module = { exports: {} }; new Function('module', 'exports', js)(module, module.exports);
const { crownContentInset: inset, crownItemScale: scale, crownItemOpacity: opacity } = module.exports;
const close = (x, y) => assert.ok(Math.abs(x - y) < 1e-9);
test('不同圆屏尺寸的首尾行均可居中最大化', () => {
  for (const factor of [0.8, 1, 1.25, 1.6]) {
    const h = 161 * factor, item = 64 * factor, gap = 8 * factor;
    for (let i = 0; i < 7; i++) close(scale(i, i * (item + gap), h, item, gap), 1);
    assert.ok(inset(h, item) > 0);
  }
});
test('缩放关于视口中心对称且逐帧连续，不改变行高', () => {
  close(scale(1, 60, 161, 64, 8), scale(1, 84, 161, 64, 8));
  let previous = scale(1, 0, 161, 64, 8);
  for (let offset = .1; offset <= 72; offset += .1) {
    const current = scale(1, offset, 161, 64, 8);
    assert.ok(current >= previous - 1e-10);
    assert.ok(Math.abs(current - previous) < .002);
    previous = current;
  }
});
test('回弹、极端滚动量和小视口不产生负缩放或 NaN', () => {
  for (const h of [0, 10, 161]) for (const o of [-1000, -2, 0, 10, 2000]) {
    const value = scale(0, o, h, 64, 8);
    assert.ok(Number.isFinite(value) && value >= .7 && value <= 1);
    assert.ok(opacity(value) >= .58 && opacity(value) <= 1);
  }
});
test('控制中心与快捷共用大胶囊、绝对偏移，表冠焦点落在各自页面', async () => {
  const component = await readFile(new URL(common + 'CrownMenu.ets', import.meta.url), 'utf8');
  const page = await readFile(new URL('../watch-app/entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
  assert.match(component, /\.height\(this.u\(64\)\)/);
  assert.match(component, /currentOffset\(\).yOffset/);
  assert.match(component, /onDigitalCrown/);
  assert.match(page, /focusId: 'crown-quick', items: this.quickItems/);
  assert.match(page, /focusId: 'crown-menu', items: this.menuItems/);
  assert.doesNotMatch(page.slice(page.indexOf('private goPage'), page.indexOf('private edgeOpacity')), /crown-sessions/);
  assert.match(page, /LocalChat\(\{ screenWidth/);
  assert.match(page, /this.view !== 'local'/);
});
