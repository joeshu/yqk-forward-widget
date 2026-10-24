# 设备注册、JCE 时移与 TS 缓存：当前原生 SDK 核实

核实对象：CCTVHost 当前集成的 CNPlayerSDK 3.23.28、CicadaPlayerSDK、alivcffmpeg；用户提供的《央视网 iOS 播放器集成手册》BV3.23.17。本文不把央视影音 App 的业务流程自动等同于播放器 SDK 接口。

| 能力 | 当前仓库中可确认的实现 | 原生 SDK 接入结论 |
| --- | --- | --- |
| ytpcloudws 设备注册 | 内置 Python 的 `cloud_registration_flow` 调用 `/device/v2/get`、`/device/v2/register`，其 GUID 用于插件自己的业务会话 | 三个 framework 的字符串/导出符号及宿主中没有发现这一服务的直接调用接口；这不构成 SDK 内部绝不存在间接调用的证明。不能把插件 GUID 当作原生 SDK 授权结果，也不能认定注册后就会加快原生 VDN/DRM |
| JCE 时移 | Python `jce_timeshift_url` 将起止时间编码成 JCE，向 `jacc.ysp.cctv.cn` 发送命令 25312 | 原生 CNPlayerSDK 有独立时移路径，包含 `liveTimeshift.do`、`seekToStartTime:endTime:completionHandler:`、`backToLive` 和版权检查；没有找到直接暴露 JCE 命令的宿主 API |
| TS 缓存 | Python 的 `/proxy.ts` 和 `TsSegmentCache` 是分片代理缓存 | Cicada 的 `CicadaCacheConfig` 是另一个缓存接口。上游官方 Apple 文档明确：直接 URL 播放的 m3u8 不参与此边播边缓存，不能据此声称原生直播 TS 缓存已经可用；尚无当前定制版另行支持直播 TS 缓存的接口证据 |

## 代码与二进制核实

- `cctv-ios-host/Plugins/ysp-live.py` 已包含 ytpcloudws 注册、JCE 请求和 TS 分片缓存，三者属于内置插件链路。原生 CCTV 正式播放使用 CNPlayerSDK，未调用插件取流。
- 原生 SDK 的时移方法已能从二进制确认。`seekToStartTime:endTime:completionHandler:` 的两个时间参数使用 double 浮点 ABI；不能用当前通用动态调用器的对象参数替代。仍应获取对应完整协议头文件，确认时间语义、回调参数、支持区间及错误处理，再接入 UI。
- 原生时移中存在时移地址为空、回看区间不可用及版权拒绝等路径。任意频道都可回看、固定七天范围或无条件返回直播成功，均没有依据。
- 三个原生 framework 中未搜索到 `ytpcloudws`、`cloudps/wssapi` 字符串；CNPlayerSDK 中可以定位 `https://vdn.live.cntv.cn/api2/liveTimeshift.do`。静态搜索只能说明当前可见证据，不能替代真机请求跟踪。
- Cicada 的 `maxDuration` 是可缓存的单个视频时长上限，单位秒；`maxSizeMB` 是缓存空间上限。它们不是直播起播缓冲毫秒参数，也不是一个 TS 分片的存活时间。

## 对开台、切台速度的实际意义

- 设备注册只有处在当前原生起播关键路径、且结果可由 SDK 复用时，提前注册才可能缩短首次启动；目前没有这种接入依据。额外调用插件的注册接口可能只增加网络开销。
- 时移解决时间定位和回看，不天然缩短直播调度。JCE 业务流程与当前 SDK 时移路径的认证、频道标识、地址及版权结果不能直接互换。
- TS 缓存主要帮助重复读取相同分片或缓冲连续性；切到另一个频道通常没有相同 TS。正在变化的直播列表还必须及时刷新。缓存容量扩大不能直接推导为首次开台更快。
- 已交付的 0.17.3 是 SDK 元数据预解析、起播缓冲调整与宿主等待移除；预解析缓存不是媒体 TS 缓存。

## 可继续接入的依据

若用户所指是另一套央视影音 SDK，需要对应 SDK 版本、公开协议头文件及设备注册/JCE/缓存的实际调用说明；如果来自 App 抓包，应按原生业务层对接研究，并明确它和现有 CNPlayerSDK 的授权/媒体接入关系。当前材料不足以把这三项标记为已加入原生播放器。

本次仅完成核实，没有为展示功能而加入不可验证的注册请求、伪缓存开关或替换原生 DRM 流程。

## 官方上游来源

- [CicadaPlayer Apple README，边播边缓存章节](https://github.com/alibaba/CicadaPlayer/blob/master/platform/Apple/README.md)：说明 prepare 前配置、成功读取完整资源后复用，以及直接 m3u8 地址不缓存的限制。
- [CicadaCacheConfig.h](https://github.com/alibaba/CicadaPlayer/blob/master/platform/Apple/source/CicadaCacheConfig.h)：maxDuration/maxSizeMB/enable/path 参数定义。

以上上游文档用于解释缓存接口，不将其当作当前央视定制 SDK 所有内部行为的保证。
