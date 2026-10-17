ysp-live 9.5.1-local 本地优化版

这是基于用户提供的 ysp-live v9.5 与 ysp-engine.js 制作的修改版，保留原作者声明；不是原作者的正式发行。Python 入口已整合为单文件，下载 `ysp-live.py` 即可运行，无需同目录的 `ysp_*.py` 模块。Node 伴生引擎仍为可选增强。

1. 启动与升级

需要 Python 3.10+；伴生引擎需要 Node.js 20+（建议22/24）。没有 pip 或 npm 第三方依赖。本次实际验证环境是 Linux、Python 3.12、Node.js 24。

```sh
python ysp-live.py 8767 --data-dir ./data
```

启动后在播放器订阅：

```text
http://服务器IP:8767/all.m3u
```

Python 会自动启动同目录的 Node 引擎，后者只监听127.0.0.1:8787。退出Python会一同停止由它启动的引擎；已存在的外部引擎只在身份检查通过后使用，不负责终止。

仅使用1080p备用路径、不启动设备注册与Node：

```sh
python ysp-live.py 8767 --data-dir ./data --no-4k --no-engine
```

升级时先停止旧程序，备份原文件及数据目录，将原 device-state-rs.json、proxy-cache-state-rs.json 放入新的 --data-dir。不要同时运行新旧进程使用同一数据目录。旧文件格式继续兼容；运行中的会话会重新建立。

2. 本版主要变化

- 同一分片一个上游下载、多个独立读取者，首个观众断开不会取消其他人的下载。
- 进行中内容使用临时文件与独立读游标，完成缓存由不可变分块构成，避免原先bytearray转bytes整片复制。慢读者持有的已淘汰缓存仍计入RAM预算。
- 下载并发、客户端连接、临时文件字节、单资源大小、读写期限都有上限。线程启动和关闭失败会归还容量。
- 设备解析、会话初始化、前台/后台刷新共享结果；修复双重失败计数、冷却绕过、旧请求覆盖新缓存和跨入口列表缓存抖动。设备源前台最多等默认2秒，后台可继续完成。
- 分离列表请求成功与媒体推进；冻结流、分片401/403/404会按频道与源代际降级和受限重建。
- JCE保留单调媒体序号，改写标签URI，保留KEY/MAP/BYTERANGE/PDT，AES-128隐式IV在重新编号前显式化。修复重签地址、时区比较和重定向基址。
- 切源边界保留在输出窗口里，HEAD只读；不能可靠对齐的格式通过 X-Stream-Restart: required 标明可能需要播放器重开，不承诺所有编码/格式无缝切换。
- 回看参数严格校验，错误或源失败不会静默播放当前直播；显式 fallback=live 可允许直播降级。
- 分片使用服务器登记的短期资源令牌，任意Base64 URL不再能充当代理授权。每次连接/重定向检查目标、DNS地址和端口，拒绝非预期私网及HTTPS降级。
- Node侧增加连接池、并发与队列限制、短列表缓存/播放地址缓存分离、同频道请求合并、失败退避、流式HEAD/Range、冻结识别和优雅退出。
- 原子持久化、受限DNS缓存与daemon工作池避免损坏状态或阻塞退出。

普通JCE/BK播放列表通常让播放器直接访问CDN，媒体不经过Python的RAM缓存。共享下载和cache参数主要影响设备协议与伴生媒体代理路径；相同频道可以节约上游下载，对观众的出站带宽仍随人数增加。

3. 常用参数

| 参数 | 默认值 | 用途 |
| --- | --- | --- |
| --cache-mb | 200 | 已完成分片RAM预算，0真正关闭该缓存 |
| --inflight-mb | 256 | 共享下载临时文件总预算MiB |
| --temp-dir | 系统临时目录 | 临时文件位置，空间需求受inflight预算限制 |
| --download-workers | 8 | Python上游媒体下载并发 |
| --max-connections | 64 | Python客户端连接上限，超出快速503 |
| --client-timeout | 20 | 客户端请求头/写入空闲秒数 |
| --media-timeout | 30 | 单次媒体转发总期限秒数 |
| --foreground-wait | 2 | 前台等待设备播放列表的秒数 |
| --timeout | 10 | 设备协议单次HTTP超时 |
| --quality | 保持各频道原设置 | auto/fhd/shd，控制Python JCE/BK档位/主列表选择 |
| --device-rate | auto | 设备源auto/36p/10p；指定档位不存在时交给备用源 |
| --no-4k | 关闭 | 禁用设备协议，仍可使用Node回退 |
| --only-4k | 关闭 | 仅4K/8K标称频道走设备协议 |
| --no-engine | 关闭 | 不启动或访问伴生引擎 |
| --links-per-device | 6 | 保留原设备链接配额策略，0关闭本地主动配额检查 |
| --zap-debounce | 10 | 普通频道升级高码率前防抖秒数 |
| --bind | 0.0.0.0 | Python监听地址 |
| --engine-port | 8787 | 伴生引擎端口 |
| --public-base-url | 空 | 反代公开origin，例如https://tv.example.com；不支持路径前缀 |
| --trust-proxy | 关闭 | 只在可信反代环境启用，允许X-Forwarded-Proto |
| --access-token | 环境变量或空 | 可选访问令牌，推荐用YSP_ACCESS_TOKEN传入 |

低内存部署示例（临时目录可放实际可用的磁盘）：

```sh
python ysp-live.py 8767 --data-dir ./data --cache-mb 32 --inflight-mb 64 --download-workers 2 --max-connections 16
```

临时目录若在tmpfs，文件也会消耗系统内存；--cache-mb限制的是程序的完成缓存，不能代表整个进程或整台机器的总内存。使用磁盘目录会产生持续分片写入，应按设备存储选择 --temp-dir。

4. 访问令牌、反向代理与诊断

可设置YSP_ACCESS_TOKEN，播放器订阅地址使用 /all.m3u?access_token=你的令牌。订阅内频道地址会携带访问令牌，媒体资源使用短期独立令牌；HTTP客户端也可使用Authorization: Bearer。/livez不要求令牌，其余管理/频道接口要求令牌。短期资源令牌重启后失效，重新取得播放列表即可。

公开地址推荐固定 --public-base-url https://tv.example.com。只有可信反代才设置 --trust-proxy；默认不会信任任意客户端传入的X-Forwarded-Proto。自带白名单只允许既有CCTV及常见CDN域名与公网地址；如果上游以后换到新的CDN域名，应审查后同时更新Python与Node白名单，不能关闭私网校验。

- /livez：进程存活，正常200。
- /health 与 /readyz：当前设备协议或已观测频道是否就绪；冷启动未拉取媒体时可能503。不是所有64个频道逐一可用的保证。
- /diag：只读诊断，含频道进展和共享下载指标；配置访问令牌后受保护。
- /all.m3u、/<频道>.m3u8：保留原订阅与频道入口。
- /proxy、/proxy.ts、/engine_proxy：只接受程序生成的短期资源令牌，不再接受任意目标URL。

分片状态可通过X-Cache区分HIT-RAM、SHARED、MISS-UPSTREAM、BYPASS。列表响应的X-Source、X-Source-Epoch和X-Stream-Restart用于判断来源及切源；它们不会改变播放器对编码格式的支持。

5. 回看与画质

回看支持start/end（Unix秒、毫秒或带时区ISO）及原playseek格式。无时区的日期按中国标准时间解释。显式无效、未来或倒序范围返回400，不支持频道返回422，上游失败返回502。请求窗口最多7天、单次最多24小时是本地校验上限，实际可用范围取决于上游。只有显式加fallback=live才在回看失败时继续直播。

--quality控制Python备用源；--device-rate控制设备协议；Node目前保留各频道原始请求档位。频道名和档位标签不等同于实测分辨率/码率，实际画质及codec需要真实播放器确认。复杂LL-HLS或无法安全重新编号的加密格式保留原列表，可能需要播放器重开。

6. Node可选配置

单独运行：node ysp-engine.js 8787。YSP_ENGINE_HOST默认127.0.0.1。其余环境变量均以YSP_ENGINE_开头：MAX_REQUESTS(64)、MAX_CONNECTIONS(128)、MAX_UPSTREAM(24)、MAX_QUEUE(64)、TIMEOUT_MS(10000)、RESOLVE_TIMEOUT_MS(25000)、SEGMENT_TIMEOUT_MS(30000)、MAX_PLAYLIST_BYTES(2097152)、MAX_SEGMENT_BYTES(36700160)、STALL_MS(45000)、SHUTDOWN_MS(5000)。Python启动子进程时会显式设定本机监听、端口和2秒退出期限。

Python的urllib及媒体代理保留HTTP_PROXY/HTTPS_PROXY/NO_PROXY环境配置；直连媒体连接使用经过校验的DNS地址与正确TLS主机名。Node媒体传输使用内置直连连接池，不把HTTP_PROXY自动解释为代理连接。

7. 本地验证

```sh
python -m unittest discover -s tests -p "test_*.py" -v
node --test tests/test_engine.js
```

测试包括真实本地HTTP/HTTPS socket、8客户端共享下载、首字节流式发送、客户端断开、HEAD/Range、截断、重定向、目标限制、预算、关闭异常、冻结、HLS加密/时移时间线、原子落盘与Python/Node进程启停。TLS测试需要openssl；测试上游均为内存替身或本地服务，不会调用真实注册/播放/遥测接口。具体结果见同目录测试日志及RELEASE.json。

仍需在你的部署设备和播放器上验证真实频道、码率、首帧、切源和长时间运行。本次没有对真实直播源作性能或可用性承诺。
