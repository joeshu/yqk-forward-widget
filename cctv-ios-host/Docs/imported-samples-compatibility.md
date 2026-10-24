# 0.18.1 附件资源兼容与验证

基于 `d28ad71`，已合入用户最新成功 CI 的 `fix/cctv-plain-routes-direct` / `0355d6c`。未改变来源的登录、版权或地域规则。

## 看剧AI截图的文件错误

截图中的 `Errno 2 / No such file or directory` 发生在加载入口文件之前。原实现把 `packageRoot` 和 `archivePath` 的整个 App 沙盒绝对路径写入配置；容器 UUID 改变后可能继续引用旧地址。此故障不同于来源 API 或视频解码失败。

现在按服务 ID 保存 `packageRelativePath` / `archiveRelativePath`，在读取旧配置和启动服务时重定位到当前 Services 目录。中文、空格、ZIP 内的嵌套目录会保留；不会扫描其他服务、替换来源代码或覆盖用户配置。Python 的显示类型也从错误的 ESM 改为脚本。若当前服务目录里的原文件确实丢失，会在启动前明确提示重新导入，保留旧配置和日志。没有实机文件系统证据时，不能断定截图一定由容器迁移造成。

## 原文件支持方式

| 附件 | 识别及入口 | 本轮验证 | 边界 |
| --- | --- | --- | --- |
| 猫源本地包0911.zip | Node / CatPaw HTTP / CommonJS；加载同包 index.config.js | 原包两轮启动、43 个来源、停止/重启、另一服务仍可调用 | 每个远端来源的视频可用性未逐一实测 |
| cheyong-rex.js | Node / Widget 原脚本 | 原代码加密请求、指定第 2 集、HLS 首分片探测；宿主安全随机数与请求头传递 | 原代码测试使用模拟 API/媒体；远端内容和真机解码未测 |
| 看剧AI.py | Python Spider | 原代码加载、8 个分类、直链结果；宿主 HLS 转发可读到分片 | 媒体传输使用本地测试数据；截图缺文件不能靠网络重试修好 |
| 蝴蝶影院 iOS.py | Python Spider | 原代码加载、带 User-Agent / Referer 的 HLS 转发可读到分片 | 测试不访问内容站；远端内容与真机解码未测 |
| cbox_live_plugin.py | Python HTTP /all.m3u | 与另外两个直播服务同时运行、读取列表、独立关闭后端口拒绝连接 | 来源脚本仅提供其可用明文频道 |
| ysp_live_plugin.py | Python HTTP /all.m3u | 同上；不因订阅读取而触发高码率注册 | 高码率上游及真机播放未测 |
| ysp-live-v9.5.zip | 自动选择唯一 Python HTTP 入口，保留伴生 JS 文件 | 64 项列表、三服务并存、独立关闭 | 原设备协议的 heartbeat/refresh/retry 为无停止接口的永久循环；默认使用其 --no-4k 1080p 模式，--no-engine，32 MB 缓存。详情页明确展示限制；不启动 Node/WASM 子进程 |

猫源包需要 `catServerFactory` 和 Dart 消息端口接口。宿主提供 Node HTTP 工厂及“无 Dart 伴生服务”的真实返回，记录主工厂的监听器，防止误连包内其他辅助服务。为兼容手机不能创建 pino Worker，使用包自身 development 日志模式。

对带本机登录的猫源包，通过其 `/website/auth/status`、`setup`、`login` 接口正常初始化/登录。全新本机数据目录生成私有随机密码，原子保存为权限 0600 的 `catpaw-auth.json`；已有密码且无对应本机凭据时，提示在“插件参数”填写 `password`，不尝试猜测或反复登录。令牌仅附加给同一 Node 本机 origin，不能传给远端媒体地址。

Node 的原生 FormData/File 惰性 getter 可能加载依赖 WASM 的 undici，即使 fetch 已被替换。现在打包 node-fetch 3 的完整纯 JS Fetch / Headers / Request / Response / FormData / Blob / File，避免在无 WASM 的运行时中触发原生 getter。进程事件监听与文件 watcher 也归属各自会话并随停止/启动失败清理。

## 界面与使用

在“资源 → 添加资源 → 导入文件/ZIP”选择原附件，默认不执行代码。导入后启用对应服务：Python 直播包自动提供本机订阅，频道在“频道”页；Spider、Widget、猫源从“打开影视”进入。Widget 来源的工具栏筛选可选择季/集，界面显示当前参数；旧请求不能覆盖新集的解析结果。每个服务保留独立日志和导出。

明文 CCTV 线路检查只抓取有限层数的 HLS 清单，不下载 TS 来判断文本；清单最大 256 KiB，网络限时、切台可取消、完整地址作为短时缓存键。旧探测必须同时匹配播放代次、频道和线路。识别明文仅决定 AVPlayer 路径，不视为完成视频解码。

## 可复现检查

```sh
cd cctv-ios-host
(cd JSPlugins && npm ci --no-audit --no-fund && npm run build && npm test)
python3 -m unittest discover -s Tests -p 'test_*.py' -v
CCTVHOST_SAMPLE_DIR=/path/to/attachments CCTVHOST_NODE_BINARY=/path/to/node \
  python3 -m unittest Tests.test_imported_samples -v
```

附件测试不把第三方源码写入仓库。四个原文件集成用例在 Linux / Node 18.20.4 --jitless 实际通过，覆盖表中七份文件。通用 Node 无 WASM 测试也在 Node 22.23.4 执行通过。Foundation 的路径迁移、真实导入器、HLS 探测测试及 iOS 构建由 macOS CI 验证；真实 iPhone 的内存压力、SDK/AVPlayer 解码、后台持续播放仍需设备验收。
