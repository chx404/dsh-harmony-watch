import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';
const root = new URL('../watch-app/entry/src/main/ets/', import.meta.url);
const page = await readFile(new URL('pages/Index.ets', root), 'utf8');
const logic = await readFile(new URL('common/ChatImmersion.ets', root), 'utf8');
const compile = code => ts.transpileModule(code, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText;
const module = { exports: {} }; new Function('module', 'exports', compile(logic))(module, module.exports);
function extract(name) {
  const start=page.search(new RegExp('^  private '+name+'\\(', 'm'));
  assert.notEqual(start,-1,name); const end=page.indexOf('\n  }',start);
  return page.slice(start,end+4);
}
const methods=['focusMainCrown','routeMainCrown','canImmerseChat','animateChatChrome','finishChatCrown','resetChatChrome','handleChatTouch','handleChatCrown','measureChatStart','handleCrown'];
const js=compile(`class Harness { ${methods.map(extract).join('\n')} }`);
const TouchType={Down:0,Up:1,Move:2,Cancel:3}, CrownAction={BEGIN:0,UPDATE:1,END:2};
function fixture() {
  const timers=new Map(), animations=[], edges=[], focus={ok:true,requests:[]}; let next=0;
  const Harness=new Function('animateTo','Curve','TouchType','CrownAction','setTimeout','clearTimeout',js+';return Harness;')(
    (options, action)=>{animations.push(options.duration);action();}, {EaseOut:'out'},TouchType,CrownAction,
    callback=>{const id=++next;timers.set(id,callback);return id;}, id=>timers.delete(id));
  const h=new Harness();
  Object.assign(h,{view:'main',pageIndex:1,showPrompt:false,showModels:false,showGuide:false,pageVisible:true,returnAnimating:false,
    chatChromeHidden:false,chatChromeProgress:0,chatCrownQuietTimer:-1,chatFocusTimer:-1,chatScrollOrigin:0,px:v=>v,
    resetCrown(){this.crownOwner=undefined;},
    getUIContext:()=>({getFocusController:()=>({requestFocus(id){focus.requests.push(id);}})}),
    scroller:{offset:-48, top:48, by:[],to:[],currentOffset(){return {yOffset:this.offset};},getItemRect(){return {y:this.top,height:64};},isAtEnd:()=>false,
      scrollBy(_x,dy){this.by.push(dy);this.offset+=dy;this.top-=dy;},scrollTo(options){this.to.push(options);this.offset=Math.max(0,options.yOffset);}},
    crownMotion:{begin(){},end(){},updateAtEdges(delta,offset,start,end){edges.push({delta,offset,start,end});return offset;}}});
  h.chatChrome=new module.exports.ChatChromeController(hidden=>h.animateChatChrome(hidden));
  return {h,timers,animations,edges,focus};
}
const touch=(h,type,x=40,y=60)=>h.handleChatTouch({type,touches:type===TouchType.Up||type===TouchType.Cancel?[]:[{x,y}]});
const crown=(h,action,degree=1)=>h.handleCrown(h.scroller,{action,degree});
test('真实触摸接线：按下不隐藏，纵拖动画仅触发一次，松手立即恢复',()=>{
 const {h,animations}=fixture();touch(h,TouchType.Down);assert.equal(h.chatChromeProgress,0);
 touch(h,TouchType.Move,42,82);touch(h,TouchType.Move,44,110);
 assert.equal(h.chatChromeHidden,true);assert.equal(h.chatChromeProgress,1);assert.deepEqual(animations,[150]);
 touch(h,TouchType.Up);assert.equal(h.chatChromeHidden,false);assert.equal(h.chatChromeProgress,0);assert.deepEqual(animations,[150,220]);
});
test('横向Swiper与被系统取消不会留下隐藏状态',()=>{
 const {h}=fixture();touch(h,TouchType.Down);touch(h,TouchType.Move,90,66);assert.equal(h.chatChromeHidden,false);
 touch(h,TouchType.Cancel);touch(h,TouchType.Move,40,200);assert.equal(h.chatChromeHidden,false);
});
test('模型/输入浮层、缓存页和后台不进入沉浸状态',()=>{
 for(const change of [{showModels:true},{showPrompt:true},{pageIndex:0},{pageIndex:2},{pageVisible:false},{view:'settings'},{returnAnimating:true}]){
  const {h,timers}=fixture();Object.assign(h,change);touch(h,TouchType.Down);touch(h,TouchType.Move,40,100);crown(h,CrownAction.UPDATE);
  assert.equal(h.chatChromeHidden,false,JSON.stringify(change));assert.equal(timers.size,0);
 }
});
test('表冠只在UPDATE隐藏，连续更新只保留一只保险timer，END恢复并清timer',()=>{
 const {h,timers,animations}=fixture();crown(h,CrownAction.BEGIN);assert.equal(h.chatChromeHidden,false);
 for(let i=0;i<5;i++)crown(h,CrownAction.UPDATE);
 assert.equal(h.chatChromeHidden,true);assert.equal(timers.size,1);assert.deepEqual(animations,[150]);
 crown(h,CrownAction.END);assert.equal(h.chatChromeHidden,false);assert.equal(timers.size,0);assert.deepEqual(animations,[150,220]);
});
test('失去END与离场两种路径均能恢复，旧MOVE不能重新隐藏',()=>{
 const {h,timers}=fixture();crown(h,CrownAction.UPDATE);
 const callback=timers.values().next().value;timers.clear();callback();assert.equal(h.chatChromeHidden,false);
 touch(h,TouchType.Down);touch(h,TouchType.Move,40,110);crown(h,CrownAction.UPDATE);h.resetChatChrome();
 assert.equal(timers.size,0);assert.equal(h.chatChromeProgress,0);touch(h,TouchType.Move,40,180);assert.equal(h.chatChromeHidden,false);
});
test('负inset原点校准后，中途向上转表冠不能被误判为已经到顶',()=>{
 const {h,edges}=fixture();h.scroller.offset=-20;h.scroller.top=20;crown(h,CrownAction.UPDATE,-1);
 assert.equal(h.chatScrollOrigin,-48);assert.equal(edges.at(-1).start,false);
 h.scroller.offset=-48;h.scroller.top=48;crown(h,CrownAction.UPDATE,-1);assert.equal(edges.at(-1).start,true);
});
test('程序滚动不主动隐藏，表冠使用独立叶子焦点而非List自身或移出的标题',()=>{
 const main=page.slice(page.indexOf('  MainView()'),page.indexOf('  QuickView()'));
 const list=main.slice(main.indexOf('List({ scroller: this.scroller })'),main.indexOf("Text(' ')"));
 const anchor=main.slice(main.indexOf("Text(' ')"),main.indexOf('// 全高纵向布局'));
 assert.match(list,/\.height\('100%'\)/);assert.match(list,/\.focusable\(false\)/);
 assert.doesNotMatch(list,/\.onDigitalCrown/);
 assert.match(anchor,/\.id\('crown-main'\)/);assert.match(anchor,/\.focusable\(true\)/);
 assert.match(anchor,/this.routeMainCrown\(event\)/);assert.doesNotMatch(anchor,/chatChromeProgress|chatChromeHidden|\.opacity\(0\)/);
 assert.doesNotMatch(list.match(/\.onScroll\([^\n]*/)?.[0]||'',/chatChrome|handleChatTouch|handleChatCrown/);
 assert.doesNotMatch(main,/\.align\(Alignment\.(?:Top|Bottom)\)/);
 assert.match(main,/Blank\(\)\s*\.layoutWeight\(1\)\s*\.hitTestBehavior\(HitTestMode.None\)/);
 assert.match(main,/\.id\('chat-controls-overlay'\)\s*\.width\('100%'\)\s*\.height\('100%'\)\s*\.hitTestBehavior\(HitTestMode.Transparent\)/);
});
test('回归：负偏移区间用scrollBy相对滚动，不再被scrollTo归零',()=>{
 const {h}=fixture();h.scroller.offset=-20;h.scroller.top=20;
 h.crownMotion.updateAtEdges=(delta,offset,start)=>start&&delta<0?offset:offset+delta;
 crown(h,CrownAction.UPDATE,1);assert.equal(h.scroller.offset,-22);
 crown(h,CrownAction.UPDATE,1);assert.equal(h.scroller.offset,-24);
 crown(h,CrownAction.UPDATE,-1);assert.equal(h.scroller.offset,-22);
 assert.deepEqual(h.scroller.by,[-2,-2,2]);assert.equal(h.scroller.to.length,0);
});
test('从负inset起点可以离开边界再返回，其他Scroller仍走原逻辑',()=>{
 const {h}=fixture();h.crownMotion.updateAtEdges=(delta,offset,start)=>start&&delta<0?offset:offset+delta;
 crown(h,CrownAction.UPDATE,1);assert.equal(h.scroller.offset,-48);
 crown(h,CrownAction.UPDATE,-1);assert.equal(h.scroller.offset,-46);
 crown(h,CrownAction.UPDATE,1);assert.equal(h.scroller.offset,-48);
 const other={currentOffset:()=>({yOffset:10}),isAtEnd:()=>false,scrollTo(options){this.saved=options;}};
 h.handleCrown(other,{action:CrownAction.UPDATE,degree:1});assert.equal(other.saved.yOffset,8);
});
test('叶子焦点的表冠事件阻止冒泡，仅滚动一次，隐藏控件后仍可继续滚动',()=>{
 const {h,focus}=fixture();h.crownMotion.updateAtEdges=(delta,offset)=>offset+delta;
 let stopped=false;const event={action:CrownAction.UPDATE,degree:-1,stopPropagation(){stopped=true;}};
 h.routeMainCrown(event);if(!stopped)h.routeMainCrown(event);
 assert.equal(h.scroller.by.length,1);assert.equal(h.chatChromeHidden,true);
 h.focusMainCrown();assert.deepEqual(focus.requests,['crown-main']);
 stopped=false;h.routeMainCrown(event);assert.equal(h.scroller.by.length,2);
});
test('主页面兜底不截走模型窗或输入窗自己的表冠事件',()=>{
 for(const props of [{showModels:true},{showPrompt:true},{pageIndex:0},{pageVisible:false}]){
  const {h}=fixture();Object.assign(h,props);let stopped=false;
  h.routeMainCrown({action:CrownAction.UPDATE,degree:1,stopPropagation(){stopped=true;}});
  assert.equal(stopped,false);assert.equal(h.scroller.by.length,0);
 }
});
test('焦点只补一次，打开浮层后不重试抢焦点，退出时清理定时器',()=>{
 const {h,timers,focus}=fixture();h.focusMainCrown();h.focusMainCrown();
 assert.equal(timers.size,1);assert.equal(focus.requests.length,2);
 h.showModels=true;const callback=timers.values().next().value;timers.clear();callback();
 assert.equal(focus.requests.length,2);assert.equal(timers.size,0);
 h.showModels=false;h.focusMainCrown();assert.equal(timers.size,1);
 h.resetChatChrome();assert.equal(timers.size,0);assert.equal(h.chatFocusTimer,-1);
});
test('触摸聊天重新归还主表冠焦点，源代码同时覆盖唤醒和关闭浮层',()=>{
 const {h,focus}=fixture();touch(h,TouchType.Down);assert.deepEqual(focus.requests,['crown-main']);
 const onShow=page.slice(page.indexOf('  onPageShow()'),page.indexOf('  onPageHide()'));
 assert.match(onShow,/this.focusMainCrown\(\)/);
 const close=page.slice(page.indexOf('  private closePrompt()'),page.indexOf('  private location()'));
 assert.match(close,/this.focusMainCrown\(\)/);
});
