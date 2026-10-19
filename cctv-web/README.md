# CCTV 网页来源 Python 订阅实验版

使用 [CCTV-2 官方手机网页](https://tv.cctv.com/live/cctv2/m/index.shtml) 本身播放的内容，独立于本仓库的央视频 `ysp-live` 服务。目前只提供 CCTV-2，便于先验证整条链路。

**这是浏览器采集、转码输出的实验版。** 完整官方网页在 Chromium 中正常播放，浏览器标准 `captureStream()` / `MediaRecorder` 接口采集视音频，经 FFmpeg 转为 H.264/AAC 的 HLS，再由 Python 输出 `/all.m3u`。没有替换成央视频源，没有修改官方播放器组件或移植其解密代码。它不是原始码流直连，会重新编码、占用 CPU、增加延迟；不适合追求低延迟或秒切的用途。

## 安装与启动

需要能运行 Chromium 的电脑或服务器、Python 3.10+、Playwright 和包含 libx264/AAC 编码器的 FFmpeg。暂不支持只有纯 Python 运行环境的 iPhone/iPad。手机可以作为播放器，通过局域网访问电脑上的服务。

只需下载项目的这一个 Python 文件：

```text
https://raw.githubusercontent.com/joeshu/yqk-forward-widget/refs/heads/main/cctv-web/cctv-web.py
```

安装 FFmpeg 并确保 `ffmpeg` 在 PATH 中，然后安装浏览器依赖：

```sh
python -m pip install playwright
python -m playwright install chromium
```

Linux 缺少浏览器系统依赖时，可按照 Playwright 提示安装，或使用 `python -m playwright install --with-deps chromium`。程序会优先使用 PATH 中的 `chromium` / `google-chrome`，找不到时使用 Playwright 安装的 Chromium，也可用 `--browser /绝对路径/浏览器` 指定。程序保持 TLS 校验，并沿用进程代理环境。

```sh
python cctv-web.py 18768
```

播放器订阅：

```text
http://127.0.0.1:18768/all.m3u
```

单台播放：`http://127.0.0.1:18768/cctv2.m3u8`。状态：`http://127.0.0.1:18768/status`。订阅和 HEAD 不启动浏览器，第一次实际播放才启动网页；首次可能等待数十秒，部分播放器需提高打开流超时或稍后重试。HTTP 503 表示尚未准备好或已失败，不会返回无效视频占位。

手机/电视访问电脑：

```sh
python cctv-web.py 18768 --bind 0.0.0.0
```

此时将订阅地址改为 `http://电脑局域网IP:18768/all.m3u`；手机的 `127.0.0.1` 指向手机自身。默认端口 18768 与已有 PHP 网关 52451、央视频服务 18767 分开；位置参数可改端口。

## 运行行为与限制

- 多个观众共享一份网页和编码进程；连续请求播放列表/分片保持运行，默认无人观看 120 秒后关闭浏览器页面与编码器。重新选台会重新启动，播放地址中的会话代号会更新。
- 只保存本次会话的短视频窗口，FFmpeg 自动淘汰旧分片；正常退出会删除本次临时目录。断电/强杀残留目录可在服务停止后清理。`--data-dir` 指定临时目录的父目录，不是长期录像目录。
- `/status` 的 `opening`、`waiting-video`、`buffering`、`ready`、`idle`、`error` 显示实际阶段。`media_ready` 仅说明近期 HLS 窗口就绪，不代表每台用户设备已验证可播。
- 内存队列有界，编码器跟不上、浏览器卡顿或官方页面改动可能导致 503；错误后最多 30 秒冷却，再由新播放请求重试。没有自动换成其他平台来源。
- `--startup-timeout` 控制本地播放请求等待时间，默认 75 秒，范围 5–120；`--idle-timeout` 范围 30–3600。无人观看回收与冷启动是本实验版的取舍。
- `--public-base-url https://example.com/tv` 可用于明确配置的反向代理前缀，不读取不可信的转发头。服务默认仅本机监听，未实现访问账号；局域网使用时按自己的网络环境部署。
- 输出最高限制为 1280 像素宽、25fps，H.264/AAC、约 2 秒 TS 分片。这是重新编码后的输出，不承诺与官网同画质或同延迟。未提供 EPG、回看、4K、其他频道或 iOS 原生服务运行支持。
- Node 加载官方 WebAssembly 的研究未能完成播放器初始化，本版没有把那个未完成的适配器包装成可用功能，也不需要 Node。

## 验证

本环境单独复制一个 Python 文件启动，实际完成 `/all.m3u` → `/cctv2.m3u8` → TS 分片请求，输出 H.264 1280×720 和 AAC，严格解码 25 帧通过。具体耗时与范围见 [VALIDATION.md](VALIDATION.md)。用户播放器与长期运行仍需验证。

离线 HTTP、窗口和路由检查：

```sh
python -m unittest discover -s cctv-web/tests -v
```
