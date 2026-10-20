# APTV JavaScriptCore 验证记录

2026-10-20。目标仍为 `https://tv.cctv.com/live/cctv2/m/index.shtml` 的官方网页来源，未换用央视频源。

- 用户 iPhone 截图：APTV 内嵌 Python 3.14.6，`platform=ios`；系统 JavaScriptCore 的 JS 与微型 WASM 均返回 42。检测脚本旧版打印后退出，因此 APTV 显示“没有启动监听服务”；这与引擎测试成功不矛盾。
- Linux 开发机：通过 `ctypes` 直接加载 Debian JavaScriptCoreGTK 2.54.0；没有启动 Node、Chromium、FFmpeg 作为服务运行组件。官方 JS/WASM 保持原样，SHA-256 校验沿用原服务。
- 原始 SDK 初始化成功，并通过正常 HTTP 获取官方 H5player 配置；实际配置响应经过 SDK 的正常 XHR 和 IndexedDB 回调路径。
- 已有相邻真实原始分片样本：204 个媒体单元约 0.193 秒完成 SDK 处理，重新映射 TS 后严格解码无错误。该耗时仅代表本机样本。
- 生成的 `cctv-aptv.py` 实际启动 HTTP 服务，订阅 `/all.m3u`，播放 `/cctv2.m3u8`：首次约 19.576 秒进入 ready；连续严格解码 60 秒、1496 帧，解码错误日志 0 字节，无重复或丢帧报告。FFmpeg 仅用于独立开发验证，不是手机或服务依赖。
- 75 项回归通过，含真实 JavaScriptCore 的持久上下文、二进制 IndexedDB 事务回调、跨线程拒绝及无限循环超时终止。未配置测试系统库时，这 4 项会明确跳过，其余 71 项仍运行；CI 不代替实播验证。

复测方法：

```sh
python cctv-native/build_aptv.py --check
CCTV_JSCORE_TEST_LIBRARY=/path/to/libjavascriptcoregtk-4.1.so.0 python -m unittest discover -s cctv-native/tests -v
python cctv-aptv.py 18768 --jscore-library /path/to/libjavascriptcoregtk-4.1.so.0
ffmpeg -hide_banner -loglevel error -err_detect explode -i http://127.0.0.1:18768/cctv2.m3u8 -t 60 -f null -
```

iPhone 上只需在 APTV 加载根目录 `cctv-aptv.py` 并启动，默认订阅 `http://127.0.0.1:18768/all.m3u`。完整 SDK、连续分片、系统执行时间限制接口、手机内存与实际播放器表现尚待该手机验收；微型 WASM 成功不保证整个 SDK 在 iOS 上必然成功。发生问题请保留服务日志和 `/status` JSON；服务不回传原始上游签名地址或 SDK 内部数据。

入口兼容修订：用户随后报告只有“未启动监听服务”，没有服务启动日志。检查发现原单文件通过动态 exec 执行整个 Python 服务，存在嵌入式宿主入口识别兼容隐患。现改为静态顶层 Python 声明，只压缩 JavaScript 数据，并提供 `start(ctx)`。本地分别验证直接运行和以非 `__main__` 名称导入后调用 start，两者均能监听并返回 HTTP 200 订阅。此改动是否解决该手机的启动问题仍待用户验收。
