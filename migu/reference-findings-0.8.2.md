# 0.8.2：用参考 JavaScript 生成对照基准

参考版本：`akiralereal/iptv@e475b2f6d24029f844ada2b362d703c8b88c2e9b`。

本轮没有继续猜客户端参数。对已审阅且哈希固定的 `androidURL.js`、`ddCalcuURL.js`，提取协议函数，在 Node VM 中以固定时间、随机数和模拟 fetch 响应执行。没有启用参考服务器、登录模块、网络或真实账号。默认 Node 运行环境与 Python 的 TLS/网络行为未作等同假设。

比较游客高清、账号高清、账号降到游客标清、游客标清、体育频道共 5 个场景。基线 0.8.1 的 API URL 和模块请求头 5/5 匹配，最终播放地址只有 4/5 匹配。差异来自参考 getAndroidURL：在替换成服务器实际 rateType 之前，用原请求 rateType 调用 getddCalcuURL。Python 却提前使用了返回 rateType。在账号请求高清而服务器只返回标清时，两者会选到不同的第一个插入字符。

0.8.2 按参考的请求模式计算校验，实际返回画质继续只用于观测。修复后请求、模块请求头和最终播放地址均 5/5 匹配。此结论限定于这些合成场景，不证明真实账号或媒体解码成功。

对照记录见 `reference-comparison-0.8.2.json`，基准在 `tests/migu_live/reference_cases.json`。基准保存合成输入与哈希，没有真实播放签名、地址或账号；可通过 `capture_reference.cjs` 从哈希匹配的本地参考仓库重建。Node 仅是开发验证工具，不是单文件运行依赖。

另外，[get302URL](https://github.com/akiralereal/iptv/blob/e475b2f6d24029f844ada2b362d703c8b88c2e9b/extractors/migu/androidURL.js#L302) 明确排除以 http://bofang 开头的跳转，并将其视为本次获取节点失败。因此之前不能把该跳转直接描述成正常媒体链路已通。这里并未据此断言目标页面具体内容，也未添加此域名为可信媒体。

参考项目本身也有 [取源失败问题记录 #171](https://github.com/akiralereal/iptv/issues/171)，作者区分了无法连接与收到地区拒绝。这些记录不能证明用户手机的原因，更不能据此保证任何部署可播。

本版最终单文件实测 CCTV2：内置目录成功，本地播放入口在 API 地区拒绝后返回 403，无媒体 URL，没有进入解码阶段，记录见 `live-validation-0.8.2.json`。114 项服务测试、39 项目录/传输测试通过，单文件指纹匹配。真实账号降档场景没有自有凭据可验，结果仍限于独立参考函数基准。
