# cbox-live v1.6.0：APTV 单文件服务

运行时只需要 Python 文件。HAR 用于离线协议研究，不是服务的输入或播放依赖。

## 本版修正

- 移除 HAR 解析、`--har` 参数、文件变更轮询、热更新及相关锁、版本计数和诊断提示。
- 移除内嵌的旧 App 抓包 URL、`auth-key` 和会话请求模板；不依靠过期请求模拟实时签名。
- 保留原 App 的接口、清单与参数处理研究代码及 61 台目录。本脚本的原 App 实时签名和 UDRM 处理尚未接入，打开其播放入口会明确返回 HTTP 503，不再要求用户导入抓包。
- 央视频纯 Python 签名、地方源、同台备用选择、节目单、分片直连、直播窗口及切台优化保留。推荐目录仍为 85 个不同频道条目，存在目录不等于已逐台验证可播。
- 清理已合入主文件的旧 `cbox-live-next.py` 研究版副本，避免继续使用旧 HAR 运行方式。历史研究过程与版本记录可从 Git 历史查看。

## 启动与 APTV 订阅

需要 Python 3.10+，央视频签名仅用标准库，无需 Node、pip 包、HAR、Cookie 或附加 JS 文件。

```bash
python cbox-live.py 8767
```

在同一手机的 APTV 内运行时，启动脚本后刷新订阅：

```text
http://127.0.0.1:8767/aptv.m3u
```

节目单：

```text
http://127.0.0.1:8767/aptv-epg.xml.gz
```

脚本部署在电脑、NAS 或其他设备时，将 `127.0.0.1` 换成那台设备的局域网 IP。Python 下载地址是脚本文件，不是频道订阅地址。

更新步骤：停止旧服务，替换 Python 文件，重新启动并刷新原订阅。新版已删除 `--har`；旧启动命令应去掉该参数。

## 模式与能力

| 路径 | 目录数 | 说明 |
|---|---:|---|
| `/aptv.m3u` | 85 | 推荐：同台合并与来源选择 |
| `/combined.m3u` | 134 | 完整来源条目，包含同台多源 |
| `/ysp/all.m3u` | 63 | 央视频公开流，纯 Python 签名，默认分片直连 |
| `/regional/all.m3u` | 10 | 宁夏及黑龙江官方源目录 |
| `/web/all.m3u` | 61 | 原网页 CDRM，需可选 Node.js 18+ 内核 |
| `/app/all.m3u` | 61 | 本脚本的原 App 研究目录；实时签名和 UDRM 尚未接入，不能视为可播源 |

默认同时保留原网页和 App 研究入口，并启用央视频及地方来源。没有 Node 时，未加模式前缀的 `/all.m3u` 和旧频道入口自动使用推荐来源选择。显式网页来源缺少内核时返回能力说明。

本脚本原 App 的 `request_generation` 为 `APP_SIGNER_NOT_IMPLEMENTED`，`video_processing` 为 `UDRM_NOT_IMPLEMENTED`。`CORE_B85` 是网页处理核心，不代表原 App 已实现；网页签名常量也不能直接当作 App 签名算法使用。


原 App UDRM 现已在独立的 [cctv-app-udrm 单文件服务](../cctv-app-udrm/) 中跑通：旧错误样本和三路实时源均通过音视频解码验证，详见 [2026-10-21 研究记录](research/UDRM-20261021.md)。新服务的 v0.3.0 已移植到系统 JavaScriptCore，无需JDK；手机同机订阅 `http://127.0.0.1:8769/all.m3u`，实机待验收。本脚本原61台目录及节目单继续保留。

## 切台与诊断

央视频首选清单超过 0.65 秒仍未完成时，才尝试一个官方备用，使用先成功的有效结果。清单单请求超时默认 3 秒；短缓存、票据续期、已观察分片窗口与观看期间共享刷新保留。实际出画面时间还受官方 CDN、网络和播放器缓冲影响。

- `/diagnostics.json`：模式能力、请求阶段耗时、来源错误及直播窗口。
- `/aptv/channels.json`：同台来源与选择状态。
- `/modes.json`：启用模式与推荐入口。
- 各模式 `/diag`、`/channels.json`：模式状态及频道目录。

首次频道打开或明显慢请求会记录“频道清单响应 X 秒”。`api_wait_ms`、`manifest_wait_ms`、`playlist_wait_ms` 不包含播放器下载分片或缓冲。

缓存目录无法写入时自动使用内存，不影响服务启动。APTV 托管线程无需安装 Node 即可运行央视频；原网页 CDRM 的可选依赖另行报告。

## 可选参数

只启用央视频：

```bash
python cbox-live.py 8767 --api-mode ysp --extra-sources none
```

此配置的推荐目录为央视频 63 条，不包含未启用的来源。

```bash
python cbox-live.py --api-mode ysp --extra-sources none --doctor ysp-cctv1
python cbox-live.py 8767 --ysp-manifest-timeout 8 --ysp-hedge-delay 0
```

FFmpeg 只用于可选视频诊断。`--direct` 只控制 Python 请求是否使用代理环境变量，不控制 APTV 自己的网络路径。默认央视频 `--ysp-media relay`；`proxy` 为可选分片转发对照模式。

## 验证与限制

139 项现行功能回归测试通过，覆盖无 HAR 参数、无抓包文件访问的启动、无 Node 托管运行、85 条推荐目录与原 61 台保留、App 明确返回 503、纯 Python 签名、HLS 重写、直播窗口、备用选择和切台故障恢复。原先专门测试 HAR 导入/热更新或内嵌抓包请求的旧用例随对应功能退役，不计入本版验证。

本轮不宣称原 App 解码已解决，也没有在用户 iOS 上新增实播验证。此前提供的原 App 样本仍有解码错误，待取得可验证的真实签名和视频处理实现后再接入。频道可用性仍取决于官方接口、版权限制、CDN 及设备解码能力。

## 来源与下载

新增来源适配参考 akiralereal/iptv 提交 `e475b2f6d24029f844ada2b362d703c8b88c2e9b`，GPL-3.0，署名及修改记录见 `NOTICE-SOURCES.md`。原 JS 参考源码和许可继续内嵌，运行 `python cbox-live.py --licenses` 可查看。单文件运行无需另放 JS 或许可证文件。

[下载单文件 Python](https://raw.githubusercontent.com/joeshu/yqk-forward-widget/main/cbox-live/cbox-live.py?v=1.6.0)

本版验证记录：`validation-v1.6.0.json`。历史验证记录只代表当时版本，不代表新版仍支持已经移除的 HAR 工作流。
