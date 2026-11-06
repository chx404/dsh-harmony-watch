import http from '@ohos.net.http';
import { ModelCatalog, SimpleResult, StateSnapshot, SessionsSnapshot } from './Types';

interface PairBody {
  code: string;
}

interface PromptBody {
  text: string;
  mode: string;
}

interface ApprovalBody {
  id: string;
  decision: string;
}

interface SelectBody {
  sessionId: string;
}

interface EventDetail {
  ok: boolean;
  text?: string;
  error?: string;
}

interface ModelBody {
  sessionId: string;
  provider: string;
  model: string;
}

export function normalizeUrl(raw: string): string {
  let h: string = (raw || '').trim();
  if (h.length === 0) {
    return '';
  }
  if (!h.startsWith('http://') && !h.startsWith('https://')) {
    h = 'http://' + h;
  }
  while (h.endsWith('/')) {
    h = h.substring(0, h.length - 1);
  }
  return h;
}

// 宿主靠这个头记住手表版本，排查时能直接看出装的哪一版。
const APP_VERSION = '2.1.7';

function buildHeader(token: string): Record<string, string> {
  const h: Record<string, string> = {
    'Content-Type': 'application/json',
    'x-dsh-watch-token': token,
    'x-dsh-watch-version': APP_VERSION
  };
  return h;
}

async function requestText(method: http.RequestMethod, url: string, token: string, body: string): Promise<string> {
  const req = http.createHttp();
  try {
    const options: http.HttpRequestOptions = {
      method: method,
      header: buildHeader(token),
      extraData: body,
      connectTimeout: 10000,
      readTimeout: 20000
    };
    const res = await req.request(url, options);
    const result: string | Object | ArrayBuffer = res.result;
    if (typeof result === 'string') {
      return result;
    }
    return '';
  } finally {
    req.destroy();
  }
}

/** 用 6 位配对码换长期令牌。 */
export async function pair(base: string, code: string): Promise<SimpleResult> {
  const body: PairBody = { code: code };
  let text: string = '';
  try {
    text = await requestText(http.RequestMethod.POST, normalizeUrl(base) + '/api/pair', '', JSON.stringify(body));
  } catch (e) {
    return { ok: false, error: '网络不通，检查地址和网络' };
  }
  try {
    const obj = JSON.parse(text) as SimpleResult;
    if (obj.ok === undefined) {
      return { ok: false, error: '配对失败' };
    }
    return obj;
  } catch (e) {
    return { ok: false, error: '返回值不是 JSON' };
  }
}

export async function fetchState(base: string, token: string): Promise<StateSnapshot> {
  const text = await requestText(http.RequestMethod.GET, normalizeUrl(base) + '/api/state', token, '');
  return JSON.parse(text) as StateSnapshot;
}

export async function fetchSessions(base: string, token: string): Promise<SessionsSnapshot> {
  const text = await requestText(http.RequestMethod.GET, normalizeUrl(base) + '/api/sessions?all=1', token, '');
  return JSON.parse(text) as SessionsSnapshot;
}

export async function sendPrompt(base: string, token: string, text: string, mode: string): Promise<SimpleResult> {
  const body: PromptBody = { text: text, mode: mode };
  const raw = await requestText(http.RequestMethod.POST, normalizeUrl(base) + '/api/prompt', token, JSON.stringify(body));
  return JSON.parse(raw) as SimpleResult;
}

export async function decideApproval(base: string, token: string, id: string, decision: string): Promise<SimpleResult> {
  const body: ApprovalBody = { id: id, decision: decision };
  const raw = await requestText(http.RequestMethod.POST, normalizeUrl(base) + '/api/approval', token, JSON.stringify(body));
  return JSON.parse(raw) as SimpleResult;
}

export async function selectSession(base: string, token: string, sessionId: string): Promise<SimpleResult> {
  const body: SelectBody = { sessionId: sessionId };
  const raw = await requestText(http.RequestMethod.POST, normalizeUrl(base) + '/api/select', token, JSON.stringify(body));
  return JSON.parse(raw) as SimpleResult;
}

export async function newSession(base: string, token: string): Promise<SimpleResult> {
  const raw = await requestText(http.RequestMethod.POST, normalizeUrl(base) + '/api/new', token, '{}');
  return JSON.parse(raw) as SimpleResult;
}

export async function cancelTurn(base: string, token: string): Promise<SimpleResult> {
  const raw = await requestText(http.RequestMethod.POST, normalizeUrl(base) + '/api/cancel', token, '{}');
  return JSON.parse(raw) as SimpleResult;
}


export async function fetchModels(base: string, token: string, sessionId: string): Promise<ModelCatalog> {
  const text = await requestText(http.RequestMethod.GET,
    normalizeUrl(base) + '/api/models?sessionId=' + encodeURIComponent(sessionId), token, '');
  return JSON.parse(text) as ModelCatalog;
}

export async function switchModel(base: string, token: string, sessionId: string,
  provider: string, model: string): Promise<SimpleResult> {
  const body: ModelBody = { sessionId: sessionId, provider: provider, model: model };
  const raw = await requestText(http.RequestMethod.POST, normalizeUrl(base) + '/api/model', token, JSON.stringify(body));
  return JSON.parse(raw) as SimpleResult;
}

export async function fetchEventDetail(base: string, token: string, sessionId: string,
  seq: number, t: number): Promise<string> {
  const text = await requestText(http.RequestMethod.GET,
    normalizeUrl(base) + '/api/event-detail?sessionId=' + encodeURIComponent(sessionId) +
      '&seq=' + seq + '&t=' + t, token, '');
  const obj = JSON.parse(text) as EventDetail;
  return obj.ok === true && obj.text !== undefined ? obj.text : '';
}


export async function ping(base: string): Promise<boolean> {
  try {
    const text = await requestText(http.RequestMethod.GET, normalizeUrl(base) + '/api/ping', '', '');
    const obj = JSON.parse(text) as SimpleResult;
    return obj.ok === true;
  } catch (e) {
    return false;
  }
}
