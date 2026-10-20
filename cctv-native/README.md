# CCTV-2 网页原分片订阅实验版

使用 [CCTV-2 官方手机网页](https://tv.cctv.com/live/cctv2/m/index.shtml) 对应的播放来源，只提供 CCTV-2 财经。本服务独立于 `ysp-live`，不会替换成央视频或其他平台的来源。

**当前播放服务用于电脑/服务器，不能直接在 APTV 内置 Python 运行。** APTV 截图已确认没有 Node，且提示不支持 `subprocess`；下载旧播放脚本不会解决这个限制。手机直跑方案仍在研究，尚未验证可播。可在 APTV 加载 [aptv-probe.py 环境检测脚本](https://raw.githubusercontent.com/joeshu/yqk-forward-widget/refs/heads/main/cctv-native/aptv-probe.py)，将日志中的“Python版本”和“可见候选模块”用于后续适配。检测脚本仅使用标准库、不导入候选原生模块、不启动子进程、不访问外网，也不提供频道订阅；完整报告位于 `http://127.0.0.1:18770/status`，模块可见不代表可用或支持 WebAssembly。

**需要 Python 3.10+、Node.js 20+ 和 npm，不需要 Chromium、Playwright 或 FFmpeg。** Python 提供本地订阅和分片缓存，Node 运行固定版本的官方组件；处理后的原 TS 分片直接供播放器解码，不采集网页画面、不重新编码。这仍是 Python + Node 程序，只有纯 Python 的环境不能运行。

## 下载与启动

下载仓库根目录的单文件 [cctv-native.py](https://raw.githubusercontent.com/joeshu/yqk-forward-widget/refs/heads/main/cctv-native.py)，保存到本地。无需同时下载本目录的源码。

首次安装独立运行依赖：

```sh
python cctv-native.py --setup
```

该命令通过 npm 安装四个固定版本依赖，并下载原样的官方 `live.worker.js`，校验 SHA-256 后存入 `~/.cache/cctv-native`。依赖使用独立缓存目录，官方组件不写入仓库；下载到不同版本时会报错，需要更新脚本。安装和播放均沿用系统代理与 TLS 校验。

之后启动：

```sh
python cctv-native.py 18768 --warmup
```

播放器添加订阅：

```text
http://127.0.0.1:18768/all.m3u
```

`--warmup` 在播放器 GET 订阅时后台提前取源，订阅本身立即返回；省略时首次选台才启动。HEAD 不触发预热。首次播放需要等待官方组件初始化及相邻分片准备，真实耗时见 [VALIDATION.md](VALIDATION.md)。

手机或电视访问电脑上的服务时：

```sh
python cctv-native.py 18768 --bind 0.0.0.0 --warmup
```

订阅地址改为 `http://电脑局域网IP:18768/all.m3u`。手机上的 `127.0.0.1` 指向手机自身。旧版 `cctv-web.py` 也默认使用 18768，两个服务需停止其中一个，或用不同端口启动。

## 状态与运行选项

- 单台地址：`http://127.0.0.1:18768/cctv2.m3u8`。
- 状态地址：`http://127.0.0.1:18768/status`。包含实际阶段、分片数量、缓存占用、阶段耗时与脱敏错误；`transport_retries` 是本次会话的网络重试次数，`last_transport_error` 在恢复后清空；`media_ready` 不代表用户播放器已经验收通过。
- `--node /路径/node`：指定 Node 可执行文件。
- `--cache-dir /路径/缓存目录`：改变安装缓存；安装与启动须使用同一目录。
- `--buffer-mb 64`：分片内存上限，范围 16–256MiB；最多保存 10 个分片，播放器列表提供最近 6 个。
- `--idle-timeout 120`：无人观看后停止取源，范围 30–3600 秒。再次选台会重新初始化。

多个观众共享一份取源与处理进程。播放请求最长等待约 50 秒；尚未准备好或失败返回 HTTP 503，可查看 `/status`，错误冷却 30 秒后由新播放请求重试。旧会话或已淘汰分片返回 410，需让播放器刷新清单。

短暂超时、断链及 HTTP 408 / 429 / 5xx 会按 0.8–4 秒退避重试，保留已就绪的播放缓存；401 / 403 / 404 会重新获取官方调度。重试受无媒体进展 30 秒的检查预算约束，当前网络读取结束后判断；持续故障仍会停止。官方拒绝播放、格式错误和组件进程错误不会进入网络重试循环。

主清单首次解析后直接轮询媒体清单，120 秒取源刷新时重新解析，减少重复请求。该优化不保证固定的冷启动耗时。

## 当前支持范围

本版仅支持当前观察到的 TS / H.264 分片结构。为确认分片末尾的媒体单元完整，先核对相邻 HLS 序号及下一片起始码，再按原 TS 结构重组媒体数据、保留原音频和时间戳。支持的变短媒体单元限于单个 PES 内；增长、未知封装、无法证明相邻帧边界或上游格式变化都会明确失败。下载过慢导致直播窗口跳过片段时，丢弃缺失区间并用 HLS 不连续标记重新接入当前窗口；`/status` 的 `source_gaps` 记录次数，不拼接缺失片段的媒体字节。它不具备通用媒体转码能力。

上游返回 `play != 1` 时停止，不通过更换地区、账号或来源继续取流。官方组件和接口变化、网络及播放器差异都可能影响可用性；目前不保证其他网络可播，未提供其他频道、EPG、回看或 4K。真实验证范围以 [VALIDATION.md](VALIDATION.md) 为准。

此前的 [cctv-web 浏览器采集版](../cctv-web/README.md) 继续保留，可独立选择使用。

## 开发

编辑 `service.py`、`cctv_native_ts.py`、`engine.cjs`，然后生成单文件：

```sh
python cctv-native/build_service.py
```

离线检查：

```sh
python -m unittest discover -s cctv-native/tests -v
python cctv-native/build_service.py --check
node --check cctv-native/engine.cjs
python -m py_compile cctv-native.py cctv-native/service.py cctv-native/cctv_native_ts.py cctv-native/build_service.py
```

CI 运行 Python 3.10 / 3.12 与 Node 22 的离线检查，不执行官方接口实播。FFmpeg 可用于开发时验证输出解码，服务运行不依赖它。
