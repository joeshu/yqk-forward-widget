# AVPlayer / Cicada 与附件 Python 播放适配审计

本轮基于 `joeshu/yqk-forward-widget` 的 `main` 提交
`12e2a1dc6b3afdb4a5b83ad7ee1def5170e1c61b`，范围是宿主播放交接、生命周期、请求头、媒体转发与三个附件 Spider。只修改源码和离线夹具，没有更改闭源播放器二进制，也没有推送远程仓库。

## 发现与修复

| 原问题 | 修改后的行为 | 验证位置 |
| --- | --- | --- |
| AVPlayer 失败切 Cicada 时旧 item、观察者和网络载入仍可能存活 | 清理旧 item/seek/asset 与观察者后再交接，保留可用进度；预取结果校验播放代次 | `MediaPlaybackViewController.m`、route fallback 合同及 UI smoke |
| 首帧单次超时遇到续播弹框或暂停就永久丢失 | 使用可取消监测，只累计实际等待时间；可在继续播放后检测超时 | 同上 |
| 纯音频可能因没有视频首帧而被误判失败；取消预取后迟到结果仍可重建资源 | 加载轨道后确认纯音频，跳过视频首帧等待；跨来源重建预取客户端，取消与内存回收递增预取代次 | 同上 |
| Cicada 暂停、停止和失败后仍有轮询，迟到回调可污染终态 | 停止无效定时器，校验 player 身份及状态；待处理 seek 在取消/销毁时完成一次 | `MediaPlaybackCicadaAdapter.m`、`CicadaAdapterProbe.m` |
| 设置画面比例发生在 SDK player 创建前，设置被丢弃 | 暂存比例，在 prepare 时应用；在 setUrlSource 前安装 delegate | 同上 |
| 超过 100 小时的直播时间又被除以 1000 | 仅按 SDK 返回类型/已知单位转换；节流使用单调时钟，seek/rate 拒绝非有限数 | 同上 |
| 引擎回退直接绕过 loopback 代理，可能丢失 Cookie、清单重写或解密结果 | 一般媒体保留有效播放 URL；仅显式 `dashRemuxed` 允许改回原 DASH | VC route fallback 合同 |
| 失败后按片名自动请求第三方 MacCMS，可能错播 | 移除自动调用入口，保留当前资源的重试与线路回退 | VC route fallback 合同 |
| 同名不同大小写请求头重复，Referer 值含 `$` 时被误拆 | 大小写不敏感覆盖，按最早的冒号/美元符分隔；过滤控制字符和跳转连接头 | `MediaPlaybackHeaders.m`、Python runtime、原生及 Python 行为用例 |
| 部分不支持的格式被标为 Cicada 支持；MIME 空格导致误判 | 收紧能力表并规范化 MIME/format/engine | Headers / DecodeRouter |
| HEAD 重定向变 GET，探测可能下载视频 | 301/302/303/307/308 后仍为 HEAD；跨 origin 去 Cookie/Authorization | `test_relay_transport_regressions.py` |
| 206 响应被去除 TS 前缀或 PNG 解包，Content-Range 与字节不一致 | 范围响应保留原始字节；完整 GET 才应用媒体清洗 | 同上 |
| TLS 失败后自动关闭验证且按主机缓存 | 保持 CA/主机名校验，只有暂时 GET/HEAD 超时可重试；无效证书明确失败 | 同上 |
| PNG 压缩媒体解包可能消耗无界内存，关闭后保留内联密钥/清单 | 解压输出上限 16 MiB，关闭时清理缓存 | 同上 |

## 播放能力与边界

| 输入 | 入口与限制 |
| --- | --- |
| HLS（包括 master、相对分片、密钥、MAP/BYTERANGE）、MP4/MOV、常见音频 | 默认 AVPlayer；必要头通过宿主代理传给子资源；实际可解码编码由 iOS/设备决定 |
| 明文 DASH | 可支持的清单先通过既有 DASH→HLS 桥交 AVPlayer，失败时仍可尝试原 DASH 的 Cicada 路径 |
| FLV、MKV、WebM、3GP、RTMP | Cicada 优先或回退尝试；容器识别不等于其中每种编码都支持 |
| AVI、WMV/ASF、RM/RMVB 等 | 随仓库提供的 Cicada/FFmpeg 二进制没有相应 demuxer；不能靠路由修改获得解码能力 |
| WebM 中的 VP8/VP9/Opus、其他新编码 | 不能把 WebM 容器支持当作这些编码已获 Cicada 支持；需要换 SDK/转码或对应系统能力 |
| 解析网页、DRM/授权媒体 | 需要来源返回有效解析结果及合法密钥/授权；双引擎重试不会自动解决网页验证或授权问题 |

当前路由沿用工程的原生双引擎策略，不自动启动网页播放器。`RequiresWebViewOnly` 是历史命名，其含义是两路引擎能力表之外，不是网页实播承诺。

三个附件的适配版本、配置和导入说明见 [附件适配说明](ATTACHED-PYTHON-PLAYBACK.md)。只使用本机 HTTP 和模拟页面/清单测试，未访问附件内容站点，没有把在线可达性或实际解码标为通过。

## 验证与复现

在 Linux 使用隔离虚拟环境安装 `beautifulsoup4`、`requests`，执行：

```sh
cd cctv-ios-host
python -m unittest discover -s Tests -p 'test_*.py'
cd JSPlugins
npm ci --ignore-scripts
npm run build
npm test
```

最终回归：850 项检查，786 项通过、64 项按平台/运行条件跳过（38.813 秒）；JavaScript 两组测试通过；源码语法/清单扫描无错误，`git diff --check` 通过。原始日志随更新包的 `validation/` 提供。测试同时包含 HTTP 行为、离线 Spider 行为与已有源码合同；源码合同通过不代表 iOS 解码通过。新增 Objective-C 行为断言放入原生 Foundation 测试和现有 JAR smoke 的 SDK 替身探针，须在 macOS CI/模拟器实际运行。

当前环境为 Linux，无 Xcode / Apple SDK / iPhone，因此未执行 iOS 编译、签名或设备播放，没有生成 IPA。性能收益限于删除无效轮询、释放旧载入、避免 HEAD 误下载与内存上限等可解释的改动；没有测量首帧延迟、CPU、耗电或崩溃率，不能声称这些数值已提升。

仓库已有 [Cicada HLS 原生崩溃调查](CICADA-HLS-CRASH-20261110.md) 记录了 SDK 二进制内部空指针。宿主生命周期修复不能证明供应商线程安全问题已解决。发布前应在真机验证连续切集/切线路、后台恢复、暂停后续播、弱网/断网、Range seek、HLS 密钥与分片错误、硬解失败后软解，以及实际 SDK 的 stop/destroy；记录解码回调和画面，不以初始化成功代替首帧成功。
