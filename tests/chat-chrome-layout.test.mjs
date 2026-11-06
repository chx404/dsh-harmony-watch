import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const page=await readFile(new URL('../watch-app/entry/src/main/ets/pages/Index.ets',import.meta.url),'utf8');
const main=page.slice(page.indexOf('  MainView()'),page.indexOf('  QuickView()'));
// Structural brace pairs preserve direct-parent relationships. Merely finding
// align(Top/Bottom) was insufficient: ArkUI align aligns content, not Stack children.
const blocks=[],stack=[],byClose=new Map(); let quote='',line=false,block=false;
for(let i=0;i<main.length;i++){
 const c=main[i],n=main[i+1];
 if(line){if(c==='\n')line=false;continue;}
 if(block){if(c==='*'&&n==='/'){block=false;i++;}continue;}
 if(quote){if(c==='\\')i++;else if(c===quote)quote='';continue;}
 if(c==='/'&&n==='/'){line=true;i++;continue;}
 if(c==='/'&&n==='*'){block=true;i++;continue;}
 if(c==='"'||c==="'"||c==='`'){quote=c;continue;}
 if(c==='{'){const node={open:i,parent:stack.at(-1),close:-1};blocks.push(node);stack.push(node);}
 if(c==='}'){const node=stack.pop();assert.ok(node);node.close=i;byClose.set(i,node);}
}
assert.equal(stack.length,0,'balanced MainView');
function owner(id){
 const at=main.indexOf(`.id('${id}')`);assert.ok(at>0,id);
 let close=at-1;while(/\s/.test(main[close]))close--;
 assert.equal(main[close],'}',id+' modifier must belong to a component block');
 const node=byClose.get(close);assert.ok(node,id);return node;
}
function styles(id,end){const at=main.indexOf(`.id('${id}')`);return main.slice(at,end);}
const overlay=owner('chat-controls-overlay'),header=owner('chat-header'),footer=owner('chat-footer');
test('顶栏和底栏是同一全高Column的直接孩子，中间由弹性Blank分开',()=>{
 assert.equal(header.parent,overlay);assert.equal(footer.parent,overlay);
 assert.ok(header.close<footer.open);
 assert.match(main.slice(overlay.open-20,overlay.open),/Column\(\)\s*$/);
 const gap=main.slice(header.close,footer.open);
 assert.match(gap,/Blank\(\)\s*\.layoutWeight\(1\)\s*\.hitTestBehavior\(HitTestMode.None\)/);
 const overlayStyle=styles('chat-controls-overlay',main.indexOf('if (this.showPrompt)'));
 assert.match(overlayStyle,/\.height\('100%'\)/);
 assert.match(overlayStyle,/HitTestMode.Transparent/);
 assert.doesNotMatch(main,/\.align\(Alignment\.(?:Top|Bottom)\)/);
});
test('标题绿点只在顶栏，消息停止和模型只在底栏，不混在中央',()=>{
 const top=main.slice(header.open,header.close),bottom=main.slice(footer.open,footer.close);
 assert.match(top,/Text\(this.chatTitle\(\)\)/);assert.match(top,/Circle\(/);
 assert.doesNotMatch(top,/openPrompt|doStop|openModels/);
 for(const action of ['openPrompt','doStop','openModels'])assert.ok(bottom.includes(`this.${action}()`),action);
 assert.doesNotMatch(bottom,/chatTitle\(\)|Circle\(/);
});
test('上下操作层不再绘制整片背景，按钮本身底色和淡出布局保留',()=>{
 assert.doesNotMatch(page,/CHAT_CHROME_BG/);
 const buttons=main.slice(footer.open,footer.close);
 assert.match(buttons,/\.backgroundColor\('#0D181C'\)/);
 assert.match(buttons,/'#282126'/);
 const top=styles('chat-header',footer.open),bottom=styles('chat-footer',overlay.close);
 assert.match(top,/\.height\(this.px\(48\)\)/);
 for(const section of [top,bottom]){
  assert.doesNotMatch(section,/\.(?:backgroundColor|backgroundBlurStyle|linearGradient)\(/);
  assert.match(section,/\.opacity\(1 - this.chatChromeProgress\)/);
  assert.match(section,/this.chatChromeHidden \? HitTestMode.None : HitTestMode.Default/);
 }
 assert.match(top,/y: -this.px\(64\) \* this.chatChromeProgress/);
 assert.match(bottom,/y: this.px\(108\) \* this.chatChromeProgress/);
 assert.doesNotMatch(main,/\.(?:height|padding|margin|layoutWeight|contentStartOffset|contentEndOffset)\([^\n]*(?:chatChromeHidden|chatChromeProgress)/);
});
test('聊天在布局层后方，透明中间区域能透传触摸，浮层仍在控件之后',()=>{
 assert.ok(main.indexOf('List({ scroller: this.scroller })')<overlay.open);
 assert.doesNotMatch(main.slice(overlay.open,overlay.close),/List\(/);
 assert.ok(main.indexOf('if (this.showPrompt)')>overlay.close);
 assert.ok(main.indexOf('if (this.showModels)')>overlay.close);
 const content=main.slice(0,overlay.open);
 assert.match(content,/\.onTouch\(\(event: TouchEvent\) => \{ this.handleChatTouch\(event\); \}\)/);
 assert.match(content,/\.contentStartOffset\(this.px\(48\)\)/);
 assert.match(content,/\.contentEndOffset\(this.px\(this.pending.length > 0 \? 90 : 64\)\)/);
});
