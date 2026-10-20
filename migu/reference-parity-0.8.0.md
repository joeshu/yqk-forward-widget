# 公开参考实现对照：0.8.0

研究基线为 `akiralereal/iptv` 提交 `e475b2f6d24029f844ada2b362d703c8b88c2e9b`。主要文件：[resolve.js](https://github.com/akiralereal/iptv/blob/e475b2f6d24029f844ada2b362d703c8b88c2e9b/extractors/migu/resolve.js)、[androidURL.js](https://github.com/akiralereal/iptv/blob/e475b2f6d24029f844ada2b362d703c8b88c2e9b/extractors/migu/androidURL.js)、[ddCalcuURL.js](https://github.com/akiralereal/iptv/blob/e475b2f6d24029f844ada2b362d703c8b88c2e9b/extractors/migu/ddCalcuURL.js)。参考项目标注 GPL-3.0-only。未运行克隆下来的程序、登录流程或依赖安装脚本；本地 Python 保持标准库单文件。

## 确认并修复的差异

| 项目 | 0.7.1 | 0.8.0 |
| --- | --- | --- |
| 游客高清路由 | rateType=2 才走旧版 | 无账号且 rateType≥3 走 2600034600 旧版，与 resolve.js 对齐 |
| 现代版本 | 请求头和签名均为 26000370 | 请求头 2600037000，签名输入 26000370，与 androidURL.js 对齐 |
| 改成 2600000900 | 仍混用现代签名常量 | Android 模式拒绝混用，保留单独 native 实验路径 |
| 完整地址 | 重复追加 ddCalcu | 已有唯一非空 ddCalcu 则原文保留 |
| 返回频道 | 未核对 | 内容 contId 与 URL ProgramID 必须匹配请求 |
| 奇数种子 | 中间字符重复 | 中间字符只出现一次；这是修正，不是逐字照搬参考边界行为 |
| 日期来源 | 播放时本机日期 | 优先使用已签发 URL 时间戳 |
| 降档 | 可重复请求同档，每次重新算预算 | 只降档、不重复，共享 12 秒总预算 |
| 成功缓存 | 3 小时 | 5 分钟，仍不推断真实签名寿命 |
| 默认提供方 | list | android，按用户要求不读取外部列表 |

账号失效时参考实现可能仍取得游客降档地址，因此不能单凭账号认证结果推断无地址。但这不意味着所有拒绝响应都能使用：Android 模式必须为 SUCCESS；native 模式也拒绝明确及未知非成功 rid，只有 SUCCESS 的游客地址才容许账号认证未通过。地址存在仍不证明实际解码成功。

没有引入参考项目的自动账号登录/刷新、设备注册、投屏专用 4K 额外请求或服务端选择 CDN。保留系统代理和 TLS 校验，未轮换出口、伪造地区字段、取消授权检查或放宽到未知跳转域名。

## 运行验证

最终单文件从空目录启动，`/all.m3u` 本地生成内置频道，不读取外部列表。抽样 CCTV1、CCTV2、CCTV13，当前网络都在取源接口收到地区拒绝，没有可供验证的媒体 URL，故没有首帧解码成功。记录见 `live-validation-0.8.0.json`。该结果不代表 iPhone 环境的结果，也不能宣称参考项目必定解决上游地区、终端或账号限制。

上一版文档将未知 `bofang` 第二跳归因于沙箱 DNS，并称链路已通，缺少媒体响应证据；本版移除该结论。不能仅靠 302 判断目标是媒体 CDN、错误页还是其他调度服务。未知域名不会自动加入媒体白名单。
