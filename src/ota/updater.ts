/**
 * OTA 下载与落盘（Spike 闭环）
 *
 * 链路：清单 → 下载到 tmp → 校验大小与 sha256 → 旧包改名备份 → tmp 晋升 → 写 meta → 重启生效。
 * 失败一律「删 tmp、保留旧包」，绝不留半新半旧的 bundle。
 *
 * 与 native 侧的契约（MainApplication.kt）：
 *   加载 `<filesDir>/ota/index.android.bundle`，不存在则回落包内。
 *   所以「回滚」= 删掉这个文件。
 */

import RNFS from 'react-native-fs';
import { candidateUrls, isBundleApplicable, type OtaManifest } from './manifest';

const OTA_DIR = `${RNFS.DocumentDirectoryPath}/ota`;
const BUNDLE_PATH = `${OTA_DIR}/index.android.bundle`;
const TMP_PATH = `${OTA_DIR}/index.android.bundle.tmp`;
const BACKUP_PATH = `${OTA_DIR}/index.android.bundle.bak`;
const META_PATH = `${OTA_DIR}/meta.json`;
const BOOT_PATH = `${OTA_DIR}/boot.json`;

export type OtaState = {
  active: boolean;
  build: number | null;
  version: string | null;
  appliedAt: string | null;
  bootCount: number;
};

export type ApplyResult =
  | { ok: true; build: number; version: string; bytes: number }
  | { ok: false; reason: string };

async function ensureDir(): Promise<void> {
  const exists = await RNFS.exists(OTA_DIR);
  if (!exists) await RNFS.mkdir(OTA_DIR);
}

async function readJson<T>(path: string): Promise<T | null> {
  try {
    if (!(await RNFS.exists(path))) return null;
    return JSON.parse(await RNFS.readFile(path, 'utf8')) as T;
  } catch {
    return null;
  }
}

async function writeJson(path: string, value: unknown): Promise<void> {
  await RNFS.writeFile(path, JSON.stringify(value), 'utf8');
}

export async function readState(): Promise<OtaState> {
  const meta = await readJson<{ build: number; version: string; appliedAt: string }>(META_PATH);
  const boot = await readJson<{ count: number }>(BOOT_PATH);
  const active = await RNFS.exists(BUNDLE_PATH);
  return {
    active,
    build: meta?.build ?? null,
    version: meta?.version ?? null,
    appliedAt: meta?.appliedAt ?? null,
    bootCount: boot?.count ?? 0,
  };
}

/** 拉清单并判断是否适用；不做下载。 */
export async function checkForUpdate(
  baseUrl: string,
  appVersion: string,
  localBuild: number,
): Promise<{ ok: true; manifest: OtaManifest } | { ok: false; reason: string }> {
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 8000);
    const res = await fetch(`${baseUrl}/manifest.json`, {
      signal: controller.signal,
      headers: { 'Cache-Control': 'no-cache' },
    });
    clearTimeout(timer);
    if (!res.ok) return { ok: false, reason: `清单 HTTP ${res.status}` };

    const manifest = (await res.json()) as OtaManifest;
    const verdict = isBundleApplicable(manifest, appVersion, localBuild);
    return verdict.ok ? { ok: true, manifest } : { ok: false, reason: verdict.reason ?? '不适用' };
  } catch (e) {
    return { ok: false, reason: `清单获取失败: ${e instanceof Error ? e.message : String(e)}` };
  }
}

/**
 * 下载并原子应用。任一步失败都保留旧包。
 */
export async function downloadAndApply(manifest: OtaManifest): Promise<ApplyResult> {
  const download = manifest.bundle.downloads['android-arm64-v8a'];
  if (!download) return { ok: false, reason: '清单里没有 android-arm64-v8a 产物' };

  try {
    await ensureDir();
    if (await RNFS.exists(TMP_PATH)) await RNFS.unlink(TMP_PATH);

    let lastError = '';
    for (const url of candidateUrls(download)) {
      try {
        const result = await RNFS.downloadFile({ fromUrl: url, toFile: TMP_PATH }).promise;
        if (result.statusCode !== 200) {
          lastError = `HTTP ${result.statusCode}`;
          continue;
        }
        const stat = await RNFS.stat(TMP_PATH);
        if (Number(stat.size) !== download.sizeBytes) {
          lastError = `大小不符: ${stat.size} != ${download.sizeBytes}`;
          await RNFS.unlink(TMP_PATH);
          continue;
        }
        const hash = await RNFS.hash(TMP_PATH, 'sha256');
        if (hash.toLowerCase() !== download.sha256.toLowerCase()) {
          lastError = 'sha256 不符';
          await RNFS.unlink(TMP_PATH);
          continue;
        }

        // 旧包先留备份，晋升失败可以还原
        if (await RNFS.exists(BUNDLE_PATH)) {
          if (await RNFS.exists(BACKUP_PATH)) await RNFS.unlink(BACKUP_PATH);
          await RNFS.moveFile(BUNDLE_PATH, BACKUP_PATH);
        }
        await RNFS.moveFile(TMP_PATH, BUNDLE_PATH);
        await writeJson(META_PATH, {
          build: manifest.bundle.build,
          version: manifest.bundle.version,
          sha256: download.sha256,
          appliedAt: new Date().toISOString(),
        });
        // 新包首次启动，计数从 0 开始
        await writeJson(BOOT_PATH, { count: 0 });

        return {
          ok: true,
          build: manifest.bundle.build,
          version: manifest.bundle.version,
          bytes: download.sizeBytes,
        };
      } catch (e) {
        lastError = e instanceof Error ? e.message : String(e);
      }
    }
    return { ok: false, reason: `全部源失败: ${lastError}` };
  } catch (e) {
    return { ok: false, reason: `落盘失败: ${e instanceof Error ? e.message : String(e)}` };
  }
}

/** 回滚：删掉覆盖包（保留备份文件不影响，native 只看 index.android.bundle）。 */
export async function rollback(): Promise<void> {
  if (await RNFS.exists(BUNDLE_PATH)) await RNFS.unlink(BUNDLE_PATH);
  if (await RNFS.exists(BACKUP_PATH)) await RNFS.unlink(BACKUP_PATH);
  if (await RNFS.exists(META_PATH)) await RNFS.unlink(META_PATH);
  if (await RNFS.exists(BOOT_PATH)) await RNFS.unlink(BOOT_PATH);
}

/**
 * 启动计数：JS 能跑起来说明 bundle 至少「能加载」，但仍然可能启动后崩。
 * 连续 3 次没被 markHealthy 清零，就自动回滚。
 */
export async function noteBoot(): Promise<{ rolledBack: boolean; count: number }> {
  const active = await RNFS.exists(BUNDLE_PATH);
  if (!active) return { rolledBack: false, count: 0 };

  const boot = (await readJson<{ count: number }>(BOOT_PATH)) ?? { count: 0 };
  const count = boot.count + 1;
  await writeJson(BOOT_PATH, { count });

  if (count >= 3) {
    await rollback();
    return { rolledBack: true, count };
  }
  return { rolledBack: false, count };
}

/** 渲染成功后调用，清掉启动计数。 */
export async function markHealthy(): Promise<void> {
  if (!(await RNFS.exists(BOOT_PATH))) return;
  await writeJson(BOOT_PATH, { count: 0 });
  // 新包已经稳定跑起来，旧的备份可以丢了（省 900KB 左右）
  if (await RNFS.exists(BACKUP_PATH)) {
    await RNFS.unlink(BACKUP_PATH).catch(() => undefined);
  }
}
