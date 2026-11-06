import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';
const root = new URL('../watch-app/entry/src/main/ets/common/', import.meta.url);
const code = await readFile(new URL('CrownGeometry.ets', root), 'utf8');
const module = { exports: {} };
new Function('module', 'exports', ts.transpileModule(code, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText)(module, module.exports);
const { crownMeasuredScale: scale, crownNativeOrigin: origin, crownContentInset: inset } = module.exports;
const close = (a,b) => assert.ok(Math.abs(a-b)<1e-9, `${a} != ${b}`);
test('真实可见行中间最大，上下相同距离同样收小', () => {
  for (const f of [.8,1,1.25,1.6]) {
    const h=216*f, row=64*f, mid=(h-row)/2;
    close(scale(mid,row,h),1);
    for (const d of [12,36,72]) close(scale(mid-d*f,row,h),scale(mid+d*f,row,h));
    assert.ok(scale(mid-72*f,row,h)<scale(mid-36*f,row,h));
    assert.ok(scale(mid+72*f,row,h)<scale(mid+36*f,row,h));
  }
});
test('原生offset以0或负inset开头都能由实测矩形校准，不能重复加头部偏移', () => {
  const view=216,row=64,gap=8,pad=inset(view,row);
  for (const nativeOrigin of [0,-pad,23]) {
    for (const index of [0,1,2,10,499]) {
      const displacement=index*(row+gap), offset=nativeOrigin+displacement;
      close(origin(offset,pad,index,view,row,gap),nativeOrigin);
      close(scale(pad,row,view),1);
    }
  }
});
test('回弹位移对称加入实际行中心，不固定偏向第一项', () => {
  close(scale(76,64,216,12),scale(76,64,216,-12));
  assert.ok(scale(76,64,216,20)<1);
  close(scale(4,64,216,72),1);
});
test('UI优先查询原生getItemRect，几何边界和触摸弹性均接线', async () => {
  const menu=await readFile(new URL('CrownMenu.ets',root),'utf8');
  assert.match(menu,/getItemRect\(index\)/);
  assert.match(menu,/crownMeasuredScale\(rect.y, rect.height/);
  assert.match(menu,/crownNativeOrigin\(offset, rect.y, index/);
  assert.match(menu,/onScrollIndex/);
  assert.match(menu,/this.nativeOrigin, max/);
  assert.match(menu,/alwaysEnabled: true/);
});
test('移除多余入口、简化会话名称，模型小窗只展示配置摘要', async () => {
  const page=await readFile(new URL('../watch-app/entry/src/main/ets/pages/Index.ets',import.meta.url),'utf8');
  const menu=page.slice(page.indexOf('private menuItems:'),page.indexOf('private quickItems:'));
  assert.doesNotMatch(menu,/独立对话|全部会话/);
  assert.match(menu,/title: '会话'/);
  assert.match(page,/ForEach\(this.apiProfiles/);
  assert.match(page,/onProfileConfigured:/);
  assert.match(page,/chooseApiProfile\(profile.id\)/);
  assert.doesNotMatch(page,/Text\(profile.apiKey\)/);
});
