import http from '@ohos.net.http';
import { DirectApiConfig } from './DirectApi';

export interface ProvisionTicket {
  id: string;
  pagePath: string;
  expiresAt: number;
}

export interface ProvisionPoll {
  status: string;
  config?: DirectApiConfig;
}

interface ProvisionResponse {
  id?: string;
  pagePath?: string;
  expiresAt?: number;
  status?: string;
  config?: DirectApiConfig;
}

interface TicketBody {
  id: string;
}

interface ProvisionHeaders {
  'Content-Type': string;
  'x-dsh-watch-token': string;
}

const ROOT = '/api/direct-provision';
const UPDATE_HOST = '需更新并重启宿主';

// base 只能由父组件传入已配对的可达宿主地址。绝不从页面、Host 头或 API 地址推导。
function provisionBase(base: string): string {
  const value = base.trim().replace(/\/+$/, '');
  if (!/^https?:\/\/[^/?#@\s]+$/.test(value)) {
    throw new Error('请使用已配对的宿主地址');
  }
  return value;
}

function ticketId(id: string): string {
  if (!/^[A-Za-z0-9_-]{43}$/.test(id)) {
    throw new Error('临时配置票据无效，请重新生成');
  }
  return id;
}

async function provisionRequest(base: string, token: string, path: string,
  method: http.RequestMethod, payload: string, polling: boolean = false): Promise<ProvisionResponse> {
  const host = provisionBase(base);
  if (!token.trim()) {
    throw new Error('请先配对宿主');
  }
  const client = http.createHttp();
  const headers: ProvisionHeaders = { 'Content-Type': 'application/json', 'x-dsh-watch-token': token };
  try {
    const result = await client.request(host + path, {
      method: method,
      header: headers,
      extraData: payload,
      expectDataType: http.HttpDataType.STRING,
      usingCache: false,
      connectTimeout: 8000,
      readTimeout: 8000
    });
    const code = result.responseCode;
    if (polling && (code === 404 || code === 410)) {
      return { status: 'expired' };
    }
    if (code === 404 || code === 405 || code === 501) {
      throw new Error(UPDATE_HOST);
    }
    if (code === 401 || code === 403) {
      throw new Error('配置授权失败，请重新配对宿主');
    }
    if (code === 429) {
      throw new Error('临时票据已满，请取消旧票据或稍后重试');
    }
    if (code < 200 || code >= 300) {
      throw new Error('宿主配置请求失败，HTTP ' + code.toString());
    }
    try {
      const decoded = JSON.parse(result.result as string) as ProvisionResponse;
      if (!decoded || typeof decoded !== 'object') {
        throw new Error(UPDATE_HOST);
      }
      return decoded;
    } catch {
      throw new Error(UPDATE_HOST);
    }
  } finally {
    client.destroy();
  }
}

export async function startDirectProvision(base: string, token: string): Promise<ProvisionTicket> {
  const result = await provisionRequest(base, token, ROOT + '/start', http.RequestMethod.POST, '{}');
  if (typeof result.id !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(result.id) ||
    result.pagePath !== '/configure#' + result.id || typeof result.expiresAt !== 'number' ||
    !Number.isFinite(result.expiresAt) || result.expiresAt <= 0) {
    throw new Error(UPDATE_HOST);
  }
  return { id: result.id, pagePath: result.pagePath, expiresAt: result.expiresAt };
}

export async function pollDirectProvision(base: string, token: string, id: string): Promise<ProvisionPoll> {
  const body: TicketBody = { id: ticketId(id) };
  const result = await provisionRequest(base, token, ROOT + '/poll', http.RequestMethod.POST,
    JSON.stringify(body), true);
  if (result.status === 'pending' || result.status === 'expired' || result.status === 'cancelled') {
    return { status: result.status };
  }
  const config = result.config;
  if (result.status !== 'ready' || !config || typeof config.baseUrl !== 'string' ||
    typeof config.apiKey !== 'string' || !config.apiKey.trim() || typeof config.model !== 'string' ||
    !config.model.trim() || (config.protocol !== 'chat' && config.protocol !== 'responses') ||
    !/^https:\/\/[^/?#@\s]+(?:\/[^?#\s]*)?$/.test(config.baseUrl)) {
    throw new Error('宿主返回的独立 API 配置无效，请重新生成票据');
  }
  // 只交还草稿；调用者必须展示 endpoint 供用户核对并手动保存，不能自动试连。
  return { status: 'ready', config: config };
}

export async function cancelDirectProvision(base: string, token: string, id: string): Promise<void> {
  const body: TicketBody = { id: ticketId(id) };
  await provisionRequest(base, token, ROOT, http.RequestMethod.DELETE, JSON.stringify(body), true);
}
