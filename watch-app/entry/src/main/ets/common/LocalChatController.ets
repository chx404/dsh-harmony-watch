import common from '@ohos.app.ability.common';
import { DirectApiClient, DirectApiConfig, DirectMessage, copyDirectConfig, validateDirectConfig } from './DirectApi';
import { ApiProfile, ApiProfileStore } from './ApiProfiles';
import { LocalSession, LocalSessionStore } from './LocalSessions';
import { DshEvent } from './Types';

// 本地会话与 DSH 事件流完全分离；只在展示层转换成同一种气泡数据。
export class LocalChatController {
  private store: LocalSessionStore;
  private configStore: ApiProfileStore;
  private client: DirectApiClient = new DirectApiClient();
  private config?: DirectApiConfig;
  private selected?: LocalSession;
  private loading?: Promise<void>;
  private loaded: boolean = false;
  private busy: boolean = false;
  private revision: number = 0;
  private pending: string = '';
  private notice: string = '';
  private writeBusy: boolean = false;
  private changed: () => void;

  constructor(context: common.Context, changed: () => void) {
    this.store = new LocalSessionStore(context);
    this.configStore = new ApiProfileStore(context);
    this.changed = changed;
  }

  async initialize(): Promise<void> {
    if (this.loaded) { return; }
    if (this.loading) { return this.loading; }
    this.loading = this.restore();
    try { await this.loading; } finally { this.loading = undefined; }
  }

  private async restore(): Promise<void> {
    const saved = await this.store.load();
    await this.configStore.load();
    const active = this.configStore.active();
    this.config = active ? copyDirectConfig(active) : undefined;
    this.selected = saved.sessions.find((item: LocalSession) => item.id === saved.selectedId);
    this.notice = this.selected && this.selected.draft ? '上次未完成的输入已恢复，可编辑后重试' : '';
    this.loaded = true;
    this.changed();
  }

  sessions(): LocalSession[] { return this.store.list(); }
  current(): LocalSession | undefined {
    const selected = this.selected;
    if (!selected) { return undefined; }
    return this.store.list().find((item: LocalSession) => item.id === selected.id);
  }
  isBusy(): boolean { return this.busy || this.writeBusy; }
  status(): string { return this.notice; }
  hasConfig(): boolean { return this.config !== undefined; }

  profiles(): ApiProfile[] { return this.configStore.list(); }
  activeProfileId(): string {
    const current = this.current();
    return current && current.profileId ? current.profileId : (this.configStore.active()?.id || '');
  }

  async reloadProfiles(): Promise<void> {
    await this.initialize();
    await this.configStore.load();
    const active = this.configStore.active();
    this.config = active ? copyDirectConfig(active) : undefined;
    this.changed();
  }

  private sessionConfig(session: LocalSession): DirectApiConfig {
    if (!this.config) { throw new Error('请先设置 API Key；本地历史仍可阅读'); }
    const profiles = this.configStore.list();
    let profile: ApiProfile | undefined;
    if (session.profileId) {
      profile = profiles.find((item: ApiProfile) => item.id === session.profileId);
      if (!profile) { throw new Error('会话的 API 配置已删除；历史仍保留，请重新添加配置并选择'); }
    } else {
      const candidates = profiles.filter((item: ApiProfile) => item.baseUrl === session.baseUrl &&
        item.model === session.model && item.protocol === session.protocol);
      if (candidates.length === 1) { profile = candidates[0]; }
      else if (candidates.length > 1) { throw new Error('有多套匹配配置，请在模型小窗明确选择此会话的 API'); }
      else { throw new Error('请先添加与此会话地址和模型匹配的 API；历史仍保留'); }
    }
    if (profile.baseUrl !== session.baseUrl || profile.model !== session.model || profile.protocol !== session.protocol) {
      throw new Error('该 API 的地址或模型已修改，请在小窗选择后新建对话；旧历史未删除');
    }
    return validateDirectConfig({ baseUrl: session.baseUrl, model: session.model,
      protocol: session.protocol, apiKey: profile.apiKey });
  }

  async configured(config: DirectApiConfig): Promise<void> {
    await this.initialize();
    const profile = await this.configStore.upsert(config);
    await this.useProfile(profile.id);
  }

  async useProfile(id: string): Promise<void> {
    await this.initialize();
    if (this.writeBusy || this.unsaved) { throw new Error('请先完成回复保存再切换 API'); }
    this.cancel(); this.writeBusy = true; this.changed();
    try {
      const profile = await this.configStore.select(id);
      this.config = copyDirectConfig(profile);
      const current = this.current();
      const sameBinding: boolean = current !== undefined && current.baseUrl === profile.baseUrl &&
        current.model === profile.model && current.protocol === profile.protocol;
      if (current && sameBinding && (!current.profileId || current.profileId === profile.id)) {
        if (!current.profileId) { current.profileId = profile.id; await this.store.save(current); this.selected = this.current(); }
        this.notice = 'API 已选中，会话历史保留';
      } else {
        this.selected = await this.store.create(profile, profile.id);
        this.notice = '已选择 API，原会话保留在会话列表';
      }
    } finally { this.writeBusy = false; this.changed(); }
  }

  credentialsCleared(): void {
    this.cancel(); this.config = undefined;
    this.notice = 'API 配置已清除，本地会话和历史仍保留'; this.changed();
  }

  async open(): Promise<boolean> {
    await this.initialize();
    if (this.selected) { this.changed(); return true; }
    if (!this.config) { return false; }
    await this.create(); return true;
  }

  async create(): Promise<void> {
    await this.initialize();
    if (this.writeBusy) { throw new Error('正在保存，请稍后'); }
    if (this.unsaved) { throw new Error('请先重试保存已收到的回复'); }
    if (!this.config) { throw new Error('请先设置独立 API'); }
    this.cancel(); this.writeBusy = true; this.changed();
    try {
      this.selected = await this.store.create(this.config, this.configStore.active()?.id || '');
      this.notice = ''; this.changed();
    } finally { this.writeBusy = false; this.changed(); }
  }

  async select(id: string): Promise<void> {
    await this.initialize();
    if (this.writeBusy) { throw new Error('正在保存，请稍后'); }
    if (this.unsaved) { throw new Error('请先重试保存已收到的回复'); }
    this.cancel(); this.writeBusy = true;
    try {
      this.selected = await this.store.select(id);
      if (this.selected.profileId && this.configStore.list().some((item: ApiProfile) => item.id === this.selected?.profileId)) {
        const active = await this.configStore.select(this.selected.profileId);
        this.config = copyDirectConfig(active);
      }
      this.notice = this.selected.draft ? '未完成的输入已恢复，可编辑后重试' : '';
    } finally { this.writeBusy = false; this.changed(); }
  }

  async saveDraft(text: string): Promise<void> {
    const session = this.current();
    if (!session) { return; }
    session.draft = text.slice(0, 2000);
    await this.store.save(session);
    this.selected = this.current();
    this.changed();
  }

  cancel(): void {
    this.revision++;
    this.client.cancel();
    if (this.busy) { this.notice = '已停止，输入保留在本地草稿；可编辑后重试'; }
    this.busy = false; this.pending = ''; this.changed();
  }

  async send(text: string): Promise<void> {
    await this.initialize();
    if (this.busy || this.writeBusy) { throw new Error('请等待当前请求或保存完成'); }
    if (this.unsaved) { throw new Error('回复尚未保存，请重试保存，不要重发'); }
    const session = this.current();
    if (!session) { throw new Error('请先新建或选择本地会话'); }
    const config = this.sessionConfig(session);
    const input: string = text.trim();
    if (!input || input.length > 2000) { throw new Error('请输入 1–2000 字消息'); }
    const revision: number = ++this.revision;
    this.busy = true; this.pending = input; this.notice = '正在直连 API…'; this.changed();
    session.draft = input;
    let ownsWrite: boolean = false;
    try {
      // 先落盘草稿，持久化失败时绝不发送，避免用户以为消息已保存。
      await this.store.save(session);
      if (revision !== this.revision) { return; }
      const reply: string = await this.client.send(config, session.messages, input);
      if (revision !== this.revision) { return; }
      session.messages = session.messages.concat([{ role: 'user', content: input }, { role: 'assistant', content: reply }]);
      session.draft = '';
      this.writeBusy = true; ownsWrite = true;
      try {
        await this.store.save(session);
      } catch (_) {
        // 保留已经收到的正文，允许重试存盘，不自动重发产生重复计费。
        this.unsaved = session;
        throw new Error('回复已收到但未存盘，请点保存重试；不要重新发送');
      }
      if (revision !== this.revision) { return; }
      this.selected = this.current(); this.notice = ''; this.pending = '';
    } catch (error) {
      if (revision === this.revision) { this.notice = (error as Error).message; }
      throw new Error((error as Error).message);
    } finally {
      if (revision === this.revision) { this.busy = false; this.pending = ''; }
      if (ownsWrite) { this.writeBusy = false; }
      this.changed();
    }
  }

  private unsaved?: LocalSession;
  hasUnsavedReply(): boolean { return this.unsaved !== undefined; }
  async retrySave(): Promise<void> {
    if (!this.unsaved || this.writeBusy || this.busy) { return; }
    this.writeBusy = true;
    try {
      await this.store.save(this.unsaved); this.unsaved = undefined;
      this.selected = this.current(); this.notice = '回复已保存';
    } finally { this.writeBusy = false; this.changed(); }
  }

  async removeCurrent(): Promise<void> {
    const session = this.current();
    if (!session) { return; }
    if (this.writeBusy) { throw new Error('正在保存，请稍后'); }
    if (this.unsaved) { throw new Error('请先重试保存已收到的回复'); }
    this.cancel(); this.writeBusy = true; this.changed();
    try {
      await this.store.remove(session.id);
      this.selected = this.store.list().find((item: LocalSession) => item.id === this.store.currentId());
      this.notice = '已删除本地会话';
    } finally { this.writeBusy = false; this.changed(); }
  }

  events(): DshEvent[] {
    const current = this.current();
    if (!current) { return []; }
    const shown: LocalSession = this.unsaved && this.unsaved.id === current.id ? this.unsaved : current;
    const events: DshEvent[] = shown.messages.map((message: DirectMessage, index: number): DshEvent => ({
      seq: index + 1, t: shown.createdAt + index, sessionId: shown.id,
      kind: message.role, text: message.content
    }));
    if (this.busy && this.pending) {
      events.push({ seq: events.length + 1, t: Date.now(), sessionId: shown.id, kind: 'user', text: this.pending });
    }
    if (this.notice) {
      events.push({ seq: events.length + 1, t: Date.now(), sessionId: shown.id, kind: 'info', text: this.notice });
    }
    return events;
  }
}
