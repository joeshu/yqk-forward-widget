# 央视影音 App UDRM 单文件 v0.2.1（无 JDK）

v0.2.0 把原 App SDK 的 ARM64 运行层移植到 **系统 JavaScriptCore + WebAssembly 解释器**。运行只使用 Python 标准库和系统 JavaScriptCore，不再启动 Java、Node、编译器、FFmpeg 或外部 OpenSSL 命令。许可和视频处理继续由原样官方 SDK 完成。

开发环境已通过真实官方许可、原错误样本和实时HLS解码测试；**用户 iPhone APTV 实机尚待验收**。这里不把 Linux JavaScriptCoreGTK 的测试当作手机实测。

## APTV 添加与订阅

1. 停止旧的 JDK 版服务，添加下面带版本号的 Python 文件。
2. 在 APTV 脚本服务中启动，日志应显示 `原 App UDRM 无JDK版 0.2.1`。
3. 首次先检查宿主的 JavaScriptCore/WebAssembly 能力，再下载约3.55MiB（SDK压缩段约2.10MiB、解释器约1.45MiB）。看到“SDK 已取得许可并就绪”后刷新订阅；17ms之类的列表测速不表示SDK已经就绪。若服务器不支持分段下载，日志会说明回退约47MiB的完整安装包。

[下载 cctv-app-udrm-v0.2.1.py](https://raw.githubusercontent.com/joeshu/yqk-forward-widget/main/cctv-app-udrm/cctv-app-udrm-v0.2.1.py)

手机同机订阅：

```text
http://127.0.0.1:8769/all.m3u
```

状态：`http://127.0.0.1:8769/status`。正常应显示 `version: 0.2.1`、`jdk_required: false`、`sdk_phase: ready`。HTTP监听先启动，下载和授权在后台进行，准备期间可查看 `preparation_progress` 和 `preparation_error`。如果宿主不支持所需能力，会在下载前报错；这个错误需更换支持该能力的运行环境，不能靠继续等待解决。`start(ctx)` 和托管线程入口均保留，跳过托管环境不允许的进程信号注册。

脚本运行需要 Python 3.10+、`ctypes`、`ssl`，以及支持 WebAssembly、BigInt 的系统 JavaScriptCore。默认从 iOS 系统路径加载框架。没有手工安装 pip 包、JS文件、JAR或完整安卓虚拟机的步骤。当前默认文件 [cctv-app-udrm.py](cctv-app-udrm.py) 与带版本号文件完全相同。

终端运行：

```bash
python3 cctv-app-udrm-v0.2.1.py
# 指定端口、缓存或关闭预热
python3 cctv-app-udrm-v0.2.1.py 8769 --cache-dir ./cbox-cache --no-warmup
# 能力检查，不访问节目源
python3 cctv-app-udrm-v0.2.1.py --doctor
```

电脑/服务器供手机访问时，显式加 `--host 0.0.0.0`，订阅地址改为该电脑的局域网IP。Linux开发测试使用JavaScriptCoreGTK共享库，通过 `--jscore-library /path/to/libjavascriptcoregtk-4.1.so.0` 指定；它不是iPhone需下载的依赖。

## 已验证与保留范围

默认目录为 **CCTV-1、CCTV-7、贵州卫视** 三个已验证的App实时来源。原 [cbox-live](../cbox-live/) 的61台目录继续保留；尚未把全部61台App源标成可播。CCTV-5/5+观察到403，未列入本版默认目录。

- 五组离线样本经无JDK处理后，与之前官方SDK版的输出逐字节一致，音视频解码错误均为0。
- 最终单文件在禁止 `subprocess.Popen` 的验证中仍完成正式许可和媒体处理，旧“95条”和“126条错误”样本恢复正常。
- 三路并发各60秒音视频解码错误均为0；实时测试和本地HTTP响应记录见 [无JDK验证](NOJDK-VALIDATION.json)。服务响应时间不代表手机APTV首帧或切台时间。
- 已人工查看处理后的央视画面，台标、字幕和画面正常。原SDK样本对照仍见 [SAMPLE-VALIDATION.json](SAMPLE-VALIDATION.json)。

本入口尚未合并EPG，原61台服务的节目单继续保留。更多频道的实时调度签名、CDN权限与用户手机的内存/首帧表现仍需继续核对。

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
