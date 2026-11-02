# 本机影视资源使用说明（0.18）

底部导航为 **CCTV｜频道｜首页｜资源｜设置**。CCTV 使用原生 SDK；频道播放 M3U；首页汇总继续观看、收藏和固定来源，并进入影视库；资源负责导入、启停、配置、日志、导出和删除。没有 iCloud 功能。

## 导入和使用

1. 打开「资源 → ＋」，选择 JS/Python/ZIP 文件，或输入资源文件下载地址。CatPaw 的 `.js.md5` 地址可以直接输入，宿主会下载配对脚本并校验。
2. 直接导入 `.js`、`.mjs`、`.cjs`、`.py`，或者带依赖文件的 ZIP。导入只安装文件，不执行代码。
3. 导入器会识别 HTTP 200 返回的 HTML 登录/拦截页，并在保存前说明来源权限、登录状态或直链问题，避免把网页错误地登记成脚本。
4. 在「资源」列表启用资源；到「首页」选择固定来源卡片或点按「影视库」选择已导入的资源。服务型资源只在用户打开时启动，TVBox JSON API 则直接请求，不启动插件运行时。
5. 选定来源后，进入推荐或分类，使用搜索和筛选，打开影片详情，再选择线路与分集播放。CatPawOpen 服务可提供多个来源，站点选择器会列出其 `/config` 返回的站点；首页「全站搜索」会逐来源显示运行、进度、结果和错误，不自动启动其余插件。
6. 直播提取包提供「添加直播订阅」，生成本机 `/all.m3u`，在「频道」播放。影视搜索结果不会混入直播列表。

导入猫爪时可直接输入 `https://joeshu.github.io/yqk-forward-widget/catpaw/index.js.md5`。宿主下载对应 JS，核对 MD5 后安装；MD5 文件本身不会作为 JS 执行。校验仅证明传输内容一致。

「资源 → ＋」提供自动识别、Python Spider、CatVod/TVBox JS、Node.js Mobile、TVBox JSON、MacCMS、直播列表和本地文件入口。脚本链接与 ZIP 快捷入口最终共用 `MediaPackageImporter` 的静态检查，不会因入口标签换用不同的解析器；Node 快捷入口只在确实需要动态 Node 模块时使用，并会拒绝要求 JavaScriptCore / CPython 的协议。导入结果会显示识别出的运行时和协议；未静态声明的能力需在资源详情启动服务后实际查询，导入成功不等于播放解码成功。

Node ZIP 包的入口按 `cctvhost.json` 的 `entry`、`package.json` 根 `exports`、`module` / `main` 和常见入口名依次识别。根导出支持字符串、数组及 `import` / `require` / `node` / `default` 条件；只声明 `./subpath` 的 exports 不会误当成包入口，导出目标仍受资源目录路径校验限制。

## 包类型

| 类型 | 本机引擎 | 接口 |
| --- | --- | --- |
| 普通 JS | JavaScriptCore；CommonJS `require()` 或非 Spider npm dependencies 默认走 Node.js Mobile | home/category/search/detail/play，可选 channels/catalog/resolve |
| CatPaw JS Spider | JavaScriptCore 本机路由适配器 | ESM 默认导出的工厂函数或旧式对象；运行 `api(fastify)` 的 init/home/category/detail/play/search 路由 |
| CatVod / TVBox 风格 JS | JavaScriptCore 或清单指定 Node | 新式 `home/category/search/detail/play` 与旧式 `homeContent/categoryContent/searchContent/detailContent/playerContent` |
| Hamo v3 影视源 | JavaScriptCore | `apiVersion: 3` 的 `home/category/search/detail/resolve`；兼容 `$http.get`、带 TTL 的 `$cache`、Base64 `$crypto.encode` |
| drpy 规则 | JavaScriptCore + 固定版本 dr_py 引擎 | 声明 `var/let/const rule = {...}` 的规则文件 |
| Python Spider | CPython 3.13 | Spider.init/homeContent/homeVideoContent/categoryContent/searchContent/detailContent/playerContent/destroy |
| CatPawOpen / 猫爪 Node 服务 | Node.js Mobile 18.20.4 | `start/stop` + `/config`、`/spider/...` |
| NanoTV v2 直播服务 | Node.js Mobile 18.20.4 | `nanoService.start/channels/resolve/stop`；本机 `/all.m3u`、`/live/<频道>.m3u8` 与 HLS 会话续期 |
| iptv 项目提取模块（如咪咕） | Node.js Mobile | fetch(options) 返回 groups；resolve(ref, context) 返回 URL |
| 已有 Python HTTP 服务 | CPython | 原有服务启动参数与 HTTP 接口 |

JS 原文件由 JS 引擎执行，Python 原文件由 CPython 执行，均在 iPhone 进程内。Node 框架首次启用相关资源才加载，不在 CCTV 开台时启动。

iPhone 的 CPython 不包含也不能启动桌面 `ffmpeg` 命令行程序。应用已链接
`alivcffmpeg.framework`；Python 现可导入 `cctvhost_ffmpeg`，读取本机构建的
FFmpeg 版本和解码器能力，并用 `cctvhost_ffmpeg.probe(url, headers={}, timeout=12)`
检查本地文件或 HTTP(S) 媒体是否包含视频、音频和字幕流。接口设置 1–30 秒的单次 I/O
等待上限、2 MiB 格式探测上限、256 个探测包上限和 5 秒流分析参数，不会启动进程。当前 Python 接口用于媒体
探测；任意 FFmpeg 命令行参数、滤镜和转码任务仍需各自的原生 API 支持。

Python 同时内置纯 Python `Crypto` 与 `Cryptodome` 兼容包，常见 PyCryptodome
脚本可直接导入，无需安装桌面 wheel 或加载原生扩展。覆盖 AES ECB/CBC/CFB/OFB/CTR/GCM/EAX、
MD5/SHA-1/SHA-2/SHA-3/SHAKE、HMAC/CMAC、PBKDF2/HKDF/scrypt、公钥 RSA PKCS#1 v1.5/OAEP
加密、PKCS#7/X9.23/ISO7816 填充、随机字节和常用 `Crypto.Util` 辅助接口。它不包含完整
PyCryptodome：RSA 私钥运算与签名、ECC、DES/3DES、ChaCha20、CCM 和原生内部模块仍不支持；
依赖这些功能的脚本需要自行适配。

需要高速逐块 AES-CTR 时，Python 还可直接使用宿主内建的 `hostcrypto`，无需 `ctypes`、
wheel 或插件自建服务：

```python
import hostcrypto

ctr = hostcrypto.AES_CTR(key16, iv16)  # key 和 counter block 都必须是 16 字节
try:
    first = ctr.update(cipher_bytes[:4096])
    rest = ctr.update(cipher_bytes[4096:])  # 同一个对象会连续推进 counter
finally:
    ctr.close()
```

iOS 端由 CommonCrypto 原生实现，`Crypto`/`Cryptodome` 兼容包继续保留，供其它算法和旧脚本使用。
桌面测试中的 `hostcrypto.py` 是兼容回退实现。8 MB 在真机上低于 2 秒是性能验收目标，须以目标 iPhone
实测记录确认；模拟器或桌面耗时不能替代该验收。

## ZIP 清单

ZIP 根目录可包含 `cctvhost.json`；也支持外层再套一个文件夹。存在清单时优先使用清单，否则尝试 package.json 和常见入口。CommonJS 代码使用静态 `require("...")` 或 `package.json` 声明 dependencies 时，未指定运行时时默认选择 Node.js Mobile。导入 `node:*` 核心模块或 Node 内置模块（如 `crypto`、`fs`、`http`、`https`）时也会选择 Node.js Mobile，包括清单误标为 `javascript` 的 CatVod 源；检测会扫描 ZIP 内 `.js`、`.mjs`、`.cjs` 文件，包含 `node_modules`。旧版本已导入的资源会在下次启动时重新识别。CatPaw Spider、Hamo 等专用协议仍遵守各自运行时要求。Node 包需要在 ZIP 内带齐它使用的 `node_modules`，应用不会联网安装 npm 依赖。用变量拼出的动态模块名无法静态识别；这类包可在清单中指定 `runtime: node`。无法确定入口时会明确报错。

Node 核心模块按下表处理：

| 模块 | JavaScriptCore 兼容层 | Node.js Mobile |
| --- | --- | --- |
| `node:crypto` | 只有常见摘要、HMAC、随机数等轻量适配 | Node 原生 Crypto API |
| `node:fs` | ZIP 只读及内存临时文件子集 | Node 文件 API；相对路径落在资源数据目录 |
| `node:http` / `node:https` | 不提供 Node 兼容实现 | Node HTTP/HTTPS API |
| `node:stream` / `node:buffer` / `node:url` | 有常用适配子集 | Node 原生 API |

包含 Node 核心模块导入的影视源会交给 Node.js Mobile（Node 18.20.4），避免把部分 JSC 适配误认为完整 Node 模块。`child_process` 的外部进程调用和 `worker_threads.Worker` 会被宿主拒绝；任意 `.node` 原生扩展也无法加载。依赖 ffmpeg 等外部二进制的源仍需改成纯 JS/WASM 或服务端方案。

### Node 运行时与媒体服务

CommonJS 的 `require()`、清单声明 `runtime: "node"`、或静态导入 `node:*` 核心模块时会选择内嵌
Node.js Mobile 18.20.4。`node:crypto`、`node:http`、`node:https` 和 `node:fs` 使用 Node 运行时接口；
其中 `fs` 的可写相对路径受限于该资源的数据目录。JavaScriptCore 会话只提供文档表格所列的兼容子集，
不能把 JSC 中的 `http`、`https` 或部分 `crypto` 适配当成完整 Node 行为。CatPaw Spider、Hamo 等专用
协议仍运行在各自指定的 JavaScriptCore 会话。

Node 插件可以用 `server.listen(0, "127.0.0.1")` 获取系统分配的端口，并在监听回调后通过
`server.address().port` 读取它；但普通插件的这个地址不会自动注册到宿主媒体代理，也不会被改写成 AVPlayer 可用的媒体 URL。
CatPawOpen 是专用例外：宿主只把它声明的 `/spider/...` 服务路由转接到已发现的服务地址。宿主为每个 Node 插件跟踪最多
4 个 loopback Server 和关联连接，并在 `stop`/`close` 或资源停止时关闭。解密媒体应走宿主 `localProxy()` 协议，不能把媒体交付依赖于插件另起 HTTP 监听。Python Spider 可直接返回
`[status, headers, bytes]`；Node.js Mobile 的 `localProxy()` 可返回同样结构，或返回宿主管理的数据目录中的受限文件引用。iOS 后台运行受系统生命周期限制；停止资源时宿主会清理
注册的计时器、连接和监听。

Node `https.request/get` 先尝试 Node 原生 TLS。默认 TLS 配置下，若在收到响应前发生连接或 TLS 握手错误，宿主会通过
带随机令牌的回环接口让内嵌 Python `urllib` 重试一次，并透传请求头、Range、状态码、响应头和响应内容（最多 16 MiB）。
Python 仍使用默认 CA 证书校验；证书校验失败、自定义 TLS 参数或自定义 Agent 不触发回退。明文 HTTP、已有原生 TLS
响应的请求和自定义 Node TLS 配置都保留原行为。`node:child_process` 不能启动桌面二进制；`Worker` 和任意 `.node` 扩展不支持。

Python Spider 的媒体中转应优先用 `localProxy()`，避免为一个解密流程另起 `http.server`：

```python
def playerContent(self, flag, vid, vipFlags):
    return {"url": "cenc://" + vid, "proxy": 1,
            "format": "mp4", "contentType": "video/mp4"}

def localProxy(self, params):
    # url、method、headers、range；upstreamHeaders 是 playerContent 的源站请求头
    return [206, {"Content-Type": "video/mp4", "Accept-Ranges": "bytes",
                  "Content-Range": "bytes 0-1023/8966975"}, chunk_bytes]
```

`proxy: 1` 会使 `playback()` 将自定义绝对 URI 改写成本机 `/proxy/<token>` 地址，供 AVPlayer 使用。
请求会把播放器的 `GET`/`HEAD`、`Range` 和常用请求头传入 `localProxy()`；参数 `url` 保留原地址，
`headers` 是播放器请求头，`range` 是 Range 字符串，`upstreamHeaders` 是播放地址返回的源站请求头。
回调返回 `[status, headers, body]`，其中 body 为 bytes；宿主管理端口和 HTTP 响应，不把源站 Cookie 交给播放器。
单次响应上限 16 MiB，较大媒体应返回 Range 分片。原有 `/proxy?url=...` 调用形式继续兼容。
Python Spider 为兼容非线程安全脚本仍串行执行；代理调用等待前一个回调的排队上限为 120 秒，以容纳首轮下载/解密期间播放器并发的 Range 或 HEAD 请求。普通影视接口仍使用原 12 秒默认排队上限。

Node.js Mobile 资源也可导出 `localProxy(params)`。Node 回调如果需要传输大文件，可把完成的媒体放在该资源的数据目录内，并将第三项设为
`{__cctvhostFileResponse: true, path, offset, length}`。宿主会校验真实路径仍位于该资源数据目录、文件范围有效且单次响应不超过 16 MiB，随后从文件读取 Range 分片；视频内容不经过 2 MiB 的 Node JSON 控制桥。HEAD 保留声明的 `Content-Length`，但不读取文件内容。文件引用只供 Node 宿主内部使用，Python Spider 应继续直接返回 bytes。

示例 `Plugins/example-encrypted-media.py` 使用标准库解析 MP4、按样本解密并支持 Range；资源的「插件选项」JSON
可通过 `items` 配置分集 URL、32 位十六进制 AES-128 密钥和请求头。模板支持未分片 MP4、`stsz/stsc/stco`
或 `co64`、`tenc`/`senc` 每样本 8 或 16 字节 IV、CTR `cenc` 和标准 HTTP Range；文件最大 128 MiB，
单次代理响应和 `moov` 最大 16 MiB。不支持 fragmented MP4 (`moof`)、pattern encryption、外置 IV 表或所有
私有 DRM 变体，也不替来源实现登录、签名和密钥派生。导入前需用目标来源的真实媒体样本验证；模板不依赖 ffmpeg
或插件自建监听端口。

```json
{
  "schemaVersion": 1,
  "name": "我的影视",
  "runtime": "javascript",
  "protocol": "catvod-js",
  "moduleType": "esm",
  "entry": "src/index.js",
  "options": {"playTimeoutMs": 20000}
}
```

`options.playTimeoutMs` 可将播放解析接口等待时间设置为 1,000–120,000 毫秒，默认 15,000 毫秒；
超出范围的值会夹到边界，无效或零值回到默认值。此值只作用于 `play` 请求，列表、详情、搜索继续使用
原有请求超时。Python Spider 等插件若 `playerContent()` 本身需下载、签名或解密，可据实际耗时增加该值。

`runtime` 支持 `javascript`、`python`、`node`。`protocol` 支持 `cctvhost.media/1`、`catvod-js`、`catvod-spider`、`drpy`、`python-spider`、`python-http`、`iptv-extractor`、`catpaw-http`。清单中的 `tvbox`、`tvbox-js`、`catvod-quickjs`、`catvod-open-js` 会规范化为 `catvod-js`；`catvod-open` 根据入口识别为本机 CatPawOpen Node 服务或 CatVod JS。JS 的 moduleType 为 `esm`、`commonjs` 或普通规则使用的 `script`。

CatPaw JS Spider 按附件中的本机 Spider 规范运行：ESM 默认导出工厂，返回 `{ meta, api(fastify) }`，并注册 `/init`、`/home`、`/category`、`/detail`、`/play`、`/search` 六个 POST 路由。兼容默认导出工厂与历史对象导出。请求会按 CatVod 字段传递：搜索 `wd/page/quick`、分类 `id/page/filters/extend`、详情 `id[]`、播放 `flag/id`。打包入口可为单文件，也可通过 ZIP 清单的 `entry` 指向包内入口。

CatVod/TVBox 风格 JS 支持 `export default site => ({ init(ext), home(filter), homeVod(), category(tid, pg, filter, extend), search(key, quick, pg), detail(id), play(flag, id, vipFlags) })`，也兼容旧版 `homeContent/categoryContent/searchContent/detailContent/playerContent`。站点参数可放在 `options` 本身，或 `options.site`；`options.ext` 会传给 `init(ext)`。标准 `net.http/net.json`、`local.get/set/delete` 可在本机使用。没有清单时，导入器会按入口代码识别这类方法式 Spider。

Hamo v3 单文件影视源可直接作为 JS 资源导入。宿主会把其 `title/poster/sources` 数据映射到影视卡片、详情线路和分集，并把分集引用保存在本机播放 ID 中，交给 `resolve` 解析；返回网页地址时会进入网页播放路径。`$http` 使用本机有界 HTTP 客户端，`$cache` 按来源隔离并支持 TTL，`$crypto.encode` 支持 UTF-8、Base64 与十六进制转换。

TVBox type 3 的远程 `.py` 若提供标准 `class Spider` 接口，可按 Python Spider 导入。依赖 Android `/sdcard`、Activity 或向 Android TVBox 写配置的自动加载器，在 iOS 中不能执行这些 Android 专属动作；导入后会在资源详情中显示说明。Android/JAR `csp_*` 插件仍不能在 iOS 本机运行。

CatPawOpen 服务 ZIP 可将 `entry` 指向服务入口（例如 `src/index.js`），入口导出 `start()`/`stop()` 并在本机监听，服务须实现 `/config` 与 `/spider/<key>/3/...`。导入器会检查入口及 `router.js`，自动识别常见 Node 服务包；Node 依赖须一并放进 ZIP 的 `node_modules`。启用后，影视来源选择器按 `/config` 提供的站点显示与搜索。

NanoTV v2 的单文件 JS 带 `nanoTV-declaration` JSON 头并导出 `globalThis.nanoService`。CCTVHost 检查声明版本、入口、能力及网络主机后，将其识别为 Node.js Mobile 的直播服务。服务详情显示 NanoTV 协议版本和直播能力，不会把它误列为影视站点。选择“打开直播频道”会启动服务、读取 `/all.m3u` 并加入“频道”订阅；每个 M3U 项会把 `source`、`rate`、`start`、`end` 等查询参数传回 `resolve`，可用于来源选择、码率和 JCE 时移。HLS 子清单、分片和密钥经本机流式代理，请求播放清单时按服务回调刷新签名地址；多个并发刷新合并，刷新失败采用有界退避。服务停止会清理对应会话和定时器。

NanoTV 首次打开频道才按脚本逻辑尝试设备会话注册；服务启动、`/health` 成功和 64 项静态频道表可读，都不能证明上游注册成功或 AVPlayer 已解码首帧。遇到黑屏时查看该服务独立日志中的设备注册、`resolve`、HTTP 状态和媒体代理阶段；校验通过只说明导入文件一致，不代表上游账号、地域、签名或视频流可用。当前附件脚本在 Node `--jitless` 下已离线验证启动、能力查询、64 项频道表、加密桥接和停止；未在此环境触发真实 ytpcloudws 注册或真机播放。

`.js.md5` 可以直接作为链接导入。宿主先读取校验文件，再从最终校验响应的同目录下载脚本；若脚本声明猫源配置，会在同源下载 `index.config.js.md5` 与 `index.config.js`。本地 ZIP 中若带 `index.js.md5`、`index.config.js.md5`，导入前逐个核对并在详情显示已校验的文件名；不匹配时拒绝安装，原有服务和用户数据保留。MD5 是一致性校验，不是来源签名。

TVBox 配置支持两种可直接使用的 HTTP JSON CMS 来源：type 1 和 type 4。type 1/4 作为影视来源加入首页；CCTVHost 按 `filter=true`、`wd/quick/pg`、`ac=detail/t/pg`、`ac=detail/ids` 与 `play/flag` 发送请求，保留源 URL 查询参数，并传递 `ext` 与请求头。列表、分类、影片详情、多线路、多分集、type 1 直出地址和 type 4 播放解析响应会映射到现有影视页与 AVPlayer/Web 播放链路。请求和响应受超时、URL、请求头、2 MiB 响应体限制；上游响应或解码失败会显示为来源错误。type 3/JAR 明确不支持，iOS 不会下载或运行 JAR；TVBox 的 JS/Python/ZIP 脚本仍走上面的现有脚本导入适配器。导入成功只表示文件和入口已识别，不能证明视频已播放，播放需以 AVPlayer 首帧为准。

MacCMS JSON/XML 接口可在「资源 → ＋ → MacCMS 影视接口」单独添加。保存时不会请求或执行接口；选中该影视来源后，宿主用 `ac=videolist` 请求分类、列表和搜索，用 `ac=detail&ids=…` 请求详情，并自动接受 JSON 或 `<rss><list><video>`、`<rss><class><ty>` 格式的 XML。播放线路中的分集 URL、源请求头和完整查询参数会传入现有播放器分流。XML 输入上限 2 MiB、节点 50,000、文本 1 MiB；外部实体不解析。XML 只覆盖上述常见结构，站点私有 XML 扩展、需要网页登录的来源仍需实际端点样本确认。

跨来源搜索每次最多并行检查 3 个独立来源；同一个 Python、Node.js 或 JavaScriptCore 服务中的站点仍按顺序请求，避免争用它自己的会话。结果按来源即时追加，显示当前站点、失败信息和进度。搜索不会自动启动停用的插件；用户点按某个来源后才会启动该服务，其他插件不受影响。搜索结果最多保留 100 条，失败来源可单独重试。

CatPaw Spider 的常用 `util/req.js`、`util/htmlParser.js`、缓存、并发、通用工具及运行时配置导入映射到本机兼容模块；`req.js` 提供域名隔离 Cookie、保存/恢复/清除接口。`axios`、`cheerio`、`crypto-js`、`iconv-lite`、`jpeg-js`、`http2`、`stream`、`qs` 等通过应用内的 JS 依赖注册表提供。`node:stream` 当前提供 `Readable.from`、`data/end` 事件和 `pipe` 常用能力；`fs` 只读 ZIP 文件，临时写入留在内存中，不会访问 iPhone 其它目录。ZIP 自带的其它 JS 依赖仍须保持在 ZIP 中。Fastify 标准 `get/post` 路由可在本机服务下调用；`/spider/<key>/3/...` 私有路由同样可从 AVPlayer 请求，适合返回重写后的 HLS 清单。`parse: 1` 会交给应用的网页播放页，`parse: 0` 则交给 AVPlayer；本机播放器不会把解析页面冒充媒体流。

手动声明 CatPaw Spider 时使用：

```json
{
  "schemaVersion": 1,
  "name": "我的影视源",
  "runtime": "javascript",
  "protocol": "catvod-spider",
  "moduleType": "esm",
  "entry": "spider/video/source.js"
}
```

Python Spider 示例只需将 runtime 改为 `python`、protocol 改为 `python-spider`、entry 指向原 `.py` 文件。单个包含 Spider 类的 Python 文件通常无需清单。内置提供 base.spider 兼容层，以及 requests、BeautifulSoup、html5lib 等纯 Python 依赖；包自身的其他依赖也需一并提供。

咪咕所在 iptv 项目需要保持原目录与依赖。例如 entry 为 `extractors/migu/index.js`，runtime 为 `node`、protocol 为 `iptv-extractor`、moduleType 为 `esm`，同时包含它引用的 config.js、utils 及纯 JS node_modules。**单独压缩 migu 子目录会缺少 ../../utils 等依赖，无法直接运行。** 可在资源配置的「插件选项」JSON 中设置原模块要求的 userId、token、rateType 等参数；宿主原样传入 fetch，并把账号传入 resolve。播放权限由来源服务决定。

## 播放与资源限制

直接 HTTP/HTTPS 媒体交给 AVPlayer，携带请求头的播放使用本机流式代理，HLS 子清单、分片、密钥与初始化段继承所需请求头；跨来源跳转移除 Cookie/Authorization。`parse=1` 的网页交给按需创建的 WebKit 页面，保留网页原始地址，不假装成 HLS，也不保证网页一定提供可播放内容。

ZIP 上限 24 MB、单文件 8 MB、解压总量 64 MB、文件数 2048。拒绝路径越界、符号链接、损坏校验、加密 ZIP 和 ZIP64。JS/API/缓存、并发连接和日志均有上限。

Node 提供本机网络、文件、加密等接口，但 iOS 不支持桌面子进程或任意 `.node` 扩展；当前宿主禁用 Worker 和 process.exit 等会破坏生命周期的调用。JSC 不等同完整 Node。依赖桌面浏览器、ffmpeg 二进制、未适配的 Python 原生扩展或新版专用规则引擎的包，仍需包作者适配。不是所有第三方 ZIP 都能直接运行。

停止会关闭已接管的监听、连接、计时器和后台任务。任意插件的死循环、原生扩展故障不能保证隔离；不可安全停止时不会显示成「已停止」。

## 验证范围

已验证 JS 通用运行时的 ESM/CommonJS、CatPaw 路由、CatVod 新旧方法签名；Node 宿主中的 CatPawOpen HTTP 服务、NanoTV v2 服务桥接和多个服务独立停止；Python Spider 协议、多线路和分页；媒体地址/请求头归一化、HLS 刷新、ZIP 路径与 MD5 校验。Mac 上的 JavaScriptCore/Objective-C importer 测试由 macOS CI 执行；当前 Linux 环境跳过这些平台测试。第三方网站账号、网络与真机持续播放仍取决于上游服务和实际设备。CCTV SDK 的开台速度需真机测量，不提供未经测量的提升百分比。
