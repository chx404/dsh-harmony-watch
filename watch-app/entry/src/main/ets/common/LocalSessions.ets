import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import util from '@ohos.util';
import { DirectApiConfig, DirectMessage, validateDirectConfig } from './DirectApi';

export interface LocalSession {
  id: string;
  title: string;
  baseUrl: string;
  model: string;
  protocol: string;
  profileId?: string;
  createdAt: number;
  updatedAt: number;
  messages: DirectMessage[];
  draft: string;
}

export interface LocalSessionsSnapshot {
  sessions: LocalSession[];
  selectedId: string;
}

interface StoredSessions {
  version: number;
  sessions: LocalSession[];
  selectedId: string;
}

export const LOCAL_SESSION_MAX_COUNT: number = 30;
export const LOCAL_SESSION_MAX_MESSAGES: number = 100;
export const LOCAL_SESSION_MAX_BYTES: number = 4 * 1024 * 1024;
export const LOCAL_SESSION_HISTORY_NOTICE: string = '每个会话仅保留最近 100 条完整消息（50 轮）';
export const LOCAL_SESSION_STORAGE_NOTICE: string = '聊天正文以明文保存在应用私有目录，不是加密聊天记录；API 配置独立保存，修改或切换 API 不删除聊天';

const STORE_NAME: string = 'dsh_local_sessions_v1';
const SNAPSHOT_KEY: string = 'snapshot';
const MAX_DRAFT: number = 2000;
const MAX_REPLY: number = 12000;
const MAX_TITLE: number = 32;
let idCounter: number = 0;
// One queue also protects distinct store instances using the same preferences file.
let operations: Promise<void> = Promise.resolve();
let preferencesNeedReload: boolean = false;

function cloneSession(session: LocalSession): LocalSession {
  // Never stringify caller objects: they can contain extra fields such as apiKey.
  const copy: LocalSession = {
    id: session.id, title: session.title, baseUrl: session.baseUrl,
    model: session.model, protocol: session.protocol,
    createdAt: session.createdAt, updatedAt: session.updatedAt,
    messages: session.messages.map((message: DirectMessage): DirectMessage => {
      return { role: message.role, content: message.content };
    }),
    draft: session.draft
  };
  if (session.profileId) { copy.profileId = session.profileId; }
  return copy;
}

function cloneSnapshot(snapshot: LocalSessionsSnapshot): LocalSessionsSnapshot {
  return {
    sessions: snapshot.sessions.map((session: LocalSession): LocalSession => cloneSession(session)),
    selectedId: snapshot.selectedId
  };
}

function validId(id: string): boolean {
  return typeof id === 'string' && /^local-[a-zA-Z0-9_-]{1,120}$/.test(id);
}

function validDate(value: number): boolean {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;
}

function validMessage(message: DirectMessage, role: string, max: number): boolean {
  return message !== null && typeof message === 'object' && !Array.isArray(message) &&
    message.role === role && typeof message.content === 'string' &&
    message.content.trim().length > 0 && message.content.length <= max;
}

function checkedSession(value: LocalSession, recovering: boolean): LocalSession {
  if (value === null || typeof value !== 'object' || Array.isArray(value) ||
    !validId(value.id) || typeof value.title !== 'string' || value.title.length > MAX_TITLE ||
    typeof value.baseUrl !== 'string' || typeof value.model !== 'string' ||
    typeof value.protocol !== 'string' || !validDate(value.createdAt) ||
    !validDate(value.updatedAt) || value.updatedAt < value.createdAt ||
    typeof value.draft !== 'string' || value.draft.length > MAX_DRAFT || !Array.isArray(value.messages) ||
    (value.profileId !== undefined && !/^api-[A-Za-z0-9_-]{1,120}$/.test(value.profileId))) {
    throw new Error('本地会话字段无效');
  }
  // Only these three binding fields are accepted. No parsed object is cast to config.
  // The synthetic validation key is never stored and is not an account credential.
  const binding: DirectApiConfig = validateDirectConfig({
    baseUrl: value.baseUrl, model: value.model, protocol: value.protocol,
    apiKey: 'local-session-binding-validation'
  });
  const messages: DirectMessage[] = [];
  for (let i: number = 0; i < value.messages.length; i += 2) {
    const user: DirectMessage = value.messages[i];
    const assistant: DirectMessage = value.messages[i + 1];
    if (user !== undefined && assistant !== undefined && validMessage(user, 'user', MAX_DRAFT) &&
      validMessage(assistant, 'assistant', MAX_REPLY)) {
      messages.push({ role: 'user', content: user.content });
      messages.push({ role: 'assistant', content: assistant.content });
    } else if (!recovering) {
      throw new Error('历史只能保存完整成功的 user/assistant 消息对；未完成消息请保存为草稿');
    }
  }
  // Trim whole pairs only; request context remains separately bounded by DirectApi.
  return {
    id: value.id, title: value.title, baseUrl: binding.baseUrl,
    model: binding.model, protocol: binding.protocol, profileId: value.profileId,
    createdAt: value.createdAt, updatedAt: value.updatedAt,
    messages: messages.slice(-LOCAL_SESSION_MAX_MESSAGES), draft: value.draft
  };
}

function snapshotText(snapshot: LocalSessionsSnapshot): string {
  if (snapshot.sessions.length > LOCAL_SESSION_MAX_COUNT) {
    throw new Error('本地会话已达 30 个上限，请先删除不需要的会话');
  }
  const stored: StoredSessions = {
    version: 1,
    sessions: snapshot.sessions.map((session: LocalSession): LocalSession => cloneSession(session)),
    selectedId: snapshot.selectedId
  };
  const raw: string = JSON.stringify(stored);
  if (raw.length > LOCAL_SESSION_MAX_BYTES ||
    new util.TextEncoder().encodeInto(raw).length > LOCAL_SESSION_MAX_BYTES) {
    throw new Error('本地会话总大小超过 4 MiB，请先删除不需要的会话或缩短内容');
  }
  return raw;
}

function titleFrom(messages: DirectMessage[]): string {
  return messages.length > 0 ? messages[0].content.trim().replace(/\s+/g, ' ').slice(0, MAX_TITLE) : '新对话';
}

export class LocalSessionStore {
  private context: common.Context;
  private snapshot: LocalSessionsSnapshot = { sessions: [], selectedId: '' };

  constructor(context: common.Context) { this.context = context; }

  private serial<T>(action: () => Promise<T>): Promise<T> {
    const result: Promise<T> = operations.then(action);
    // A rejected write must not poison later retry/load operations.
    operations = result.then((): void => {}, (): void => {});
    return result;
  }

  private async preferencesStore(): Promise<preferences.Preferences> {
    if (preferencesNeedReload) {
      // put() changes preferences' own cache before flush(). Never reload that
      // uncommitted cache after a failed flush; retry eviction if it also failed.
      try {
        await preferences.removePreferencesFromCache(this.context, STORE_NAME);
        preferencesNeedReload = false;
      } catch (_) {
        throw new Error('本地会话缓存恢复失败，请重试加载；未覆盖已有会话');
      }
    }
    return preferences.getPreferences(this.context, STORE_NAME);
  }

  private async readSnapshot(): Promise<LocalSessionsSnapshot> {
    let raw: preferences.ValueType;
    try {
      const store: preferences.Preferences = await this.preferencesStore();
      if (!await store.has(SNAPSHOT_KEY)) { return { sessions: [], selectedId: '' }; }
      raw = await store.get(SNAPSHOT_KEY, '');
    } catch (_) {
      throw new Error('本地会话读取失败，请重试；未覆盖已有会话');
    }
    if (typeof raw !== 'string' || raw.length > LOCAL_SESSION_MAX_BYTES ||
      new util.TextEncoder().encodeInto(raw).length > LOCAL_SESSION_MAX_BYTES) {
      throw new Error('本地会话主快照损坏或超过 4 MiB；未覆盖已有数据');
    }
    let stored: StoredSessions;
    try {
      stored = JSON.parse(raw) as StoredSessions;
    } catch (_) {
      throw new Error('本地会话主快照 JSON 损坏；未覆盖已有数据');
    }
    if (stored === null || typeof stored !== 'object' || Array.isArray(stored) || stored.version !== 1 ||
      !Array.isArray(stored.sessions) || typeof stored.selectedId !== 'string') {
      throw new Error('本地会话主快照格式损坏；未覆盖已有数据');
    }
    const sessions: LocalSession[] = [];
    for (let i: number = 0; i < stored.sessions.length; i++) {
      try {
        const session: LocalSession = checkedSession(stored.sessions[i], true);
        if (!sessions.some((item: LocalSession): boolean => item.id === session.id)) { sessions.push(session); }
      } catch (_) {
        // Isolate malformed entries rather than discarding other valid sessions.
      }
    }
    if (stored.sessions.length > 0 && sessions.length === 0) {
      throw new Error('本地会话主快照没有有效会话；未覆盖已有数据');
    }
    const selectedId: string = sessions.some((session: LocalSession): boolean => session.id === stored.selectedId) ?
      stored.selectedId : (sessions.length > 0 ? sessions[0].id : '');
    const result: LocalSessionsSnapshot = { sessions: sessions, selectedId: selectedId };
    snapshotText(result);
    return result;
  }

  private async commit(snapshot: LocalSessionsSnapshot): Promise<void> {
    const raw: string = snapshotText(snapshot);
    const store: preferences.Preferences = await this.preferencesStore();
    try {
      // A single versioned key, never several independently flushed entries.
      await store.put(SNAPSHOT_KEY, raw);
      await store.flush();
    } catch (_) {
      preferencesNeedReload = true;
      try {
        await preferences.removePreferencesFromCache(this.context, STORE_NAME);
        preferencesNeedReload = false;
      } catch (_) {}
      throw new Error('本地会话保存失败；内存未提交，请重试加载或保存');
    }
    // Publish only after the complete snapshot has flushed successfully.
    this.snapshot = cloneSnapshot(snapshot);
  }

  async load(): Promise<LocalSessionsSnapshot> {
    return this.serial(async (): Promise<LocalSessionsSnapshot> => {
      const snapshot: LocalSessionsSnapshot = await this.readSnapshot();
      this.snapshot = cloneSnapshot(snapshot);
      return cloneSnapshot(snapshot);
    });
  }

  async create(config: DirectApiConfig, profileId: string = ''): Promise<LocalSession> {
    if (profileId !== '' && !/^api-[A-Za-zA-Z0-9_-]{1,120}$/.test(profileId)) { throw new Error('API 配置绑定无效'); }
    const checked: DirectApiConfig = validateDirectConfig(config);
    // Deliberately do not close over config/checked (or their apiKey) in the queue.
    const baseUrl: string = checked.baseUrl;
    const model: string = checked.model;
    const protocol: string = checked.protocol;
    return this.serial(async (): Promise<LocalSession> => {
      const snapshot: LocalSessionsSnapshot = await this.readSnapshot();
      const now: number = Date.now();
      let id: string;
      do {
        idCounter++;
        id = 'local-' + now.toString(36) + '-' + idCounter.toString(36) + '-' +
          Math.floor(Math.random() * 0x100000000).toString(36);
      } while (snapshot.sessions.some((session: LocalSession): boolean => session.id === id));
      const session: LocalSession = {
        id: id, title: '新对话', baseUrl: baseUrl, model: model, protocol: protocol,
        createdAt: now, updatedAt: now, messages: [], draft: ''
      };
      if (profileId !== '') { session.profileId = profileId; }
      snapshot.sessions.push(session);
      snapshot.selectedId = id;
      await this.commit(snapshot);
      return cloneSession(session);
    });
  }

  async select(id: string): Promise<LocalSession> {
    return this.serial(async (): Promise<LocalSession> => {
      const snapshot: LocalSessionsSnapshot = await this.readSnapshot();
      const session: LocalSession | undefined = snapshot.sessions.find((item: LocalSession): boolean => item.id === id);
      if (!session) { throw new Error('本地会话不存在'); }
      snapshot.selectedId = id;
      await this.commit(snapshot);
      return cloneSession(session);
    });
  }

  async save(session: LocalSession): Promise<void> {
    // Capture a validated whitelist copy immediately, before an asynchronous queue wait.
    const input: LocalSession = checkedSession(session, false);
    const firstTitle: string = titleFrom(session.messages);
    return this.serial(async (): Promise<void> => {
      const snapshot: LocalSessionsSnapshot = await this.readSnapshot();
      const index: number = snapshot.sessions.findIndex((item: LocalSession): boolean => item.id === input.id);
      if (index < 0) { throw new Error('本地会话不存在；请先新建会话'); }
      const previous: LocalSession = snapshot.sessions[index];
      if (previous.baseUrl !== input.baseUrl || previous.model !== input.model || previous.protocol !== input.protocol ||
        previous.createdAt !== input.createdAt || (previous.profileId !== undefined && previous.profileId !== input.profileId)) {
        throw new Error('不能更改已有会话的 API 地址、模型、协议或创建时间；请新建会话');
      }
      input.title = previous.messages.length === 0 && input.messages.length > 0 ? firstTitle : previous.title;
      input.updatedAt = Math.max(Date.now(), previous.updatedAt);
      snapshot.sessions[index] = input;
      await this.commit(snapshot);
    });
  }

  async remove(id: string): Promise<void> {
    return this.serial(async (): Promise<void> => {
      const snapshot: LocalSessionsSnapshot = await this.readSnapshot();
      const index: number = snapshot.sessions.findIndex((item: LocalSession): boolean => item.id === id);
      if (index < 0) { throw new Error('本地会话不存在'); }
      snapshot.sessions.splice(index, 1);
      if (snapshot.selectedId === id) {
        snapshot.selectedId = snapshot.sessions.length > 0 ? snapshot.sessions[Math.min(index, snapshot.sessions.length - 1)].id : '';
      }
      await this.commit(snapshot);
    });
  }

  list(): LocalSession[] { return cloneSnapshot(this.snapshot).sessions; }
  currentId(): string { return this.snapshot.selectedId; }
}
