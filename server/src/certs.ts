import forge from 'node-forge';
import crypto from 'crypto';
import fs from 'fs';
import path from 'path';
import os from 'os';

const CERTS_DIR = path.resolve('certs');
const CA_CERT_PATH = path.join(CERTS_DIR, 'PromptRelay-CA.pem');
const CA_KEY_PATH = path.join(CERTS_DIR, 'PromptRelay-CA-key.pem');
const SERVER_CERT_PATH = path.join(CERTS_DIR, 'server.pem');
const SERVER_KEY_PATH = path.join(CERTS_DIR, 'server-key.pem');

// 外部証明書を使用中（Host 自動検出をスキップ）
let usingExternalCert = false;
// 現在の証明書がカバーする SAN 一覧
let currentSans: Set<string> = new Set();
// 動的に検出された追加 SAN（Host ヘッダー由来）
const dynamicSans: Set<string> = new Set();

function isIPAddress(s: string): boolean {
  return /^\d{1,3}(\.\d{1,3}){3}$/.test(s);
}

function parseExtraSans(): string[] {
  const extra = process.env.HTTPS_EXTRA_SANS;
  if (!extra) return [];
  return extra.split(',').map(s => s.trim()).filter(Boolean);
}

/** 指定ホスト名が現在の証明書 SAN に含まれるか */
export function isSanCovered(hostname: string): boolean {
  if (usingExternalCert) return true;
  return currentSans.has(hostname.toLowerCase());
}

/** 動的に追加された SAN の数を返す */
export function dynamicSanCount(): number {
  return dynamicSans.size;
}

/** 新しい SAN を追加してサーバ証明書を再生成 */
export function regenerateCert(newSans: string[]): CertPaths | null {
  for (const san of newSans) {
    dynamicSans.add(san);
  }

  if (!fs.existsSync(CA_CERT_PATH) || !fs.existsSync(CA_KEY_PATH)) {
    return null;
  }

  const caCert = forge.pki.certificateFromPem(fs.readFileSync(CA_CERT_PATH, 'utf8'));
  const caKey = forge.pki.privateKeyFromPem(fs.readFileSync(CA_KEY_PATH, 'utf8'));

  const lanIPs = getLanIPs();
  const allExtra = [...parseExtraSans(), ...dynamicSans];
  const server = generateServerCert(caCert, caKey, lanIPs, allExtra);

  fs.writeFileSync(SERVER_CERT_PATH, forge.pki.certificateToPem(server.cert));
  fs.writeFileSync(SERVER_KEY_PATH, forge.pki.privateKeyToPem(server.key), { mode: 0o600 });

  return { cert: SERVER_CERT_PATH, key: SERVER_KEY_PATH, ca: CA_CERT_PATH };
}

export function getLanIPs(): string[] {
  const interfaces = os.networkInterfaces();
  const ips: string[] = [];
  for (const iface of Object.values(interfaces)) {
    if (!iface) continue;
    for (const info of iface) {
      if (info.family === 'IPv4' && !info.internal) {
        ips.push(info.address);
      }
    }
  }
  return ips;
}

function generateCA(): { cert: forge.pki.Certificate; key: forge.pki.rsa.PrivateKey } {
  console.log('[certs] Generating local CA...');
  const { publicKey: pubPem, privateKey: privPem } = crypto.generateKeyPairSync('rsa', {
    modulusLength: 2048,
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  });
  const publicKey = forge.pki.publicKeyFromPem(pubPem);
  const privateKey = forge.pki.privateKeyFromPem(privPem);

  const cert = forge.pki.createCertificate();
  cert.publicKey = publicKey;
  cert.serialNumber = '01';
  cert.validity.notBefore = new Date();
  cert.validity.notAfter = new Date();
  cert.validity.notAfter.setFullYear(cert.validity.notBefore.getFullYear() + 10);

  const attrs = [{ name: 'commonName', value: 'Prompt Relay Local CA' }];
  cert.setSubject(attrs);
  cert.setIssuer(attrs);
  cert.setExtensions([
    { name: 'basicConstraints', cA: true },
    { name: 'keyUsage', keyCertSign: true, cRLSign: true },
  ]);
  cert.sign(privateKey, forge.md.sha256.create());

  return { cert, key: privateKey };
}

function generateServerCert(
  caCert: forge.pki.Certificate,
  caKey: forge.pki.rsa.PrivateKey,
  ips: string[],
  extraSans: string[] = [],
): { cert: forge.pki.Certificate; key: forge.pki.rsa.PrivateKey } {
  // SAN を重複排除で収集
  const sanSet = new Set<string>();
  sanSet.add('localhost');
  sanSet.add('127.0.0.1');
  for (const ip of ips) sanSet.add(ip);
  for (const san of extraSans) sanSet.add(san);

  console.log(`[certs] Generating server cert for: ${[...sanSet].join(', ')}`);
  const { publicKey: pubPem, privateKey: privPem } = crypto.generateKeyPairSync('rsa', {
    modulusLength: 2048,
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  });
  const publicKey = forge.pki.publicKeyFromPem(pubPem);
  const privateKey = forge.pki.privateKeyFromPem(privPem);

  const cert = forge.pki.createCertificate();
  cert.publicKey = publicKey;
  cert.serialNumber = String(Date.now());
  cert.validity.notBefore = new Date();
  cert.validity.notAfter = new Date();
  cert.validity.notAfter.setFullYear(cert.validity.notBefore.getFullYear() + 1);

  const attrs = [{ name: 'commonName', value: 'prompt-relay' }];
  cert.setSubject(attrs);
  cert.setIssuer(caCert.subject.attributes);

  const altNames: Array<{ type: number; value?: string; ip?: string }> = [];
  for (const san of sanSet) {
    if (isIPAddress(san)) {
      altNames.push({ type: 7, ip: san });   // X.509 SAN type 7 = IPAddress
    } else {
      altNames.push({ type: 2, value: san }); // X.509 SAN type 2 = DNSName
    }
  }

  cert.setExtensions([
    { name: 'subjectAltName', altNames } as any,
    { name: 'keyUsage', digitalSignature: true, keyEncipherment: true },
    { name: 'extKeyUsage', serverAuth: true },
  ]);
  cert.sign(caKey, forge.md.sha256.create());

  // 現在の SAN を追跡
  currentSans = new Set([...sanSet].map(s => s.toLowerCase()));

  return { cert, key: privateKey };
}

export interface CertPaths {
  cert: string;
  key: string;
  ca: string;
}

export function ensureCerts(): CertPaths | null {
  // 手動設定の証明書がある場合はそちらを使う（Host 自動検出も無効化）
  if (process.env.HTTPS_CERT_PATH && process.env.HTTPS_KEY_PATH) {
    usingExternalCert = true;
    console.log('[certs] Using external certificate, auto-detection disabled');
    return {
      cert: process.env.HTTPS_CERT_PATH,
      key: process.env.HTTPS_KEY_PATH,
      ca: CA_CERT_PATH,
    };
  }

  fs.mkdirSync(CERTS_DIR, { recursive: true });

  const lanIPs = getLanIPs();
  const extraSans = parseExtraSans();

  // CA の読み込みまたは生成
  let caCert: forge.pki.Certificate;
  let caKey: forge.pki.rsa.PrivateKey;

  if (fs.existsSync(CA_CERT_PATH) && fs.existsSync(CA_KEY_PATH)) {
    console.log('[certs] Using existing CA');
    caCert = forge.pki.certificateFromPem(fs.readFileSync(CA_CERT_PATH, 'utf8'));
    caKey = forge.pki.privateKeyFromPem(fs.readFileSync(CA_KEY_PATH, 'utf8'));
  } else {
    const ca = generateCA();
    caCert = ca.cert;
    caKey = ca.key;
    fs.writeFileSync(CA_CERT_PATH, forge.pki.certificateToPem(caCert));
    fs.writeFileSync(CA_KEY_PATH, forge.pki.privateKeyToPem(caKey), { mode: 0o600 });
    console.log(`[certs] CA saved to ${CA_CERT_PATH}`);
  }

  // サーバ証明書は毎回再生成（IP 変更に対応）
  const server = generateServerCert(caCert, caKey, lanIPs, extraSans);
  fs.writeFileSync(SERVER_CERT_PATH, forge.pki.certificateToPem(server.cert));
  fs.writeFileSync(SERVER_KEY_PATH, forge.pki.privateKeyToPem(server.key), { mode: 0o600 });

  return {
    cert: SERVER_CERT_PATH,
    key: SERVER_KEY_PATH,
    ca: CA_CERT_PATH,
  };
}
