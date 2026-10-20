# 咪咕单文件服务 0.7.1

下载 [migu-live-v0.7.1.py](https://raw.githubusercontent.com/joeshu/yqk-forward-widget/main/migu/migu-live-v0.7.1.py)，或更新根目录 [migu-live.py](https://raw.githubusercontent.com/joeshu/yqk-forward-widget/main/migu-live.py)。Python 3.10+，仅需一个文件，无 pip、Node 或项目目录依赖。

**0.7.0 保留默认的列表安全转发，并新增与公开参考实现对齐的 `--provider android` 客户端兼容模式。** 默认仍先读取实时上游 `migu.txt`，不可用、过期或校验失败时回退仓库中最近一次通过校验的快照；进程内用 `ETag` / `If-None-Match` 条件刷新，不把签名 URL 写入磁盘。`android` 模式按公开参考实现请求咪咕 playurl 接口、补 `ddCalcu` 与 `sv/ct` 后缀，支持游客或自己的账号（`MIGU_USER_ID` / `MIGU_USER_TOKEN`）；上游返回什么地区和权益，就如实返回什么，不做改区、换出口或会员伪装。

```sh
python3 migu-live.py 18768
```

手机 App 直接运行时默认端口也是 18768，日志显示 `provider=published-list`。保持运行，在同一设备播放器订阅：

```text
http://127.0.0.1:18768/all.m3u
```

`/migu.m3u8` 是目录别名。App 挂起脚本或停止运行时，本地服务也会停止。

## 默认列表播放路径

实时列表含已签发的频道 URL，服务不解码、重排或本地续签其中的查询参数。首次订阅时加载目录，以 `ProgramID` 导出稳定的本地频道键；之后播放器访问固定本地入口，服务返回原始签名地址的 `302`。因此上游刷新签名或更新显示名后，播放器订阅地址不变。

默认源优先级：

1. 实时原始列表 `http://www.52top.com.cn:678/downloads/migu.txt`；
2. 仓库中最近一次校验通过的 `migu.m3u8` 快照（仅当实时源网络失败、过期或验证失败时使用）。

每次刷新都受频道数量、签名时间、频道保留率、可信域名/端口和重定向边界约束；保留有效内存快照并合并并发刷新。单文件在进程内保存来源 `ETag`，下一次刷新发送 `If-None-Match`；收到 `304` 时只复用仍通过完整校验的内存快照，不下载重复列表、不落盘签名 URL。默认不调用匿名咪咕 API，也不因为刷新失败返回未校验的新地址。

## 可选 Android 客户端兼容模式

`--provider android` 按公开参考实现 [`akiralereal/iptv` 的咪咕模块](https://github.com/akiralereal/iptv/tree/main/extractors/migu) 对齐实现，代码位于 `migu/android.py`：

- 请求 `https://play.miguvideo.com/playurl/v1/play/playurl`，参数顺序为 `sign`、`rateType`、`contId`、`timestamp`、`salt`、`flvEnable`、`super4k`，随后按开关追加 `h265N`、`4kvivid/2Kvivid/vivid`；
- 现代档位使用 `AppVersion 26000370` 与固定 `salt=1230024`；标清（`rateType=2`）走旧版 `2600034600` 与随机 8 位 salt；
- 返回地址按参考规则补 `ddCalcu` 与 `&sv=10004&ct=android`，`puData` 逐字符处理，不做 URL 重编码；
- `TIPS_NEED_MEMBER` 时按参考降一档重试一次，其次再降到高清；地区或版权拒绝如实上报，不重试、不改参数；
- 同一频道成功缓存 3 小时、失败缓存 1 分钟，同频道并发合并，60 秒内超过 30 次解析返回 `MIGU_RESOLVE_BURST_LIMIT`，避免播放器批量扫描打到上游；
- 默认“客户端就近取流”，把 GSLB 地址直接交给播放器，由观看设备选 CDN。

可选配置：

```sh
MIGU_USER_ID=你的账号 MIGU_USER_TOKEN=你的令牌 MIGU_RATE_TYPE=3 \
python3 migu-live.py 18768 --provider android
```

`MIGU_RATE_TYPE` 支持 2/3/4/7/8/9；`MIGU_HDR=0`、`MIGU_H265=0`、`MIGU_CLIENT_DISPATCH=0` 可关闭对应行为。凭据只进请求头，不会出现在订阅地址、状态或日志中；账号失效、会员不足、地区限制都按上游真实结果返回。

2026-10-20 在本机网络实测该模式：请求按上述格式发出，上游返回 `rid=BLACK_APP_OR_TERMINAL`（映射为 `MIGU_TERMINAL_BLOCKED`），即咪咕拒绝当前声明的客户端/终端标识。CCTV1、CCTV3、东方卫视均返回同一 rid，说明是**客户端标识/出口层面**的整体拒绝，不是单个频道问题；CCTV5 另返回 `WUDALIANSAI_FUFEI_VERSION_UPGRADE`（映射为 `MIGU_CLIENT_VERSION_UPGRADE_REQUIRED`），属于上游要求客户端版本升级。

可用的兼容项（默认值即上表；应填**你自己设备上官方商店版本**的真实值）：

```sh
MIGU_APP_VERSION=你的客户端版本号 \
MIGU_APP_CODE=miguvideo_default_android \
MIGU_CLIENT_CHANNEL_ID=你的客户端渠道标识 \
python3 migu-live.py 18768 --provider android
```

这三项只用于让请求与你实际安装的官方客户端一致，不用于伪造成其他终端去换取放行；服务不会自动轮换标识试探。若改用自己网络与自有账号后仍返回 `BLACK_APP_OR_TERMINAL`，说明该出站网络或该客户端未被上游允许，应回到默认列表模式。是否可播需在你自己的网络与合法账号环境下验证。

## 那条列表 URL 说明了什么

对列表中任一地址（`puData` + `ddCalcu` + `timestamp` + `ProgramID`）做离线复算，可判定它由哪套客户端规则签发。本次实测：

```text
urls: 115
legacy_rule_matches: 115
modern_rule_matches: 0
client_id_families: ['0116_2600000900']
app_codes: ['miguvideo_android']
```

也就是说，列表里的地址全部由 **`2600000900` 系列旧版客户端规则**签发，与本项目 `--provider native` 使用的规则一致；`--provider android` 使用的 `26000370` 现代标识与它不同，因此被上游以 `BLACK_APP_OR_TERMINAL` 拒绝。

由此可得出两点：

1. 项目对这类 URL 的算法复现是正确的（115/115 匹配），问题不在 `ddCalcu` 实现；
2. 列表能播是因为**发布者的出口、会话与账号已在签发时通过上游校验**，本项目复算只能验证结构，不能凭空获得同样的放行。

离线核验单条或整份列表（不联网、不打印签名值）：

```sh
python3 -m migu.verify_url '<播放地址>'
python3 -m migu.verify_url --file migu.m3u8
```

若确实要让 `--provider android` 与列表使用同一客户端家族，可显式对齐标识（仍需你的出口与账号被上游放行）：

```sh
MIGU_APP_VERSION=2600000900 \
MIGU_CLIENT_CHANNEL_ID=0116_2600000900-99000-201600010010027 \
MIGU_APP_CODE=miguvideo_android \
python3 migu-live.py 18768 --provider android
```

### 方式 B 实测结果（0.7.1）

把内置客户端渠道标识也对齐列表后，本机上游响应从地区拒绝变为正常签发：

```text
rid=SUCCESS  code=200  has_play_url=True  authResult=FAIL(guest)  rateType=2
```

`--provider native` 此前会因 `authResult=FAIL` 直接丢弃这个可播地址；本版已按参考实现修正：**只要返回了播放地址就转发**，仅在“授权失败且没有地址”时才报 `MIGU_AUTHORIZATION_REJECTED`。四个抽样频道（CCTV1、CCTV3、东方卫视、CCTV5）均能取得地址。

本地服务实测：`/live/p608807420.m3u8` 返回 `302`，目标为咪咕 GSLB，再由 GSLB 跳 `bofang.miguvideo.net.cn`。本沙箱环境解析该调度域为 IPv6 私网/代理地址，无法完成第二跳；官方 App 通常可达。因此**能否出画面取决于你运行服务的网络**，代码侧链路已通。

启动命令（可与列表模式共存）：

```sh
MIGU_APP_VERSION=2600000900 \
MIGU_CLIENT_CHANNEL_ID=0116_2600000900-99000-201600010010027 \
MIGU_APP_CODE=miguvideo_android \
python3 migu-live.py 18768 --provider native
```

`MIGU_APP_VERSION`、`MIGU_CLIENT_CHANNEL_ID`、`MIGU_APP_CODE` 同时被 `--provider native` 与 `--provider android` 读取；填你自己环境的值，不要用于伪造成其他终端换取放行。

## 可选原生 API 实验路径

文件内置 123 个频道的 ProgramID、名称和分组。使用 `--provider native` 时，服务按频道 ID 和当前时间计算 API 请求签名、向固定 HTTPS 端点请求地址，并检查地区及账号授权后返回上游地址。该路径可配置自己的账号，但当前服务器验证记录为 `COPYRIGHT_AREA_INVALID`，未完成成功验播；它不应替代默认列表路径。

## 本轮取源研究结论

原列表地址的客户端标识为 `2600000900` 系列，不是之前默认使用的 `2600037000` 系列。公开的[旧版参考实现](https://kaniptv.com/forum.php?mod=viewthread&page=4&tid=433)给出了候选 API 请求参数与地址校验规则。没有执行该 PHP 程序，也没有沿用它关闭 TLS 校验、永久缓存地址或只做 HEAD 验证的做法。

对公开原列表的 117 条地址，直接调用本版 `native_proof()` 全部重算一致：`puData` 首尾交错，在四个位置加入 `e`、URL 中 `timestamp` 的第 7 个字符、`ProgramID` 的第 3 个字符、`0`（均按人类从 1 开始计数）。奇数长度保留中间字符一次；计算使用签发 URL 自身时间，避免跨午夜后本机日期变化导致校验错误。服务运行时不需要读取列表来计算这些值。

本版采用公开参考的旧版请求签名参数。服务器上该候选接口的画质 2、3 请求都返回 `COPYRIGHT_AREA_INVALID`，没有媒体 URL；生产函数的实测结果记录在 `live-validation-0.6.1.json`。这只证明当前网络未获播放地址，既不能证明签名已被接口接受，也不能证明接口在用户设备上必定可用。未做 IP 伪造或忽略授权错误。

## 顶部授权与协议配置

生成的单文件最上方就是 `NATIVE_SETTINGS`，无需寻找分散的代码。修改配置后停止并重启脚本。

| 字段 | 用途 |
| --- | --- |
| `app_version`、`client_channel` | 已实现的旧版客户端信息，必须与请求签名方案配套 |
| `sign_salt`、`sign_suffix` | 请求签名参数，签名仍按当前实现的两次 MD5 规则计算 |
| `user_id`、`user_token` | 自己账号的一对授权字段，默认均为空 |
| `rate_type` | 默认请求 3，旧版广东卫视使用 2；实际画质与授权仍由上游决定 |
| `dd_keys`、`dd_anonymous_word`、`dd_timestamp_index`、`dd_program_index`、`dd_tail` | 播放地址校验参数；默认匹配原始列表的旧版规则 |
| `dd_suffix`、`app_code` | 默认空，不强加新客户端的 URL 后缀或 appCode 请求头 |

支持直接编辑本地文件中的两个账号字段；请不要将填写后的文件提交到公开仓库。也可通过 `MIGU_USER_ID` / `MIGU_USER_TOKEN` 环境变量覆盖它们，避免凭据留在脚本内。服务访问令牌 `--token-env` 用于保护本地 HTTP 服务，与咪咕账号授权不同。

账号字段只发送到固定咪咕 API 的请求头，不加入订阅 URL。配置检查会拒绝单边凭据、非法控制字符、错误类型或未知字段；状态和诊断只显示是否配置账号，不显示 ID、令牌或签名密钥。配置账号不代表已验证有效、具有会员权益或能解除地区限制；上游明确拒绝时停止，不返回拒绝响应中的播放地址。

这个配置区方便维护**当前已实现协议**。如果以后仅参数变动，可以集中替换；如果接口、签名算法或授权流程变化，仍需修改取源适配代码，不能保证只换一项就恢复。原始列表的 `ddCalcu` 规则现已逐条匹配，但生成端没有公开；上游 API 请求所用授权及运行网络尚未确认，不能把校验算法匹配等同于完整取源成功。研究依据见 [source-research.md](source-research.md)。

## 保留的性能改进

取源、清单和节目单下载各自支持 8 路工作任务，实际出站网络请求再由一个总上限为 **8 路** 的传输池约束；不会叠加成 24 路连接。请求排队时间也计入超时预算。空闲线程阻塞等待任务，不周期性唤醒轮询。

节目单优先补齐缺失频道，然后更新过期数据；连续失败或空结果依次冷却 15 分钟、30 分钟、1 小时，最长 6 小时，成功后重置。已有未过期频道不重复下载。

## 可选的重启缓存

默认仍是内存模式。启用持久化：

```sh
python3 migu-live.py 18768 --epg-cache
```

默认写入 `~/.cache/migu-live/epg-cache-v1.json`，也可以用 `--data-dir /App可写目录/migu-live` 指定目录。手机 App 支持启动参数时填入 `--epg-cache`；不提供参数也能照常使用内存模式。

缓存只包含节目、频道、更新时间和重试状态，不保存播放签名或账号。文件以私有权限、临时文件加原子替换方式写入；数据未变化不重写，更新过程最多约每 30 秒保存一次进度，完成时再保存。重启先读取仍有效的节目，同时只补缺失或过期频道；过期、损坏或符号链接缓存不会作为有效节目使用。

缓存目录不可写或写入失败时自动继续使用内存，状态中显示 `storage`、`cache_error`，不因节目缓存失败退出。显式要求持久化服务访问令牌时，令牌目录仍必须可写。

## 完整请求预算

从提交网络任务开始计算排队、连接、TLS、重定向、响应头及响应体的总等待时间；超过预算不会接受晚到结果。连接建立后的慢响应头、慢响应体会由截止时间监控关闭套接字。系统 DNS 解析不能被 Python 安全强制终止，极端情况下其后台任务可能继续到系统超时，但播放器等待时间仍受预算限制，后台线程总数也有上限。

## 节目单

订阅头自动声明本地 XMLTV 地址：

```text
http://127.0.0.1:18768/epg.xml
```

支持 `x-tvg-url` 的播放器可自动发现；其他播放器可将上面地址手动填入节目单设置。目录中的 `tvg-id` 优先使用稳定的 `p<咪咕频道ID>`，对应 XMLTV 相同 ID；极少数没有 ProgramID 的条目使用名称摘要，可能没有对应节目单。节目单目前仍按内置官方频道集合获取，列表新增或更换频道 ID 时可能出现节目单缺失，不保证全覆盖。中文、特殊字符和北京时间 `+0800` 由 XML 序列化与时区转换处理。

节目数据直接来自咪咕官方当天节目接口，**没有使用旧的 GitHub XML 镜像**：核查时那些镜像仍是 2026 年 8 月数据。每日日期按北京时间计算，跨零点会重新获取当天节目。节目预告只表示播出安排，不代表当前账号有播放权限，也不启用回看。

首次访问 `/epg.xml` 才启动后台获取，每批最多 8 个频道，首次最多等待 5 秒，然后返回当前已有的有效节目；未取得有效数据时返回 503，可稍后重试。第一轮可能需要约 1–2 分钟，期间已加载的节目可先使用。**首次导入后若节目不全，稍后在播放器里刷新节目单**；播放器是否自动重复下载由其自身设置决定。

- 有效频道数据在内存中缓存 6 小时；失败或空结果使用从 15 分钟到 6 小时的递增冷却，不反复请求所有频道。
- 每轮刷新最多 2 分钟，并发上限 8；未完成的频道会在后续请求触发的刷新中继续补齐。
- 更新中可使用尚未结束、缓存年龄不超过 36 小时的上一版节目；已过期节目不会冒充当前节目。没有有效节目时不生成占位节目。
- `/diag`、`/status` 的 `epg` 字段显示实际节目条数、已匹配频道数、缺少节目的频道、更新中状态及错误。目录数量以发布列表为准，不承诺每个频道都有官方节目单。
- 节目单更新独立于直播取源，更新失败不阻断 `/all.m3u` 或直播入口。

禁用节目单：

```sh
python3 migu-live.py 18768 --no-epg
```

## 本版精简和手机运行改进

本机默认仅监听 `127.0.0.1`，无需服务访问令牌；不启用 `--epg-cache` 时不写运行文件。带签名播放地址只在运行内存中保存，不提交或另写源目录缓存，不依赖文件锁；持久化选项只缓存节目单数据。内置频道目录启动即可使用，节目单首次请求时独立加载，无定时全频道播放扫描。

启动日志显示版本、Python 版本、平台、主线程状态、频道数，以及订阅和诊断地址。`/diag` 保存最近 120 条脱敏诊断，重复代码 15 秒内合并；常见地区限制、网络和节目单错误带中文说明。日志不记录请求查询、访问令牌、原始接口响应或播放签名。

后台任务使用有界的守护线程与队列；停止时取消排队任务，关闭监听和仍在处理的客户端连接。已经发出的网络请求可能继续运行到其超时，但不会阻止独立进程退出；宿主 App 保留解释器时，旧请求可能短暂留在后台。信号接口不可用时不接管宿主信号，可以使用 App 的停止按钮。

## 直播行为和限制

默认列表模式的频道、清晰度和可用性取决于上游已签发地址；每次目录刷新优先拉取实时原始列表，失败时才使用仓库快照。原生模式使用内置频道、默认匿名请求 `rateType=3`，可通过 `--provider native` 显式启用并配置自己的账号及请求画质；它当前没有成功验播记录。本服务不注册设备、不自动申请账号或会员权限，也不尝试伪造或延长第三方播放签名。

原生模式同频道请求合并，成功地址缓存 30 秒、失败冷却 5 秒，最多 64 条；列表模式则统一共享一份频道目录，不为每个频道分别下载整份列表。媒体和 API 地址限制主机、端口、路径、重定向及响应大小；保留系统代理和 TLS 校验。

| 模式 | 参数 | 行为 |
| --- | --- | --- |
| 直连，默认 | 无 | 固定频道入口返回 302，播放器访问咪咕 CDN。 |
| 清单转发 | `--mode manifest` | 读取入口 HLS，按最终响应地址展开相对 URI，保留变体、KEY/MAP 和时间线；视频由播放器访问 CDN。 |

服务不下载视频分片、不转码，也不提供无缝会话迁移；CDN 会话过期后可能需要重新打开频道。清单模式最多 8 路下载、8 个进行中/排队键，成功缓存 1 秒、失败冷却 3 秒，已完成缓存最多 32 条/8 MiB；每张清单最多 512 KiB。客户端并发上限 32。

## 诊断和局域网使用

```text
http://127.0.0.1:18768/diag
http://127.0.0.1:18768/status
```

`process_up`、频道目录和节目单就绪不代表视频已经解码；状态中的 `playback_verified: false` 明确保留这个区别。当前服务器直播取源曾返回地区限制，iPhone 实机与长时间播放尚未验收。

跨设备使用需要明确配置地址，并自动启用服务访问令牌：

```sh
python3 migu-live.py 18768 --bind 0.0.0.0 --public-base http://192.168.1.10:18768 --data-dir /可写目录/migu-live
```

日志显示 `access.token` 路径；订阅为 `http://192.168.1.10:18768/all.m3u?token=文件中的令牌`。节目单地址会自动携带同一访问令牌，节目单、状态、诊断、直播接口均受相同检查。

也可使用 `--require-token` 强制本机鉴权，或 `--token-env MIGU_ACCESS_TOKEN` 从指定环境变量读取 32–128 个 URL 安全字符。持久化访问令牌或节目单缓存时需要可写目录，默认 `~/.cache/migu-live`；本机默认仍是纯内存模式。免令牌模式限制 Host 和跨站请求；对外地址不从 Host/Forwarded 头推断。公网部署应使用 HTTPS 反向代理与访问令牌。

## 开发和验证

源模块：`migu/core.py`、`migu/workers.py`、`migu/native.py`、`migu/source.py`、`migu/epg.py`、`migu/service.py`。构建器将这些源码展开为可审阅单文件，并生成 SHA-256 指纹；没有动态 exec、压缩代码载荷或远程代码加载。

```sh
python3 -m unittest discover -s tests/migu -v
python3 -m unittest discover -s tests/migu_live -v
python3 migu/build_service.py --check
```

测试覆盖缓存重启复用、损坏/不可写回退、递增退避、8 路并发和慢响应头/体的截止时间，也包括当前 HTTP 权限、节目单转换、部分更新、失败和日期切换、线程/队列上限、停止与原端口重启，以及历史发布的兼容回归。原生请求结果见 [0.6.1 验证记录](live-validation-0.6.1.json)，历史列表模式结果见 [0.5.0 验证记录](live-validation-0.5.0.json)。Linux 下的测试不能代替用户 App 的实机验证。

参考：用户提供的 [YSP v9.5](https://garysclub.sharewithyou.dpdns.org/ysp-live/ysp-live-v9.5.py) 的启动与诊断方式，以及 [develop202/migu_video](https://github.com/develop202/migu_video) 中公开的咪咕接口字段；没有执行它们的代码或复制账号/设备注册流程。节目单使用固定 HTTPS 接口 `https://program-sc.miguvideo.com/live/v2/tv-programs-data/<频道ID>/<北京时间日期>`。


0.5.0 网络抽样通过独立根目录脚本的 HTTP 入口，检查了 CCTV1、CCTV2、CCTV13 的 302、媒体清单和首个视频分片，并用验证环境中的 FFmpeg 成功解码首帧（抽样的是首个 H.264 480p 变体，不代表最高画质或全频道）。FFmpeg 仅用于开发验收，不是运行脚本的依赖；正常服务仍不下载视频分片。临时媒体已删除，没有上传到仓库。未完成 iPhone 实机、长时间播放或回看验收。
