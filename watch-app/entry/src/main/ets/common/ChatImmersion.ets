// Pure input state machine. The caller owns chrome animation and crown quiet timers.
export class ChatChromeController {
  private readonly changed: (hidden: boolean) => void;
  private hidden: boolean = false;
  private touching: boolean = false;
  private dragging: boolean = false;
  private crownActive: boolean = false;
  private startX: number = 0;
  private startY: number = 0;

  constructor(changed: (hidden: boolean) => void) {
    this.changed = changed;
  }

  // A fresh touch takes over from an old crown gesture, but is not yet a drag.
  touchStart(x: number, y: number): void {
    this.touching = true;
    this.dragging = false;
    this.crownActive = false;
    this.startX = x;
    this.startY = y;
    this.syncHidden();
  }

  touchMove(x: number, y: number, minDistance: number = 6): void {
    if (!this.touching || this.dragging) { return; }
    const dx: number = Math.abs(x - this.startX);
    const dy: number = Math.abs(y - this.startY);
    if (dy >= minDistance && dy > dx * 1.2) {
      this.dragging = true;
      this.syncHidden();
    }
  }

  // Both UP and CANCEL release immediately; momentum is not an active source.
  touchEnd(): void {
    this.touching = false;
    this.dragging = false;
    this.syncHidden();
  }

  crownUpdate(): void {
    this.crownActive = true;
    this.syncHidden();
  }

  crownEnd(): void {
    this.crownActive = false;
    this.syncHidden();
  }

  reset(): void {
    this.touching = false;
    this.dragging = false;
    this.crownActive = false;
    this.startX = 0;
    this.startY = 0;
    this.syncHidden();
  }

  isHidden(): boolean {
    return this.hidden;
  }

  private syncHidden(): void {
    const hidden: boolean = this.dragging || this.crownActive;
    if (hidden === this.hidden) { return; }
    this.hidden = hidden;
    this.changed(hidden);
  }
}
