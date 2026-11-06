import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import display from '@ohos.display';
import notificationManager from '@ohos.notificationManager';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import { BusinessError } from '@ohos.base';
import {
  cancelTurn, decideApproval, fetchEventDetail, fetchModels, fetchSessions, fetchState, newSession, ping,
  normalizeUrl, pair, selectSession, sendPrompt, switchModel
} from '../common/Net';
import { DshEvent, DshImage, ModelOption, PendingInfo, ProviderOption, SessionInfo, SimpleResult, StateSnapshot } from '../common/Types';
import { reconcileEventFeed, visibleFeedEvents } from '../common/EventFeed';
import { swiperProgress, indicatorTranslation } from '../common/SwiperProgress';
import { QuickGuide } from '../common/QuickGuide';
import { CrownMenu, CrownMenuItem } from '../common/CrownMenu';
import { LocalChat } from '../common/LocalChat';
import { DirectApiConfig } from '../common/DirectApi';
import { ApiProfile } from '../common/ApiProfiles';
import { LocalSession } from '../common/LocalSessions';
import { LocalChatController } from '../common/LocalChatController';
import { ViewHistory, WatchLocation, isWatchBackSwipe } from '../common/ViewHistory';
import { CrownElastic } from '../common/CrownElastic';
import { ChatChromeController } from '../common/ChatImmersion';

const STORE = 'dsh_watch';
// Sea Glass：低饱和海盐绿，只给可操作元素和状态上色。
const BG = '#060A0D';
const CARD = '#142126';
const TEXT = '#EDF4F3';
const DIM = '#9BAFB3';
const ACCENT = '#ADE9D9';
const WARN = '#EFC49A';
const OK = '#ADE9D9';
const BAD = '#F1ABA8';
const HAIRLINE = '#24D7F1EB';
const INK = '#102D29';

interface Preset {
  label: string;
  text: string;
}

interface ActionItem {
  key: string;
  label: string;
  color: string;
  ring: string;
}

// 会话列表可能上百条，用懒加载数据源，滚动时只渲染可见项。
class SessionDataSource implements IDataSource {
  private listeners: DataChangeListener[] = [];
  private items: SessionInfo[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): SessionInfo {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const i: number = this.listeners.indexOf(listener);
    if (i >= 0) {
      this.listeners.splice(i, 1);
    }
  }

  set(items: SessionInfo[]): void {
    this.items = items;
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded();
    }
  }

  count(): number {
    return this.items.length;
  }
}

@Entry
@Component
struct Index {
  @State view: string = 'connect';
  @State bootReady: boolean = false;
  @State showGuide: boolean = false;
  @State chatKind: string = 'dsh';
  @State localSessions: LocalSession[] = [];
  @State localEvents: DshEvent[] = [];
  @State localId: string = '';
  @State localTitle: string = '';
  @State localModel: string = '';
  @State localBusy: boolean = false;
  @State localUnsaved: boolean = false;
  @State localNotice: string = '';
  @State apiProfiles: ApiProfile[] = [];
  @State selectedApiId: string = '';
  @State sceneX: number = 0;
  @State sceneOpacity: number = 1;
  @State chatChromeHidden: boolean = false;
  @State chatChromeProgress: number = 0;
  private chatChrome: ChatChromeController = new ChatChromeController((hidden: boolean) => { this.animateChatChrome(hidden); });
  private chatCrownQuietTimer: number = -1;
  private chatFocusTimer: number = -1;
  private chatScrollOrigin: number = 0;
  private returnAnimating: boolean = false;
  @State pickerItems: CrownMenuItem[] = [];
  private localController?: LocalChatController;
  private localUiEpoch: number = 0;
  private localDraftTimer: number = -1;
  private dshDraft: string = '';
  private localDeleteArmed: boolean = false;
  @State server: string = '';
  @State primaryServer: string = '';
  @State remoteUrl: string = '';
  @State usingRemote: boolean = false;
  @State lanUrl: string = '';
  @State netMode: string = 'auto';
  @State serverEdit: string = '';
  @State settingsCode: string = '';
  @State lanEdit: string = '';
  @State remoteEdit: string = '';
  @State code: string = '';
  @State token: string = '';
  @State connected: boolean = false;
  @State connecting: boolean = false;
  @State title: string = '';
  @State status: string = 'offline';
  @State events: DshEvent[] = [];
  @State pending: PendingInfo[] = [];
  @State sessions: SessionInfo[] = [];
  @State promptText: string = '';
  @State message: string = '';
  @State lastSeq: number = -1;
  @State showPrompt: boolean = false;
  @State showModels: boolean = false;
  @State selectionProvider: string = '';
  @State selectionModel: string = '';
  @State modelOptions: ProviderOption[] = [];
  @State expandedSeq: number = -1;
  @State expandedText: string = '';
  @State scrollY: number = 0;
  @State viewH: number = 120;
  @State sw: number = 233;
  @State sh: number = 233;
  @State pageVisible: boolean = true;
  @StorageLink('appInBackground') appInBackground: boolean = false;
  @State stopArmed: boolean = false;
  @State pollDelay: number = 2000;
  @State failCount: number = 0;
  @State lastError: string = '';
  @State modelPending: boolean = false;
  @State modelsLoading: boolean = false;
  @State currentSessionId: string = '';
  @State pageIndex: number = 1;
  @State swiperInitialIndex: number = 1;
  @State localBackRequest: number = 0;
  @State editingInput: boolean = false;
  @State crownStretch: number = 0;
  private viewHistory: ViewHistory = new ViewHistory();
  private lastBackAt: number = 0;
  private backPanStartX: number = 0;
  private crownOwner?: Scroller;
  private crownMotion: CrownElastic = new CrownElastic((stretch: number) => { this.crownStretch = stretch; });
  @State slidePos: number = 1;
  @State notifyEnabled: string = '';
  @State bgState: string = '未启动';
  @State imgFail: number = 0;
  @State testImgUrl: string = '';

  private timer: number = -1;
  private lanTimer: number = -1;
  private busy: boolean = false;
  private feedSessionId: string = '';
  private requestGeneration: number = 0;
  private changingSession: boolean = false;
  private histories: Map<string, DshEvent[]> = new Map<string, DshEvent[]>();
  private lastSaveAt: number = 0;
  private toastTimer: number = -1;
  private stopTimer: number = -1;
  private sessionSource: SessionDataSource = new SessionDataSource();
  private sessionSig: string = '';
  private lastRunning: boolean = false;
  private lastPendingCount: number = 0;
  private lastApprovalId: string = '';
  private notifySeq: number = 0;
  private bgRunning: boolean = false;
  private delayId: number = -1;
  private scroller: Scroller = new Scroller();
  private promptScroller: Scroller = new Scroller();
  private connectScroller: Scroller = new Scroller();
  private approvalScroller: Scroller = new Scroller();
  private sessionsScroller: Scroller = new Scroller();
  private modelsScroller: Scroller = new Scroller();
  private settingsScroller: Scroller = new Scroller();
  private swiper: SwiperController = new SwiperController();
  private diagScroller: Scroller = new Scroller();
  private menuItems: CrownMenuItem[] = [
    { key: 'sessions', title: '会话', caption: '本地 API 与 DSH 会话', symbol: '≡' },
    { key: 'local', title: 'API 设置', caption: '模型、密钥与手机扫码', symbol: '◇' },
    { key: 'settings', title: '连接设置', caption: '管理 DSH 宿主连接', symbol: '◇' },
    { key: 'guide', title: '使用引导', caption: '重新认识腕上 DSH', symbol: '?' },
    { key: 'diagnostics', title: '诊断', caption: '连接、轮询与缓存', symbol: '◎' }
  ];
  private quickItems: CrownMenuItem[] = [
    { key: 'continue', title: '继续', caption: '接着完成当前任务', symbol: '›' },
    { key: 'status', title: '在干嘛', caption: '看看现在的进展', symbol: '·' },
    { key: 'summary', title: '总结', caption: '整理刚才的进展', symbol: '≡' },
    { key: 'pause', title: '停一下', caption: '先停下来，说说状态', symbol: 'Ⅱ' },
    { key: 'new', title: '新建 DSH 会话', caption: '开始一件新的事', symbol: '+' }
  ];
  private presets: Preset[] = [
    { label: '继续', text: '继续' },
    { label: '在干嘛', text: '现在在干什么？' },
    { label: '总结', text: '总结一下刚才的进展' },
    { label: '停一下', text: '先停下来，说说现在的状态' }
  ];
  private actions: ActionItem[] = [
    { key: 'allow', label: '允许', color: '#04120C', ring: '#6ED4A0' },
    { key: 'deny', label: '拒绝', color: '#FFE9E9', ring: '#2A171C' }
  ];

  aboutToAppear(): void {
    this.measure();
    this.localController = new LocalChatController(this.ctx(), () => { this.syncLocalView(); });
    this.restore();
  }

  onPageShow(): void {
    this.pageVisible = true;
    this.cancelDelay();
    this.focusMainCrown();
  }

  onPageHide(): void {
    this.resetChatChrome();
    this.resetCrown();
    this.pageVisible = false;
    this.localUiEpoch++; this.localController?.cancel();
    this.flushLocalDraft().catch(() => { this.toast('本地草稿尚未保存'); });
    // 穿戴设备不给长时任务（9800005），退而求其次：申请系统延迟挂起，
    // 通常能多撑几分钟，足够一轮对话跑完。
    this.requestDelay();
  }

  private async requestDelay(): Promise<void> {
    if (this.delayId >= 0) {
      return;
    }
    try {
      const info = await backgroundTaskManager.requestSuspendDelay('DSH 保持连接', () => {
        this.delayId = -1;
        this.bgState = '延迟到期';
      });
      this.delayId = info.requestId;
      this.bgState = '延迟 ' + Math.round(info.actualDelayTime / 1000) + ' 秒';
    } catch (e) {
      this.bgState = '延迟失败';
    }
  }

  private cancelDelay(): void {
    if (this.delayId < 0) {
      return;
    }
    try {
      backgroundTaskManager.cancelSuspendDelay(this.delayId);
    } catch (e) {
    }
    this.delayId = -1;
    this.bgState = '前台';
  }

  private testImageLoad(): void {
    const withImage = this.events.slice().reverse()
      .find((ev: DshEvent) => ev.images !== undefined && ev.images.length > 0);
    if (withImage === undefined) {
      this.toast('当前会话没有图片');
      return;
    }
    this.testImgUrl = this.imageUrl(withImage, 0) + '&t=' + Date.now().toString();
    this.toast('正在加载');
  }

  private testNotify(): void {
    this.pushNotification('DSH 测试', '通知通道正常');
    this.toast('已发测试通知');
  }

  private async ensureNotification(): Promise<void> {
    try {
      const enabled: boolean = await notificationManager.isNotificationEnabled();
      this.notifyEnabled = enabled ? '已开启' : '未开启';
      if (!enabled) {
        await notificationManager.requestEnableNotification();
        this.notifyEnabled = '已开启';
      }
    } catch (e) {
    }
  }

  private async startBackground(): Promise<void> {
    if (this.bgRunning) {
      return;
    }
    // 手表允许的后台模式因机型而异：先数据同步，不行再试音频播放。
    const modes: backgroundTaskManager.BackgroundMode[] = [
      backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
      backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK
    ];
    const labels: string[] = ['数据', '音频'];
    const errors: string[] = [];
    for (let i = 0; i < modes.length; i++) {
      try {
        const info: wantAgent.WantAgentInfo = {
          wants: [{ bundleName: 'com.dsh.watchharmony', abilityName: 'EntryAbility' }],
          actionType: wantAgent.OperationType.START_ABILITY,
          requestCode: 0,
          actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
        };
        const agent = await wantAgent.getWantAgent(info);
        await backgroundTaskManager.startBackgroundRunning(this.ctx(), modes[i], agent);
        this.bgRunning = true;
        this.bgState = i === 0 ? '运行中' : '运行中·音频';
        return;
      } catch (e) {
        const be = e as BusinessError;
        const code: string = be !== undefined && be.code !== undefined ? String(be.code) : '?';
        errors.push(labels[i] + ' ' + code);
      }
    }
    this.bgRunning = false;
    this.bgState = '失败 ' + errors.join(' / ');
  }

  private async stopBackground(): Promise<void> {
    if (!this.bgRunning) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.ctx());
    } catch (e) {
    }
    this.bgRunning = false;
  }

  aboutToDisappear(): void {
    this.resetChatChrome();
    this.resetCrown();
    this.localUiEpoch++; this.localController?.cancel();
    this.flushLocalDraft().catch(() => {});
    this.stopPolling();
    this.stopBackground();
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer);
      this.toastTimer = -1;
    }
    if (this.stopTimer >= 0) {
      clearTimeout(this.stopTimer);
      this.stopTimer = -1;
    }
  }

  // -------------------------------------------------------------------------
  // 尺寸：全部用 vp，避开系统字体缩放
  // -------------------------------------------------------------------------

  private measure(): void {
    try {
      const d = display.getDefaultDisplaySync();
      const w: number = d.width / d.densityPixels;
      const h: number = d.height / d.densityPixels;
      if (w > 100 && w < 600) {
        this.sw = w;
      }
      if (h > 100 && h < 600) {
        this.sh = h;
      }
    } catch (e) {
    }
  }

  private px(n: number): number {
    return Math.round(this.sw * n / 233);
  }

  private vp(n: number): string {
    return Math.round(this.sw * n / 233).toString() + 'vp';
  }

  private ctx(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  private async restore(): Promise<void> {
    // 默认展示，偏好读取失败也能离线跳过；等待读取完成前不闪现配对页。
    this.showGuide = true;
    try {
      const p = await preferences.getPreferences(this.ctx(), STORE);
      this.showGuide = (await p.get('guideSeenV1', false)) !== true;
      const s = await p.get('server', '');
      const t = await p.get('token', '');
      const sv: string = typeof s === 'string' ? s : '';
      const tv: string = typeof t === 'string' ? t : '';
      const nm = await p.get('netMode', 'auto');
      if (typeof nm === 'string' && nm !== '') { this.netMode = nm; }
      const lanSaved = await p.get('lan', '');
      const remoteSaved = await p.get('remote', '');
      if (typeof lanSaved === 'string' && lanSaved !== '') { this.lanEdit = lanSaved; this.lanUrl = lanSaved; }
      if (typeof remoteSaved === 'string' && remoteSaved !== '') { this.remoteEdit = remoteSaved; this.remoteUrl = remoteSaved; }
      if (tv === '' && this.serverEdit === '') {
        this.serverEdit = this.server;
      }
      if (sv !== '' && tv !== '') {
        this.server = sv;
        this.primaryServer = sv;
        this.token = tv;
        this.connected = true;
        this.switchView('main');
        this.startPolling();
      }
    } catch (e) {
    } finally {
      if (this.localController) {
        try {
          await this.localController.initialize();
          const p = await preferences.getPreferences(this.ctx(), STORE);
          const kind = await p.get('chatKind', 'dsh');
          if (kind === 'local' && this.localController.current()) {
            this.chatKind = 'local';
            this.syncLocalView();
            this.promptText = this.localController.current()?.draft || '';
            this.view = 'main';
          }
        } catch (e) { this.toast('本地会话读取失败，未覆盖原数据'); }
      }
      this.bootReady = true;
      if (!this.showGuide) { this.ensureNotification(); }
    }
  }

  private async finishGuide(): Promise<void> {
    // 先关闭，再落盘。跳过和完成均不打断已有配对、会话与待审批状态。
    this.showGuide = false;
    this.ensureNotification();
    try {
      const p = await preferences.getPreferences(this.ctx(), STORE);
      await p.put('guideSeenV1', true);
      await p.flush();
    } catch (e) {
      this.toast('引导进度未保存，下次可能再次显示');
    }
  }

  private syncLocalView(): void {
    if (!this.localController) { return; }
    const wasBusy: boolean = this.localBusy;
    const current = this.localController.current();
    this.localSessions = this.localController.sessions();
    this.localId = current ? current.id : '';
    this.localTitle = current ? current.title : '新的独立对话';
    this.localModel = current ? current.model : '';
    this.localBusy = this.localController.isBusy();
    this.localUnsaved = this.localController.hasUnsavedReply();
    this.localNotice = this.localController.status();
    this.localEvents = this.localController.events();
    this.apiProfiles = this.localController.profiles();
    this.selectedApiId = this.localController.activeProfileId();
    if (wasBusy && !this.localBusy && !this.localUnsaved && this.localNotice === '' && this.chatKind === 'local' && !this.showPrompt) {
      this.promptText = current ? current.draft : '';
    }
    this.updatePicker();
    if (this.chatKind === 'local' && this.view === 'main') { this.scrollToBottom(); }
  }

  private updatePicker(): void {
    const items: CrownMenuItem[] = [
      { key: 'new-local', title: '新建独立会话', caption: '手表直连 API · 本地保存', symbol: '+' },
      { key: 'new-dsh', title: '新建 DSH 会话', caption: '由已配对的宿主执行', symbol: '+' }
    ];
    for (let i = 0; i < this.localSessions.length; i++) {
      const item = this.localSessions[i];
      const active: boolean = this.chatKind === 'local' && item.id === this.localId;
      items.push({ key: 'api:' + item.id, title: (active ? '✓ ' : '') + item.title,
        caption: '本地 API · ' + item.model + (item.draft ? ' · 草稿' : ''), symbol: '✦' });
    }
    for (let i = 0; i < this.sessions.length; i++) {
      const item = this.sessions[i];
      const active: boolean = this.chatKind === 'dsh' && item.id === this.currentSessionId;
      items.push({ key: 'dsh:' + item.id, title: (active ? '✓ ' : '') + (item.title || item.id),
        caption: 'DSH · ' + (item.running ? '执行中' : (item.live ? '在线' : '已存档')), symbol: '≡' });
    }
    if (this.chatKind === 'local' && this.localId !== '') {
      items.push({ key: 'delete-local', title: '删除当前本地会话', caption: '连续点两次确认 · 不影响 DSH', symbol: '−' });
    }
    this.pickerItems = items;
  }

  private async rememberChatKind(): Promise<void> {
    try {
      const p = await preferences.getPreferences(this.ctx(), STORE);
      await p.put('chatKind', this.chatKind);
      await p.flush();
    } catch (e) { this.toast('未保存启动模式，但聊天记录仍单独保存'); }
  }

  private async flushLocalDraft(): Promise<void> {
    if (this.localDraftTimer >= 0) { clearTimeout(this.localDraftTimer); this.localDraftTimer = -1; }
    if (this.chatKind === 'local' && this.localController && !this.localBusy && !this.localUnsaved) {
      await this.localController.saveDraft(this.promptText);
    }
  }

  private changeComposer(value: string): void {
    this.promptText = this.chatKind === 'local' ? value.slice(0, 2000) : value;
    if (this.chatKind !== 'local') { return; }
    if (this.localDraftTimer >= 0) { clearTimeout(this.localDraftTimer); }
    this.localDraftTimer = setTimeout(() => {
      this.localDraftTimer = -1;
      this.flushLocalDraft().catch(() => { this.toast('草稿未存盘，请勿退出并重试'); });
    }, 400);
  }

  private async enterLocal(id: string = '', create: boolean = false): Promise<void> {
    if (!this.localController || this.changingSession) { return; }
    this.changingSession = true;
    try {
      await this.flushLocalDraft();
      if (this.chatKind === 'dsh') { this.dshDraft = this.promptText; }
      this.localUiEpoch++;
      if (id !== '') { await this.localController.select(id); }
      else if (create) { await this.localController.create(); }
      else if (!await this.localController.open()) { this.switchView('local'); return; }
      this.chatKind = 'local'; this.localDeleteArmed = false; this.stopArmed = false;
      this.showPrompt = false; this.showModels = false;
      this.syncLocalView();
      this.promptText = this.localController.current()?.draft || '';
      this.goPage(1); this.rememberChatKind();
    } catch (error) {
      this.toast((error as Error).message || '本地会话不可用');
      if (!this.localController.hasConfig() && id === '') { this.switchView('local'); }
    } finally { this.changingSession = false; }
  }

  private async openLocalSettings(): Promise<void> {
    try {
      if (this.chatKind === 'local') { this.localUiEpoch++; this.localController?.cancel(); }
      await this.flushLocalDraft(); this.switchView('local');
    } catch (e) { this.toast('草稿未保存，请重试后再改配置'); }
  }

  private async reloadApiProfiles(): Promise<void> {
    try { await this.localController?.reloadProfiles(); this.syncLocalView(); }
    catch (e) { this.toast('API 配置读取失败，未清除原数据'); }
  }

  private async chooseApiProfile(id: string): Promise<void> {
    if (!this.localController || this.localBusy) { this.toast('请先等待或停止当前回复'); return; }
    try {
      await this.flushLocalDraft();
      if (this.chatKind === 'dsh') { this.dshDraft = this.promptText; }
      this.localUiEpoch++;
      await this.localController.useProfile(id);
      this.chatKind = 'local'; this.syncLocalView();
      this.promptText = this.localController.current()?.draft || '';
      this.closeModels(); this.goPage(1); this.rememberChatKind();
      this.toast('已选择 API，原会话保留');
    } catch (error) { this.toast((error as Error).message || '未能切换 API；原数据保留'); }
  }

  private async configuredLocal(config: DirectApiConfig): Promise<void> {
    if (!this.localController) { return; }
    try {
      await this.flushLocalDraft();
      if (this.chatKind === 'dsh') { this.dshDraft = this.promptText; }
      this.localUiEpoch++;
      await this.localController.configured(config);
      this.chatKind = 'local'; this.syncLocalView();
      this.promptText = this.localController.current()?.draft || '';
      this.goPage(1); this.rememberChatKind();
    } catch (error) { this.toast((error as Error).message || '配置已保存，但未能打开会话'); }
  }

  private async sendLocal(): Promise<void> {
    if (!this.localController || this.localBusy) { return; }
    if (this.localUnsaved) {
      try { await this.localController.retrySave(); this.promptText = ''; }
      catch (e) { this.toast('回复仍未保存，请检查手表存储后重试'); }
      return;
    }
    if (this.localDraftTimer >= 0) { clearTimeout(this.localDraftTimer); this.localDraftTimer = -1; }
    const id: string = this.localId;
    const epoch: number = ++this.localUiEpoch;
    const text: string = this.promptText;
    this.closePrompt(); this.goPage(1);
    try {
      await this.localController.send(text);
      if (epoch === this.localUiEpoch && this.chatKind === 'local' && this.localId === id) {
        this.promptText = this.localController.current()?.draft || '';
      }
    } catch (error) {
      if (epoch === this.localUiEpoch && this.chatKind === 'local') { this.toast((error as Error).message); }
    }
  }

  private async pickSession(key: string): Promise<void> {
    if (key === 'new-local') { this.enterLocal('', true); return; }
    if (key.startsWith('api:')) { this.enterLocal(key.substring(4)); return; }
    if (key === 'delete-local') {
      if (!this.localDeleteArmed) { this.localDeleteArmed = true; this.toast('再点一次，删除当前本地会话'); return; }
      this.localDeleteArmed = false;
      try {
        this.localUiEpoch++; await this.localController?.removeCurrent(); this.syncLocalView();
        this.promptText = this.localController?.current()?.draft || '';
      } catch (error) { this.toast((error as Error).message); }
      return;
    }
    this.localDeleteArmed = false;
    if (key === 'new-dsh') {
      if (this.token === '') { this.toast('请先连接 DSH 宿主'); return; }
      await this.useDsh(); this.doNew(); return;
    }
    if (key.startsWith('dsh:')) { await this.doSelect(key.substring(4)); }
  }

  private async useDsh(): Promise<void> {
    if (this.localUnsaved) { throw new Error('请先保存已收到的本地回复'); }
    if (this.chatKind === 'local') {
      await this.flushLocalDraft(); this.localUiEpoch++; this.localController?.cancel();
      this.chatKind = 'dsh'; this.promptText = this.dshDraft; this.stopArmed = false;
      this.showPrompt = false; this.showModels = false; this.updatePicker(); this.rememberChatKind();
    }
  }

  private chatEvents(): DshEvent[] { return this.chatKind === 'local' ? this.localEvents : visibleFeedEvents(this.events); }
  private chatEventKey(event: DshEvent): string {
    // 本地历史裁剪后会复用位置序号；内容变化必须让 ForEach 更新气泡，而不是显示旧行。
    const text: string = event.text || '';
    let hash: number = 0;
    for (let i = 0; i < text.length; i++) { hash = (hash * 31 + text.charCodeAt(i)) >>> 0; }
    return event.sessionId + ':' + event.seq + ':' + event.kind + ':' + text.length + ':' + hash;
  }
  private chatTitle(): string { return this.chatKind === 'local' ? '✦ ' + this.localTitle : (this.title || 'DSH Watch'); }
  private modelCaption(): string {
    if (this.chatKind === 'local') { return '模型 · ' + (this.localModel || '选择 API'); }
    return '模型 · ' + (this.selectionModel || '跟随默认') + (this.modelPending ? ' · 下轮生效' : '');
  }

  private async saveHistory(sessionId: string, events: DshEvent[]): Promise<void> {
    if (sessionId === '') { return; }
    this.histories.set(sessionId, events);
    try {
      const slim: DshEvent[] = events.slice(-12).map((ev: DshEvent) => {
        const copy: DshEvent = {
          seq: ev.seq, t: ev.t, sessionId: ev.sessionId, kind: ev.kind,
          text: (ev.text === undefined ? '' : ev.text).substring(0, 200)
        };
        return copy;
      });
      const p = await preferences.getPreferences(this.ctx(), STORE);
      await p.put('hist_' + sessionId, JSON.stringify(slim));
      await p.flush();
    } catch (e) {
    }
  }

  private async loadHistory(sessionId: string): Promise<DshEvent[]> {
    const cached: DshEvent[] | undefined = this.histories.get(sessionId);
    if (cached !== undefined) { return cached; }
    try {
      const p = await preferences.getPreferences(this.ctx(), STORE);
      const raw = await p.get('hist_' + sessionId, '');
      if (typeof raw === 'string' && raw !== '') {
        const list = JSON.parse(raw) as DshEvent[];
        if (Array.isArray(list)) {
          this.histories.set(sessionId, list);
          return list;
        }
      }
    } catch (e) {
    }
    return [];
  }

  private async persist(): Promise<void> {
    try {
      const p = await preferences.getPreferences(this.ctx(), STORE);
      await p.put('server', this.server);
      await p.put('token', this.token);
      await p.put('netMode', this.netMode);
      await p.put('lan', this.lanUrl);
      await p.put('remote', this.remoteUrl);
      await p.flush();
    } catch (e) {
    }
  }

  private startPolling(): void {
    this.stopPolling();
    this.pollDelay = 2000;
    this.poll();
    this.startLanProbe();
  }

  private stopPolling(): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    if (this.lanTimer >= 0) {
      clearInterval(this.lanTimer);
      this.lanTimer = -1;
    }
  }

  // 失败次数越多等得越久，连上就立刻回到 2 秒，不再每 2 秒撞一次墙。
  private schedulePoll(): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
    }
    if (this.token === '' || this.server === '') {
      this.timer = -1;
      return;
    }
    const delay: number = this.pollDelay;
    this.timer = setTimeout(() => {
      this.timer = -1;
      this.poll();
    }, delay);
  }

  // 用外网时每 30 秒探一次内网，回到同一 Wi-Fi 就自动切回。
  private startLanProbe(): void {
    if (this.lanTimer >= 0) {
      clearInterval(this.lanTimer);
    }
    this.lanTimer = setInterval(() => {
      if (this.netMode !== 'auto' || !this.usingRemote || this.lanUrl === '' || this.lanUrl === this.server || this.token === '') {
        return;
      }
      const target: string = this.lanUrl;
      ping(target).then((ok: boolean) => {
        if (ok && this.usingRemote) {
          this.server = target;
          this.primaryServer = target;
          this.usingRemote = false;
          this.poll();
        }
      });
    }, 30000);
  }

  private async poll(): Promise<void> {
    if (this.token === '' || this.server === '') {
      return;
    }
    if (this.busy || this.changingSession) {
      this.schedulePoll();
      return;
    }
    const generation: number = this.requestGeneration;
    this.busy = true;
    try {
      const snap: StateSnapshot = await fetchState(this.server, this.token);
      if (generation === this.requestGeneration && !this.changingSession) {
        this.apply(snap);
      }
      this.failCount = 0;
      this.pollDelay = 2000;
      this.lastError = '';
    } catch (e) {
      if (generation === this.requestGeneration) {
        this.connected = false;
        this.status = 'offline';
        this.lastError = this.errText(e);
        this.failCount += 1;
        this.pollDelay = Math.min(30000, 2000 * Math.pow(2, Math.min(4, this.failCount - 1)));
        this.failover();
      }
    } finally {
      this.busy = false;
      this.schedulePoll();
    }
  }

  // 局域网不通就换外网地址，外网也断就退回原始地址，两个方向都只试一次。
  private async pairFromSettings(): Promise<void> {
    const base: string = this.netMode === 'remote' && this.remoteEdit !== ''
      ? normalizeUrl(this.remoteEdit)
      : (this.lanEdit !== '' ? normalizeUrl(this.lanEdit) : normalizeUrl(this.server));
    if (base === '' || this.settingsCode.length < 6) {
      this.toast('地址和 6 位码都要填');
      return;
    }
    try {
      const r: SimpleResult = await pair(base, this.settingsCode);
      if (r.ok === true) {
        this.server = base;
        this.primaryServer = base;
        this.serverEdit = base;
        this.token = r.token === undefined ? '' : r.token;
        this.usingRemote = false;
        this.settingsCode = '';
        await this.persist();
        this.switchView('main');
        this.startPolling();
        this.toast('已配对');
      } else {
        this.toast(r.error === undefined ? '配对失败' : r.error);
      }
    } catch (e) {
      this.toast('配对失败');
    }
  }

  private applyServer(): void {
    const lan: string = normalizeUrl(this.lanEdit);
    const remote: string = normalizeUrl(this.remoteEdit);
    if (lan === '' && remote === '') {
      this.toast('至少填一个地址');
      return;
    }
    this.lanUrl = lan;
    this.remoteUrl = remote;
    const base: string = this.netMode === 'remote' && remote !== '' ? remote : (lan !== '' ? lan : remote);
    this.server = base;
    this.primaryServer = base;
    this.serverEdit = base;
    this.usingRemote = base === remote && remote !== '';
    this.persist();
    this.poll();
    this.toast('地址已更新');
  }

  private setNetMode(mode: string): void {
    this.netMode = mode;
    this.persist();
    if (mode === 'remote' && this.remoteUrl !== '') {
      this.server = this.remoteUrl;
      this.usingRemote = true;
    } else if (mode === 'lan' && this.lanUrl !== '') {
      this.server = this.lanUrl;
      this.primaryServer = this.lanUrl;
      this.usingRemote = false;
    } else if (mode === 'lan' && this.primaryServer !== '') {
      this.server = this.primaryServer;
      this.usingRemote = false;
    }
    this.poll();
  }

  private failover(): void {
    if (this.netMode !== 'auto') { return; }
    if (!this.usingRemote && this.remoteUrl !== '' && this.remoteUrl !== this.server) {
      this.server = this.remoteUrl;
      this.usingRemote = true;
      return;
    }
    if (this.usingRemote && this.primaryServer !== '' && this.primaryServer !== this.server) {
      this.server = this.primaryServer;
      this.usingRemote = false;
    }
  }

  private apply(snap: StateSnapshot): void {
    if (!snap || snap.ok !== true) {
      return;
    }
    this.connected = true;
    const sel = snap.selected;
    if (sel) {
      this.title = sel.title === '' ? sel.id : sel.title;
      this.status = sel.running ? 'running' : 'idle';
    } else {
      this.status = 'idle';
    }
    if (snap.sessions) {
      this.syncSessions(snap.sessions);
    }
    if (snap.remote !== undefined && snap.remote !== '') {
      this.remoteUrl = snap.remote;
    }
    if (snap.lan !== undefined && snap.lan.length > 0) {
      this.lanUrl = 'http://' + snap.lan[0];
    }
    if (snap.selection !== undefined) {
      this.selectionProvider = snap.selection.provider;
      this.selectionModel = snap.selection.model;
    }
    const nextSessionId: string = snap.selected === undefined ? '' : snap.selected.id;
    if (nextSessionId !== this.currentSessionId) {
      this.currentSessionId = nextSessionId;
      this.sessionSource.set(this.sessions);
      this.updatePicker();
    }
    if (this.feedSessionId !== '' && nextSessionId !== this.feedSessionId && this.events.length > 0) {
      this.saveHistory(this.feedSessionId, this.events);
    }
    const feed = reconcileEventFeed({
      sessionId: this.feedSessionId,
      lastSeq: this.lastSeq,
      events: this.events
    }, snap);
    const grew: boolean = feed.events.length > this.events.length ||
      (feed.events.length > 0 && this.events.length > 0 && feed.events[0].seq !== this.events[0].seq);
    this.feedSessionId = feed.sessionId;
    this.lastSeq = feed.lastSeq;
    this.events = feed.events;
    if (grew) {
      if (this.chatKind === 'dsh') { this.scrollToBottom(); }
      const now: number = Date.now();
      if (now - this.lastSaveAt > 3000) {
        this.lastSaveAt = now;
        this.saveHistory(this.feedSessionId, this.events);
      }
    }
    const pend: PendingInfo[] = snap.pending ? snap.pending : [];
    this.pending = pend;
    const newApproval: boolean = pend.length > 0 && (this.lastPendingCount === 0 || pend[0].id !== this.lastApprovalId);
    if (pend.length > 0 && (this.view === 'local' || this.chatKind === 'local') && this.lastPendingCount === 0) {
      this.toast('DSH 有待审批，返回后可处理');
    }
    if (newApproval && this.view !== 'approval' && this.view !== 'prompt' && this.view !== 'local' && this.chatKind !== 'local') {
      this.switchView('approval');
    }
    if (pend.length === 0 && this.view === 'approval') {
      this.backScene();
    }
    const running: boolean = this.status === 'running';
    this.notifyTransitions(this.lastRunning, running, pend.length);
    this.lastRunning = running;
    this.lastPendingCount = pend.length;
    this.lastApprovalId = pend.length > 0 ? pend[0].id : '';
    if (running) {
      this.modelPending = false;
    }
  }

  // 只有页面不在前台时才发通知；正在看的时候系统会自己亮，不必再响一次。
  private notifyTransitions(prevRunning: boolean, running: boolean, pendingCount: number): void {
    // 页面可见且应用在前台才不打扰；息屏时页面回调可能漏，Ability 的前后台更可靠。
    if (this.pageVisible && !this.appInBackground) {
      return;
    }
    const name: string = this.title === '' ? 'DSH 手表' : this.title;
    if (pendingCount > 0 && this.lastPendingCount === 0) {
      this.pushNotification('等待你审批', name + ' 有新的操作请求');
      return;
    }
    if (prevRunning && !running) {
      this.pushNotification('回合结束', name + ' 已完成');
    }
  }

  private pushNotification(title: string, text: string): void {
    this.notifySeq += 1;
    try {
      notificationManager.publish({
        id: 1000 + (this.notifySeq % 50),
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: { title: title, text: text }
        }
      }).then(() => {
      }, () => {
      });
    } catch (e) {
    }
  }

  private scrollToBottom(): void {
    setTimeout(() => {
      try {
        this.scroller.scrollEdge(Edge.Bottom);
      } catch (e) {
      }
    }, 100);
  }

  private async unbind(): Promise<void> {
    this.requestGeneration += 1;
    this.feedSessionId = '';
    this.events = [];
    this.lastSeq = -1;
    this.sessions = [];
    this.sessionSig = '';
    this.currentSessionId = '';
    this.sessionSource.set([]);
    this.stopPolling();
    this.token = '';
    this.server = '';
    this.connected = false;
    try {
      const p = await preferences.getPreferences(this.ctx(), STORE);
      await p.delete('server');
      await p.delete('token');
      await p.flush();
    } catch (e) {
    }
    this.switchView('connect');
    this.toast('已解除绑定');
  }

  private async toggleDetail(ev: DshEvent): Promise<void> {
    if (this.expandedSeq === ev.seq) {
      this.expandedSeq = -1;
      this.expandedText = '';
      return;
    }
    this.expandedSeq = ev.seq;
    this.expandedText = '';
    if (ev.hasDetail === true) {
      try {
        const text: string = await fetchEventDetail(this.server, this.token, ev.sessionId, ev.seq, ev.t);
        if (this.expandedSeq === ev.seq) { this.expandedText = text; }
      } catch (e) {
      }
    }
  }

  private async openModels(): Promise<void> {
    this.resetChatChrome();
    if (this.showModels) {
      return;
    }
    this.modelsLoading = true;
    animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
      this.showModels = true;
    });
    setTimeout(() => {
      try { this.getUIContext().getFocusController().requestFocus('crown-models'); } catch (e) { }
    }, 150);
    try {
      if (this.chatKind === 'local') {
        await this.localController?.reloadProfiles();
        this.syncLocalView(); return;
      }
      const catalog = await fetchModels(this.server, this.token, this.feedSessionId);
      if (catalog.ok === true) { this.modelOptions = catalog.providers; }
    } catch (e) {
      this.toast('模型列表读取失败');
    } finally {
      this.modelsLoading = false;
    }
  }

  private async doSwitchModel(provider: string, model: string): Promise<void> {
    try {
      const r: SimpleResult = await switchModel(this.server, this.token, this.feedSessionId, provider, model);
      if (r.ok === true) {
        this.selectionProvider = provider;
        this.selectionModel = model;
        this.modelPending = true;
        this.closeModels();
        this.toast('已切换，下一轮生效');
      } else {
        this.toast(r.error === undefined ? '切换失败' : r.error);
      }
    } catch (e) {
      this.toast('切换失败');
    }
  }

  private closeModels(): void {
    if (!this.showModels) {
      return;
    }
    animateTo({ duration: 200, curve: Curve.EaseIn }, () => {
      this.showModels = false;
    });
    setTimeout(() => {
      this.focusMainCrown();
    }, 240);
  }

  private openPrompt(): void {
    this.resetChatChrome();
    if (this.chatKind === 'local' && this.localUnsaved) { this.sendLocal(); return; }
    if (this.chatKind === 'local' && this.localBusy) { this.toast('请等待回复或先停止'); return; }
    animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
      this.showPrompt = true;
    });
  }

  private closePrompt(): void {
    animateTo({ duration: 200, curve: Curve.EaseIn }, () => {
      this.showPrompt = false;
    });
    this.focusMainCrown();
  }

  private location(): WatchLocation { return { view: this.view, page: this.pageIndex }; }

  private recordLocation(next: WatchLocation): void {
    this.resetChatChrome();
    if (this.bootReady) { this.viewHistory.record(this.location(), next); }
    this.resetCrown();
    this.editingInput = false;
  }

  private switchView(v: string): void {
    if (v === 'menu') { this.goPage(0); return; }
    if (v === 'main') { this.goPage(1); return; }
    this.recordLocation({ view: v, page: this.pageIndex });
    // 再创建 Swiper 时保留其实际来源页，不重置到固定的中间页。
    this.swiperInitialIndex = this.pageIndex;
    animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.view = v; });
    if (v === 'diagnostics') { this.refreshNotifyState(); }
    this.focusLocation();
  }

  private goPage(index: number): void {
    this.recordLocation({ view: 'main', page: index });
    const recreate: boolean = this.view !== 'main';
    if (recreate) { this.swiperInitialIndex = index; this.slidePos = index; }
    this.pageIndex = index; this.view = 'main';
    if (!recreate) { try { this.swiper.changeIndex(index, true); } catch (e) { } }
    if (index === 2) { this.refreshSessions(); }
    this.focusLocation();
  }

  private focusLocation(): void {
    setTimeout(() => {
      const id: string = this.view === 'main'
        ? (this.pageIndex === 0 ? 'crown-menu' : (this.pageIndex === 2 ? 'crown-quick' : 'crown-main'))
        : 'crown-' + this.view;
      try { this.getUIContext().getFocusController().requestFocus(id); } catch (e) { }
    }, 140);
  }

  private animateReturn(action: () => void): void {
    if (this.returnAnimating) { return; }
    this.returnAnimating = true;
    this.resetChatChrome();
    this.resetCrown();
    // 先让当前页退出，再替换内容并让上一页进入；不依赖条件节点是否自带 transition。
    animateTo({ duration: 110, curve: Curve.EaseIn, onFinish: () => {
      action();
      this.sceneX = -this.px(20); this.sceneOpacity = 0.2;
      animateTo({ duration: 170, curve: Curve.EaseOut, onFinish: () => { this.returnAnimating = false; } }, () => {
        this.sceneX = 0; this.sceneOpacity = 1;
      });
    } }, () => { this.sceneX = this.px(30); this.sceneOpacity = 0; });
  }

  private restoreLocation(target: WatchLocation): void {
    this.animateReturn(() => {
      this.editingInput = false;
      this.localDeleteArmed = false; this.showModels = false; this.showPrompt = false;
      this.swiperInitialIndex = target.page; this.pageIndex = target.page;
      this.slidePos = target.page; this.view = target.view;
      if (target.view === 'main') {
        try { this.swiper.changeIndex(target.page, false); } catch (e) { }
      }
      this.focusLocation();
    });
  }

  private backScene(): void {
    const target = this.viewHistory.pop();
    if (target) { this.restoreLocation(target); }
    else { this.restoreLocation({ view: this.token !== '' || this.chatKind === 'local' ? 'main' : 'connect', page: 1 }); }
  }

  onBackPress(): boolean { return this.requestBack(); }

  private requestBack(): boolean {
    if (!this.bootReady || this.returnAnimating) { return true; }
    // 系统边缘返回和组件手势有时会同一轮到达，只消费一次。
    const now: number = Date.now();
    if (now - this.lastBackAt < 350) { return true; }
    this.lastBackAt = now;
    if (this.editingInput) {
      this.editingInput = false;
      try { this.getUIContext().getFocusController().clearFocus(); } catch (e) { }
      return true;
    }
    if (this.showPrompt) {
      this.flushLocalDraft().catch(() => { this.toast('草稿未存盘，请重试'); });
      this.closePrompt(); return true;
    }
    if (this.showModels) { this.closeModels(); return true; }
    if (this.showGuide) { this.animateReturn(() => { this.finishGuide(); }); return true; }
    if (this.view === 'local') { this.localBackRequest++; return true; }
    if (this.viewHistory.size() > 0) { this.backScene(); return true; }
    if (this.view !== 'main' && this.view !== 'connect') { this.backScene(); return true; }
    return false; // 只有真正根界面才允许系统退出 App。
  }

  private isBackSurface(): boolean {
    return this.view !== 'main' || this.showPrompt || this.showModels || this.showGuide;
  }

  private resetCrown(): void {
    this.crownMotion.cancel(); this.crownOwner = undefined;
  }

  private crownOffset(target: Scroller): number { return this.crownOwner === target ? this.crownStretch : 0; }

  private edgeOpacity(idx: number): number {
    const itemH: number = 34;
    const center: number = idx * itemH + itemH / 2 - this.scrollY;
    const mid: number = this.viewH / 2;
    const d: number = Math.min(1, Math.abs(center - mid) / Math.max(1, mid));
    return Math.max(0.7, 1 - d * 0.3);
  }

  private edgeScale(idx: number): number {
    const itemH: number = 34;
    const center: number = idx * itemH + itemH / 2 - this.scrollY;
    const mid: number = this.viewH / 2;
    const d: number = Math.min(1, Math.abs(center - mid) / Math.max(1, mid));
    return 1 - d * 0.16;
  }

  private activeScroller(): Scroller {
    if (this.view === 'prompt') {
      return this.promptScroller;
    }
    if (this.view === 'connect') {
      return this.connectScroller;
    }
    if (this.view === 'approval') {
      return this.approvalScroller;
    }
    if (this.view === 'sessions') {
      return this.sessionsScroller;
    }
    return this.scroller;
  }

  private measureChatStart(): void {
    try {
      const first: RectResult = this.scroller.getItemRect(0);
      if (first.height > 0) {
        this.chatScrollOrigin = this.scroller.currentOffset().yOffset + first.y - this.px(48);
      }
    } catch (e) { }
  }

  private canImmerseChat(): boolean {
    return this.view === 'main' && this.pageIndex === 1 && !this.showPrompt && !this.showModels &&
      !this.showGuide && this.pageVisible && !this.returnAnimating;
  }

  private focusMainCrown(retry: boolean = true): void {
    if (!this.canImmerseChat()) { return; }
    try { this.getUIContext().getFocusController().requestFocus('crown-main'); } catch (e) { }
    if (retry && this.chatFocusTimer < 0) {
      // API 20 的 requestFocus 没有返回值；首次挂载后只补一次，并重新检查当前页面。
      this.chatFocusTimer = setTimeout(() => {
        this.chatFocusTimer = -1; this.focusMainCrown(false);
      }, 80);
    }
  }

  private routeMainCrown(event: CrownEvent): void {
    if (!this.canImmerseChat()) { return; }
    event.stopPropagation();
    this.handleCrown(this.scroller, event);
  }

  private animateChatChrome(hidden: boolean): void {
    if (this.chatChromeHidden === hidden) { return; }
    this.chatChromeHidden = hidden;
    animateTo({ duration: hidden ? 150 : 220, curve: Curve.EaseOut }, () => {
      this.chatChromeProgress = hidden ? 1 : 0;
    });
  }

  private finishChatCrown(): void {
    if (this.chatCrownQuietTimer >= 0) { clearTimeout(this.chatCrownQuietTimer); this.chatCrownQuietTimer = -1; }
    this.chatChrome.crownEnd();
  }

  private resetChatChrome(): void {
    if (this.chatFocusTimer >= 0) { clearTimeout(this.chatFocusTimer); this.chatFocusTimer = -1; }
    if (this.chatCrownQuietTimer >= 0) { clearTimeout(this.chatCrownQuietTimer); this.chatCrownQuietTimer = -1; }
    this.chatChrome.reset();
  }

  private handleChatTouch(event: TouchEvent): void {
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) { this.chatChrome.touchEnd(); return; }
    if (!this.canImmerseChat() || event.touches.length === 0) { return; }
    const point: TouchObject = event.touches[0];
    if (event.type === TouchType.Down) {
      this.focusMainCrown();
      this.finishChatCrown(); this.chatChrome.touchStart(point.x, point.y);
    } else if (event.type === TouchType.Move) {
      this.chatChrome.touchMove(point.x, point.y, this.px(6));
    }
  }

  private handleChatCrown(event: CrownEvent): void {
    if (event.action === CrownAction.END) { this.finishChatCrown(); return; }
    if (event.action !== CrownAction.UPDATE || event.degree === 0 || !this.canImmerseChat()) { return; }
    this.chatChrome.crownUpdate();
    if (this.chatCrownQuietTimer >= 0) { clearTimeout(this.chatCrownQuietTimer); }
    // END 因焦点/系统取消而丢失时仍能恢复，连续更新只重置这一只短定时器。
    this.chatCrownQuietTimer = setTimeout(() => {
      this.chatCrownQuietTimer = -1; this.chatChrome.crownEnd();
    }, 260);
  }

  private handleCrown(target: Scroller, event: CrownEvent): void {
    if (target === this.scroller) { this.handleChatCrown(event); }
    if (this.crownOwner !== target) { this.resetCrown(); this.crownOwner = target; }
    if (event.action === CrownAction.BEGIN) { this.crownMotion.begin(); return; }
    if (event.action === CrownAction.END) { this.crownMotion.end(); return; }
    if (event.action !== CrownAction.UPDATE) { return; }
    try {
      if (target === this.scroller) { this.measureChatStart(); }
      const current: number = target.currentOffset().yOffset;
      const origin: number = target === this.scroller ? this.chatScrollOrigin : 0;
      const next: number = this.crownMotion.updateAtEdges(-event.degree * 2, current,
        current <= origin + 0.5, target.isAtEnd());
      if (target === this.scroller) {
        // List 的 contentStartOffset 可能令 currentOffset 为负；scrollTo 会把负目标归 0。
        target.scrollBy(0, next - current);
      } else {
        target.scrollTo({ xOffset: 0, yOffset: next, animation: false });
      }
    } catch (e) { this.resetCrown(); }
  }

  private async doConnect(): Promise<void> {
    const base: string = normalizeUrl(this.server);
    if (base === '') {
      this.message = '先填地址';
      return;
    }
    if (this.code.length < 6) {
      this.message = '配对码 6 位';
      return;
    }
    this.connecting = true;
    this.message = '连接中…';
    try {
      const r: SimpleResult = await pair(base, this.code);
      if (r.ok !== true) {
        this.message = r.error === undefined ? '配对失败' : r.error;
        return;
      }
      this.server = base;
      this.primaryServer = base;
      if (r.addresses !== undefined && r.addresses.length > 0) {
        this.lanUrl = 'http://' + r.addresses[0];
      }
      this.usingRemote = false;
      this.token = r.token === undefined ? '' : r.token;
      this.connected = true;
      this.lastSeq = -1;
      this.events = [];
      this.switchView('main');
      await this.persist();
      this.startPolling();
      this.toast('已连上');
    } catch (e) {
      this.message = '连不上：' + this.errText(e);
    } finally {
      this.connecting = false;
    }
  }

  private async doSend(mode: string): Promise<void> {
    if (this.chatKind === 'local') { await this.sendLocal(); return; }
    const t: string = this.promptText.trim();
    if (t === '' || this.token === '') {
      return;
    }
    try {
      const r: SimpleResult = await sendPrompt(this.server, this.token, t, mode);
      if (r.ok === true) {
        this.promptText = '';
        this.closePrompt();
        this.switchView('main');
        this.toast(mode === 'steer' ? '已插话' : '已排队');
      } else {
        this.toast(r.error === undefined ? '发送失败' : r.error);
      }
    } catch (e) {
      this.toast('发送失败');
    }
  }

  private async sendPreset(text: string): Promise<void> {
    if (this.chatKind === 'local') {
      if (this.localBusy) { this.toast('请等待当前回复'); return; }
      this.changeComposer(text); await this.sendLocal(); return;
    }
    if (this.token === '') {
      return;
    }
    try {
      const r: SimpleResult = await sendPrompt(this.server, this.token, text, 'followup');
      if (r.ok === true) {
        this.goPage(1);
        this.toast('已发送');
      } else {
        this.toast(r.error === undefined ? '发送失败' : r.error);
      }
    } catch (e) {
      this.toast('发送失败');
    }
  }

  private async doDecide(decision: string): Promise<void> {
    if (this.pending.length === 0) {
      return;
    }
    const id: string = this.pending[0].id;
    try {
      const r: SimpleResult = await decideApproval(this.server, this.token, id, decision);
      if (r.ok === true) {
        this.pending = [];
        this.backScene();
        this.toast(decision === 'allow' ? '已允许' : '已拒绝');
      } else {
        this.toast('提交失败');
      }
    } catch (e) {
      this.toast('提交失败');
    }
  }

  private async doNew(): Promise<void> {
    if (this.chatKind === 'local') { await this.enterLocal('', true); return; }
    if (this.token === '') { this.toast('请先连接 DSH 宿主'); return; }
    if (this.changingSession) { return; }
    this.changingSession = true;
    this.requestGeneration += 1;
    if (this.feedSessionId !== '') {
      await this.saveHistory(this.feedSessionId, this.events);
    }
    this.toast('创建会话中…');
    try {
      const r: SimpleResult = await newSession(this.server, this.token);
      if (r.ok === true) {
        this.events = [];
        this.lastSeq = -1;
        this.feedSessionId = '';
        this.switchView('main');
        this.toast('新会话');
      } else {
        this.toast('新建失败');
      }
    } catch (e) {
      this.toast('新建失败');
    } finally {
      this.changingSession = false;
      this.poll();
    }
  }

  private openSessions(): void {
    this.localDeleteArmed = false;
    this.updatePicker();
    this.flushLocalDraft().catch(() => { this.toast('当前草稿未保存，请重试'); });
    this.switchView('sessions');
    this.refreshSessions();
  }

  private async refreshSessions(): Promise<void> {
    if (this.token === '') {
      return;
    }
    try {
      const r = await fetchSessions(this.server, this.token);
      if (r.sessions) {
        this.syncSessions(r.sessions);
      }
    } catch (e) {
    }
  }

  // 会话列表每 2 秒都会到一份，签名没变就不重建，省掉整屏重排。
  private syncSessions(list: SessionInfo[]): void {
    this.sessions = list;
    let sig: string = '';
    for (let i = 0; i < list.length; i++) {
      const s: SessionInfo = list[i];
      sig += s.id + '|' + s.title + '|' + (s.running ? '1' : '0') + (s.live ? '1' : '0') + ';';
    }
    if (sig !== this.sessionSig) {
      this.sessionSig = sig;
      this.sessionSource.set(list);
      this.updatePicker();
    }
  }

  private async doSelect(id: string): Promise<void> {
    if (this.token === '') { this.toast('请先连接 DSH 宿主'); return; }
    if (this.localUnsaved) { this.toast('请先保存已收到的本地回复'); return; }
    if (this.changingSession) { return; }
    this.changingSession = true;
    this.requestGeneration += 1;
    try {
      await this.flushLocalDraft();
      const r: SimpleResult = await selectSession(this.server, this.token, id);
      if (r.ok === true) {
        await this.useDsh();
        if (this.feedSessionId !== '') {
          await this.saveHistory(this.feedSessionId, this.events);
        }
        this.events = await this.loadHistory(id);
        this.lastSeq = -1;
        this.feedSessionId = id;
        this.switchView('main');
      } else {
        this.toast('切换失败');
      }
    } catch (e) {
      this.toast('切换失败');
    } finally {
      this.changingSession = false;
      this.poll();
    }
  }

  private async doStop(): Promise<void> {
    // 两段式：第一下只是亮个红，3 秒内再点才真的停，避免表冠误触。
    if (!this.stopArmed) {
      this.stopArmed = true;
      this.toast('再点一次确认停止');
      if (this.stopTimer >= 0) {
        clearTimeout(this.stopTimer);
      }
      this.stopTimer = setTimeout(() => {
        this.stopArmed = false;
        this.stopTimer = -1;
      }, 3000);
      return;
    }
    this.stopArmed = false;
    if (this.stopTimer >= 0) {
      clearTimeout(this.stopTimer);
      this.stopTimer = -1;
    }
    if (this.chatKind === 'local') {
      this.localUiEpoch++; this.localController?.cancel();
      this.toast('已停止，输入已留在本地草稿'); return;
    }
    try {
      await cancelTurn(this.server, this.token);
      this.toast('已请求停止');
    } catch (e) {
      this.toast('请求失败');
    }
  }

  private toast(text: string): void {
    this.message = text;
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer);
    }
    const self = this;
    this.toastTimer = setTimeout(() => {
      if (self.message === text) {
        self.message = '';
      }
    }, 2600);
  }

  private errText(e: Object): string {
    const be = e as BusinessError;
    return be && be.message ? be.message : '未知错误';
  }

  private imageUrl(ev: DshEvent, index: number): string {
    const img: DshImage | undefined = ev.images === undefined ? undefined : ev.images[index];
    if (img === undefined) {
      return '';
    }
    // 按附件 id 取：事件滚出宿主缓存后图还在。
    return this.server + '/api/image?token=' + encodeURIComponent(this.token) +
      '&id=' + encodeURIComponent(img.attachmentId) + '&type=' + encodeURIComponent(img.mediaType);
  }

  private formatEvent(ev: DshEvent): string {
    const t: string = ev.text === undefined ? '' : ev.text;
    const tool: string = ev.tool === undefined ? '' : ev.tool;
    const kind: string = ev.kind;
    if (kind === 'user') {
      return '你 · ' + t;
    }
    if (kind === 'assistant') {
      return t;
    }
    if (kind === 'tool') {
      return '▸ ' + (tool === '' ? '工具' : tool) + (t === '' ? '' : ' ' + t);
    }
    if (kind === 'tool-result') {
      return '✓ ' + t;
    }
    if (kind === 'turn') {
      if (ev.reason === 'error') { return '本轮执行失败，请在手机查看详情'; }
      return ev.running === true ? '… 执行中' : '— 结束';
    }
    if (kind === 'status') {
      return ev.running === true ? '运行中' : '待命';
    }
    if (kind === 'approval') {
      return '⚠ 审批：' + tool;
    }
    if (kind === 'approval-done') {
      return '审批已处理';
    }
    if (kind === 'approval-missed') {
      return '审批已转电脑';
    }
    if (kind === 'title') {
      return '标题 · ' + t;
    }
    return t;
  }

  private eventColor(ev: DshEvent): string {
    const kind: string = ev.kind;
    if (kind === 'user') {
      return '#7FB6FF';
    }
    if (kind === 'assistant') {
      return TEXT;
    }
    if (kind === 'tool') {
      return '#FFC66D';
    }
    if (kind === 'tool-result') {
      return '#9ED49A';
    }
    if (kind === 'approval') {
      return WARN;
    }
    if (kind === 'turn' || kind === 'status') {
      return DIM;
    }
    return '#9AA6B5';
  }

  // 以下仅为视觉与布局，网络、配对、消息处理沿用原实现。
  private eventSurface(ev: DshEvent): string {
    if (ev.kind === 'user') {
      return '#152B2A';
    }
    if (ev.kind === 'assistant') {
      return '#142026';
    }
    return '#0D151B';
  }

  private pagePos(): number {
    if (this.view === 'main') { return this.pageIndex; }
    return -1;
  }

  @Builder
  PageDots() {
    Stack() {
      Row() {
        Text('')
          .width(this.px(4))
          .height(this.px(4))
          .backgroundColor('#5E6E74')
          .borderRadius(this.px(2))
          .margin({ left: this.px(3), right: this.px(3) })
        Text('')
          .width(this.px(4))
          .height(this.px(4))
          .backgroundColor('#5E6E74')
          .borderRadius(this.px(2))
          .margin({ left: this.px(3), right: this.px(3) })
        Text('')
          .width(this.px(4))
          .height(this.px(4))
          .backgroundColor('#5E6E74')
          .borderRadius(this.px(2))
          .margin({ left: this.px(3), right: this.px(3) })
      }
      .height(this.px(4))
      Text('')
        .width(this.px(10))
        .height(this.px(4))
        .backgroundColor('#FFFFFF')
        .borderRadius(this.px(2))
        .position({ x: this.px(2), y: 0 })
        .translate({ x: indicatorTranslation(this.slidePos, this.px(10)), y: 0 })
    }
    .width(this.px(34))
    .height(this.px(4))
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      if (!this.bootReady) {
        Column() {
          Text('DSH')
            .fontSize(this.vp(20))
            .fontWeight(FontWeight.Bold)
            .fontColor(ACCENT)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.showGuide) {
        QuickGuide({ screenWidth: this.sw, screenHeight: this.sh,
          onFinish: () => { this.finishGuide(); } })
      } else if (this.view === 'local') {
        LocalChat({ screenWidth: this.sw, screenHeight: this.sh,
          hostBase: this.server, hostToken: this.token, settingsOnly: true,
          onConfigured: (config: DirectApiConfig) => { this.configuredLocal(config); },
          onProfileConfigured: (profile: ApiProfile) => { this.chooseApiProfile(profile.id); },
          onProfilesChanged: () => { this.reloadApiProfiles(); },
          onConfigCleared: () => { this.localController?.credentialsCleared(); },
          backRequest: this.localBackRequest,
          onRequestBack: () => { this.requestBack(); },
          onEditingChanged: (editing: boolean) => { this.editingInput = editing; },
          onClose: () => { this.backScene(); } })
      } else if (this.view === 'connect') {
        this.ConnectView()
      } else if (this.view === 'approval') {
        this.ApprovalView()
      } else if (this.view === 'sessions') {
        this.SessionsView()
      } else if (this.view === 'settings') {
        this.SettingsView()
      } else if (this.view === 'diagnostics') {
        this.DiagnosticsView()
      } else {
        Column() {
          Swiper(this.swiper) {
            this.MenuView()
            this.MainView()
            this.QuickView()
          }
          .index(this.swiperInitialIndex)
          .indicator(false)
          .loop(false)
          .cachedCount(1)
          .onContentDidScroll((_selectedIndex: number, index: number, position: number, _mainAxisLength: number) => {
            // 原生逐帧位置覆盖拖动、松手惯性、取消回弹和程序切页。
            // 不依赖 selectedIndex，避免选中页变化或同帧多页回调造成反向/跳变。
            this.slidePos = swiperProgress(index, position, 3);
          })
          .onAppear(() => {
            // 返回子页面来源时按历史重建，不把菜单/快捷强制重置成聊天页。
            this.pageIndex = this.swiperInitialIndex;
            this.slidePos = this.swiperInitialIndex;
          })
          .onAnimationEnd((i: number, _extra: SwiperAnimationEvent) => {
            // 缓存页出现时不能抢焦点；翻页完成后把表冠明确交给当前页。
            if (this.view !== 'main' || this.showGuide) { return; }
            const focus: string = i === 0 ? 'crown-menu' : (i === 2 ? 'crown-quick' : 'crown-main');
            try { this.getUIContext().getFocusController().requestFocus(focus); } catch (e) { }
          })
          .onChange((i: number) => {
            this.resetChatChrome();
            this.pageIndex = i;
            // 选中项事件不驱动白条，不能提前抢走尚未结束的原生动画。
            const focus: string = i === 0 ? 'crown-menu' : (i === 2 ? 'crown-quick' : 'crown-main');
            try { this.getUIContext().getFocusController().requestFocus(focus); } catch (e) { }
            if (i === 2) {
              this.refreshSessions();
            }
          })
          .layoutWeight(1)
          .width('100%')

          Row() {
            this.PageDots()
          }
          .width('100%')
          .height(this.px(14))
          .justifyContent(FlexAlign.Center)
          .margin({ top: this.px(1), bottom: this.px(2) })
        }
        .width('100%')
        .height('100%')
      }
      if (this.message !== '' && this.bootReady && !this.showGuide) {
        Text(this.message)
          .fontSize(this.vp(9))
          .fontWeight(FontWeight.Medium)
          .fontColor(INK)
          .maxLines(2)
          .textAlign(TextAlign.Center)
          .width(this.px(144))
          .padding({ left: this.px(10), right: this.px(10), top: this.px(6), bottom: this.px(6) })
          .backgroundColor(ACCENT)
          .borderRadius(this.px(14))
          .margin({ top: this.px(32) })
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG)
    .linearGradient({ angle: 150, colors: [['#162D32', 0], ['#0B151C', 0.32], [BG, 0.76], ['#0B151B', 1]] })
    .translate({ x: this.sceneX })
    .opacity(this.sceneOpacity)
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.resetCrown(); this.finishChatCrown();
        this.backPanStartX = event.touches.length > 0 ? event.touches[0].x : 0;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        // 列表手势被 Swiper/系统接管后，也不能让操作层一直留在隐藏状态。
        this.chatChrome.touchEnd(); this.focusMainCrown();
      }
    })
    .parallelGesture(PanGesture({ fingers: 1, direction: PanDirection.Right, distance: 18 })
      .onActionEnd((event: GestureEvent) => {
        if (this.isBackSurface() && isWatchBackSwipe(this.backPanStartX, event.offsetX,
          event.offsetY, this.sw, this.editingInput)) { this.requestBack(); }
      }))
  }

  @Builder
  ConnectView() {
    Scroll(this.connectScroller) {
      Column() {
        Text('DSH')
          .id('crown-connect')
          .fontSize(this.vp(23))
          .fontWeight(FontWeight.Bold)
          .fontColor(ACCENT)
          .letterSpacing(this.px(3))
          .focusable(true)
          .focusOnTouch(true)
          .defaultFocus(true)
          .onDigitalCrown((event: CrownEvent) => {
            this.handleCrown(this.connectScroller, event);
          })
        Text('腕上，与灵感相连')
          .fontSize(this.vp(9))
          .fontColor(DIM)
          .margin({ top: this.px(3), bottom: this.px(14) })
        TextInput({ placeholder: '服务器地址', text: this.server })
          .fontSize(this.vp(10))
          .placeholderFont({ size: this.vp(9) })
          .fontColor(TEXT)
          .placeholderColor(DIM)
          .height(this.px(32))
          .backgroundColor(CARD)
          .border({ width: 0.5, color: HAIRLINE })
          .borderRadius(this.px(12))
          .onEditChange((editing: boolean) => { this.editingInput = editing; })
          .onChange((v: string) => { this.server = v; })
        TextInput({ placeholder: '六位配对码', text: this.code })
          .type(InputType.Number)
          .fontSize(this.vp(12))
          .placeholderFont({ size: this.vp(9) })
          .fontColor(TEXT)
          .placeholderColor(DIM)
          .height(this.px(32))
          .backgroundColor(CARD)
          .border({ width: 0.5, color: HAIRLINE })
          .borderRadius(this.px(12))
          .margin({ top: this.px(7) })
          .onEditChange((editing: boolean) => { this.editingInput = editing; })
          .onChange((v: string) => { this.code = v; })
        Text('独立 API 对话')
          .fontSize(this.vp(10))
          .fontColor(ACCENT)
          .textAlign(TextAlign.Center)
          .height(this.px(34))
          .width('100%')
          .backgroundColor('#142126')
          .borderRadius(this.px(17))
          .margin({ top: this.px(10) })
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => { this.enterLocal(); })
        Text('先进入工作台')
          .fontSize(this.vp(8))
          .fontColor(DIM)
          .margin({ top: this.px(10) })
          .padding({ top: this.px(4), bottom: this.px(4), left: this.px(10), right: this.px(10) })
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => { this.switchView('main'); })
        Text(this.connecting ? '连接中…' : '连接设备  ↗')
          .fontSize(this.vp(10))
          .fontWeight(FontWeight.Medium)
          .fontColor(INK)
          .textAlign(TextAlign.Center)
          .height(this.px(30))
          .width('100%')
          .backgroundColor(ACCENT)
          .borderRadius(this.px(15))
          .margin({ top: this.px(10) })
          .enabled(!this.connecting)
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => { this.doConnect(); })
      }
      .width('100%')
      .padding({ left: this.px(43), right: this.px(43), top: this.px(34), bottom: this.px(38) })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .translate({ y: this.crownStretch })
  }

  @Builder
  ChatBubble(ev: DshEvent) {
    Column() {
      if ((ev.text === undefined ? '' : ev.text) !== '') {
        Text(ev.kind === 'user' ? (ev.text === undefined ? '' : ev.text) : this.formatEvent(ev))
          .fontSize(this.vp(11))
          .lineHeight(this.vp(16))
          .fontColor(ev.kind === 'user' ? '#0C1B10' : TEXT)
          .textAlign(TextAlign.Start)
      }
      if (ev.images !== undefined && ev.images.length > 0) {
        Image(this.imageUrl(ev, 0))
          .width(this.px(100))
          .height(this.px(74))
          .objectFit(ImageFit.Cover)
          .borderRadius(this.px(8))
          .margin({ top: this.px(3) })
          .onError(() => { this.imgFail += 1; })
        if (ev.images.length > 1) {
          Text('+' + (ev.images.length - 1) + ' 张')
            .fontSize(this.vp(7))
            .fontColor(ev.kind === 'user' ? '#33501F' : DIM)
            .margin({ top: this.px(2) })
        }
      }
    }
    .alignItems(ev.kind === 'user' ? HorizontalAlign.End : HorizontalAlign.Start)
    .padding({ left: this.px(12), right: this.px(12), top: this.px(8), bottom: this.px(8) })
    .backgroundColor(ev.kind === 'user' ? '#95EC69' : '#18242A')
    .borderRadius(this.px(16))
    .constraintSize({ maxWidth: this.px(172) })
  }

  @Builder
  MainView() {
    Stack({ alignContent: Alignment.Center }) {
        // 聊天永久铺满该页，顶/底操作层浮在上方；隐藏时不改变 List 高度或滚动位置。
        List({ scroller: this.scroller }) {
          if (this.chatEvents().length === 0) {
            ListItem() {
              Column() {
                Text(this.chatKind === 'local' ? '独立对话' : (this.connected ? '一切就绪' : '正在重连'))
                  .fontSize(this.vp(13))
                  .fontWeight(FontWeight.Medium)
                  .fontColor(TEXT)
                Text(this.chatKind === 'local' ? '记录保存在手表 · 无需宿主在线' : (this.connected ? '从腕上发起下一步' : '等待设备重新上线'))
                  .fontSize(this.vp(8))
                  .fontColor(DIM)
                  .margin({ top: this.px(5) })
              }
              .width('100%')
              .padding({ top: this.px(22), bottom: this.px(22) })
            }
          } else {
            ForEach(this.chatEvents(), (ev: DshEvent, idx: number) => {
              ListItem() {
                if (ev.kind === 'user' || ev.kind === 'assistant') {
                  Row() {
                    this.ChatBubble(ev)
                  }
                  .width('100%')
                  .justifyContent(ev.kind === 'user' ? FlexAlign.End : FlexAlign.Start)
                  .padding({ left: this.px(4), right: this.px(4), top: this.px(3), bottom: this.px(3) })
                  .opacity(1)
                } else if (ev.kind === 'info') {
                  Text(ev.text || '')
                    .fontSize(this.vp(9))
                    .lineHeight(this.vp(13))
                    .fontColor(DIM)
                    .textAlign(TextAlign.Center)
                    .width('100%')
                    .padding({ top: this.px(6), bottom: this.px(6), left: this.px(12), right: this.px(12) })
                } else {
                  Column() {
                    Row() {
                      Text(this.formatEvent(ev))
                        .fontSize(this.vp(9))
                        .lineHeight(this.vp(12))
                        .fontColor(this.eventColor(ev))
                        .maxLines(this.expandedSeq === ev.seq ? 12 : 1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .layoutWeight(1)
                      Text(this.expandedSeq === ev.seq ? '⌃' : '⌄')
                        .fontSize(this.vp(10))
                        .fontColor(DIM)
                        .padding({ left: this.px(4) })
                        .onClick(() => { this.toggleDetail(ev); })
                    }
                    .width('100%')
                    if (this.expandedSeq === ev.seq && this.expandedText !== '') {
                      Text(this.expandedText)
                        .fontSize(this.vp(8))
                        .lineHeight(this.vp(11))
                        .fontColor(DIM)
                        .width('100%')
                        .margin({ top: this.px(4) })
                    }
                  }
                  .width('100%')
                  .padding({ left: this.px(10), right: this.px(10), top: this.px(6), bottom: this.px(6) })
                  .margin({ left: this.px(6), right: this.px(6) })
                  .backgroundColor('#0B1418')
                  .borderRadius(this.px(12))
                  .opacity(1)
                }
              }
            }, (ev: DshEvent) => this.chatEventKey(ev))
          }
        }
        .width('100%')
        .height('100%')
        .contentStartOffset(this.px(48))
        .contentEndOffset(this.px(this.pending.length > 0 ? 90 : 64))
        .padding({ left: this.px(17), right: this.px(17) })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .translate({ y: this.crownOffset(this.scroller) })
        .onTouch((event: TouchEvent) => { this.handleChatTouch(event); })
        .onScroll((offset: number, _state: ScrollState) => { this.scrollY = offset; this.measureChatStart(); })
        .onAreaChange((_old: Area, area: Area) => { this.viewH = area.height as number; this.measureChatStart(); })
        .focusable(false)

        // 叶子焦点不随顶栏淡出移动，也不与 List 自带的表冠滚动争抢。
        Text(' ')
          .id('crown-main')
          .width(this.px(12)).height(this.px(12))
          .fontColor('#00484848')
          .position({ x: this.px(110), y: this.px(52) })
          .focusable(true)
          .defaultFocus(true)
          .hitTestBehavior(HitTestMode.None)
          .accessibilityLevel('no')
          .onDigitalCrown((event: CrownEvent) => { this.routeMainCrown(event); })

        // 全高纵向布局用弹性空白分开上下操作层；align() 只对齐组件内部内容，不能定位 Stack 子项。
        Column() {
        Column() {
        Row() {
          Text(this.chatTitle())
            .fontSize(this.vp(10))
            .fontWeight(FontWeight.Medium)
            .fontColor(TEXT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Circle({ width: this.vp(5), height: this.vp(5) })
            .fill(this.chatKind === 'local' ? (this.localBusy ? WARN : ACCENT) : (this.connected ? (this.status === 'running' ? WARN : OK) : DIM))
            .margin({ left: this.px(7) })
        }
        .width('100%')
        .height(this.px(26))
        .padding({ left: this.px(57), right: this.px(57) })
        }
        .id('chat-header')
        .width('100%')
        .height(this.px(48))
        .padding({ top: this.px(18), bottom: this.px(4) })
        .opacity(1 - this.chatChromeProgress)
        .translate({ y: -this.px(64) * this.chatChromeProgress })
        .hitTestBehavior(this.chatChromeHidden ? HitTestMode.None : HitTestMode.Default)

        Blank()
          .layoutWeight(1)
          .hitTestBehavior(HitTestMode.None)

        Column() {
        if (this.pending.length > 0) {
          Text('待审批  ' + this.pending.length + '  ›')
            .fontSize(this.vp(9))
            .fontColor(WARN)
            .textAlign(TextAlign.Center)
            .height(this.px(22))
            .width('100%')
            .backgroundColor('#30251E')
            .border({ width: 0.5, color: '#40EFC49A' })
            .borderRadius(this.px(11))
            .margin({ top: this.px(4) })
            .clickEffect({ level: ClickEffectLevel.LIGHT })
            .onClick(() => { this.switchView('approval'); })
        }

        Row() {
          Row() {
            Text('+')
              .fontSize(this.vp(15))
              .fontColor(ACCENT)
              .margin({ right: this.px(6) })
            Text(this.localUnsaved && this.chatKind === 'local' ? '重试保存回复' : (this.promptText.trim() === '' ? (this.chatKind === 'local' ? '发消息' : '发送指令') : this.promptText))
              .fontSize(this.vp(9))
              .fontColor(TEXT)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .height(this.px(28))
          .layoutWeight(1)
          .padding({ left: this.px(11), right: this.px(9) })
          .backgroundColor('#0D181C')
          .border({ width: 0.5, color: '#2A4046' })
          .borderRadius(this.px(14))
          .accessibilityText('编辑指令')
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => { this.openPrompt(); })
          Text(this.stopArmed ? '确认' : '■')
            .fontSize(this.stopArmed ? this.vp(7) : this.vp(8))
            .fontColor(this.stopArmed ? '#FFFFFF' : BAD)
            .textAlign(TextAlign.Center)
            .width(this.stopArmed ? this.px(34) : this.px(28))
            .height(this.px(28))
            .backgroundColor(this.stopArmed ? '#7A2A2E' : '#282126')
            .border({ width: 0.5, color: this.stopArmed ? '#B4585C' : '#46F1ABA8' })
            .borderRadius(this.px(14))
            .margin({ left: this.px(6) })
            .accessibilityText(this.stopArmed ? '确认停止当前任务' : '停止当前任务')
            .clickEffect({ level: ClickEffectLevel.LIGHT })
            .onClick(() => { this.doStop(); })
        }
        .width('100%')
        .padding({ left: this.px(20), right: this.px(20) })
        .margin({ top: this.px(7), bottom: this.px(2) })

        Row() {
          Text(this.modelCaption())
            .fontSize(this.vp(7))
            .fontColor(this.modelPending ? WARN : (this.selectionModel === '' ? DIM : ACCENT))
            .height(this.px(16))
            .padding({ left: this.px(11), right: this.px(11) })
            .textAlign(TextAlign.Center)
            .backgroundColor('#14D5EFE9')
            .border({ width: 0.5, color: '#2AD7F1EB' })
            .borderRadius(this.px(8))
            .clickEffect({ level: ClickEffectLevel.LIGHT })
            .onClick(() => { this.openModels(); })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ top: this.px(3) })

      }
      .id('chat-footer')
      .width('100%')
      .padding({ left: this.px(13), right: this.px(13), bottom: this.px(8) })
      .opacity(1 - this.chatChromeProgress)
      .translate({ y: this.px(108) * this.chatChromeProgress })
      .hitTestBehavior(this.chatChromeHidden ? HitTestMode.None : HitTestMode.Default)
        }
        .id('chat-controls-overlay')
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)

      if (this.showPrompt) {
        Stack() {
          Column() {}
            .width('100%')
            .height('100%')
            .backgroundColor('#9903070A')
            .onClick(() => { this.closePrompt(); })
          Column() {
            Row() {
              Text(this.chatKind === 'local' ? '新消息' : '新指令')
                .fontSize(this.vp(11))
                .fontWeight(FontWeight.Medium)
                .fontColor(TEXT)
                .layoutWeight(1)
              Text('×')
                .fontSize(this.vp(16))
                .fontColor(DIM)
                .textAlign(TextAlign.Center)
                .width(this.px(24))
                .height(this.px(24))
                .accessibilityText('收起指令')
                .clickEffect({ level: ClickEffectLevel.LIGHT })
                .onClick(() => { this.closePrompt(); })
            }
            .width('100%')
            .height(this.px(24))
            TextArea({ placeholder: '说点什么', text: this.promptText })
              .placeholderFont({ size: this.vp(9) })
              .fontSize(this.vp(10))
              .fontColor(TEXT)
              .placeholderColor(DIM)
              .backgroundColor('#0B171D')
              .border({ width: 0.5, color: '#35B8E0D6' })
              .borderRadius(this.px(12))
              .height(this.px(44))
              .width('100%')
              .padding(this.px(8))
              .margin({ top: this.px(5) })
              .onEditChange((editing: boolean) => { this.editingInput = editing; })
          .onChange((v: string) => { this.changeComposer(v); })
            Row() {
              if (this.chatKind === 'dsh') {
              Text('插话')
                .fontSize(this.vp(9))
                .fontColor(TEXT)
                .textAlign(TextAlign.Center)
                .height(this.px(28))
                .layoutWeight(1)
                .backgroundColor('#23343A')
                .border({ width: 0.5, color: HAIRLINE })
                .borderRadius(this.px(14))
                .clickEffect({ level: ClickEffectLevel.LIGHT })
                .onClick(() => { this.doSend('steer'); })
              }
              Text('发送 ↗')
                .fontSize(this.vp(9))
                .fontWeight(FontWeight.Medium)
                .fontColor(INK)
                .textAlign(TextAlign.Center)
                .height(this.px(28))
                .layoutWeight(1)
                .backgroundColor(ACCENT)
                .borderRadius(this.px(14))
                .margin({ left: this.chatKind === 'local' ? 0 : this.px(7) })
                .clickEffect({ level: ClickEffectLevel.LIGHT })
                .onClick(() => { this.doSend('followup'); })
            }
            .width('100%')
            .margin({ top: this.px(7) })
          }
          .width(this.px(174))
          .padding({ left: this.px(14), right: this.px(14), top: this.px(10), bottom: this.px(12) })
          .linearGradient({ angle: 145, colors: [['#F32A4144', 0], ['#F2112029', 1]] })
          .backgroundBlurStyle(BlurStyle.Thin, { colorMode: ThemeColorMode.DARK })
          .borderRadius(this.px(22))
          .border({ width: 0.5, color: '#66C2E5DA' })
          .shadow({ radius: this.px(18), color: '#66000000', offsetY: this.px(7) })
          .transition(TransitionEffect.scale({ x: 0.94, y: 0.94 }).combine(TransitionEffect.OPACITY))
        }
        .width('100%')
        .height('100%')
        .transition(TransitionEffect.OPACITY)
      }

      if (this.showModels) {
        Stack() {
          Column() {}
            .width('100%')
            .height('100%')
            .backgroundColor('#9903070A')
            .onClick(() => { this.closeModels(); })
          Column() {
            Row() {
              Text('切换模型')
                .fontSize(this.vp(11))
                .fontWeight(FontWeight.Medium)
                .fontColor(TEXT)
                .layoutWeight(1)
              Text('×')
                .fontSize(this.vp(16))
                .fontColor(DIM)
                .textAlign(TextAlign.Center)
                .width(this.px(24))
                .height(this.px(24))
                .onClick(() => { this.closeModels(); })
            }
            .width('100%')
            .height(this.px(22))
            if (this.modelsLoading && (this.chatKind === 'local' ? this.apiProfiles.length === 0 : this.modelOptions.length === 0)) {
              Text('读取中…')
                .fontSize(this.vp(9))
                .fontColor(DIM)
                .width('100%')
                .textAlign(TextAlign.Center)
                .margin({ top: this.px(24) })
            }
            List({ scroller: this.modelsScroller }) {
              if (this.chatKind === 'local') {
                ForEach(this.apiProfiles, (profile: ApiProfile) => {
                  ListItem() {
                    Column() {
                      Text((profile.id === this.selectedApiId ? '✓ ' : '') + profile.name)
                        .fontSize(this.vp(10)).fontColor(profile.id === this.selectedApiId ? ACCENT : TEXT)
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(profile.model)
                        .fontSize(this.vp(8)).fontColor(DIM).maxLines(1)
                      Text(profile.baseUrl)
                        .fontSize(this.vp(7)).fontColor(DIM).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    .alignItems(HorizontalAlign.Start)
                    .width('100%')
                    .padding({ top: this.px(6), bottom: this.px(6) })
                    .onClick(() => { this.chooseApiProfile(profile.id); })
                  }
                }, (profile: ApiProfile) => profile.id)
              } else {
              ForEach(this.modelOptions, (p: ProviderOption) => {
                ForEach(p.models, (m: ModelOption) => {
                  ListItem() {
                    Column() {
                      Text(m.name)
                        .fontSize(this.vp(9))
                        .fontColor(m.id === this.selectionModel ? ACCENT : TEXT)
                        .width('100%')
                      Text(p.name)
                        .fontSize(this.vp(7))
                        .fontColor(DIM)
                        .width('100%')
                    }
                    .alignItems(HorizontalAlign.Start)
                    .padding({ top: this.px(5), bottom: this.px(5) })
                    .onClick(() => { this.doSwitchModel(p.id, m.id); })
                  }
                }, (m: ModelOption) => p.id + '/' + m.id)
              }, (p: ProviderOption) => p.id)
              }
            }
            .layoutWeight(1)
            .width('100%')
            .scrollBar(BarState.Off)
            .margin({ top: this.px(2) })
            .id('crown-models')
            .focusable(true)
            .defaultFocus(true)
            .onDigitalCrown((event: CrownEvent) => {
              this.handleCrown(this.modelsScroller, event);
            })
            .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
            .translate({ y: this.crownOffset(this.modelsScroller) })
            if (this.chatKind === 'local') {
              Text(this.apiProfiles.length === 0 ? '添加 API 配置' : '管理 API 配置')
                .fontSize(this.vp(10)).fontColor(ACCENT).textAlign(TextAlign.Center)
                .height(this.px(28)).width('100%').backgroundColor('#142126').borderRadius(this.px(14))
                .margin({ top: this.px(3) })
                .onClick(() => { this.closeModels(); this.openLocalSettings(); })
            }
          }
          .width(this.px(176))
          .height(this.px(150))
          .padding({ left: this.px(14), right: this.px(14), top: this.px(10), bottom: this.px(10) })
          .linearGradient({ angle: 145, colors: [['#F32A4144', 0], ['#F2112029', 1]] })
          .borderRadius(this.px(20))
          .border({ width: 0.5, color: '#66C2E5DA' })
          .transition(TransitionEffect.scale({ x: 0.88, y: 0.88 }).combine(TransitionEffect.OPACITY))
        }
        .width('100%')
        .height('100%')
        .transition(TransitionEffect.OPACITY)
      }
    }
    .width('100%')
    .height('100%')
    .onAppear(() => { this.focusMainCrown(); })
    .onDigitalCrown((event: CrownEvent) => { this.routeMainCrown(event); })
  }

  @Builder
  QuickView() {
    CrownMenu({ screenWidth: this.sw, title: '快捷',
      focusId: 'crown-quick', items: this.quickItems,
      onAction: (key: string) => {
        if (this.chatKind === 'dsh' && this.token === '') { this.toast('先连接 DSH 宿主；独立对话请进控制中心'); return; }
        if (key === 'new') { this.doNew(); return; }
        const index: number = key === 'continue' ? 0 : (key === 'status' ? 1 : (key === 'summary' ? 2 : 3));
        this.sendPreset(this.presets[index].text);
      } })
  }

  @Builder
  ApprovalView() {
    Scroll(this.approvalScroller) {
      Column() {
        Text('操作确认')
          .id('crown-approval')
          .fontSize(this.vp(14))
          .fontWeight(FontWeight.Medium)
          .fontColor(WARN)
          .padding(this.px(5))
          .focusable(true)
          .focusOnTouch(true)
          .defaultFocus(true)
          .onDigitalCrown((event: CrownEvent) => { this.handleCrown(this.approvalScroller, event); })
        if (this.pending.length > 0) {
          Text(this.pending[0].tool)
            .fontSize(this.vp(11))
            .fontColor(TEXT)
            .margin({ top: this.px(5) })
          Text(this.pending[0].reason === '' ? this.pending[0].preview : this.pending[0].reason)
            .fontSize(this.vp(9))
            .fontColor(DIM)
            .maxLines(4)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textAlign(TextAlign.Center)
            .margin({ top: this.px(6), bottom: this.px(6) })
        }
        ForEach(this.actions, (a: ActionItem) => {
          Text(a.label)
            .fontSize(this.vp(10))
            .fontColor(a.key === 'allow' ? INK : BAD)
            .textAlign(TextAlign.Center)
            .width('100%')
            .height(this.px(30))
            .backgroundColor(a.key === 'allow' ? ACCENT : '#282126')
            .border({ width: 0.5, color: a.key === 'allow' ? '#66ADE9D9' : '#38F1ABA8' })
            .borderRadius(this.px(15))
            .margin({ top: this.px(6) })
            .clickEffect({ level: ClickEffectLevel.LIGHT })
            .onClick(() => { this.doDecide(a.key); })
        }, (a: ActionItem) => a.key)
        Text('超时后交回主机处理')
          .fontSize(this.vp(7))
          .fontColor(DIM)
          .margin({ top: this.px(8) })
      }
      .width('100%')
      .padding({ left: this.px(42), right: this.px(42), top: this.px(36), bottom: this.px(38) })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .translate({ y: this.crownStretch })
  }

  @Builder
  MenuView() {
    CrownMenu({ screenWidth: this.sw, title: '控制中心',
      focusId: 'crown-menu', items: this.menuItems,
      onAction: (key: string) => {
        if (key === 'sessions') { this.openSessions(); }
        else if (key === 'local-chat') { this.enterLocal(); }
        else if (key === 'local') { this.openLocalSettings(); }
        else if (key === 'guide') { this.swiperInitialIndex = this.pageIndex; this.showGuide = true; }
        else { this.switchView(key); }
      } })
  }

  @Builder
  SettingsView() {
    Scroll(this.settingsScroller) {
      Column() {
      Text('设置')
        .id('crown-settings')
        .fontSize(this.vp(14))
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT)
        .focusable(true)
        .focusOnTouch(true)
        .defaultFocus(true)
      Column() {
        Text('内网地址')
          .fontSize(this.vp(7))
          .fontColor(DIM)
        TextInput({ placeholder: '192.168.x.x:8765', text: this.lanEdit })
          .fontSize(this.vp(8))
          .placeholderFont({ size: this.vp(7) })
          .fontColor(TEXT)
          .placeholderColor(DIM)
          .height(this.px(24))
          .width('100%')
          .backgroundColor('#0B171D')
          .border({ width: 0.5, color: '#35B8E0D6' })
          .borderRadius(this.px(9))
          .margin({ top: this.px(4) })
          .onEditChange((editing: boolean) => { this.editingInput = editing; })
          .onChange((v: string) => { this.lanEdit = v; })
        Text('外网地址')
          .fontSize(this.vp(7))
          .fontColor(DIM)
          .margin({ top: this.px(6) })
        TextInput({ placeholder: 'https://...trycloudflare.com', text: this.remoteEdit })
          .fontSize(this.vp(8))
          .placeholderFont({ size: this.vp(7) })
          .fontColor(TEXT)
          .placeholderColor(DIM)
          .height(this.px(24))
          .width('100%')
          .backgroundColor('#0B171D')
          .border({ width: 0.5, color: '#35B8E0D6' })
          .borderRadius(this.px(9))
          .margin({ top: this.px(4) })
          .onEditChange((editing: boolean) => { this.editingInput = editing; })
          .onChange((v: string) => { this.remoteEdit = v; })
        TextInput({ placeholder: '6 位配对码', text: this.settingsCode })
          .type(InputType.Number)
          .fontSize(this.vp(9))
          .placeholderFont({ size: this.vp(7) })
          .fontColor(TEXT)
          .placeholderColor(DIM)
          .height(this.px(24))
          .width('100%')
          .backgroundColor('#0B171D')
          .border({ width: 0.5, color: '#35B8E0D6' })
          .borderRadius(this.px(9))
          .margin({ top: this.px(5) })
          .onEditChange((editing: boolean) => { this.editingInput = editing; })
          .onChange((v: string) => { this.settingsCode = v; })
        Row() {
          Text('保存地址')
            .fontSize(this.vp(8))
            .fontColor(TEXT)
            .textAlign(TextAlign.Center)
            .height(this.px(22))
            .layoutWeight(1)
            .backgroundColor('#23343A')
            .border({ width: 0.5, color: HAIRLINE })
            .borderRadius(this.px(11))
            .clickEffect({ level: ClickEffectLevel.LIGHT })
            .onClick(() => { this.applyServer(); })
          Text('配对')
            .fontSize(this.vp(8))
            .fontColor(INK)
            .textAlign(TextAlign.Center)
            .height(this.px(22))
            .layoutWeight(1)
            .backgroundColor(ACCENT)
            .borderRadius(this.px(11))
            .margin({ left: this.px(6) })
            .clickEffect({ level: ClickEffectLevel.LIGHT })
            .onClick(() => { this.pairFromSettings(); })
        }
        .width('100%')
        .margin({ top: this.px(6) })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding(this.px(11))
      .backgroundColor(CARD)
      .border({ width: 0.5, color: HAIRLINE })
      .borderRadius(this.px(14))
      .margin({ top: this.px(12) })
      Row() {
        Text('网络')
          .fontSize(this.vp(8))
          .fontColor(DIM)
          .layoutWeight(1)
        Text('自动')
          .fontSize(this.vp(8))
          .fontColor(this.netMode === 'auto' ? INK : DIM)
          .textAlign(TextAlign.Center)
          .height(this.px(20))
          .padding({ left: this.px(10), right: this.px(10) })
          .backgroundColor(this.netMode === 'auto' ? ACCENT : '#142126')
          .borderRadius(this.px(10))
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => { this.setNetMode('auto'); })
        Text('内网')
          .fontSize(this.vp(8))
          .fontColor(this.netMode === 'lan' ? INK : DIM)
          .textAlign(TextAlign.Center)
          .height(this.px(20))
          .padding({ left: this.px(10), right: this.px(10) })
          .backgroundColor(this.netMode === 'lan' ? ACCENT : '#142126')
          .borderRadius(this.px(10))
          .margin({ left: this.px(4) })
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => { this.setNetMode('lan'); })
        Text('外网')
          .fontSize(this.vp(8))
          .fontColor(this.netMode === 'remote' ? INK : DIM)
          .textAlign(TextAlign.Center)
          .height(this.px(20))
          .padding({ left: this.px(10), right: this.px(10) })
          .backgroundColor(this.netMode === 'remote' ? ACCENT : '#142126')
          .borderRadius(this.px(10))
          .margin({ left: this.px(4) })
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => { this.setNetMode('remote'); })
      }
      .width('100%')
      .margin({ top: this.px(10) })
      Text('解除绑定')
        .fontSize(this.vp(10))
        .fontColor(BAD)
        .textAlign(TextAlign.Center)
        .width('100%')
        .height(this.px(30))
        .margin({ top: this.px(9) })
        .backgroundColor('#282126')
        .border({ width: 0.5, color: '#38F1ABA8' })
        .borderRadius(this.px(15))
        .clickEffect({ level: ClickEffectLevel.LIGHT })
        .onClick(() => { this.unbind(); })
    }
      .width('100%')
      .padding({ left: this.px(40), right: this.px(40), top: this.px(34), bottom: this.px(30) })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .translate({ y: this.crownStretch })
    .focusable(true)
    .onDigitalCrown((event: CrownEvent) => {
      this.handleCrown(this.settingsScroller, event);
    })
  }

  private linkText(): string {
    if (this.netMode === 'lan') { return '内网 · 固定'; }
    if (this.netMode === 'remote') { return '外网 · 固定'; }
    return this.usingRemote ? '自动 · 当前外网' : '自动 · 当前内网';
  }

  private async refreshNotifyState(): Promise<void> {
    try {
      const enabled: boolean = await notificationManager.isNotificationEnabled();
      this.notifyEnabled = enabled ? '已开启' : '未开启';
    } catch (e) {
      this.notifyEnabled = '未知';
    }
  }

  private async requestNotify(): Promise<void> {
    try {
      await notificationManager.requestEnableNotification();
      this.toast('通知已设置');
    } catch (e) {
      this.toast('去系统设置里开通知');
    }
    this.refreshNotifyState();
  }

  private async clearHistory(): Promise<void> {
    this.histories.clear();
    try {
      const p = await preferences.getPreferences(this.ctx(), STORE);
      const all = await p.getAll();
      const keys: string[] = Object.keys(all);
      for (let i = 0; i < keys.length; i++) {
        if (keys[i].startsWith('hist_')) {
          await p.delete(keys[i]);
        }
      }
      await p.flush();
    } catch (e) {
    }
    this.toast('本地缓存已清');
  }

  @Builder
  DiagRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(this.vp(8))
        .fontColor(DIM)
        .width(this.px(42))
      Text(value === '' ? '—' : value)
        .fontSize(this.vp(8))
        .fontColor(TEXT)
        .layoutWeight(1)
        .textAlign(TextAlign.End)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: this.px(4), bottom: this.px(4) })
  }

  @Builder
  DiagnosticsView() {
    Scroll(this.diagScroller) {
      Column() {
        Text('诊断')
          .id('crown-diagnostics')
          .fontSize(this.vp(14))
          .fontWeight(FontWeight.Medium)
          .fontColor(TEXT)
          .focusable(true)
          .focusOnTouch(true)
          .defaultFocus(true)
          .onDigitalCrown((event: CrownEvent) => { this.handleCrown(this.diagScroller, event); })
        Column() {
          this.DiagRow('版本', '2.1.7')
          this.DiagRow('地址', this.server)
          this.DiagRow('链路', this.linkText())
          this.DiagRow('内网候选', this.lanUrl)
          this.DiagRow('状态', this.connected ? '在线' : '离线')
          this.DiagRow('轮询', Math.round(this.pollDelay / 1000) + ' 秒')
          this.DiagRow('失败', this.failCount + ' 次')
          this.DiagRow('事件', this.events.length + ' 条')
          this.DiagRow('会话', this.sessions.length + ' 个')
          this.DiagRow('待审批', this.pending.length + ' 个')
          this.DiagRow('通知', this.notifyEnabled)
          this.DiagRow('后台', this.bgState)
          this.DiagRow('图片失败', this.imgFail + ' 次')
          this.DiagRow('外网', this.remoteUrl)
          if (this.lastError !== '') {
            this.DiagRow('最近错误', this.lastError)
          }
        }
        .width('100%')
        .padding({ left: this.px(12), right: this.px(12), top: this.px(6), bottom: this.px(6) })
        .backgroundColor(CARD)
        .border({ width: 0.5, color: HAIRLINE })
        .borderRadius(this.px(14))
        .margin({ top: this.px(12) })
        Text('测试图片')
          .fontSize(this.vp(9))
          .fontColor(TEXT)
          .textAlign(TextAlign.Center)
          .width('100%')
          .height(this.px(26))
          .margin({ top: this.px(8) })
          .backgroundColor('#23343A')
          .border({ width: 0.5, color: HAIRLINE })
          .borderRadius(this.px(13))
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => { this.testImageLoad(); })
        if (this.testImgUrl !== '') {
          Image(this.testImgUrl)
            .width(this.px(96))
            .height(this.px(72))
            .objectFit(ImageFit.Cover)
            .borderRadius(this.px(10))
            .margin({ top: this.px(8) })
            .onError(() => { this.imgFail += 1; this.toast('测试图加载失败'); })
        }
        Text('测试通知')
          .fontSize(this.vp(9))
          .fontColor(TEXT)
          .textAlign(TextAlign.Center)
          .width('100%')
          .height(this.px(26))
          .margin({ top: this.px(8) })
          .backgroundColor('#23343A')
          .border({ width: 0.5, color: HAIRLINE })
          .borderRadius(this.px(13))
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => { this.testNotify(); })
        Text('开启通知')
          .fontSize(this.vp(9))
          .fontColor(TEXT)
          .textAlign(TextAlign.Center)
          .width('100%')
          .height(this.px(26))
          .margin({ top: this.px(8) })
          .backgroundColor('#23343A')
          .border({ width: 0.5, color: HAIRLINE })
          .borderRadius(this.px(13))
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => { this.requestNotify(); })
        Text('清空本地缓存')
          .fontSize(this.vp(9))
          .fontColor(BAD)
          .textAlign(TextAlign.Center)
          .width('100%')
          .height(this.px(28))
          .margin({ top: this.px(9) })
          .backgroundColor('#282126')
          .border({ width: 0.5, color: '#38F1ABA8' })
          .borderRadius(this.px(14))
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => { this.clearHistory(); })
      }
      .width('100%')
      .padding({ left: this.px(40), right: this.px(40), top: this.px(34), bottom: this.px(30) })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .translate({ y: this.crownStretch })
    .focusable(true)
    .onDigitalCrown((event: CrownEvent) => {
      this.handleCrown(this.diagScroller, event);
    })
  }

  @Builder
  SessionsView() {
    CrownMenu({ screenWidth: this.sw, title: '会话', subtitle: '本地 API · DSH · 表冠滚动选择',
      focusId: 'crown-sessions', items: this.pickerItems,
      onAction: (key: string) => { this.pickSession(key).catch(() => { this.toast('切换前保存失败，请重试'); }); } })
  }
}
