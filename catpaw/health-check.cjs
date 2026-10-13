const DEFAULT_TIMEOUT_MS = 30000;

function safeError(error) {
  const message = String(error?.message || error || 'Unknown error');
  return message.replace(/https?:\/\/[^\s)]+/g, '[URL omitted]').slice(0, 500);
}

async function invoke(server, site, action, payload, timeoutMs) {
  let timer;const controller=new AbortController();
  try {
    return await Promise.race([
      typeof server.healthAction==='function'?server.healthAction(site,action,payload,{signal:controller.signal}):server.inject({ method: 'POST', url: `${site.api}/${action}`, payload }),
      new Promise((_, reject) => { timer = setTimeout(() => (controller.abort(new Error(`${action} timed out after ${timeoutMs}ms`)),reject(controller.signal.reason)), timeoutMs); })
    ]);
  } finally { clearTimeout(timer);controller.abort(new Error('只读检查动作已结束')); }
}

function jsonReply(reply, action) {
  let data;
  try { data = reply.json(); } catch { throw new Error(`${action} HTTP ${reply.statusCode}; invalid JSON`); }
  if (reply.statusCode < 200 || reply.statusCode >= 300){const e=new Error(`${action} HTTP ${reply.statusCode}${data?.err ? `: ${safeError(data.err)}` : ''}`);e.code=data?.code;throw e;}
  if(data?.catalogueError){const error=new Error(safeError(data.catalogueError));error.code=data.code;throw error;}
  if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Error(`${action} returned invalid structure`);
  if (data.err) throw new Error(`${action}: ${safeError(data.err)}`);
  return data;
}

async function runSourceHealthCheck(server, site, { timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
  const row = { source: String(site?.name || site?.key || 'unknown'), key: site?.key || null, enabled: site?.enable !== false, checks: {}, passed: false };
  try {
    if (!site?.api) throw new Error('source API route missing');
    const homeReply = await invoke(server, site, 'home', {}, timeoutMs);
    const home = jsonReply(homeReply, 'home');
    const classes = (Array.isArray(home.class) ? home.class : []).filter(c=>!c.utility&&!['__status','__play','collectionGuide','aiQuotaStatus'].includes(String(c.type_id)));
    if (!classes.length) throw new Error('home returned no categories');
    row.checks.home = { passed: true, categories: classes.length };
    const category = classes.find(c => ['latest', 'home'].includes(c?.type_id)) || classes[0];
    if (!category || category.type_id == null) throw new Error('home category has no type_id');
    row.category = String(category.type_id).slice(0, 120);
    const listReply = await invoke(server, site, 'category', { id: category.type_id, page: 1, filters: {} }, timeoutMs);
    const listing = jsonReply(listReply, 'category');
    const cards = Array.isArray(listing.list) ? listing.list : [];
    if (!cards.length) throw new Error('category returned no cards');
    row.checks.category = { passed: true, cards: cards.length, pagecount: Number.isFinite(Number(listing.pagecount)) ? Number(listing.pagecount) : null };

    const card = cards.find(c => c && (c.vod_id || c.id));
    if (card) {
      const itemId = String(card.vod_id ?? card.id);
      row.sampleTitle = String(card.vod_name || card.title || '').slice(0, 160);
      try {
        const detailReply = await invoke(server, site, 'detail', { id: itemId }, timeoutMs);
        const detail = jsonReply(detailReply, 'detail');
        const item = Array.isArray(detail.list) ? detail.list[0] : null;
        if (!item) throw new Error('detail returned no item');
        row.checks.detail = { passed: true, episodes: String(item.vod_play_url || '').split('$$$').reduce((n, g) => n + g.split('#').filter(Boolean).length, 0) };
        const first = String(item.vod_play_url || '').split('$$$')[0].split('#')[0];
        const dollar = first.indexOf('$');
        row.checks.play = { passed: null, status:'NOT_RUN', reason:'只读健康检查不执行播放、奖励或媒体请求', episodeAvailable:dollar>=0&&dollar<first.length-1 };
      } catch (error) { row.checks.detail = { passed: false, error: safeError(error) }; }
      const term = row.sampleTitle || '';
      if (term) {
        try {
          const searchReply = await invoke(server, site, 'search', { wd: term, page: 1 }, timeoutMs);
          const search = jsonReply(searchReply, 'search');
          row.checks.search = { passed: Array.isArray(search.list)&&search.list.length>0, results: Array.isArray(search.list) ? search.list.length : 0 };
          if (Array.isArray(search.list)&&!search.list.length)row.checks.search.reason='搜索样本未命中';
          if (!Array.isArray(search.list)) row.checks.search.error = 'search list malformed';
        } catch (error) { row.checks.search = { passed: false, error: safeError(error) }; }
      } else row.checks.search = { passed: null, reason: 'sample has no searchable title' };
    }
    row.passed = row.checks.home?.passed === true && row.checks.category?.passed === true;
  } catch (error) { row.error = safeError(error);row.status=error.code==='AUDIT_BLOCKED'?'NOT_RUN':'FAIL'; }
  if(row.passed)row.status='PASS';return row;
}

module.exports = { runSourceHealthCheck, safeError };
