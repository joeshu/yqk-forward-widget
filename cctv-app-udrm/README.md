# 央视影音 App UDRM → APTV

原 App 的媒体处理链已跑通。这个独立单文件 Python 在电脑/服务器上运行，APTV 通过局域网订阅；需要 **Python 3.10+、JDK 21、OpenSSL**。本次实际验证环境为 Linux x86_64、Python 3.12、JDK 21。

[下载单文件 cctv-app-udrm.py](https://raw.githubusercontent.com/joeshu/yqk-forward-widget/main/cctv-app-udrm/cctv-app-udrm.py)

```bash
python3 cctv-app-udrm.py --warmup
```

APTV 添加订阅：

```text
http://运行电脑的局域网IP:8769/all.m3u
```

电脑本机可用 `http://127.0.0.1:8769/all.m3u`。手机和电脑是不同设备时，应填写电脑的局域网 IP。服务需要持续运行。手机 APTV 内置的纯 Python 环境不能直接承载本版 Java/ARM64 模拟依赖。

第一次启动会下载固定版本的官方 APK、Maven 和 Java 依赖，校验后构建本地桥；不需要完整安卓虚拟机、Node.js 或 FFmpeg。FFmpeg只用于开发时验证。后续启动复用缓存。JDK 21 和 OpenSSL 需事先安装。

```bash
# 先准备依赖
python3 cctv-app-udrm.py --setup-only
# 自定缓存和端口
python3 cctv-app-udrm.py --cache-dir ./cbox-cache --port 8769 --warmup
# 查看状态
curl http://127.0.0.1:8769/status
```

## 实际验证范围

默认目录包含 **CCTV-1、CCTV-7、贵州卫视** 三路已经取到实时分片并通过解码验证的 App 节目源。原有 [cbox-live](../cbox-live/) 的 61 台目录继续保留；这里的三路验证不代表全部 61 台的 App UDRM 直播都通过。

- 旧“95 条错误”、后来的“126 条错误”、CCTV-1/CCTV-7连续样本，处理后音视频解码错误均为0。
- 贵州卫视样本经过 SDK 后逐字节不变，仍正常解码。
- 新取到的三路实时分片解码错误均为0，并进一步做三路并发各60秒的本地HTTP音视频连续解码，错误均为0，详见下列JSON。
- 已人工查看处理后的央视画面，台标和字幕正常；尚未在用户的 iPhone APTV 实机测量首帧时间。

记录：[旧样本](SAMPLE-VALIDATION.json)、[新取实时分片](FRESH-VALIDATION.json)、[连续播放及服务响应](LIVE-VALIDATION.json)。JSON只保留测试统计和摘要，不包含视频、许可内容或抓包鉴权头。

这次解决的是原 App 载荷处理。CCTV-5/5+ 的已观察 CDN 仍返回403，调度签名与更多频道的取源还需要单独完善，未列入默认可播目录。现有61台的节目单和网页/央视频入口仍由原服务提供，本文件暂未合并EPG。

## 播放链路与切台

Python下载 App HLS → 校验完整TS/PES → 已获正式许可的官方 Android SDK 处理视频 → 写回原TS位置 → APTV读取本地HLS。

每次会话由原SDK生成正式请求，转发至App配置的官方许可入口，由同一SDK检查响应；成功后才处理视频。未嵌入HAR、过期会话、设备密钥或许可响应；运行中不读取、扫描或重载HAR。SDK库保持原样，仅支持校验过的指定版本，摘要不同会停止。

服务保留音频、PTS/DTS、TS头和包长，拒绝不完整的206/Content-Length、损坏TS及长度变化的处理结果。对未声明长度的末尾PES，只有相邻同源分片证明边界后才发布。当前不支持跨HLS对象延续同一个PES、fMP4、HLS AES/SAMPLE-AES。

`--warmup` 并行预热默认频道；后台刷新使用独立任务，缓存清单和分片直接响应，SDK会话长期复用。网络或许可失败时返回明确错误并限次重建会话。热请求响应统计不等于APTV首帧时间；首次准备、许可和CDN网络仍会影响等待。

可用自己有权使用的其他 App HLS 地址作补充验证：

```bash
python3 cctv-app-udrm.py --source channel_id=https://example.com/live/index.m3u8
```

增加地址不等于验证该频道；许可是否覆盖、码流格式和源站权限均会实际检查。本版保持原有61台项目与这个实验入口独立，方便回退和核对。

## 源码与验证

单文件内的 `PYTHON_SOURCES`、`JAVA_SOURCES` 都是可读源码。SDK二进制从官方APK按固定SHA-256提取，不随仓库分发。外网HTTPS沿用环境代理和正常证书校验；SDK到本机回环使用每个缓存生成的本地TLS传输适配器。

```bash
python3 -m unittest discover -s tests -v
```

离线测试覆盖音频/封装字节保留、重复TS、截断PES、相邻边界、SDK超时与错序、HEAD不触发授权、HTTP Range以及相对清单地址。不把SDK返回0或FFmpeg退出0单独视为画面正常。
