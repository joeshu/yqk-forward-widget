# 0.8.1：继续对照网络层与账号观测

参考 [utils/net.js](https://github.com/akiralereal/iptv/blob/e475b2f6d24029f844ada2b362d703c8b88c2e9b/utils/net.js)、[account.js](https://github.com/akiralereal/iptv/blob/e475b2f6d24029f844ada2b362d703c8b88c2e9b/extractors/migu/account.js)、[resolve.js](https://github.com/akiralereal/iptv/blob/e475b2f6d24029f844ada2b362d703c8b88c2e9b/extractors/migu/resolve.js)。没有执行参考仓库程序或读取其中的账号配置。

0.8.0 已对齐游客高清/现代请求的分支、版本与签名，并保留自己的安全和性能边界。此次继续检查外层网络封装：参考通过 node-fetch 发送请求。0.8.1 明确为咪咕 API 设置该库的默认 User-Agent 与 Accept，避免被本地通用 MiguLive 请求头覆盖。仍保留 identity 响应编码、系统代理与 TLS 信任、有界下载和总预算；这不是字节级 TLS/网络环境复现，也不能据此保证上游放行。

参考 account.js 说明，配了账号但上游未认可时可能仍获得游客档位。0.8.1 从正常解析响应收集有限的状态字段，不保存原始响应、不新增检查请求。只有本次确实发送的账号才能改变账号状态；标清游客请求不会误判账号失效。上游明确拒绝仍报错，不忽略地区或权益限制。成功缓存命中不重复观测、不请求上游；刷新后认可登录可更新状态。

实际取源状态记录见 `live-validation-0.8.1.json`：默认单文件从空目录运行、内置 123 个频道；CCTV1、CCTV2、CCTV13 都在 API 阶段返回 code 403、rid COPYRIGHT_AREA_INVALID、没有播放地址。没有进入媒体链路，也没有成功解码。此次没有自有账号，账号失效、恢复、标清不发送账号、脱敏和缓存行为通过合成响应验证，不能当作真实账号验收。

测试：113 项服务测试与 39 项目录/传输测试通过，单文件指纹检查通过。客户端是否在同一网络使用游客/账号模式实际成功，仍需设备侧证据；一个公开实现不能单独证明所有部署环境可播。
