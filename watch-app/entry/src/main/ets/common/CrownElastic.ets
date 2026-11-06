// UI-independent crown elasticity. Positive delta means increasing scroll offset;
// positive stretch means translating the scrollable content down. Callers own
// native scrollTo({ animation: false }), bounds and the translated content layer.
export class CrownElastic {
  private pull: number = 0;
  private stretch: number = 0;
  private velocity: number = 0;
  private springTimer: number = -1;
  private readonly resistance: number = 0.45;
  private readonly limit: number;
  private readonly onStretch: (stretch: number) => void;

  constructor(onStretch: (stretch: number) => void, maxStretch: number = 36) {
    this.onStretch = onStretch;
    this.limit = Math.max(1, maxStretch);
  }

  // Interrupt a release without snapping: the next UPDATE can reverse it.
  begin(): void {
    this.stopSpring();
    this.velocity = 0;
  }

  update(delta: number, offset: number, min: number, max: number): number {
    this.begin();
    const lower: number = Math.min(min, max);
    const upper: number = Math.max(min, max);
    let position: number = Math.max(lower, Math.min(upper, offset));
    let remaining: number = delta;
    if (this.pull !== 0) {
      const combined: number = this.pull + remaining;
      if (combined * this.pull >= 0) {
        this.pull = combined;
        remaining = 0;
      } else {
        remaining = combined;
        this.pull = 0;
      }
    }
    if (remaining !== 0) {
      const target: number = position + remaining;
      position = Math.max(lower, Math.min(upper, target));
      this.pull += target - position;
    }
    // Bound even an unbroken rotation; never accumulate an unbounded reverse debt.
    this.pull = Math.max(-this.limit * 8, Math.min(this.limit * 8, this.pull));
    this.stretch = -this.limit * this.pull / (this.limit / this.resistance + Math.abs(this.pull));
    this.onStretch(this.stretch);
    return position;
  }

  // For a Scroller without a known content extent. Unknown edges remain free;
  // callers may feed a native scrollBy remainder back with its confirmed edge.
  updateAtEdges(delta: number, offset: number, atStart: boolean, atEnd: boolean): number {
    const lower: number = atStart ? offset : Math.min(offset, offset + delta);
    const upper: number = atEnd ? offset : Math.max(offset, offset + delta);
    return this.update(delta, offset, lower, upper);
  }

  // Exactly one timer after END, none during UPDATE, no animateTo restarts.
  end(): void {
    if (this.springTimer !== -1 || this.stretch === 0) { return; }
    this.springTimer = setInterval(() => { this.springStep(); }, 16);
  }

  // Required on touch takeover, page hide and component destruction.
  cancel(): void {
    this.stopSpring();
    this.pull = 0;
    this.velocity = 0;
    this.stretch = 0;
    this.onStretch(0);
  }

  private stopSpring(): void {
    if (this.springTimer !== -1) {
      clearInterval(this.springTimer);
      this.springTimer = -1;
    }
  }

  private springStep(): void {
    // Critically damped spring, integrated at a fixed 16 ms timestep.
    this.velocity += (-484 * this.stretch - 44 * this.velocity) * 0.016;
    this.stretch += this.velocity * 0.016;
    if (Math.abs(this.stretch) < 0.05 && Math.abs(this.velocity) < 0.5) {
      this.cancel();
      return;
    }
    // Keep pull synchronized so BEGIN or UPDATE mid-release can reverse smoothly.
    this.pull = -this.stretch * (this.limit / this.resistance) /
      Math.max(0.001, this.limit - Math.abs(this.stretch));
    this.onStretch(this.stretch);
  }
}
