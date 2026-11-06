import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';

const source = await readFile(new URL('../watch-app/entry/src/main/ets/common/SwiperProgress.ets', import.meta.url), 'utf8');
const js = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
const module = { exports: {} };
new Function('module', 'exports', js)(module, module.exports);
const { swiperProgress, indicatorTranslation } = module.exports;
const close = (actual, expected) => assert.ok(Math.abs(actual - expected) < 1e-10, `${actual} != ${expected}`);

// 按官方语义模拟可见页回调；不假装这些是手表实测采样。
function checkFrames(frames) {
  for (const progress of frames) {
    for (let index = 0; index < 3; index++) {
      const position = index - progress;
      if (Math.abs(position) <= 1) close(swiperProgress(index, position, 3), progress);
    }
  }
}
for (const [from, to] of [[0, 1], [1, 0], [1, 2], [2, 1]]) {
  test(`双向切页 ${from} → ${to}：拖动和惯性连续，多页回调一致`, () => {
    checkFrames([0, .025, .12, .36, .51, .72, .88, .96, .995, 1].map(t => from + (to - from) * t));
  });
}
test('松手未换页：白条跟随内容回到原页', () => {
  checkFrames([1, 1.1, 1.25, 1.3, 1.22, 1.11, 1.04, 1.005, 1]);
  checkFrames([1, .9, .75, .7, .78, .89, .96, .995, 1]);
});
test('动画被反向拖动打断：没有旧补间继续追目标', () => {
  checkFrames([1, 1.2, 1.4, 1.65, 1.62, 1.5, 1.2, .9, .6, .2, 0]);
});
test('原生弹簧越过中间目标再回弹', () => {
  checkFrames([.8, .95, 1, 1.03, 1.07, 1.04, 1.01, 1]);
});
test('非相邻程序切页也使用同一坐标系', () => {
  checkFrames([0, .2, .7, 1, 1.4, 1.8, 2]);
});
test('边界回弹不让白条跑出三点范围', () => {
  assert.equal(swiperProgress(0, .2, 3), 0);
  assert.equal(swiperProgress(2, -.2, 3), 2);
});
test('末段小于 1vp 的移动保留小数，不量化为整数', () => {
  close(indicatorTranslation(.991, 10), 9.91);
  close(indicatorTranslation(.999, 10), 9.99);
  assert.notEqual(indicatorTranslation(.991, 10), indicatorTranslation(.999, 10));
});
test('页面接入仅由内容逐帧回调驱动，不叠加手势或选页补间', async () => {
  const page = await readFile(new URL('../watch-app/entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
  const swiper = page.slice(page.indexOf('Swiper(this.swiper)'), page.indexOf('.layoutWeight(1)', page.indexOf('Swiper(this.swiper)')));
  assert.match(swiper, /onContentDidScroll/);
  assert.match(swiper, /this\.slidePos = swiperProgress\(index, position, 3\)/);
  assert.doesNotMatch(swiper, /onGestureSwipe|animateTo/);
  const onChange = swiper.slice(swiper.indexOf('.onChange'));
  assert.doesNotMatch(onChange, /slidePos\s*=/);
  assert.match(page, /\.translate\(\{ x: indicatorTranslation\(this\.slidePos, this\.px\(10\)\)/);
  assert.doesNotMatch(page, /this\.px\(this\.slidePos/);
});
