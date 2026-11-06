import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';

const common = process.env.CROWN_COMMON_DIR || '../watch-app/entry/src/main/ets/common/';
const source = await readFile(new URL(common + 'CrownElastic.ets', import.meta.url), 'utf8');
const js = ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
}).outputText;

function rig(limit = 36) {
  const timers = new Map();
  const values = [];
  let serial = 0;
  const module = { exports: {} };
  new Function('module', 'exports', 'setInterval', 'clearInterval', js)(module, module.exports,
    (fn, delay) => { assert.equal(delay, 16); timers.set(++serial, fn); return serial; },
    id => timers.delete(id));
  const elastic = new module.exports.CrownElastic(value => values.push(value), limit);
  return {
    elastic, timers, values,
    stretch: () => values.at(-1) || 0,
    tick(count = 1) { for (let i = 0; i < count; i++) for (const fn of [...timers.values()]) fn(); }
  };
}

const close = (actual, expected) => assert.ok(Math.abs(actual - expected) < 1e-8, `${actual} != ${expected}`);

test('中部滚动不拉伸、首尾越界阻尼且有界，UPDATE 不创建 timer', () => {
  const r = rig();
  assert.equal(r.elastic.update(25, 50, 0, 100), 75);
  close(r.stretch(), 0);
  assert.equal(r.elastic.update(-100, 20, 0, 100), 0);
  assert.ok(r.stretch() > 0 && r.stretch() < 36);
  const first = r.stretch();
  for (let i = 0; i < 1000; i++) r.elastic.update(-1000, 0, 0, 100);
  assert.ok(r.stretch() >= first && r.stretch() < 36);
  assert.equal(r.timers.size, 0);
  r.elastic.cancel();
  assert.equal(r.elastic.update(100, 80, 0, 100), 100);
  assert.ok(r.stretch() < 0 && r.stretch() > -36);
});

test('在边界松手只创建一个 spring timer，并最终归零清理', () => {
  for (const [offset, delta] of [[0, -80], [100, 80]]) {
    const r = rig();
    r.elastic.update(delta, offset, 0, 100);
    const initial = Math.abs(r.stretch());
    r.elastic.end(); r.elastic.end();
    assert.equal(r.timers.size, 1);
    r.tick();
    assert.ok(Math.abs(r.stretch()) < initial);
    r.tick(240);
    close(r.stretch(), 0);
    assert.equal(r.timers.size, 0);
    r.elastic.end();
    assert.equal(r.timers.size, 0);
  }
});

test('反向先释放拉伸，超过原拉伸输入后剩余量正常滚动', () => {
  const r = rig();
  r.elastic.update(-80, 0, 0, 100);
  const first = r.stretch();
  assert.equal(r.elastic.update(30, 0, 0, 100), 0);
  assert.ok(r.stretch() > 0 && r.stretch() < first);
  assert.equal(r.elastic.update(70, 0, 0, 100), 20);
  close(r.stretch(), 0);
  r.elastic.end();
  assert.equal(r.timers.size, 0);
});

test('spring 中 BEGIN 不跳变，UPDATE 反向不与旧 timer 打架', () => {
  const r = rig();
  r.elastic.update(-80, 0, 0, 100);
  r.elastic.end(); r.tick(4);
  const releasing = r.stretch();
  r.elastic.begin();
  close(r.stretch(), releasing);
  assert.equal(r.timers.size, 0);
  r.elastic.update(1, 0, 0, 100);
  assert.ok(r.stretch() < releasing && r.stretch() > 0);
  assert.equal(r.timers.size, 0);
  r.elastic.end();
  assert.equal(r.timers.size, 1);
});

test('触摸/离场 cancel 归零清 timer，可重复清理且不遗留迟到回调', () => {
  const r = rig();
  r.elastic.update(40, 100, 0, 100);
  r.elastic.end();
  assert.equal(r.timers.size, 1);
  r.elastic.cancel(); r.elastic.cancel();
  close(r.stretch(), 0);
  assert.equal(r.timers.size, 0);
  r.tick(200);
  close(r.stretch(), 0);
  assert.equal(r.elastic.update(-20, 50, 0, 100), 30);
  close(r.stretch(), 0);
});

test('空列表/单行上下边同时成立，两个方向均能拉伸与归位', () => {
  const r = rig();
  assert.equal(r.elastic.update(-40, 0, 0, 0), 0);
  assert.ok(r.stretch() > 0);
  assert.equal(r.elastic.update(80, 0, 0, 0), 0);
  assert.ok(r.stretch() < 0);
  r.elastic.end(); r.tick(240);
  close(r.stretch(), 0);
  assert.equal(r.timers.size, 0);
});

test('通用 Scroller 可用已知边界，不需要总内容高度', () => {
  const r = rig();
  assert.equal(r.elastic.updateAtEdges(20, 50, false, false), 70);
  close(r.stretch(), 0);
  assert.equal(r.elastic.updateAtEdges(20, 70, false, true), 70);
  assert.ok(r.stretch() < 0);
  assert.equal(r.elastic.updateAtEdges(-30, 70, false, true), 60);
  close(r.stretch(), 0);
  assert.equal(r.elastic.updateAtEdges(-20, 0, true, false), 0);
  assert.ok(r.stretch() > 0);
  r.elastic.cancel();
  assert.equal(r.elastic.updateAtEdges(-20, 0, true, true), 0);
  assert.ok(r.stretch() > 0);
});

test('阻尼按 limit 缩放，固定时步 spring 不受墙钟跳变影响', () => {
  for (const limit of [1, 18, 36, 60]) {
    const r = rig(limit);
    r.elastic.update(-limit * 2, 0, 0, 100);
    assert.ok(r.stretch() > 0 && r.stretch() < limit);
    r.elastic.end(); r.tick(240);
    close(r.stretch(), 0);
    assert.equal(r.timers.size, 0);
  }
});
