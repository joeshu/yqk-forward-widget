# 官方iOS/直放路径复核与手机探针

本次检查未完成App UDRM原生替换。生产播放脚本仍为v0.3.7，不将检测工具当成新的播放器，也不把网页来源当作App来源。

**IPA与手册复核新增进展**：用户样本中已定位独立 iOS ARM64 CNPlayerSDK及其Cicada/xnet依赖，且核验用户附件与随包BV3.23.17集成手册逐字节一致。基础工程、VOD、视图、生命周期、回调与错误说明已取得；上轮漏查中文Markdown手册，“没有正式手册”的说法现予更正。完整头文件、LIVE/UDRM配置/授权合同与APTV接入仍未完成。见 [手册复核](IOS-SDK-MANUAL-REVIEW.md) 和 [IPA证据](IOS-SDK-IPA-REVIEW.md)。旧v0.1.0未匹配CNPlayer/Cicada；[v0.1.1](https://raw.githubusercontent.com/joeshu/yqk-forward-widget/main/cctv-app-udrm/diagnostics/cctv-ios-native-probe-v0.1.1.py)补充名称及注册类只读查询。

## 最新实测

官方iOS liveconfig共776项，其中191项drm=1、585项drm=0。当前项目53节目全部对应drm=1，未建立同节目明文高清直放路线。bcctv1/bcctv7虽然配置drm=0，接口实际返回play=0、status=4“该视频不存在”，不能据名称相似当作备用。

普通App来源请求不带App鉴权时，pdrm=0和pdrm=1均返回play=0，没有媒体地址；改参数不能证明可直放。未重放HAR鉴权。

正常官方网页接口对当前53个ID有45台play=1、8台play=0。全部响应都带hls_cdrm，拒播频道也带该字段，所以必须先检查play。未找到hls_nd/hls_url明文分支，也未因缺少EXT-X-KEY就断言视频ES未保护。本轮没有对这些45台新增媒体处理/解码验证。

已有独立的cctv-native网页服务使用官方JS/WASM而不模拟ARM；它是另一种来源，已有14台验证，不代表53台App UDRM原生化。本轮没有静默替换App服务。网页45台的接口许可结果仅为扩展该独立服务的候选。

## 原生SDK调查结果

APTV官方文档索引与公开仓库未提供原生插件或SDK桥接ABI；公告能确认Python脚本服务，不能据此推断第三方iOS SDK可注入。早期按kooplayer/libkooplayer搜索未得到iOS SDK交付与头文件。现已补充CNPlayerSDK二进制、随包基础手册及Cicada公开接口；未补齐的是版本匹配的头文件/协议/枚举、LIVE/UDRM配置和正式服务授权样例。

找到广科院/TrustDTA的SDK正式合作申请渠道及UDRM服务端评估目录，可作为后续供应商线索；这些页面未确认iOS支持、libkooplayer归属或当前央视服务兼容性，不能把同名UDRM产品直接装进本项目。

需要向提供方核验的具体材料：支持当前直播协议的iOS ARM64 SDK或官方UDRM WASM构建、正式服务端兼容与集成说明、输出类型（原生播放视图/受保护样本/编码媒体），以及APTV能够编译签名集成的桥接接口。没有这些材料，ctypes可用仍不能使Android ELF库变成iOS组件。

## 可立即运行的手机检测

下载独立脚本 [cctv-ios-native-probe-v0.1.1.py](https://raw.githubusercontent.com/joeshu/yqk-forward-widget/main/cctv-app-udrm/diagnostics/cctv-ios-native-probe-v0.1.1.py)，停止旧检测服务后在APTV运行新版。它不提供节目订阅；主播放服务可以保留。

结果地址：

```text
http://127.0.0.1:18771/status
```

启动日志也打印同一类JSON报告。把报告和APTV版本号用于下一步判定。默认仅监听本机，保持HTTP服务运行，避免托管环境把“打印后退出”显示为启动失败；电脑可用 --once 只打印。

探针使用公开dyld接口查看已经加载的匹配组件basename，检查已可见的Unicorn/JSC C接口是否存在，通过objc_lookUpClass只读查看已注册CNPlayer/Cicada类，并列出start(ctx)所传宿主对象里与native/sdk/plugin等相关的接口名称。不会调用播放器/许可方法或这些未知宿主接口，不打印值，不下载/加载样本SDK，不取媒体或许可，不读取HAR，不启动外部进程，也不输出完整App路径。

它能确认“此进程此刻观察到什么”，不能证明未加载的组件不在App里，也不能从组件名称或符号存在推导出授权、可桥接或可播放。界面框架不等于央视DRM SDK，加载候选SDK也仍需正式接口文档。探针相关12项本地检查通过，其中新版5项使用合成iOS调用对象；旧版另有真实本地HTTP检查。新版尚未在用户iPhone运行；旧版实机结果见下文。

用户已在 APTV TestFlight 9.9.9（548）的 iPhone 12（`iPhone13,2`）运行 v0.1.0 探针。该进程观察到 Apple 视频框架和 JavaScriptCore，没有观察到旧名称过滤器匹配的组件/Unicorn API；该版未检查 CNPlayer/Cicada 名称或注册类。`start(ctx)` 未收到宿主对象仅说明此次调用，不排除其他宿主模块、全局或静态接口。APTV 官方通知对 9.9.9（540）的公开发布说明新增 Python/PHP 脚本服务，但未列出原生插件 ABI；548 是用户截图确认的构建。实际播放日志显示 SDK 处理调用每处理约4秒视频需要约4–10.5秒，排队和映射耗时很小，出现间歇卡顿符合该吞吐量。现有计时没有再拆分 JSC/WASM 桥接与模拟器内部耗时。探针和播放日志的详析见[实机卡顿报告](IOS-PLAYBACK-STUTTER-2026-10-22.md)。当前尚无受支持的央视SDK分发/接口合同或APTV插件ABI，原生替换仍未解决。来源：[APTV 官方 TestFlight 通知](https://t.me/s/aptvplayerchannel)。

## 本轮核对的公开来源

- 官方iOS配置：https://api.live.cntv.cn/liveconfig/bcsioslivecbox_000.json
- APTV官网：https://www.aptv.app/
- APTV文档索引：https://docs.aptvapp.com/llms.txt
- APTV公开仓库：https://github.com/Kimentanm/aptv
- 官方脚本服务公告：https://t.me/AptvPlayerChannel/614
- 官方TF发布范围说明：https://t.me/AptvPlayerChannel/617
- 广科院SDK合作说明：https://developer.trustdta.com/article/detail?id=125
- UDRM服务端评估目录：https://developer.trustdta.com/article/detail?id=136

数据与探针摘要见 [OFFICIAL-IOS-PATH-CHECK.json](OFFICIAL-IOS-PATH-CHECK.json)。
