# CCTVHost 0.16.1 起播与切台修复

## 对照基准及证据

用户确认 0.13 或 0.14 以后变慢，因此对照 0.11（9c20d96）、0.12（94007e8）、
0.13（74db487）与 0.16.0（b3d0aca）。SDK 三件套没有更换：CNPlayerSDK 二进制
自最初导入提交 1d35242 起未改动。

0.12 的核心是 `stop → reset retained CNPlayer → playLIVEWithChannelID → prepareToPlay`，
传入 Title、开启 autoPlay。0.12 到 0.13 没有更换此 API；新增的是画中画、EPG 磁盘缓存、
跨源回退、收藏等。因此不能仅凭版本时间点断言某一 API 就是所有慢开台的根因。

用户日志中近期原生首帧为 7.36s、6.04s、14.77s，慢例大部分时间在 VDN 完成前。
订阅记录的 2.69–3.81s 是 AVPlayerItem ready，不能与视频首帧等同。
另有明确的本机服务未启动就续播，以及 v0.16 服务入口更改了数据目录的情况。

## 修改

1. 默认启用 **0.12 原生播放兼容模式**，恢复 retained wrapper 的 stop/reset 起播顺序。
   设置中关闭此项后，下次选台使用独立 wrapper，以便在相同设备/网络上对比。
   两种模式都保留 Title、官方调度和 SDK 自身鉴权，不硬编码过期播放地址或替换 DRM。
2. SDK 已自动渲染后，PrepareDone 不再额外调用一次 play；手动 CDN 偏好切回自动时
   恢复启动时的 SDK 默认对象，并校验返回值，不能确认时明确记日志。
3. 切台停止并释放旧 PiP、AVPlayerItem 和 layer，取消旧 asset 加载、seek 和条目通知。
   不再只 pause 后留下旧 item 被 PiP 或延时块间接持有。
4. 选台取消列表 EPG 请求；原生起播期间不再发起新的列表预取。
   EPG 磁盘保存合并为 2 秒批次，序列化和写盘移到串行后台队列。
5. 本机订阅未启动时暂缓读取，不再在 App 打开时先报连接失败。
   恢复内置订阅时先启动对应内置服务，再以 HTTP /health 的 200 + JSON ok=true
   确认服务可用，才创建 AVPlayer；轮询最多等待 20 秒。
   engine.ready 不作为阻塞条件，因为内置服务的备用流可先播放。
6. 手动和自动服务入口统一使用 ServiceStore。内置服务回到历史 ysp 数据目录；
   v0.16 新目录中存在而历史目录缺失的文件复制过去，不覆盖已有身份/缓存文件。
   自定义服务不会因自动续播而自动执行代码，需用户先在服务页启动。
7. 服务健康等待、旧播放清理、配置、prepare 调用、VDN、Setup、PrepareDone、
   itemReady 与视频 frame 分开以单调时钟计时，附当前频道及代际。
   AVPlayerLayer.readyForDisplay 才认定订阅视频首帧，不把 itemReady 伪报为首帧。
8. 等待期间明确区分“VDN 未完成”和“等待视频数据”，不在调度尚在进行时盲目重启。
   停止后的 CPython 仍不能在同一进程安全重启，明确提示重新打开 App。

## 验证

- 既有回归检查；macOS 原生测试覆盖 readiness 的 503、ok=false、最终成功、
  截止时间、取消后不能完成，以及 itemReady/frame 分开记录。
- 模拟器 UI 测试继续检查页面；新增 SDK 测试替身验证 0.12 模式复用、独立模式切换、
  旧实例事件拒绝、已自动首帧后不会多 play。
- 模拟器使用真实 loopback HTTP 与小视频，验证服务启动只调用一次、健康检查前
  不创建 AVPlayer、真实 AVPlayerItem 就绪、AVPlayerLayer 出帧及切回原生时旧 item 被移除。
  Python 进程状态和官方 SDK 是测试替身，不会进入设备 IPA。
- 真机 IPA 经过语法、arm64 编译及包结构校验。

尚未进行新版本真机播放测速。以上修复处理可复现的生命周期问题，不承诺所有网络下
VDN 调度都恢复到某个固定秒数；日志需在相同设备/网络上与 0.12 做实测对比。
