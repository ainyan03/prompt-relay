const MAX_EVENT_IDS = 4096;

export class NotificationDedupe {
  private readonly seen = new Map<string, true>();

  accept(scope: string, eventId: unknown): boolean {
    if (typeof eventId !== 'string' || eventId.length === 0 || eventId.length > 256) {
      return true;
    }

    const key = JSON.stringify([scope, eventId]);
    if (this.seen.has(key)) return false;

    this.seen.set(key, true);
    while (this.seen.size > MAX_EVENT_IDS) {
      const oldest = this.seen.keys().next().value;
      if (oldest === undefined) break;
      this.seen.delete(oldest);
    }
    return true;
  }
}
