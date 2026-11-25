import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { EventEmitter } from 'node:events';
import { randomBytes } from 'node:crypto';
import ts from 'typescript';
const root = new URL('../watch-app/entry/src/main/ets/common/', import.meta.url);
const compile = name => ts.transpileModule(fs.readFileSync(new URL(name, root),'utf8'), {compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText;
const protocolModule={exports:{}}; new Function('exports','require','module',compile('WatchProvisionProtocol.ets'))(protocolModule.exports,()=>{throw Error('pure protocol must not import dependencies');},protocolModule);
const serviceJs=compile('WatchProvisionService.ets');
const config={baseUrl:'https://api.example.com/v1',model:'model',apiKey:'private-key',protocol:'chat'};
function harness(options={}) {
  let id=0; const timeouts=new Map(), intervals=new Map(), servers=[], received=[], notices=[];
  class Emitter extends EventEmitter { off(name,callback){if(callback)return super.off(name,callback);this.removeAllListeners(name);return this;} }
  class Client extends Emitter {
    clientId=++id; sent=[]; closed=false;
    async send(data){this.sent.push(Buffer.from(data.data));if(options.failSend)throw Error('send failed');}
    async close(){this.closed=true;this.emit('close');}
  }
  class Server extends Emitter {
    closed=false;
    async listen(address){this.bound=address;if(options.listen)await options.listen(this);}
    async getLocalAddress(){return {address:this.bound.address,port:43210};}
    async close(){this.closed=true;}
  }
  const socket={constructTCPSocketServerInstance(){const s=new Server();servers.push(s);return s;}};
  const net={NetBearType:{BEARER_WIFI:1},async getAllNets(){return options.nets||[{netId:1}];},async getNetCapabilities(n){if(options.caps)return options.caps(n);return {bearerTypes:[1]};},async getConnectionProperties(n){if(options.props)return options.props(n);return {linkAddresses:[{address:{address:'192.168.3.99'}}]};}};
  const util={TextEncoder:class{encodeInto(s){return new Uint8Array(Buffer.from(s));}},Base64Helper:class{encodeToStringSync(b){return Buffer.from(b).toString('base64');}}};
  const crypto={createRandom(){return {generateRandomSync(){return {data:new Uint8Array(randomBytes(32))};}};}};
  const requireMock=name=>{
    if(name==='@ohos.net.socket')return {default:socket};if(name==='@ohos.net.connection')return {default:net};if(name==='@ohos.security.cryptoFramework')return {default:crypto};if(name==='@ohos.util')return {default:util};if(name==='./WatchProvisionProtocol')return protocolModule.exports;if(name==='./DirectApi')return {validateDirectConfig(c){assert.ok(c.baseUrl.startsWith('https://'));return {...c};}};throw Error('unexpected dependency '+name);
  };
  const module={exports:{}};
  new Function('exports','require','module','setTimeout','clearTimeout','setInterval','clearInterval',serviceJs)(module.exports,requireMock,module,(cb,ms)=>{const n=++id;timeouts.set(n,{cb,ms});return n;},n=>timeouts.delete(n),(cb,ms)=>{const n=++id;intervals.set(n,{cb,ms});return n;},n=>intervals.delete(n));
  const service=new module.exports.WatchProvisionService(c=>received.push(c),n=>notices.push(n));
  const connect=()=>{const c=new Client();servers.at(-1).emit('connect',c);return c;};
  return {service,servers,received,notices,connect,timeouts,intervals,net,isIPv4:module.exports.isWatchLanIPv4};
}
const flush=()=>new Promise(resolve=>setImmediate(resolve));
const bytes=(method,path,body,origin='http://192.168.3.99:43210')=>Buffer.from(method+' '+path+' HTTP/1.1\r\nHost: 192.168.3.99:43210\r\nOrigin: '+origin+'\r\nContent-Type: application/json\r\nContent-Length: '+Buffer.byteLength(body)+'\r\n\r\n'+body);

test('local server binds only Wi-Fi IP, uses random port and fresh 256-bit URL ticket',async()=>{
  const h=harness();const first=await h.service.start();assert.match(first.url,/^http:\/\/192\.168\.3\.99:43210\/#[-_A-Za-z0-9]{43}$/);assert.deepEqual(h.servers[0].bound,{address:'192.168.3.99',family:1,port:0});
  assert.ok(first.expiresAt>Date.now());assert.equal(h.intervals.size,1);assert.equal(h.timeouts.size,1);
  const second=await h.service.start();assert.notEqual(first.url,second.url);assert.equal(h.servers[0].closed,true);h.service.stop();assert.equal(h.intervals.size,0);assert.equal(h.timeouts.size,0);
});

test('stale network handles do not prevent finding a working Wi-Fi',async()=>{
  const h=harness({nets:[{netId:1},{netId:2}],caps:async n=>{if(n.netId===1)throw Error('stale');return {bearerTypes:[1]};}});const link=await h.service.start();assert.match(link.url,/192\.168\.3\.99/);h.service.stop();
});

test('no Wi-Fi refuses to advertise cellular or VPN address',async()=>{
  const h=harness({caps:async()=>({bearerTypes:[0,4]})});await assert.rejects(h.service.start(),/Wi-Fi/);assert.equal(h.servers.length,0);assert.equal(h.timeouts.size,0);
});

test('valid submission acknowledges no secret, closes all sockets and delivers only a draft',async()=>{
  const h=harness();const link=await h.service.start();const client=h.connect();const wire=bytes('POST','/submit',JSON.stringify({ticket:link.url.split('#')[1],...config}));
  client.emit('message',{message:wire.subarray(0,81)});assert.equal(h.received.length,0);client.emit('message',{message:wire.subarray(81)});await flush();
  assert.deepEqual(h.received,[config]);assert.equal(client.closed,true);assert.equal(h.servers[0].closed,true);const response=Buffer.concat(client.sent).toString();assert.match(response,/HTTP\/1.1 200/);assert.match(response,/Cache-Control: no-store/);assert.match(response,/Referrer-Policy: no-referrer/);assert.doesNotMatch(response,/private-key/);assert.equal(h.timeouts.size,0);assert.equal(h.intervals.size,0);
});

test('phone acknowledgement failure still preserves valid submission for watch confirmation',async()=>{
  const h=harness({failSend:true});const link=await h.service.start();h.connect().emit('message',{message:bytes('POST','/submit',JSON.stringify({ticket:link.url.split('#')[1],...config}))});await flush();assert.deepEqual(h.received,[config]);assert.equal(h.servers[0].closed,true);
});

test('page content-length counts UTF-8 bytes and GET neither discloses nor consumes ticket',async()=>{
  const h=harness();const link=await h.service.start();const c=h.connect();c.emit('message',{message:bytes('GET','/','')});await flush();const response=Buffer.concat(c.sent);const split=response.indexOf('\r\n\r\n');const declared=Number(/Content-Length: (\d+)/.exec(response.subarray(0,split).toString())[1]);assert.equal(response.length-split-4,declared);assert.doesNotMatch(response.toString(),new RegExp(link.url.split('#')[1]));assert.equal(h.servers[0].closed,false);h.service.stop();
});

test('stop during async listen closes late server and produces no usable QR',async()=>{
  let finish;const h=harness({listen:()=>new Promise(resolve=>{finish=resolve;})});const starting=h.service.start();await flush();h.service.stop();finish();await assert.rejects(starting,/取消/);assert.equal(h.servers[0].closed,true);assert.equal(h.received.length,0);assert.equal(h.timeouts.size,0);
});

test('expiry closes listener and notifies watch without any background work remaining',async()=>{
  const h=harness();await h.service.start();const expiry=[...h.timeouts.values()].find(x=>x.ms===300000);expiry.cb();assert.equal(h.servers[0].closed,true);assert.match(h.notices[0],/过期/);assert.equal(h.timeouts.size,0);assert.equal(h.intervals.size,0);
});

test('Wi-Fi address change cancels old ticket instead of silently switching endpoints',async()=>{
  const h=harness();await h.service.start();h.net.getConnectionProperties=async()=>({linkAddresses:[{address:{address:'10.0.0.22'}}]});await [...h.intervals.values()][0].cb();await flush();assert.equal(h.servers[0].closed,true);assert.match(h.notices[0],/变化/);assert.equal(h.intervals.size,0);
});

test('bounded concurrent clients, idle timeout and malformed request cleanup',async()=>{
  const h=harness();await h.service.start();const clients=Array.from({length:5},()=>h.connect());assert.equal(clients[4].closed,true);assert.equal(clients[0].closed,false);[...h.timeouts.values()].find(x=>x.ms===8000).cb();assert.equal(clients[0].closed,true);
  clients[1].emit('message',{message:Buffer.alloc(24577)});await flush();assert.equal(clients[1].closed,true);assert.match(Buffer.concat(clients[1].sent).toString(),/HTTP\/1.1 400/);assert.equal(h.received.length,0);h.service.stop();assert.ok(clients.every(c=>c.closed));assert.equal(h.timeouts.size,0);
});

test('IPv4 selection excludes loopback, link-local, carrier and public interfaces',()=>{
  const h=harness();for(const address of ['10.0.0.2','172.16.1.2','172.31.2.3','192.168.3.1'])assert.equal(h.isIPv4(address),true,address);for(const address of ['127.0.0.1','169.254.1.2','172.19.0.1/30','8.8.8.8','100.64.0.1','10.999.1.1','::1','192.168.1.1:80'])assert.equal(h.isIPv4(address),false,address);
});
