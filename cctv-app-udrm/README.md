# 央视影音 App UDRM 单文件 v0.2.7（无 JDK）

v0.2.0 把原 App SDK 的 ARM64 运行层移植到 **系统 JavaScriptCore + WebAssembly 解释器**。运行只使用 Python 标准库和系统 JavaScriptCore，不再启动 Java、Node、编译器、FFmpeg 或外部 OpenSSL 命令。许可和视频处理继续由原样官方 SDK 完成。

开发环境已通过真实官方许可、原错误样本和实时HLS解码测试；**用户 iPhone APTV 实机尚待验收**。这里不把 Linux JavaScriptCoreGTK 的测试当作手机实测。

## APTV 添加与订阅

1. 停止旧的 JDK 版服务，添加下面带版本号的 Python 文件。
2. 在 APTV 脚本服务中启动，日志应显示 `原 App UDRM 无JDK版 0.2.7`。
3. 首次先检查宿主的 JavaScriptCore/WebAssembly 能力，再下载约3.55MiB（SDK压缩段约2.10MiB、解释器约1.45MiB）。看到“SDK 已取得许可并就绪”后刷新订阅；17ms之类的列表测速不表示SDK已经就绪。若服务器不支持分段下载，日志会说明回退约47MiB的完整安装包。

[下载 cctv-app-udrm-v0.2.7.py](https://raw.githubusercontent.com/joeshu/yqk-forward-widget/main/cctv-app-udrm/cctv-app-udrm-v0.2.7.py)

手机同机订阅：

```text
http://127.0.0.1:8769/all.m3u
```

状态：`http://127.0.0.1:8769/status`。正常应显示 `version: 0.2.7`、`jdk_required: false`、`sdk_phase: ready`。HTTP监听先启动，下载和授权在后台进行，准备期间可查看 `preparation_progress` 和 `preparation_error`。如果宿主不支持所需能力，会在下载前报错；这个错误需更换支持该能力的运行环境，不能靠继续等待解决。`start(ctx)` 和托管线程入口均保留，跳过托管环境不允许的进程信号注册。

脚本运行需要 Python 3.10+、`ctypes`、`ssl`，以及支持 WebAssembly、BigInt 的系统 JavaScriptCore。默认从 iOS 系统路径加载框架。没有手工安装 pip 包、JS文件、JAR或完整安卓虚拟机的步骤。当前默认文件 [cctv-app-udrm.py](cctv-app-udrm.py) 与带版本号文件完全相同。

终端运行：

```bash
python3 cctv-app-udrm-v0.2.7.py
# 指定端口、缓存或关闭预热
python3 cctv-app-udrm-v0.2.7.py 8769 --cache-dir ./cbox-cache --no-warmup
# 能力检查，不访问节目源
python3 cctv-app-udrm-v0.2.7.py --doctor
```

电脑/服务器供手机访问时，显式加 `--host 0.0.0.0`，订阅地址改为该电脑的局域网IP。Linux开发测试使用JavaScriptCoreGTK共享库，通过 `--jscore-library /path/to/libjavascriptcoregtk-4.1.so.0` 指定；它不是iPhone需下载的依赖。

## 已验证与保留范围

默认目录为 **CCTV-1、CCTV-7、贵州卫视** 三个已验证的App实时来源。原 [cbox-live](../cbox-live/) 的61台目录继续保留；尚未把全部61台App源标成可播。CCTV-5/5+观察到403，未列入本版默认目录。

- 五组离线样本经无JDK处理后，与之前官方SDK版的输出逐字节一致，音视频解码错误均为0。
- 最终单文件在禁止 `subprocess.Popen` 的验证中仍完成正式许可和媒体处理，旧“95条”和“126条错误”样本恢复正常。
- 三路并发各60秒音视频解码错误均为0；实时测试和本地HTTP响应记录见 [无JDK验证](NOJDK-VALIDATION.json)。服务响应时间不代表手机APTV首帧或切台时间。
- 已人工查看处理后的央视画面，台标、字幕和画面正常。原SDK样本对照仍见 [SAMPLE-VALIDATION.json](SAMPLE-VALIDATION.json)。

本入口尚未合并EPG，原61台服务的节目单继续保留。更多频道的实时调度签名、CDN权限与用户手机的内存/首帧表现仍需继续核对。

## 0.2.7 寄存器批量读取与TLS EOF恢复

用户0.2.6日志已确认：队列接近0，映射校验约0.03–0.07秒，但SDK处理4秒视频约3.69–8.70秒；CCTV-7还有SSLEOFError和TimeoutError。不能把当前卡顿继续归因于Python映射，也不能把网络故障与SDK执行慢混为一谈。

每次模拟器进入libc/JNI导入时，把X0–X7与返回地址LR通过同一Unicorn公开C接口 `uc_reg_read_batch` 一次读入，保留原9次读取的参数含义；标量64位寄存器读写复用独立暂存区，通过 `uc_reg_read`/`uc_reg_write` 直接调用，减少每次malloc/free和通用包装。检查原生返回码，读取失败不返回旧缓冲内容；带符号整数、32/64位边界与返回地址做一致性验证。官方SDK、模拟器WASM、许可检查和清晰度不变。

同一开发环境进程交替比较3轮、每轮20,000次寄存器读写：旧路径94/60/61ms，新路径16/13/11ms，中位数61→13ms。这是寄存器接口微基准，不是整个SDK或手机首帧提速倍数。

遇明确的TLS提前EOF/RemoteDisconnected时，仅使用同URL新连接重试一次；证书拒绝、HTTP拒绝、正文损坏、普通超时不做这次额外重试，避免无限重试或延长超时。二次失败仍进入原有退避。正常HTTPS证书校验和完整性检查保留。

许可就绪日志与 `/status` 新增 `runtime_features`：正常启用时 `bulk_memory`、`register_batch`、`register_scalar` 为true，便于核实手机是否实际使用加速路径。缺少导出能力时保留兼容路径，不伪报启用。

39项回归检查通过，三组原样本600帧错误0、输出摘要不变；三路高清依次各20秒音视频解码错误0，状态确认三项运行层加速均已启用。验证见 [0.2.7报告](REGISTER-VALIDATION-v0.2.7.json)。手机实际速度仍需同清晰度实测；用户日志中SDK已超过实时预算，本次只是继续降低运行层开销，不能保证每台手机仅靠解释器就能持续高清播放。

## 0.2.6 保持高清，优化内存复制

按用户要求恢复原有2.5Mbps码率选择上限：CCTV-1/7官方主清单当前选择1280×720、1.8Mbps；贵州卫视使用其原有档位。没有使用0.2.5默认的600kbps降档，不转码、不修改分辨率、音频或时间戳。

确认Unicorn.js 2.1.4的 `mem_read` 包装逐字节清零和读取结果，并且每次分配/释放临时空间。新增自有批量适配层，通过同一模拟器导出的 `uc_mem_read` / `uc_mem_write` C接口和可复用暂存区传递数据，用TypedArray批量复制。WebAssembly.Memory来自标准instantiateWasm宿主钩子；每次分配后重新获取视图以适应内存增长，原生调用失败时不返回任何未初始化内容。已固定摘要的官方SDK和Unicorn二进制均未修改。能力不完整时仍保留原包装层兼容路径。

每个最多4-PES批次仅分配一个媒体工作缓冲区，逐帧复用并清零64字节尾部，避免逐帧分配及先清零整帧再覆盖。每帧仍完整交给原SDK，保持同台状态和等长校验，不通过跳过保护数据换取速度。

开发环境单项基准：512KiB往返读写30轮，旧包装547ms，新适配8ms；这是内存复制微基准，不是整段SDK、首帧或手机播放提速倍数。原三组样本输出SHA-256与历史正确输出一致，600帧音视频解码错误0，36项检查通过。三路高清依次各20秒解码无错误；CCTV-1首轮397帧、重复测试498帧，保留首轮可能存在的时间连续性/可用性问题，不把“无解码错误”等同于已经完全无卡顿。见 [0.2.6验证](HD-VALIDATION-v0.2.6.json)。手机实际改善仍需同清晰度实测；模拟器内部执行、上游等待仍可能限制实时性。

## 0.2.5 手机码率、抢占与重试

用户0.2.4完整日志显示许可已成功，但三台仍交替处理，4秒分片用了5.24–19.89秒；这个指标包含等待SDK锁，不能直接断言都是模拟器执行时间。CCTV-7还反复出现URLError。

本版默认码率上限由2.5Mbps改为600kbps，依据官方主清单选择CCTV-1/7已有的640×360、600kbps档位，而非原先1280×720、1.8Mbps。以降低清晰度换取较小的下载和处理量，不转码、不猜测隐藏地址。贵州卫视主清单仅有800kbps时仍用最低可用档位；600kbps是选择目标而非强行限制每台实际流量。桌面要恢复较高清晰度可指定 `--max-bitrate 1800000`。

已切走频道的任务在进入SDK锁后和每批最多4个PES之前检查选择状态，过期任务退出；若中途已处理部分PES，重置该频道SDK状态，丢弃整片输出，防止带着半处理状态续播。当前批次不能强制中断，不会终止正在运行的官方代码。

状态新增 `media_timings`，记录每片解析、排队、SDK调用、映射/其他处理时间；日志打印排队/SDK/映射校验/视频时长。SDK调用计时包括工作线程调度，不是硬件CPU计数。上游重复失败退避3、6、12、24、30秒，成功发布后恢复；URLError增加安全的底层异常类型，保持正常TLS证书校验。

34项检查通过，三组原样本共600帧错误0，三路依次各20秒实时音视频解码错误0。CCTV-7期间出现一次上游超时，恢复后的首次清单共等了26.958秒；不据此宣称所有首播耗时已改善。验证见 [0.2.5报告](PERFORMANCE-VALIDATION-v0.2.5.json)。这些优化仍不构成手机实时播放保证；若排队接近0而SDK处理时间持续超过视频时长，纯解释器已成为实际性能限制，需要更快的运行宿主或服务端运行同一脚本。

## 0.2.4 按需处理与逐片发布

用户手机0.2.3已取得真实许可，但三路初次刷新分别96.52、108.68、123.81秒，画面仍转圈。旧实现启动时同时预取三台，在同一个SDK工作线程串行处理，并等整轮分片完成才发布清单，显著增加手机首播等待。这些刷新耗时包含授权和争用，不能当作单台SDK的纯处理速度。

启动仅预热SDK和许可，三台目录保留，媒体只处理最近选择的一台；切台后旧频道处理完当前分片便让出后续任务。首个完整且已校验的分片立刻发布，后续分片逐片追加。已有清单立即返回，刷新在后台继续；首次请求最多等待8秒，尚未就绪返回503和Retry-After，避免HTTP工作线程被整轮处理长期占用。若播放器不自动重试，可在SDK就绪后重新打开频道。

SDK调用以最多4个PES为一组批量跨越Python/JavaScriptCore边界，减少队列、JS编译和缓冲区传递次数。仍逐PES调用原SDK，保留帧顺序、每台状态、等长检查、原音频和时间戳；任何处理失败均不输出未经处理的视频。

状态中的 `processing_to_video_ratio` 表示单分片处理耗时/视频时长，包含等待SDK锁的时间。持续大于1时会提示“低于实时速度”，意味着当前宿主仍不能连续实时播放；本版不能保证纯解释器在每台iPhone都能达到实时速度。开发环境29项检查通过，最终单文件三组样本600帧错误0；三路依次各20秒音视频解码错误0，首次清单分别6.341、11.039、8.528秒，每次首个清单均只有1片，证明逐片发布路径已执行。这些是开发机HTTP响应耗时，不是手机首帧。测试见 [0.2.4验证](PLAYBACK-VALIDATION-v0.2.4.json)，手机首帧与持续播放仍待验证。

## 0.2.3 Android/Linux 与 iOS socket ABI 转换

用户0.2.2手机日志中的 `sdk_license_rejected code=80001001` 是SDK返回码，不能单凭它认定官方服务器已收到并拒绝许可请求。审查发现桥接层曾直接透传主机socket常量和errno，Linux开发机上碰巧相同，Darwin/iOS上并不相同。

新增非阻塞连接errno、socket选项及消息标志转换。例如iOS `EINPROGRESS=36` 转成Android/Linux的115；`SOL_SOCKET`、`SO_ERROR`、收发超时等按主机名称映射；`SO_ERROR`返回的主机errno再次转成Linux值。Darwin发送使用可用的SO_NOSIGPIPE，未知选项/标志明确失败，不直接套用错误编号。许可失败时保留并打印请求长度、HTTP状态、业务状态或传输异常类型；未记录许可正文或密钥。空记录表示尚无完整HTTP POST到达本地许可处理器，并不能区分TLS握手与更早的连接失败。

开发环境26项检查通过，其中5项模拟Darwin编号差异；最终文件真实官方许可通过，三组样本600帧解码错误0。见 [0.2.3验证](SOCKET-VALIDATION-v0.2.3.json)。已修复确定的跨平台兼容缺陷，尚待手机确认是否解决此次80001001；没有把模拟编号测试当作iPhone实测。

## 0.2.2 手机初始化等待修复

用户iPhone的0.2.1日志已确认系统WebAssembly检查通过、SDK缓存校验通过；随后失败于 `unsupported libc import usleep`。这证明问题已推进到官方SDK运行时，尚不能据此判断手机授权或视频解码成功。

补齐ARM64 libc `usleep` 导入：读取32位无符号微秒参数，暂停模拟器，交给Python `time.sleep` 实际等待并释放GIL，再把返回值或errno写回并恢复SDK。零时长也会让出执行机会，不忙等、不跳过等待。单次超过30秒返回EINVAL以遵守SDK操作预算，中断返回EINTR。运行仍无需JDK、外部命令或HAR。

最终单文件在开发环境强制执行真实ARM64 `usleep` 导入20,000微秒，实测23.6毫秒后恢复返回0；随后真实官方授权通过，三组样本共600帧、音视频解码错误0，21项检查通过。见 [0.2.2验证](WAIT-VALIDATION-v0.2.2.json)。这是开发环境验证，手机后续初始化和播放仍需实测；未改动官方SDK或许可判断。

## 0.2.1 首次启动优化

截图中的0.2.0仍在下载完整官方安装包，尚无后续授权结果。0.2.1使用严格HTTP Range直接下载固定版本SDK的压缩段，要求206及完全一致的Content-Range，并核对正文长度、解压大小、CRC和SDK SHA-256；摘要不符时停止，不加载其他版本。仅服务器不支持Range或请求无法建立时回退完整安装包，仍校验完整APK摘要。SDK二进制未上传仓库。

空缓存开发环境测试下载共3,721,415字节，用时9.139秒；这是开发环境下载耗时，不是iPhone首帧承诺。最终单文件真实许可通过，三组样本共600帧、音视频解码错误0，17项离线检查通过，见 [0.2.1验证](STARTUP-VALIDATION-v0.2.1.json)。0.2.0的三路60秒实时结果仍保留在原报告中，本次没有把旧结果记作0.2.1手机测试。

当前仅支持有JavaScriptCore/WebAssembly能力的宿主；尚无本用户iPhone实机通过的记录。旧版 [v0.2.0](cctv-app-udrm-v0.2.0.py) 保留供回退。

## 0.2.0 改动

移除运行时JDK/Maven、Java子进程和外部证书生成命令；使用标准库解析已固定摘要的ELF，JavaScriptCore运行Unicorn WASM/TCI。每个SDK会话固定在一个工作线程上，原SDK真实许可检查返回0后才处理媒体。

视频通过主机自己的TypedArray缓冲区传递，避免逐帧把整段视频编成JS源码；SDK状态、许可及密钥不会经这个接口返回。大型ELF描述使用原生JSON接口装载，减少JS编译开销。模拟器的8MiB分配区支持空闲块拆分、合并和回收，避免连续播放时因碎片反复重建许可会话。

首次先完成SDK与许可准备，再获取当前直播窗口，避免准备期间的旧分片影响首播。保留并行预取、最近观看时后台刷新、本地最多五片清单窗口、缓存清单/分片直接响应、完整206及Content-Length检查、TS/PES校验、音频与时间戳保留、相邻分片边界证明。没有未处理视频的“成功”回退。当前不支持跨HLS对象延续同一个PES、fMP4或HLS AES/SAMPLE-AES。

默认尝试使用App临时目录缓存已校验的SDK和解释器，缓存不可写时使用内存。临时TLS证书由标准库生成，仅用于回环传输，加载后立即删除临时文件；不读取设备/厂商私钥。外部HTTPS继续使用正常证书校验。HAR只用于离线研究，运行不会读取、扫描或重载HAR。

## 开发验证与来源

```bash
python3 -m unittest discover -s tests -v
```

普通离线检查仅用标准库。分配器压力检查需要系统JavaScriptCore；Linux可通过测试环境变量 `CCTV_JSC_LIBRARY` 指定库位置。检查覆盖同线程SDK调用、许可拒绝、处理失败不返回原始视频、只读缓存、TS重复包/截断/边界、HTTP Range、HEAD及10000次分配回收。

SDK从[央视影音官方APK](https://download.cntv.cn/app/cntv/cbox_7.9.31_release_androidguanwang.apk)下载，校验APK和指定库SHA-256，不在仓库分发二进制。解释器使用 [Unicorn.js v2.1.4](https://github.com/AlexAltea/unicorn.js/tree/v2.1.4) 官方发布物并固定SHA-256；其上游GPLv2说明与源代码见该项目。单文件中的Python与JS适配源码均为可读文本。

旧服务器/JDK版保留为 [cctv-app-udrm-jdk-v0.1.0.py](cctv-app-udrm-jdk-v0.1.0.py)，需要JDK21和OpenSSL，供旧部署回退，不是本版APTV手机入口。[LIVE-VALIDATION.json](LIVE-VALIDATION.json)、[FRESH-VALIDATION.json](FRESH-VALIDATION.json)属于旧版历史记录；本版证据以 `NOJDK-VALIDATION.json` 为准。
