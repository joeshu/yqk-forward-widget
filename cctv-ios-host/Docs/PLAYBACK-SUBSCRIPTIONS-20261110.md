# 运行日志、DASH 与订阅适配修复

基线：`e620368c5d57a4298f12685a7289387d53a05e34`。检查日期：2026-11-10（北京时间）。两份用户诊断记录来自 App 1.30 / build 480、iOS 27.0.1。

## 日志证据与处理

| 证据 | 根因/边界 | 修改 |
| --- | --- | --- |
| 2 次 `UnicodeEncodeError`，发生在中文分集路径转发 | Python HTTP 传输要求 ASCII request-target；旧转发直接使用中文 URL | 传输前编码 Unicode 路径/查询；保留已有百分号、加号、签名顺序，处理中文重定向 |
| DASH 15 次 `0x20030003` 输入解析错误、1 次首帧超时 | 不能从这些错误推断硬件解码器故障 | 明文 ISO-BMFF DASH 转 HLS；解析/网络/超时不再重建软件解码器 |
| HLS 8 次 `0x20050006` / HTTP 404 | 上游地址失效，软解码不能恢复不存在的资源 | 直接推进原有线路回退；保留真实上游失败 |
| 5 次资源导入 HTTP 403 | 日志不能证明 token 失效 | 区分 HTTP 401 与 403 的提示，不把拒绝访问当作确证的凭据过期 |
| `spider_init` 发生 IndexError | 日志缺少对应脚本的行号，不能归因到某个站点 | 失败健康响应带脚本文件名、函数、阶段和行号，不含异常变量/源码/凭据；原失败保持失败 |
| `csp_SP360` ext 为空 | 旧代码没有该站点协议，只能报缺少 URL | 增加 360 独立 JSON 目录、分类、搜索、详情、分集适配；分集官方网页仍走解析流程 |
| 三秋 404、面包 403、部分海报 `encrypted: 1` | 独立源站协议/可达性与图片解密问题 | 保留失败；没有声称所有 JAR、受保护图片或站点都已打通 |

## DASH 范围

- 一个 Period；H.264/HEVC 等 iOS 可解码视频及 AAC/AC3 音频的 fMP4 分片。
- 继承的 SegmentTemplate、Number/Time/RepresentationID/Bandwidth 模板、SegmentTimeline、有限的负重复、SegmentList 与字节范围。
- 明确时间线且固定分片时长的 Time 模板直播；缓存按 minimumUpdatePeriod 更新。
- master HLS 包含独立音轨和视频变体；初始化片段和媒体片段均经现有有界代理，继承来源请求头与同源签名参数。
- 主清单验证后交给 AVPlayer；备用清晰度按选择加载，不逐个预下载。回退 Cicada 时使用原 MPD 和原请求头。
- DRM、WebM/未知编码、SegmentBase、多 Period、无法确定边界的直播保留原 DASH 引擎。没有添加授权绕过或转码器。

本地用 FFmpeg **仅生成测试素材并验收解码**，App 内不会调用 FFmpeg 可执行文件。HTTP -> DASH -> HLS -> 初始化片段/音频/视频分片的端到端测试已实际解码出音视频；这不能代替 iPhone AVPlayer 首帧、音画同步和 seek 验收。

## 两个订阅的实测

测试使用用户提供的订阅凭据；凭据和下载脚本未加入本次提交。

| 对象 | 实测结果 | 可确认范围 |
| --- | --- | --- |
| `/hamo/… .hawk` | HTTP 200，schemaVersion 1，63 个 source 模块，入口为 .hjs | 合集结构能识别；不等于模块可以执行 |
| 七猫短剧、橙果短剧、哔哩哔哩 HJS 样本 | HTTP 200；实际内容均是 `ver/alg/iv/cipher` AES-256-GCM 包 | 导入器现在明确提示需要发布方明文包或授权接口，不再按 JS 执行加密 JSON；尚未打通 |
| `/get?…&client=ios` | HTTP 403；JSON 返回 ACCESS_DENIED，明确拒绝脚本访问 | 未绕过源站限制；当前配置研究使用仓库已有的 324 项索引 |
| 腾讯 Python 入口 | HTTP 200；原脚本在宿主初始化成功，首页 7 类 / 21 项 | 脚本可导入、目录可读；播放返回解析网页，未验证每部影片可播 |
| 爱奇艺 Python 入口 | HTTP 200；原脚本初始化成功，首页 7 类 / 24 项 | 脚本可导入、目录可读；播放按真实结果区分网页与直连媒体 |
| 优酷 Python 入口 | HTTP 200；在对应 Python 依赖和 Crypto 兼容层下初始化成功 | 仍依赖上游 token/cookie 和影片授权，未验证所有影片播放 |
| 360 目录接口 | 当前环境返回 HTTP 200 的 Site Unavailable HTML | 协议适配有本地原生功能测试；在线目录与播放尚未验收 |

360 适配的协议依据：`pcbean/CatVod-Src` 的 `js/sp360.js`（commit `5ffdf70d8592f17db5c17fce6711828fdf261f9b`，上游 jadehh/TVSpider）。Cicada 错误分类依据：alibaba/CicadaPlayer 的 `platform/Apple/source/CicadaErrorCode.h`。没有把整包 Android JAR 标记为已执行。

## 验证

- 本地全套回归：812 项，58 项因需要 macOS/iOS 跳过，其余通过；runtime 专项为 80 项通过。
- DASH 专项：6 项通过，包含真正的音视频 HTTP 解码；native 专项在 macOS 上执行。
- 打包脚本复制新增 DASH/URL 模块；IPA 校验强制检查两个模块存在。
- 分支推送会启动原有 macOS 构建、原生协议检查、IPA 校验和模拟器 smoke。分支构建不会发布正式 Release。

尚需真机验证：用户失败的原 MPD（诊断中没有完整 URL）、DASH 音画同步/seek、受保护站点解析结果以及用户账号能访问的影片。加密 HJS 还需要发布方提供互操作资料或授权接口；没有密钥时不能承诺全部 63 项可播放。
