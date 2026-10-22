# 在 CCTVHost 里运行 Python 插件（ysp-live 类）的研究与方案

样本：`ysp-live-v9.5.py`（3504 行）、`cctv-app-udrm-v0.3.7.py`（APTV 脚本服务）
结论先行：**这类插件可以在本 App 内运行，且样本的依赖条件相当友好（纯标准库）；真正的成本是嵌入 CPython 解释器（包体 +40–60 MB）和 iOS 的进程生命周期限制，而不是脚本本身。**

## 一、脚本画像（实测）

| 维度 | 结果 |
| --- | --- |
| 行数 | 3504 |
| 第三方依赖 | **无**。全部为标准库：`http.server`、`ssl`、`socket`、`threading`、`hmac`、`gzip`、`urllib`、`dataclasses`… |
| 入口 | `main()` + `argparse`（port/bind/data-dir/cache-mb/no-engine…）；另有 `start_companion_engine()` |
| 服务形态 | `ThreadingHTTPServer`，路由 `/all.m3u`、`/diag`、`/health`、`/<channel>.m3u8`、`/proxy.ts`、`/engine_proxy` |
| 输出 | m3u 订阅（频道列表）+ 每频道 m3u8 + 代理 TS（明文 HLS） |
| 受限 API | 仅一处 `__import__('subprocess')`，用于拉起 Node 伴生引擎；iOS 无 node/subprocess，脚本用 `shutil.which('node')` 判断后**自动跳过**，不影响主流程 |
| 语法要求 | 无 `match`、无 `X | Y` 类型注解，`from __future__ import annotations`，Python 3.9+ 即可 |
| 持久化 | `--data-dir` / `YSP_DATA_DIR`，可指向 App 沙盒目录 |

这意味着：**不需要 pip、不需要交叉编译任何 C 扩展**，只要有一个可用 CPython 运行时即可跑起来。

## 二、三条路线

| 路线 | 做法 | 成本 | 能力损失 | 适用 |
| --- | --- | --- | --- | --- |
| **A. 内嵌 CPython** | 链接预编译 `Python.xcframework`（BeeWare Python-Apple-support），`Py_Initialize` + 打包 stdlib zip，后台线程执行脚本，App 内订阅 `127.0.0.1:<port>/all.m3u` | 包体 +40–60 MB；CI 增加链接与资源打包；脚本无第三方依赖所以不需要 pip | 无 Node 伴生引擎（少 Web/WASM 高码率路径，自动回退 1080p）；后台挂起即停服；无 subprocess/fork | 想「装上就能用」 |
| **B. 外部运行 + 本 App 订阅** | 插件跑在电脑/NAS/另一台设备，本 App 添加 `http://<host>:8767/all.m3u` | **0（已实现，0.8.0）** | 需要那台设备常开；跨网络要放行端口 | 现在就能用 |
| **C. 用 Swift 重写插件** | 用原生代码复刻 3500 行（含设备协议、签名、加密、TS 代理） | 极高，且后续无法跟进上游版本 | 无 | 不推荐 |

## 三、已落地的部分（0.8.0）

- 导航栏 **订阅**：输入 m3u/m3u8 地址 → 拉取 → 解析（`#EXTINF` 的 `tvg-name` / `group-title`、相对地址补全）→ 并入频道列表的「订阅」分组 → 持久化到 `NSUserDefaults`，下次启动自动刷新。
- 订阅频道用 **AVPlayer** 播放（明文 HLS 的正确选择，走系统硬解与 ATS 豁免），控制条、全屏、静音、切台复用同一套 UI。
- 央视频道的 UDRM 路径不受影响，仍由 CNPlayerSDK 处理。

所以「运行插件 → 订阅 m3u8 → 播放」这条链路，**今天就可以用 B 路线完整走通**：把 ysp-live 跑在任意设备上，App 里订阅它的 `/all.m3u` 即可。

## 四、A 路线的实施清单（如需内置）

1. **运行时**：取 Python-Apple-support 的 `Python.xcframework`（含 `libpython3.x.a` 与 stdlib），放 `Vendor/`；CI 里 `-framework`/`-lpython3.x` 链接，并把 `python3xx.zip` 作为资源打包。
2. **启动**：`PyConfig` 设 `home`、`module_search_paths` 指向沙盒内解压的 stdlib；`Py_InitializeFromConfig`；`PyRun_SimpleString("import sys; sys.argv=['ysp','--no-engine','8767']")` 后 `runpy.run_path(script)`。
3. **线程**：脚本自带 `ThreadingHTTPServer`，在独立线程启动即可；主线程继续跑 UI。
4. **沙盒**：`data-dir` 指向 `Library/Application Support/ysp`；关闭 subprocess（脚本已自动跳过）。
5. **生命周期**：iOS 进入后台会挂起进程 → 服务随之停止；App 内播放时不受影响，若要做到「锁屏继续」需 `beginBackgroundTask`（仅数十秒）或避免依赖后台常驻。
6. **可观测**：把 `print` 重定向到内置日志面板（`sys.stdout` 替换为自定义 writer），便于排障。
7. **风险**：Py_Initialize 失败、`_ssl` 模块缺失（脚本要 HTTPS）、包体超标、审核层面（自用无碍，上架需注意）。

## 五、建议顺序

1. 先用 **B 路线**验证插件产出与本 App 的播放兼容性（今天可做）。
2. 确认稳定后再做 A：先只做「启动/停止解释器 + 日志面板」，跑通 `--no-engine` 的 `/health`，再订阅 `/all.m3u`。
3. 不建议走 C。

## 六、待确认

- 是否接受包体增加 40–60 MB（影响安装包与首次启动时间）。
- 插件是否需要在 App 后台继续工作（这决定要不要额外的保活设计，且 iOS 上不可靠）。
- 数据目录是否需要持久化跨版本（频道缓存、设备注册信息）。
