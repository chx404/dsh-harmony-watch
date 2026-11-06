import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import util from '@ohos.util';
import { DirectApiConfig, DirectConfigStore, DirectStoredConfig, validateDirectConfig } from './DirectApi';

export interface ApiProfile extends DirectApiConfig {
  id: string;
  name: string;
}

export interface ApiProfilesSnapshot {
  profiles: ApiProfile[];
  selectedId: string;
  notice: string;
}

interface InternalSnapshot extends ApiProfilesSnapshot {
  legacyPending: boolean;
}

interface StoredProfiles {
  version: number;
  profiles: ApiProfile[];
  selectedId: string;
  legacyPending?: boolean;
}

export const API_PROFILE_MAX_COUNT: number = 30;
export const API_PROFILE_MAX_BYTES: number = 1024 * 1024;
export const API_PROFILE_STORAGE_NOTICE: string = 'API Key 按用户选择以明文保存在应用私有目录，不加密；不会发送到宿主或日志';
const STORE_NAME: string = 'dsh_api_profiles_v1';
const LEGACY_STORE_NAME: string = 'dsh_direct_api_secure_v1';
const SNAPSHOT_KEY: string = 'snapshot';
const MIGRATION_NOTICE: string = '旧 API 配置迁移未完成：旧配置未能读取或解密仍保留，可继续新增；稍后自动重试迁移';
const LEGACY_EMPTY_NOTICE: string = '未配置；可手动输入，无需宿主';
let operations: Promise<void> = Promise.resolve();
let preferencesNeedReload: boolean = false;
let idCounter: number = 0;

function copyProfile(profile: ApiProfile): ApiProfile {
  return {
    id: profile.id, name: profile.name, baseUrl: profile.baseUrl,
    apiKey: profile.apiKey, model: profile.model, protocol: profile.protocol
  };
}

function copySnapshot(snapshot: ApiProfilesSnapshot): ApiProfilesSnapshot {
  return {
    profiles: snapshot.profiles.map((profile: ApiProfile): ApiProfile => copyProfile(profile)),
    selectedId: snapshot.selectedId, notice: snapshot.notice
  };
}

function validId(id: string): boolean {
  return typeof id === 'string' && /^api-[A-Za-z0-9_-]{1,120}$/.test(id);
}

function checkedConfig(config: DirectApiConfig): DirectApiConfig {
  if (config === null || typeof config !== 'object' || Array.isArray(config) ||
    typeof config.baseUrl !== 'string' || typeof config.apiKey !== 'string' ||
    typeof config.model !== 'string' || typeof config.protocol !== 'string') {
    throw new Error('API 配置字段无效');
  }
  // Explicit whitelist: never serialize caller objects, getters beyond these fields, or toJSON.
  const checked: DirectApiConfig = validateDirectConfig({
    baseUrl: config.baseUrl, apiKey: config.apiKey, model: config.model, protocol: config.protocol
  });
  // URL normalization may expand Unicode paths; never persist a value we cannot read back.
  return validateDirectConfig(checked);
}

function checkedName(name: string, config: DirectApiConfig): string {
  if (typeof name !== 'string' || name.length > 120 || /[\x00-\x1f\x7f]/.test(name)) {
    throw new Error('API 名称须为 120 字以内的单行文字');
  }
  return name.trim() || config.model.slice(0, 120);
}

function profileFrom(config: DirectApiConfig, name: string, id: string): ApiProfile {
  return { id: id, name: name, baseUrl: config.baseUrl, apiKey: config.apiKey, model: config.model, protocol: config.protocol };
}

function snapshotText(snapshot: InternalSnapshot): string {
  if (snapshot.profiles.length > API_PROFILE_MAX_COUNT) {
    throw new Error('API 配置已达 30 个上限，请先删除不需要的配置');
  }
  const stored: StoredProfiles = {
    version: 1, profiles: snapshot.profiles.map((profile: ApiProfile): ApiProfile => copyProfile(profile)),
    selectedId: snapshot.selectedId, legacyPending: snapshot.legacyPending
  };
  const raw: string = JSON.stringify(stored);
  if (raw.length > API_PROFILE_MAX_BYTES || new util.TextEncoder().encodeInto(raw).length > API_PROFILE_MAX_BYTES) {
    throw new Error('API 配置总大小超过 1 MiB；未覆盖已有配置');
  }
  return raw;
}

export class ApiProfileStore {
  private context: common.Context;
  private snapshot: ApiProfilesSnapshot = { profiles: [], selectedId: '', notice: API_PROFILE_STORAGE_NOTICE };

  constructor(context: common.Context) { this.context = context; }

  private serial<T>(action: () => Promise<T>): Promise<T> {
    const result: Promise<T> = operations.then(action);
    operations = result.then((): void => {}, (): void => {});
    return result;
  }

  private async preferencesStore(): Promise<preferences.Preferences> {
    if (preferencesNeedReload) {
      try {
        await preferences.removePreferencesFromCache(this.context, STORE_NAME);
        preferencesNeedReload = false;
      } catch (_) {
        throw new Error('API 配置缓存恢复失败，请重试；未覆盖已有配置');
      }
    }
    return preferences.getPreferences(this.context, STORE_NAME);
  }

  private newId(profiles: ApiProfile[]): string {
    let id: string;
    do {
      idCounter++;
      id = 'api-' + Date.now().toString(36) + '-' + idCounter.toString(36) + '-' +
        Math.floor(Math.random() * 0x100000000).toString(36);
    } while (profiles.some((profile: ApiProfile): boolean => profile.id === id));
    return id;
  }

  private async migrate(snapshot: InternalSnapshot): Promise<InternalSnapshot> {
    let legacy: DirectStoredConfig;
    let hasSealed: boolean;
    snapshot.legacyPending = true;
    snapshot.notice = API_PROFILE_STORAGE_NOTICE + '；' + MIGRATION_NOTICE;
    try {
      // Read only. Never call legacy save/clear/delete, including for malformed ciphertext.
      const oldStore: preferences.Preferences = await preferences.getPreferences(this.context, LEGACY_STORE_NAME);
      hasSealed = await oldStore.has('sealed');
      legacy = await new DirectConfigStore(this.context).load();
    } catch (_) { return snapshot; }
    if (!legacy.config) {
      if (!hasSealed && legacy.notice === LEGACY_EMPTY_NOTICE) {
        snapshot.legacyPending = false;
        snapshot.notice = API_PROFILE_STORAGE_NOTICE;
      }
      return snapshot;
    }
    let config: DirectApiConfig;
    try { config = checkedConfig(legacy.config); } catch (_) { return snapshot; }
    if (snapshot.profiles.length >= API_PROFILE_MAX_COUNT) {
      snapshot.notice += '；请释放一个配置名额后重试迁移';
      return snapshot;
    }
    const profile: ApiProfile = profileFrom(config, checkedName('', config), this.newId(snapshot.profiles));
    const migrated: InternalSnapshot = {
      profiles: snapshot.profiles.concat([profile]), selectedId: snapshot.selectedId || profile.id,
      notice: API_PROFILE_STORAGE_NOTICE + '；旧配置已迁移，旧加密副本仍保留', legacyPending: false
    };
    try { snapshotText(migrated); } catch (_) {
      snapshot.notice += '；迁移需更多存储空间';
      return snapshot;
    }
    await this.commit(migrated);
    return migrated;
  }

  private async readSnapshot(): Promise<InternalSnapshot> {
    let raw: preferences.ValueType;
    let exists: boolean;
    try {
      const store: preferences.Preferences = await this.preferencesStore();
      exists = await store.has(SNAPSHOT_KEY);
      raw = exists ? await store.get(SNAPSHOT_KEY, '') : '';
    } catch (_) {
      throw new Error('API 配置读取失败，请重试；未覆盖已有配置');
    }
    // An explicit empty snapshot is a committed deletion, not an invitation to re-migrate.
    if (!exists) { return this.migrate({ profiles: [], selectedId: '', notice: '', legacyPending: false }); }
    if (typeof raw !== 'string' || raw.length > API_PROFILE_MAX_BYTES ||
      new util.TextEncoder().encodeInto(raw).length > API_PROFILE_MAX_BYTES) {
      throw new Error('API 配置主快照损坏或超过 1 MiB；未覆盖已有配置');
    }
    let stored: StoredProfiles;
    try { stored = JSON.parse(raw) as StoredProfiles; } catch (_) {
      throw new Error('API 配置主快照 JSON 损坏；未覆盖已有配置');
    }
    if (stored === null || typeof stored !== 'object' || Array.isArray(stored) || stored.version !== 1 ||
      !Array.isArray(stored.profiles) || typeof stored.selectedId !== 'string' ||
      (stored.legacyPending !== undefined && typeof stored.legacyPending !== 'boolean')) {
      throw new Error('API 配置主快照格式损坏；未覆盖已有配置');
    }
    if (stored.profiles.length > API_PROFILE_MAX_COUNT) {
      throw new Error('API 配置超过 30 个上限；未覆盖已有配置');
    }
    const profiles: ApiProfile[] = [];
    try {
      for (let i: number = 0; i < stored.profiles.length; i++) {
        const value: ApiProfile = stored.profiles[i];
        if (value === null || typeof value !== 'object' || !validId(value.id) ||
          profiles.some((profile: ApiProfile): boolean => profile.id === value.id)) {
          throw new Error('无效或重复 ID');
        }
        const config: DirectApiConfig = checkedConfig(value);
        profiles.push(profileFrom(config, checkedName(value.name, config), value.id));
      }
      if ((profiles.length === 0 && stored.selectedId !== '') ||
        (profiles.length > 0 && !profiles.some((profile: ApiProfile): boolean => profile.id === stored.selectedId))) {
        throw new Error('无效选中 ID');
      }
    } catch (_) {
      // Do not isolate/drop malformed entries: each one may hold an irreplaceable Key.
      throw new Error('API 配置条目损坏；未覆盖任何已有配置');
    }
    const snapshot: InternalSnapshot = {
      profiles: profiles, selectedId: stored.selectedId, notice: API_PROFILE_STORAGE_NOTICE,
      legacyPending: stored.legacyPending === true
    };
    return snapshot.legacyPending ? this.migrate(snapshot) : snapshot;
  }

  private async commit(snapshot: InternalSnapshot): Promise<void> {
    const raw: string = snapshotText(snapshot);
    try {
      const store: preferences.Preferences = await this.preferencesStore();
      // Atomic application-level commit: one JSON value, never delete the previous value first.
      await store.put(SNAPSHOT_KEY, raw);
      await store.flush();
    } catch (_) {
      preferencesNeedReload = true;
      try {
        await preferences.removePreferencesFromCache(this.context, STORE_NAME);
        preferencesNeedReload = false;
      } catch (_) {}
      throw new Error('API 配置保存失败；未提交修改，原配置保留，请重试');
    }
    this.snapshot = copySnapshot(snapshot);
  }

  async load(): Promise<ApiProfilesSnapshot> {
    return this.serial(async (): Promise<ApiProfilesSnapshot> => {
      const snapshot: ApiProfilesSnapshot = await this.readSnapshot();
      this.snapshot = copySnapshot(snapshot);
      return copySnapshot(snapshot);
    });
  }

  list(): ApiProfile[] {
    return this.snapshot.profiles.map((profile: ApiProfile): ApiProfile => copyProfile(profile));
  }

  active(): ApiProfile | undefined {
    const profile: ApiProfile | undefined = this.snapshot.profiles.find((item: ApiProfile): boolean => item.id === this.snapshot.selectedId);
    return profile ? copyProfile(profile) : undefined;
  }

  async upsert(config: DirectApiConfig, name: string = '', id: string = ''): Promise<ApiProfile> {
    // Snapshot inputs before waiting on slow writes from another instance.
    const checked: DirectApiConfig = checkedConfig(config);
    const label: string = checkedName(name, checked);
    if (id !== '' && !validId(id)) { throw new Error('API 配置 ID 无效'); }
    return this.serial(async (): Promise<ApiProfile> => {
      const snapshot: InternalSnapshot = await this.readSnapshot();
      const index: number = id === '' ? -1 : snapshot.profiles.findIndex((profile: ApiProfile): boolean => profile.id === id);
      if (id !== '' && index < 0) { throw new Error('API 配置不存在；请刷新列表'); }
      const profile: ApiProfile = profileFrom(checked, label, id || this.newId(snapshot.profiles));
      if (id === '') {
        snapshot.profiles.push(profile);
        snapshot.selectedId = profile.id;
      } else {
        snapshot.profiles[index] = profile;
      }
      await this.commit(snapshot);
      return copyProfile(profile);
    });
  }

  async select(id: string): Promise<ApiProfile> {
    return this.serial(async (): Promise<ApiProfile> => {
      const snapshot: InternalSnapshot = await this.readSnapshot();
      const profile: ApiProfile | undefined = snapshot.profiles.find((item: ApiProfile): boolean => item.id === id);
      if (!profile) { throw new Error('API 配置不存在'); }
      snapshot.selectedId = id;
      await this.commit(snapshot);
      return copyProfile(profile);
    });
  }

  async remove(id: string): Promise<void> {
    return this.serial(async (): Promise<void> => {
      const snapshot: InternalSnapshot = await this.readSnapshot();
      const index: number = snapshot.profiles.findIndex((profile: ApiProfile): boolean => profile.id === id);
      if (index < 0) { throw new Error('API 配置不存在'); }
      snapshot.profiles.splice(index, 1);
      if (snapshot.profiles.length === 0) {
        // Explicit deletion to empty must never revive a legacy entry on restart.
        snapshot.legacyPending = false;
        snapshot.notice = API_PROFILE_STORAGE_NOTICE;
      }
      if (snapshot.selectedId === id) {
        snapshot.selectedId = snapshot.profiles.length > 0 ? snapshot.profiles[Math.min(index, snapshot.profiles.length - 1)].id : '';
      }
      await this.commit(snapshot);
    });
  }
}
