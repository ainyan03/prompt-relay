import webpush from 'web-push';
import type { WebPushSubscription } from './store.js';

let configured = false;

export function initWebPush(): void {
  const publicKey = process.env.VAPID_PUBLIC_KEY;
  const privateKey = process.env.VAPID_PRIVATE_KEY;
  const subject = process.env.VAPID_SUBJECT;

  if (!publicKey || !privateKey || !subject) return;

  webpush.setVapidDetails(subject, publicKey, privateKey);
  configured = true;
}

export function isConfigured(): boolean {
  return configured;
}

export function getVapidPublicKey(): string | undefined {
  return process.env.VAPID_PUBLIC_KEY;
}

interface WebPushPayload {
  title: string;
  subtitle?: string;
  body: string;
  tag?: string;
  data?: Record<string, unknown>;
}

export async function sendWebPushNotification(
  subscription: WebPushSubscription,
  payload: WebPushPayload,
): Promise<void> {
  const pushPayload = JSON.stringify({
    title: payload.title,
    body: payload.body,
    subtitle: payload.subtitle,
    ...(payload.tag && { tag: payload.tag }),
    data: payload.data || {},
  });

  await webpush.sendNotification(subscription, pushPayload, { TTL: 120 });
}
