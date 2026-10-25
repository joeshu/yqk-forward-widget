# 本机影视资源使用说明（0.18）

底部导航为 **CCTV｜频道｜首页｜资源｜设置**。CCTV 使用原生 SDK；频道播放 M3U；首页汇总继续观看、收藏和固定来源，并进入影视库；资源负责导入、启停、配置、日志、导出和删除。没有 iCloud 功能。

## 导入和使用

1. 打开「资源 → ＋」，选择 JS/Python/ZIP 文件，或输入资源文件下载地址。CatPaw 的 `.js.md5` 地址可以直接输入，宿主会下载配对脚本并校验。
2. 直接导入 `.js`、`.mjs`、`.cjs`、`.py`，或者带依赖文件的 ZIP。导入只安装文件，不执行代码。
3. 在「资源」列表启用资源；到「首页」选择固定来源卡片或点按「影视库」选择已导入的资源。服务型资源只在用户打开时启动，TVBox JSON API 则直接请求，不启动插件运行时。
4. 选定来源后，进入推荐或分类，使用搜索和筛选，打开影片详情，再选择线路与分集播放。CatPawOpen 服务可提供多个来源，站点选择器会列出其 `/config` 返回的站点；首页「全站搜索」会逐来源显示运行、进度、结果和错误，不自动启动其余插件。
5. 直播提取包提供「添加直播订阅」，生成本机 `/all.m3u`，在「频道」播放。影视搜索结果不会混入直播列表。

导入猫爪时可直接输入 `https://joeshu.github.io/yqk-forward-widget/catpaw/index.js.md5`。宿主下载对应 JS，核对 MD5 后安装；MD5 文件本身不会作为 JS 执行。校验仅证明传输内容一致。

## 包类型

| 类型 | 本机引擎 | 接口 |
| --- | --- | --- |
| 普通 JS | JavaScriptCore；CommonJS `require()` 或非 Spider npm dependencies 默认走 Node.js Mobile | home/category/search/detail/play，可选 channels/catalog/resolve |
| CatPaw JS Spider | JavaScriptCore 本机路由适配器 | ESM 默认导出的工厂函数或旧式对象；运行 `api(fastify)` 的 init/home/category/detail/play/search 路由 |
| CatVod / TVBox 风格 JS | JavaScriptCore 或清单指定 Node | 新式 `home/category/search/detail/play` 与旧式 `homeContent/categoryContent/searchContent/detailContent/playerContent` |
| drpy 规则 | JavaScriptCore + 固定版本 dr_py 引擎 | 声明 `var/let/const rule = {...}` 的规则文件 |
| Python Spider | CPython 3.13 | Spider.init/homeContent/homeVideoContent/categoryContent/searchContent/detailContent/playerContent/destroy |
| CatPawOpen / 猫爪 Node 服务 | Node.js Mobile 18.20.4 | `start/stop` + `/config`、`/spider/...` |
| NanoTV v2 直播服务 | Node.js Mobile 18.20.4 | `nanoService.start/channels/resolve/stop`；本机 `/all.m3u`、`/live/<频道>.m3u8` 与 HLS 会话续期 |
| iptv 项目提取模块（如咪咕） | Node.js Mobile | fetch(options) 返回 groups；resolve(ref, context) 返回 URL |
| 已有 Python HTTP 服务 | CPython | 原有服务启动参数与 HTTP 接口 |

JS 原文件由 JS 引擎执行，Python 原文件由 CPython 执行，均在 iPhone 进程内。Node 框架首次启用相关资源才加载，不在 CCTV 开台时启动。

## ZIP 清单

ZIP 根目录可包含 `cctvhost.json`；也支持外层再套一个文件夹。存在清单时优先使用清单，否则尝试 package.json 和常见入口。CommonJS 代码使用静态 `require("...")` 或 `package.json` 声明 dependencies 时，未指定运行时时默认选择 Node.js Mobile；drpy 等专用协议仍使用 JavaScriptCore。旧版本已导入的无清单 Node/CommonJS 资源会在下次启动时重新识别。Node 包需要在 ZIP 内带齐它使用的 `node_modules`，应用不会联网安装 npm 依赖。无法确定入口时会明确报错。

```json
{
  "schemaVersion": 1,
  "name": "我的影视",
  "runtime": "javascript",
  "protocol": "catvod-js",
  "moduleType": "esm",
  "entry": "src/index.js",
  "options": {}
}
```

`runtime` 支持 `javascript`、`python`、`node`。`protocol` 支持 `cctvhost.media/1`、`catvod-js`、`catvod-spider`、`drpy`、`python-spider`、`python-http`、`iptv-extractor`、`catpaw-http`。清单中的 `tvbox`、`tvbox-js`、`catvod-quickjs`、`catvod-open-js` 会规范化为 `catvod-js`；`catvod-open` 根据入口识别为本机 CatPawOpen Node 服务或 CatVod JS。JS 的 moduleType 为 `esm`、`commonjs` 或普通规则使用的 `script`。

CatPaw JS Spider 按附件中的本机 Spider 规范运行：ESM 默认导出工厂，返回 `{ meta, api(fastify) }`，并注册 `/init`、`/home`、`/category`、`/detail`、`/play`、`/search` 六个 POST 路由。兼容默认导出工厂与历史对象导出。请求会按 CatVod 字段传递：搜索 `wd/page/quick`、分类 `id/page/filters/extend`、详情 `id[]`、播放 `flag/id`。打包入口可为单文件，也可通过 ZIP 清单的 `entry` 指向包内入口。

CatVod/TVBox 风格 JS 支持 `export default site => ({ init(ext), home(filter), homeVod(), category(tid, pg, filter, extend), search(key, quick, pg), detail(id), play(flag, id, vipFlags) })`，也兼容旧版 `homeContent/categoryContent/searchContent/detailContent/playerContent`。站点参数可放在 `options` 本身，或 `options.site`；`options.ext` 会传给 `init(ext)`。标准 `net.http/net.json`、`local.get/set/delete` 可在本机使用。没有清单时，导入器会按入口代码识别这类方法式 Spider。

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
