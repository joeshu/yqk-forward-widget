# 央视官网订阅：APTV 多频道与 CCTV-2 电脑版

使用 [央视官网直播](https://tv.cctv.com/live/) 对应的播放来源：APTV 手机版现提供 14 个已通过真实分片验证的频道，原 Python + Node 电脑版继续仅提供 CCTV-2。本服务独立于 `ysp-live`，不会替换成央视频或其他平台的来源。

**APTV 手机实验版现已独立提供：[cctv-aptv.py](https://raw.githubusercontent.com/joeshu/yqk-forward-widget/main/cctv-aptv.py)。** 用户 iPhone 日志已确认 Python 3.14.6 可以直接调用系统 JavaScriptCore 并执行微型 WASM。新版本使用该引擎，不依赖 Node、npm、浏览器、FFmpeg 或子进程；已在 Linux JavaScriptCore 中通过真实央视分片处理及连续解码验证，**用户已确认关闭 MitM 后可在 iPhone APTV 播放**。详见 [APTV 验证记录](APTV-VALIDATION.md)。原有 `cctv-native.py` 仍用于电脑/服务器，需要 Node。

在 APTV 添加 Python 服务，远程链接填写上面的 `cctv-aptv.py`，加载最新代码并启动，然后订阅：

```text
http://127.0.0.1:18768/all.m3u
```

仅提供 CCTV-2 财经，来源仍为指定央视网页。若运行设置更改端口，订阅中的端口也要对应更改。服务会立即监听；默认在 GET 订阅时提前准备频道（`--no-warmup` 可关闭），下载并校验固定版本官方组件，默认仅在内存缓存，不访问用户主目录、无需磁盘写入权限或 `--setup`。可选 `--cache-dir` 才启用磁盘缓存，缓存读写失败自动退回内存。查看 `http://127.0.0.1:18768/status` 可区分初始化、取源、就绪或错误；`official-runtime-download-permission-denied` 表示下载操作被拒绝，区别于磁盘缓存问题；`jscore-framework-or-time-limit-unavailable` 表示所需系统接口不全，不能据微型测试通过推断完整服务一定可用。初次播放需要等待组件及相邻分片准备，本次 Linux 连续测试约 19.6 秒进入就绪；不保证手机同等速度。

`aptv-jscore-probe.py` 是独立诊断脚本，现默认监听 `18770/status`，避免 APTV 将“打印后正常退出”显示为启动失败。`--once` 可恢复仅打印行为。诊断脚本不提供频道，请使用新播放服务的链接。

### 新增的 14 个官网频道

APTV 新版仍订阅同一个 `/all.m3u`，更新脚本后要在播放器中**刷新订阅**，才会从原先 1 个更新为 14 个。包括 CCTV-1、2、4、7、9、10、11、12、13、14、15、17，以及 CCTV-4 欧洲、美洲。网页中的 `cctvjilu` 对应 CCTV-9，`cctvchild` 对应 CCTV-14；其他频道使用官网原标识，不切换央视频源。

实测 20 个官网入口，以上 14 个取得官方许可和媒体清单，逐台下载真实原始分片、通过原 SDK 处理并对完整样本严格解码，均为零错误；本轮样本均是 1280×720 H.264。CCTV-3、5、5+、6、8、16 本次返回 `play != 1`，未加入订阅。详见 [逐台验证记录](CHANNEL-VALIDATION.json)，不保证不同时间、网络或节目状态下持续可用。CCTV-2 已由用户在 iPhone 验收，多频道换台还需该手机验证。

手机端按需准备当前选中的频道，订阅刷新仅在尚无当前频道时预热 CCTV-2，不会初始化全部频道，也不会打断正在看的其他台。换台会停止上一频道取流；最多两个原生处理实例用于切换过渡，避免快速切换时堆积大量 SDK。它主要面向单设备逐台观看，不提供同时独立观看所有频道的能力。当前状态与当前频道见 `/status`。

进一步的启动优化：记住本次进程中已经成功的 TLS 1.2 取源方式，下次取源或换台优先复用；网络改变导致握手失败时可尝试默认 TLS 恢复。仅保留一次经验证成功的选择，不保存账号、地址或签名，不关闭证书校验，仍不能替代关闭相关域名的 MitM。每轮只预取最多 3 个相邻分片，减少过量排队以及换台时旧频道的收尾等待。


**需要 Python 3.10+、Node.js 20+ 和 npm，不需要 Chromium、Playwright 或 FFmpeg。** Python 提供本地订阅和分片缓存，Node 运行固定版本的官方组件；处理后的原 TS 分片直接供播放器解码，不采集网页画面、不重新编码。这仍是 Python + Node 程序，只有纯 Python 的环境不能运行。


### APTV 适配实现

手机服务复用已有 TS 映射、同源调度、播放许可检查、缓存、重试和 HTTP 逻辑。Python 通过系统 C API 执行原样官方 JS/WASM；使用原 Emscripten `instantiateWasm` 接口同步实例化，网络与定时器由 Python 驱动，存储使用固定版本 fake-indexeddb。原始官方组件下载后校验 SHA-256，不写入仓库，不替换来源。全部 JavaScriptCore 操作由同一工作线程执行，原生执行时间限制终止失控脚本，不创建 Python 原生回调。

第三方 fake-indexeddb 6.2.6 的原始 CommonJS 内容和本地加载器随单文件打包，Apache-2.0 许可完整保留在 [vendor/fake-indexeddb-LICENSE](vendor/fake-indexeddb-LICENSE) 以及单文件 `THIRD_PARTY_LICENSE` 中。该依赖只是浏览器存储接口，不是新的节目源。

构建：`python cctv-native/build_aptv.py`；检查：`python cctv-native/build_aptv.py --check`。iOS 运行不安装任何 pip/npm 包。Linux 开发验证可通过隐藏参数 `--jscore-library /绝对路径/libjavascriptcoregtk-4.1.so.0` 指定测试系统库，这不属于手机安装要求。


## 下载与启动

下载仓库根目录的单文件 [cctv-native.py](https://raw.githubusercontent.com/joeshu/yqk-forward-widget/refs/heads/main/cctv-native.py)，保存到本地。无需同时下载本目录的源码。

首次安装独立运行依赖：

```sh
python cctv-native.py --setup
```

该命令通过 npm 安装四个固定版本依赖，并下载原样的官方 `live.worker.js`，校验 SHA-256 后存入 `~/.cache/cctv-native`。依赖使用独立缓存目录，官方组件不写入仓库；下载到不同版本时会报错，需要更新脚本。安装和播放均沿用系统代理与 TLS 校验。

之后启动：

```sh
python cctv-native.py 18768 --warmup
```

播放器添加订阅：

```text
http://127.0.0.1:18768/all.m3u
```

`--warmup` 在播放器 GET 订阅时后台提前取源，订阅本身立即返回；省略时首次选台才启动。HEAD 不触发预热。首次播放需要等待官方组件初始化及相邻分片准备，真实耗时见 [VALIDATION.md](VALIDATION.md)。

手机或电视访问电脑上的服务时：

```sh
python cctv-native.py 18768 --bind 0.0.0.0 --warmup
```

订阅地址改为 `http://电脑局域网IP:18768/all.m3u`。手机上的 `127.0.0.1` 指向手机自身。旧版 `cctv-web.py` 也默认使用 18768，两个服务需停止其中一个，或用不同端口启动。

## 状态与运行选项

- 单台地址：`http://127.0.0.1:18768/cctv2.m3u8`。
- 状态地址：`http://127.0.0.1:18768/status`。包含实际阶段、分片数量、缓存占用、阶段耗时与脱敏错误；`transport_retries` 是本次会话的网络重试次数，`last_transport_error` 在恢复后清空；`media_ready` 不代表用户播放器已经验收通过。
- `--node /路径/node`：指定 Node 可执行文件。
- `--cache-dir /路径/缓存目录`：改变安装缓存；安装与启动须使用同一目录。
- `--buffer-mb 64`：分片内存上限，范围 16–256MiB；最多保存 10 个分片，播放器列表提供最近 6 个。
- `--idle-timeout 120`：无人观看后停止取源，范围 30–3600 秒。再次选台会重新初始化。

多个观众共享一份取源与处理进程。播放请求最长等待约 50 秒；尚未准备好或失败返回 HTTP 503，可查看 `/status`，错误冷却 30 秒后由新播放请求重试。旧会话或已淘汰分片返回 410，需让播放器刷新清单。

短暂超时、断链及 HTTP 408 / 429 / 5xx 会按 0.8–4 秒退避重试，保留已就绪的播放缓存；401 / 403 / 404 会重新获取官方调度。重试受无媒体进展 30 秒的检查预算约束，当前网络读取结束后判断；持续故障仍会停止。官方拒绝播放、格式错误和组件进程错误不会进入网络重试循环。

主清单首次解析后直接轮询媒体清单，120 秒取源刷新时重新解析，减少重复请求。该优化不保证固定的冷启动耗时。

## 当前支持范围

本版仅支持当前观察到的 TS / H.264 分片结构。为确认分片末尾的媒体单元完整，先核对相邻 HLS 序号及下一片起始码，再按原 TS 结构重组媒体数据、保留原音频和时间戳。支持的变短媒体单元限于单个 PES 内；增长、未知封装、无法证明相邻帧边界或上游格式变化都会明确失败。下载过慢导致直播窗口跳过片段时，丢弃缺失区间并用 HLS 不连续标记重新接入当前窗口；`/status` 的 `source_gaps` 记录次数，不拼接缺失片段的媒体字节。它不具备通用媒体转码能力。

上游返回 `play != 1` 时停止，不通过更换地区、账号或来源继续取流。官方组件和接口变化、网络及播放器差异都可能影响可用性；目前不保证其他网络可播，未提供其他频道、EPG、回看或 4K。真实验证范围以 [VALIDATION.md](VALIDATION.md) 为准。

此前的 [cctv-web 浏览器采集版](../cctv-web/README.md) 继续保留，可独立选择使用。

## 开发

编辑 `service.py`、`cctv_native_ts.py`、`engine.cjs`，然后生成单文件：

```sh
python cctv-native/build_service.py
```

离线检查：

```sh
python -m unittest discover -s cctv-native/tests -v
python cctv-native/build_service.py --check
node --check cctv-native/engine.cjs
python -m py_compile cctv-native.py cctv-native/service.py cctv-native/cctv_native_ts.py cctv-native/build_service.py
```

CI 运行 Python 3.10 / 3.12 与 Node 22 的离线检查，不执行官方接口实播。FFmpeg 可用于开发时验证输出解码，服务运行不依赖它。

取流停滞排查：`source-media-stalled` 表示播放器初始化已完成，但 30 秒内没有发布新分片，不直接说明原因。新版日志打印首次进入的 `phase`、每次网络重试的 `operation/cause`，出错时自动打印脱敏 `diagnostics` JSON；`/status` 同时提供 `operation`、`operation_seconds`、`playlist_entries` 和 `last_segment_bytes`。`media-playlist` 指清单获取，`segment-download` 指分片下载，`sdk-transform` 指原组件处理。诊断不输出上游地址、签名、异常原文或证书内容，仍保留原来的超时保护。

若 `source-api` 出现 `URLError:SSLError`，新版只为该官方 API 增加一次保留证书与主机名校验的 TLS 1.2 兼容重试，其他媒体请求不套用这项协议限制。日志同时显示 OpenSSL 的枚举原因，便于进一步区分握手故障；证书验证失败不会触发兼容重试。手机该故障尚待新版实测，不保证 TLS 1.2 一定解决。

加载耗时说明：手机成功播放后的日志显示，初始 SSL 失败重试仍可占用约 13 秒。应先关闭针对央视域名的 MitM，再重启服务和选台，避免把握手失败耗时算作播放器缓冲。新版本默认在读取订阅时预热，并减少 TS 映射索引构建、列表切片和重复解析；保留相邻片边界证明与输出一致性检查。首次清单就绪会打印 `media-ready startup_seconds=...`，该数值从本次后台准备开始计算，不包含播放器自身缓冲。
