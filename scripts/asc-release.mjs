#!/usr/bin/env node
// App Store Connect release driver — zero-dep.
//
// Fills the gap left by having no fastlane: takes an already-uploaded build
// (see scripts/release-testflight.sh) and drives it through App Store review +
// release via the App Store Connect API.
//
// Reads `Key ID` / `Issuer ID` from ./.env and the matching private key from
// ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8.
//
// Usage:
//   node scripts/asc-release.mjs status              # read-only: app / build / version state
//   node scripts/asc-release.mjs submit              # submit for review, auto-release after approval
//   node scripts/asc-release.mjs submit --manual     # submit for review, manual release after approval
//
// Release target comes from environment variables, falling back to project.yml.

import { existsSync, readFileSync } from 'node:fs';
import { sign as cryptoSign, createPrivateKey } from 'node:crypto';
import { homedir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));

function envValue(label) {
  const envPath = join(__dirname, '..', '.env');
  if (!existsSync(envPath)) return null;
  const env = readFileSync(envPath, 'utf8');
  const escaped = label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const m = env.match(new RegExp('^' + escaped + '\\s*=\\s*(.+)$', 'm'));
  return m ? m[1].trim() : null;
}

function projectSetting(key) {
  const yml = readFileSync(join(__dirname, '..', 'project.yml'), 'utf8');
  const m = yml.match(new RegExp(`^\\s*${key}:\\s*"?([^"\\n]+)"?\\s*$`, 'm'));
  if (!m) throw new Error(`Missing ${key} in project.yml`);
  return m[1].trim();
}

const BUNDLE_ID = process.env.ASC_BUNDLE_ID || envValue('Bundle ID') || 'com.korteqo.app.ios';
const VERSION = process.env.ASC_RELEASE_VERSION || projectSetting('MARKETING_VERSION');
const BUILD = process.env.ASC_RELEASE_BUILD || projectSetting('CURRENT_PROJECT_VERSION');
const ASC = 'https://api.appstoreconnect.apple.com';

// "What's New" shown on the App Store, per locale.
const WHATS_NEW = {
  'zh-Hans': process.env.ASC_WHATS_NEW_ZH_HANS ||
    '本次更新将应用品牌更新为 DeepSeno（思维匣子），并同步新的隐私政策与技术支持页面。\n\n- 优化本地录音、照片、视频和文字捕捉体验\n- 保留局域网配对与本地 AI 处理流程\n- 改进连接稳定性和上传队列说明\n- 全部功能免费，无需登录、无订阅',
  'en-US': process.env.ASC_WHATS_NEW_EN_US ||
    'This update refreshes the app brand to DeepSeno and updates the privacy policy and support pages.\n\n- Improves local audio, photo, video, and text capture\n- Keeps LAN pairing and local AI processing flows\n- Improves connection stability and upload queue messaging\n- All features are free, with no login, subscription, or VIP tier',
};

// ── Auth ────────────────────────────────────────────────────────────────
function loadCreds() {
  const keyId = envValue('Key ID');
  const issuerId = envValue('Issuer ID');
  if (!keyId || !issuerId) throw new Error('.env must contain "Key ID=" and "Issuer ID=" lines');
  const p8Path = join(homedir(), '.appstoreconnect', 'private_keys', `AuthKey_${keyId}.p8`);
  const privateKeyBase64 = envValue('Private Key Base64') || process.env.APP_STORE_CONNECT_PRIVATE_KEY_BASE64;
  const p8 = existsSync(p8Path)
    ? readFileSync(p8Path, 'utf8')
    : Buffer.from(privateKeyBase64 || '', 'base64').toString('utf8');
  if (!p8.trim()) {
    throw new Error(`Missing private key at ${p8Path}, or "Private Key Base64=" in .env`);
  }
  return { keyId, issuerId, p8 };
}

const b64url = (buf) =>
  Buffer.from(buf).toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');

function makeJWT({ keyId, issuerId, p8 }) {
  const header = { alg: 'ES256', kid: keyId, typ: 'JWT' };
  const now = Math.floor(Date.now() / 1000);
  const payload = { iss: issuerId, iat: now, exp: now + 1200, aud: 'appstoreconnect-v1' };
  const input = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`;
  // ES256 JWS wants the raw R||S (P1363) signature, not DER.
  const sig = cryptoSign('SHA256', Buffer.from(input), {
    key: createPrivateKey(p8),
    dsaEncoding: 'ieee-p1363',
  });
  return `${input}.${b64url(sig)}`;
}

// ── REST helper ─────────────────────────────────────────────────────────
let TOKEN;
async function api(method, path, body) {
  const res = await fetch(ASC + path, {
    method,
    headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json;
  try { json = text ? JSON.parse(text) : {}; } catch { json = { raw: text }; }
  if (!res.ok) {
    throw new Error(`${method} ${path} → ${res.status}\n${JSON.stringify(json, null, 2)}`);
  }
  return json;
}

// ── Lookups ─────────────────────────────────────────────────────────────
async function getApp() {
  const r = await api('GET', `/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}`);
  if (!r.data?.length) throw new Error(`No app for bundle id ${BUNDLE_ID}`);
  return r.data[0];
}

async function getBuild(appId) {
  const r = await api(
    'GET',
    `/v1/builds?filter[app]=${appId}&filter[preReleaseVersion.version]=${VERSION}&filter[version]=${BUILD}&limit=10`,
  );
  return r.data?.[0] || null;
}

async function getEditableVersion(appId) {
  const r = await api(
    'GET',
    `/v1/apps/${appId}/appStoreVersions?filter[versionString]=${VERSION}&limit=5`,
  );
  return r.data?.[0] || null;
}

async function getLocalizations(versionId) {
  const r = await api('GET', `/v1/appStoreVersions/${versionId}/appStoreVersionLocalizations?limit=50`);
  return r.data || [];
}

// ── Commands ────────────────────────────────────────────────────────────
async function status() {
  const app = await getApp();
  console.log(`App: ${app.attributes.name} (${app.attributes.bundleId}) id=${app.id}`);

  const build = await getBuild(app.id);
  if (!build) {
    console.log(`Build ${VERSION} (${BUILD}): NOT FOUND yet (still uploading / indexing?)`);
  } else {
    console.log(
      `Build ${VERSION} (${BUILD}): id=${build.id} processingState=${build.attributes.processingState} ` +
        `usesNonExemptEncryption=${build.attributes.usesNonExemptEncryption}`,
    );
  }

  const ver = await getEditableVersion(app.id);
  if (!ver) {
    console.log(`App Store version ${VERSION}: does NOT exist yet (will be created on submit)`);
  } else {
    console.log(
      `App Store version ${VERSION}: id=${ver.id} state=${ver.attributes.appStoreState} ` +
        `releaseType=${ver.attributes.releaseType}`,
    );
    const locs = await getLocalizations(ver.id);
    for (const l of locs) {
      const w = (l.attributes.whatsNew || '').replace(/\n/g, ' / ').slice(0, 60);
      console.log(`  • ${l.attributes.locale}: whatsNew="${w}${w.length >= 60 ? '…' : ''}"`);
    }
  }
}

// ── Submit ──────────────────────────────────────────────────────────────
async function setExportCompliance(buildId) {
  // Relay traffic uses only standard TLS via Apple APIs → exempt encryption.
  await api('PATCH', `/v1/builds/${buildId}`, {
    data: { type: 'builds', id: buildId, attributes: { usesNonExemptEncryption: false } },
  });
}

async function createVersion(appId, releaseType) {
  const r = await api('POST', '/v1/appStoreVersions', {
    data: {
      type: 'appStoreVersions',
      attributes: { platform: 'IOS', versionString: VERSION, releaseType },
      relationships: { app: { data: { type: 'apps', id: appId } } },
    },
  });
  return r.data;
}

async function linkBuild(versionId, buildId) {
  await api('PATCH', `/v1/appStoreVersions/${versionId}/relationships/build`, {
    data: { type: 'builds', id: buildId },
  });
}

async function setWhatsNew(versionId) {
  // Only update locales that ALREADY exist on the version (inherited from the
  // previous release, so they carry the required description/keywords/supportUrl).
  // Never create a new locale here — a locale with only whatsNew is missing
  // those required attributes and blocks submission.
  const locs = await getLocalizations(versionId);
  const byLocale = Object.fromEntries(locs.map((l) => [l.attributes.locale, l]));
  for (const [locale, text] of Object.entries(WHATS_NEW)) {
    const existing = byLocale[locale];
    if (!existing) {
      console.log(`   (skip ${locale}: not a listed locale on this app)`);
      continue;
    }
    await api('PATCH', `/v1/appStoreVersionLocalizations/${existing.id}`, {
      data: { type: 'appStoreVersionLocalizations', id: existing.id, attributes: { whatsNew: text } },
    });
  }
}

// Count screenshots across all localizations — Apple rejects a submission with none.
async function countScreenshots(versionId) {
  const locs = await getLocalizations(versionId);
  let total = 0;
  for (const l of locs) {
    const sets = await api('GET', `/v1/appStoreVersionLocalizations/${l.id}/appScreenshotSets?limit=50`);
    for (const s of sets.data || []) {
      const shots = await api('GET', `/v1/appScreenshotSets/${s.id}/appScreenshots?limit=50`);
      total += (shots.data || []).length;
    }
  }
  return total;
}

async function submitForReview(appId, versionId) {
  let subId;
  try {
    const r = await api('POST', '/v1/reviewSubmissions', {
      data: {
        type: 'reviewSubmissions',
        attributes: { platform: 'IOS' },
        relationships: { app: { data: { type: 'apps', id: appId } } },
      },
    });
    subId = r.data.id;
  } catch (e) {
    // An open submission may already exist — reuse it.
    const open = await api('GET', `/v1/reviewSubmissions?filter[app]=${appId}&filter[platform]=IOS&limit=10`);
    const reusable = (open.data || []).find((s) => !s.attributes.submitted);
    if (!reusable) throw e;
    subId = reusable.id;
  }
  try {
    await api('POST', '/v1/reviewSubmissionItems', {
      data: {
        type: 'reviewSubmissionItems',
        relationships: {
          reviewSubmission: { data: { type: 'reviewSubmissions', id: subId } },
          appStoreVersion: { data: { type: 'appStoreVersions', id: versionId } },
        },
      },
    });
  } catch (e) {
    if (!String(e.message).includes('409')) throw e;
    console.log('→ Review submission item already exists; reusing draft item');
  }
  await api('PATCH', `/v1/reviewSubmissions/${subId}`, {
    data: { type: 'reviewSubmissions', id: subId, attributes: { submitted: true } },
  });
  return subId;
}

async function submit(manual) {
  const releaseType = manual ? 'MANUAL' : 'AFTER_APPROVAL';
  const app = await getApp();
  const build = await getBuild(app.id);
  if (!build) throw new Error(`Build ${VERSION} (${BUILD}) not found`);
  if (build.attributes.processingState !== 'VALID')
    throw new Error(`Build not ready: processingState=${build.attributes.processingState} (wait & retry)`);

  if (build.attributes.usesNonExemptEncryption === null) {
    console.log('→ Export compliance: usesNonExemptEncryption=false (standard TLS)');
    await setExportCompliance(build.id);
  } else {
    console.log(`→ Export compliance already set (usesNonExemptEncryption=${build.attributes.usesNonExemptEncryption})`);
  }

  let ver = await getEditableVersion(app.id);
  if (!ver) {
    console.log(`→ Creating App Store version ${VERSION} (releaseType=${releaseType})`);
    ver = await createVersion(app.id, releaseType);
  } else {
    console.log(`→ Reusing version ${VERSION} (state=${ver.attributes.appStoreState}); setting releaseType=${releaseType}`);
    await api('PATCH', `/v1/appStoreVersions/${ver.id}`, {
      data: { type: 'appStoreVersions', id: ver.id, attributes: { releaseType } },
    });
  }

  console.log('→ Linking build to version');
  await linkBuild(ver.id, build.id);

  console.log('→ Writing "What\'s New" (zh-Hans, en-US)');
  await setWhatsNew(ver.id);

  const shots = await countScreenshots(ver.id);
  console.log(`→ Screenshots on version: ${shots}`);
  if (shots === 0) {
    throw new Error(
      'No screenshots on version ' + VERSION + '. Apple requires at least one and they did NOT ' +
        'carry over via API. Add them in App Store Connect (Copy from previous version), then re-run `submit`.',
    );
  }

  console.log('→ Submitting for review');
  const subId = await submitForReview(app.id, ver.id);
  console.log(`\n✅ Submitted for review (reviewSubmission ${subId}).`);
  console.log(releaseType === 'AFTER_APPROVAL'
    ? '   Will auto-release to the App Store once Apple approves.'
    : '   After approval, release manually in App Store Connect.');
}

main().catch((e) => {
  console.error('❌', e.message);
  process.exit(1);
});

async function locales() {
  const app = await getApp();
  const versions = await api('GET', `/v1/apps/${app.id}/appStoreVersions?limit=10`);
  for (const v of versions.data || []) {
    console.log(`\nVersion ${v.attributes.versionString} (${v.attributes.appStoreState}) id=${v.id}`);
    const locs = await getLocalizations(v.id);
    for (const l of locs) {
      const a = l.attributes;
      console.log(
        `  ${l.attributes.locale} [${l.id}]  desc=${a.description ? 'Y' : 'NULL'} ` +
          `kw=${a.keywords ? 'Y' : 'NULL'} support=${a.supportUrl ? 'Y' : 'NULL'} ` +
          `whatsNew=${a.whatsNew ? 'Y' : 'NULL'}`,
      );
    }
  }
}

async function main() {
  TOKEN = makeJWT(loadCreds());
  const cmd = process.argv[2] || 'status';
  if (cmd === 'status') return status();
  if (cmd === 'locales') return locales();
  if (cmd === 'rmloc') {
    const id = process.argv[3];
    if (!id) throw new Error('rmloc needs a localization id');
    await api('DELETE', `/v1/appStoreVersionLocalizations/${id}`);
    console.log(`Deleted localization ${id}`);
    return;
  }
  if (cmd === 'submit') return submit(process.argv.includes('--manual'));
  throw new Error(`Unknown command: ${cmd}`);
}
