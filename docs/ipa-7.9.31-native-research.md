# 央视影音 7.9.31 IPA 研究与 CCTVHost 0.17.4

用户指定样本：`cctv-app-udrm/cn.vuclip.mobiletv-7.9.31-eeveedecrypter.ipa`，74,093,434 字节，SHA256 `e7b153ab80a17a646d7011ebedc17b786835ab27feba4959af07bcc7ec8c9315`。主程序声明 7.9.31、最低 iOS 15，主 Mach-O 的 cryptid=0。

本次检查包结构、前端 Objective-C 接口、配套框架依赖和时移调用 ABI；不执行原 App，不修改授权、许可或媒体加密流程。没有向业务服务器注册新设备。

## 实际发现

1. 包内 CNPlayerSDK、CicadaPlayerSDK、alivcffmpeg 与本项目现用三个二进制逐字节一致。原生播放器版本相同，不能把替换同一份 SDK 当作提速改动。
2. App 的 CNPlayerView、CNPlayerSimpleLiveView、CNPlayerPortraitLiveView、CNPlayerLiveView 均有 `seekToStartTime:endTime:completionHandler:` 和 `backToLive` 前端。SDK 参数编码为两个 double 时间值和一个 block。进一步确认 SDK 默认完成 block 的签名为 `v12@?0B8`（一个 BOOL），不是凭名称猜测 NSError 回调。
3. SDK 内部 endTime==0 进入时移，endTime 非零进入有结束时间的回看。版权、可用地址和服务支持范围仍由原 SDK 检查。
4. 主程序的 `registerDeviceWithRetryTimes:`、`registerDeviceInternal:` 实际属于 **EBAppLogRegisterEngine**（统计组件）；不能把这些名字当成 ytpcloudws 注册。主程序及本次可见包内容没有找到 ytpcloudws/JCE 对应宿主接口的直接证据，不能据此实现另一个未知 SDK 协议。
5. 包中另有 xnet.framework。CNPlayerSDK 对它使用 **LC_LOAD_WEAK_DYLIB**，解释了当前宿主没有嵌入 xnet 仍可原生播放。xnet 内存在 HlsServer、TS 处理、xdfs/cache 及 `xnet/live/hls/max_ts_buffer` 等实现/配置线索。
6. xnet 的存在不等于当前直播实际启用该缓存。尚缺匹配版本的初始化、SDK 选路、配置生效、命中统计及上传行为合同。本次没有盲目嵌入或激活它。它也不等同于 CicadaCacheConfig；此前上游 Cicada 直接 URL HLS 的缓存限制不能用于断言 xnet 没有分片缓存。
7. App 里名为 TimeShiftHelper 的类还有 domain/appId/bizId 和腾讯直播 URL 格式，不能把所有名为 timeshift 的代码都认作 JCE。

接口摘要见 [JSON 证据](ipa-7.9.31-interface-evidence.json)。`tools/ipa/objc-method-index.py` 是本样本使用的离线 Mach-O 元数据索引工具；只读本地解包后的可执行文件，输出类/方法/编码。支持本样本遇到的常规及相对方法表、offset chained 指针，不声明是任意 Mach-O 的通用解析器。

## 已落地到 0.17.4

- CCTV 原生播放器“更多”中增加时移/回看、回退 1/5/30 分钟、返回直播。
- 原生频道节目单中，已播节目显示“点按回看”；未来节目不触发回看。须先播放对应原生频道；订阅 AVPlayer 不使用这个接口。
- 调用现有 SDK 实例的原生时移接口，不重新 playLIVE、不切到 Python 代理或其他来源。
- 专用 NativeTimeshiftSession 验证 double/block ABI、Unix 秒范围、取消代次和单次回调；保留 SDK 版权允许/拒绝结果，不承诺任意频道支持固定七天回看。
- 操作首帧与正常频道首帧分别记录，避免混入开台/切台统计。时移过程中不继续预解析相邻频道。
- 失败时显示操作失败，保留“返回直播/重新选台”路径；不把接口调用成功伪记为已经出画面。

## 验证及边界

Foundation 执行测试：double 传参、end=0/非零分支、未来/非法时间拒绝、版权拒绝传播、重复/取消回调、返回直播和错误 ABI。
模拟器 SDK 桩：时移与返回直播产生新首帧、保持同一 SDK 实例、不再次配置频道；节目单已播/未来节目行为。真实 SDK 的服务端版权、时移范围、首帧耗时仍需真机验证。

设备注册（ytpcloudws）、JCE 时移协议、xnet TS 缓存开关本次未标记为已实现；现有内置 Python 中的实现也未冒充新增原生能力。后续 xnet 研究应先取得并核实配置/缓存命中接口，再用同频道同画质验证，不能仅凭新增库或缓存目录宣称速度改善。
