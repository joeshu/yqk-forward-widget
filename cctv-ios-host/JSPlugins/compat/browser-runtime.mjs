// The upstream browser/Chromium branch cannot run inside JavaScriptCore.
// Keep index.js intact, but report capabilities truthfully instead of pretending login works.
const unsupported = () => { throw new Error('此 JS 运行环境不包含 Node.js/Chromium 会员浏览器会话') }
export const browserLoginFlow = { status: () => ({ available: false, reason: '需要独立 Node.js/Chromium 服务' }), start: unsupported, check: unsupported }
export const claimsLocalPath = () => false
export const credentialRejected = () => false
export const handleLocalRequest = unsupported
export const shutdown = async () => {}
