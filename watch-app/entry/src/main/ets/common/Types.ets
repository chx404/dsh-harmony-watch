export interface DshImage {
  attachmentId: string;
  mediaType: string;
  width: number;
  height: number;
  bytes?: number;
  name?: string;
}

export interface DshEvent {
  seq: number;
  t: number;
  sessionId: string;
  kind: string;
  text?: string;
  tool?: string;
  approvalId?: string;
  timeoutMs?: number;
  running?: boolean;
  fromWatch?: boolean;
  outcome?: string;
  reason?: string;
  hasDetail?: boolean;
  images?: DshImage[];
}

export interface SessionInfo {
  id: string;
  title: string;
  cwd: string;
  running: boolean;
  live: boolean;
}

export interface PendingInfo {
  id: string;
  tool: string;
  reason: string;
  preview: string;
  expiresAt: number;
}

export interface SelectionInfo {
  provider: string;
  model: string;
  reasoningEffort?: string;
}

export interface ModelOption {
  id: string;
  name: string;
}

export interface ProviderOption {
  id: string;
  name: string;
  models: ModelOption[];
}

export interface ModelCatalog {
  ok: boolean;
  sessionId: string;
  providers: ProviderOption[];
  selection?: SelectionInfo;
  error?: string;
}

export interface StateSnapshot {
  ok: boolean;
  name: string;
  version: string;
  now: number;
  remote: string;
  lan?: string[];
  selected?: SessionInfo;
  sessions: SessionInfo[];
  pending: PendingInfo[];
  lastSeq: number;
  events: DshEvent[];
  selection?: SelectionInfo;
}

export interface SessionsSnapshot {
  ok: boolean;
  selectedId: string;
  sessions: SessionInfo[];
}

export interface SimpleResult {
  ok: boolean;
  error?: string;
  token?: string;
  host?: string;
  port?: number;
  addresses?: string[];
}
