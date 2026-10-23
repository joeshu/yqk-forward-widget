# 本机影视资源使用说明（0.18）

底部导航为 **CCTV｜频道｜影视｜资源｜设置**。CCTV 使用原生 SDK；频道播放 M3U；影视负责影视来源、分类、搜索、详情、线路和选集；资源负责导入、启停、配置、日志、导出和删除。没有 iCloud 功能。

## 导入和使用

1. 打开「资源 → ＋」，选择 JS/Python/ZIP 文件，或输入资源文件下载地址。
2. 直接导入 `.js`、`.mjs`、`.cjs`、`.py`，或者带依赖文件的 ZIP。导入只安装文件，不执行代码。
3. 在资源列表启用资源，或者进入「影视」选择它。切换资源时先停止旧实例；停止失败会保留真实状态。
4. 影视页面右上角选择资源/来源，支持搜索来源名称；输入关键词搜索影片，选择分类和筛选条件，加载更多，进入详情后选择线路和分集。
5. 直播提取包提供「添加直播订阅」，生成本机 `/all.m3u`，在「频道」播放。影视搜索结果不会混入直播列表。

导入猫爪时可直接输入 `https://joeshu.github.io/yqk-forward-widget/catpaw/index.js.md5`。宿主下载对应 JS，核对 MD5 后安装；MD5 文件本身不会作为 JS 执行。校验仅证明传输内容一致。

## 包类型

| 类型 | 本机引擎 | 接口 |
| --- | --- | --- |
| 普通 JS | JavaScriptCore | home/category/search/detail/play，可选 channels/catalog/resolve |
| CatVod JS | JavaScriptCore 或清单指定 Node | home/category/search/detail/play，亦支持 homeContent 等别名 |
| drpy 规则 | JavaScriptCore + 固定版本 dr_py 引擎 | 声明 `var/let/const rule = {...}` 的规则文件 |
| Python Spider | CPython 3.13 | Spider.init/homeContent/homeVideoContent/categoryContent/searchContent/detailContent/playerContent/destroy |
| 原猫爪 Node bundle | Node.js Mobile 18.20.4 | start/stop + /config、/spider/... |
| iptv 项目提取模块（如咪咕） | Node.js Mobile | fetch(options) 返回 groups；resolve(ref, context) 返回 URL |
| 已有 Python HTTP 服务 | CPython | 原有服务启动参数与 HTTP 接口 |

JS 原文件由 JS 引擎执行，Python 原文件由 CPython 执行，均在 iPhone 进程内。Node 框架首次启用相关资源才加载，不在 CCTV 开台时启动。

## ZIP 清单

ZIP 根目录可包含 `cctvhost.json`；也支持外层再套一个文件夹。存在清单时优先使用清单，否则尝试 package.json 和常见入口。无法确定入口时会明确报错。

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

`runtime` 支持 `javascript`、`python`、`node`。`protocol` 支持 `cctvhost.media/1`、`catvod-js`、`drpy`、`python-spider`、`python-http`、`iptv-extractor`、`catpaw-http`。JS 的 moduleType 为 `esm`、`commonjs` 或普通规则使用的 `script`。

Python Spider 示例只需将 runtime 改为 `python`、protocol 改为 `python-spider`、entry 指向原 `.py` 文件。单个包含 Spider 类的 Python 文件通常无需清单。内置提供 base.spider 兼容层，以及 requests、BeautifulSoup、html5lib 等纯 Python 依赖；包自身的其他依赖也需一并提供。

咪咕所在 iptv 项目需要保持原目录与依赖。例如 entry 为 `extractors/migu/index.js`，runtime 为 `node`、protocol 为 `iptv-extractor`、moduleType 为 `esm`，同时包含它引用的 config.js、utils 及纯 JS node_modules。**单独压缩 migu 子目录会缺少 ../../utils 等依赖，无法直接运行。** 可在资源配置的「插件选项」JSON 中设置原模块要求的 userId、token、rateType 等参数；宿主原样传入 fetch，并把账号传入 resolve。播放权限由来源服务决定。

## 播放与资源限制

直接 HTTP/HTTPS 媒体交给 AVPlayer，携带请求头的播放使用本机流式代理，HLS 子清单、分片、密钥与初始化段继承所需请求头；跨来源跳转移除 Cookie/Authorization。`parse=1` 的网页交给按需创建的 WebKit 页面，保留网页原始地址，不假装成 HLS，也不保证网页一定提供可播放内容。

ZIP 上限 24 MB、单文件 8 MB、解压总量 64 MB、文件数 2048。拒绝路径越界、符号链接、损坏校验、加密 ZIP 和 ZIP64。JS/API/缓存、并发连接和日志均有上限。

Node 提供本机网络、文件、加密等接口，但 iOS 不支持桌面子进程或任意 `.node` 扩展；当前宿主禁用 Worker 和 process.exit 等会破坏生命周期的调用。JSC 不等同完整 Node。依赖桌面浏览器、ffmpeg 二进制、未适配的 Python 原生扩展或新版专用规则引擎的包，仍需包作者适配。不是所有第三方 ZIP 都能直接运行。

停止会关闭已接管的监听、连接、计时器和后台任务。任意插件的死循环、原生扩展故障不能保证隔离；不可安全停止时不会显示成「已停止」。

## 验证范围

已验证原生 JavaScriptCore 中的 ESM、加密、drpy HTML/同步请求及取消；真实 Node.js Mobile 模拟器框架中的 CommonJS、读写、停止；Python Spider 协议、多线路和分页；ZIP 路径与校验；完整版 iOS arm64 IPA 结构。第三方网站的账号、网络与真机持续播放需要实际设备确认。CCTV SDK 的开台速度也需真机测量，不提供未经测量的提升百分比。
