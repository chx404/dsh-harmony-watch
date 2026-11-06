import http from '@ohos.net.http';
import url from '@ohos.url';
import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import huks from '@ohos.security.huks';
import cryptoFramework from '@ohos.security.cryptoFramework';
import util from '@ohos.util';
import { BusinessError } from '@ohos.base';

export interface DirectApiConfig {
  baseUrl: string;
  apiKey: string;
  model: string;
  protocol: string;
}

export interface DirectMessage {
  role: string;
  content: string;
}

export interface DirectStoredConfig {
  config?: DirectApiConfig;
  persistent: boolean;
  notice: string;
}

interface SealedConfig {
  version: number;
  nonce: string;
  data: string;
}

interface DirectHeaders {
  'Content-Type': string;
  'Authorization': string;
}

interface ChatBody {
  model: string;
  stream: boolean;
  messages: DirectMessage[];
}

interface ResponsesBody {
  model: string;
  stream: boolean;
  store: boolean;
  input: DirectMessage[];
}

interface ChatChoice {
  message?: DirectMessage;
}

interface ResponseContent {
  type?: string;
  text?: string;
}

interface ResponseOutput {
  type?: string;
  role?: string;
  content?: ResponseContent[];
}

interface DirectWireReply {
  choices?: ChatChoice[];
  output?: ResponseOutput[];
  output_text?: string;
  status?: string;
}

const STORE_NAME: string = 'dsh_direct_api_secure_v1';
const KEY_ALIAS: string = 'dsh_direct_api_aes_gcm_v1';
const MAX_INPUT: number = 2000;
const MAX_REPLY: number = 12000;
const MAX_HISTORY: number = 12;
const MAX_HISTORY_CHARS: number = 24000;
let sessionConfig: DirectApiConfig | undefined = undefined;

export function copyDirectConfig(config: DirectApiConfig): DirectApiConfig {
  return { baseUrl: config.baseUrl, apiKey: config.apiKey, model: config.model, protocol: config.protocol };
}

// A full endpoint is accepted, then reduced to one canonical API root.
export function normalizeDirectBase(value: string): string {
  const raw: string = value.trim();
  if (raw.length === 0 || raw.length > 2048 || /[\s\\?#]/.test(raw) || !/^https:\/\//i.test(raw)) {
    throw new Error('API 地址须为 HTTPS，不能含查询或片段');
  }
  let parsed: url.URL;
  try {
    parsed = new url.URL(raw);
  } catch (_) {
    throw new Error('API 地址无效');
  }
  const authority: string = raw.slice(raw.indexOf('://') + 3).split('/')[0];
  if (!parsed.hostname || parsed.protocol !== 'https:' || parsed.username || parsed.password ||
    parsed.search || parsed.hash || authority.indexOf('@') >= 0 || authority.indexOf('%') >= 0) {
    throw new Error('API 地址不能含内嵌凭证');
  }
  let path: string = parsed.pathname.replace(/\/+$/, '');
  // Repeated endpoint suffixes are removed rather than appended again.
  while (/\/(chat\/completions|responses)$/.test(path)) {
    path = path.replace(/\/(chat\/completions|responses)$/, '').replace(/\/+$/, '');
  }
  return parsed.origin + path;
}

// Provision links are a separate trust boundary: only the paired host's fixed page is permitted.
export function normalizeDirectProvisionHost(value: string): string {
  let raw: string = value.trim().replace(/\/+$/, '');
  if (raw.indexOf('://') < 0) { raw = 'http://' + raw; }
  if (/[\s\\?#]/.test(raw) || !/^https?:\/\//.test(raw)) { throw new Error('宿主地址无效'); }
  const parsed: url.URL = new url.URL(raw);
  if (!parsed.hostname || parsed.username || parsed.password || parsed.search || parsed.hash ||
    (parsed.pathname !== '/' && parsed.pathname !== '') ||
    raw.slice(raw.indexOf('://') + 3).split('/')[0].indexOf('@') >= 0) {
    throw new Error('宿主地址无效');
  }
  return parsed.origin;
}

export function directProvisionQrLink(base: string, pagePath: string, id: string, expiresAt: number, now: number = Date.now()): string {
  const host: string = normalizeDirectProvisionHost(base);
  if (!/^[A-Za-z0-9_-]{43}$/.test(id) || pagePath !== '/configure#' + id ||
    !Number.isFinite(expiresAt) || expiresAt <= now) {
    throw new Error('配置链接无效或已过期');
  }
  // The random ticket stays in the fragment, absent from HTTP requests and referrer URLs.
  return host + pagePath;
}

export function validateDirectConfig(config: DirectApiConfig): DirectApiConfig {
  const base: string = normalizeDirectBase(config.baseUrl);
  const model: string = config.model.trim();
  const key: string = config.apiKey.trim();
  if (config.protocol !== 'chat' && config.protocol !== 'responses') {
    throw new Error('请选择 chat 或 responses 协议');
  }
  if (!model || model.length > 200 || /[\x00-\x1f\x7f]/.test(model)) {
    throw new Error('请填写有效模型名');
  }
  if (!key || key.length > 8192 || /[\x00-\x20\x7f]/.test(key)) {
    throw new Error('请填写有效 API Key');
  }
  return { baseUrl: base, model: model, apiKey: key, protocol: config.protocol };
}

export function directEndpoint(config: DirectApiConfig): string {
  const checked: DirectApiConfig = validateDirectConfig(config);
  return checked.baseUrl + (checked.protocol === 'responses' ? '/responses' : '/chat/completions');
}

export function boundedDirectHistory(messages: DirectMessage[]): DirectMessage[] {
  const result: DirectMessage[] = [];
  // Only complete user/assistant pairs can enter the committed history.
  for (let i: number = 0; i + 1 < messages.length; i += 2) {
    if (messages[i].role === 'user' && messages[i + 1].role === 'assistant') {
      result.push({ role: 'user', content: messages[i].content.slice(0, MAX_INPUT) });
      result.push({ role: 'assistant', content: messages[i + 1].content.slice(0, MAX_REPLY) });
    }
  }
  let chars: number = result.reduce((sum: number, item: DirectMessage) => sum + item.content.length, 0);
  while (result.length > MAX_HISTORY || chars > MAX_HISTORY_CHARS) {
    chars -= result[0].content.length + result[1].content.length;
    result.splice(0, 2);
  }
  return result;
}

export function directRequestBody(config: DirectApiConfig, history: DirectMessage[], input: string): string {
  const checked: DirectApiConfig = validateDirectConfig(config);
  const text: string = input.trim();
  if (!text || text.length > MAX_INPUT) {
    throw new Error('请输入 1–2000 字消息');
  }
  const messages: DirectMessage[] = boundedDirectHistory(history);
  messages.push({ role: 'user', content: text });
  if (checked.protocol === 'responses') {
    const body: ResponsesBody = { model: checked.model, stream: false, store: false, input: messages };
    return JSON.stringify(body);
  }
  const body: ChatBody = { model: checked.model, stream: false, messages: messages };
  return JSON.stringify(body);
}

export function parseDirectReply(raw: string, protocol: string): string {
  if (raw.length > 262144) {
    throw new Error('回复过大，请新建对话');
  }
  let reply: DirectWireReply;
  try {
    reply = JSON.parse(raw) as DirectWireReply;
  } catch (_) {
    throw new Error('API 返回格式无效');
  }
  if (!reply) {
    throw new Error('API 返回格式无效');
  }
  let text: string = '';
  if (protocol === 'chat') {
    if (Array.isArray(reply.choices) && reply.choices.length > 0) {
      const message: DirectMessage | undefined = reply.choices[0].message;
      if (message && typeof message.content === 'string') {
        text = message.content;
      }
    }
  } else {
    if (reply.status === 'failed' || reply.status === 'incomplete') {
      throw new Error('API 未完成回复，请缩短消息');
    }
    if (typeof reply.output_text === 'string') {
      text = reply.output_text;
    } else if (Array.isArray(reply.output)) {
      for (let i: number = 0; i < reply.output.length; i++) {
        const item: ResponseOutput = reply.output[i];
        if (item.type === 'message' && item.role === 'assistant' && Array.isArray(item.content)) {
          for (let j: number = 0; j < item.content.length; j++) {
            const part: ResponseContent = item.content[j];
            if (part.type === 'output_text' && typeof part.text === 'string') {
              text += part.text;
            }
          }
        }
      }
    }
  }
  if (!text.trim()) {
    throw new Error('API 未返回文本回复');
  }
  const suffix: string = '\n[回复已截断]';
  return text.length > MAX_REPLY ? text.slice(0, MAX_REPLY - suffix.length) + suffix : text;
}

export function directHttpError(status: number): string {
  if (status === 401 || status === 403) { return 'API 鉴权失败，请检查 Key'; }
  if (status === 404) { return 'API 路径或模型不存在'; }
  if (status === 429) { return 'API 限流或额度不足'; }
  if (status >= 500) { return 'API 服务暂不可用'; }
  if (status >= 300 && status < 400) { return '请填写最终 HTTPS API 地址'; }
  return 'API 请求失败（' + status.toString() + '）';
}

export class DirectApiClient {
  private request?: http.HttpRequest;
  private rejectPending?: (reason: Error) => void;
  private timer: number = -1;
  private generation: number = 0;

  cancel(): void { this.terminate('已停止；该消息未加入历史'); }

  private terminate(message: string): void {
    this.generation++;
    if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
    const reject: ((reason: Error) => void) | undefined = this.rejectPending;
    this.rejectPending = undefined;
    if (this.request) {
      try { this.request.destroy(); } catch (_) {}
      this.request = undefined;
    }
    if (reject) { reject(new Error(message)); }
  }

  send(config: DirectApiConfig, history: DirectMessage[], input: string): Promise<string> {
    if (this.request) { return Promise.reject(new Error('请等待当前回复')); }
    const checked: DirectApiConfig = validateDirectConfig(config);
    const endpoint: string = directEndpoint(checked);
    const body: string = directRequestBody(checked, history, input);
    let request: http.HttpRequest;
    try { request = http.createHttp(); } catch (_) { throw new Error('此设备暂不支持直连请求'); }
    this.request = request;
    const generation: number = ++this.generation;
    const headers: DirectHeaders = { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + checked.apiKey };
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST, header: headers, extraData: body,
      expectDataType: http.HttpDataType.STRING, usingCache: false,
      connectTimeout: 15000, readTimeout: 60000, maxLimit: 262144
    };
    return new Promise<string>((resolve, reject) => {
      this.rejectPending = reject;
      this.timer = setTimeout(() => {
        if (generation !== this.generation) { return; }
        this.terminate('API 请求超时，请稍后再试');
      }, 65000);
      try {
        request.request(endpoint, options, (error: BusinessError, response: http.HttpResponse) => {
        if (generation !== this.generation) { return; }
        if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
        this.rejectPending = undefined;
        this.request = undefined;
        try { request.destroy(); } catch (_) {}
        if (error) {
          reject(new Error(error.code === 2300028 ? 'API 请求超时，请稍后再试' : '直连失败，请检查网络与 HTTPS 证书'));
          return;
        }
        if (response.responseCode < 200 || response.responseCode >= 300) {
          reject(new Error(directHttpError(response.responseCode)));
          return;
        }
        if (typeof response.result !== 'string') {
          reject(new Error('API 返回格式无效'));
          return;
        }
        try { resolve(parseDirectReply(response.result, checked.protocol)); } catch (_) {
          // Never expose server bodies or native error strings, which may contain credentials.
          reject(new Error('API 未返回有效完整文本'));
        }
        });
      } catch (_) {
        if (generation === this.generation) { this.terminate('直连失败，请检查网络与 HTTPS 证书'); }
      }
    });
  }
}

// Only successful pairs are committed: stop/failure + retry never duplicates a user message.
export class DirectConversation {
  private client: DirectApiClient = new DirectApiClient();
  private history: DirectMessage[] = [];
  private revision: number = 0;
  private busy: boolean = false;

  messages(): DirectMessage[] { return boundedDirectHistory(this.history); }
  cancel(): void { this.revision++; this.busy = false; this.client.cancel(); }
  reset(): void { this.cancel(); this.history = []; }

  async send(config: DirectApiConfig, input: string): Promise<string> {
    if (this.busy) { throw new Error('请等待当前回复'); }
    this.busy = true;
    const revision: number = this.revision;
    try {
      const reply: string = await this.client.send(config, this.history, input);
      if (revision !== this.revision) { throw new Error('已停止'); }
      this.history = boundedDirectHistory(this.history.concat([
        { role: 'user', content: input.trim() }, { role: 'assistant', content: reply }
      ]));
      return reply;
    } finally {
      if (revision === this.revision) { this.busy = false; }
    }
  }
}

function aesProperties(purpose: number): huks.HuksParam[] {
  return [
    { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
    { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
    { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: purpose },
    { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
    { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE }
  ];
}

async function cryptConfig(data: Uint8Array, nonce: Uint8Array, encrypt: boolean): Promise<Uint8Array> {
  const purpose: number = encrypt ? huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT : huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT;
  const properties: huks.HuksParam[] = aesProperties(purpose);
  properties.push({ tag: huks.HuksTag.HUKS_TAG_NONCE, value: nonce });
  properties.push({ tag: huks.HuksTag.HUKS_TAG_ASSOCIATED_DATA, value: new util.TextEncoder().encodeInto('dsh-direct-api-v1') });
  let input: Uint8Array = data;
  if (!encrypt) {
    if (data.length < 16) { throw new Error('安全配置损坏'); }
    properties.push({ tag: huks.HuksTag.HUKS_TAG_AE_TAG, value: data.slice(data.length - 16) });
    input = data.slice(0, data.length - 16);
  }
  const options: huks.HuksOptions = { properties: properties };
  const session: huks.HuksSessionHandle = await huks.initSession(KEY_ALIAS, options);
  try {
    const finish: huks.HuksOptions = { properties: properties, inData: input };
    const result: huks.HuksReturnResult = await huks.finishSession(session.handle, finish);
    if (!result.outData || result.outData.length === 0) { throw new Error('安全存储不可用'); }
    return result.outData;
  } catch (_) {
    try { await huks.abortSession(session.handle, options); } catch (_) {}
    throw new Error('安全存储不可用');
  }
}

export class DirectConfigStore {
  private context: common.Context;
  constructor(context: common.Context) { this.context = context; }

  async load(): Promise<DirectStoredConfig> {
    if (sessionConfig) {
      return { config: copyDirectConfig(sessionConfig), persistent: false, notice: '仅本次 App 进程保存；进程结束后需重新配置' };
    }
    try {
      const store: preferences.Preferences = await preferences.getPreferences(this.context, STORE_NAME);
      const raw = await store.get('sealed', '');
      if (typeof raw !== 'string' || raw.length === 0) {
        return { persistent: false, notice: '未配置；可手动输入，无需宿主' };
      }
      const sealed: SealedConfig = JSON.parse(raw) as SealedConfig;
      if (sealed.version !== 1 || typeof sealed.nonce !== 'string' || typeof sealed.data !== 'string') {
        throw new Error('安全配置损坏');
      }
      const base64: util.Base64Helper = new util.Base64Helper();
      const nonce: Uint8Array = base64.decodeSync(sealed.nonce);
      if (nonce.length !== 12) { throw new Error('安全配置损坏'); }
      const plain: Uint8Array = await cryptConfig(base64.decodeSync(sealed.data), nonce, false);
      const config: DirectApiConfig = validateDirectConfig(JSON.parse(new util.TextDecoder().decodeWithStream(plain)) as DirectApiConfig);
      plain.fill(0);
      return { config: config, persistent: true, notice: '配置已由系统 HUKS 加密保存' };
    } catch (_) {
      return { persistent: false, notice: '安全存储不可用或配置已失效，请重新填写；不会读取明文' };
    }
  }

  async save(config: DirectApiConfig): Promise<DirectStoredConfig> {
    const checked: DirectApiConfig = validateDirectConfig(config);
    // Remove the previous ciphertext first, so a failed replacement cannot silently restore old credentials.
    await this.clear();
    sessionConfig = copyDirectConfig(checked);
    try {
      const empty: huks.HuksOptions = { properties: [] };
      if (!await huks.isKeyItemExist(KEY_ALIAS, empty)) {
        const keyOptions: huks.HuksOptions = { properties: aesProperties(
          huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT) };
        await huks.generateKeyItem(KEY_ALIAS, keyOptions);
      }
      const nonce: Uint8Array = cryptoFramework.createRandom().generateRandomSync(12).data;
      const plain: Uint8Array = new util.TextEncoder().encodeInto(JSON.stringify(checked));
      let encrypted: Uint8Array;
      try { encrypted = await cryptConfig(plain, nonce, true); } finally { plain.fill(0); }
      const base64: util.Base64Helper = new util.Base64Helper();
      const sealed: SealedConfig = { version: 1, nonce: base64.encodeToStringSync(nonce), data: base64.encodeToStringSync(encrypted) };
      const store: preferences.Preferences = await preferences.getPreferences(this.context, STORE_NAME);
      await store.put('sealed', JSON.stringify(sealed));
      await store.flush();
      sessionConfig = undefined;
      return { config: checked, persistent: true, notice: '配置已由系统 HUKS 加密保存' };
    } catch (_) {
      return { config: checked, persistent: false, notice: '此设备安全存储不可用，仅本次 App 进程保存；绝不明文落盘' };
    }
  }

  async clear(): Promise<void> {
    const store: preferences.Preferences = await preferences.getPreferences(this.context, STORE_NAME);
    await store.delete('sealed');
    await store.flush();
    sessionConfig = undefined;
  }
}
