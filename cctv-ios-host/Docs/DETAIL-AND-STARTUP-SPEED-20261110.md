# 详情、选集与 HLS 起播速度改进

基于 `12e2a1dc6b3afdb4a5b83ad7ee1def5170e1c61b` 及同一工作区已完成的播放器/附件适配改动。

## 详情页

- `MediaMetadataCache` 现在接收详情数据。仅相同资源身份、配置、请求头、provider 与影片 ID 的结果会互相命中；详情在内存中保鲜 60 秒，最长展示陈旧结果 5 分钟并于后台刷新。新鲜命中会直接展示并跳过请求；“重新加载详情”仍强制请求来源。
- 播放地址、带签名/授权的 URL、Cookie/请求头、DRM 资料和本机代理地址不进入详情缓存；缓存不把详情写入磁盘。来源切换或敏感详情替换会清除对应缓存项。
- 收到详情后，线路与分集清理、敏感地址检查、序列化计费都转到专用工作队列；主线程只更新视图。新增 `prepare_ms` 诊断字段以便设备日志区分网络与页面准备时间。
- JAR API 回来的目录/详情也在 worker queue 做规范化；同一个 `MediaAPIClient` 的不同 `NSURLSession` 可能各自有相同的 task ID，请求上下文现按 task 对象身份保存，迟到的取消/完成回调不会取走新请求的数据。

首次打开一个此前未加载的影片仍需等待该来源返回数据。Python Spider 共用一个解释器和 GIL，来源内部可能串行网络请求；这些来源响应时间不能由详情缓存或界面改造消除。

## 选集与首帧

- 对 AVPlayer 可播放的下一集，按播放来源、选集、URL 与请求头创建短期 AVURLAsset metadata 预热，并允许安全的本机 HLS relay 地址参与。只加载 `playable` 元数据，不发盲目 Range 请求，也不下载整段媒体；Cicada、DRM 自定义密钥和资源紧张时不做这项预热。
- 用户切到预解析正进行中的同一分集时，当前播放接管这次请求及其结果，不取消后再发一份相同解析。来源、provider、parser 或选集不同则不提升旧请求。缓存资产复用前验证 URL、来源身份、请求头和 120 秒时限。
- 启播缓冲策略维持原有自适应值，没有将预缓冲调到零。缩短缓冲而不测源波动可能让首播看似快一些，却增加停顿；本次没有测量设备温度、电量或真实上游抖动。

## HLS 分片代理

- 同一 token、URL、请求头和本机服务端口的 HLS 清单 GET 只合并尚在进行中的读取与改写；读取结束立即删记录，因此直播的下一次 reload 获取新序号，不会命中过期 playlist。HEAD、媒体 Range、不同 token/请求头或服务实例不共享。并发 flight 上限为 4，关闭时会唤醒等待请求。
- fMP4 首部判断每次小块读取后立即更新。若 `ftyp` / `moof` 标志跨越多个 TCP read，识别出完整标志就开始向播放器发送，不再等到额外 16 KiB 或上游结束。206 Range 原字节与 Content-Range 仍完整保留。
- 基准脚本：`python3 cctv-ios-host/Scripts/benchmark_hls_bootstrap.py`。Linux loopback fixture 中，4 个同时 GET 同一清单、每次上游读取固定延迟 150 ms，3 次测试的中位等待从 609.5 ms 降到 154.6 ms，上游 GET 从 4 次降为 1 次。夹具用串行上游模拟排队；它是并发去重的可复现证据，不是实际 HLS 首帧或 CDN 吞吐数据。
- 回归还验证清单序号在下一次请求继续前进、错误共同交付且可重试、token 隔离、flight 上限、HEAD 与 GET 分离、Range 内容不变、首部够识别时上游尾部尚未释放播放器已收到数据。

## 验证边界与后续测量

最终 Python 回归共 858 项，794 项通过、64 项按平台/运行条件跳过；`git diff --check` 与全源语法/清单审计通过。Linux 可验证的 HTTP 行为、元数据缓存合同和基准命令在交付验证记录中。此环境没有 Xcode / Apple SDK / iPhone，因此没有运行 iOS 原生 cache/seek probe、UI smoke 或真机连续切集。首帧延迟还受 DNS/TLS、站点排队、首片大小与编码、AVPlayer/Cicada 解码影响；没有对这些真实链路声称提速百分比。

要量化实际开片速度，请在目标设备启用运行诊断模式，对同一来源、同一影片和同一网络分别记录 `media_detail_request_started` → `media_detail_readable` 的 `elapsed_ms` / `prepare_ms`，以及 `episode_player_handoff` → `media_first_frame_ready` 的间隔；另记录 HLS 首个 manifest/key/init/media 分片的到达时间和请求数。至少比较同设备多次冷开片与缓存详情重进，并保持线路/清晰度一致。若单个分片本身慢，再按代理日志的上游首字节耗时继续定位连接建立、分片服务器与媒体时长；不要用改 playlist 时长或跳过 Range 字节来换表面速度。
