# 从原央视影音 IPA 核实自选地址播放

2026-10-24。本文先记录原 App 的静态调用证据和宿主原有缺口，随后按用户确认将 CCTV 手选线路接入同一 CNPlayer URL 起播入口。它不是原生播放验收；未修改订阅、用户配置或 SDK 二进制。

## 结论

自选地址和脱离 SDK 是两件事。样本中的三个直播 URL 前端最终都调用 **CNPlayer 的 URL 起播实例方法**；没有从这三个前端找到已验证的普通 AVPlayer 或独立 Cicada 播放央视受保护源的路径。不能把 App 存在 URL 方法解释成其直播源能作为普通 HLS 直接播放。

调查时的宿主静态 WS/BD/KS/TX 选项只修改 SDK CDN 默认偏好，仍按 channel ID 起播。即使偏好回读一致，也没有把所选 URL 交给 URL 起播接口。这个历史问题已由下方“当前接入”说明的调用路径取代；CDN 配置回读本身仍不能证明实际使用了某地址。

**建议接入方向是“自选地址 + CNPlayer SDK”。** 这样仍通过 SDK 的播放入口，宿主没有主动关闭或改写授权配置；但样本没有提供一份经确认可用于所有静态来源的授权配置，具体许可、频道访问和解码结果仍需设备验证。若要求完全脱离 CNPlayer，现有材料尚未提供完整、可验证的独立 UDRM 集成合同，不能承诺普通 AVPlayer/通用 Cicada 可以正常播放这些源。

## 样本与仓库核对

通过 GitHub main 的递归文件树核对，未截断的文件列表只包含一个 IPA：

- [原 IPA](https://github.com/joeshu/yqk-forward-widget/blob/main/cctv-app-udrm/cn.vuclip.mobiletv-7.9.31-eeveedecrypter.ipa)
- Git blob：`0b85700ff9fa586cc558c262368afef8d16728b2`，74,093,434 字节。
- SHA-256：`e7b153ab80a17a646d7011ebedc17b786835ab27feba4959af07bcc7ec8c9315`。
- Info.plist：`cn.vuclip.mobiletv`、7.9.31/build 1。
- 样本 CNPlayerSDK 与当前宿主二进制逐字节摘要相同：`e8556692053692ef89b264105931f4eed979132d1d275fa937a1d41c3fe4a9fe`。

这说明当前项目已经带有样本中的这个播放器库，重新复制同一库不会自动补齐线路调用。样本经过修改，其原始分发签名真实性未独立认证。

同时核对了此前的 `joeshu/iptv`、`ios151/One-releases` 文件树，两者主分支均无 IPA 文件。对附件 One-unsigned.ipa 另做包结构和标识字符串检查：One 1.5.0/build 8、`com.ios151.one`、1,301,282 字节、SHA-256 `b9dd91d0f4d55506d309f5f2d3377d7ab042038241d9707a218b7830206e4bed`，无嵌入 framework；主程序存在 AVPlayer 标识，未找到 CNPlayer/Cicada 及本次选定的央视 UDRM 标识。这不是对其所有功能的完整证明，但未提供可以复用的央视受保护源播放证据。不能将通用影视/直播播放器支持 M3U 宣传成支持这批央视线路。

One 的 IPA 实际放在 Releases。继续检查了当前最新 [v1.6.2-11](https://github.com/ios151/One-releases/releases/tag/v1.6.2-11) 的 1,517,270 字节安装包，同样无嵌入 framework，所选央视标识仍未出现；只读检查摘要见 [ONE-RELEASE-PLAYBACK-MARKERS.json](ONE-RELEASE-PLAYBACK-MARKERS.json)。没有运行它，也未把标识搜索结果扩大为完整功能审计结论。

## 实际调用证据

只读解析主程序的 Objective-C 方法元数据和 arm64 前端调用，三个前端均调用 `-[CNPlayer playLIVEWithUrl:delegate:configOptions:]`：

| App 前端 | 前端地址 | 调用地址 |
| --- | --- | --- |
| CNPlayerSimpleLiveView | `0x100300e4c` | `0x100300f80` |
| CNPlayerLiveView | `0x100e34138` | `0x100e34250` |
| CNPlayerPortraitLiveView | `0x1005645e4` | `0x100564708` |

以上地址属于本报告固定摘要的未加载文件，不是运行时地址。对应 SDK 实例方法地址为 `0x80c4c`，运行时类型为 `B40@0:8@16@24@32`：返回 BOOL，接收三个对象参数。不能误用同名类方法，也不能将返回 YES 当成解码成功。

URL 前端把调用方传入的 URL、delegate、configOptions 继续交给 CNPlayer；本身并没有提供一份可复制的完整受保护直播配置样例。SDK 的 URL 分支会创建直播内核、设置 URL、应用 options，并由 SDK 配置底层播放处理。因此，**“旧代码只传标题”是可确认的实现差异，但不能据此认定少一个 DrmConfig 参数就是唯一故障原因。** 本次没有猜测一个 DRM 开关、抄取 App 凭据或拼出一个声称已可播的参数包。

SDK 存在 `CNPlayerConfigOptionKey_DrmConfig`，策略配置入口会读取它；CNPlayerPlayOptions 也存在对象型的 `drmLive`。这些仅证明配置入口存在，不证明它们的完整取值合同、适用频道、服务授权或某个静态地址的可播放性。随包基础手册未给出相应完整 LIVE 配置样例。

机器可复核证据：[CCTV-IPA-LIVE-ROUTES-AUDIT.json](CCTV-IPA-LIVE-ROUTES-AUDIT.json)。新增审计脚本只检查上述前端，不检查密钥或解密算法，不加载/执行 IPA，也不发送许可请求。

## 与宿主历史版本的差别

| 版本/提交 | 实际行为 | 尚缺的证明 |
| --- | --- | --- |
| 0.3 / `0b99af8` | 创建独立 Cicada，尝试设置底层配置并直接 prepare/start | 没有建立完整 Cicada 回调闭环，不能用现有 CNPlayer 首帧回调证明它出画；私有配置猜测不构成受支持的集成 |
| 0.6 / `15bbc38` | 调用 CNPlayer URL 实例方法，options 只有标题；约 7 秒未观察首帧就改回按 ID 自动播放 | 没有对应版本真机成功证据；固定 7 秒回退可能提前打断尚在准备的线路。附件中其他版本的 SDK 首帧曾超过 7 秒，但不能据此推定 0.6 的准确耗时 |
| 0.7 / `8e3db1f` 至当前 | 删除 URL 起播入口，改成 CDN 偏好，再按 channel ID 起播 | 配置回读不等于所选 URL 被使用；也不等于该节点已解码 |

旧 URL 分支还会在失败后静默回到自动，菜单名称可能继续显示自选提供商。这会掩盖“所选线路失败、实际正在播放自动线路”的区别。当前未重新引入这个回退行为。

## 普通解码的有限抽查

Linux 开发环境、系统 ffprobe/ffmpeg。每组读取一份主清单、第一条变体清单及其中连续三个完整 TS，使用普通 HTTPS GET；不添加账号、Cookie、签名或密钥，不转换受保护媒体。临时分片在检查结束后删除。选取清单第一条变体只是诊断采样，没有修改 App 清晰度配置。

| 样本 | HTTP 结果 | 连续片数/总字节 | ffprobe 识别 | 普通视频解码 |
| --- | --- | --- | --- | --- |
| CCTV-1 / WS | 主、子清单及三片均 200 | 3 / 1,025,728 | H.264 640×360 + AAC | 报告 146 帧，同时 742 行错误日志 |
| 广东卫视 / TX | 主、子清单及三片均 200 | 3 / 2,517,884 | H.264 1280×720 + AAC | 报告 9 帧，同时 1,105 行错误日志 |

错误包括 `Invalid data found when processing input`、`error while decoding MB`、`decode_slice_header error`。两次 ffmpeg **进程都返回 0**，所以不能只检查退出码，也不能把有部分输出帧算作正常完整播放。这里记录的是 ffmpeg stderr 日志行数，包含其探测与解码阶段可能产生的重复报告，不是损坏帧数。

两个样本均没有在所读变体中声明标准 EXT-X-KEY；缺少这个标签也不能证明明文可播。随包频道配置中 cctv1/cctv7/cctv13 的 drm 标记为 1。普通解码错误与这一受保护链路背景一致，但错误本身不能唯一确定加密机制，也不能排除其他媒体或传输问题。不能把这两组结果外推到所有线路。

解码检查实际调用形式为：

```sh
ffprobe -v error -show_entries stream=codec_type,codec_name,width,height -of json sample.ts
ffmpeg -hide_banner -v error -err_detect explode -threads 1 -i sample.ts -map 0:v:0 -an -f null - -progress pipe:1 -nostats
```

不含媒体/签名 URL 的原始结果摘要：[CCTV-PLAIN-ROUTE-SAMPLES.json](CCTV-PLAIN-ROUTE-SAMPLES.json)。这些结果不是 iOS AVPlayer 测试、原 SDK 播放结果或手机性能基线。

## 本次代码改动与剩余验收

- 自动播放仍调用 CNPlayer 的 channel ID 接口；手动选择 WS/BD/KS/TX 会把原始完整 URL 交给 CNPlayer 的 URL 接口。CDN 偏好 setter 不再代表选线播放。
- URL 起播先核对 SDK 方法 ABI；options 只带标题、SDK 当前 userID（可取得时）和 SDK 定义的 URL 来源频道统计 ID，不主动关闭或改写授权配置，不写入硬编码凭据。保留原 URL 查询串用于实际起播和播放信息展示；宿主日志只记录来源主机。URL 接口对具体静态地址的授权行为尚未真机确认。
- 所选 URL 在重试及“缺少内核恢复”时保持不变。SDK 返回拒绝、回调失败或超时时展示失败；不会暗中改走自动线路。自动回退需由用户点选。
- 由于没有 Xcode 或授权测试环境，本次只能核对 SDK ABI 并实现调用路径；没有验证实时 URL 播放是否成功、该 SDK 版本是否对每一条静态地址完成相同的许可/版权流程，也没有真机首帧和持续解码数据。

上设备至少要按 CCTV-1 WS/BD/KS、CCTV-7 WS/BD/KS、一个 TX 卫视线路逐条记录：SDK 是否接受、版权/许可回调、首帧、SDK 报告节点、连续播放 60 秒、快速切台和前后台恢复。失败应保留实际错误，并由用户明确选择重试该线路或切回自动；不同频道没有的 CDN 地址不显示为可用线路。

本轮已把自选地址入口接入项目的 CNPlayer 调用路径，作为待设备验收的实现，不据此宣称已通过央视许可或真机播放。

## 本地复核

从 `cctv-ios-host/` 运行：

```sh
python3 Scripts/audit_ipa_live_routes.py
python3 -m unittest discover -s Tests -p 'test_ipa_live_routes.py' -v
```

脚本使用仓库现有 ObjC 索引器，不依赖 capstone、不安装或执行 IPA。测试覆盖地址解码、无效输入边界、样本身份、宿主 SDK 一致性及三个前端的真实调用目标。静态测试通过不等于原生播放通过。

较早的静态诊断轮次记录过 149 项 Python 测试（124 通过、25 跳过），该结果早于当前 URL 接入，不作为本轮改动的测试结果。本轮未运行测试或 iOS 构建；当前环境没有 `xcodebuild`/`xcrun`。性能基线、首帧速度和持续播放验收均为“未测”。
