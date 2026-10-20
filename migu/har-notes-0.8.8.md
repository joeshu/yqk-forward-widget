# 咪咕直播 0.8.8 改进版

基于用户指定的 `joeshu/yqk-forward-widget/main/migu/migu-live-v0.8.7.py`，结合 2026-10-20 提供的 6 份 HAR 修改。Python 3.10+，仅使用标准库。

## 修改内容

1. **修复直播 CDN 8088 端口被拒绝**：抓包中的 `mgsp-cty2.live.miguvideo.com:8088` 和 `mgsp-ws2.live.miguvideo.com:8088` 原先无法通过 URL 校验；现在 stream/media 两种角色均支持该端口。域名边界检查与其他端口限制继续生效。
2. **修复降清晰度的请求与签名不一致**：每次请求分别记录清晰度和是否发送账号；`ddCalcu` 使用最终一次请求的配置，而非最初的高画质配置。标清请求和签名都使用匿名身份。
3. **完善降级流程**：仅在 `TIPS_NEED_MEMBER` 时向更低清晰度尝试，最多 3 次降级，可降至标清；旧版协议实际固定请求 720P，不再重复发送伪装成降级的相同请求。地域、版权、登录失败不会触发降级。
4. **改进诊断与错误识别**：诊断分别给出初始请求画质和最终请求画质，补充 `NEED_LOGIN` / `USER_NOT_LOGIN` 错误映射。
5. **补齐 native 返回地址检查**：拒绝空的或重复的 `ddCalcu`，检查 URL 中的 `ProgramID` 是否匹配请求频道。

## 六份附件说明

| 附件时间 | 类型 | 分析结果 |
| --- | --- | --- |
| 19:07:02 | CCTV5 HLS | 8088 端口，H.265，3 个 6 秒分片 |
| 21:50:15 | CCTV2 HLS | 8088 端口，H.265，4 个 6 秒分片 |
| 21:56:17 | CCTV4 节目单 | 42 条节目；原解析器已支持，已回放验证 XMLTV 输出 |
| 22:42:17 | play-pre POST | 短视频点播，`videoType=vod`，不是直播取址 |
| 21:55:26 | play-pre POST | 短视频点播，`videoType=vod`，不是直播取址 |
| 21:52:48 | 播放历史 POST | 账号播放记录，不是播放地址接口 |

两份 HLS 的每个分片均带独立 `encrypt`。改写时保留每条分片自身的查询串，不复制主播放列表的参数覆盖分片参数。原脚本已有正确的相对地址转绝对地址逻辑，本次新增抓包回归覆盖，没有重写这部分。

这些附件不能证明 Android 直播签名应切换到 iOS 协议，也不足以推出 iOS 的动态 sign、设备证明或分片 encrypt 算法。因此保留原有 Android/native 协议，没有硬编码抓包中的过期播放地址和 iOS 请求头。节目单中的节目 contId 与直播频道 pID 也不能简单互换。

## 使用

原部署可直接将单文件脚本替换为 `migu/migu-live-v0.8.8.py` 或根目录 `migu-live.py`，继续使用原参数。首次使用可运行：

```bash
python3 migu-live-v0.8.8.py 28768 --mode manifest
```

播放器订阅地址：`http://127.0.0.1:28768/all.m3u`。
节目单：`http://127.0.0.1:28768/epg.xml`。
诊断：`http://127.0.0.1:28768/diag`。

`manifest` 模式会读取上游播放列表并把相对分片地址转成绝对地址；分片仍由播放器直接请求 CDN，并非完整媒体代理。默认不传 `--mode` 时仍为原来的 redirect 模式。

账号使用自己的 `MIGU_USER_ID` 和 `MIGU_USER_TOKEN` 环境变量，也可以填写脚本顶部的配置。不要把 iOS appVersion、appCode 直接填进 Android 配置，不能据此获得相应的 iOS 协议实现。可选 `MIGU_RATE_TYPE=2/3/4/7/8/9`；实际画质及可用性由服务端权益决定。局域网绑定方式仍沿用原脚本的 `--bind`、`--public-base` 与访问令牌配置。

## 验证与限制

```bash
python3 -m unittest discover -s tests/migu_live -p test_har_regressions.py -v
# 带原始附件验证全部 9 项（附件不在交付包中）：
MIGU_HAR_DIR=/path/to/har-directory python3 -m unittest discover -s tests/migu_live -p test_har_regressions.py -v
```

已通过 9 项离线回归测试，覆盖两份真实 HLS 的解析与改写、42 条节目单、CDN 域名端口边界、完整地址保留、降级请求账号和签名一致性、登录错误、频道匹配和 native proof 检查。脚本命令行帮助可正常运行。

没有使用 HAR 中的账号凭证发起网络请求；没有进行在线取址或播放器实播。因此不能保证原有 Android/native 签名在当前服务器仍然有效，不能据此宣称解决了全部播放或鉴权问题。若仍遇到取址失败，下一步需要对应直播频道的 playurl 请求及响应（目前提供的两份 playurl 都是点播），而不是仅最终 CDN 地址。

本次提交不含原始 HAR、用户 token、Cookie、设备标识或抓包播放地址。
