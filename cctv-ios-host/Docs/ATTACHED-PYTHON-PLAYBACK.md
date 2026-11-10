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

## 宿主兼容修复

`Plugins/host_media_runtime.py` 现在按第一个 `:` 或 `$` 分隔文本请求头，允许 Referer URL 自身包含 `$`。头名按大小写无关方式合并；同一个结果的 `header` 覆盖 `headers`，`customHeaders` 最后覆盖，具体清晰度头覆盖公共头。非法控制字符会被过滤。

PythonSpider 对声明 `format: hls`、HLS MIME 或直接媒体能力的 `.png` / 无后缀地址直接交给播放器，避免多余的网页请求。运行时、PythonSpider 兼容升级和 AppVideoEngine 均不再仅按片名到其他目录替换选中的播放地址：原始网页地址交给宿主网页解析，源返回的直接媒体地址保留。

## 离线验证

```sh
python -m unittest discover -s cctv-ios-host/Tests -p test_attachment_playback_adapters.py -v
```

14 项测试使用真实 PythonSpider 加载清单，覆盖重定向、签名地址、完整 HLS 时间线、重复播放的请求头、跨域 Cookie 隔离、初始化无网络请求及宿主请求头合并。仅使用本机 HTTP fixture，没有访问内容站点。

这些测试证明协议适配与传输参数正确；远程域名存活、内容授权、真实编码/画面/音轨和 iOS 真机播放仍需在目标设备验证。
