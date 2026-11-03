import { DshEvent, StateSnapshot } from './Types';

// 运行状态已显示在顶栏，不用重复的开始/结束行淹没真正的回复。
export function visibleFeedEvents(events: DshEvent[]): DshEvent[] {
  const out: DshEvent[] = [];
  for (let i = 0; i < events.length; i++) {
    const ev: DshEvent = events[i];
    if (ev.kind === 'title') { continue; }
    const last: DshEvent | undefined = out.length === 0 ? undefined : out[out.length - 1];
    // 相邻的同类状态只保留最后一次，避免刷屏又不必整类隐藏。
    if (last !== undefined && last.kind === ev.kind &&
      (ev.kind === 'status' || (ev.kind === 'turn' && ev.reason !== 'error'))) {
      out[out.length - 1] = ev;
      continue;
    }
    out.push(ev);
  }
  return out;
}

export interface EventFeedState {
  sessionId: string;
  lastSeq: number;
  events: DshEvent[];
}

// 状态接口的窗口是权威数据：即使序号与缓存相同也用快照更新。
// 新会话或宿主序号回退时，不能沿用上一条流的增量游标。
export function reconcileEventFeed(previous: EventFeedState, snap: StateSnapshot): EventFeedState {
  const sessionId: string = snap.selected === undefined ? '' : snap.selected.id;
  const incoming: DshEvent[] = snap.events === undefined ? [] : snap.events;
  let reset: boolean = previous.sessionId !== sessionId || snap.lastSeq < previous.lastSeq;
  if (!reset) {
    // 宿主重启后序号可能恰好相同；时间戳不同也代表新的一代事件流。
    for (let i = 0; i < incoming.length; i++) {
      const fresh: DshEvent = incoming[i];
      if (fresh.sessionId !== sessionId) { continue; }
      for (let j = 0; j < previous.events.length; j++) {
        const cached: DshEvent = previous.events[j];
        if (cached.seq === fresh.seq && cached.t !== fresh.t) {
          reset = true;
          break;
        }
      }
      if (reset) { break; }
    }
  }
  const bySeq: Map<number, DshEvent> = new Map<number, DshEvent>();
  if (!reset) {
    for (let i = 0; i < previous.events.length; i++) {
      const cached: DshEvent = previous.events[i];
      if (cached.sessionId === sessionId) { bySeq.set(cached.seq, cached); }
    }
  }
  for (let i = 0; i < incoming.length; i++) {
    const fresh: DshEvent = incoming[i];
    if (sessionId !== '' && fresh.sessionId === sessionId) { bySeq.set(fresh.seq, fresh); }
  }
  const ordered: DshEvent[] = Array.from(bySeq.values());
  ordered.sort((a: DshEvent, b: DshEvent) => a.seq - b.seq);
  const events: DshEvent[] = [];
  const start: number = Math.max(0, ordered.length - 60);
  for (let i = start; i < ordered.length; i++) {
    const ev: DshEvent = ordered[i];
    let echo: boolean = false;
    if (ev.kind === 'user') {
      for (let j = 0; j < events.length; j++) {
        const prior: DshEvent = events[j];
        // 只合并手表本地回显和宿主回显这对消息，不吞掉主动重复发送。
        if (prior.kind === 'user' && prior.text === ev.text &&
          (prior.fromWatch === true) !== (ev.fromWatch === true) &&
          Math.abs(prior.t - ev.t) < 60000) {
          echo = true;
          break;
        }
      }
    }
    if (!echo) { events.push(ev); }
  }
  return { sessionId: sessionId, lastSeq: snap.lastSeq, events: events };
}
