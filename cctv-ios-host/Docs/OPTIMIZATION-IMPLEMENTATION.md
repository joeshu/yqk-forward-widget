# CCTVHost 三阶段全面审查与实施记录

基线：`061644dd3194e9d358e8fbb0cf0d90cd65370cbc`。本轮目标为 iPhone 优先，保留 CCTVHost 的五个主入口及现有媒体/服务模型。兼容性边界沿用仓库现状：XcodeGen 开发目标和 UI-only simulator smoke 为 iOS 15；包含 JAR 运行时的完整 IPA 由 release 脚本设为 iOS 17。下面按实际改动记录，不把协议识别、SDK 可调用或源码 smoke 当作真机播放成功。

## 阶段状态

| 阶段 | 实施状态 | 主要交付 |
| --- | --- | --- |
| 一：播放正确性、生命周期与导入稳定性 | 源码实现完成 | 播放所有权、系统命令、请求头作用域、协议分流、密钥请求、快照恢复、回归覆盖 |
| 二：播放与频道 UI、辅助功能、控制器边界 | 源码实现完成 | 共用浮层策略、触控/布局修正、轨道入口、频道/标签子控制器、主题对比度、UI smoke probes |
| 三：列表、直播来源及本机资源能力 | 源码实现完成 | TXT/M3U/catch-up/LL-HLS、TVBox 内嵌直播、媒体服务器适配、本机媒体库 |
| Apple 平台构建、模拟器及设备验收 | 当前环境未执行 | 需要 macOS/Xcode；具体清单见“发布前设备验收” |

“源码实现完成”表示改动与宿主侧自动化验证已准备好，不代表 Apple 编译、视觉验收、外部服务兼容或实际解码已通过。

## 阶段一：播放正确性、生命周期与导入稳定性

### 播放所有权与系统控制

- 新增 [PlaybackCoordinator.h](../Sources/PlaybackCoordinator.h) 和 `PlaybackCoordinator.m`，把当前活动会话作为弱引用单一所有者。频道页与影视页共享系统播放/暂停、上一项/下一项命令；切换所有者先暂停旧会话，旧页面退出不会释放新页面的所有权。
- 处理中断时记录中断前的播放意图；仅在系统允许恢复且所有者仍相同时恢复。用户主动暂停、耳机拔出、媒体服务重置均不会静默续播。
- Root 与影视播放器实现统一的 `PlaybackSession`。远程命令、Now Playing 状态更新和多播放器互斥均经同一入口。
- Cicada 首帧预算在暂停期间停止计时，恢复时只使用剩余预算；解码器切换保留暂停/播放意图，且播放器切换失败会呈现明确状态。

### 播放地址与请求安全

- 新增 `MediaDescriptor`，统一保存归一化 URL、请求头、容器、传输层及“已识别 / 未知 / 明确不支持”的区分。未知格式仍可尝试当前已有引擎；明确不支持的容器/编码不会被伪装为已支持。
- `MediaPlaybackHeadersScopedToURL` 在交给 AVPlayer/Cicada 前、以及 catch-up 和自定义 HLS 密钥请求时，按目标地址筛选请求头；同源和同主机标准端口 HTTP→HTTPS 升级保留来源请求头，跨源仅保留明确的通用传输头。HLS relay 的资源重定向、清单、分片和密钥请求沿用同样的跨源白名单，避免自定义 `X-Auth` / `X-Access-Key` 等认证头绕过旧的名称黑名单。
- AVPlayer 的直连 HLS 子分片和内部重定向由系统网络层加载，公开 API 不提供逐个子请求改写请求头的回调。需要认证且清单会跨域跳转/取分片的来源应经 `localProxy` 转发；本机不能仅凭初始 URL 的头作用域断言 AVPlayer 内部的所有子请求都已过滤。
- 新增 `MediaKeyRequest`：一次性完成、可取消、请求 6 秒/资源 8 秒超时、最多 4 KiB、要求成功 HTTP 状态、最多 5 次重定向且拒绝 HTTPS 降级。只接受规范化后的 16 字节 HLS AES-128 密钥。
- HLS AES-128 密钥请求不等于 DRM。FairPlay 证书/许可协商、Widevine、PlayReady 及 DRM 服务集成都未实现。
- `MediaPlaybackDecodeRouter` 只把带 MPD 根节点的 XML 识别为 DASH；普通 XMLTV/任意 XML 不再误判。文档页回到 WebView 路径，直接媒体继续走原生引擎。
- RTMP/RTMPS 在共同能力表、播放归一化和 Cicada 路由内使用同一判定。媒体运行时的订阅/字幕/许可 URL 校验仍限制在 HTTP(S)，不会把 RTMP 当成通用 HTTP 地址。

### UI 与手势的确定性修复

- 直播纵向手势每次消费位移增量，并在开始时锁定亮度或音量区域；横向主导手势不改系统音量/亮度。
- 频道页头图的比例高度使用较低约束优先级，同时保留 300pt 必需上限；主题刷新使用保存的语义边框色。
- Cicada 与 AVPlayer 首帧监测不再由两套并行计时器重复触发。页面可见性恢复只解除挂起，不替用户自动开始播放。
- EPG 跳转保留 catch-up 元数据和同域请求头；退到历史直播时根据模板和节目时间生成受天数边界限制的地址。

### 资源导入快照

- 导入恢复改为串行后台读取，并只在用户尚未修改表单/选择时应用旧快照；不再在页面初始化时同步解析大 JSON。
- 快照格式 v2 将较大的 NSData 作为 sidecar 存储，旧 v1 仍可读；清单和唯一 sidecar 合计上限 80 MiB，写盘原子替换，短时间多次变更合并写入，并在写入成功后清理孤立 sidecar。恢复期间有文本或选择编辑时，旧快照不会覆盖用户的新内容；只在真实写盘成功后报告持久化成功。
- 冻结恢复快照前加入 300ms debounce，后台任务在系统切后台时及时结束。

## 阶段二：界面、交互、视觉和控制器边界

### 频道与影视播放控件

- 新增 `PlaybackOverlayController` 统一控制浮层显示、自动隐藏、VoiceOver 常驻和定时器失效；暂停、拖动/手势和辅助功能状态会阻止不合时宜的隐藏，拖动结束会重新计时。
- CCTV 主播放操作保留播放、静音、全屏和更多菜单；线路与 EPG 从主操作区移入“更多”，AirPlay 入口仍可访问。
- 影视独立播放器的长控件列进入可滚动视口，竖屏和大字体下不会挤压到不可触达；内嵌播放维持现有容器行为。
- 播放器轨道菜单可显示 SDK 实际提供的音轨/字幕轨并请求切换。若 SDK 未提供轨道信息，界面说明“引擎尚未提供”，不误报为片源没有轨道。
- WebView 路由恢复可达，同时直接媒体优先走原生路径；避免把 MP4/HLS 等直接地址送入无意义的网页解析。

### 无障碍、主题与点击区域

- 主题的强调色与小尺寸按钮填充色分开，保留主题识别的红色，同时提升选中项白色文字对比度。
- 降低透明度时，玻璃材质改成实色卡片并加强边框；玻璃背景监听辅助功能设置变化。
- 列表行按 Dynamic Type 字体计算高度，重新加载时更新；播放速度入口扩大到至少 44pt 高的可点击区域，并有明确无障碍动作。
- 小尺寸辅助按钮隐藏容易截断的视觉标题，但保留完整 VoiceOver label；全屏控件在进入/退出全屏及 Dynamic Type 变化时更新名称和操作提示。
- 频道列表在窄单元格中为健康状态徽标预留标题宽度，避免标题和状态文字互相覆盖。

### 控制器拆分

- 新增 `HostTabBarController`，承接五个底部标签按钮和点击转发；Root 仍掌握全局选中状态以兼容原有视觉/页面状态。
- 新增 `HostChannelCatalogController`，承接频道表格/网格容器和空白表面点击穿透。Root 仍维护频道业务数据源和筛选状态。本阶段是边界拆分，不是对 RootViewController 的整体重写。
- 新增 `LocalMediaViewController` 作为单独的本机媒体列表。使用多选文档导入、文件协调与安全作用域访问，将文件复制到 App Support；播放只接受该受信任目录内解析符号链接后的文件。导入名有 UTF-8 长度上限，避免超长文件名写入失败。

### UI smoke probes

`Tests/UISmoke` 新增播放所有权/中断、手势事件频率独立性、导入快照恢复、Cicada 暂停首帧预算检查。它们使用宿主假对象或 SDK 替身，不会触发实际系统音量、摄像机频道或 SDK 解码。必须在 macOS workflow/模拟器构建后执行，Linux 本轮无法运行。

## 阶段三：订阅、协议适配器及本机媒体入口

### 共同媒体能力表

`Plugins/media-capabilities.json` 是源文件；`Scripts/generate_media_capabilities.py` 生成 Objective-C 的 `Sources/MediaCapabilityRegistry.h`。`--check` 会验证生成文件没有漂移，Python 与 Objective-C 共享同一组名称。

| 分类 | 可识别/路由范围 | 实际边界 |
| --- | --- | --- |
| 网络传输 | HTTP、HTTPS、RTMP、RTMPS | HTTP(S) 根据容器走 AVPlayer 或 Cicada；RTMP(S) 交 Cicada。能力表 `verifiedNetworkTransports` 为空，表示没有设备验证声明 |
| AVPlayer 容器 | HLS/M3U8、MPEG-TS、MP4/M4V/MOV、常见音频、fMP4/CMAF | 仍由 iOS 系统解码器、清单和设备能力决定；不能仅凭扩展名承诺成功 |
| Cicada 容器/协议 | FLV、DASH/MPD、MKV/Matroska、WebM、3GP、RTMP | 实际解码受仓库内 SDK 二进制、SDK 配置、编解码器和设备影响；需真机验证 |
| 明确不支持 | AVI、WMV、ASF、RM、RMVB；VP8、VP9、AV1、H.263、WMV、RV 视频编码 | 呈现当前不支持，可切换线路/格式；不表示未知编码一定失败或一定可播 |
| 未覆盖的网络协议 | RTSP、UDP、SRT 等 | 无对应播放器内核或协议适配器，本阶段不识别为可播放能力 |

媒体服务器适配器返回的直接播放 URL 仍受以上播放器能力限制；Emby/Jellyfin 服务端转码配置不会由宿主代替配置。对非 HTTP 的播放地址，媒体运行时不会注册 HTTP relay。

### M3U/TXT、catch-up、TVBox 与 LL-HLS

- M3U 解析新增 `频道名,#genre#` 分组及 `名称,URL` TXT 形式。无 `#EXTINF` 待配对项时，脚本中的裸单词不会被伪造为频道。
- RTMP/RTMPS 频道保留为单条流。M3U8 被识别为一个 HLS 媒体资源，不把分片当作独立 IPTV 频道。
- 支持从全局默认值继承 catch-up source/mode/days/tvg-shift，并生成 `start/end`、duration 或 UTC 日期模板地址；未解析模板标记和超出保留天数的请求会拒绝。
- TVBox 内嵌直播分组与频道逐项保存为内嵌播放列表，不再伪造远程来源 URL，也不会因追加第二组而删除前一组。
- LL-HLS relay 只接收经过校验的 `_HLS_msn`、`_HLS_part`、`_HLS_skip` 控制参数，保留签名查询串原始编码；初次清单请求与凭据刷新后的重试都会重新应用本次轮询参数，并避免把参数泄漏到媒体分片和密钥请求。

### 媒体服务器适配器

新增 `Plugins/host_media_servers.py`，由用户明确添加并配置；导入不会执行任意代码或自动启动远程访问。

- **Emby / Jellyfin**：用户名密码登录或 API Key，读取用户媒体库、分类、分页、搜索、详情/剧集和静态播放 URL；认证、响应 8 MiB、单请求 15 秒读取期限和 5 次重定向均有边界。
- **Xtream**：认证检查、直播/VOD/剧集分类、分页、剧集详情与播放 URL。此协议没有统一的全库分页搜索接口，因此明确显示未提供搜索，不虚报支持。
- **WebDAV**：Basic Auth、Depth 1 分页目录枚举和可逐层打开的文件夹浏览。使用 `defusedxml` 严格禁用 DTD、实体和外部实体解析，包括 UTF-16 输入；路径限制在配置根目录，禁止离开来源站点的重定向。它不提供通用服务端搜索。
- 所有适配器只允许 HTTP(S) 基础地址，基础地址不能嵌入 URL 用户名密码、查询参数或片段；跨源跳转拒绝，停止会话会释放已保存 token。

配置由固定类型和表单字段生成 CCTVHost server 资源，账号密码保存在本机资源设置中；不接受远程返回的 Python 代码作为适配器执行。真实 API 字段、认证插件、服务器版本差异仍需用用户自己的服务端验收。

### 本机媒体库

“影视库 → 我的菜单 → 本地媒体”支持多选视频/音频文件，将用户所选资源在串行后台队列内协调复制到 App Support 的隐藏暂存文件，再用同卷原子改名发布为完整文件。用户请求停止时当前文件完成后停止后续文件；目录快照不暴露未完成副本。列表可删除本机副本；删除不会修改原始文件。应用卸载会删除沙盒内副本。

## 复核后落地的边界修复

- 频道健康徽标不再按频道 ID 伪造延迟/速度，也不再把首帧等待时间冒充网络 RTT。检测使用无 Cookie、无认证头的 HTTP(S) Range 请求，最多读取 4 KiB、3.5 秒超时、最多 3 个并发；状态标成“未测 / 检测 / 可达 / 失败 / 过期”，完整请求时间、HTTP 状态和实际样本量留给 VoiceOver 读取。
- 点播网页嗅探改用有界流式读取：普通页面最多 2 MiB、请求 3.5 秒/总计 8 秒、最多 5 次跳转并拒绝 HTTPS 降级；明确的媒体 MIME 在响应头到达后立即取消正文下载。失败与超限结果不再缓存到播放器状态。
- 媒体适配诊断记录在新写入和启动恢复时统一脱敏：URL 凭据、片段及查询值会隐藏；provider URL 只保留主机名，错误文本和其他字符串字段经过敏感字段过滤。
- AVPlayer AES-128 key 重定向复用播放头作用域白名单，跨源重定向移除 Authorization、Cookie、Referer、Origin、自定义认证头；WebDAV UTF-8/UTF-16 DTD 和实体用例加入回归。
- M3U 无效/本地文件 URL 被拒绝时同步清除该条目的 catch-up 配置，避免下一条裸 URL 继承错误的回放模板。
- 点播恢复提示现在在 Cicada seek 完成后校验播放意图、视图挂起状态和当前播放所有者；锁屏/耳机媒体命令新增 toggle play/pause。
- 全屏网页嗅探超限时停止提取；直播底部玻璃层、频道悬浮控件、通用工具栏和资源头部统一注册 Reduce Transparency 实色刷新；大字号标签栏改为图标显示并保留完整 VoiceOver 标签，频道网格维持 4 列。
- UI-only smoke 改为经 RootViewController 的真实影视库标签打开测试页面，并覆盖 iPhone SE/常规 iPhone、默认/AX XXXL 字号、浅色/深色组合。Xcode workflow 对同一 ref 的构建串行，新 main 提交会取消旧运行；release job 发布前再核对 main HEAD，跳过过期构建。

## 本轮回归修复补充

- 播放会话以用户播放意图作为状态来源：解析期间暂停不会被结果回调或缓冲启动逻辑重新播放；AVPlayer 原生暂停/恢复会同步会话意图，延迟状态回调会核对当前播放器状态；Now Playing 只由当前所有者更新，画质切换会替换对应的格式和编码能力信息，自动切集保持播放状态。
- TVBox 告警在导航栈仍以该页为顶页但窗口尚未挂接时最多重试 10 次、每次 100ms；重试随页面离开或新告警取消。内嵌直播保留全局 UA、节目单、台标及逐频道请求头。
- TXT/M3U 仅包含不支持协议时会保留识别结果并说明跳过原因，不创建可选择的空白导入项。Xtream 路径凭据在诊断文本中脱敏。
- 发布动作移出构建 job，等待 IPA 构建成功并满足所选的媒体兼容矩阵；自动发布仅限 `main` 推送，手动发布需在 `main` 明确启用。

## 自动化验证记录

在仓库根目录运行：

```sh
cd cctv-ios-host
CCTVHOST_TEST_PYTHON_DEPS=/tmp/cctvhost-test-python-deps
python3 -m pip install --disable-pip-version-check --target "$CCTVHOST_TEST_PYTHON_DEPS" -r Scripts/media-python-requirements.txt
PYTHONPATH="$CCTVHOST_TEST_PYTHON_DEPS${PYTHONPATH:+:$PYTHONPATH}" python3 -m unittest discover -s Tests -p 'test_*.py' -v
(cd JSPlugins && npm test)
python3 Scripts/generate_media_capabilities.py --check
git diff --check
```

本轮最终复跑结果记录为：Python **936 项，869 通过、67 跳过、0 失败**；JavaScript 插件测试 3 个 suite 全通过；能力表生成检查、Python 语法检查、shell 语法、工作流 YAML 解析、全量源清单审计（664 个文件、0 错误）与 `git diff --check` 通过。67 项跳过包括 macOS Foundation 原生密钥测试、原生/IPA 检查及原有附件样本。Python loopback 测试覆盖 Emby/Jellyfin、Xtream、WebDAV、HTTP 重定向、认证、分页和运行时归一化，不访问公共真实服务。

Linux 环境没有 `xcodebuild`、`xcrun` 或 iOS SDK，未编译任何 Objective-C/UIKit/AVFoundation 源，也未运行 `Tests/UISmoke`。静态源契约通过不是 Objective-C 编译证明。

## 发布前设备验收

在仓库的 macOS CI/Xcode 环境按以下顺序完成；失败时先修编译/测试错误，再用测试账号和自有合法媒体源执行真实兼容验证：

1. 生成/编译 iOS App，运行完整的原生测试和 `Tests/UISmoke`，确认新增 `.m` 文件链接成功；检查新 API 可用版本。UI-only smoke 按 iOS 15 target 验证，完整 IPA 按 iOS 17 target 验证。
2. iPhone SE 级窄屏、常规 iPhone 和大字号：五标签、频道列表/网格、播放控件纵向滚动、横竖屏旋转和 VoiceOver 聚焦顺序；暗色/浅色以及降低透明度。
3. 频道切换、AirPlay、锁屏/耳机命令、来电或音频中断、插拔耳机、媒体服务重置；确认两页播放器不会同时出声，离开页面后系统命令不再操作旧播放器。
4. 自有媒体源分别测 HTTP HLS、HTTPS HLS AES-128 密钥、MP4、DASH、FLV、RTMP/RTMPS，以及明确不支持容器/编码；跨域重定向和跨域密钥需验证凭据不会透传。记录真实首帧时间、缓冲、音轨/字幕轨和设备/SDK版本。
5. 用测试服务器逐一验证 Emby/Jellyfin 密码和 API Key、Xtream 账号、WebDAV Basic Auth、分页/剧集/播放 URL、停止后再启动与凭据脱敏。再测 M3U/TXT、catch-up 模板、TVBox 多分组、LL-HLS 签名查询和本机文件导入/删除。
6. 至少覆盖一台 iOS 17 真机和一台较新系统设备；重复打开/关闭播放器及切源，检查内存、残留后台请求、Now Playing、锁屏控制和屏幕常亮状态。iOS 15 只属于不含 JAR 的开发/UI smoke 目标，不作为完整 IPA 的支持承诺。

## 当前不包含的新增能力

新的 RTSP/UDP/SRT 内核、FairPlay/Widevine/PlayReady、DLNA/Cast 协议实现、下载、录制、截图、外置字幕文件管理、弹幕、iPad/tvOS 专属布局均不属于这三阶段。已有 AirPlay UI 入口不代表实现了 DLNA 或任意协议投屏。
