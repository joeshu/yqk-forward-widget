const DEFAULT_SITE = "https://hstream.moe";
const DEFAULT_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const ORDERS = [
  ["最新上传", "recently-uploaded"], ["最新发行", "recently-released"],
  ["最早上传", "oldest-uploads"], ["最早发行", "oldest-releases"],
  ["最多播放", "view-count"], ["名称 A–Z", "az"], ["名称 Z–A", "za"]
];
let listSnapshot = null;

WeBox.define({
  api: "1.1", id: "moe.hstream.webox", name: "HStream", version: "1.0.1",
  requires: ["html"], cache: { list: 180, detail: 60, filters: 3600 },
  settings: { fields: [
    { key: "site", label: "站点地址", type: "url", default: DEFAULT_SITE },
    { key: "quality", label: "优先画质", type: "select", default: "1080", options: [
      { label: "4K (2160p)", value: "2160" }, { label: "4K 48fps", value: "2160i" },
      { label: "1080p", value: "1080" }, { label: "1080p 48fps", value: "1080i" },
      { label: "720p", value: "720" }
    ] },
    { key: "cookie", label: "登录 Cookie（可选）", type: "secret", maxLength: 8192,
      help: "仅用于站点正常登录后的授权访问；不绕过登录限制。留空可浏览公开内容。" },
    { key: "timeout", label: "请求超时秒数", type: "number", default: 15, min: 5, max: 30, step: 1 }
  ] },
  async filters() {
    return [{ key: "order", label: "排序方式", type: "select", default: "recently-uploaded",
      searchable: true, options: ORDERS.map(pair => ({ label: pair[0], value: pair[1] })) }];
  },
  async list(ctx, req) { return browseHstream(ctx, req, ""); },
  async search(ctx, req) {
    const query = cleanSingleLine(req.query);
    if (!query) return { items: [], nextCursor: null };
    return browseHstream(ctx, req, query);
  },
  async detail(ctx, req) {
    const base = resolveBaseSite(ctx);
    const contentId = validateContentId(ctx, req.id, base);
    const res = await fetchPage(ctx, ctx.url.resolve(contentId, base));
    const $ = ctx.html.load(res.data);
    const title = extractDetailTitle($);
    const poster = extractDetailPoster(ctx, $, res.url);
    const summary = extractDetailSummary($);
    const episodes = extractSeriesEpisodes(ctx, $, contentId, base);
    const result = { id: req.id, kind: /-\d+$/.test(contentId) || episodes.length > 1 ? "series" : "movie",
      groups: episodes.length ? [{ id: "main", name: "默认线路", episodes }] : [] };
    if (title) result.title = title.slice(0, 240);
    if (poster) result.poster = poster;
    if (summary) result.summary = summary.slice(0, 65536);
    return result;
  },
  async play(ctx, req) {
    const base = resolveBaseSite(ctx);
    const contentId = validateContentId(ctx, req.contentId, base);
    const episodeId = validateContentId(ctx, req.episodeId, base);
    if (req.groupId !== "main" || seriesKey(episodeId) !== seriesKey(contentId)) {
      ctx.fail("NOT_FOUND", "选集身份无效，请重新打开详情");
    }
    const episodeUrl = ctx.url.resolve(episodeId, base);
    let page = await fetchPage(ctx, episodeUrl);
    let $ = ctx.html.load(page.data);
    let direct = extractDownloadLinks(ctx, $, page.url);
    let eId = extractEpisodeId($, page.data);
    let apiFailure = null;
    let payload = null;
    if (!eId && direct.length === 0) {
      if (pageRequiresLogin($)) ctx.fail("AUTH_REQUIRED", "该内容需要登录，请在源设置中填写有效的登录 Cookie");
      ctx.fail("INVALID_RESPONSE", "页面没有提供剧集 ID 或媒体链接，站点结构可能已变化");
    }
    if (eId) {
      for (let attempt = 0; attempt < 2; attempt++) {
        try {
          const csrf = extractCsrfToken($);
          const xsrf = csrf ? "" : extractCookieXsrf(ctx.settings.cookie);
          const headers = buildRequestHeaders(ctx, episodeUrl, {
            Accept: "application/json", "Content-Type": "application/json",
            "X-Requested-With": "XMLHttpRequest", Origin: ctx.url.origin(base)
          });
          if (csrf) headers["X-CSRF-TOKEN"] = csrf;
          else if (xsrf) headers["X-XSRF-TOKEN"] = xsrf;
          else ctx.fail("AUTH_REQUIRED", "页面没有提供会话令牌，请刷新页面或重新配置登录 Cookie");
          ctx.signal.throwIfAborted();
          const res = await ctx.http.post(ctx.url.resolve("/player/api", base), {
            headers, json: { episode_id: eId }, responseType: "text", timeoutMs: getTimeoutMs(ctx)
          });
          ctx.signal.throwIfAborted();
          // Refresh the anonymous/authorized page once on expired CSRF, not on access denial.
          if (res.status === 419 && attempt === 0) {
            page = await fetchPage(ctx, episodeUrl); $ = ctx.html.load(page.data);
            direct = extractDownloadLinks(ctx, $, page.url);
            eId = extractEpisodeId($, page.data);
            if (!eId) ctx.fail("AUTH_REQUIRED", "会话刷新后仍无法读取剧集，请重新登录");
            continue;
          }
          checkStatus(ctx, res.status, "播放接口", res.headers);
          try { payload = typeof res.data === "string" ? JSON.parse(res.data) : res.data; }
          catch (_) { ctx.fail("INVALID_RESPONSE", "播放接口没有返回有效 JSON"); }
          if (!payload || typeof payload !== "object" || Array.isArray(payload)) ctx.fail("INVALID_RESPONSE", "播放接口结构无效");
          break;
        } catch (error) {
          rethrowCancellation(ctx, error);
          apiFailure = error; break;
        }
      }
    }
    let sources = [];
    if (req.purpose !== "download" && payload) {
      try { sources = await verifiedPlayerSources(ctx, payload, episodeUrl); }
      catch (error) { rethrowCancellation(ctx, error); apiFailure = error; }
    }
    const seen = new Set(sources.map(s => s.url));
    for (const source of direct) if (!seen.has(source.url)) { seen.add(source.url); sources.push(source); }
    // Public player explicitly supports a 720p MP4 on Apple/non-DASH clients.
    if (payload) {
      for (const source of buildMp4Sources(ctx, payload, episodeUrl)) {
        if (!seen.has(source.url)) { seen.add(source.url); sources.push(source); }
      }
    }
    if (sources.length) return { sources };
    if (apiFailure) throw apiFailure;
    ctx.fail(req.purpose === "download" ? "UNSUPPORTED" : "NOT_FOUND",
      req.purpose === "download" ? "没有 MP4 下载线路；当前 WeBox 不支持 DASH 离线下载" : "没有可用媒体线路，请稍后重试或更新内容源");
  }
});

function cleanSingleLine(value) { return String(value == null ? "" : value).replace(/\u00a0/g, " ").replace(/\s+/g, " ").trim(); }
function getTimeoutMs(ctx) { const n = Number(ctx.settings.timeout || 15); return Math.round((Number.isFinite(n) ? Math.max(5, Math.min(30, n)) : 15) * 1000); }
function resolveBaseSite(ctx) {
  const raw = String(ctx.settings.site || DEFAULT_SITE).trim();
  if (!/^https?:\/\//i.test(raw) || /[\r\n]/.test(raw)) ctx.fail("CONFIG_REQUIRED", "请输入有效站点地址");
  const origin = ctx.url.origin(raw);
  if (/^https?:\/\/[^/]*@/i.test(raw)) ctx.fail("CONFIG_REQUIRED", "站点地址不能包含账号或密码");
  return origin;
}
function normalizeHttpUrl(ctx, raw, base) {
  if (!raw || /[\r\n]/.test(String(raw))) return "";
  try {
    const url = ctx.url.resolve(String(raw).trim(), base);
    if (/^https?:\/\//i.test(url) && !/^https?:\/\/[^/]*@/i.test(url)) return url;
  } catch (_) {}
  return "";
}
function normalizeContentPath(ctx, raw, base) {
  const url = normalizeHttpUrl(ctx, raw, base);
  if (!url || ctx.url.origin(url) !== ctx.url.origin(base)) return "";
  const path = url.slice(ctx.url.origin(url).length).split(/[?#]/)[0].replace(/\/+$/, "");
  return /^\/hentai\/[a-z0-9]+(?:-[a-z0-9]+)*$/i.test(path) && path.length <= 1024 ? path : "";
}
function validateContentId(ctx, raw, base) {
  const path = normalizeContentPath(ctx, raw, base);
  if (!path || typeof raw !== "string" || path !== raw) ctx.fail("NOT_FOUND", "内容标识无效，请重新打开详情");
  return path;
}
function seriesKey(path) { return path.replace(/-\d+$/, ""); }
function parsePageCursor(ctx, cursor) {
  if (cursor == null) return 1;
  if (typeof cursor !== "string" || !/^[1-9]\d*$/.test(cursor) || Number(cursor) > 10000) ctx.fail("INVALID_RESPONSE", "分页游标无效");
  return Number(cursor);
}
function buildRequestHeaders(ctx, url, extra) {
  const headers = Object.assign({ "User-Agent": DEFAULT_UA, Accept: "text/html,application/xhtml+xml,*/*",
    "Accept-Language": "en-US,en;q=0.9,zh-CN;q=0.8", Referer: url }, extra || {});
  const cookie = String(ctx.settings.cookie || "").trim();
  if (cookie && ctx.url.origin(url) === ctx.url.origin(resolveBaseSite(ctx))) {
    if (/[\r\n]/.test(cookie)) ctx.fail("CONFIG_REQUIRED", "Cookie 不能包含换行，请复制单行 Cookie 值");
    headers.Cookie = cookie;
  }
  return headers;
}
function errorCode(error) {
  if (error && typeof error.code === "string") return error.code;
  const raw = String(error && error.message || error || "");
  const p = raw.indexOf("WBX_ERROR:");
  if (p >= 0) try { return JSON.parse(raw.slice(p + 10)).code; } catch (_) {}
  return "";
}
function rethrowCancellation(ctx, error) {
  ctx.signal.throwIfAborted();
  if (["CANCELLED", "TIMEOUT"].includes(errorCode(error))) throw error;
}
function checkStatus(ctx, status, where, headers) {
  if (status >= 200 && status < 300) return;
  if ([401, 403, 419].includes(status)) ctx.fail("AUTH_REQUIRED", where + (status === 419 ? "会话令牌已过期，请重新登录或刷新" : "拒绝访问，请检查登录状态或网站验证"));
  if (status === 429) {
    const retry = Number((headers || {})["retry-after"]);
    ctx.fail("RATE_LIMITED", where + "请求过于频繁，请稍后重试", { retryAfterSeconds: Number.isFinite(retry) && retry > 0 ? Math.min(retry, 3600) : 20 });
  }
  if (status === 404 || status === 410) ctx.fail("NOT_FOUND", where + "已失效或不存在");
  ctx.fail("NETWORK", where + "请求失败（HTTP " + status + "）");
}
async function fetchPage(ctx, url, query) {
  ctx.signal.throwIfAborted();
  const options = { headers: buildRequestHeaders(ctx, url), responseType: "text", timeoutMs: getTimeoutMs(ctx) };
  if (query) options.query = query;
  const res = await ctx.http.get(url, options);
  ctx.signal.throwIfAborted();
  checkStatus(ctx, res.status, "网页", res.headers);
  const data = String(res.data || "");
  const finalUrl = res.url || url;
  if (ctx.url.origin(finalUrl) !== ctx.url.origin(url)) ctx.fail("AUTH_REQUIRED", "网页跳转到其他站点，请检查站点地址或完成网站验证");
  if (!data.trim()) ctx.fail("INVALID_RESPONSE", "站点返回空页面");
  const $ = ctx.html.load(data);
  if (/\/login(?:[/?#]|$)/i.test(finalUrl) || pageRequiresLogin($)) ctx.fail("AUTH_REQUIRED", "该内容需要登录，请在源设置中填写有效 Cookie");
  if ($("#challenge-running, #challenge-stage, form#challenge-form").length || /^(just a moment|attention required)/i.test($("title").text().trim())) ctx.fail("AUTH_REQUIRED", "站点要求浏览器验证，请完成正常网站验证后再试");
  return { data, url: finalUrl, headers: res.headers || {} };
}
function pageRequiresLogin($) {
  const passwordForm = $("form").toArray().some(el => $(el).find("input[type='password']").length && /login|sign.?in/i.test($(el).attr("action") || ""));
  return !!passwordForm || !!$("[data-auth-required='true'], #restricted-content").length;
}
function extractCsrfToken($) {
  const token = $("meta[name='csrf-token']").attr("content") || $("input[name='_token']").first().val();
  return typeof token === "string" && token.length <= 8192 && !/[\r\n]/.test(token) ? token : "";
}
function extractCookieXsrf(cookie) {
  const match = String(cookie || "").match(/(?:^|;\s*)XSRF-TOKEN=([^;]+)/i);
  if (!match) return "";
  let token = match[1]; try { token = decodeURIComponent(token); } catch (_) {}
  return /[\r\n]/.test(token) ? "" : token;
}
async function browseHstream(ctx, req, keyword) {
  const page = parsePageCursor(ctx, req.cursor);
  const base = resolveBaseSite(ctx);
  const order = req.filters && req.filters.order || "recently-uploaded";
  if (!ORDERS.some(pair => pair[1] === order)) ctx.fail("CONFIG_REQUIRED", "请选择有效排序方式");
  const ttl = ctx.cache.seconds(180) * 1000;
  const generation = ctx.cache.generation;
  const key = JSON.stringify([base, order, page, keyword, String(ctx.settings.cookie || "")]);
  if (!keyword && !req.refresh && ttl > 0 && listSnapshot && listSnapshot.key === key && listSnapshot.generation === generation && Date.now() - listSnapshot.savedAt < ttl) return listSnapshot.value;
  const query = { order, page: String(page) };
  if (keyword) query.search = keyword;
  const res = await fetchPage(ctx, ctx.url.resolve("/search", base), query);
  const parsed = parseHstreamCards(ctx, res.data, base, page);
  const result = { items: parsed.items, nextCursor: parsed.hasNext && parsed.items.length && page < 10000 ? String(page + 1) : null };
  if (!keyword && ttl > 0 && generation === ctx.cache.generation) listSnapshot = { key, generation, savedAt: Date.now(), value: result };
  return result;
}
function parseHstreamCards(ctx, html, base, page) {
  const $ = ctx.html.load(html), items = [], seen = new Set();
  $("a[href*='/hentai/']").each((_, el) => {
    const a = $(el), id = normalizeContentPath(ctx, a.attr("href"), base);
    if (!id || seen.has(id)) return;
    const img = a.find("img").first();
    const title = cleanSingleLine(a.find("h2,h3,h4,.title").first().text()) || cleanSingleLine(img.attr("alt")) || cleanSingleLine(a.attr("title"));
    if (!title || (!img.length && !a.find("h2,h3,h4").length)) return;
    const item = { id, title: title.slice(0, 240), kind: /-\d+$/.test(id) ? "series" : "unknown" };
    const poster = normalizeHttpUrl(ctx, img.attr("data-src") || img.attr("src"), base);
    if (poster) item.poster = poster;
    seen.add(id); items.push(item);
  });
  return { items, hasNext: hasNextPage(ctx, $, base, page || 1) };
}
function hasNextPage(ctx, $, base, page) {
  function enabled(el) {
    const n = $(el);
    return n.attr("disabled") == null && n.attr("aria-disabled") !== "true" && !n.hasClass("disabled") && !n.parents("[aria-disabled='true'],[disabled]").length;
  }
  return $("a[rel='next'],a[wire\\:click],button[wire\\:click]").toArray().some(el => {
    if (!enabled(el)) return false;
    const n = $(el), wire = String(n.attr("wire:click") || "");
    if (/^nextPage(?:\(|$)/.test(wire)) return true;
    if (n.attr("rel") !== "next") return false;
    const url = normalizeHttpUrl(ctx, n.attr("href"), base);
    if (!url || ctx.url.origin(url) !== ctx.url.origin(base)) return false;
    const target = url.match(/[?&]page=(\d+)(?:&|$)/);
    return !!target && Number(target[1]) > page;
  });
}
function extractDetailTitle($) {
  return cleanSingleLine($("h1").first().text() || $("meta[property='og:title']").attr("content") || $("title").text())
    .replace(/\s*\|\s*hstream\.moe.*$/i, "").replace(/^Watch\s+/i, "").replace(/\s+Online in HD.*$/i, "").trim();
}
function extractDetailPoster(ctx, $, base) {
  return normalizeHttpUrl(ctx, $("meta[property='og:image']").attr("content") || $("img[alt*='cover'],img[src*='cover']").first().attr("src"), base);
}
function extractDetailSummary($) {
  const heading = $("h2").toArray().find(e => /^(description|synopsis|简介)$/i.test(cleanSingleLine($(e).text())));
  const explicit = heading ? cleanSingleLine($(heading).next().text()) : "";
  const fallback = cleanSingleLine($("meta[property='og:description']").attr("content") || $("meta[name='description']").attr("content"));
  return explicit || (/^Stream English subbed/i.test(fallback) ? "" : fallback);
}
function extractSeriesEpisodes(ctx, $, contentId, base) {
  const prefix = seriesKey(contentId), found = new Set();
  $("a[href*='/hentai/']").each((_, el) => {
    const id = normalizeContentPath(ctx, $(el).attr("href"), base);
    if (id && /-\d+$/.test(id) && seriesKey(id) === prefix) found.add(id);
  });
  // A standalone player page with a non-numeric slug is also playable.
  if (/-\d+$/.test(contentId) || extractEpisodeId($, $.html()) || $("video source[src],a[download]").length) found.add(contentId);
  return Array.from(found).sort((a, b) => Number((a.match(/-(\d+)$/) || [0, 0])[1]) - Number((b.match(/-(\d+)$/) || [0, 0])[1]))
    .map(id => ({ id, name: /-\d+$/.test(id) ? "第 " + id.match(/-(\d+)$/)[1] + " 集" : "正片" }));
}
function extractEpisodeId($, html) {
  const value = $("#e_id").val() || $("input[name='episode_id']").val();
  if (/^\d+$/.test(String(value || ""))) return String(value);
  const match = String(html).match(/["'](?:episode_id|e_id)["']\s*:\s*["']?(\d+)/i);
  return match ? match[1] : "";
}
function mediaHeaders(ctx, referer) {
  // Never copy the user login Cookie onto CDN or media URLs.
  return { "User-Agent": DEFAULT_UA, Referer: referer, Origin: ctx.url.origin(referer) };
}
function streamDomains(ctx, payload) {
  const primary = [].concat(payload.stream_domains || payload.stream_domain || []);
  const fallback = [].concat(payload.asia_stream_domains || []);
  const all = [].concat(primary.slice(0, 1), fallback, primary.slice(1));
  const seen = new Set(), domains = [];
  for (const raw of all) {
    const url = normalizeHttpUrl(ctx, raw, resolveBaseSite(ctx));
    if (!/^https?:\/\//i.test(String(raw || "")) || !url) continue;
    const domain = url.replace(/\/+$/, "");
    if (/[?#]/.test(domain) || seen.has(domain)) continue;
    seen.add(domain); domains.push(domain);
  }
  return domains.slice(0, 3);
}
function streamPath(payload) {
  const raw = String(payload.stream_url || "").replace(/^\/+|\/+$/g, "");
  if (!raw || raw.length > 4096 || /[?#\\\r\n]/.test(raw) || raw.split("/").some(p => !p || p === "." || p === ".." || /%2e|%2f|%5c/i.test(p))) return "";
  return raw;
}
function dashQualities(ctx, payload) {
  const codes = ["720", "1080", "2160"];
  if (Number(payload.interpolated) === 1) codes.push("1080i");
  if (Number(payload.interpolated_uhd) === 1) codes.push("2160i");
  const prefer = ctx.settings.quality || "1080";
  const labels = { "720": "720p", "1080": "1080p", "2160": "4K", "1080i": "1080p 48fps", "2160i": "4K 48fps" };
  return codes.sort((a, b) => (a === prefer ? 0 : 1) - (b === prefer ? 0 : 1)).map(code => ({ code, label: labels[code] }));
}
async function verifiedPlayerSources(ctx, payload, referer) {
  if (Number(payload.legacy) === 1) return [];
  const path = streamPath(payload), domains = streamDomains(ctx, payload);
  if (!path || !domains.length) ctx.fail("INVALID_RESPONSE", "播放接口缺少有效媒体域名或路径");
  const sources = [], headers = mediaHeaders(ctx, referer), deadline = Date.now() + 45000;
  let lastError = null;
  for (let index = 0; index < domains.length && Date.now() < deadline; index++) {
    const qualities = dashQualities(ctx, payload);
    const found = await Promise.all(qualities.map(async quality => {
      const remaining = deadline - Date.now();
      if (remaining <= 0) return null;
      const url = domains[index] + "/" + path + "/" + quality.code + "/manifest.mpd";
      try {
        ctx.signal.throwIfAborted();
        const res = await ctx.http.get(url, { headers, responseType: "text", timeoutMs: Math.min(getTimeoutMs(ctx), 8000, remaining) });
        ctx.signal.throwIfAborted();
        if (res.status < 200 || res.status >= 300) { checkStatus(ctx, res.status, "媒体清单", res.headers); return null; }
        const text = String(res.data || "");
        const xml = ctx.html.load(text, { xmlMode: true });
        const mpd = xml("MPD");
        if (!mpd.length || !mpd.find("Period").length || !mpd.find("Representation").length) return null;
        if (mpd.find("ContentProtection").length) { lastError = { unsupported: true }; return null; }
        return { id: "dash-" + (index + 1) + "-" + quality.code, name: quality.label + " [DASH]",
          url: res.url || url, mime: "application/dash+xml", headers, downloadable: false };
      } catch (error) { rethrowCancellation(ctx, error); lastError = error; return null; }
    }));
    sources.push(...found.filter(Boolean));
    if (sources.length) break; // Avoid probing every CDN after one server succeeds.
  }
  if (!sources.length && lastError && lastError.unsupported) ctx.fail("UNSUPPORTED", "该线路含内容保护，当前脚本不处理 DRM");
  if (!sources.length && lastError) throw lastError;
  return sources;
}
function buildMp4Sources(ctx, payload, referer) {
  const path = streamPath(payload);
  if (!path) return [];
  return streamDomains(ctx, payload).slice(0, 1).map((domain, index) => ({
    id: "mp4-" + (index + 1) + "-720", name: "720p MP4（站点备用，可下载）",
    url: domain + "/" + path + "/x264.720p.mp4", mime: "video/mp4",
    headers: mediaHeaders(ctx, referer), downloadable: true
  }));
}
function extractDownloadLinks(ctx, $, referer) {
  const sources = [], seen = new Set();
  $("a[href],source[src],video[src]").each((_, el) => {
    const n = $(el), url = normalizeHttpUrl(ctx, n.attr("href") || n.attr("src"), referer);
    if (!url || !/\.mp4$/i.test(url.split(/[?#]/)[0]) || seen.has(stableMediaId(url))) return;
    seen.add(stableMediaId(url));
    sources.push({ id: "direct-" + stableMediaId(url), name: cleanSingleLine(n.text()).slice(0, 40) || "MP4 直链",
      url, mime: "video/mp4", headers: mediaHeaders(ctx, referer), downloadable: true });
  });
  return sources;
}

function stableMediaId(url) {
  // Signed query strings rotate: use origin/path for stable playback-line identity.
  const path = url.split(/[?#]/)[0];
  let a = 2166136261, b = 5381;
  for (let i = 0; i < path.length; i++) { a = Math.imul(a ^ path.charCodeAt(i), 16777619); b = Math.imul(b, 33) ^ path.charCodeAt(i); }
  return (a >>> 0).toString(16) + "-" + (b >>> 0).toString(16);
}

