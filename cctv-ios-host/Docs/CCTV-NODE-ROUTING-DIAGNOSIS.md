# CCTV 节点线路故障调查

日期：2026-10-24。调查对象为 CCTV 页的 WS / BD / KS / TX 静态线路，未更改版权、登录或 DRM 校验流程。

后续进一步核对了原央视影音 IPA 的三个 URL 直播前端及原始媒体的普通解码表现，并将 CCTV 手选地址改为直接调用 CNPlayer URL 起播入口。历史 CDN 偏好调查仍用于解释旧版错误；当前自选 URL 实现及真机验收边界见 [IPA 自选线路调查](CCTV-IPA-SELF-ROUTES-RESEARCH.md)。

## 已确认原因

1. 旧版宿主的 CCTV 选线最终调用 `playLIVEWithChannelID:delegate:configOptions:`。所选静态 URL 没有交给 AVPlayer 或独立 Cicada；它们只被当作 SDK CDN 偏好的来源元数据。独立 Cicada 直连曾存在于 0.3，0.6 尝试 SDK URL 播放，0.7（`8e3db1f`）改成了偏好方式。当前手选地址调用 URL 起播入口，见下文更新记录。
2. `CNPlayer configSDK_CDN_LIVEDefaultCDNInfo:` 的参数经 SDK 配置管理器检查为非空 NSDictionary。旧实现依次传 NSArray / CNPlayerHlsCdnInfoItem，均不符合该路径的输入类型。`cdn_vip` 在 SDK 默认配置中是域名字符串，旧实现却设成 NSNumber 0。
3. `getVDNConfig_CDNLive_DefaultCDNInfo` 是 CNVDNManager 的类方法，当前 SDK 的 CNPlayer 没有该方法。旧宿主向 CNPlayer 回读，必然得到 nil；不是媒体服务器给了空播放地址。
4. 附件日志 8192333E 的 09:43:49–09:43:57 显示 CCTV-7 选择 WS 后回读为空，随后明确记录“按默认调度播放”及 SDK 首帧。它证明当时播放成功的是默认 SDK 流程，不能证明 WS 偏好生效。
5. 旧菜单仍用 WS/BD/KS/TX 选中标记表示结果，配置失败也保持选中名称；重试又会隐式回到自动，容易让用户误以为正在播放选定的非 SDK 线路。

SDK 证据来自仓库内 CNPlayerSDK 3.23.28 的 Objective-C 方法元数据，以及以下配置方法的本地实现检查：

- `+[CNPlayer configSDK_CDN_LIVEDefaultCDNInfo:]`：对象参数，对象返回值（nil 成功或错误对象）。
- `-[CNVDNConfigManager startVDNConfig_CDNLive_DefaultCDNInfo:]`：非空字典写入配置。
- `+[CNVDNManager getVDNConfig_CDNLive_DefaultCDNInfo]`：读取默认 CDN 字典。
- SDK 自带 CNLiveConfig_V2th.json 中 cctv1/cctv7 等频道的 drm 标记为 1。

## 有限网络抽查

只做普通 HTTPS GET，不访问密钥/授权端点，不下载或解码媒体分片，不添加账号或签名：

| 样本 | 主清单 | 首个子清单 | 含义 |
| --- | --- | --- | --- |
| CCTV-1 WS | HTTP 200、有效 HLS | HTTP 200、有效 HLS | 清单当前可读取 |
| CCTV-1 BD | HTTP 200、有效 HLS | HTTP 200、有效 HLS | 清单当前可读取 |
| CCTV-1 KS | HTTP 200、有效 HLS | HTTP 200、有效 HLS | 不能沿用旧文档的 KS 全部 404 结论 |
| 广东卫视 TX | HTTP 200、有效 HLS | HTTP 200、有效 HLS | 清单当前可读取 |

四个样本不能代表全部 94 条静态地址，也不能代表用户设备网络、实时版权或视频解码成功。SDK 的 DRM 标记和普通清单可读取是两个不同事实；没有据此认定它们适合独立 AVPlayer 播放。

## 此前配置修复（现已不用于手选线路起播）

- 新增 NativeCDNPreference，以字典传配置，在 CNVDNManager 回读并比较；cdn_vip 只使用来源 host。cdn_code/cdn_name 沿用仓库 provider 标签，不伪造服务端完整 CDN 编码。
- 保存并校验恢复原始 SDK 配置；拒绝写入、回读不一致时尝试回滚。不把配置回读成功宣传为实际 CDN 选择或解码成功。
- 配置检查发生在旧播放停止之前；失败有明确原因和“使用 SDK 自动线路”入口，不静默改成自动播放。
- 该阶段曾让手动重试保留所选偏好，并将菜单称为“SDK CDN 偏好”。当前线路面板显示“CNPlayer 自选地址”，播放信息分别显示所选来源完整 URL 与 SDK 报告节点。
- 修正 UI 测试替身：读接口放在 CNVDNManager，写接口校验字典并返回错误对象。

## 限制与验收

此接口名称和实现仅支持“默认 CDN 配置”的结论，不足以证明它会强制改写服务器 VDN 调度。provider 标签是否与当前服务端编码一致、偏好是否被当前直播核心采用，都需要在真机对照“请求线路 / SDK 报告节点 / 首帧”日志验证。当前自选地址路径将完整 URL 交给 CNPlayer URL 接口；这仍不等于已验证该地址完成授权、持续解码或真机稳定播放。真正绕过 CNPlayer 的独立 DRM 播放仍未实现，也未在本次改造中宣称支持。

此前的静态源码契约和 macOS Foundation 测试覆盖过配置读写边界；它们没有证明真实播放。当前轮没有运行测试；当前 Linux 环境没有 Apple SDK，原生构建与真机播放均未验证。
