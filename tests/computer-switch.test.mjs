import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';

const root = new URL('../watch-app/entry/src/main/ets/', import.meta.url);
const source = await readFile(new URL('pages/Index.ets', root), 'utf8');
const profileSource = await readFile(new URL('common/ComputerProfiles.ets', root), 'utf8');
const compile = input => ts.transpileModule(input, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText;
const profileExports = {};
new Function('exports', compile(profileSource))(profileExports);
const extract = name => {
  const start = source.search(new RegExp(`^  private (?:async )?${name}\\(`, 'm'));
  assert.notEqual(start, -1, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
};
const methods = ['historyKey', 'restoreComputers', 'safeComputerAddress', 'findComputer', 'writeComputers', 'updateComputers',
  'activateComputer', 'prepareComputerControl', 'enterComputerChat', 'switchComputer', 'doConnect', 'unbind', 'poll', 'refreshSessions', 'doSend', 'doDecide'];
const js = compile(`class Harness {\n${methods.map(extract).join('\n')}\n}`);
const profile = (id, extra = {}) => ({ id, name: id.toUpperCase(), server: `http://${id}.test:8765`, token: `test-token-${id}`, ...extra });
const A = profile('a', { lan: 'http://a.test:8765', remote: 'https://a-remote.test', mode: 'lan' });
const B = profile('b', { remote: 'https://b-remote.test', mode: 'remote' });

function fixture({ saved = '', legacy = {}, broken = false, pair, fetchState, fetchSessions, sendPrompt, decideApproval } = {}) {
  const state = { raw: saved, pending: undefined, broken, writes: 0, polls: 0, applies: [], sessionReplies: [], toasts: [] };
  const preferences = {
    getPreferences: async () => ({
      get: async () => state.raw,
      put: async (_, value) => { state.pending = value; },
      flush: async () => { if (state.broken) throw Error('disk error'); state.raw = state.pending; state.writes++; }
    }),
    async removePreferencesFromCache() { state.pending = undefined; }
  };
  const Harness = new Function('preferences', 'COMPUTER_STORE', 'COMPUTER_KEY', 'parseComputerProfiles', 'normalizeComputerServer',
    'upsertComputerProfile', 'removeComputerProfile', 'pair', 'fetchState', 'fetchSessions', 'sendPrompt', 'decideApproval', js + ';return Harness;')(
    preferences, 'computer-store', 'profilesV1', profileExports.parseComputerProfiles, profileExports.normalizeComputerServer,
    profileExports.upsertComputerProfile, profileExports.removeComputerProfile, pair, fetchState, fetchSessions, sendPrompt, decideApproval);
  const h = Object.assign(new Harness(), { activeComputerId: '', computerProfiles: [], computerDrafts: new Map(), computerEpoch: 0,
    requestGeneration: 0, stopTimer: -1, view: 'connect', chatKind: 'dsh', code: '', token: '', server: '', connected: false,
    promptText: '', dshDraft: '', ctx() {}, flushLocalDraft: async () => {}, updatePicker() {}, sessionSource: { set() {} },
    startPolling() { state.polls++; }, stopPolling() {}, schedulePoll() {}, failover() {}, rememberChatKind() {}, closePrompt() {},
    toast(text) { state.toasts.push(text); }, switchView(v) { this.view = v; }, backScene() { this.view = 'computers'; },
    apply(snap) { state.applies.push(snap); }, syncSessions(list) { state.sessionReplies.push(list); } });
  return { h, state, async restore() { await h.restoreComputers({ get: async (k, fallback) => legacy[k] ?? fallback }); } };
}
const snapshot = (profiles, selectedId) => JSON.stringify({ profiles, selectedId });

test('upgrade migrates legacy credentials and network mode once; explicit empty store does not reimport', async () => {
  const legacy = { server: 'a.test:8765', token: A.token, netMode: 'remote', remote: 'https://a-remote.test', lan: 'invalid?token=x' };
  const { h, state, restore } = fixture({ legacy }); await restore();
  assert.equal(h.activeComputerId, 'legacy'); assert.equal(h.server, 'https://a-remote.test'); assert.equal(h.token, A.token);
  assert.equal(h.historyKey('same'), 'hist_same'); assert.equal(state.writes, 1); assert.equal(state.polls, 1);
  assert.equal(JSON.parse(state.raw).profiles[0].lan, '');
  const deleted = fixture({ saved: snapshot([], ''), legacy }); await deleted.restore();
  assert.equal(deleted.h.activeComputerId, ''); assert.equal(deleted.state.writes, 0);
});

test('switching clears host UI, restores per-PC drafts and saves the active ID before switching', async () => {
  const { h, state, restore } = fixture({ saved: snapshot([A, B], 'a') }); await restore();
  Object.assign(h, { connected: true, pending: [{ id: 'approval-a' }], sessions: [{ id: 'same' }], events: ['computer-a'], promptText: 'draft-a', modelOptions: ['a'], expandedText: 'private a', stopArmed: true });
  const keyA = h.historyKey('same'); await h.switchComputer('b');
  assert.equal(h.server, B.remote); assert.equal(h.token, B.token); assert.equal(h.connected, false);
  assert.notEqual(h.historyKey('same'), keyA); assert.equal(h.promptText, '');
  for (const key of ['pending', 'sessions', 'events', 'modelOptions']) assert.deepEqual(h[key], []);
  assert.equal(h.expandedText, ''); assert.equal(h.stopArmed, false);
  assert.equal(JSON.parse(state.raw).selectedId, 'b');
  h.promptText = 'draft-b'; await h.switchComputer('a'); assert.equal(h.promptText, 'draft-a');
  await h.switchComputer('b'); assert.equal(h.promptText, 'draft-b');
});

test('read or write failure leaves current selection and local mode intact', async () => {
  const { h, state, restore } = fixture({ saved: snapshot([A, B], 'a'), broken: true }); await restore();
  h.chatKind = 'local'; h.promptText = 'local draft'; await h.switchComputer('b');
  assert.equal(h.chatKind, 'local'); assert.equal(h.promptText, 'local draft'); assert.equal(h.activeComputerId, 'a');
  assert.equal(JSON.parse(state.raw).selectedId, 'a'); assert.equal(state.pending, undefined);
  const bad = fixture({ saved: '{bad', legacy: { server: A.server, token: A.token } }); await bad.restore();
  assert.equal(bad.h.computerStoreLoaded, undefined); assert.equal(bad.state.writes, 0);
});

test('pairing sends only the new address and six-digit code and preserves the prior computer', async () => {
  const attempts = []; const { h, state, restore } = fixture({ saved: snapshot([A], 'a'), pair: async (...args) => { attempts.push(args); return { ok: true, token: B.token }; } });
  await restore(); h.addressEdit = 'b.test:8765'; h.computerNameEdit = 'Laptop'; h.code = '000123'; await h.doConnect();
  assert.deepEqual(attempts, [[B.server, '000123']]); assert.equal(h.activeComputerName, 'Laptop'); assert.equal(h.code, '');
  assert.equal(JSON.parse(state.raw).profiles.length, 2); assert.equal(JSON.parse(state.raw).profiles[0].token, A.token);
});

test('late poll, session list, action and approval replies from previous computer cannot overwrite new state', async () => {
  const outstanding = [];
  const delayed = (...args) => new Promise(resolve => outstanding.push({ args, resolve }));
  const f = fixture({ saved: snapshot([A, B], 'a'), fetchState: delayed, fetchSessions: delayed, sendPrompt: delayed, decideApproval: delayed });
  await f.restore(); const { h, state } = f;
  Object.assign(h, { connected: true, promptText: 'draft-a', pending: [{ id: 'old-approval' }] });
  const old = [h.poll(), h.refreshSessions(), h.doSend('followup'), h.doDecide('allow')];
  assert.equal(outstanding.length, 4); assert.ok(outstanding.every(item => item.args[0] === A.server && item.args[1] === A.token));
  await h.switchComputer('b');
  const newPoll = h.poll(); assert.equal(outstanding.length, 5); assert.equal(h.busy, true);
  h.pending = [{ id: 'b-approval' }]; h.promptText = 'draft-b';
  outstanding.slice(0, 4).forEach(x => x.resolve({ ok: true, sessions: [{ id: 'old-session' }] })); await Promise.all(old);
  assert.deepEqual(state.applies, []); assert.deepEqual(state.sessionReplies, []); assert.deepEqual(h.pending, [{ id: 'b-approval' }]);
  assert.equal(h.promptText, 'draft-b'); assert.equal(h.busy, true);
  outstanding[4].resolve({ ok: true }); await newPoll; assert.equal(state.applies.length, 1); assert.equal(h.busy, false);
});

test('removing the active computer requires confirmation and never auto-selects another', async () => {
  const { h, state, restore } = fixture({ saved: snapshot([A, B], 'a') }); await restore();
  await h.unbind(); assert.equal(state.writes, 0); assert.equal(h.activeComputerId, 'a');
  await h.unbind(); assert.equal(h.activeComputerId, ''); assert.equal(h.token, ''); assert.equal(h.view, 'computers');
  assert.deepEqual(JSON.parse(state.raw), { profiles: [B], selectedId: '' });
});
