import { createHash } from 'crypto';

// APNs の apns-collapse-id は最大 64 bytes。長い Codex セッション識別子は
// 固定長ハッシュに置換し、通知自体が BadCollapseId で拒否されるのを防ぐ。
export function makeCollapseId(target: string | undefined, slot?: number): string | undefined {
  if (!target) return undefined;
  const suffix = slot === undefined ? '' : `:${slot}`;
  const raw = `relay:${target}${suffix}`;
  if (Buffer.byteLength(raw, 'utf8') <= 64) return raw;

  const digest = createHash('sha256').update(target).digest('hex').slice(0, 40);
  return `relay:h:${digest}${suffix}`;
}
