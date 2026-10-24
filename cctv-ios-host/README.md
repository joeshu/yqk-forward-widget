# CCTVHost — iOS 频道与本机资源宿主

本目录包含 Objective-C/UIKit iOS App，最低系统版本 iOS 15。当前代码包括频道与订阅浏览、原生及 AVPlayer 播放入口、EPG、资源导入、Python/JavaScript/Node 插件服务和独立日志中心。

实现状态、测试证据、性能测量限制和真机验收清单见 [QUALITY-REVIEW-v0.18.0.md](QUALITY-REVIEW-v0.18.0.md)。代码存在不代表央视 SDK 真机起播、插件端口释放或媒体解码已经在设备上验证。

## 构建

用 macOS 和 Xcode 打开本目录中的 XcodeGen 工程描述：

    brew install xcodegen
    cd cctv-ios-host
    xcodegen generate
    open CCTVHost.xcodeproj

为真机选择自己的签名 Team，并确认嵌入式 framework 的签名设置。仓库 CI 另用 Scripts/ci-build.sh 生成 unsigned IPA。

央视播放 framework 仅包含设备 arm64 架构，原生播放须在真机验证。仓库另有使用 SDK 替身的模拟器 UI smoke；该测试只覆盖宿主界面和部分 AVPlayer 流程，不代表央视 SDK 解码通过。

## 导航与日志

主入口为 CCTV、频道、影视、资源、设置。资源与服务管理、订阅、EPG 和播放诊断沿用 CCTVHost 自身的数据模型和视觉风格。

设置中的日志中心显示宿主总日志；服务详情中的日志页仅显示对应服务脚本输出。每个插件日志可单独搜索、复制、导出和清空。日志进入存储、展示或导出前会对常见凭据字段脱敏。

服务开关按服务 ID 管理。不同端口的 Python HTTP 服务、Node 插件及 JavaScriptCore 插件可以同时启动；关闭一个服务只请求停止该服务及其关联的媒体运行时。相同端口不能同时监听，启动时会检查已运行服务并给出端口冲突提示。服务卡片显示各自运行会话，HTTP 检测仍需在详情页单独执行。

## 播放器诊断边界

日志中 SDK 类可加载、配置对象构造、播放调用返回，只能说明对应初始化步骤已执行，不能证明鉴权通过或视频已解码。只有 SDK/AVPlayer 实际回调和画面可用于确认对应播放状态。

CNPlayerSDK 是原生央视直播入口。CCTV 页按频道 ID 交给 SDK 自动调度；自选 WS/BD/KS/TX 地址会先做限时、限大小且可取消的 HLS 清单检查，确认明文时用 AVPlayer，其他所选地址继续交给 `playLIVEWithUrl:delegate:configOptions:`。明文自选播放留在 CCTV 页，保留线路选择及重试，不自动混入订阅来源。SDK 路径继续通过 CNPlayer，并传入当前可取得的 SDK 用户 ID、频道统计 ID和播放器回调；宿主没有关闭或改写授权配置。SDK 是否接受及完成特定地址的授权和解码，仍需真机确认。请求被拒或播放失败时会保留所选线路，不静默切回自动。播放信息展示所选完整来源地址（保留查询参数）和 SDK 返回节点（取不到时显示未知）。[节点故障调查](Docs/CCTV-NODE-ROUTING-DIAGNOSIS.md)与[IPA 自选线路落地记录](Docs/CCTV-IPA-SELF-ROUTES-RESEARCH.md)说明了现有路径、SDK 接口证据及验证边界。

[原 IPA 自选线路核实](Docs/CCTV-IPA-SELF-ROUTES-RESEARCH.md)记录了三个直播 URL 前端实际调用 CNPlayer 的证据，以及两组原始媒体普通解码异常。可运行 `python3 Scripts/audit_ipa_live_routes.py` 只读复核；这是静态审计，不是原生播放验收。

Python Spider 的 `localProxy` 支持常见 `[状态码, 响应头, 内容]` 返回值；本机代理保留媒体类型、Range 与 Content-Range，GET/HEAD 分开传递，并对带请求头的 HLS 分片使用有界本机转发。相同参数的目录/详情请求会合并进行中的调用。协议测试只验证本机桥接行为，不能替代 iPhone 上的上游可达性和视频解码验收。

本地导入还识别 `WidgetMetadata` / `Widget.http` / `loadResource(params)` 影视解析脚本，并将搜索结果接入影视页详情和 AVPlayer 播放流程；Widget HTTP 响应限时、限大小。CatPaw 的 `globalThis.Pans` ESM Fastify 包由 Node 宿主绑定本机服务并在停止时关闭。带有明确 argparse `--port`、`--bind` 声明的 Python HTTP 包会使用 CCTVHost 分配的端口；检测到 `/all.m3u` 生成器与路由时，启用服务后自动添加本机订阅。原始 ZIP 会保留，运行时补充的 ESM `package.json` 只写入应用沙盒中的解包副本。

## 本地验证

    cd cctv-ios-host
    python3 -m unittest discover -s Tests -p 'test_*.py' -v
    (cd JSPlugins && npm test)

完整 iOS 设备构建和替身 UI smoke 由仓库 .github/workflows/cctv-ios-host.yml 在 macOS runner 执行。具体真机验收项和当前未验证项目见质量审查记录。

## 已知边界

- Python 插件共用一个嵌入式 CPython 解释器和 GIL；宿主会隔离每个会话的 Python `os.environ` 视图、启动参数、日志、监听器、工作线程和停止回调，并串行化脚本初始化，但这不是进程级沙箱。插件若依赖同名全局模块、直接修改进程级状态或创建宿主无法跟踪的线程，仍可能互相影响；此类插件无法承诺同时稳定运行。
- Node 插件各自跟踪定时器、请求、Socket、监听器、存储目录、常见插件全局对象和环境视图，但仍共用一个 Node 进程；任意第三方原生模块或未纳入会话作用域的全局副作用仍可能共享。
- JavaScriptCore 为每个会话分配独立 context、串行队列和网络请求集合；同一 App 进程仍受系统内存及后台执行限制。
- Python、JavaScriptCore 与 Node.js Mobile 服务运行受 iOS 后台执行策略限制；系统终止 App 后，不能保证插件继续运行。
- 通用 Python HTTP 服务没有统一健康协议时只能显示 HTTP 可达与状态码，不能证明频道清单正确或媒体成功解码。
- 央视 SDK 的线路、首帧、实际分辨率和错误语义需要真机及授权服务验证。本工程不绕过登录、版权、地域或来源访问控制。
- 历史磁盘日志不会被静默改写；其 UI 和导出会先应用日志脱敏。

附件资源兼容、旧沙盒路径修复、手机端运行限制与复现命令见 [0.18.1 兼容说明](Docs/imported-samples-compatibility.md)。
