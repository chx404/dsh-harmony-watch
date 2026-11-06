import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';

const source = await readFile(new URL('../watch-app/entry/src/main/ets/common/EventFeed.ets', import.meta.url), 'utf8');
const js = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
const module = { exports: {} };
new Function('module', 'exports', js)(module, module.exports);
const { reconcileEventFeed: merge, visibleFeedEvents: visible } = module.exports;
const event = (seq, kind='assistant', sessionId='s1', t=seq*100, text='reply') => ({seq,kind,sessionId,t,text});
const snap = (sessionId, lastSeq, events) => ({ok:true,selected:{id:sessionId},lastSeq,events});
const prev = (sessionId='s1',lastSeq=-1,events=[]) => ({sessionId,lastSeq,events});

test('切到新会话后低序号回复仍然可见', () => {
 const feed=merge(prev('old',200,[event(200,'user','old')]),snap('new',9,[event(8,'assistant','new')]));
 assert.equal(feed.events.length,1);
 assert.equal(feed.events[0].kind,'assistant');
 assert.equal(feed.sessionId,'new');
 assert.equal(feed.lastSeq,9);
});
test('同会话的宿主游标回退后清缓存并重收回复', () => {
 const feed=merge(prev('s1',120,[event(120)]),snap('s1',8,[event(8)]));
 assert.deepEqual(feed.events.map(e=>e.seq),[8]);
});
test('宿主重启后序号相等但时间变化时清除旧一代', () => {
 const feed=merge(prev('s1',8,[event(8),event(7)]),snap('s1',8,[event(8,'assistant','s1',9999,'new reply')]));
 assert.equal(feed.events.length,1);
 assert.equal(feed.events[0].text,'new reply');
});
test('重复快照不会重复插入回复', () => {
 const s=snap('s1',8,[event(8)]);
 const first=merge(prev(),s);
 assert.deepEqual(merge(first,s),first);
});
test('同一序号内容更新后以服务端快照为准', () => {
 const f=merge(prev('s1',8,[event(8,'assistant','s1',800,'old')]),snap('s1',8,[event(8,'assistant','s1',800,'new')]));
 assert.equal(f.events[0].text,'new');
});
test('其他会话的事件不会挤进当前对话', () => {
 const f=merge(prev(),snap('s1',99,[event(8),event(99,'info','other')]));
 assert.deepEqual(f.events.map(e=>e.seq),[8]);
 assert.equal(f.lastSeq,99);
});
test('同批次手表回显与宿主消息合并为一条', () => {
 const f=merge(prev(),snap('s1',5,[event(4,'user'),{...event(5,'user'),fromWatch:true}]));
 assert.equal(f.events.length,1);
});
test('用户真的重复发送同样内容不会被吞', () => {
 const f=merge(prev(),snap('s1',5,[event(4,'user'),event(5,'user')]));
 assert.equal(f.events.length,2);
});
test('运行状态保留且相邻同类只显示最后一次', () => {
 const result=visible([{...event(10,'status'),running:false},{...event(9,'status'),running:true},event(8),event(7,'title')]);
 assert.deepEqual(result.map(e=>e.kind),['status','assistant']);
 assert.equal(result[0].running,true);
});
test('失败回合仍保留错误提示', () => {
 assert.equal(visible([{...event(9,'turn'),reason:'error'}]).length,1);
});
test('缓存保持有界且保留最近回复', () => {
 const events=Array.from({length:100},(_,i)=>event(i+1));
 const f=merge(prev(),snap('s1',100,events));
 assert.equal(f.events.length,60);
 assert.equal(f.events[f.events.length-1].seq,100);
});
