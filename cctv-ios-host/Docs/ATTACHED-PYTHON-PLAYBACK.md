# 附件 Python 播放适配

三个适配包保留附件的列表、搜索、详情协议，入口统一为 `spider.py`，使用宿主的 `python-spider` 接口。每个目录包含独立 `cctvhost.json`，三个包应分别导入。

| 原附件 | 适配目录 | 播放修复 |
| --- | --- | --- |
| 肉视频.py | `Examples/rou-python` | 接受普通 HLS / 无扩展重定向；给 `index.png`、HLS 接口声明真实格式；按目标域读取会话 Cookie；初始化不等待导航站探测 |
| 718吃瓜.py | `Examples/718-python` | 保留签名的 `%`、`+`、引号和参数顺序；解码 HTML 分隔符；不合成 HTTPS → HTTP 备用线；没有媒体时返回空线路 |
| 黄果剧场.py | `Examples/huangguo-python` | 直接交给播放器处理完整 HLS master，避免把首个 `.mp4` 分片当整片；保留来源页 Referer 与 Cookie；取消无限期播放 URL 缓存；不再依赖 requests |

适配版恢复默认 TLS 证书验证。Cookie 使用 CookieJar 按目标域、路径和协议筛选；黄果页面抓取的跨域重定向会重新生成 Cookie，不转发来源域的认证。黄果页面响应及 gzip 解压后内容均限制为 4 MiB。

## 导入

在 CCTVHost 的资源导入页面选择对应 ZIP，启用后进入影视列表。也可单独导入各目录的 `spider.py`。ZIP 根目录应包含 `cctvhost.json` 和 `spider.py`，不要将三个目录合并为一个多入口 ZIP。

无需安装额外 Python 依赖。可在清单中配置来源基址（如域名变化时）：

```json
"options": { "siteUrl": "https://your-source-host" }
```

肉视频默认在第一次内容请求失败时尝试导航恢复，避免阻塞初始化；需要原先的初始化探测时可加 `"discoverOnInit": true`。

## 2026-11-11 附件检查

| 附件 | 检查结果 |
| --- | --- |
| `guaziAPP.py` | 详情使用 `resolution||720@1080` 一类的分集 ID，宿主能够保留并回传参数；播放接口返回 HLS 地址。该脚本需要 RSA PKCS#1 v1.5 私钥解密接口响应密钥，兼容层此前只有 RSA 公钥加密，因此所有加密 API 响应都会变成空数据。本轮增加 PKCS#1/PKCS#8 私钥导入与 v1.5 解密后，附件的详情选集和 HLS 播放在离线夹具中通过。 |
| `youkushipin1.py` | 详情能生成分集 ID；`playerContent()` 返回 `/video?vid=…` 页面并标记 `parse/jx`，它没有解析出 HLS/MP4 直链。宿主会尝试合集内明确配置的解析接口，再尝试后台提取；只拿到网页时会保留为待解析页面，不会误标成原生媒体。需要从原合集导入以保留其解析接口；若接口未返回真实媒体地址，则仍不能原生播放。 |
| `3E7E0C8A023B624CEC6BDCC200F06F02.js` | 文件实现 DRPY 通用运行时，内部没有站点 `host`、首页/详情规则或媒体地址，不能单独作为影视站点导入；它需要对应的站点规则配置。 |

本批附件验证只使用离线响应和播放夹具，没有请求上述站点，也没有把附件中的密钥或 Cookie 复制进应用源码。

## 宿主兼容修复

`Plugins/host_media_runtime.py` 现在按第一个 `:` 或 `$` 分隔文本请求头，允许 Referer URL 自身包含 `$`。头名按大小写无关方式合并；同一个结果的 `header` 覆盖 `headers`，`customHeaders` 最后覆盖，具体清晰度头覆盖公共头。非法控制字符会被过滤。

PythonSpider 对声明 `format: hls`、HLS MIME 或直接媒体能力的 `.png` / 无后缀地址直接交给播放器，避免多余的网页请求。运行时、PythonSpider 兼容升级和 AppVideoEngine 均不再仅按片名到其他目录替换选中的播放地址：原始网页地址交给宿主网页解析，源返回的直接媒体地址保留。

## 离线验证

```sh
python -m unittest discover -s cctv-ios-host/Tests -p test_attachment_playback_adapters.py -v
```

14 项测试使用真实 PythonSpider 加载清单，覆盖重定向、签名地址、完整 HLS 时间线、重复播放的请求头、跨域 Cookie 隔离、初始化无网络请求及宿主请求头合并。仅使用本机 HTTP fixture，没有访问内容站点。

这些测试证明协议适配与传输参数正确；远程域名存活、内容授权、真实编码/画面/音轨和 iOS 真机播放仍需在目标设备验证。

## 2026-11-11 优酷 / 腾讯视频补充检查

本次附件的 `playerContent()` 都没有返回可供 AVPlayer/CicadaPlayer 解码的 HLS、DASH 或 MP4 媒体地址。优酷直接返回官方 `/video?vid=…` 页面；腾讯原脚本把官方分集页包装到第三方 `jx.xmflv.com`，这仍然是网页解析，不是媒体直链。

为避免黑屏等待，`MediaPlaybackDecodeRouter` 对 `parse/jx/requiresWebPlayback` 页面直接选择应用内网页播放，不再先让两个原生播放器尝试读取 HTML。优酷和腾讯官方 HTTPS 播放页不会提交给合集解析 API。附件适配版 `Tencent-官方网页播放适配版.py` 返回腾讯官方分集页，由官方网页执行登录、订阅及播放授权。

这条路径用于通过官方页面显示画面，不会保证或尝试从会员/DRM 页面提取原生流。要使用 AVPlayer/CicadaPlayer，来源必须通过官方授权接口提供可播放媒体地址及合法请求头；上述附件本身不具备该能力。
