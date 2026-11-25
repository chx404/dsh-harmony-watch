import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import display from '@ohos.display';
import notificationManager from '@ohos.notificationManager';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import { BusinessError } from '@ohos.base';
import {
  cancelTurn, decideApproval, fetchEventDetail, fetchModels, fetchSessions, fetchState, newSession,
  pair, selectSession, sendPrompt, switchModel
} from '../common/Net';
import { DshEvent, DshImage, ModelOption, PendingInfo, ProviderOption, SessionInfo, SimpleResult, StateSnapshot } from '../common/Types';
import { reconcileEventFeed, visibleFeedEvents } from '../common/EventFeed';
import { swiperProgress, indicatorTranslation } from '../common/SwiperProgress';
import { RepoWelcome } from '../common/RepoWelcome';
import { APP_VERSION } from '../common/AppVersion';
import { ComputerProfile, ComputerProfileSnapshot, normalizeComputerServer, parseComputerProfiles,
  upsertComputerProfile, removeComputerProfile } from '../common/ComputerProfiles';
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
const COMPUTER_STORE = 'dsh_watch_computers';
const COMPUTER_KEY = 'profilesV1';
const PANEL_COUNT = 4;
const SESSION_PANEL = 1;
const CHAT_PANEL = 2;
// 黑白设计：白色为主要操作，状态用文字、符号和明暗区分。
const BG = '#080808';
const CARD = '#191919';
const TEXT = '#F4F4F4';
const DIM = '#B5B5B5';
const ACCENT = '#F5F5F5';
const WARN = '#DFDFDF';
const OK = '#F5F5F5';
const BAD = '#DDDDDD';
const HAIRLINE = '#24EBEBEB';
const INK = '#111111';

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
  @State showRepoWelcome: boolean = false;
  @State activeComputerId: string = '';
  @State activeComputerName: string = '';
  @State computerItems: CrownMenuItem[] = [];
  @State computerNameEdit: string = '';
  @State addressEdit: string = '';
  private computerProfiles: ComputerProfile[] = [];
  private computerStoreLoaded: boolean = false;
  private computerEpoch: number = 0;
  private computerDrafts: Map<string, string> = new Map<string, string>();
  private removeArmedUntil: number = 0;
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
  @State pageIndex: number = CHAT_PANEL;
  @State swiperInitialIndex: number = CHAT_PANEL;
  @State localBackRequest: number = 0;
  @State editingInput: boolean = false;
  @State crownStretch: number = 0;
  private viewHistory: ViewHistory = new ViewHistory();
  private lastBackAt: number = 0;
  private backPanStartX: number = 0;
  private crownOwner?: Scroller;
  private crownMotion: CrownElastic = new CrownElastic((stretch: number) => { this.crownStretch = stretch; });
  @State slidePos: number = CHAT_PANEL;
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
  private modelsScroller: Scroller = new Scroller();
  private settingsScroller: Scroller = new Scroller();
  private swiper: SwiperController = new SwiperController();
  private diagScroller: Scroller = new Scroller();
  private menuItems: CrownMenuItem[] = [
    { key: 'local', title: 'API 设置', caption: '模型、密钥与手机扫码', symbol: '◇' },
    { key: 'computers', title: '电脑', caption: '添加、切换与管理连接', symbol: '⊡' },
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
    { key: 'allow', label: '允许', color: '#0F0F0F', ring: '#BBBBBB' },
    { key: 'deny', label: '拒绝', color: '#EEEEEE', ring: '#1B1B1B' }
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
    this.showRepoWelcome = true;
    try {
      const p = await preferences.getPreferences(this.ctx(), STORE);
      this.showGuide = (await p.get('guideSeenV1', false)) !== true;
      this.showRepoWelcome = (await p.get('repoWelcomeVersion', '')) !== APP_VERSION;
      await this.restoreComputers(p);

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
      if (!this.showGuide && !this.showRepoWelcome) { this.ensureNotification(); }
    }
  }

  private async finishRepoWelcome(remember: boolean): Promise<void> {
    this.showRepoWelcome = false;
    if (!this.showGuide) { this.ensureNotification(); }
    if (!remember) { return; }
    try {
      const p = await preferences.getPreferences(this.ctx(), STORE);
      await p.put('repoWelcomeVersion', APP_VERSION);
      await p.flush();
    } catch (_) { this.toast('未保存此版本的引导设置'); }
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
      { key: 'new-dsh', title: '新建 DSH 会话', caption: this.activeComputerName || '先连接电脑', symbol: '+' },
      { key: 'computer', title: this.activeComputerName || '连接电脑', caption: '点按管理和切换电脑', symbol: '⊡' }
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
    if (!this.localController || this.changingSession || this.connecting) { return; }
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
      this.goPage(CHAT_PANEL); this.rememberChatKind();
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
      this.closeModels(); this.goPage(CHAT_PANEL); this.rememberChatKind();
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
      this.goPage(CHAT_PANEL); this.rememberChatKind();
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
    this.closePrompt(); this.goPage(CHAT_PANEL);
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
    if (key === 'computer') { this.switchView('computers'); return; }
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
  private chatTitle(): string { return this.chatKind === 'local' ? '✦ ' + this.localTitle : (this.title || this.activeComputerName || 'DSH Watch'); }
  private modelCaption(): string {
    if (this.chatKind === 'local') { return '模型 · ' + (this.localModel || '选择 API'); }
    return '模型 · ' + (this.selectionModel || '跟随默认') + (this.modelPending ? ' · 下轮生效' : '');
  }

  private async saveHistory(sessionId: string, events: DshEvent[]): Promise<void> {
    if (sessionId === '' || this.activeComputerId === '') { return; }
    const key: string = this.historyKey(sessionId);
    this.histories.set(key, events);
    try {
      const slim: DshEvent[] = events.slice(-12).map((ev: DshEvent) => {
        const copy: DshEvent = {
          seq: ev.seq, t: ev.t, sessionId: ev.sessionId, kind: ev.kind,
          text: (ev.text === undefined ? '' : ev.text).substring(0, 200)
        };
        return copy;
      });
      const p = await preferences.getPreferences(this.ctx(), STORE);
      await p.put(key, JSON.stringify(slim));
      await p.flush();
    } catch (e) {
    }
  }

  private historyKey(sessionId: string): string {
    // The migrated computer alone can read pre-upgrade history keys.
    return this.activeComputerId === 'legacy' ? 'hist_' + sessionId : 'pc_hist_' + this.activeComputerId + ':' + sessionId;
  }

  private async loadHistory(sessionId: string): Promise<DshEvent[]> {
    if (this.activeComputerId === '') { return []; }
    const key: string = this.historyKey(sessionId);
    const cached: DshEvent[] | undefined = this.histories.get(key);
    if (cached !== undefined) { return cached; }
    try {
      const p = await preferences.getPreferences(this.ctx(), STORE);
      const raw = await p.get(key, '');
      if (typeof raw === 'string' && raw !== '') {
        const list = JSON.parse(raw) as DshEvent[];
        if (Array.isArray(list)) {
          this.histories.set(key, list);
          return list;
        }
      }
    } catch (e) {
    }
    return [];
  }

  private async restoreComputers(legacy: preferences.Preferences): Promise<void> {
    try {
      const p = await preferences.getPreferences(this.ctx(), COMPUTER_STORE);
      const raw = await p.get(COMPUTER_KEY, '');
      if (typeof raw !== 'string') { throw new Error('电脑列表格式有误'); }
      let snapshot: ComputerProfileSnapshot = parseComputerProfiles(raw);
      if (raw === '') {
        const server = await legacy.get('server', '');
        const token = await legacy.get('token', '');
        if (typeof server === 'string' && server !== '' && typeof token === 'string' && token !== '') {
          const mode = await legacy.get('netMode', 'auto');
          const lan = await legacy.get('lan', '');
          const remote = await legacy.get('remote', '');
          snapshot = upsertComputerProfile(snapshot, { id: 'legacy', name: '原有电脑', server: server, token: token,
            mode: mode === 'lan' || mode === 'remote' ? mode : 'auto',
            lan: typeof lan === 'string' ? this.safeComputerAddress(lan) : '',
            remote: typeof remote === 'string' ? this.safeComputerAddress(remote) : '' });
          // Keep old keys intact for rollback. A present snapshot, even empty, suppresses reimport.
          await this.writeComputers(snapshot);
        }
      }
      this.computerProfiles = snapshot.profiles;
      this.computerStoreLoaded = true;
      const selected = this.findComputer(snapshot.selectedId);
      if (selected) {
        this.activateComputer(selected);
        this.switchView('main');
        this.startPolling();
      } else { this.updateComputers(); }
    } catch (_) { this.toast('电脑列表未能读取，未覆盖旧数据'); }
  }

  private safeComputerAddress(value: string): string {
    try { return normalizeComputerServer(value); } catch (_) { return ''; }
  }

  private findComputer(id: string): ComputerProfile | undefined {
    return this.computerProfiles.find((profile: ComputerProfile) => profile.id === id);
  }

  private async writeComputers(snapshot: ComputerProfileSnapshot): Promise<void> {
    const p = await preferences.getPreferences(this.ctx(), COMPUTER_STORE);
    try {
      await p.put(COMPUTER_KEY, JSON.stringify(snapshot));
      await p.flush();
    } catch (_) {
      try { await preferences.removePreferencesFromCache(this.ctx(), COMPUTER_STORE); } catch (_) {}
      throw new Error('电脑列表未保存');
    }
  }

  private updateComputers(): void {
    const items: CrownMenuItem[] = [{ key: 'add', title: '添加电脑', caption: '输入地址及 6 位配对码', symbol: '+' }];
    for (let i: number = 0; i < this.computerProfiles.length; i++) {
      const profile: ComputerProfile = this.computerProfiles[i];
      const active: boolean = this.activeComputerId === profile.id;
      items.push({ key: 'pc:' + profile.id, title: profile.name, caption: active ? '当前控制 · 点按进入聊天' : '点按切换 · ' + profile.server,
        symbol: active ? '✓' : '⊡' });
    }
    if (this.activeComputerId !== '') {
      items.push({ key: 'settings', title: '当前电脑设置', caption: '名称、网络与移除', symbol: '◇' });
    }
    this.computerItems = items;
  }

  private activateComputer(profile?: ComputerProfile): void {
    if (this.activeComputerId !== '') {
      this.computerDrafts.set(this.activeComputerId, this.chatKind === 'dsh' ? this.promptText : this.dshDraft);
    }
    this.computerEpoch++;
    this.requestGeneration++;
    this.stopPolling();
    this.busy = false;
    this.feedSessionId = ''; this.events = []; this.lastSeq = -1;
    this.sessions = []; this.sessionSource.set([]); this.sessionSig = ''; this.currentSessionId = '';
    this.pending = []; this.lastPendingCount = 0; this.lastApprovalId = ''; this.lastRunning = false;
    this.lastSaveAt = 0; this.title = ''; this.connected = false; this.status = 'offline';
    this.lastError = ''; this.failCount = 0; this.imgFail = 0; this.testImgUrl = '';
    this.expandedSeq = -1; this.expandedText = ''; this.localDeleteArmed = false;
    this.showPrompt = false; this.showModels = false; this.modelsLoading = false; this.modelPending = false;
    this.modelOptions = []; this.selectionModel = ''; this.selectionProvider = '';
    this.stopArmed = false; this.removeArmedUntil = 0;
    if (this.stopTimer >= 0) { clearTimeout(this.stopTimer); this.stopTimer = -1; }
    this.activeComputerId = profile?.id || '';
    this.activeComputerName = profile?.name || '';
    this.computerNameEdit = this.activeComputerName;
    this.primaryServer = profile?.server || '';
    this.token = profile?.token || '';
    this.lanUrl = profile?.lan || ''; this.remoteUrl = profile?.remote || '';
    this.lanEdit = this.lanUrl; this.remoteEdit = this.remoteUrl;
    this.netMode = profile?.mode || 'auto';
    this.server = this.netMode === 'remote' && this.remoteUrl !== '' ? this.remoteUrl :
      (this.netMode === 'lan' && this.lanUrl !== '' ? this.lanUrl : this.primaryServer);
    this.usingRemote = this.server !== '' && this.server === this.remoteUrl;
    this.dshDraft = this.computerDrafts.get(this.activeComputerId) || '';
    if (this.chatKind === 'dsh') { this.promptText = this.dshDraft; }
    this.updateComputers(); this.updatePicker();
  }

  private async prepareComputerControl(): Promise<void> {
    if (this.localUnsaved) { throw new Error('请先保存本地回复'); }
    await this.flushLocalDraft();
  }

  private enterComputerChat(): void {
    if (this.chatKind !== 'local') { return; }
    this.localUiEpoch++; this.localController?.cancel();
    this.chatKind = 'dsh'; this.promptText = this.dshDraft;
    this.stopArmed = false; this.showPrompt = false; this.showModels = false;
    this.updatePicker(); this.rememberChatKind();
  }

  private async switchComputer(id: string): Promise<void> {
    if (this.connecting || this.changingSession || !this.computerStoreLoaded) { return; }
    const profile = this.findComputer(id);
    if (!profile) { return; }
    this.connecting = true;
    try {
      await this.prepareComputerControl();
      if (id !== this.activeComputerId) {
        await this.writeComputers({ profiles: this.computerProfiles, selectedId: id });
        this.activateComputer(profile);
      }
      this.enterComputerChat();
      this.switchView('main');
      this.toast('当前电脑：' + profile.name);
    } catch (_) { this.toast('未切换，请先保存本地回复或检查存储'); }
    finally { this.connecting = false; this.startPolling(); }
  }

  private computerAction(key: string): void {
    if (this.connecting || this.changingSession) { return; }
    this.removeArmedUntil = 0;
    if (key === 'add') {
      this.addressEdit = ''; this.computerNameEdit = ''; this.code = '';
      this.switchView('connect'); return;
    }
    if (key === 'settings') {
      this.computerNameEdit = this.activeComputerName; this.lanEdit = this.lanUrl; this.remoteEdit = this.remoteUrl;
      this.switchView('settings'); return;
    }
    if (key.startsWith('pc:')) { this.switchComputer(key.substring(3)); }
  }

  private startPolling(): void {
    this.stopPolling();
    this.pollDelay = 2000;
    if (this.token === '' || this.server === '') { return; }
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
      const epoch: number = this.computerEpoch;
      fetchState(target, this.token).then((snapshot: StateSnapshot) => {
        if (snapshot.ok === true && epoch === this.computerEpoch && !this.connecting && this.usingRemote && target === this.lanUrl) {
          this.requestGeneration++;
          this.server = target;
          this.usingRemote = false;
          this.connected = false;
          this.poll();
        }
      }).catch(() => {});
    }, 30000);
  }

  private async poll(): Promise<void> {
    if (this.token === '' || this.server === '') {
      return;
    }
    if (this.busy || this.changingSession || this.connecting) {
      this.schedulePoll();
      return;
    }
    const generation: number = this.requestGeneration;
    const epoch: number = this.computerEpoch;
    this.busy = true;
    try {
      const snap: StateSnapshot = await fetchState(this.server, this.token);
      if (generation !== this.requestGeneration || this.changingSession || this.connecting) { return; }
      if (!snap || snap.ok !== true) { throw new Error('当前电脑未通过连接校验'); }
      this.apply(snap);
      this.failCount = 0;
      this.pollDelay = 2000;
      this.lastError = '';
    } catch (e) {
      if (generation === this.requestGeneration && !this.connecting) {
        this.connected = false;
        this.status = 'offline';
        this.lastError = this.errText(e);
        this.failCount += 1;
        this.pollDelay = Math.min(30000, 2000 * Math.pow(2, Math.min(4, this.failCount - 1)));
        this.failover();
      }
    } finally {
      if (epoch === this.computerEpoch) { this.busy = false; this.schedulePoll(); }
    }
  }

  private async applyServer(mode: string = this.netMode): Promise<void> {
    if (this.connecting || this.changingSession || !this.computerStoreLoaded) { return; }
    const current = this.findComputer(this.activeComputerId);
    if (!current) { return; }
    this.connecting = true;
    try {
      const lan: string = this.lanEdit.trim() === '' ? '' : normalizeComputerServer(this.lanEdit);
      const remote: string = this.remoteEdit.trim() === '' ? '' : normalizeComputerServer(this.remoteEdit);
      if ((mode === 'remote' && remote === '') || (mode === 'lan' && lan === '')) {
        this.toast('请先填写对应地址'); return;
      }
      const next = upsertComputerProfile({ profiles: this.computerProfiles, selectedId: current.id },
        { id: current.id, server: current.server, token: current.token, name: this.computerNameEdit.trim() || current.name,
          lan: lan, remote: remote, mode: mode });
      await this.writeComputers(next);
      this.computerProfiles = next.profiles;
      const updated = this.findComputer(next.selectedId);
      if (updated) { this.activateComputer(updated); }
      this.toast('当前电脑设置已保存');
    } catch (_) { this.toast('设置未保存，请检查地址及存储'); }
    finally { this.connecting = false; this.startPolling(); }
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
      const candidate: string = this.safeComputerAddress(snap.remote);
      if (candidate !== '') { this.remoteUrl = candidate; }
    }
    if (snap.lan !== undefined && snap.lan.length > 0) {
      const candidate: string = this.safeComputerAddress(snap.lan[0]);
      if (candidate !== '') { this.lanUrl = candidate; }
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
    if (newApproval && this.view !== 'approval' && !this.connecting && this.view !== 'computers' && this.view !== 'settings' && this.view !== 'connect' && this.view !== 'prompt' && this.view !== 'local' && this.chatKind !== 'local') {
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
    if (this.connecting || this.changingSession || !this.computerStoreLoaded || this.activeComputerId === '') { return; }
    if (Date.now() >= this.removeArmedUntil) {
      this.removeArmedUntil = Date.now() + 3500; this.toast('再点一次，移除当前电脑'); return;
    }
    this.removeArmedUntil = 0;
    this.connecting = true;
    try {
      const id: string = this.activeComputerId;
      const next = removeComputerProfile({ profiles: this.computerProfiles, selectedId: id }, id);
      await this.writeComputers(next);
      this.computerProfiles = next.profiles;
      this.activateComputer(); this.computerDrafts.delete(id);
      this.backScene();
      this.toast('已移除本表配对，不影响电脑');
    } catch (_) { this.toast('未移除，请稍后重试'); }
    finally { this.connecting = false; this.startPolling(); }
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
        const epoch: number = this.computerEpoch;
        const text: string = await fetchEventDetail(this.server, this.token, ev.sessionId, ev.seq, ev.t);
        if (epoch === this.computerEpoch && this.expandedSeq === ev.seq) { this.expandedText = text; }
      } catch (e) {
      }
    }
  }

  private async openModels(): Promise<void> {
    this.resetChatChrome();
    if (this.showModels) {
      return;
    }
    const epoch: number = this.computerEpoch;
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
      if (epoch === this.computerEpoch && catalog.ok === true) { this.modelOptions = catalog.providers; }
    } catch (e) {
      if (epoch === this.computerEpoch) { this.toast('模型列表读取失败'); }
    } finally {
      if (epoch === this.computerEpoch) { this.modelsLoading = false; }
    }
  }

  private async doSwitchModel(provider: string, model: string): Promise<void> {
    if (!this.connected || this.connecting) { return; }
    const epoch: number = this.computerEpoch;
    try {
      const r: SimpleResult = await switchModel(this.server, this.token, this.feedSessionId, provider, model);
      if (epoch !== this.computerEpoch || this.connecting) { return; }
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
      if (epoch !== this.computerEpoch || this.connecting) { return; }      this.toast('切换失败');
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
    if (this.chatKind === 'dsh' && !this.connected) { this.toast('当前电脑未在线'); return; }
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
    if (v === 'main') { this.goPage(CHAT_PANEL); return; }
    this.recordLocation({ view: v, page: this.pageIndex });
    // 再创建 Swiper 时保留其实际来源页，不重置到固定的中间页。
    this.swiperInitialIndex = this.pageIndex;
    animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.view = v; });
    if (v === 'diagnostics') { this.refreshNotifyState(); }
    this.focusLocation();
  }

  private goPage(index: number): void {
    if (this.view === 'main') {
      this.resetChatChrome(); this.resetCrown(); this.editingInput = false;
    } else { this.recordLocation({ view: 'main', page: index }); }
    const recreate: boolean = this.view !== 'main';
    if (recreate) { this.swiperInitialIndex = index; this.slidePos = index; }
    this.pageIndex = index; this.view = 'main';
    if (!recreate) { try { this.swiper.changeIndex(index, true); } catch (e) { } }
    if (index === SESSION_PANEL) { this.refreshSessions(); }
    this.focusLocation();
  }

  private panelFocus(index: number): string {
    if (index === 0) { return 'crown-menu'; }
    if (index === SESSION_PANEL) { return 'crown-sessions'; }
    return index === CHAT_PANEL ? 'crown-main' : 'crown-quick';
  }

  private focusLocation(): void {
    setTimeout(() => {
      const id: string = this.view === 'main'
        ? this.panelFocus(this.pageIndex)
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
    else { this.restoreLocation({ view: this.token !== '' || this.chatKind === 'local' ? 'main' : 'connect', page: CHAT_PANEL }); }
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
    if (this.showRepoWelcome) { this.finishRepoWelcome(false); return true; }
    if (this.showGuide) { this.animateReturn(() => { this.finishGuide(); }); return true; }
    if (this.view === 'local') { this.localBackRequest++; return true; }
    if (this.connecting) { return true; }
    this.removeArmedUntil = 0;
    if (this.viewHistory.size() > 0) { this.backScene(); return true; }
    if (this.view !== 'main' && this.view !== 'connect') { this.backScene(); return true; }
    return false; // 只有真正根界面才允许系统退出 App。
  }

  private isBackSurface(): boolean {
    return this.view !== 'main' || this.showPrompt || this.showModels || this.showGuide || this.showRepoWelcome;
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
    return this.view === 'main' && this.pageIndex === CHAT_PANEL && !this.showPrompt && !this.showModels &&
      !this.showGuide && !this.showRepoWelcome && this.pageVisible && !this.returnAnimating;
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
    if (this.connecting || this.changingSession) { return; }
    if (!this.computerStoreLoaded) { this.toast('电脑列表未载入，请重开应用'); return; }
    let base: string;
    try { base = normalizeComputerServer(this.addressEdit); }
    catch (_) { this.toast('请输入有效的电脑地址'); return; }
    const code: string = this.code.trim();
    if (!/^[0-9]{6}$/.test(code)) { this.toast('请输入 6 位配对码'); return; }
    const name: string = this.computerNameEdit.trim();
    const id: string = 'pc-' + Date.now().toString(36) + '-' + Math.random().toString(36).substring(2, 10);
    this.connecting = true;
    try {
      await this.prepareComputerControl();
      // Preflight limit/validation before a successful pairing rotates the computer's code.
      const before: ComputerProfileSnapshot = { profiles: this.computerProfiles, selectedId: this.activeComputerId };
      const sameAddress = this.computerProfiles.find((profile: ComputerProfile) => profile.server === base);
      upsertComputerProfile(before, { id: id, name: name || base.substring(0, 120), server: base,
        token: sameAddress?.token || 'pending' });
      const result: SimpleResult = await pair(base, code);
      if (result.ok !== true || !result.token) { this.toast(result.error || '配对失败'); return; }
      const lan: string = result.addresses && result.addresses.length > 0 ? this.safeComputerAddress(result.addresses[0]) : '';
      const label: string = (name || (typeof result.host === 'string' ? result.host.trim() : '') || base).substring(0, 120);
      const next = upsertComputerProfile(before, { id: id, name: label, server: base, token: result.token,
        lan: lan, remote: '', mode: 'auto' });
      await this.writeComputers(next);
      this.computerProfiles = next.profiles;
      this.code = '';
      const profile = this.findComputer(next.selectedId);
      if (profile) { this.activateComputer(profile); }
      this.enterComputerChat();
      this.switchView('main');
      this.toast('已配对并保存 · ' + label);
    } catch (_) { this.toast('未保存电脑；请检查存储或电脑数量（最多 12 台）'); }
    finally { this.connecting = false; this.startPolling(); }
  }

  private async doSend(mode: string): Promise<void> {
    if (this.chatKind === 'local') { await this.sendLocal(); return; }
    const t: string = this.promptText.trim();
    if (t === '' || this.token === '') {
      return;
    }
    if (!this.connected || this.connecting) { return; }
    const epoch: number = this.computerEpoch;
    try {
      const r: SimpleResult = await sendPrompt(this.server, this.token, t, mode);
      if (epoch !== this.computerEpoch || this.connecting) { return; }
      if (r.ok === true) {
        this.promptText = '';
        this.closePrompt();
        this.switchView('main');
        this.toast(mode === 'steer' ? '已插话' : '已排队');
      } else {
        this.toast(r.error === undefined ? '发送失败' : r.error);
      }
    } catch (e) {
      if (epoch !== this.computerEpoch || this.connecting) { return; }      this.toast('发送失败');
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
    if (!this.connected || this.connecting) { return; }
    const epoch: number = this.computerEpoch;
    try {
      const r: SimpleResult = await sendPrompt(this.server, this.token, text, 'followup');
      if (epoch !== this.computerEpoch || this.connecting) { return; }
      if (r.ok === true) {
        this.goPage(CHAT_PANEL);
        this.toast('已发送');
      } else {
        this.toast(r.error === undefined ? '发送失败' : r.error);
      }
    } catch (e) {
      if (epoch !== this.computerEpoch || this.connecting) { return; }      this.toast('发送失败');
    }
  }

  private async doDecide(decision: string): Promise<void> {
    if (this.pending.length === 0) {
      return;
    }
    const id: string = this.pending[0].id;
    if (!this.connected || this.connecting) { return; }
    const epoch: number = this.computerEpoch;
    try {
      const r: SimpleResult = await decideApproval(this.server, this.token, id, decision);
      if (epoch !== this.computerEpoch || this.connecting) { return; }
      if (r.ok === true) {
        this.pending = [];
        this.backScene();
        this.toast(decision === 'allow' ? '已允许' : '已拒绝');
      } else {
        this.toast('提交失败');
      }
    } catch (e) {
      if (epoch !== this.computerEpoch || this.connecting) { return; }      this.toast('提交失败');
    }
  }

  private async doNew(): Promise<void> {
    if (this.chatKind === 'local') { await this.enterLocal('', true); return; }
    if (this.token === '') { this.toast('请先连接 DSH 宿主'); return; }
    if (this.changingSession || this.connecting) { return; }
    if (!this.connected) { this.toast('当前电脑未在线'); return; }
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

  private async refreshSessions(): Promise<void> {
    if (this.token === '' || this.connecting) {
      return;
    }
    try {
      const epoch: number = this.computerEpoch;
      const r = await fetchSessions(this.server, this.token);
      if (epoch === this.computerEpoch && r.sessions) {
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
    if (this.changingSession || this.connecting) { return; }
    if (!this.connected) { this.toast('当前电脑未在线'); return; }
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
    if (!this.connected || this.connecting) { return; }
    const epoch: number = this.computerEpoch;
    try {
      await cancelTurn(this.server, this.token);
      if (epoch === this.computerEpoch) { this.toast('已请求停止'); }
    } catch (e) {
      if (epoch === this.computerEpoch) { this.toast('请求失败'); }
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
      return '#B0B0B0';
    }
    if (kind === 'assistant') {
      return TEXT;
    }
    if (kind === 'tool') {
      return '#CCCCCC';
    }
    if (kind === 'tool-result') {
      return '#C4C4C4';
    }
    if (kind === 'approval') {
      return WARN;
    }
    if (kind === 'turn' || kind === 'status') {
      return DIM;
    }
    return '#A5A5A5';
  }

  // 以下仅为视觉与布局，网络、配对、消息处理沿用原实现。
  private eventSurface(ev: DshEvent): string {
    if (ev.kind === 'user') {
      return '#262626';
    }
    if (ev.kind === 'assistant') {
      return '#1E1E1E';
    }
    return '#141414';
  }

  private pagePos(): number {
    if (this.view === 'main') { return this.pageIndex; }
    return -1;
  }

  @Builder
  PageDots() {
    Stack() {
      Row() {
        ForEach([0, 1, 2, 3], (dot: number) => {
          Text('').width(this.px(4)).height(this.px(4))
            .backgroundColor('#626262').borderRadius(this.px(2))
            .margin({ left: this.px(3), right: this.px(3) })
        }, (dot: number) => dot.toString())
      }.height(this.px(4))
      Text('').width(this.px(10)).height(this.px(4)).backgroundColor('#FFFFFF')
        .borderRadius(this.px(2)).position({ x: this.px(2), y: 0 })
        .translate({ x: indicatorTranslation(this.slidePos, this.px(10)), y: 0 })
    }.width(this.px(44)).height(this.px(4))
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
      } else if (this.showRepoWelcome) {
        RepoWelcome({ screenWidth: this.sw, screenHeight: this.sh,
          onDismiss: () => { this.finishRepoWelcome(true); }, onSkip: () => { this.finishRepoWelcome(false); } })
      } else if (this.showGuide) {
        QuickGuide({ screenWidth: this.sw, screenHeight: this.sh,
          onFinish: () => { this.finishGuide(); } })
      } else if (this.view === 'local') {
        LocalChat({ screenWidth: this.sw, screenHeight: this.sh,
          settingsOnly: true,
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
      } else if (this.view === 'computers') {
        this.ComputersView()
      } else if (this.view === 'settings') {
        this.SettingsView()
      } else if (this.view === 'diagnostics') {
        this.DiagnosticsView()
      } else {
        Column() {
          Swiper(this.swiper) {
            this.MenuView()
            this.SessionsView()
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
            this.slidePos = swiperProgress(index, position, PANEL_COUNT);
          })
          .onAppear(() => {
            // 返回子页面来源时按历史重建，不把菜单/快捷强制重置成聊天页。
            this.pageIndex = this.swiperInitialIndex;
            this.slidePos = this.swiperInitialIndex;
          })
          .onAnimationEnd((i: number, _extra: SwiperAnimationEvent) => {
            // 缓存页出现时不能抢焦点；翻页完成后把表冠明确交给当前页。
            if (this.view !== 'main' || this.showGuide || this.showRepoWelcome) { return; }
            const focus: string = this.panelFocus(i);
            try { this.getUIContext().getFocusController().requestFocus(focus); } catch (e) { }
          })
          .onChange((i: number) => {
            this.resetChatChrome();
            this.pageIndex = i;
            // 选中项事件不驱动白条，不能提前抢走尚未结束的原生动画。
            const focus: string = this.panelFocus(i);
            try { this.getUIContext().getFocusController().requestFocus(focus); } catch (e) { }
            if (i === SESSION_PANEL) {
              this.localDeleteArmed = false;
              this.updatePicker();
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
      if (this.message !== '' && this.bootReady && !this.showGuide && !this.showRepoWelcome) {
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
    .linearGradient({ angle: 150, colors: [['#191919', 0], ['#101010', 0.32], [BG, 0.76], ['#101010', 1]] })
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
        TextInput({ placeholder: '电脑地址', text: this.addressEdit })
          .fontSize(this.vp(10))
          .placeholderFont({ size: this.vp(9) })
          .fontColor(TEXT)
          .placeholderColor(DIM)
          .height(this.px(32))
          .backgroundColor(CARD)
          .border({ width: 0.5, color: HAIRLINE })
          .borderRadius(this.px(12))
          .onEditChange((editing: boolean) => { this.editingInput = editing; })
          .onChange((v: string) => { this.addressEdit = v; })
        TextInput({ placeholder: '名称（可选）', text: this.computerNameEdit })
          .fontSize(this.vp(10)).fontColor(TEXT).placeholderColor(DIM)
          .height(this.px(32)).width('100%').margin({ top: this.px(7) }).backgroundColor(CARD)
          .border({ width: 0.5, color: HAIRLINE }).borderRadius(this.px(12)).maxLength(40)
          .onEditChange((editing: boolean) => { this.editingInput = editing; })
          .onChange((v: string) => { this.computerNameEdit = v; })
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
        Button(this.connecting ? '配对中…' : '配对并保存', { type: ButtonType.Capsule })
          .fontSize(this.vp(10)).fontColor(INK).backgroundColor(ACCENT)
          .height(this.px(36)).width('100%').margin({ top: this.px(10) })
          .enabled(!this.connecting).onClick(() => { this.doConnect(); })
        if (this.computerItems.length > 1 && this.activeComputerId === '') {
          Button('已保存的电脑', { type: ButtonType.Capsule })
            .fontSize(this.vp(10)).fontColor(TEXT).backgroundColor(CARD)
            .height(this.px(36)).width('100%').margin({ top: this.px(8) })
            .enabled(!this.connecting).onClick(() => { this.switchView('computers'); })
        }
        Text('独立 API 对话')
          .fontSize(this.vp(10))
          .fontColor(ACCENT)
          .textAlign(TextAlign.Center)
          .height(this.px(34))
          .width('100%')
          .backgroundColor('#191919')
          .borderRadius(this.px(17))
          .margin({ top: this.px(10) })
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => { if (!this.connecting) { this.enterLocal(); } })
        Text('先进入工作台')
          .fontSize(this.vp(8))
          .fontColor(DIM)
          .margin({ top: this.px(10) })
          .padding({ top: this.px(4), bottom: this.px(4), left: this.px(10), right: this.px(10) })
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => { if (!this.connecting) { this.switchView('main'); } })

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
          .fontColor(ev.kind === 'user' ? '#111111' : TEXT)
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
            .fontColor(ev.kind === 'user' ? '#414141' : DIM)
            .margin({ top: this.px(2) })
        }
      }
    }
    .alignItems(ev.kind === 'user' ? HorizontalAlign.End : HorizontalAlign.Start)
    .padding({ left: this.px(12), right: this.px(12), top: this.px(8), bottom: this.px(8) })
    .backgroundColor(ev.kind === 'user' ? '#EEEEEE' : '#1D1D1D')
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
                  .backgroundColor('#121212')
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
          Column({ space: this.px(1) }) {
            Text(this.chatTitle())
              .fontSize(this.vp(10))
              .fontWeight(FontWeight.Medium)
              .fontColor(TEXT)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            if (this.chatKind === 'dsh') {
              Text(this.activeComputerName ? this.activeComputerName + ' ›' : '选择电脑 ›')
                .fontSize(this.vp(7)).fontColor(DIM).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
            }
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Circle({ width: this.vp(5), height: this.vp(5) })
            .fill(this.chatKind === 'local' ? (this.localBusy ? WARN : ACCENT) : (this.connected ? (this.status === 'running' ? WARN : OK) : DIM))
            .margin({ left: this.px(7) })
        }
        .width('100%')
        .height(this.px(26))
        .padding({ left: this.px(57), right: this.px(57) })
        .accessibilityText(this.chatKind === 'dsh' ? this.chatTitle() + '，管理和切换电脑' : this.chatTitle())
        .onClick(() => { if (this.chatKind === 'dsh') { this.switchView('computers'); } })
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
            .backgroundColor('#272727')
            .border({ width: 0.5, color: '#40DFDFDF' })
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
          .backgroundColor('#181818')
          .border({ width: 0.5, color: '#3C3C3C' })
          .borderRadius(this.px(14))
          .accessibilityText('编辑指令')
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => { this.openPrompt(); })
          Text(this.stopArmed ? '确认' : '■')
            .fontSize(this.stopArmed ? this.vp(7) : this.vp(8))
            .fontColor(this.stopArmed ? INK : BAD)
            .textAlign(TextAlign.Center)
            .width(this.stopArmed ? this.px(34) : this.px(28))
            .height(this.px(28))
            .backgroundColor(this.stopArmed ? '#E5E5E5' : '#232323')
            .border({ width: 0.5, color: this.stopArmed ? '#FAFAFA' : '#46DDDDDD' })
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
            .textAlign(TextAlign.Center).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: this.px(140) })
            .backgroundColor('#14E9E9E9')
            .border({ width: 0.5, color: '#2AEBEBEB' })
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
            .backgroundColor('#99060606')
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
              .backgroundColor('#151515')
              .border({ width: 0.5, color: '#35D7D7D7' })
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
                .backgroundColor('#313131')
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
          .linearGradient({ angle: 145, colors: [['#F33C3C3C', 0], ['#F21D1D1D', 1]] })
          .backgroundBlurStyle(BlurStyle.Thin, { colorMode: ThemeColorMode.DARK })
          .borderRadius(this.px(22))
          .border({ width: 0.5, color: '#66DDDDDD' })
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
            .backgroundColor('#99060606')
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
                .height(this.px(28)).width('100%').backgroundColor('#191919').borderRadius(this.px(14))
                .margin({ top: this.px(3) })
                .onClick(() => { this.closeModels(); this.openLocalSettings(); })
            }
          }
          .width(this.px(176))
          .height(this.px(150))
          .padding({ left: this.px(14), right: this.px(14), top: this.px(10), bottom: this.px(10) })
          .linearGradient({ angle: 145, colors: [['#F33C3C3C', 0], ['#F21D1D1D', 1]] })
          .borderRadius(this.px(20))
          .border({ width: 0.5, color: '#66DDDDDD' })
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
            .backgroundColor(a.key === 'allow' ? ACCENT : '#232323')
            .border({ width: 0.5, color: a.key === 'allow' ? '#66F5F5F5' : '#38DDDDDD' })
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
        if (key === 'local-chat') { this.enterLocal(); }
        else if (key === 'local') { this.openLocalSettings(); }
        else if (key === 'guide') { this.swiperInitialIndex = this.pageIndex; this.showGuide = true; }
        else { this.switchView(key); }
      } })
  }

  @Builder
  ComputersView() {
    CrownMenu({ screenWidth: this.sw, title: '我的电脑', subtitle: '点按切换 · 各自保存连接',
      focusId: 'crown-computers', items: this.computerItems,
      onAction: (key: string) => { this.computerAction(key); } })
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
        TextInput({ placeholder: '电脑名称', text: this.computerNameEdit })
          .fontSize(this.vp(10)).fontColor(TEXT).placeholderColor(DIM).width('100%').height(this.px(32))
          .backgroundColor(BG).borderRadius(this.px(9)).maxLength(40)
          .onEditChange((editing: boolean) => { this.editingInput = editing; })
          .onChange((value: string) => { this.computerNameEdit = value; })
        Text('内网地址').margin({ top: this.px(8) })
          .fontSize(this.vp(7))
          .fontColor(DIM)
        TextInput({ placeholder: '192.168.x.x:8765', text: this.lanEdit })
          .fontSize(this.vp(8))
          .placeholderFont({ size: this.vp(7) })
          .fontColor(TEXT)
          .placeholderColor(DIM)
          .height(this.px(24))
          .width('100%')
          .backgroundColor('#151515')
          .border({ width: 0.5, color: '#35D7D7D7' })
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
          .backgroundColor('#151515')
          .border({ width: 0.5, color: '#35D7D7D7' })
          .borderRadius(this.px(9))
          .margin({ top: this.px(4) })
          .onEditChange((editing: boolean) => { this.editingInput = editing; })
          .onChange((v: string) => { this.remoteEdit = v; })
        Button('保存当前电脑设置', { type: ButtonType.Capsule })
          .fontSize(this.vp(9)).fontColor(INK).backgroundColor(ACCENT).width('100%')
          .height(this.px(34)).margin({ top: this.px(8) }).enabled(!this.connecting)
          .onClick(() => { this.applyServer(); })
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
          .backgroundColor(this.netMode === 'auto' ? ACCENT : '#191919')
          .borderRadius(this.px(10))
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => { this.applyServer('auto'); })
        Text('内网')
          .fontSize(this.vp(8))
          .fontColor(this.netMode === 'lan' ? INK : DIM)
          .textAlign(TextAlign.Center)
          .height(this.px(20))
          .padding({ left: this.px(10), right: this.px(10) })
          .backgroundColor(this.netMode === 'lan' ? ACCENT : '#191919')
          .borderRadius(this.px(10))
          .margin({ left: this.px(4) })
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => { this.applyServer('lan'); })
        Text('外网')
          .fontSize(this.vp(8))
          .fontColor(this.netMode === 'remote' ? INK : DIM)
          .textAlign(TextAlign.Center)
          .height(this.px(20))
          .padding({ left: this.px(10), right: this.px(10) })
          .backgroundColor(this.netMode === 'remote' ? ACCENT : '#191919')
          .borderRadius(this.px(10))
          .margin({ left: this.px(4) })
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => { this.applyServer('remote'); })
      }
      .width('100%')
      .margin({ top: this.px(10) })
      Text('移除当前电脑')
        .fontSize(this.vp(10))
        .fontColor(BAD)
        .textAlign(TextAlign.Center)
        .width('100%')
        .height(this.px(30))
        .margin({ top: this.px(9) })
        .backgroundColor('#232323')
        .border({ width: 0.5, color: '#38DDDDDD' })
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
        if (keys[i].startsWith('hist_') || keys[i].startsWith('pc_hist_')) {
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
          this.DiagRow('版本', APP_VERSION)
          this.DiagRow('电脑', this.activeComputerName)
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
          .backgroundColor('#313131')
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
          .backgroundColor('#313131')
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
          .backgroundColor('#313131')
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
          .backgroundColor('#232323')
          .border({ width: 0.5, color: '#38DDDDDD' })
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
    CrownMenu({ screenWidth: this.sw, title: '会话', subtitle: this.activeComputerName ? '本地 API · ' + this.activeComputerName.substring(0, 12) : '本地 API · DSH',
      focusId: 'crown-sessions', items: this.pickerItems,
      onAction: (key: string) => { this.pickSession(key).catch(() => { this.toast('切换前保存失败，请重试'); }); } })
  }
}
