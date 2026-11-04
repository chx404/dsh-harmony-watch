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
  private menuScroller: Scroller = new Scroller();
  private diagScroller: Scroller = new Scroller();
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
    this.restore();
  }

  onPageShow(): void {
    this.pageVisible = true;
    this.cancelDelay();
  }

  onPageHide(): void {
    this.pageVisible = false;
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
      this.scrollToBottom();
      const now: number = Date.now();
      if (now - this.lastSaveAt > 3000) {
        this.lastSaveAt = now;
        this.saveHistory(this.feedSessionId, this.events);
      }
    }
    const pend: PendingInfo[] = snap.pending ? snap.pending : [];
    this.pending = pend;
    if (pend.length > 0 && this.view !== 'approval' && this.view !== 'prompt') {
      this.switchView('approval');
    }
    if (pend.length === 0 && this.view === 'approval') {
      this.switchView('main');
    }
    const running: boolean = this.status === 'running';
    this.notifyTransitions(this.lastRunning, running, pend.length);
    this.lastRunning = running;
    this.lastPendingCount = pend.length;
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
      try { this.getUIContext().getFocusController().requestFocus('crown-main'); } catch (e) { }
    }, 240);
  }

  private openPrompt(): void {
    animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
      this.showPrompt = true;
    });
  }

  private closePrompt(): void {
    animateTo({ duration: 200, curve: Curve.EaseIn }, () => {
      this.showPrompt = false;
    });
  }

  private switchView(v: string): void {
    if (v === 'menu') {
      this.goPage(0);
      return;
    }
    if (v === 'main') {
      this.goPage(1);
      return;
    }
    animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
      this.view = v;
    });
    if (v === 'diagnostics') {
      this.refreshNotifyState();
    }
    setTimeout(() => {
      try {
        this.getUIContext().getFocusController().requestFocus('crown-' + v);
      } catch (e) {
      }
    }, 120);
  }

  private goPage(index: number): void {
    this.pageIndex = index;
    this.view = 'main';
    try {
      this.swiper.changeIndex(index, true);
    } catch (e) {
    }
    if (index === 2) {
      this.refreshSessions();
    }
    setTimeout(() => {
      try {
        const id: string = index === 0 ? 'crown-menu' : (index === 2 ? 'crown-sessions' : 'crown-main');
        this.getUIContext().getFocusController().requestFocus(id);
      } catch (e) {
      }
    }, 160);
  }

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

  private handleCrown(target: Scroller, event: CrownEvent): void {
    if (event.action !== CrownAction.UPDATE) {
      return;
    }
    try {
      target.scrollBy(0, -event.degree * 2);
    } catch (e) {
    }
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
        this.switchView('main');
        this.toast(decision === 'allow' ? '已允许' : '已拒绝');
      } else {
        this.toast('提交失败');
      }
    } catch (e) {
      this.toast('提交失败');
    }
  }

  private async doNew(): Promise<void> {
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
    }
  }

  private async doSelect(id: string): Promise<void> {
    if (this.changingSession) { return; }
    this.changingSession = true;
    this.requestGeneration += 1;
    try {
      const r: SimpleResult = await selectSession(this.server, this.token, id);
      if (r.ok === true) {
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
          .index(1)
          .indicator(false)
          .loop(false)
          .cachedCount(1)
          .onContentDidScroll((_selectedIndex: number, index: number, position: number, _mainAxisLength: number) => {
            // 原生逐帧位置覆盖拖动、松手惯性、取消回弹和程序切页。
            // 不依赖 selectedIndex，避免选中页变化或同帧多页回调造成反向/跳变。
            this.slidePos = swiperProgress(index, position, 3);
          })
          .onAppear(() => {
            // Swiper 离开主界面后会被销毁；重建的初始页是 .index(1)。
            this.pageIndex = 1;
            this.slidePos = 1;
          })
          .onChange((i: number) => {
            this.pageIndex = i;
            // 选中项事件不驱动白条，不能提前抢走尚未结束的原生动画。
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
  }

  @Builder
  ConnectView() {
    Scroll() {
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
          .onChange((v: string) => { this.code = v; })
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
      Column() {
        Row() {
          Text(this.title === '' ? 'DSH Watch' : this.title)
            .id('crown-main')
            .fontSize(this.vp(10))
            .fontWeight(FontWeight.Medium)
            .fontColor(TEXT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            .focusable(true)
            .focusOnTouch(true)
            .defaultFocus(true)
            .onDigitalCrown((event: CrownEvent) => {
              this.handleCrown(this.scroller, event);
            })
          Circle({ width: this.vp(5), height: this.vp(5) })
            .fill(this.connected ? (this.status === 'running' ? WARN : OK) : DIM)
            .margin({ left: this.px(7) })
        }
        .width('100%')
        .height(this.px(26))
        .padding({ left: this.px(44), right: this.px(44) })
        .margin({ bottom: this.px(3) })

        List({ scroller: this.scroller }) {
          if (visibleFeedEvents(this.events).length === 0) {
            ListItem() {
              Column() {
                Text(this.connected ? '一切就绪' : '正在重连')
                  .fontSize(this.vp(13))
                  .fontWeight(FontWeight.Medium)
                  .fontColor(TEXT)
                Text(this.connected ? '从腕上发起下一步' : '等待设备重新上线')
                  .fontSize(this.vp(8))
                  .fontColor(DIM)
                  .margin({ top: this.px(5) })
              }
              .width('100%')
              .padding({ top: this.px(22), bottom: this.px(22) })
            }
          } else {
            ForEach(visibleFeedEvents(this.events), (ev: DshEvent, idx: number) => {
              ListItem() {
                if (ev.kind === 'user' || ev.kind === 'assistant') {
                  Row() {
                    this.ChatBubble(ev)
                  }
                  .width('100%')
                  .justifyContent(ev.kind === 'user' ? FlexAlign.End : FlexAlign.Start)
                  .padding({ left: this.px(4), right: this.px(4), top: this.px(3), bottom: this.px(3) })
                  .opacity(1)
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
            }, (ev: DshEvent) => ev.seq.toString())
          }
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .onScroll((offset: number, state: ScrollState) => { this.scrollY = offset; })
        .onAreaChange((oldValue: Area, newValue: Area) => { this.viewH = newValue.height as number; })
        .focusable(false)

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
            Text(this.promptText.trim() === '' ? '发送指令' : this.promptText)
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
          Text(this.modelPending
            ? ('模型 · ' + (this.selectionModel === '' ? '默认' : this.selectionModel) + ' · 下轮生效')
            : ('模型 · ' + (this.selectionModel === '' ? '跟随默认' : this.selectionModel)))
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
      .width('100%')
      .height('100%')
      .padding({ left: this.px(13), right: this.px(13), top: this.px(18), bottom: this.px(8) })

      if (this.showPrompt) {
        Stack() {
          Column() {}
            .width('100%')
            .height('100%')
            .backgroundColor('#9903070A')
            .onClick(() => { this.closePrompt(); })
          Column() {
            Row() {
              Text('新指令')
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
              .onChange((v: string) => { this.promptText = v; })
            Row() {
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
              Text('发送 ↗')
                .fontSize(this.vp(9))
                .fontWeight(FontWeight.Medium)
                .fontColor(INK)
                .textAlign(TextAlign.Center)
                .height(this.px(28))
                .layoutWeight(1)
                .backgroundColor(ACCENT)
                .borderRadius(this.px(14))
                .margin({ left: this.px(7) })
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
            if (this.modelsLoading && this.modelOptions.length === 0) {
              Text('读取中…')
                .fontSize(this.vp(9))
                .fontColor(DIM)
                .width('100%')
                .textAlign(TextAlign.Center)
                .margin({ top: this.px(24) })
            }
            List({ scroller: this.modelsScroller }) {
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
    
  }

  @Builder
  QuickView() {
    Scroll() {
      Column() {
        Text('快捷')
          .id('crown-quick')
          .fontSize(this.vp(13))
          .fontWeight(FontWeight.Medium)
          .fontColor(TEXT)
          .focusable(true)
          .focusOnTouch(true)
          .defaultFocus(true)
        Text('抬手就能派活')
          .fontSize(this.vp(7))
          .fontColor(DIM)
          .margin({ top: this.px(2), bottom: this.px(10) })
        ForEach(this.presets, (item: Preset) => {
          Row() {
            Text(item.label)
              .fontSize(this.vp(11))
              .fontColor(TEXT)
            Blank()
            Text('›')
              .fontSize(this.vp(13))
              .fontColor(DIM)
          }
          .width('100%')
          .height(this.px(42))
          .padding({ left: this.px(16), right: this.px(14) })
          .backgroundColor('#0D181C')
          .borderRadius(this.px(21))
          .margin({ top: this.px(7) })
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => { this.sendPreset(item.text); })
        }, (item: Preset) => item.label)
        Row() {
          Text('新建会话')
            .fontSize(this.vp(10))
            .fontColor(ACCENT)
        }
        .width('100%')
        .height(this.px(36))
        .justifyContent(FlexAlign.Center)
        .margin({ top: this.px(6) })
        .clickEffect({ level: ClickEffectLevel.LIGHT })
        .onClick(() => { this.doNew(); })
      }
      .width('100%')
      .padding({ left: this.px(30), right: this.px(30), top: this.px(30), bottom: this.px(30) })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  ApprovalView() {
    Scroll() {
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
  }

  @Builder
  MenuTile(label: string, caption: string, symbol: string, destination: string) {
    Row() {
      Text(symbol)
        .fontSize(this.vp(12))
        .fontColor(ACCENT)
        .textAlign(TextAlign.Center)
        .width(this.px(28))
        .height(this.px(28))
        .backgroundColor('#1B3335')
        .borderRadius(this.px(14))
        .margin({ right: this.px(9) })
      Column() {
        Text(label)
          .fontSize(this.vp(11))
          .fontWeight(FontWeight.Medium)
          .fontColor(TEXT)
        Text(caption)
          .fontSize(this.vp(7))
          .fontColor(DIM)
          .margin({ top: this.px(1) })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text('›')
        .fontSize(this.vp(14))
        .fontColor(DIM)
        .margin({ left: this.px(4) })
    }
    .width('100%')
    .height(this.px(44))
    .padding({ left: this.px(8), right: this.px(13) })
    .backgroundColor('#0D181C')
    .borderRadius(this.px(22))
    .margin({ top: this.px(7) })
    .clickEffect({ level: ClickEffectLevel.LIGHT })
    .onClick(() => {
      if (destination === 'sessions') { this.openSessions(); }
      else if (destination === 'guide') { this.showGuide = true; }
      else { this.switchView(destination); }
    })
  }

  @Builder
  MenuView() {
    Scroll(this.menuScroller) {
      Column() {
        Text('控制中心')
          .id('crown-menu')
          .fontSize(this.vp(13))
          .fontWeight(FontWeight.Medium)
          .fontColor(TEXT)
          .focusable(true)
          .focusOnTouch(true)
          .defaultFocus(true)
          .onDigitalCrown((event: CrownEvent) => { this.handleCrown(this.menuScroller, event); })
        this.MenuTile('会话', '回到正在进行的事', '≡', 'sessions')
        this.MenuTile('设置', '连接与设备管理', '◇', 'settings')
        this.MenuTile('诊断', '连接、轮询与缓存', '◎', 'diagnostics')
        this.MenuTile('使用引导', '重新认识腕上 DSH', '?', 'guide')
      }
      .width('100%')
      .padding({ left: this.px(43), right: this.px(43), top: this.px(37), bottom: this.px(34) })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    
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
      Text('返回')
        .fontSize(this.vp(9))
        .fontColor(ACCENT)
        .padding({ left: this.px(16), right: this.px(16), top: this.px(6), bottom: this.px(6) })
        .margin({ top: this.px(5) })
        .clickEffect({ level: ClickEffectLevel.LIGHT })
        .onClick(() => { this.switchView('main'); })
    }
      .width('100%')
      .padding({ left: this.px(40), right: this.px(40), top: this.px(34), bottom: this.px(30) })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
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
          this.DiagRow('版本', '2.0.38')
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
        Text('返回')
          .fontSize(this.vp(9))
          .fontColor(ACCENT)
          .padding({ left: this.px(16), right: this.px(16), top: this.px(6), bottom: this.px(6) })
          .margin({ top: this.px(5) })
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => { this.switchView('main'); })
      }
      .width('100%')
      .padding({ left: this.px(40), right: this.px(40), top: this.px(34), bottom: this.px(30) })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .focusable(true)
    .onDigitalCrown((event: CrownEvent) => {
      this.handleCrown(this.diagScroller, event);
    })
  }

  @Builder
  SessionsView() {
    Column() {
      Row() {
        Text('会话')
          .id('crown-sessions')
          .fontSize(this.vp(12))
          .fontWeight(FontWeight.Medium)
          .fontColor(TEXT)
          .layoutWeight(1)
          .focusable(true)
          .focusOnTouch(true)
          .defaultFocus(true)
          .onDigitalCrown((event: CrownEvent) => { this.handleCrown(this.sessionsScroller, event); })
        Text('+')
          .fontSize(this.vp(17))
          .fontColor(ACCENT)
          .textAlign(TextAlign.Center)
          .width(this.px(24))
          .height(this.px(24))
          .accessibilityText('新建会话')
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => { this.doNew(); })
      }
      .width('100%')
      .height(this.px(27))
      .padding({ left: this.px(40), right: this.px(40) })
      .margin({ top: this.px(35), bottom: this.px(5) })
      List({ scroller: this.sessionsScroller }) {
        LazyForEach(this.sessionSource, (s: SessionInfo) => {
          ListItem() {
            Row() {
              Circle({ width: this.vp(4), height: this.vp(4) })
                .fill(s.running ? WARN : (s.live ? OK : DIM))
                .margin({ right: this.px(8) })
              Column() {
                Text(s.title === '' ? s.id : s.title)
                  .fontSize(this.vp(10))
                  .fontColor(TEXT)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(s.running ? '执行中' : (s.live ? '在线 · 随时继续' : '已存档'))
                  .fontSize(this.vp(7))
                  .fontColor(DIM)
                  .margin({ top: this.px(3) })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text('›')
                .fontSize(this.vp(14))
                .fontColor(DIM)
                .margin({ left: this.px(5) })
            }
            .width('100%')
            .padding({ left: this.px(11), right: this.px(12), top: this.px(10), bottom: this.px(10) })
            .backgroundColor(s.id === this.currentSessionId ? '#16302F' : '#0D181C')
            .border({ width: s.id === this.currentSessionId ? 1 : 0, color: '#66ADE9D9' })
            .borderRadius(this.px(24))
          }
          .padding({ bottom: this.px(5) })
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => { this.doSelect(s.id); })
        }, (s: SessionInfo) => s.id)
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: this.px(32), right: this.px(32), bottom: this.px(37) })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .focusable(false)
    }
    .width('100%')
    .height('100%')
    
  }
}
