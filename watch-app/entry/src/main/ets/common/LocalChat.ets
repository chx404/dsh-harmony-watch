import common from '@ohos.app.ability.common';
import {
  DirectApiConfig, DirectConfigStore, DirectConversation, DirectMessage,
  DirectStoredConfig, copyDirectConfig, validateDirectConfig
} from './DirectApi';
import { WatchProvisionService } from './WatchProvisionService';
import { CrownElastic } from './CrownElastic';
import { CrownMenu, CrownMenuItem } from './CrownMenu';
import { ApiProfile, ApiProfilesSnapshot, ApiProfileStore } from './ApiProfiles';

const DIRECT_TEXT: string = '#F4F4F4';
const DIRECT_DIM: string = '#B5B5B5';
const DIRECT_ACCENT: string = '#F5F5F5';

@Component
export struct LocalChat {
  @Prop screenWidth: number = 233;
  @Prop screenHeight: number = 233;
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
  @State pendingEndpoint: string = '';
  @State pendingModel: string = '';
  @State pendingProtocol: string = '';
  private pendingImport?: DirectApiConfig;
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
  private watchProvision?: WatchProvisionService;
  private scroll: Scroller = new Scroller();
  private settingsScroll: Scroller = new Scroller();
  private provisionScroll: Scroller = new Scroller();
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
    if (this.appInBackground || this.loading || this.inputEditing ||
      (this.page !== 'settings' && this.page !== 'chat' && this.page !== 'qr' && this.page !== 'confirm')) {
      this.crownMotion.cancel();
      return;
    }
    if (event.action === CrownAction.BEGIN) { this.crownMotion.begin(); return; }
    if (event.action === CrownAction.END) { this.crownMotion.end(); return; }
    if (event.action !== CrownAction.UPDATE) { return; }
    try {
      const scroller: Scroller = this.page === 'settings' ? this.settingsScroll :
        (this.page === 'qr' || this.page === 'confirm' ? this.provisionScroll : this.scroll);
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
    this.clearPhoneImport();
    this.keyDraft = '';
    this.activeConfig = undefined;
  }

  private backgroundChanged(): void {
    if (this.appInBackground) {
      this.crownMotion.cancel();
      this.stopProvision();
      this.stopSend();
      if (this.page === 'qr' || this.page === 'confirm') {
        this.clearPhoneImport();
        this.page = 'settings';
        this.status = '已关闭临时配置服务；回到前台后可重新生成';
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
    if (this.page === 'qr' || this.page === 'confirm') {
      this.stopProvision();
      this.clearPhoneImport();
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
    this.watchProvision?.stop();
    this.watchProvision = undefined;
    this.qrValue = '';
    this.qrBusy = false;
  }

  private clearPhoneImport(): void {
    this.pendingImport = undefined;
    this.pendingEndpoint = '';
    this.pendingModel = '';
    this.pendingProtocol = '';
  }

  private async beginProvision(): Promise<void> {
    if (this.loading || this.saving || this.qrBusy || this.appInBackground) { return; }
    this.stopProvision();
    this.clearPhoneImport();
    const generation: number = this.provisionGeneration;
    // Phone imports always create a new draft, never replace another saved API.
    if (this.settingsOnly) { this.discardDraft(); }
    this.qrBusy = true;
    this.page = 'qr';
    this.status = '正在手表上生成链接，不连接 DSH 宿主…';
    const service = new WatchProvisionService((config: DirectApiConfig) => {
      this.receivePhoneImport(config, generation);
    }, (notice: string) => {
      if (!this.alive || this.appInBackground || generation !== this.provisionGeneration) { return; }
      this.stopProvision(); this.page = 'qr'; this.status = notice;
    });
    this.watchProvision = service;
    this.provisionTimer = setTimeout(() => {
      if (!this.alive || generation !== this.provisionGeneration) { return; }
      this.stopProvision(); this.page = 'qr'; this.status = '启动超时，请确认手表已连接 Wi-Fi 后重试';
    }, 15000);
    try {
      const link = await service.start();
      if (!this.alive || this.appInBackground || generation !== this.provisionGeneration) {
        service.stop(); return;
      }
      if (this.provisionTimer >= 0) { clearTimeout(this.provisionTimer); this.provisionTimer = -1; }
      this.qrValue = link.url;
      this.qrBusy = false;
      this.status = '手机与手表同一 Wi-Fi，扫码直连手表；5 分钟有效，保持此页';
    } catch (error) {
      if (this.alive && generation === this.provisionGeneration) {
        this.stopProvision(); this.page = 'qr';
        this.status = (error as Error).message || '无法开启手表配置页，请检查手表 Wi-Fi 后重试';
      }
    }
  }

  private receivePhoneImport(config: DirectApiConfig, generation: number): void {
    if (!this.alive || this.appInBackground || generation !== this.provisionGeneration) { return; }
    try {
      const checked: DirectApiConfig = validateDirectConfig(config);
      this.stopProvision();
      this.pendingImport = checked;
      this.pendingEndpoint = checked.baseUrl;
      this.pendingModel = checked.model;
      this.pendingProtocol = checked.protocol;
      this.status = '';
      this.page = 'confirm';
    } catch (_) {
      this.stopProvision(); this.page = 'qr'; this.status = '手机配置无效，请重新扫码填写';
    }
  }

  private confirmPhoneImport(): void {
    if (this.appInBackground || this.page !== 'confirm' || !this.pendingImport) { return; }
    const checked: DirectApiConfig = this.pendingImport;
    this.clearPhoneImport();
    if (this.settingsOnly) { this.discardDraft(); }
    this.fillDraft(checked);
    this.imported = true;
    this.clearArmed = false;
    this.saveArmed = false;
    this.page = 'settings';
    this.status = this.settingsOnly ? '手机配置是新草稿，尚未启用；核对后保存并返回主聊天，不覆盖其他 API' : '手机配置待核对：确认地址、模型及协议后，点「保存并新建」；尚未启用';
  }

  private rejectPhoneImport(): void {
    this.clearPhoneImport();
    this.returnTo('settings');
    this.status = '已放弃手机配置，未保存 API Key';
  }

  @Builder
  Pill(label: string, action: () => void, accent: boolean = false) {
    Button(label, { type: ButtonType.Capsule })
      .fontSize(this.u(11))
      .fontColor(accent ? '#111111' : DIRECT_ACCENT)
      .backgroundColor(accent ? DIRECT_ACCENT : '#131313')
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
          .fontSize(this.u(12)).fontWeight(FontWeight.Medium).fontColor(this.imported ? '#DFDFDF' : DIRECT_TEXT)
        Button(this.qrBusy ? '准备中…' : '手机填写', { type: ButtonType.Capsule })
          .height(this.u(40)).width('100%').fontSize(this.u(12))
          .backgroundColor(!this.configured ? DIRECT_ACCENT : '#131313')
          .fontColor(!this.configured ? '#111111' : DIRECT_ACCENT)
          .enabled(!this.loading && !this.saving && !this.qrBusy)
          .onClick(() => { this.draftChanged(); this.beginProvision(); })
        this.Note(this.settingsOnly ? '扫码另建新草稿；或在手表填写' : '或在手表填写')
        if (this.settingsOnly) {
          Column({ space: this.u(6) }) {
            Text('API 名称').fontSize(this.u(11)).fontColor(DIRECT_ACCENT).alignSelf(ItemAlign.Start)
            TextInput({ placeholder: '便于识别的名称', text: this.nameDraft })
              .fontSize(this.u(10)).height(this.u(40)).backgroundColor('#131313').fontColor(DIRECT_TEXT).borderRadius(this.u(20))
              .enabled(!this.saving).maxLength(80).enableAutoFill(false)
              .onChange((value: string) => { this.nameDraft = value; this.draftChanged(); })
              .onEditChange((editing: boolean) => { this.editingChanged(editing); })
          }.width('100%').alignItems(HorizontalAlign.Start)
        }
        Column({ space: this.u(6) }) {
          Text('API 地址 · HTTPS').fontSize(this.u(11)).fontColor(DIRECT_ACCENT).alignSelf(ItemAlign.Start)
          TextInput({ placeholder: 'https://api.example.com/v1', text: this.baseDraft })
            .fontSize(this.u(10)).height(this.u(40)).backgroundColor('#131313').fontColor(DIRECT_TEXT).borderRadius(this.u(20))
            .enabled(!this.saving).maxLength(2048).enableAutoFill(false)
            .onChange((value: string) => { this.baseDraft = value; this.draftChanged(); })
            .onEditChange((editing: boolean) => { this.editingChanged(editing); })
          Text('模型').fontSize(this.u(11)).fontColor(DIRECT_ACCENT).alignSelf(ItemAlign.Start)
          TextInput({ placeholder: '模型名称', text: this.modelDraft })
            .fontSize(this.u(10)).height(this.u(40)).backgroundColor('#131313').fontColor(DIRECT_TEXT).borderRadius(this.u(20))
            .enabled(!this.saving).maxLength(200).enableAutoFill(false)
            .onChange((value: string) => { this.modelDraft = value; this.draftChanged(); })
            .onEditChange((editing: boolean) => { this.editingChanged(editing); })
          Text('API Key · 始终隐藏').fontSize(this.u(11)).fontColor(DIRECT_ACCENT).alignSelf(ItemAlign.Start)
          TextInput({ placeholder: 'API Key', text: this.keyDraft })
            .type(InputType.Password).showPasswordIcon(false).showPassword(false).copyOption(CopyOptions.None).enableAutoFill(false)
            .fontSize(this.u(10)).height(this.u(40)).backgroundColor('#131313').fontColor(DIRECT_TEXT).borderRadius(this.u(20))
            .enabled(!this.saving).maxLength(8192)
            .onChange((value: string) => { this.keyDraft = value; this.draftChanged(); })
            .onEditChange((editing: boolean) => { this.editingChanged(editing); })
        }.width('100%').alignItems(HorizontalAlign.Start)
        Column({ space: this.u(6) }) {
          Text('请求协议').fontSize(this.u(11)).fontColor(DIRECT_ACCENT).alignSelf(ItemAlign.Start)
          Button(this.protocolDraft === 'chat' ? '✓ Chat Completions' : '○ Chat Completions', { type: ButtonType.Capsule })
            .fontSize(this.u(10)).height(this.u(36)).width('100%').fontColor(this.protocolDraft === 'chat' ? '#111111' : DIRECT_DIM)
            .backgroundColor(this.protocolDraft === 'chat' ? DIRECT_ACCENT : '#131313').enabled(!this.saving)
            .onClick(() => { this.protocolDraft = 'chat'; this.draftChanged(); })
          Button(this.protocolDraft === 'responses' ? '✓ Responses' : '○ Responses', { type: ButtonType.Capsule })
            .fontSize(this.u(10)).height(this.u(36)).width('100%').fontColor(this.protocolDraft === 'responses' ? '#111111' : DIRECT_DIM)
            .backgroundColor(this.protocolDraft === 'responses' ? DIRECT_ACCENT : '#131313').enabled(!this.saving)
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
        this.Note('配置页为 HTTP，仅在同一可信 WiFi 使用，链接勿转发；无需连接宿主')
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
          .fontSize(this.u(11)).fontColor(DIRECT_ACCENT).backgroundColor('#131313').onClick(() => { this.openSettings(); })
        Button('新建', { type: ButtonType.Capsule }).height(this.u(30)).width(this.u(70))
          .fontSize(this.u(11)).fontColor(DIRECT_ACCENT).backgroundColor('#131313').onClick(() => { this.newChat(); })
      }
      Scroll(this.scroll) {
        Column({ space: this.u(8) }) {
          if (this.messages.length === 0 && !this.busy) {
            this.Note('独立对话\n消息仅发送给你确认的 API\n无需 DSH 宿主运行')
          }
          ForEach(this.messages, (message: DirectMessage, index: number) => {
            Column({ space: this.u(3) }) {
              Text(message.role === 'user' ? '你' : 'API').fontSize(this.u(9)).fontColor(DIRECT_ACCENT)
              Text(message.content).fontSize(this.u(12)).lineHeight(this.u(17)).fontColor(DIRECT_TEXT).width('100%')
            }.alignItems(HorizontalAlign.Start).width('100%').padding(this.u(9))
              .backgroundColor(message.role === 'user' ? '#2D2D2D' : '#1A1A1A').borderRadius(this.u(12))
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
      Row().width(this.u(148)).height(this.u(1)).backgroundColor('#353535')
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
        .fontSize(this.u(13)).fontColor(DIRECT_TEXT).backgroundColor('#1A1A1A')
        .height(this.u(102)).width(this.u(164)).maxLength(2000).enableAutoFill(false)
        .onChange((value: string) => { this.prompt = value; })
        .onEditChange((editing: boolean) => { this.editingChanged(editing); })
      if (this.status) { this.Note(this.status) }
      Column() { this.Pill('发送', () => { this.send(); }, true) }.width(this.u(148))
    }.width(this.u(176)).height(this.u(147))
  }

  @Builder
  Provision() {
    Scroll(this.provisionScroll) {
      Column({ space: this.u(6) }) {
        if (this.qrValue) {
          Column() {
            QRCode(this.qrValue).width(this.u(116)).height(this.u(116))
              .color('#000000').backgroundColor('#FFFFFF')
          }.padding(this.u(7)).backgroundColor('#FFFFFF').borderRadius(this.u(5))
        } else {
          Text(this.qrBusy ? '生成中…' : '未开启配置页').fontSize(this.u(12)).fontColor(DIRECT_ACCENT)
        }
        Text(this.status).fontSize(this.u(10)).lineHeight(this.u(14)).fontColor(DIRECT_DIM)
          .width(this.u(166)).textAlign(TextAlign.Center)
        Text('无需宿主或配对 · 手机直连手表').fontSize(this.u(9)).fontColor(DIRECT_ACCENT)
          .width(this.u(166)).textAlign(TextAlign.Center)
        Text('HTTP 仅限可信 Wi-Fi；不要转发二维码').fontSize(this.u(8)).fontColor('#DFDFDF')
          .width(this.u(164)).textAlign(TextAlign.Center)
        if (!this.qrValue && !this.qrBusy) {
          this.Pill('重新生成', () => { this.beginProvision(); }, true)
        }
      }.width(this.u(168)).padding({ top: this.u(58), bottom: this.u(45) })
        .translate({ y: this.crownStretch })
    }.width('100%').height('100%').scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
  }

  @Builder
  ConfirmPhoneImport() {
    Scroll(this.provisionScroll) {
      Column({ space: this.u(10) }) {
        Text('核对手机提交的 API').fontSize(this.u(12)).fontColor(DIRECT_TEXT)
        Text(this.pendingEndpoint).fontSize(this.u(11)).fontColor(DIRECT_ACCENT)
          .width('100%').wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.None)
        Text('模型：' + this.pendingModel).fontSize(this.u(10)).fontColor(DIRECT_DIM)
          .width('100%').wordBreak(WordBreak.BREAK_ALL)
        Text('协议：' + this.pendingProtocol).fontSize(this.u(10)).fontColor(DIRECT_DIM)
        this.Note('确认前不保存、不请求 API；确认后仍需点保存')
        this.Pill('地址正确，继续', () => { this.confirmPhoneImport(); }, true)
        this.Pill('放弃这次配置', () => { this.rejectPhoneImport(); })
      }.width(this.u(168)).padding({ top: this.u(62), bottom: this.u(55) })
        .translate({ y: this.crownStretch })
    }.width('100%').height('100%').scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
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
        this.Provision()
      } else if (this.page === 'confirm') {
        this.ConfirmPhoneImport()
      } else if (!this.settingsOnly && this.page === 'compose') {
        Column() { this.Compose() }.width('100%').height('100%').justifyContent(FlexAlign.Center)
          .transition(TransitionEffect.OPACITY)
      } else if (!this.settingsOnly) {
        Column() { this.Chat() }.width('100%').height('100%').justifyContent(FlexAlign.Center)
          .transition(TransitionEffect.OPACITY)
      }
      if (this.page !== 'profiles') {
        // Transparent overlay: content keeps the full viewport and scrolls behind this title.
        Text(this.page === 'qr' ? '直连扫码' : this.page === 'confirm' ? '确认地址' : this.page === 'settings' ? 'API设置' : '独立 API')
          .fontSize(this.u(11)).fontColor(DIRECT_TEXT).textAlign(TextAlign.Center)
          .width(this.u(152)).height(this.u(30)).margin({ top: this.u(20) })
          .id('direct-crown-' + this.page).focusable(true).focusOnTouch(false).defaultFocus(true)
          .hitTestBehavior(HitTestMode.None)
          .onDigitalCrown((event: CrownEvent) => { this.handleCrown(event); })
      }
    }.width('100%').height('100%').backgroundColor('#080808')
      .linearGradient({ angle: 150, colors: [['#191919', 0], ['#101010', 0.35], ['#080808', 0.8], ['#101010', 1]] })
      .clip(true)
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) { this.crownMotion.cancel(); }
      })
  }
}
