import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';

const page = await readFile(new URL('../watch-app/entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const guide = await readFile(new URL('../watch-app/entry/src/main/ets/common/QuickGuide.ets', import.meta.url), 'utf8');
const welcome = await readFile(new URL('../watch-app/entry/src/main/ets/common/RepoWelcome.ets', import.meta.url), 'utf8');
const appVersion = await readFile(new URL('../watch-app/entry/src/main/ets/common/AppVersion.ets', import.meta.url), 'utf8');
const version = /APP_VERSION: string = '([^']+)'/.exec(appVersion)[1];
// 直接运行生产代码的恢复/完成方法，而非测试另写一套引导状态机。
const methods = page.slice(page.indexOf('  private async restore()'), page.indexOf('  private async saveHistory('));
const js = ts.transpileModule(`class Harness { ${methods} }`, { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText;
function fixture(saved = {}, broken = false) {
  const values = new Map(Object.entries(saved));
  const preferences = { getPreferences: async () => {
    if (broken) throw new Error('storage unavailable');
    return { get: async (key, fallback) => values.has(key) ? values.get(key) : fallback,
      put: async (key, value) => values.set(key, value), flush: async () => {} };
  } };
  const Harness = new Function('preferences', 'STORE', 'APP_VERSION', js + '; return Harness;')(preferences, 'dsh_watch', version);
  const h = new Harness();
  Object.assign(h, { bootReady: false, showGuide: false, view: 'connect', server: '', serverEdit: '', token: '', notifications: 0, polls: 0,
    ctx: () => ({}), switchView(v) { this.view = v; }, startPolling() { this.polls++; },
    async restoreComputers(p) {
      const server = await p.get('server', '');
      if (server) { this.server = server; this.switchView('main'); this.startPolling(); }
    },
    ensureNotification() { this.notifications++; }, toast(text) { this.message = text; } });
  return { h, values };
}
test('首次打开显示引导，读完偏好才打开首屏，不提前弹通知权限', async () => {
  const { h } = fixture();
  await h.restore();
  assert.equal(h.bootReady, true);
  assert.equal(h.showGuide, true);
  assert.equal(h.notifications, 0);
  assert.equal(h.view, 'connect');
});
test('跳过或完成持久化，下次启动不再自动弹出', async () => {
  const { h, values } = fixture();
  await h.restore(); await h.finishGuide();
  assert.equal(h.showGuide, false);
  assert.equal(values.get('guideSeenV1'), true);
  assert.equal(h.notifications, 1);
  const next = fixture(Object.fromEntries(values)).h;
  await next.restore();
  assert.equal(next.showGuide, false);
});
test('已有配对的升级用户看完引导仍保留连接并进入主界面', async () => {
  const { h, values } = fixture({ server: 'http://host', token: 'test-token' });
  await h.restore();
  assert.equal(h.showGuide, true);
  assert.equal(h.polls, 1);
  await h.finishGuide();
  assert.equal(h.view, 'main');
  assert.equal(h.server, 'http://host');
  assert.equal(values.get('token'), 'test-token');
});
test('引导期间收到的审批不会被完成按钮覆盖', async () => {
  const { h } = fixture(); await h.restore();
  h.view = 'approval';
  await h.finishGuide();
  assert.equal(h.view, 'approval');
});
test('存储异常仍允许离线退出引导，不锁死启动', async () => {
  const { h } = fixture({}, true); await h.restore();
  assert.equal(h.bootReady, true);
  await h.finishGuide();
  assert.equal(h.showGuide, false);
  assert.match(h.message, /未保存/);
});
test('重看入口与五页离线演示齐全，不发送真实任务或审批', () => {
  assert.match(page, /key: 'guide', title: '使用引导'/);
  assert.match(page, /key === 'guide'.*this.showGuide = true/);
  assert.match(guide, /this.step === 4 \? '开始使用'/);
  assert.match(guide, /上一步/);
  assert.match(guide, /跳过引导/);
  assert.match(guide, /Math.min\(this.screenWidth \/ 233, this.screenHeight \/ 233\)/);
  assert.doesNotMatch(guide, /sendPrompt|decideApproval|cancelTurn|Swiper\(/);
  assert.ok(page.indexOf('else if (this.showGuide)') < page.indexOf('Swiper(this.swiper)'));
});

test('仓库欢迎页每个版本独立展示，跳过不记忆，确认后同版本不再显示', async () => {
  const old = { guideSeenV1: true, repoWelcomeVersion: '2.1.7' };
  const { h, values } = fixture(old); await h.restore();
  assert.equal(h.showRepoWelcome, true); assert.equal(h.notifications, 0);
  await h.finishRepoWelcome(false);
  assert.equal(h.showRepoWelcome, false); assert.equal(values.get('repoWelcomeVersion'), '2.1.7');
  await h.finishRepoWelcome(true);
  assert.equal(values.get('repoWelcomeVersion'), version);
  const next = fixture(Object.fromEntries(values)).h; await next.restore();
  assert.equal(next.showRepoWelcome, false); assert.equal(next.notifications, 1);
});

test('欢迎页二维码仅指向项目仓库，版本与发布清单一致', async () => {
  const manifest = JSON.parse(await readFile(new URL('../watch-app/AppScope/app.json5', import.meta.url), 'utf8'));
  assert.equal(manifest.app.versionName, version);
  assert.match(welcome, /'https:\/\/github\.com\/chx404\/dsh-harmony-watch'/);
  assert.match(welcome, /QRCode\(REPO_URL\)/);
  assert.match(welcome, /Button\('今后不再显示'/);
  assert.ok(page.indexOf('else if (this.showRepoWelcome)') < page.indexOf('else if (this.showGuide)'));
});
