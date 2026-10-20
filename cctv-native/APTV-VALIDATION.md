# APTV JavaScriptCore 验证记录

2026-10-20。目标仍为 `https://tv.cctv.com/live/cctv2/m/index.shtml` 的官方网页来源，未换用央视频源。

- 用户 iPhone 截图：APTV 内嵌 Python 3.14.6，`platform=ios`；系统 JavaScriptCore 的 JS 与微型 WASM 均返回 42。检测脚本旧版打印后退出，因此 APTV 显示“没有启动监听服务”；这与引擎测试成功不矛盾。
- Linux 开发机：通过 `ctypes` 直接加载 Debian JavaScriptCoreGTK 2.54.0；没有启动 Node、Chromium、FFmpeg 作为服务运行组件。官方 JS/WASM 保持原样，SHA-256 校验沿用原服务。
- 原始 SDK 初始化成功，并通过正常 HTTP 获取官方 H5player 配置；实际配置响应经过 SDK 的正常 XHR 和 IndexedDB 回调路径。
- 已有相邻真实原始分片样本：204 个媒体单元约 0.193 秒完成 SDK 处理，重新映射 TS 后严格解码无错误。该耗时仅代表本机样本。
- 生成的 `cctv-aptv.py` 实际启动 HTTP 服务，订阅 `/all.m3u`，播放 `/cctv2.m3u8`：首次约 19.576 秒进入 ready；连续严格解码 60 秒、1496 帧，解码错误日志 0 字节，无重复或丢帧报告。FFmpeg 仅用于独立开发验证，不是手机或服务依赖。
- 75 项回归通过，含真实 JavaScriptCore 的持久上下文、二进制 IndexedDB 事务回调、跨线程拒绝及无限循环超时终止。未配置测试系统库时，这 4 项会明确跳过，其余 71 项仍运行；CI 不代替实播验证。

复测方法：

```sh
python cctv-native/build_aptv.py --check
CCTV_JSCORE_TEST_LIBRARY=/path/to/libjavascriptcoregtk-4.1.so.0 python -m unittest discover -s cctv-native/tests -v
python cctv-aptv.py 18768 --jscore-library /path/to/libjavascriptcoregtk-4.1.so.0
ffmpeg -hide_banner -loglevel error -err_detect explode -i http://127.0.0.1:18768/cctv2.m3u8 -t 60 -f null -
```

iPhone 上只需在 APTV 加载根目录 `cctv-aptv.py` 并启动，默认订阅 `http://127.0.0.1:18768/all.m3u`。完整 SDK、连续分片、系统执行时间限制接口、手机内存与实际播放器表现尚待该手机验收；微型 WASM 成功不保证整个 SDK 在 iOS 上必然成功。发生问题请保留服务日志和 `/status` JSON；服务不回传原始上游签名地址或 SDK 内部数据。

入口兼容修订：用户随后报告只有“未启动监听服务”，没有服务启动日志。检查发现原单文件通过动态 exec 执行整个 Python 服务，存在嵌入式宿主入口识别兼容隐患。现改为静态顶层 Python 声明，只压缩 JavaScript 数据，并提供 `start(ctx)`。本地分别验证直接运行和以非 `__main__` 名称导入后调用 start，两者均能监听并返回 HTTP 200 订阅。此改动是否解决该手机的启动问题仍待用户验收。

权限兼容修订：用户选台后出现通用 PermissionError，日志尚不能证明具体失败系统调用。旧版在启动引擎时默认对 Path.home() 下缓存目录进行 mkdir/read/write，存在 APTV 沙盒写入权限问题。现默认不访问文件系统，官方组件校验后存放内存，当前服务进程内复用；可选磁盘缓存读写失败也退回内存，下载 PermissionError 单独标记 official-runtime-download-permission-denied。新增默认零文件访问、只读缓存、无法创建目录、下载权限错误定位和拒绝错误哈希五项回归，共 80 项（含 4 项真实 JSC 测试）通过。手机修订版仍待用户验证。

停滞诊断修订：用户提供新截图，服务监听正常、内存缓存版本触发 source-media-stalled。此错误只会在 Engine 构造完成后出现，因此 SDK 初始化已通过；截图不足以区分网络重试、清单不前进或下载阶段。新增具体操作阶段、清单项数、末片字节数、嵌套网络异常类型/数值 errno、重试日志及失败时自动脱敏状态输出。未放宽 30 秒保护，也未宣称解决未知停滞原因。82 项回归通过，包括阶段定位、保留最后网络错误与诊断日志不泄露上游令牌；真实 JSC 四项也通过。

TLS 定位与兼容修订：用户导出的 09:13:25Z 日志证明 SDK 初始化约 0.855 秒完成，随后 source-api 阶段连续 9 次 URLError:SSLError:errno-1，playlist_entries、last_segment_bytes、processed_segments 都为 0；失败发生在 HTTPS 取源接口，尚未请求媒体清单。旧版没有记录 SSLError.library/reason，不能由 errno=1 推断确切握手原因。

现仅针对 vdnx.live.cntv.cn 的 /api/v3/vdn/live，在非证书类 SSL 错误后尝试一次验证完整的 TLS 1.2 请求：同 URL、同签名头、相同代理/CA、主机名验证和重定向限制，不切换来源、不使用 HTTP、不启用不验证证书的连接。SSLCertVerificationError 不触发该重试。SSL 原因只输出符合枚举格式的 library/reason，不转发异常原文。

本地真实联网验证：首次请求人工注入 SSL 失败，随后由新分支调用真实官方 API，play 检查通过并取得 HTTPS 播放地址，约 0.969 秒。该证据来自开发机当前代理网络，不代表已复现或解决 iOS 原生网络的握手错误。86 项测试通过，包括真实 JSC 四项、TLS 范围/证书校验/请求保持及 SSL 日志脱敏。手机仍需验证，超时保护保持不变。

首播优化与手机验收：用户确认关闭 MitM 后可以在 iPhone APTV 播放。09:25:39Z 开始初始化，09:25:40Z 至 09:25:53Z 取源阶段先出现四次 SSL 错误重试；09:25:54Z 开始 TS 分析，09:25:56Z 进入 SDK，09:25:58Z 进入 TS 重组。没有记录完整首个可播清单时间，不能据此推断新会话始终需要重试。

去掉 `_mapped_slice` 每次重建整个偏移数组和切片，直接二分查找现有有序跨度。真实样本包含 204 个 NAL、2970 个跨度，七次解析中位数由约 0.034 秒降为 0.019 秒，所有分析字段逐一一致；这仅代表开发机样本。相邻片证明后复用 TS 分析结果，只更新末 NAL 的完整标记。保留边界证明、PES 限制与输出再解析核对。真实分片经原 SDK 处理及新映射后严格解码无错误。

APTV 现默认在 GET 订阅时预热（--no-warmup 可关闭），首次可播清单打印 media-ready startup_seconds，时间从后台准备开始，不包含播放器缓冲。86 项回归（含真实 JSC 四项）通过。手机优化幅度待新版实测；已成功播放的事实不保证任意网络、频道或开启 MitM 时可用。

多频道扩展（同日）：从 https://tv.cctv.com/live/ 的实际链接及手机页 TVchannel 变量核对 20 个标识，逐个调用同一官方 v3 API。14 个通过 play 检查并返回 HLS；6 个拒绝播放（CCTV-3、5、5+、6、8、16），未加入订阅，也未换源绕过。逐台结果见 CHANNEL-VALIDATION.json：14 个频道各下载一对相邻真实分片，原样 SDK 处理第一个完整分片，重组后对整个分片严格解码，14/14 错误日志均为空，本轮样本均 1280×720 H.264。这是开发网络下的逐台短样本验证，不等于全部设备或长时间播放保证。

实际新单文件 HTTP 路径验证：订阅返回 14 台，依次请求 /cctv1.m3u8（12 秒、297 帧）、/cctv13.m3u8（8 秒、195 帧）、/cctvchild.m3u8（8 秒、197 帧），均完整结束、解码错误日志 0 字节，证明带频道标识的分片 URL 和切换路径可用。手机多频道版仍待用户换台验收。

新增按需频道管理器与请求独立路由视图，换台停止前台旧频道；全局最多两个 JSC 处理线程持有实例，快速切换不会无界创建原生 VM。HEAD 探测不启动/切换频道；刷新订阅只在无当前频道时预热 CCTV-2。每轮只预取最多 3 片，收尾队列有界。GET 列表仍用原端口 /all.m3u，更新后需刷新订阅。

TLS 优化：服务进程内记录实际验证成功的 API TLS 1.2 方式，后续优先使用，网络变化握手失败时可恢复默认 TLS；不禁用证书校验、主机名验证或代理。95 项回归通过（含真实 JSC 四项），覆盖 14 台订阅、跨频道/代际隔离、HEAD 无副作用、切换停止、原生实例并发上限、官方拒绝不绕过，以及成功 TLS 模式复用和网络变化恢复。

后续手机日志：09:59:40Z~10:00:57Z 各次就绪为 10.428、9.780、9.314、5.423、16.402、14.383 秒；除了 source-api TLS 重试，sdk-transform 和 ts-repack 各占数秒。进一步优化媒体传递：仅对自建媒体 TypedArray 通过公开 JSObjectGetTypedArrayBytesPtr/ByteLength API 即时复制，指针不跨 JSC 调用持有，对象保存在上下文全局根中，并经 JSValueToObject 显式转换；不取 SDK/WASM 内部内存。缺少 C API 时保留 Base64 路径。

真实同一分片对比：204 个 NAL，旧媒体传递完整 transform 调用约 0.197 秒，新方式约 0.1173 秒，输出所有媒体字节一致；重复测试为约 0.168/0.1217 秒，表明时间有波动。这是 Linux 开发机样本，不推断整个手机换台同比提速。TS 重组复用同一不可变字节对象的分析和包视图，仍执行边界证明、完整限制和输出重新解析。101 项回归通过，新增两项真实 JSC 缓冲区测试、三项预解析完整性验证和旧式握手前两次短退避验证；其中真实 JSC 测试合计六项。

全部 14 个独立频道用新媒体传递及预解析路径重新采样，完整分片严格解码仍均无错误。完整 HTTP 新链路也验证了综合（8 秒、196 帧）与新闻（12 秒、297 帧），错误日志均 0 字节；旧英语入口样本（12 秒、294 帧）虽解码成功，但画面台标明确为 CCTV-9 纪录，因此未发布为新频道。

扩台额外核对：官网 new/live/cctv/ 列出的六个旧入口，其中 cctvdoc/cctvxiyu/cctvfrench/cctvarabic/cctvrussian 均返回不允许播放；new/live/cctvnews/ 返回页面并指定 rel_url=cctv9，但视频是中文纪录频道。旧链接 live/cctv9/index.shtml 已返回 404。累计 26 个入口标识中，14 个独立频道发布、11 个因许可拒绝排除、1 个因内容重复排除。没有将搜索页面名称或单纯 HTTP 200 当作新增独立频道证明；手机提速实际幅度仍待用户新版验收。

最新用户日志 10:19:35Z：手机已打印 typed-array，但综合/财经/纪录/科教就绪时间仍约 7.781/8.974/11.026/19.978 秒。科教取源从 10:20:33Z 到 10:20:44Z 多次发生明确的 UNSAFE_LEGACY_RENEGOTIATION_DISABLED；默认 TLS 与 TLS 1.2 的版本切换不能稳定解决。首次预热财经尚在 SDK 处理时用户已切到综合，旧版却继续重组，存在可取消的 CPU 消耗。

新增受限的旧服务器兼容：只在固定官方调度 API 两种标准尝试后仍明确出现此错误时，启用 OP_LEGACY_SERVER_CONNECT，并必须同时设置 OP_NO_RENEGOTIATION；保持 CA/主机名验证、TLS 1.2 与原调度许可检查。该模式只接受同一官方接口路径重定向，不应用于媒体或 SDK；证书错误、普通 SSL 错误及其他主机不会触发。可选 --no-legacy-source-tls 关闭。Python 缺少所需标志时不添加数值魔法标志，回到原有错误重试。

验证：开发网络中注入前两次明确旧式握手错误，第三次使用上述 SSL 配置请求真实官方 API，play 检查通过并取得 HTTPS 流地址，约 1.407 秒；这不是 iPhone 原网络旧式握手的复现实验，不能据此宣称手机问题已解决。108 项回归通过（含六项真实 JSC），覆盖兼容条件、证书及协议限制、跨域/跨路径重定向拒绝、用户关闭开关、缺少标志、模式记忆，以及换台后 SDK 完成即跳过旧重组/发布。发布新媒体时清除已恢复的网络错误。
