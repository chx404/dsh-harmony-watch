// Pure storage model; callers own persistence and connection lifecycle.
export interface ComputerProfile {
  id: string;
  name: string;
  server: string;
  token: string;
  lan?: string;
  remote?: string;
  mode?: string;
}

export interface ComputerProfileSnapshot {
  profiles: ComputerProfile[];
  selectedId: string;
}

export const COMPUTER_PROFILE_MAX_COUNT: number = 12;
const MAX_NAME_LENGTH: number = 120;
const MAX_SERVER_LENGTH: number = 2048;
const MAX_TOKEN_LENGTH: number = 1024;
const MAX_SNAPSHOT_LENGTH: number = 1024 * 1024; // UTF-16 code units, including JSON escapes

function authorityEnd(server: string, start: number): number {
  const slash: number = server.indexOf('/', start);
  return slash < 0 ? server.length : slash;
}

function validIpv4Tail(part: string): boolean {
  const octets: string[] = part.split('.');
  return octets.length === 4 && octets.every((octet: string): boolean =>
    /^(0|[1-9][0-9]{0,2})$/.test(octet) && Number(octet) <= 255);
}

function validIpv6Host(host: string): boolean {
  const halves: string[] = host.substring(1, host.length - 1).split('::');
  if (halves.length > 2) {
    return false;
  }
  let groups: number = 0;
  for (let i: number = 0; i < halves.length; i++) {
    if (halves[i] === '') {
      continue;
    }
    const parts: string[] = halves[i].split(':');
    for (let j: number = 0; j < parts.length; j++) {
      if (/^[0-9a-fA-F]{1,4}$/.test(parts[j])) {
        groups++;
      } else if (i === halves.length - 1 && j === parts.length - 1 && validIpv4Tail(parts[j])) {
        groups += 2;
      } else {
        return false;
      }
    }
  }
  return halves.length === 2 ? groups < 8 : groups === 8;
}

/** Keep Net.normalizeUrl's trim, implied http://, and trailing slash removal; validate the result. */
export function normalizeComputerServer(raw: string): string {
  if (typeof raw !== 'string' || raw.length > MAX_SERVER_LENGTH) {
    throw new Error('电脑地址无效');
  }
  let server: string = raw.trim();
  if (!server.startsWith('http://') && !server.startsWith('https://')) {
    server = 'http://' + server;
  }
  while (server.endsWith('/')) {
    server = server.substring(0, server.length - 1);
  }
  // Credentials, queries and fragments are not allowed in an API base address.
  if (server.length > MAX_SERVER_LENGTH || /[\s\\?#\x00-\x1f\x7f]/.test(server)) {
    throw new Error('电脑地址无效');
  }
  const start: number = server.startsWith('https://') ? 8 : 7;
  const authority: string = server.substring(start, authorityEnd(server, start));
  const bracketed: boolean = authority.startsWith('[');
  const bracketEnd: number = authority.indexOf(']');
  const colon: number = authority.indexOf(':');
  const hostEnd: number = bracketed ? bracketEnd + 1 : (colon < 0 ? authority.length : colon);
  const host: string = authority.substring(0, hostEnd);
  const port: string = authority.substring(hostEnd);
  if ((bracketed ? bracketEnd < 0 || !validIpv6Host(host) : !/^[A-Za-z0-9.\u0080-\uFFFF_-]+$/.test(host)) ||
    (port !== '' && (!/^:[0-9]{1,5}$/.test(port) || Number(port.substring(1)) < 1 || Number(port.substring(1)) > 65535))) {
    throw new Error('电脑地址无效');
  }
  return server;
}

function serverKey(server: string): string {
  const start: number = server.startsWith('https://') ? 8 : 7;
  const end: number = authorityEnd(server, start);
  const authority: string = server.substring(start, end);
  // Fold only ASCII host case. Don't rewrite the stored URL or conflate schemes,
  // explicit ports, IPv6 spellings, or distinct path/escape spellings.
  return /^[\x00-\x7f]+$/.test(authority)
    ? server.substring(0, start) + authority.toLowerCase() + server.substring(end)
    : server;
}

function normalizeOptionalServer(value: string): string {
  if (typeof value !== 'string' || value.length > MAX_SERVER_LENGTH) {
    throw new Error('电脑地址无效');
  }
  return value.trim() === '' ? '' : normalizeComputerServer(value);
}

function normalizeProfile(profile: ComputerProfile): ComputerProfile {
  if (!profile || typeof profile !== 'object' || Array.isArray(profile) ||
    typeof profile.id !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(profile.id) ||
    typeof profile.name !== 'string' || profile.name.length > MAX_NAME_LENGTH ||
    profile.name.trim() === '' || /[\x00-\x1f\x7f\u2028\u2029]/.test(profile.name) ||
    typeof profile.token !== 'string' || profile.token.length === 0 || profile.token.length > MAX_TOKEN_LENGTH ||
    /[\s\x00-\x1f\x7f]/.test(profile.token) ||
    (profile.mode !== undefined && profile.mode !== 'auto' && profile.mode !== 'lan' && profile.mode !== 'remote')) {
    throw new Error('电脑配对资料无效');
  }
  const normalized: ComputerProfile = {
    id: profile.id, name: profile.name.trim(), server: normalizeComputerServer(profile.server), token: profile.token
  };
  if (profile.lan !== undefined) {
    normalized.lan = normalizeOptionalServer(profile.lan);
  }
  if (profile.remote !== undefined) {
    normalized.remote = normalizeOptionalServer(profile.remote);
  }
  if (profile.mode !== undefined) {
    normalized.mode = profile.mode;
  }
  return normalized;
}

/** Validate and clone only the known fields; no selected profile is a valid state. */
export function normalizeComputerProfiles(snapshot: ComputerProfileSnapshot): ComputerProfileSnapshot {
  if (!snapshot || typeof snapshot !== 'object' || Array.isArray(snapshot) || !Array.isArray(snapshot.profiles) ||
    snapshot.profiles.length > COMPUTER_PROFILE_MAX_COUNT || typeof snapshot.selectedId !== 'string') {
    throw new Error('电脑配对资料无效');
  }
  const profiles: ComputerProfile[] = [];
  for (let i: number = 0; i < snapshot.profiles.length; i++) {
    const profile: ComputerProfile = normalizeProfile(snapshot.profiles[i]);
    if (profiles.some((item: ComputerProfile): boolean => item.id === profile.id)) {
      throw new Error('电脑配对资料无效');
    }
    profiles.push(profile);
  }
  if (snapshot.selectedId !== '' && !profiles.some((item: ComputerProfile): boolean => item.id === snapshot.selectedId)) {
    throw new Error('电脑配对资料无效');
  }
  return { profiles: profiles, selectedId: snapshot.selectedId };
}

export function parseComputerProfiles(raw: string): ComputerProfileSnapshot {
  if (raw === '') {
    return { profiles: [], selectedId: '' };
  }
  try {
    if (typeof raw === 'string' && raw.length <= MAX_SNAPSHOT_LENGTH) {
      return normalizeComputerProfiles(JSON.parse(raw) as ComputerProfileSnapshot);
    }
  } catch (_) {
    // Do not expose native JSON errors or partially load data containing credentials.
  }
  throw new Error('电脑配对资料损坏');
}

export function upsertComputerProfile(snapshot: ComputerProfileSnapshot, profile: ComputerProfile): ComputerProfileSnapshot {
  const result: ComputerProfileSnapshot = normalizeComputerProfiles(snapshot);
  const updated: ComputerProfile = normalizeProfile(profile);
  let index: number = result.profiles.findIndex((item: ComputerProfile): boolean => item.id === updated.id);
  if (index < 0) {
    const key: string = serverKey(updated.server);
    // Different PCs can reuse the same LAN address on different networks.
    index = result.profiles.findIndex((item: ComputerProfile): boolean =>
      serverKey(item.server) === key && item.token === updated.token);
  }
  if (index >= 0) {
    updated.id = result.profiles[index].id;
    result.profiles[index] = updated;
  } else {
    if (result.profiles.length >= COMPUTER_PROFILE_MAX_COUNT) {
      throw new Error('已达电脑配对数量上限，请先移除不需要的电脑');
    }
    result.profiles.push(updated);
  }
  result.selectedId = updated.id;
  return result;
}

export function removeComputerProfile(snapshot: ComputerProfileSnapshot, id: string): ComputerProfileSnapshot {
  const result: ComputerProfileSnapshot = normalizeComputerProfiles(snapshot);
  const index: number = result.profiles.findIndex((item: ComputerProfile): boolean => item.id === id);
  if (index >= 0) {
    result.profiles.splice(index, 1);
    if (result.selectedId === id) {
      result.selectedId = '';
    }
  }
  return result;
}
