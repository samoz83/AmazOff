#!/usr/bin/env node
"use strict";

// Structural no-ads transform for Amazon's ATVUnfPlayerBundle.js.
// Anchors use property names and string literals only; minified identifiers
// are captured, never hardcoded, so re-minified upstream builds keep matching.

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const args = process.argv.slice(2);
function option(name, fallback) {
  const index = args.indexOf(name);
  return index >= 0 && index + 1 < args.length ? args[index + 1] : fallback;
}

const sourcePath = option("--source");
const outDir = option("--out-dir");
const route = option("--route");
const sourceUrl = option("--source-url", "");
const expectedSourceSha = option("--expected-source-sha", "");

if (!sourcePath || !outDir || !route) {
  console.error("usage: build-patch.js --source FILE --out-dir DIR --route NAME [--source-url URL] [--expected-source-sha SHA]");
  process.exit(2);
}

let source = fs.readFileSync(sourcePath, "utf8");
const sha256 = (s) => crypto.createHash("sha256").update(s).digest("hex");
const sourceSha256 = sha256(source);
if (expectedSourceSha && sourceSha256 !== expectedSourceSha) {
  throw new Error(`upstream bundle hash changed: expected ${expectedSourceSha}, got ${sourceSha256}`);
}

const ID = "[A-Za-z_$][\\w$]*";
function patch(label, expression, replacement, expected = 1) {
  const count = (source.match(new RegExp(expression.source, "g")) || []).length;
  if (count !== expected) throw new Error(`${label}: expected ${expected} anchor(s), got ${count}`);
  source = source.replace(new RegExp(expression.source, "g"), replacement);
}

patch(
  "no-ads flag",
  /("use strict";var [A-Za-z_$][\w$]*="undefined"!=typeof globalThis\?globalThis:"undefined"!=typeof window\?window:"undefined"!=typeof global\?global:"undefined"!=typeof self\?self:\{\};)(function e\(e\)\{)/,
  "$1var __HOMEBREW_NOADS=!0;$2"
);

// Single chokepoint: the PRSv2 converter builds playlistedPlaybackUrls for every
// player path (legacy handler, ad break manager, seek interceptor, cache, PVXpPlayer).
// Drop "Remote" (ad) items, strip overlay ads, drop pause-ad resolution.
patch(
  "playlist converter",
  new RegExp(`intraTitlePlaylist:(${ID})\\.playbackUrls\\.intraTitlePlaylist,pauseAdsResolution:\\1\\.playbackUrls\\.pauseAdsResolution,`),
  (m, e) =>
    `intraTitlePlaylist:__HOMEBREW_NOADS?${e}.playbackUrls.intraTitlePlaylist.filter(function(x){return"Remote"!==x.type}).map(function(x){if(null==x.nonLinearAds)return x;var y=Object.assign({},x);delete y.nonLinearAds;return y}):${e}.playbackUrls.intraTitlePlaylist,` +
    `pauseAdsResolution:__HOMEBREW_NOADS?void 0:${e}.playbackUrls.pauseAdsResolution,`
);

// Pause ads on the cuepoint path.
patch(
  "pause behavior",
  new RegExp(`pauseBehavior:(${ID})\\((${ID})\\),playbackResourceExpirationTimeMs:`),
  "pauseBehavior:__HOMEBREW_NOADS?void 0:$1($2),playbackResourceExpirationTimeMs:"
);

// Cuepoint / VMAP / DASH event-stream ad breaks.
patch(
  "ad-break resolver",
  new RegExp(`(\\.prototype\\.resolveWithAdBreaks=freeOnUnref\\(function\\(${ID},${ID}\\)\\{var ${ID}=this;if\\()(0===${ID}\\.length\\))`),
  "$1__HOMEBREW_NOADS||$2"
);

// Newer MediaPlayer stack: skip building ad break configs for Remote items.
patch(
  "unresolved content source",
  /case"Remote":(?=var [^;]{0,200}?this\.adBreakConfigBuilder\.build\()/,
  'case"Remote":if(__HOMEBREW_NOADS)break;'
);

// Telemetry: no-op the analytics sinks only. Every one is fire-and-forget (callers
// ignore the result). Session reporting (UpdateStream, PES sessions, bookmarks) and
// licence calls are deliberately untouched: resume and playback depend on them.
const noop = (label, expression, expected = 1) => patch(label, expression, "$1return;", expected);
// Media events (QoS, errors, custom metadata/metrics): HTTP and TelemetrySdk reporters.
noop("media events", /(\.prototype\.enqueueMediaEvents=freeOnUnref\(function\(e\)\{)(?=this\.applyDeferredEventTimestamp\(e\))/, 2);
noop("telemetry queue", /(\.prototype\.reportEvent=freeOnUnref\(function\(e\)\{var t=this;)(?=this\.queue\.add\(e\),this\.isQueueAtMaxDepth\(\))/);
noop("minerva metrics", /(\.prototype\.recordMetric=freeOnUnref\(function\(e\)\{)(?=if\(null!=this\.minervaClient\)try\{this\.minervaClient\.record\(e\))/);
noop("minerva kpi upload", /(\.prototype\.uploadMinervaKpiMetrics=freeOnUnref\(function\(\)\{)/);
noop("client log upload", /(\.prototype\.write=freeOnUnref\(function\(e,t\)\{)(?=if\(!\(e<this\.logLevel\)\)\{var n=this\.toLogLine\()/);
noop("playback diagnostics", /(\.prototype\.batchMessage=freeOnUnref\(function\(e,t\)\{)(?=1e3<=this\.batchedMessages\.length)/);
// Ad beacons: should never fire once ads are filtered; belt and braces.
patch("ad beacons", /(\.prototype\.send=freeOnUnref\(function\(e,t,n\)\{if\(void 0===t&&\(t=\{\}\),)this\.enableEventReporting(?=\)\{for\(var r=0)/, "$1!1");
noop("ad audit pings", /(\.prototype\.make(?:Direct)?AuditPingRequest=freeOnUnref\(function\([\w$]+,[\w$]+\)\{)/, 2);

new Function(source); // syntax check
fs.mkdirSync(outDir, { recursive: true });
fs.writeFileSync(path.join(outDir, "ATVUnfPlayerBundle.js"), source);
const manifest = {
  patchRevision: 3,
  route,
  sourceUrl,
  sourceSha256,
  patchedSha256: sha256(source),
};
fs.writeFileSync(path.join(outDir, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
// Location-level add_header disables inherited server-level headers, so keep no-store here.
fs.writeFileSync(
  path.join(outDir, "identity.conf"),
  `add_header Cache-Control no-store;\nadd_header X-AmazOff-Source-Sha "${sourceSha256}";\nadd_header X-AmazOff-Patch-Sha "${manifest.patchedSha256}";\n`
);
console.log(`${route}: source ${sourceSha256} -> patched ${manifest.patchedSha256}`);
