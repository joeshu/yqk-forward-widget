import '../compat/platform.mjs'
import extractor from './upstream/index.js'
import { CHANNELS, CHANNEL_BY_REF, logoFor } from './upstream/channels.js'
import { createCKey } from './upstream/ckey.js'
import { FILLER_BODY } from './upstream/libvlc-view.js'

const catalog = CHANNELS.map(channel => ({ ...channel, ref: `ysp-${channel.id}`, logo: logoFor(channel.livePid) }))
const api = {
  start: () => ({ engine: 'JavaScriptCore', source: 'joeshu/iptv', publicChannels: catalog.length, browser: false }),
  catalog: () => catalog,
  resolve: async ({ ref, userAgent = '', selfBase = '' }) => {
    if (!CHANNEL_BY_REF.has(ref)) throw new Error('此本机 JS 服务仅提供公开频道')
    return extractor.resolve(ref, { selfBase, client: { ua: userAgent, tag: 'CCTVHost' } })
  },
  epg: async ({ ref, day }) => {
    const channel = CHANNEL_BY_REF.get(ref)
    if (!channel) throw new Error('未知频道')
    return extractor.epg.programmes(channel.livePid, day, { timeoutMs: 5000 })
  },
  ckey: ({ channelId, options = {} }) => createCKey(channelId, options),
  filler: () => ({ base64: FILLER_BODY.toString('base64') }),
  stop: () => { extractor.clearResolveCache(); return true },
}
globalThis.CCTVHostJS = api
globalThis.__cctvInvoke = (operation, payload, complete) => {
  Promise.resolve().then(() => {
    if (!Object.hasOwn(api, operation)) throw new Error('未知 JS 操作')
    return api[operation](payload || {})
  }).then(result => complete(JSON.stringify({ ok: true, result })),
    error => complete(JSON.stringify({ ok: false, error: String(error?.message || error) })))
}
