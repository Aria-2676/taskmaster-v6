/**
 * OTA 清单（Spike 第 3 项的一半：先把「清单契约」定下来）
 *
 * 沿用现有 Flutter 版的清单模型，不引入第三方 OTA 服务：
 *   version / build / url / sha256 / sizeBytes / mirrors
 *
 * 与整包清单的区别：bundle 是 JS + 资源，体积 1–3MB，可以走 jsDelivr；
 * APK 仍必须走 GitHub Releases（jsDelivr 单文件 20MB 上限）。
 */

export type OtaDownload = {
  url: string;
  mirrors?: string[];
  sha256: string;
  sizeBytes: number;
};

export type OtaManifest = {
  schemaVersion: 1;
  bundle: {
    version: string;
    /** 单调递增整数，只增不减 */
    build: number;
    /** bundle 兼容的 native 版本区间，防止跨原生版本乱投 */
    minAppVersion: string;
    maxAppVersion?: string;
    downloads: Record<string, OtaDownload>;
    notes?: string[];
  };
};

/** 候选源顺序：显式镜像 → 兜底源（与整包下载保持一致的去重策略）。 */
export function candidateUrls(download: OtaDownload): string[] {
  const all = [download.url, ...(download.mirrors ?? [])];
  return Array.from(new Set(all.filter(Boolean)));
}

/** 版本比较：只支持 `x.y.z`，返回 -1 / 0 / 1。 */
export function compareVersion(a: string, b: string): number {
  const pa = a.split('.').map((n) => Number.parseInt(n, 10) || 0);
  const pb = b.split('.').map((n) => Number.parseInt(n, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i += 1) {
    const x = pa[i] ?? 0;
    const y = pb[i] ?? 0;
    if (x !== y) return x > y ? 1 : -1;
  }
  return 0;
}

/**
 * 判断某个 bundle 是否能装到当前 App 上。
 *
 * 规则：`minAppVersion <= appVersion`（且若有 `maxAppVersion`，也要满足 `appVersion <= max`），
 * 同时 `build` 必须严格大于本地已装 build——否则会出现「越更新越旧」。
 */
export function isBundleApplicable(
  manifest: OtaManifest,
  appVersion: string,
  localBuild: number,
): { ok: boolean; reason?: string } {
  const b = manifest.bundle;
  if (compareVersion(appVersion, b.minAppVersion) < 0) {
    return { ok: false, reason: `bundle 需要 App >= ${b.minAppVersion}，当前 ${appVersion}` };
  }
  if (b.maxAppVersion && compareVersion(appVersion, b.maxAppVersion) > 0) {
    return { ok: false, reason: `bundle 最高支持 App ${b.maxAppVersion}，当前 ${appVersion}` };
  }
  if (b.build <= localBuild) {
    return { ok: false, reason: `bundle build ${b.build} 不高于本地 ${localBuild}` };
  }
  return { ok: true };
}

/**
 * TODO(Spike)：下载与校验。
 *
 * 需要先定 sha256 实现（RN 无 node:crypto）——候选：
 * `react-native-quick-crypto` 或纯 JS 实现。校验不通过必须删包换源，
 * 与整包下载的策略一致（见 CLAUDE.md §4）。
 */
export const TODO_DOWNLOAD_AND_VERIFY = true;
