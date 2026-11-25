// Pure protocol: no DSH, SDK, network calls, storage, logs or global credentials.
export interface WatchHttpRequest {
  method: string;
  path: string;
  headers: Record<string, string>;
  body: string;
}

export interface WatchHttpReply {
  status: number;
  body: string;
  contentType: string;
}

export interface PhoneApiConfig {
  baseUrl: string;
  model: string;
  apiKey: string;
  protocol: string;
}

interface PhoneSubmission {
  ticket: string;
  baseUrl: string;
  model: string;
  apiKey: string;
  protocol: string;
}

// Decode only complete byte sequences. Native socket messages can split UTF-8 anywhere.
export function decodeWatchUtf8(bytes: Uint8Array): string {
  let out: string = '';
  for (let i: number = 0; i < bytes.length;) {
    const first: number = bytes[i++];
    let code: number = first;
    let more: number = 0;
    let minimum: number = 0;
    if (first < 128) { more = 0; }
    else if (first >= 194 && first <= 223) { code = first & 31; more = 1; minimum = 128; }
    else if (first >= 224 && first <= 239) { code = first & 15; more = 2; minimum = 2048; }
    else if (first >= 240 && first <= 244) { code = first & 7; more = 3; minimum = 65536; }
    else { throw new Error('invalid UTF-8'); }
    if (i + more > bytes.length) { throw new Error('invalid UTF-8'); }
    for (let j: number = 0; j < more; j++) {
      const next: number = bytes[i++];
      if ((next & 192) !== 128) { throw new Error('invalid UTF-8'); }
      code = code * 64 + (next & 63);
    }
    if (code < minimum || code > 1114111 || (code >= 55296 && code <= 57343)) {
      throw new Error('invalid UTF-8');
    }
    if (code < 65536) { out += String.fromCharCode(code); }
    else {
      code -= 65536;
      out += String.fromCharCode(55296 + (code >> 10), 56320 + (code & 1023));
    }
  }
  return out;
}

/** A bounded single HTTP/1.x request. No chunking, pipelining, duplicate headers or folding. */
export class WatchHttpParser {
  private buffer: Uint8Array = new Uint8Array(0);
  private done: boolean = false;
  private poisoned: boolean = false;

  push(bytes: Uint8Array): WatchHttpRequest | undefined {
    if (this.done || this.poisoned) { throw new Error('request already closed'); }
    try { return this.parse(bytes); }
    catch (_) {
      this.buffer.fill(0); this.buffer = new Uint8Array(0); this.poisoned = true;
      throw new Error('invalid or oversized HTTP request');
    }
  }

  private parse(bytes: Uint8Array): WatchHttpRequest | undefined {
    if (this.buffer.length + bytes.length > 24576) { throw new Error('request too large'); }
    const joined: Uint8Array = new Uint8Array(this.buffer.length + bytes.length);
    joined.set(this.buffer); joined.set(bytes, this.buffer.length);
    this.buffer.fill(0); this.buffer = joined;
    let end: number = -1;
    for (let i: number = 0; i + 3 < joined.length; i++) {
      if (joined[i] === 13 && joined[i + 1] === 10 && joined[i + 2] === 13 && joined[i + 3] === 10) {
        end = i + 4; break;
      }
    }
    if (end < 0) {
      if (joined.length >= 8192) { throw new Error('headers too large'); }
      return undefined;
    }
    if (end > 8192) { throw new Error('headers too large'); }
    let head: string = '';
    for (let i: number = 0; i < end - 4; i++) {
      if (joined[i] > 127 || joined[i] === 0) { throw new Error('invalid headers'); }
      head += String.fromCharCode(joined[i]);
    }
    const lines: string[] = head.split('\r\n');
    const first: string[] = lines[0].split(' ');
    if (first.length !== 3 || !/^[A-Z]+$/.test(first[0]) ||
      !/^\/[\x21-\x7E]*$/.test(first[1]) ||
      (first[2] !== 'HTTP/1.1' && first[2] !== 'HTTP/1.0')) { throw new Error('invalid request line'); }
    const headers: Record<string, string> = {};
    for (let i: number = 1; i < lines.length; i++) {
      const line: string = lines[i];
      const colon: number = line.indexOf(':');
      if (colon < 1) { throw new Error('invalid header'); }
      const key: string = line.substring(0, colon).toLowerCase();
      const rawValue: string = line.substring(colon + 1);
      if (/[\x00-\x08\x0A-\x1F\x7F]/.test(rawValue)) { throw new Error('invalid header value'); }
      const value: string = rawValue.trim();
      if (!/^[a-z0-9!#$%&'*+.^_`|~-]+$/.test(key) || key === '__proto__' || key === 'constructor' ||
        key === 'prototype' || headers[key] !== undefined || /[\x00-\x08\x0A-\x1F\x7F]/.test(value)) {
        throw new Error('invalid or duplicate header');
      }
      headers[key] = value;
    }
    if (headers['transfer-encoding'] !== undefined) { throw new Error('chunked unsupported'); }
    const rawLength: string = headers['content-length'];
    let length: number = 0;
    if (rawLength !== undefined) {
      if (!/^\d{1,6}$/.test(rawLength)) { throw new Error('invalid length'); }
      length = Number(rawLength);
    } else if (first[0] === 'POST') { throw new Error('length required'); }
    if (length > 16384 || (first[0] !== 'POST' && length !== 0)) { throw new Error('invalid length'); }
    if (joined.length < end + length) { return undefined; }
    if (joined.length !== end + length) { throw new Error('pipelining unsupported'); }
    const body: string = decodeWatchUtf8(joined.subarray(end));
    this.done = true;
    joined.fill(0); this.buffer = new Uint8Array(0);
    return { method: first[0], path: first[1], headers: headers, body: body };
  }
}

const WATCH_PHONE_PAGE: string = `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="no-referrer"><title>手表 API 配置</title><style>body{margin:0;background:#101010;color:#F4F4F4;font:16px system-ui,sans-serif}main{max-width:520px;margin:32px auto;padding:20px}h1{font-size:24px}label{display:block;margin:18px 0 6px}input,select,button{box-sizing:border-box;width:100%;padding:13px;border-radius:10px;border:1px solid #5B5B5B;background:#252525;color:#F4F4F4;font:inherit}button{margin-top:24px;background:#F5F5F5;color:#111111;font-weight:600}small{color:#DFDFDF;line-height:1.6}#status{white-space:pre-wrap;line-height:1.5}a{color:#F5F5F5}</style></head><body><main><h1>直接配置手表 API</h1><p>此页面由手表提供，不经过 DSH 宿主或云端。无需配对码。</p><small>仅在可信的同一 Wi-Fi 使用：本临时页面使用 HTTP，局域网中可能被窃听。二维码五分钟内有效，勿转发。请保持手表配置页在前台。</small><form id="form" autocomplete="off"><label for="base">API 地址（HTTPS）</label><input id="base" type="url" placeholder="https://api.example.com/v1" maxlength="2048" required autocomplete="off" autocapitalize="off" spellcheck="false"><label for="model">模型名称</label><input id="model" maxlength="200" required autocomplete="off" autocapitalize="off" spellcheck="false"><label for="key">API Key</label><input id="key" type="password" maxlength="8192" required autocomplete="off" autocapitalize="off" spellcheck="false"><label for="protocol">协议</label><select id="protocol"><option value="chat">Chat Completions</option><option value="responses">Responses</option></select><button id="send" type="submit">发送到手表，等待确认</button></form><p id="status" role="status"></p><noscript>请使用支持 JavaScript 的系统浏览器。</noscript></main><script>
(()=>{'use strict';let ticket=location.hash.slice(1);history.replaceState(null,'',location.pathname);const form=document.getElementById('form');const status=document.getElementById('status');const send=document.getElementById('send');const key=document.getElementById('key');let used=false;if(!/^[A-Za-z0-9_-]{43}$/.test(ticket)){form.hidden=true;status.textContent='二维码无效，请在手表上重新生成并扫码。';return;}form.addEventListener('submit',async(e)=>{e.preventDefault();if(used)return;send.disabled=true;status.textContent='正在发送给手表…';try{const response=await fetch('/submit',{method:'POST',headers:{'Content-Type':'application/json'},cache:'no-store',credentials:'omit',referrerPolicy:'no-referrer',signal:AbortSignal.timeout(10000),body:JSON.stringify({ticket:ticket,baseUrl:document.getElementById('base').value,model:document.getElementById('model').value,apiKey:key.value,protocol:document.getElementById('protocol').value})});const result=await response.json();if(response.ok&&result.ok===true){used=true;ticket='';key.value='';form.hidden=true;status.textContent='已发送。请在手表核对完整 API 地址、模型和协议，再确认保存；尚未自动启用。';}else{status.textContent=response.status===400?'配置无效：请检查 HTTPS 地址、模型和 Key。':'链接无效、已使用或已过期；请先查看手表是否已收到，再重新生成二维码。';}}catch(_){status.textContent='连接中断。请先查看手表是否已收到，再确认两端仍在同一 Wi-Fi、手表页面未退出。';}finally{send.disabled=used;}});window.addEventListener('pagehide',()=>{key.value='';ticket='';used=true;});})();
</script></body></html>`;

export class WatchProvisionProtocol {
  private ticket: string;
  private origin: string;
  private host: string;
  private expiresAt: number;
  private attempts: number = 0;
  private used: boolean = false;
  private disposed: boolean = false;
  private pending?: PhoneApiConfig;
  private validate: (config: PhoneApiConfig) => PhoneApiConfig;
  private now: () => number;

  constructor(ticket: string, origin: string, expiresAt: number,
    validate: (config: PhoneApiConfig) => PhoneApiConfig, now: () => number = Date.now) {
    if (!/^[A-Za-z0-9_-]{43}$/.test(ticket) || !/^http:\/\/\d{1,3}(\.\d{1,3}){3}:\d{1,5}$/.test(origin) ||
      !Number.isFinite(expiresAt) || expiresAt <= now() || expiresAt > now() + 300000) {
      throw new Error('invalid temporary session');
    }
    const pieces: string[] = origin.substring(7).split(':');
    const octets: string[] = pieces[0].split('.');
    for (let i: number = 0; i < octets.length; i++) {
      if (Number(octets[i]) > 255 || Number(octets[i]).toString() !== octets[i]) {
        throw new Error('invalid temporary origin');
      }
    }
    const port: number = Number(pieces[1]);
    if (port < 1 || port > 65535 || port.toString() !== pieces[1]) { throw new Error('invalid temporary port'); }
    this.ticket = ticket; this.origin = origin; this.host = origin.substring(7);
    this.expiresAt = expiresAt; this.validate = validate; this.now = now;
  }

  private reply(status: number, message: string): WatchHttpReply {
    return { status: status, body: JSON.stringify({ ok: false, error: message }), contentType: 'application/json; charset=utf-8' };
  }

  handle(request: WatchHttpRequest): WatchHttpReply {
    if (this.disposed || this.now() >= this.expiresAt) {
      this.dispose(); return this.reply(410, '配置链接已结束或过期');
    }
    if (request.headers['host'] !== this.host) { return this.reply(403, '不允许的来源'); }
    // A QR scanner may navigate from another site. GET is a static page with no secrets.
    if (request.method === 'GET' && request.path === '/') {
      return { status: 200, body: WATCH_PHONE_PAGE, contentType: 'text/html; charset=utf-8' };
    }
    if (request.method !== 'POST' || request.path !== '/submit') { return this.reply(404, 'not found'); }
    const site: string = request.headers['sec-fetch-site'];
    if (site && site !== 'same-origin' && site !== 'none') { return this.reply(403, '不允许的来源'); }
    if (request.headers['origin'] !== this.origin ||
      !/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(request.headers['content-type'] || '')) {
      return this.reply(403, '不允许的来源');
    }
    if (this.used) { return this.reply(409, '配置链接已使用，请在手表查看'); }
    if (this.attempts >= 8) { return this.reply(429, '尝试过多，请重新生成二维码'); }
    let submission: PhoneSubmission;
    try { submission = JSON.parse(request.body) as PhoneSubmission; }
    catch (_) { return this.reply(400, '配置格式无效'); }
    if (!submission || typeof submission !== 'object' || Array.isArray(submission) ||
      typeof submission.ticket !== 'string') { return this.reply(400, '配置格式无效'); }
    let mismatch: number = submission.ticket.length ^ this.ticket.length;
    for (let i: number = 0; i < this.ticket.length; i++) {
      mismatch |= this.ticket.charCodeAt(i) ^ (submission.ticket.charCodeAt(i) || 0);
    }
    if (mismatch !== 0) { this.attempts++; return this.reply(403, '配置链接无效'); }
    if (typeof submission.baseUrl !== 'string' || typeof submission.model !== 'string' ||
      typeof submission.apiKey !== 'string' || typeof submission.protocol !== 'string' ||
      submission.baseUrl.length > 2048 || submission.model.length > 200 || submission.apiKey.length > 8192) {
      return this.reply(400, '配置无效，请核对 HTTPS 地址、模型及 Key');
    }
    try {
      this.pending = this.validate({ baseUrl: submission.baseUrl, model: submission.model,
        apiKey: submission.apiKey, protocol: submission.protocol });
    } catch (_) { return this.reply(400, '配置无效，请核对 HTTPS 地址、模型及 Key'); }
    this.used = true;
    this.ticket = '';
    return { status: 200, body: '{"ok":true}', contentType: 'application/json; charset=utf-8' };
  }

  takeConfig(): PhoneApiConfig | undefined {
    const config: PhoneApiConfig | undefined = this.pending;
    this.pending = undefined;
    return config;
  }

  dispose(): void {
    this.disposed = true; this.ticket = ''; this.pending = undefined;
  }
}
