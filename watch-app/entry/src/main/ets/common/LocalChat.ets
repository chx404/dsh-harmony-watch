import common from '@ohos.app.ability.common';
import {
  DirectApiConfig, DirectConfigStore, DirectConversation, DirectMessage,
  DirectStoredConfig, copyDirectConfig, validateDirectConfig, normalizeDirectProvisionHost, directProvisionQrLink
} from './DirectApi';
import { ProvisionTicket, startDirectProvision, pollDirectProvision, cancelDirectProvision } from './DirectProvision';
import { CrownElastic } from './CrownElastic';
import { CrownMenu, CrownMenuItem } from './CrownMenu';
import { ApiProfile, ApiProfilesSnapshot, ApiProfileStore } from './ApiProfiles';

const DIRECT_TEXT: string = '#EDF4F3';
const DIRECT_DIM: string = '#9BAFB3';
const DIRECT_MINT: string = '#ADE9D9';

@Component
export struct LocalChat {
  @Prop screenWidth: number = 233;
  @Prop screenHeight: number = 233;
  @Prop hostBase: string = '';
  @Prop hostToken: string = '';
  @Prop settingsOnly: boolean = false;
  @Prop profileId: string = '';
  @Prop @Watch('backRequested') backRequest: number = 0;
  onRequestBack: () => void = () => {};
  onEditingChanged: (editing: boolean) => void = () => {};
  onConfigured: (config: DirectApiConfig) => void = () => {};
  onProfileConfigured: (profile: ApiProfile) => void = () => {};
  onProfilesChanged: () => void = () => {};
  onConfigCleared: () => void = () => {};
  onClose: () => void = () => {};
  @StorageLink('appInBackground') @Watch('backgroundChanged') appInBackground: boolean = false;
  @State @Watch('pageChanged') page: string = 'settings';
  @State profiles: ApiProfile[] = [];
  @State selectedProfileId: string = '';
  @State editingProfileId: string = '';
  @State nameDraft: string = '';
  @State inputEditing: boolean = false;
  @State baseDraft: string = 'https://api.openai.com/v1';
  @State modelDraft: string = '';
  @State keyDraft: string = '';
  @State protocolDraft: string = 'chat';
  @State prompt: string = '';
  @State messages: DirectMessage[] = [];
  @State pendingText: string = '';
  @State busy: boolean = false;
  @State saving: boolean = false;
  @State loading: boolean = true;
  @State configured: boolean = false;
  @State status: string = '读取 API 配置…';
  @State storageNotice: string = '';
  @State qrValue: string = '';
  @State qrBusy: boolean = false;
  @State imported: boolean = false;
  @State clearArmed: boolean = false;
  @State saveArmed: boolean = false;
  @State crownStretch: number = 0;
  private crownMotion: CrownElastic = new CrownElastic((stretch: number) => { this.crownStretch = stretch; }, 36);
  private activeConfig?: DirectApiConfig;
  private store?: DirectConfigStore;
  private profileStore?: ApiProfileStore;
  private conversation: DirectConversation = new DirectConversation();
  private alive: boolean = false;
  private uiGeneration: number = 0;
  private provisionGeneration: number = 0;
  private provisionTimer: number = -1;
  private provisionExpiry: number = -1;
  private ticket?: ProvisionTicket;
  private ticketBase: string = '';
  private ticketToken: string = '';
  private ticketDeadline: number = 0;
  private scroll: Scroller = new Scroller();
  private settingsScroll: Scroller = new Scroller();
  private focusTimer: number = -1;

  private pageChanged(): void {
    this.crownMotion.cancel();
    if (this.focusTimer >= 0) { clearTimeout(this.focusTimer); }
    this.focusTimer = setTimeout(() => {
      this.focusTimer = -1;
      if (!this.alive || this.appInBackground || this.inputEditing || this.page === 'compose') { return; }
      try { this.getUIContext().getFocusController().requestFocus('direct-crown-' + this.page); } catch (_) {}
    }, 50);
  }

  private handleCrown(event: CrownEvent): void {
    if (this.appInBackground || this.loading || this.inputEditing || (this.page !== 'settings' && this.page !== 'chat')) {
      this.crownMotion.cancel();
      return;
    }
    if (event.action === CrownAction.BEGIN) { this.crownMotion.begin(); return; }
    if (event.action === CrownAction.END) { this.crownMotion.end(); return; }
    if (event.action !== CrownAction.UPDATE) { return; }
    try {
      const scroller: Scroller = this.page === 'settings' ? this.settingsScroll : this.scroll;
      const offset: number = scroller.currentOffset().yOffset;
      const next: number = this.crownMotion.updateAtEdges(-event.degree * this.u(2.2), offset,
        offset <= 0.5, scroller.isAtEnd());
      scroller.scrollTo({ xOffset: 0, yOffset: next, animation: false });
    } catch (_) { this.crownMotion.cancel(); }
  }

  private u(value: number): number {
    return value * Math.min(this.screenWidth / 233, this.screenHeight / 233);
  }

  aboutToAppear(): void {
    this.alive = true;
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    if (this.settingsOnly) {
      this.profileStore = new ApiProfileStore(context);
    } else {
      // Compatibility only: production API settings never save/clear the legacy single key.
      this.store = new DirectConfigStore(context);
    }
    this.loadConfig();
  }

  aboutToDisappear(): void {
    this.crownMotion.cancel();
    this.onEditingChanged(false);
    this.alive = false;
    if (this.focusTimer >= 0) { clearTimeout(this.focusTimer); this.focusTimer = -1; }
    this.uiGeneration++;
    this.conversation.cancel();
    this.stopProvision();
    this.keyDraft = '';
    this.activeConfig = undefined;
  }

  private backgroundChanged(): void {
    if (this.appInBackground) {
      this.crownMotion.cancel();
      this.stopProvision();
      this.stopSend();
      if (this.page === 'qr') {
        this.page = 'settings';
        this.status = '已暂停扫码；回到前台后可重新生成';
      }
    }
  }

  private async loadConfig(): Promise<void> {
    if (this.settingsOnly) { await this.loadProfiles(); return; }
    if (!this.store) { return; }
    const generation: number = this.uiGeneration;
    const loaded: DirectStoredConfig = await this.store.load();
    if (!this.alive || generation !== this.uiGeneration) { return; }
    this.loading = false;
    this.storageNotice = loaded.notice;
    this.status = '';
    if (loaded.config) {
      this.activeConfig = copyDirectConfig(loaded.config);
      this.fillDraft(loaded.config);
      this.configured = true;
    }
    // Loading credentials must not navigate away from the parent's settings surface.
    this.page = this.settingsOnly || !loaded.config ? 'settings' : 'chat';
  }

  private async loadProfiles(): Promise<void> {
    if (!this.profileStore) { return; }
    const generation: number = this.uiGeneration;
    try {
      const snapshot: ApiProfilesSnapshot = await this.profileStore.load();
      if (!this.alive || generation !== this.uiGeneration) { return; }
      this.profiles = snapshot.profiles;
      this.selectedProfileId = snapshot.selectedId;
      this.storageNotice = snapshot.notice;
      this.refreshProfiles();
      this.discardDraft();
      this.page = 'profiles';
      this.status = '';
      this.loading = false;
      if (this.profileId) { this.openProfile(this.profileId); }
    } catch (_) {
      if (this.alive && generation === this.uiGeneration) {
        this.page = 'profiles';
        this.status = '无法读取 API 列表；原配置不会被删除，请重试';
      }
    } finally {
      if (this.alive && generation === this.uiGeneration) { this.loading = false; }
    }
  }

  private refreshProfiles(): void {
    if (!this.profileStore) { return; }
    this.profiles = this.profileStore.list();
    const active: ApiProfile | undefined = this.profileStore.active();
    this.selectedProfileId = active ? active.id : '';
    this.activeConfig = active ? copyDirectConfig(active) : undefined;
    this.configured = this.profiles.length > 0;
  }

  private profileItems(): CrownMenuItem[] {
    const items: CrownMenuItem[] = [];
    for (let index: number = 0; index < this.profiles.length; index++) {
      const profile: ApiProfile = this.profiles[index];
      items.push({ key: 'edit:' + profile.id, title: profile.name || 'API ' + (index + 1).toString(),
        caption: profile.id === this.selectedProfileId ? '当前 API · 点按编辑' : '已保存 · 点按编辑', symbol: '◇' });
    }
    items.push({ key: 'new', title: '新增 API', caption: '分别保存网址、模型和 Key', symbol: '+' });
    items.push({ key: 'scan', title: '手机扫码新增', caption: '导入新草稿，不覆盖已保存 API', symbol: '▦' });
    return items;
  }

  private profileAction(key: string): void {
    if (this.loading || this.saving) { return; }
    if (key === 'new' || key === 'scan') {
      this.openProfile();
      if (key === 'scan') { this.beginProvision(); }
    } else if (key.indexOf('edit:') === 0) {
      this.openProfile(key.slice(5));
    }
  }

  private discardDraft(): void {
    this.editingProfileId = '';
    this.nameDraft = '';
    this.baseDraft = '';
    this.modelDraft = '';
    this.keyDraft = '';
    this.protocolDraft = 'chat';
    this.imported = false;
    this.saveArmed = false;
    this.clearArmed = false;
  }

  private openProfile(id: string = ''): void {
    if (this.saving || this.loading) { return; }
    this.stopProvision();
    this.discardDraft();
    if (id) {
      const profile: ApiProfile | undefined = this.profiles.find((item: ApiProfile) => item.id === id);
      if (!profile) { return; }
      this.editingProfileId = profile.id;
      this.nameDraft = profile.name;
      this.fillDraft(profile);
    }
    this.status = '';
    this.page = 'settings';
    try { this.settingsScroll.scrollTo({ xOffset: 0, yOffset: 0, animation: false }); } catch (_) {}
  }

  private editingChanged(editing: boolean): void {
    this.inputEditing = editing;
    if (editing) { this.crownMotion.cancel(); } else { this.pageChanged(); }
    this.onEditingChanged(editing);
  }

  private fillDraft(config: DirectApiConfig): void {
    this.baseDraft = config.baseUrl;
    this.modelDraft = config.model;
    this.keyDraft = config.apiKey;
    this.protocolDraft = config.protocol;
  }

  private draft(): DirectApiConfig {
    return { baseUrl: this.baseDraft, apiKey: this.keyDraft, model: this.modelDraft, protocol: this.protocolDraft };
  }

  private draftChanged(): void {
    this.saveArmed = false;
    this.clearArmed = false;
    this.status = '';
  }

  private openSettings(): void {
    this.stopSend();
    this.stopProvision();
    this.saveArmed = false;
    this.clearArmed = false;
    this.page = 'settings';
    this.status = '';
  }

  private backRequested(): void {
    // Parent consumes system back and routes a single request to the actual local page.
    this.closePage();
  }

  private returnTo(page: string): void {
    animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.page = page; });
  }

  private closePage(): void {
    if (this.saving || this.inputEditing) { return; }
    if (this.page === 'qr') {
      this.stopProvision();
      this.returnTo('settings');
      this.status = '';
    } else if (this.settingsOnly) {
      this.stopProvision();
      this.discardDraft();
      this.status = '';
      if (this.page === 'settings') { this.returnTo('profiles'); } else { this.onClose(); }
    } else if (this.page === 'compose') {
      this.returnTo('chat');
    } else if (this.page === 'settings' && this.configured) {
      // Discard all unsaved imported or edited credentials, keeping the verified active endpoint.
      if (this.activeConfig) { this.fillDraft(this.activeConfig); }
      this.imported = false;
      this.returnTo('chat');
      this.status = '';
    } else {
      this.stopProvision();
      this.stopSend();
      this.imported = false;
      this.keyDraft = '';
      this.onClose();
    }
  }

  private async saveConfig(): Promise<void> {
    if (this.settingsOnly) { await this.saveProfile(); return; }
    if (this.loading || this.saving || !this.store || this.appInBackground) { return; }
    let checked: DirectApiConfig;
    try { checked = validateDirectConfig(this.draft()); } catch (_) {
      this.status = '请核对 HTTPS 地址、模型、Key 与协议；地址不能含凭证、查询或片段';
      return;
    }
    this.clearArmed = false;
    if (!this.saveArmed) {
      this.saveArmed = true;
      this.status = this.settingsOnly ? '请核对地址、模型及协议，再次点保存确认；本地会话保留' : '请核对配置，再次点保存确认；将新建空白对话';
      return;
    }
    this.saving = true;
    this.stopProvision();
    const generation: number = ++this.uiGeneration;
    if (!this.settingsOnly) {
      this.conversation.reset();
      this.messages = [];
      this.pendingText = '';
    }
    let notifyConfigured: boolean = false;
    try {
      const saved: DirectStoredConfig = await this.store.save(checked);
      if (!this.alive || generation !== this.uiGeneration) { return; }
      this.activeConfig = copyDirectConfig(checked);
      this.fillDraft(checked);
      this.configured = true;
      this.imported = false;
      this.storageNotice = saved.notice;
      this.status = saved.persistent ? 'API 配置已保存' : saved.notice;
      this.page = this.settingsOnly ? 'settings' : 'chat';
      notifyConfigured = this.settingsOnly;
    } catch (_) {
      if (this.alive && generation === this.uiGeneration) {
        this.status = '无法替换安全配置；未启用新 API，请重试';
      }
    } finally {
      if (this.alive && generation === this.uiGeneration) { this.saving = false; this.saveArmed = false; }
    }
    // Parent navigation is not part of the secure-store transaction.
    if (notifyConfigured) { this.onConfigured(copyDirectConfig(checked)); }
  }

  private async saveProfile(): Promise<void> {
    if (this.loading || this.saving || !this.profileStore || this.appInBackground || this.page !== 'settings') { return; }
    let checked: DirectApiConfig;
    try { checked = validateDirectConfig(this.draft()); } catch (_) {
      this.status = '请核对 HTTPS 地址、模型、Key 与协议；地址不能含凭证、查询或片段';
      return;
    }
    this.clearArmed = false;
    if (!this.saveArmed) {
      this.saveArmed = true;
      this.status = '再次点保存确认；保存后返回主聊天，本地会话和其他 API 保留';
      return;
    }
    this.saving = true;
    this.stopProvision();
    const generation: number = ++this.uiGeneration;
    let configuredProfile: ApiProfile | undefined;
    try {
      const profile: ApiProfile = await this.profileStore.upsert(checked, this.nameDraft.trim(), this.editingProfileId);
      // Remember an inserted id before selection: retry can never duplicate a successfully saved draft.
      if (!this.alive || generation !== this.uiGeneration) { return; }
      this.editingProfileId = profile.id;
      const selected: ApiProfile = await this.profileStore.select(profile.id);
      if (!this.alive || generation !== this.uiGeneration) { return; }
      this.refreshProfiles();
      this.nameDraft = selected.name;
      this.fillDraft(selected);
      this.imported = false;
      this.status = 'API 已保存，即将返回主聊天';
      configuredProfile = { id: selected.id, name: selected.name, baseUrl: selected.baseUrl,
        apiKey: selected.apiKey, model: selected.model, protocol: selected.protocol };
    } catch (_) {
      if (this.alive && generation === this.uiGeneration) {
        this.status = '保存或选择 API 失败；已保存的 API 不会被删除，可重试';
      }
    } finally {
      if (this.alive && generation === this.uiGeneration) { this.saving = false; this.saveArmed = false; }
    }
    // Parent owns chat popup/controller navigation; never enter the legacy local Chat here.
    if (configuredProfile) { this.onProfileConfigured(configuredProfile); }
  }

  private async removeProfile(): Promise<void> {
    if (this.loading || this.saving || !this.profileStore || this.appInBackground || !this.editingProfileId) { return; }
    this.saveArmed = false;
    if (!this.clearArmed) {
      this.clearArmed = true;
      this.status = '仅删除当前 API；其他 API 和本地会话保留，再次点删除确认';
      return;
    }
    this.saving = true;
    this.stopProvision();
    const generation: number = ++this.uiGeneration;
    let removed: boolean = false;
    try {
      await this.profileStore.remove(this.editingProfileId);
      if (!this.alive || generation !== this.uiGeneration) { return; }
      this.refreshProfiles();
      this.discardDraft();
      this.page = 'profiles';
      this.status = '当前 API 已删除，其他 API 和本地会话保留';
      removed = true;
    } catch (_) {
      if (this.alive && generation === this.uiGeneration) { this.status = '删除失败；原 API 保留，请重试'; }
    } finally {
      if (this.alive && generation === this.uiGeneration) { this.saving = false; this.clearArmed = false; }
    }
    if (removed) { this.onProfilesChanged(); }
  }

  private async clearConfig(): Promise<void> {
    if (this.settingsOnly) { await this.removeProfile(); return; }
    if (this.loading || this.saving || !this.store || this.appInBackground) { return; }
    this.saveArmed = false;
    if (!this.clearArmed) {
      this.clearArmed = true;
      this.status = '仅删除API配置，不删除本地会话；再次点清空确认';
      return;
    }
    this.saving = true;
    this.stopProvision();
    if (!this.settingsOnly) { this.stopSend(); }
    const generation: number = ++this.uiGeneration;
    let notifyCleared: boolean = false;
    try {
      await this.store.clear();
      if (!this.alive || generation !== this.uiGeneration) { return; }
      this.activeConfig = undefined;
      this.configured = false;
      this.keyDraft = '';
      this.modelDraft = '';
      this.imported = false;
      this.storageNotice = '';
      this.status = 'API 配置已删除，本地会话保留';
      this.page = 'settings';
      notifyCleared = true;
    } catch (_) {
      if (this.alive && generation === this.uiGeneration) { this.status = '清空失败，请重试；原配置仍保留'; }
    } finally {
      if (this.alive && generation === this.uiGeneration) { this.saving = false; this.clearArmed = false; }
    }
    if (notifyCleared) { this.onConfigCleared(); }
  }

  private stopSend(): void {
    this.conversation.cancel();
    if (this.busy) {
      this.uiGeneration++;
      this.busy = false;
      this.pendingText = '';
      this.status = '已停止；未加入历史，可编辑后重新发送';
    }
  }

  private newChat(): void {
    if (this.settingsOnly) { return; }
    this.stopSend();
    this.conversation.reset();
    this.messages = [];
    this.prompt = '';
    this.status = '已新建；旧对话仅在内存中，现已清除';
  }

  private async send(): Promise<void> {
    if (this.settingsOnly || this.busy || !this.activeConfig || this.appInBackground) { return; }
    const text: string = this.prompt.trim();
    if (!text || text.length > 2000) { this.status = '请输入 1–2000 字消息'; return; }
    this.busy = true;
    this.pendingText = text;
    this.status = '手表直连 API…';
    this.page = 'chat';
    const generation: number = ++this.uiGeneration;
    try {
      await this.conversation.send(this.activeConfig, text);
      if (!this.alive || generation !== this.uiGeneration) { return; }
      this.messages = this.conversation.messages();
      this.prompt = '';
      this.status = '';
      this.scroll.scrollEdge(Edge.Bottom);
    } catch (error) {
      if (!this.alive || generation !== this.uiGeneration) { return; }
      // DirectConversation produces only local sanitized errors; native/server strings never reach here.
      this.status = (error as Error).message;
    } finally {
      if (this.alive && generation === this.uiGeneration) {
        this.busy = false;
        this.pendingText = '';
      }
    }
  }

  private stopProvision(): void {
    this.provisionGeneration++;
    if (this.provisionTimer >= 0) { clearTimeout(this.provisionTimer); this.provisionTimer = -1; }
    if (this.provisionExpiry >= 0) { clearTimeout(this.provisionExpiry); this.provisionExpiry = -1; }
    const ticket: ProvisionTicket | undefined = this.ticket;
    const base: string = this.ticketBase;
    const token: string = this.ticketToken;
    this.ticket = undefined;
    this.ticketBase = '';
    this.ticketToken = '';
    this.qrValue = '';
    this.qrBusy = false;
    if (ticket) { cancelDirectProvision(base, token, ticket.id).catch(() => {}); }
  }

  private async beginProvision(): Promise<void> {
    if (this.loading || this.saving || this.qrBusy || this.appInBackground) { return; }
    if (!this.hostBase || !this.hostToken) {
      this.status = '扫码需先与 DSH 宿主配对；也可直接手动填写';
      return;
    }
    this.stopProvision();
    const generation: number = this.provisionGeneration;
    let base: string;
    try { base = normalizeDirectProvisionHost(this.hostBase); } catch (_) { this.status = '宿主地址无效，请手动配置'; return; }
    const token: string = this.hostToken;
    // A phone import is always a new draft, even when opened while editing an existing API.
    if (this.settingsOnly) { this.discardDraft(); }
    this.qrBusy = true;
    this.page = 'qr';
    this.status = '生成一次性配置链接…';
    try {
      const ticket: ProvisionTicket = await startDirectProvision(base, token);
      if (!this.alive || this.appInBackground || generation !== this.provisionGeneration) {
        cancelDirectProvision(base, token, ticket.id).catch(() => {});
        return;
      }
      this.ticket = ticket;
      this.ticketBase = base;
      this.ticketToken = token;
      const link: string = directProvisionQrLink(base, ticket.pagePath, ticket.id, ticket.expiresAt);
      if (ticket.pagePath.indexOf(token) >= 0 ||
        (this.keyDraft.length > 0 && ticket.pagePath.indexOf(this.keyDraft) >= 0)) {
        throw new Error('配置链接无效');
      }
      this.ticketDeadline = Math.min(ticket.expiresAt, Date.now() + 300000);
      this.qrValue = link;
      this.qrBusy = false;
      this.status = '手机扫码，5 分钟内有效；勿转发';
      this.provisionExpiry = setTimeout(() => {
        if (generation !== this.provisionGeneration) { return; }
        this.stopProvision();
        this.page = 'settings';
        this.status = '一次性链接已过期，可重新生成';
      }, this.ticketDeadline - Date.now());
      this.pollProvision(generation);
    } catch (error) {
      if (this.alive && generation === this.provisionGeneration) {
        this.stopProvision();
        this.page = 'settings';
        this.status = (error as Error).message === '需更新并重启宿主' ? '需更新并重启宿主；仍可手动填写' : '无法开启扫码配置；请检查宿主或手动填写';
      }
    }
  }

  private async pollProvision(generation: number): Promise<void> {
    if (!this.alive || this.appInBackground || generation !== this.provisionGeneration || !this.ticket) { return; }
    if (Date.now() >= this.ticketDeadline) {
      this.stopProvision(); this.page = 'settings'; this.status = '一次性链接已过期'; return;
    }
    const ticket: ProvisionTicket = this.ticket;
    try {
      const result = await pollDirectProvision(this.ticketBase, this.ticketToken, ticket.id);
      if (!this.alive || this.appInBackground || generation !== this.provisionGeneration) { return; }
      if (result.config && result.status === 'ready') {
        const checked: DirectApiConfig = validateDirectConfig(result.config);
        this.stopProvision();
        if (this.settingsOnly) { this.discardDraft(); }
        this.fillDraft(checked);
        this.imported = true;
        this.clearArmed = false;
        this.saveArmed = false;
        this.page = 'settings';
        this.status = this.settingsOnly ? '手机配置是新草稿，尚未启用；核对后保存并返回主聊天，不覆盖其他 API' : '手机配置待核对：确认地址、模型及协议后，点「保存并新建」；尚未启用';
        return;
      }
      if (result.status !== 'pending') {
        this.stopProvision(); this.page = 'settings'; this.status = '扫码已结束或过期，可重新生成'; return;
      }
      this.provisionTimer = setTimeout(() => { this.pollProvision(generation); }, 1800);
    } catch (_) {
      if (this.alive && generation === this.provisionGeneration) {
        this.stopProvision(); this.page = 'settings'; this.status = '扫码连接中断或配置无效；请手动核对后重试';
      }
    }
  }

  @Builder
  Pill(label: string, action: () => void, accent: boolean = false) {
    Button(label, { type: ButtonType.Capsule })
      .fontSize(this.u(11))
      .fontColor(accent ? '#102D29' : DIRECT_MINT)
      .backgroundColor(accent ? DIRECT_MINT : '#080E12')
      .height(this.u(36))
      .width('100%')
      .onClick(action)
  }

  @Builder
  Note(text: string) {
    Text(text).fontSize(this.u(10)).lineHeight(this.u(14)).fontColor(DIRECT_DIM)
      .width('100%').textAlign(TextAlign.Center)
  }

  @Builder
  Settings() {
    Scroll(this.settingsScroll) {
      Column({ space: this.u(10) }) {
        Text(this.imported ? '核对手机新草稿' : this.settingsOnly ? (this.editingProfileId ? '编辑已保存 API' : '新增 API') : '连接独立 API')
          .fontSize(this.u(12)).fontWeight(FontWeight.Medium).fontColor(this.imported ? '#EFC49A' : DIRECT_TEXT)
        Button(this.qrBusy ? '准备中…' : '手机填写', { type: ButtonType.Capsule })
          .height(this.u(40)).width('100%').fontSize(this.u(12))
          .backgroundColor(!this.configured ? DIRECT_MINT : '#080E12')
          .fontColor(!this.configured ? '#102D29' : DIRECT_MINT)
          .enabled(!this.loading && !this.saving && !this.qrBusy)
          .onClick(() => { this.draftChanged(); this.beginProvision(); })
        this.Note(this.settingsOnly ? '扫码另建新草稿；或在手表填写' : '或在手表填写')
        if (this.settingsOnly) {
          Column({ space: this.u(6) }) {
            Text('API 名称').fontSize(this.u(11)).fontColor(DIRECT_MINT).alignSelf(ItemAlign.Start)
            TextInput({ placeholder: '便于识别的名称', text: this.nameDraft })
              .fontSize(this.u(10)).height(this.u(40)).backgroundColor('#080E12').fontColor(DIRECT_TEXT).borderRadius(this.u(20))
              .enabled(!this.saving).maxLength(80).enableAutoFill(false)
              .onChange((value: string) => { this.nameDraft = value; this.draftChanged(); })
              .onEditChange((editing: boolean) => { this.editingChanged(editing); })
          }.width('100%').alignItems(HorizontalAlign.Start)
        }
        Column({ space: this.u(6) }) {
          Text('API 地址 · HTTPS').fontSize(this.u(11)).fontColor(DIRECT_MINT).alignSelf(ItemAlign.Start)
          TextInput({ placeholder: 'https://api.example.com/v1', text: this.baseDraft })
            .fontSize(this.u(10)).height(this.u(40)).backgroundColor('#080E12').fontColor(DIRECT_TEXT).borderRadius(this.u(20))
            .enabled(!this.saving).maxLength(2048).enableAutoFill(false)
            .onChange((value: string) => { this.baseDraft = value; this.draftChanged(); })
            .onEditChange((editing: boolean) => { this.editingChanged(editing); })
          Text('模型').fontSize(this.u(11)).fontColor(DIRECT_MINT).alignSelf(ItemAlign.Start)
          TextInput({ placeholder: '模型名称', text: this.modelDraft })
            .fontSize(this.u(10)).height(this.u(40)).backgroundColor('#080E12').fontColor(DIRECT_TEXT).borderRadius(this.u(20))
            .enabled(!this.saving).maxLength(200).enableAutoFill(false)
            .onChange((value: string) => { this.modelDraft = value; this.draftChanged(); })
            .onEditChange((editing: boolean) => { this.editingChanged(editing); })
          Text('API Key · 始终隐藏').fontSize(this.u(11)).fontColor(DIRECT_MINT).alignSelf(ItemAlign.Start)
          TextInput({ placeholder: 'API Key', text: this.keyDraft })
            .type(InputType.Password).showPasswordIcon(false).showPassword(false).copyOption(CopyOptions.None).enableAutoFill(false)
            .fontSize(this.u(10)).height(this.u(40)).backgroundColor('#080E12').fontColor(DIRECT_TEXT).borderRadius(this.u(20))
            .enabled(!this.saving).maxLength(8192)
            .onChange((value: string) => { this.keyDraft = value; this.draftChanged(); })
            .onEditChange((editing: boolean) => { this.editingChanged(editing); })
        }.width('100%').alignItems(HorizontalAlign.Start)
        Column({ space: this.u(6) }) {
          Text('请求协议').fontSize(this.u(11)).fontColor(DIRECT_MINT).alignSelf(ItemAlign.Start)
          Button(this.protocolDraft === 'chat' ? '✓ Chat Completions' : '○ Chat Completions', { type: ButtonType.Capsule })
            .fontSize(this.u(10)).height(this.u(36)).width('100%').fontColor(this.protocolDraft === 'chat' ? '#102D29' : DIRECT_DIM)
            .backgroundColor(this.protocolDraft === 'chat' ? DIRECT_MINT : '#080E12').enabled(!this.saving)
            .onClick(() => { this.protocolDraft = 'chat'; this.draftChanged(); })
          Button(this.protocolDraft === 'responses' ? '✓ Responses' : '○ Responses', { type: ButtonType.Capsule })
            .fontSize(this.u(10)).height(this.u(36)).width('100%').fontColor(this.protocolDraft === 'responses' ? '#102D29' : DIRECT_DIM)
            .backgroundColor(this.protocolDraft === 'responses' ? DIRECT_MINT : '#080E12').enabled(!this.saving)
            .onClick(() => { this.protocolDraft = 'responses'; this.draftChanged(); })
        }.width('100%')
        this.Note(this.settingsOnly ? 'Key 明文保存在应用私有空间，仅用于 API 鉴权，不进入链接或日志' : 'Key 仅用于 API 鉴权，不进入链接或日志')
        if (this.storageNotice && (this.configured || this.storageNotice.indexOf('未配置') !== 0)) {
          this.Note(this.storageNotice)
        }
        if (this.status) { this.Note(this.status) }
        this.Note(this.settingsOnly ? '保存后返回主聊天；未保存直接退出不会覆盖已有 API' : '保存后新建临时对话')
        this.Pill(this.saving ? '保存中…' : this.saveArmed ? (this.settingsOnly ? '确认保存并返回主聊天' : '确认保存') : this.settingsOnly ? '保存并返回主聊天' : '保存并新建', () => { this.saveConfig(); }, true)
        if (!this.settingsOnly || this.editingProfileId.length > 0) {
          this.Note('仅删除当前 API，不删除其他 API 或本地会话')
          this.Pill(this.clearArmed ? '确认删除当前 API' : '删除当前 API', () => { this.clearConfig(); })
        }
        this.Note('扫码优先 HTTPS；HTTP 仅在同一可信 WiFi 使用，链接勿转发')
        Blank().height(this.u(24))
      }.width(this.u(168)).padding({ top: this.u(62), bottom: this.u(88) })
        .translate({ y: this.crownStretch })
    }.width('100%').height('100%').scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: this.u(12) })))
      .onAppear(() => { this.pageChanged(); })
  }

  @Builder
  Chat() {
    Column({ space: this.u(5) }) {
      Row({ space: this.u(6) }) {
        Button('设置', { type: ButtonType.Capsule }).height(this.u(30)).width(this.u(70))
          .fontSize(this.u(11)).fontColor(DIRECT_MINT).backgroundColor('#080E12').onClick(() => { this.openSettings(); })
        Button('新建', { type: ButtonType.Capsule }).height(this.u(30)).width(this.u(70))
          .fontSize(this.u(11)).fontColor(DIRECT_MINT).backgroundColor('#080E12').onClick(() => { this.newChat(); })
      }
      Scroll(this.scroll) {
        Column({ space: this.u(8) }) {
          if (this.messages.length === 0 && !this.busy) {
            this.Note('独立对话\n消息仅发送给你确认的 API\n无需 DSH 宿主运行')
          }
          ForEach(this.messages, (message: DirectMessage, index: number) => {
            Column({ space: this.u(3) }) {
              Text(message.role === 'user' ? '你' : 'API').fontSize(this.u(9)).fontColor(DIRECT_MINT)
              Text(message.content).fontSize(this.u(12)).lineHeight(this.u(17)).fontColor(DIRECT_TEXT).width('100%')
            }.alignItems(HorizontalAlign.Start).width('100%').padding(this.u(9))
              .backgroundColor(message.role === 'user' ? '#16332F' : '#101C22').borderRadius(this.u(12))
          }, (message: DirectMessage, index: number) => index.toString() + ':' + message.role)
          if (this.busy) {
            this.Note('发送中：' + this.pendingText.slice(0, 80))
          }
          if (this.status) { this.Note(this.status) }
        }.width(this.u(170)).padding({ top: this.u(5), bottom: this.u(8) })
          .translate({ y: this.crownStretch })
      }.width(this.u(182)).height(this.u(67)).scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .onAppear(() => { this.pageChanged(); })
      Row().width(this.u(148)).height(this.u(1)).backgroundColor('#213A3B')
      Column() {
        if (this.busy) {
          this.Pill('停止', () => { this.stopSend(); }, true)
        } else {
          this.Pill(this.prompt ? '编辑并重试' : '写消息', () => { this.page = 'compose'; this.status = ''; }, true)
        }
      }.width(this.u(148))
    }.width(this.u(184)).height(this.u(147))
  }

  @Builder
  Compose() {
    Column({ space: this.u(8) }) {
      TextArea({ placeholder: '消息只发给独立 API', text: this.prompt })
        .fontSize(this.u(13)).fontColor(DIRECT_TEXT).backgroundColor('#101C22')
        .height(this.u(102)).width(this.u(164)).maxLength(2000).enableAutoFill(false)
        .onChange((value: string) => { this.prompt = value; })
        .onEditChange((editing: boolean) => { this.editingChanged(editing); })
      if (this.status) { this.Note(this.status) }
      Column() { this.Pill('发送', () => { this.send(); }, true) }.width(this.u(148))
    }.width(this.u(176)).height(this.u(147))
  }

  @Builder
  Provision() {
    Column({ space: this.u(4) }) {
      if (this.qrValue) {
        QRCode(this.qrValue).width(this.u(104)).height(this.u(104)).color('#000000').backgroundColor('#FFFFFF')
          .padding(this.u(6)).borderRadius(this.u(5))
      } else {
        Text('生成中…').fontSize(this.u(13)).fontColor(DIRECT_MINT).height(this.u(105))
      }
      Text(this.status).fontSize(this.u(9)).lineHeight(this.u(12)).fontColor(DIRECT_DIM)
        .width(this.u(166)).textAlign(TextAlign.Center).maxLines(2)
      Text('仅配置时需宿主；聊天由手表直连').fontSize(this.u(8)).fontColor(DIRECT_MINT)
        .width(this.u(166)).textAlign(TextAlign.Center)
    }.width(this.u(176)).height(this.u(147))
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      if (this.loading) {
        Column() {
          Text('读取 API 配置…').fontSize(this.u(12)).fontColor(DIRECT_DIM)
        }.width('100%').height('100%').justifyContent(FlexAlign.Center)
      } else if (this.settingsOnly && this.page === 'profiles') {
        CrownMenu({ screenWidth: this.screenWidth, title: 'API设置', subtitle: '',
          focusId: 'direct-crown-profiles', items: this.profileItems(),
          onAction: (key: string) => { this.profileAction(key); } })
          .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: -this.u(12) })))
        if (this.status || this.storageNotice) {
          Text(this.status || this.storageNotice).fontSize(this.u(8)).fontColor(DIRECT_DIM)
            .width(this.u(144)).maxLines(2).textAlign(TextAlign.Center)
            .position({ x: (this.screenWidth - this.u(144)) / 2, y: this.screenHeight - this.u(44) })
            .hitTestBehavior(HitTestMode.None)
        }
      } else if (this.page === 'settings') {
        this.Settings()
      } else if (this.page === 'qr') {
        Column() { this.Provision() }
          .width('100%').height('100%').justifyContent(FlexAlign.Center)
          .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: this.u(12) })))
      } else if (!this.settingsOnly && this.page === 'compose') {
        Column() { this.Compose() }.width('100%').height('100%').justifyContent(FlexAlign.Center)
          .transition(TransitionEffect.OPACITY)
      } else if (!this.settingsOnly) {
        Column() { this.Chat() }.width('100%').height('100%').justifyContent(FlexAlign.Center)
          .transition(TransitionEffect.OPACITY)
      }
      if (this.page !== 'profiles') {
        // Transparent overlay: content keeps the full viewport and scrolls behind this title.
        Text(this.page === 'qr' ? '扫码配置' : this.page === 'settings' ? 'API设置' : '独立 API')
          .fontSize(this.u(11)).fontColor(DIRECT_TEXT).textAlign(TextAlign.Center)
          .width(this.u(152)).height(this.u(30)).margin({ top: this.u(20) })
          .id('direct-crown-' + this.page).focusable(true).focusOnTouch(false).defaultFocus(true)
          .hitTestBehavior(HitTestMode.None)
          .onDigitalCrown((event: CrownEvent) => { this.handleCrown(event); })
      }
    }.width('100%').height('100%').backgroundColor('#060A0D')
      .linearGradient({ angle: 150, colors: [['#162D32', 0], ['#0B151C', 0.35], ['#060A0D', 0.8], ['#0B151B', 1]] })
      .clip(true)
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) { this.crownMotion.cancel(); }
      })
  }
}
