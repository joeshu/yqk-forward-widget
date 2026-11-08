const DEFAULT_SITE = "https://rou.video";
const DEFAULT_UA =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

let listSnapshot = null;
const pageSnapshots = new Map();
let snapshotContextKey = "";

WeBox.define({
  api: "1.1",
  id: "video.rou.webox",
  name: "肉視頻",
  version: "1.0.3",
  requires: ["html", "memoryHls", "mediaProcessor", "binary"],
  cache: { list: 180, detail: 60, filters: 3600 },

  settings: {
    fields: [
      {
        key: "site",
        label: "站点地址",
        type: "url",
        required: false,
        default: DEFAULT_SITE,
        placeholder: "https://rou.video"
      },
      {
        key: "cookie",
        label: "登录 Cookie（可选，用于解锁高峰时段播放限制）",
        type: "secret",
        maxLength: 8192,
        placeholder: "填入浏览器登录 rou.video 后的 Cookie 字符串"
      },
      {
        key: "timeout",
        label: "请求超时秒数",
        type: "number",
        default: 15,
        min: 5,
        max: 30,
        step: 1
      }
    ]
  },

  async filters(ctx, req) {
    return [
      {
        key: "category",
        label: "分类栏目",
        type: "select",
        default: "/v",
        options: [
          {"label":"首页精选","value":"/home"},
          {"label":"AI短劇","value":"/series?tag=AI短劇"},
          {"label":"國產AV","value":"/t/國產AV"},
          {"label":"探花","value":"/t/探花"},
          {"label":"自拍流出","value":"/t/自拍流出"},
          {"label":"OnlyFans","value":"/t/OnlyFans"},
          {"label":"日本","value":"/t/日本"},
          {"label":"最新劇集","value":"/series?f=fresh"},
          {"label":"最新視頻","value":"/v"},
          {"label":"國產AV精選","value":"/t/國產AV?order=likeCount"},
          {"label":"自拍流出精選","value":"/t/自拍流出?order=likeCount"},
          {"label":"探花精選","value":"/t/探花?order=likeCount"}
        ]
      },
      {
        key: "order",
        label: "视频排序",
        help: "精选栏目和剧集按首页栏目规则排序；此项用于普通视频和搜索。",
        type: "select",
        default: "createdAt",
        searchable: true,
        options: [
          { label: "最新上传", value: "createdAt" },
          { label: "最多观看", value: "viewCount" },
          { label: "最多喜欢", value: "likeCount" }
        ]
      }
    ];
  },

  async list(ctx, req) {
    const page = parsePageCursor(ctx, req.cursor);
    const filters = req.filters || {};
    const category = String(filters.category || "/v").trim();
    const order = String(filters.order || "createdAt").trim();
    const baseSite = resolveBaseSite(ctx);
    if (category === "/home" && page > 1) {
      return { items: [], nextCursor: null };
    }

    const targetUrl = buildCategoryUrl(ctx, baseSite, category);
    const route = urlParts(ctx, targetUrl);
    const query = {};
    if (category !== "/home") {
      // 首页精选链接自带排序，剧集自带 tag/f；不能被默认 createdAt 覆盖。
      if (route.path !== "/series" && !route.params.order && order) query.order = order;
      if (page > 1) query.page = String(page);
    }


    const ttlMs = ctx.cache.seconds(180) * 1000;
    const cacheKey = JSON.stringify([targetUrl, query, ctx.settings]);

    if (
      !req.refresh &&
      ttlMs > 0 &&
      listSnapshot &&
      listSnapshot.key === cacheKey &&
      listSnapshot.generation === ctx.cache.generation &&
      Date.now() - listSnapshot.savedAt < ttlMs
    ) {
      return listSnapshot.value;
    }

    const generation = ctx.cache.generation;

    const html = await fetchHtml(ctx, targetUrl, query);
    ctx.signal.throwIfAborted();

    const parsed = parseVideoList(ctx, html, baseSite, page, withQuery(targetUrl, query));
    const nextCursor =
      category !== "/home" && parsed.hasNext ? String(page + 1) : null;
    const result = { items: parsed.items, nextCursor };

    if (ttlMs > 0 && generation === ctx.cache.generation) {
      listSnapshot = {
        key: cacheKey,
        generation,
        savedAt: Date.now(),
        value: result
      };
    }
    return result;
  },

  async search(ctx, req) {
    const keyword = String(req.query || "").trim();
    if (!keyword) return { items: [], nextCursor: null };

    const page = parsePageCursor(ctx, req.cursor);
    const order = String(req.filters?.order || "").trim();
    const baseSite = resolveBaseSite(ctx);
    const searchUrl = ctx.url.resolve("/search", baseSite);

    const query = { q: keyword };
    if (order && order !== "createdAt") query.order = order;
    if (page > 1) query.page = String(page);

    const html = await fetchHtml(ctx, searchUrl, query);
    ctx.signal.throwIfAborted();

    const parsed = parseVideoList(ctx, html, baseSite, page, withQuery(searchUrl, query));
    return {
      items: parsed.items,
      nextCursor: parsed.hasNext ? String(page + 1) : null
    };
  },

  async detail(ctx, req) {
    const contentId = validateContentId(ctx, req.id);
    const baseSite = resolveBaseSite(ctx);
    const pageUrl = ctx.url.resolve(contentId, baseSite);

    // 详情缓存由宿主管理；宿主实际调用时必须回源，避免拦截主动刷新。
    const page = await readContentPage(ctx, pageUrl, true);
    const html = page.html;
    ctx.signal.throwIfAborted();

    const $ = ctx.html.load(html);
    const nextData = extractNextData($, html);
    const videoObj = extractVideoObjectFromNextData(nextData);

    const title =
      cleanSingleLine(videoObj?.name || videoObj?.title) ||
      extractDomTitle($);
    const poster =
      normalizeHttpUrl(
        ctx,
        videoObj?.coverImageUrl ||
          videoObj?.poster ||
          $("meta[property='og:image']").attr("content") ||
          $("video").first().attr("poster"),
        baseSite
      );

    const summary = buildDetailSummary($, videoObj);
    const episodes = extractSeriesEpisodes(ctx, $, nextData, contentId, baseSite);
    if (
      !videoObj &&
      !extractRouEv($, html, nextData) &&
      episodes.length === 0 &&
      $("video").length === 0
    ) {
      ctx.fail("INVALID_RESPONSE", "详情页缺少有效视频数据，可能已下架或返回验证页面");
    }

    const groups = [
      {
        id: "main",
        name: "默认线路",
        episodes:
          episodes.length > 0
            ? episodes
            : [{ id: contentId, name: "正片" }]
      }
    ];

    const detailResult = {
      id: req.id,
      kind: contentId.startsWith("/s/") || episodes.length > 1 ? "series" : "movie",
      groups
    };
    if (title) detailResult.title = title.slice(0, 240);
    if (poster) detailResult.poster = poster;
    if (summary) detailResult.summary = summary.slice(0, 65536);

    rememberContentPage(ctx, pageUrl, page);
    return detailResult;
  },

  async play(ctx, req) {
    const contentId = validateContentId(ctx, req.contentId);
    const groupId = String(req.groupId || "").trim();
    const episodeId = validateContentId(ctx, req.episodeId);
    if (groupId !== "main" || !episodeId.startsWith("/v/")) ctx.fail("NOT_FOUND", "分组或选集已变化，请重新打开详情");
    const baseSite = resolveBaseSite(ctx);
    const playPageUrl = ctx.url.resolve(episodeId, baseSite);
    if (episodeId !== contentId) {
      const parentUrl = ctx.url.resolve(contentId, baseSite);
      const parent = await readContentPage(ctx, parentUrl, !!req.refresh);
      const parent$ = ctx.html.load(parent.html);
      const episodes = extractSeriesEpisodes(ctx, parent$, extractNextData(parent$, parent.html), contentId, baseSite);
      if (!episodes.some(e => e.id === episodeId)) ctx.fail("NOT_FOUND", "选集不属于当前内容，请重新打开详情");
      rememberContentPage(ctx, parentUrl, parent);
    }
    const page = await readContentPage(ctx, playPageUrl, !!req.refresh);
    const html = page.html;
    const $ = ctx.html.load(html);
    const nextData = extractNextData($, html);

    const sources = [];
    const seenUrls = new Set();
    const addSource = (rawUrl, label, mimeHint) => {
      const resolved = normalizeHttpUrl(ctx, rawUrl, playPageUrl);
      if (!resolved || seenUrls.has(resolved)) return;
      const path = resolved.split(/[?#]/)[0];
      const hint = cleanSingleLine(mimeHint).split(";")[0].trim().toLowerCase();
      const isHls = /mpegurl/.test(hint) || /\.m3u8$/i.test(path) || /\/(hls|m3u8)\//i.test(path);
      const isMp4 = hint === "video/mp4" || /\.mp4$/i.test(path);
      if (!isHls && !isMp4) return;
      seenUrls.add(resolved);
      const mediaKind = isHls ? "hls" : "mp4";
      const suffix = sources.filter(s => s.mime === (isHls ? "application/vnd.apple.mpegurl" : "video/mp4")).length;
      sources.push({
        id: groupId + "-" + mediaKind + (suffix ? "-" + (suffix + 1) : ""),
        name: cleanSingleLine(label).slice(0, 240) || "主线路",
        url: resolved,
        mime: isHls ? "application/vnd.apple.mpegurl" : "video/mp4",
        headers: mediaHeaders(ctx, resolved, playPageUrl, baseSite),
        downloadable: true
      });
    };

    // 只解析当前页面的结构化载荷，不执行网站脚本、不扫描推荐/广告的任意媒体 URL。
    const ev = extractRouEv($, html, nextData);
    if (ev) {
      const decoded = decodeRouEv(ev);
      if (!decoded) ctx.fail("INVALID_RESPONSE", "当前视频播放数据解码失败");
      collectStreamsFromObject(decoded, addSource);
    }
    collectStreamsFromObject(extractVideoObjectFromNextData(nextData), addSource);
    $("video[src], video source[src]").each((_, el) => {
      addSource($(el).attr("src"), "直连线路", $(el).attr("type"));
    });

    // 补充 API 仅在页面没有已知资源时使用，不阻断已存在的原生 video 直链。
    if (sources.length === 0) {
      rejectChallenge(ctx, html);
      if (isLoginRestriction(html)) failLogin(ctx);
      const vid = extractVidFromPath(episodeId);
      const apiText = await fetchHtml(ctx, ctx.url.resolve("/api/v/" + vid, baseSite), null, {
        Accept: "application/json, text/plain, */*", Referer: playPageUrl
      }, true);
      if (apiText !== null) {
        let apiJson;
        try { apiJson = JSON.parse(apiText); }
        catch (_) { ctx.fail("INVALID_RESPONSE", "播放接口返回的 JSON 无效"); }
        if (apiJson?.ev) collectStreamsFromObject(decodeRouEv(apiJson.ev), addSource);
        collectStreamsFromObject(apiJson?.video || apiJson, addSource);
      }
    }
    if (sources.length === 0) {
      if (isLoginRestriction(html)) failLogin(ctx);
      ctx.fail("INVALID_RESPONSE", "页面未提供可识别的播放资源，请更新源脚本或重试");
    }

    const prepared = [];
    for (const source of sources) {
      ctx.signal.throwIfAborted();
      prepared.push(source.mime === "application/vnd.apple.mpegurl"
        ? await prepareHls(ctx, source, playPageUrl, baseSite)
        : source);
    }
    ctx.signal.throwIfAborted();
    rememberContentPage(ctx, playPageUrl, page);
    return { sources: prepared };
  },

  media: {
    request(ctx, input) {
      ctx.signal.throwIfAborted();
      const state = input.context || {};
      const baseSite = state.baseSite || resolveBaseSite(ctx);
      const headers = Object.assign({}, input.headers || {}, mediaHeaders(ctx, input.url, state.pageUrl || baseSite + "/", baseSite));
      // 不把源站 Cookie 带到 CDN，也不转发旧配置中的 Cookie。
      for (const key of Object.keys(headers)) {
        if (key.toLowerCase() === "cookie") delete headers[key];
      }
      addCookie(ctx, input.url, baseSite, headers);
      return { headers };
    },
    response(ctx, input) {
      ctx.signal.throwIfAborted();
      const size = ctx.binary.size(input.body);
      if (size < 8 || !isPng(ctx.binary.read(input.body, 0, 8))) return { body: input.body };
      const part = findRouPngPayload(ctx, size, (offset, length) => ctx.binary.read(input.body, offset, length));
      let body;
      if (part.flags === 0) {
        // 常规分片仅裁剪句柄，避免整片媒体经过 JS/Base64 往返。
        body = ctx.binary.slice(input.body, part.offset, part.length);
      } else {
        const compressed = readHandleBytes(ctx, input.body, part.offset, part.length);
        const decoded = inflateRouZlib(ctx, compressed, 8 * 1024 * 1024);
        body = writeHandleBytes(ctx, input.body, decoded);
      }
      const head = ctx.binary.read(body, 0, Math.min(512, ctx.binary.size(body)));
      const mime = sniffMediaMime(head, input.kind);
      return { body, mime };
    }
  }
});

/* ======================== 网络请求与基础校验 ======================== */

function resolveBaseSite(ctx) {
  const raw = String(ctx.settings?.site || DEFAULT_SITE).trim();
  if (!raw) return DEFAULT_SITE;
  return raw.replace(/\/+$/, "");
}

function getTimeoutMs(ctx) {
  const sec = Number(ctx.settings?.timeout || 15);
  const clamped = Number.isFinite(sec) ? Math.min(Math.max(sec, 5), 30) : 15;
  return clamped * 1000;
}

async function fetchHtml(ctx, url, query, extraHeaders, allowMissing = false) {
  ctx.signal.throwIfAborted();
  const baseSite = resolveBaseSite(ctx);
  const origin = ctx.url.origin(url);

  const headers = Object.assign(
    {
      "User-Agent": DEFAULT_UA,
      Accept:
        "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
      "Accept-Language": "zh-TW,zh-CN;q=0.9,zh;q=0.8,en;q=0.7",
      Referer: origin + "/"
    },
    extraHeaders || {}
  );

  // 仅向目标站点域发送用户配置的敏感 Cookie
  const userCookie = String(ctx.settings?.cookie || "").trim();
  if (userCookie && origin === ctx.url.origin(baseSite)) {
    headers["Cookie"] = userCookie.replace(/[\r\n]+/g, "; ");
  }

  const options = {
    headers,
    responseType: "text",
    timeoutMs: getTimeoutMs(ctx)
  };
  if (query && Object.keys(query).length > 0) {
    options.query = query;
  }

  const response = await ctx.http.get(url, options);
  ctx.signal.throwIfAborted();
  if (response.status === 429) {
    ctx.fail("RATE_LIMITED", "请求过于频繁，请稍后重试", {
      retryAfterSeconds: 15
    });
  }
  if (response.status === 404) {
    if (allowMissing) return null;
    ctx.fail("NOT_FOUND", "请求的页面或视频不存在");
  }
  if (response.status === 401 || response.status === 403) {
    ctx.fail(
      "AUTH_REQUIRED",
      "站点拒绝访问，请检查网络节点或在设置中更新 Cookie"
    );
  }
  if (response.status < 200 || response.status >= 300) {
    ctx.fail("NETWORK", `站点请求失败 (HTTP ${response.status})`);
  }

  const text = String(response.data || "");
  rejectChallenge(ctx, text);
  if (!text.trim()) {
    ctx.fail("INVALID_RESPONSE", "站点返回空白内容");
  }
  return text;
}

function buildCategoryUrl(ctx, baseSite, categoryPath) {
  const raw = String(categoryPath || "/v");
  const index = raw.indexOf("?");
  const path = index < 0 ? raw : raw.slice(0, index);
  const query = index < 0 ? "" : raw.slice(index);
  const encodedPath = path.split("/").map(segment => {
    try { return encodeURIComponent(decodeURIComponent(segment)); }
    catch (_) { return encodeURIComponent(segment); }
  }).join("/") || "/v";
  // 只编码路径，不把 ?tag=、?f= 或 ?order= 当成路径字符。
  return ctx.url.resolve(encodedPath + query, baseSite);
}

function parsePageCursor(ctx, cursor) {
  if (cursor === null) return 1;
  if (typeof cursor !== "string" || !/^[1-9][0-9]*$/.test(cursor)) {
    ctx.fail("INVALID_RESPONSE", "分页游标无效");
  }
  const page = Number(cursor);
  if (!Number.isSafeInteger(page) || page < 1 || page > 50000) {
    ctx.fail("INVALID_RESPONSE", "分页游标超出范围");
  }
  return page;
}

function validateContentId(ctx, id) {
  const clean = typeof id === "string" ? id : "";
  if (clean.length > 1024 || !/^\/(?:v|s)\/[a-zA-Z0-9_-]+$/.test(clean)) {
    ctx.fail("NOT_FOUND", "内容标识无效");
  }
  return clean;
}

/* ======================== 列表解析 (__NEXT_DATA__ + DOM) ======================== */

function extractNextData($, html) {
  const scriptText =
    $("#__NEXT_DATA__").first().html() ||
    (html.match(
      /<script[^>]+id=["']__NEXT_DATA__["'][^>]*>([\s\S]*?)<\/script>/i
    ) || [])[1] ||
    "";
  if (!scriptText) return null;
  try {
    return JSON.parse(scriptText.trim());
  } catch (_) {
    return null;
  }
}

function parseVideoList(ctx, html, baseSite, currentPage, listingUrl) {
  ctx.signal.throwIfAborted();
  rejectChallenge(ctx, html);
  const $ = ctx.html.load(html);
  const items = [];
  const seenIds = new Set();
  const seriesMode = !!listingUrl && urlParts(ctx, listingUrl).path === "/series";

  // 1. 优先从 __NEXT_DATA__ 提取结构化视频列表
  const nextData = extractNextData($, html);
  const pageProps = nextData?.props?.pageProps || {};
  const rawVideos = collectVideoArraysFromProps(pageProps);

  for (const v of rawVideos) {
    if (!v || typeof v !== "object") continue;
    const vid = String(v.id || v.vid || "").trim();
    if (!/^[a-zA-Z0-9_-]+$/.test(vid) || vid.length > 1021) continue;
    const normId = `${seriesMode ? "/s/" : "/v/"}${vid}`;
    if (seenIds.has(normId)) continue;

    const title = cleanSingleLine(v.name || v.title || v.nameZh || "");
    if (!title) continue;

    const poster = normalizeHttpUrl(
      ctx,
      v.coverImageUrl || v.poster || v.thumbUrl || v.imageUrl || "",
      baseSite
    );

    const subParts = [];
    if (v.resolution || v.quality) {
      const q = String(v.resolution || v.quality);
      subParts.push(/p$/i.test(q) ? q.toUpperCase() : `${q}P`);
    }
    if (Number(v.duration) > 0) {
      subParts.push(formatDuration(Number(v.duration)));
    }
    if (Array.isArray(v.tags) && v.tags.length > 0) {
      subParts.push(v.tags.slice(0, 3).join("/"));
    }

    seenIds.add(normId);
    const card = {
      id: normId,
      title: title.slice(0, 240),
      kind: seriesMode ? "series" : "movie"
    };
    if (poster) card.poster = poster;
    if (subParts.length > 0) {
      card.subtitle = subParts.join(" · ").slice(0, 1024);
    }
    items.push(card);
  }

  // 2. 补充或回退扫描 HTML DOM 中的视频卡片 (a[href^="/v/"])
  $(seriesMode ? "a[href*='/s/']" : "a[href*='/v/']").each((_, el) => {
    const a = $(el);
    const rawHref = String(a.attr("href") || "").trim();
    const normId = normalizeVideoPath(ctx, rawHref, baseSite, seriesMode ? "s" : "v");
    if (!normId || seenIds.has(normId)) return;

    const card = seriesMode || a.find("h2, h3, h4").length ? a : a.closest("div.group, div.relative, article, li, div");
    const img = (a.find("img").length ? a : card).find("img:not([alt='logo'])").first();
    if (!img.length && a.text().trim().length < 2) return;

    const rawPoster =
      img.attr("src") ||
      img.attr("data-src") ||
      img.attr("srcset")?.split(/\s+/)[0] ||
      "";
    const poster = normalizeHttpUrl(ctx, rawPoster, baseSite);

    let title =
      (seriesMode ? cleanSingleLine(a.find("h2,h3,h4").first().text()) : "") ||
      cleanSingleLine(img.attr("alt")) ||
      cleanSingleLine(a.attr("title")) ||
      cleanSingleLine(card.find("h2, h3, h4, .line-clamp-2, .truncate").first().text()) ||
      cleanSingleLine(a.text());

    if (!title || /^(觀看|播放|更多|登入|註冊|\d+:\d+)$/.test(title)) return;

    const badgeTexts = [];
    card.find("span, .badge").each((__, bEl) => {
      const bt = cleanSingleLine($(bEl).text());
      if (/^(\d{1,2}:\d{2}(:\d{2})?|4K|1080P|720P|HD)$/i.test(bt) && !badgeTexts.includes(bt)) {
        badgeTexts.push(bt);
      }
    });

    seenIds.add(normId);
    const item = {
      id: normId.slice(0, 1024),
      title: title.slice(0, 240),
      kind: seriesMode ? "series" : "movie"
    };
    if (poster) item.poster = poster;
    if (seriesMode) {
      const info = cleanSingleLine(a.children("div").last().text());
      if (info) item.subtitle = info.slice(0, 1024);
    } else if (badgeTexts.length > 0) {
      item.subtitle = badgeTexts.join(" · ").slice(0, 1024);
    }
    items.push(item);
  });

  const rawTotalPages = pageProps.totalPages ?? pageProps.pageCount;
  const totalPages = Number(rawTotalPages);
  let hasNext = false;
  if (
    rawTotalPages != null &&
    rawTotalPages !== "" &&
    Number.isSafeInteger(totalPages) &&
    totalPages >= 0
  ) {
    hasNext = currentPage < totalPages;
  } else if (!listingUrl || urlParts(ctx, listingUrl).path !== "/home") {
    const expected = urlParts(ctx, listingUrl || ctx.url.resolve("/v", baseSite));
    $("a[href*='page=']").each((_, el) => {
      const a = $(el);
      if (a.closest("[disabled], [aria-disabled='true'], .disabled").length) return;
      const href = normalizeHttpUrl(ctx, a.attr("href"), listingUrl || baseSite);
      if (!href) return;
      const actual = urlParts(ctx, href);
      if (actual.origin !== expected.origin || actual.path !== expected.path) return;
      for (const key of Object.keys(expected.params)) {
        if (key === "page") continue;
        if (actual.params[key] !== expected.params[key] && !(key === "order" && expected.params[key] === "createdAt" && !actual.params[key])) return;
      }
      const next = Number(actual.params.page);
      if (Number.isSafeInteger(next) && next > currentPage && next <= 50000) hasNext = true;
    });
  }

  const knownArray = Array.isArray(pageProps.videos) || Array.isArray(pageProps.data?.videos) || Array.isArray(pageProps.items);
  if (items.length === 0 && !knownArray) {
    const emptyMessage = /(未找到|沒有找到|没有找到|沒有影片|没有影片|暫無|暂无|no results|nothing found)/i.test($("main").text() || $.root().text());
    if (!emptyMessage) ctx.fail("INVALID_RESPONSE", "页面不是可识别的目录，可能返回验证或错误页面");
  }

  return { items, hasNext };
}

function collectVideoArraysFromProps(pageProps) {
  if (!pageProps || typeof pageProps !== "object") return [];
  const merged = [];
  const add = values => { if (Array.isArray(values)) merged.push(...values); };
  add(pageProps.videos); add(pageProps.data?.videos); add(pageProps.items);
  // 不能因 videos: [] 而忽略首页其它有效板块。
  for (const [key, value] of Object.entries(pageProps)) {
    if (["videos", "items"].includes(key) || !Array.isArray(value)) continue;
    if (/videos$/i.test(key)) { add(value); continue; }
    for (const entry of value) {
      if (entry && Array.isArray(entry.videos)) add(entry.videos);
    }
  }
  return merged;
}

/* ======================== 详情与播放解密工具 ======================== */

function extractVideoObjectFromNextData(nextData) {
  const pageProps = nextData?.props?.pageProps;
  if (!pageProps || typeof pageProps !== "object") return null;
  if (pageProps.video && typeof pageProps.video === "object") {
    return pageProps.video;
  }
  if (pageProps.data?.video && typeof pageProps.data.video === "object") {
    return pageProps.data.video;
  }
  return null;
}

function extractDomTitle($) {
  const raw =
    cleanSingleLine($("h1").first().text()) ||
    cleanSingleLine($("meta[property='og:title']").attr("content")) ||
    cleanSingleLine($("title").first().text());
  return raw.replace(/\s*[-|]\s*肉視頻.*$/i, "").trim();
}

function buildDetailSummary($, videoObj) {
  const lines = [];
  if (videoObj) {
    if (Array.isArray(videoObj.tags) && videoObj.tags.length > 0) {
      lines.push(`标签：${videoObj.tags.join(" / ")}`);
    }
    if (Number(videoObj.duration) > 0) {
      lines.push(`时长：${formatDuration(Number(videoObj.duration))}`);
    }
    if (videoObj.description || videoObj.desc) {
      lines.push(cleanSingleLine(videoObj.description || videoObj.desc));
    }
  }

  if (lines.length === 0) {
    const metaDesc = cleanSingleLine(
      $("meta[property='og:description']").attr("content") ||
        $("meta[name='description']").attr("content") ||
        ""
    );
    if (metaDesc) lines.push(metaDesc);
  }
  return lines.join("\n");
}

function extractSeriesEpisodes(ctx, $, nextData, contentId, baseSite) {
  const episodes = [];
  const seenIds = new Set();

  // 1. 检查 __NEXT_DATA__ 中是否存在同一合集的多集列表 (seriesVideos / orderVideos)
  const pageProps = nextData?.props?.pageProps || {};
  const seriesList =
    pageProps.seriesVideos ||
    pageProps.video?.seriesVideos ||
    pageProps.episodes ||
    [];

  if (Array.isArray(seriesList) && seriesList.length > 1) {
    seriesList.forEach((item, idx) => {
      const vid = String(item?.id || item?.vid || "").trim();
      if (!/^[a-zA-Z0-9_-]+$/.test(vid) || vid.length > 1021) return;
      const path = `/v/${vid}`;
      if (seenIds.has(path)) return;
      seenIds.add(path);
      const label =
        cleanSingleLine(item.orderName || item.episodeName || item.name) ||
        `第 ${idx + 1} 集`;
      episodes.push({ id: path, name: label.slice(0, 60) });
    });
  }

  if (contentId.startsWith("/s/")) {
    // 剧集页的 main 内用 small 标明时长的方形选集，排除开始观看按钮和推荐剧集。
    $("main a[href*='/v/']").each((_, el) => {
      const a = $(el);
      if (!a.find("small").length) return;
      const id = normalizeVideoPath(ctx, a.attr("href"), baseSite);
      if (!id || seenIds.has(id)) return;
      const label = cleanSingleLine(a.clone().find("small").remove().end().text()) || "第 " + (episodes.length + 1) + " 集";
      seenIds.add(id);
      episodes.push({ id, name: label.slice(0, 240) });
    });
  }
  if (contentId.startsWith("/v/") && episodes.length > 0 && !seenIds.has(contentId)) {
    episodes.unshift({ id: contentId, name: "当前集" });
  }
  return episodes;
}

/**
 * 解码 rou.video 的 props.pageProps.ev 混淆对象
 * 结构通常为 { d: "Base64字符串", k: 偏移整数 }
 */
function decodeRouEv(ev) {
  if (!ev) return null;
  if (typeof ev === "string") {
    try { return JSON.parse(ev); } catch (_) { return { videoUrl: ev }; }
  }
  if (typeof ev !== "object" || !ev.d) return ev;
  try {
    const raw = atob(String(ev.d).trim()), shift = Number(ev.k) || 0;
    if (!Number.isInteger(shift) || shift < 0 || shift > 255) return null;
    const bytes = new Uint8Array(raw.length);
    for (let i = 0; i < raw.length; i++) bytes[i] = (raw.charCodeAt(i) - shift) & 255;
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch (_) { return null; }
}

function collectStreamsFromObject(obj, addSource) {
  if (!obj || typeof obj !== "object") return;

  const directKeys = [
    { key: "videoUrl", label: "主线路 (HLS)" },
    { key: "hlsUrl", label: "HLS 线路" },
    { key: "m3u8Url", label: "M3U8 线路" },
    { key: "url", label: "默认线路" },
    { key: "src", label: "直连线路" }
  ];

  for (const item of directKeys) {
    const val = obj[item.key];
    if (typeof val === "string" && val.trim()) {
      addSource(val.trim(), item.label, obj.mime || obj.type);
    }
  }

  // 多清晰度数组和字典；仅识别明确的媒体字段，不递归扫描广告/推荐对象。
  for (const collection of [obj.sources, obj.qualities]) {
    const entries = Array.isArray(collection)
      ? collection.map((value, i) => [String(i + 1), value])
      : collection && typeof collection === "object" ? Object.entries(collection) : [];
    for (const [key, source] of entries) {
      if (typeof source === "string") addSource(source, key, obj.mime || obj.type);
      else if (source && typeof source === "object") {
        addSource(source.url || source.src || source.videoUrl, source.label || source.quality || key, source.mime || source.type);
      }
    }
  }
}

/* ======================== 通用格式化工具 ======================== */

function normalizeVideoPath(ctx, rawHref, baseSite, type = "v") {
  const trimmed = String(rawHref || "").trim();
  if (!trimmed) return "";
  try {
    const abs = ctx.url.resolve(trimmed, baseSite);
    const origin = ctx.url.origin(baseSite);
    if (ctx.url.origin(abs) !== origin) return "";
    const path = abs.slice(origin.length).split(/[?#]/)[0].replace(/\/+$/, "");
    if (["v", "s"].includes(type) && /^\/(?:v|s)\/[a-zA-Z0-9_-]+$/.test(path) && path.startsWith("/" + type + "/") && path.length <= 1024) return path;
  } catch (_) {}
  return "";
}

function extractVidFromPath(path) {
  const m = String(path || "").match(/\/v\/([a-zA-Z0-9_-]+)/);
  return m ? m[1] : "";
}

function normalizeHttpUrl(ctx, rawUrl, baseSite) {
  const trimmed = String(rawUrl || "")
    .replace(/\\u0026/g, "&")
    .replace(/&amp;/gi, "&")
    .replace(/&#(?:0*38|x0*26);/gi, "&")
    .trim();
  if (!trimmed || /^(data:|javascript:|blob:|#)/i.test(trimmed)) return "";
  try {
    const abs = ctx.url.resolve(trimmed, baseSite);
    if (/^https?:\/\//i.test(abs)) return abs;
  } catch (_) {}
  return "";
}

function formatDuration(totalSeconds) {
  const sec = Math.max(0, Math.floor(totalSeconds));
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = sec % 60;
  const pad = n => (n < 10 ? "0" + n : String(n));
  return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${pad(m)}:${pad(s)}`;
}

function cleanSingleLine(str) {
  return String(str || "")
    .replace(/\u00a0/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}
/* ======================== 当前页面载荷与 HLS 媒体处理 ======================== */

function extractRouEv($, html, nextData) {
  const legacy = nextData?.props?.pageProps?.ev;
  if (legacy) return legacy;
  const found = [];
  $("script:not([src])").each((_, el) => {
    const script = $(el).html() || "";
    if (!script.includes("$_TSR.router")) return;
    // TanStack Router 的序列化赋值，仅解析 d 字符串和 k 整数，不 eval 网页代码。
    const pattern = /\bev:\s*(?:\$R\[\d+\]\s*=\s*)?\{\s*d:\s*("(?:\\.|[^"\\])*"),\s*k:\s*(-?\d+)\s*\}/g;
    let match;
    while ((match = pattern.exec(script))) {
      try { found.push({ d: JSON.parse(match[1]), k: Number(match[2]) }); }
      catch (_) { /* 不接受非 JSON 字符串或不完整载荷。 */ }
    }
  });
  return found.length === 1 ? found[0] : null;
}

function withQuery(url, query) {
  const parts = Object.entries(query || {}).map(([key, value]) => encodeURIComponent(key) + "=" + encodeURIComponent(value));
  return url + (parts.length ? (url.includes("?") ? "&" : "?") + parts.join("&") : "");
}

function urlParts(ctx, url) {
  const origin = ctx.url.origin(url);
  const tail = url.slice(origin.length).split("#")[0];
  const index = tail.indexOf("?");
  const path = (index < 0 ? tail : tail.slice(0, index)) || "/";
  const params = Object.create(null);
  if (index >= 0) {
    for (const item of tail.slice(index + 1).split("&")) {
      const pair = item.split("=");
      try { params[decodeURIComponent(pair[0])] = decodeURIComponent(pair.slice(1).join("=").replace(/\+/g, " ")); }
      catch (_) { /* 损坏的分页参数不会推进游标。 */ }
    }
  }
  return { origin, path, params };
}

function isLoginRestriction(html) {
  return /(繁忙時段僅支援註冊用戶|繁忙时段仅支持注册用户|請點擊網站.*登入)/i.test(html);
}

function failLogin(ctx) {
  ctx.fail("AUTH_REQUIRED", "当前时段需要登录，请在源设置中更新 Cookie", { fields: ["cookie"] });
}

function rejectChallenge(ctx, html) {
  const title = (String(html).match(/<title[^>]*>([\s\S]*?)<\/title>/i) || [])[1] || "";
  if (/just a moment|attention required|verify you are human|access denied|人机验证|人機驗證/i.test(title) ||
      /checking your browser|id=["']cf-chl-widget|id=["']challenge-form/i.test(html)) {
    ctx.fail("INVALID_RESPONSE", "站点返回验证页面，请检查网络或更新 Cookie");
  }
}

function addCookie(ctx, url, baseSite, headers) {
  const cookie = String(ctx.settings?.cookie || "").trim();
  if (cookie && ctx.url.origin(url) === ctx.url.origin(baseSite)) {
    headers.Cookie = cookie.replace(/[\r\n]+/g, "; ");
  }
}

function mediaHeaders(ctx, url, pageUrl, baseSite) {
  const headers = { "User-Agent": DEFAULT_UA, Referer: pageUrl, Origin: ctx.url.origin(baseSite) };
  addCookie(ctx, url, baseSite, headers);
  return headers;
}

function checkMediaStatus(ctx, response) {
  if (response.status === 401 || response.status === 403) failLogin(ctx);
  if (response.status === 429) ctx.fail("RATE_LIMITED", "媒体请求过于频繁，请稍后重试", { retryAfterSeconds: 15 });
  if (response.status === 404) ctx.fail("NOT_FOUND", "播放资源不存在");
  if (response.status < 200 || response.status >= 300) ctx.fail("NETWORK", "媒体请求失败 (HTTP " + response.status + ")");
}

async function prepareHls(ctx, source, pageUrl, baseSite) {
  let url = source.url;
  const visited = new Set();
  for (let depth = 0; depth < 4; depth++) {
    ctx.signal.throwIfAborted();
    if (visited.has(url)) ctx.fail("INVALID_RESPONSE", "播放清单循环引用");
    visited.add(url);
    const response = await ctx.http.get(url, {
      headers: mediaHeaders(ctx, url, pageUrl, baseSite), responseType: "base64", timeoutMs: getTimeoutMs(ctx)
    });
    ctx.signal.throwIfAborted();
    checkMediaStatus(ctx, response);
    let bytes;
    try {
      const raw = atob(response.data);
      bytes = new Uint8Array(raw.length);
      for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
    } catch (_) { ctx.fail("INVALID_RESPONSE", "媒体接口返回的二进制数据无效"); }
    if (isPng(bytes)) {
      const part = findRouPngPayload(ctx, bytes.length, (offset, length) => bytes.subarray(offset, offset + length));
      const payload = bytes.subarray(part.offset, part.offset + part.length);
      bytes = part.flags ? inflateRouZlib(ctx, payload, 2 * 1024 * 1024) : payload;
    }
    if (bytes.length > 2 * 1024 * 1024) ctx.fail("UNSUPPORTED", "播放清单超过宿主大小限制");
    const manifest = new TextDecoder().decode(bytes).replace(/^\uFEFF/, "").trimStart();
    if (!manifest.startsWith("#EXTM3U")) {
      rejectChallenge(ctx, manifest);
      if (isLoginRestriction(manifest)) failLogin(ctx);
      ctx.fail("INVALID_RESPONSE", "媒体接口没有返回有效的 HLS 清单");
    }
    const baseUrl = response.url || url;
    const lines = manifest.split(/\r?\n/).map(line => line.trim());
    if (/#EXT-X-BYTERANGE:|\bBYTERANGE=/i.test(manifest)) ctx.fail("UNSUPPORTED", "暂不支持字节范围清单与媒体转换组合");
    const variants = [];
    for (let i = 0; i < lines.length; i++) {
      if (!lines[i].startsWith("#EXT-X-STREAM-INF:")) continue;
      const bandwidth = Number((lines[i].match(/\bBANDWIDTH=(\d+)/) || [])[1]) || 0;
      let next = i + 1;
      while (next < lines.length && (!lines[next] || lines[next].startsWith("#"))) next++;
      if (next < lines.length) variants.push({ url: ctx.url.resolve(lines[next], baseUrl), bandwidth });
    }
    if (variants.length) {
      // 单文件内存入口不能直接替换被包装的子清单，按最高码率逐层解析。
      if (/#EXT-X-MEDIA:.*URI=/i.test(manifest)) ctx.fail("UNSUPPORTED", "暂不支持需要独立音轨的主清单");
      variants.sort((a, b) => b.bandwidth - a.bandwidth);
      url = variants[0].url;
      continue;
    }
    if (!lines.some(line => line && !line.startsWith("#"))) ctx.fail("INVALID_RESPONSE", "播放清单没有媒体分片");
    const result = Object.assign({}, source, {
      manifest, baseUrl, headers: mediaHeaders(ctx, baseUrl, pageUrl, baseSite),
      processor: { request: "request", response: "response", context: { pageUrl, baseSite } }
    });
    delete result.url; // 合同要求 url 与 manifest 二选一。
    return result;
  }
  ctx.fail("INVALID_RESPONSE", "播放清单嵌套层数过多");
}

const ROU_PNG_SIGNATURE = [137, 80, 78, 71, 13, 10, 26, 10];
function isPng(bytes) {
  return bytes.length >= 8 && ROU_PNG_SIGNATURE.every((value, i) => bytes[i] === value);
}
function readU32(bytes, offset = 0) {
  return bytes[offset] * 16777216 + bytes[offset + 1] * 65536 + bytes[offset + 2] * 256 + bytes[offset + 3];
}

function findRouPngPayload(ctx, size, read) {
  let offset = 8, found = null;
  for (let chunks = 0; offset + 12 <= size && chunks < 4096; chunks++) {
    ctx.signal.throwIfAborted();
    const header = read(offset, 8);
    const length = readU32(header);
    if (length > size - offset - 12) ctx.fail("INVALID_RESPONSE", "PNG 媒体数据块不完整");
    const type = String.fromCharCode(header[4], header[5], header[6], header[7]);
    if (type === "roUd") {
      if (found || length < 2) ctx.fail("INVALID_RESPONSE", "PNG 播放载荷无效");
      const flags = read(offset + 8, 1)[0];
      if (flags !== 0 && flags !== 1) ctx.fail("UNSUPPORTED", "PNG 播放载荷版本不支持");
      found = { flags, offset: offset + 9, length: length - 1 };
    }
    offset += length + 12;
    if (type === "IEND") {
      if (length !== 0 || !found) ctx.fail("INVALID_RESPONSE", "PNG 响应没有播放载荷");
      return found;
    }
  }
  ctx.fail("INVALID_RESPONSE", "PNG 响应损坏或缺少播放载荷");
}

function readHandleBytes(ctx, handle, offset, length) {
  if (length > 8 * 1024 * 1024) ctx.fail("UNSUPPORTED", "压缩媒体资源过大");
  const result = new Uint8Array(length);
  for (let i = 0; i < length; i += 65536) {
    ctx.signal.throwIfAborted();
    result.set(ctx.binary.read(handle, offset + i, Math.min(65536, length - i)), i);
  }
  return result;
}

function writeHandleBytes(ctx, original, bytes) {
  if (!bytes.length) ctx.fail("INVALID_RESPONSE", "解压后的媒体为空");
  // 用已有句柄生成最多 64 KiB 的块，避免每次 write 都复制整片媒体。
  let seed = ctx.binary.slice(original, 0, Math.min(ctx.binary.size(original), 65536));
  while (ctx.binary.size(seed) < Math.min(bytes.length, 65536)) seed = ctx.binary.concat([seed, seed]);
  if (ctx.binary.size(seed) > 65536) seed = ctx.binary.slice(seed, 0, 65536);
  const parts = [];
  for (let i = 0; i < bytes.length; i += 65536) {
    ctx.signal.throwIfAborted();
    const chunk = bytes.subarray(i, Math.min(i + 65536, bytes.length));
    parts.push(ctx.binary.write(ctx.binary.slice(seed, 0, chunk.length), 0, chunk));
  }
  return parts.length === 1 ? parts[0] : ctx.binary.concat(parts);
}

function sniffMediaMime(head, kind) {
  if (head.length > 376 && head[0] === 0x47 && head[188] === 0x47 && head[376] === 0x47) return "video/mp2t";
  const tag = String.fromCharCode(...head.subarray(4, 8));
  if (["ftyp", "styp", "moof", "moov"].includes(tag)) return "video/mp4";
  if (new TextDecoder().decode(head.subarray(0, 16)).startsWith("WEBVTT")) return "text/vtt";
  return "application/octet-stream";
}

/* RFC 1950/1951 zlib+DEFLATE 解压：仅处理格式，不依赖 npm、Node 或浏览器 API。 */
function inflateRouZlib(ctx, bytes, limit) {
  const bad = () => ctx.fail("INVALID_RESPONSE", "PNG 压缩载荷损坏");
  if (bytes.length < 6 || (bytes[0] & 15) !== 8 || (bytes[0] >> 4) > 7 || ((bytes[0] << 8) + bytes[1]) % 31) bad();
  if (bytes[1] & 32) ctx.fail("UNSUPPORTED", "不支持带预设字典的压缩媒体");
  const end = bytes.length - 4;
  let position = 2, bits = 0, count = 0, used = 0, lastCheck = 0;
  let output = new Uint8Array(Math.min(32768, limit));
  const ensure = size => {
    if (size > limit) ctx.fail("UNSUPPORTED", "解压后的媒体超过大小限制");
    if (size > output.length) {
      const expanded = new Uint8Array(Math.min(limit, Math.max(size, output.length * 2)));
      expanded.set(output); output = expanded;
    }
  };
  const fill = width => { while (count < width && position < end) { bits |= bytes[position++] << count; count += 8; } };
  const take = width => {
    fill(width); if (count < width) bad();
    const value = bits & ((1 << width) - 1); bits >>>= width; count -= width; return value;
  };
  const tree = lengths => {
    const counts = new Uint16Array(16), next = new Uint16Array(16);
    let max = 0, remaining = 1;
    for (const n of lengths) { if (n > 15) bad(); if (n) { counts[n]++; max = Math.max(max, n); } }
    if (!max) return null;
    for (let n = 1; n <= 15; n++) { remaining = remaining * 2 - counts[n]; if (remaining < 0) bad(); }
    let code = 0;
    for (let n = 1; n <= max; n++) { code = (code + counts[n - 1]) << 1; next[n] = code; }
    const table = new Uint16Array(1 << max);
    for (let symbol = 0; symbol < lengths.length; symbol++) {
      const width = lengths[symbol]; if (!width) continue;
      let value = next[width]++, reverse = 0;
      for (let n = 0; n < width; n++) { reverse = (reverse << 1) | (value & 1); value >>>= 1; }
      const entry = (width << 9) | (symbol + 1);
      for (let i = reverse; i < table.length; i += 1 << width) table[i] = entry;
    }
    return { table, max };
  };
  const decode = t => {
    if (!t) bad(); fill(t.max);
    const entry = t.table[bits & ((1 << t.max) - 1)], width = entry >> 9;
    if (!entry || count < width) bad();
    bits >>>= width; count -= width; return (entry & 511) - 1;
  };
  const lengthBase = [3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258];
  const lengthExtra = [0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0];
  const distanceBase = [1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577];
  const distanceExtra = [0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13];
  let final;
  do {
    ctx.signal.throwIfAborted();
    final = take(1); const type = take(2);
    if (type === 0) {
      take(count % 8);
      const length = take(16), inverse = take(16);
      if ((length ^ inverse) !== 65535) bad();
      ensure(used + length);
      for (let i = 0; i < length; i++) output[used++] = take(8);
      continue;
    }
    if (type === 3) bad();
    let literals, distances;
    if (type === 1) {
      literals = new Uint8Array(288); distances = new Uint8Array(32).fill(5);
      for (let i = 0; i < 288; i++) literals[i] = i < 144 ? 8 : i < 256 ? 9 : i < 280 ? 7 : 8;
    } else {
      const nl = take(5) + 257, nd = take(5) + 1, nc = take(4) + 4;
      if (nl > 286) bad();
      // RFC 顺序完整列出，避免长度码树使用字母/数字自然顺序。
      const codeOrder = [16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15];
      const codeLengths = new Uint8Array(19);
      for (let i = 0; i < nc; i++) codeLengths[codeOrder[i]] = take(3);
      const codeTree = tree(codeLengths), lengths = [];
      while (lengths.length < nl + nd) {
        const symbol = decode(codeTree);
        if (symbol < 16) { lengths.push(symbol); continue; }
        if (symbol > 18 || (symbol === 16 && !lengths.length)) bad();
        const repeats = symbol === 16 ? take(2) + 3 : symbol === 17 ? take(3) + 3 : take(7) + 11;
        const value = symbol === 16 ? lengths[lengths.length - 1] : 0;
        if (lengths.length + repeats > nl + nd) bad();
        for (let i = 0; i < repeats; i++) lengths.push(value);
      }
      literals = lengths.slice(0, nl); distances = lengths.slice(nl);
      if (!literals[256]) bad();
    }
    const literalTree = tree(literals), distanceTree = tree(distances);
    while (true) {
      if (used - lastCheck >= 16384) { ctx.signal.throwIfAborted(); lastCheck = used; }
      const symbol = decode(literalTree);
      if (symbol === 256) break;
      if (symbol < 256) { ensure(used + 1); output[used++] = symbol; continue; }
      if (symbol > 285) bad();
      const index = symbol - 257, length = lengthBase[index] + take(lengthExtra[index]);
      const distanceCode = decode(distanceTree);
      if (distanceCode > 29) bad();
      const distance = distanceBase[distanceCode] + take(distanceExtra[distanceCode]);
      if (distance > used) bad();
      ensure(used + length);
      for (let i = 0; i < length; i++) { output[used] = output[used - distance]; used++; }
    }
  } while (!final);
  let a = 1, b = 0;
  for (let i = 0; i < used; i++) {
    a += output[i]; b += a;
    if (i % 5552 === 5551) { a %= 65521; b %= 65521; ctx.signal.throwIfAborted(); }
  }
  const checksum = (((b % 65521) << 16) | (a % 65521)) >>> 0;
  if (checksum !== readU32(bytes, end)) bad();
  return output.subarray(0, used);
}

/* 详情紧接播放时只复用短时有效页面；HLS 清单仍每次实时解析。 */
function contentSnapshotState(ctx) {
  const key = JSON.stringify([ctx.settings, ctx.cache.generation]);
  if (key !== snapshotContextKey) { pageSnapshots.clear(); snapshotContextKey = key; }
  return { key, ttlMs: Math.min(15, Math.max(0, ctx.cache.seconds(60))) * 1000 };
}
async function readContentPage(ctx, url, refresh) {
  ctx.signal.throwIfAborted();
  const state = contentSnapshotState(ctx), saved = pageSnapshots.get(url);
  if (!refresh && state.ttlMs > 0 && saved && Date.now() - saved.savedAt < state.ttlMs) {
    return { html: saved.html, contextKey: state.key, fetchedAt: saved.savedAt };
  }
  const html = await fetchHtml(ctx, url);
  return { html, contextKey: state.key, fetchedAt: Date.now() };
}
function rememberContentPage(ctx, url, page) {
  ctx.signal.throwIfAborted();
  const state = contentSnapshotState(ctx);
  if (state.ttlMs <= 0 || state.key !== page.contextKey) return;
  if (pageSnapshots.size >= 8 && !pageSnapshots.has(url)) pageSnapshots.delete(pageSnapshots.keys().next().value);
  pageSnapshots.set(url, { html: page.html, savedAt: page.fetchedAt });
}
