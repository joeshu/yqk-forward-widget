**看看新闻频道 PHP 网关（wxty）**

基于 [原作者频道](https://t.me/iptvorganization) 提供的 wxty.php 整理。保留原有 API 签名与频道映射，修复 URL/HLS、缓存并发、网络安全和故障回退问题。

这是独立的服务端 PHP 文件，需要部署到 PHP 主机。GitHub Pages 只提供静态文件，不能执行此网关；仓库的 Forward 订阅与 Pages 发布逻辑不变。

**运行**

只需下载并启动 **`wxty.php` 这一个文件**，订阅、频道路由和本地服务启动都在其中，不依赖 `router.php` 或 Composer。启动文件地址：

```text
https://raw.githubusercontent.com/joeshu/yqk-forward-widget/refs/heads/main/wxty/wxty.php
```

要求 PHP 8.2 或更新版本，启用 cURL、OpenSSL 和 JSON；缓存目录必须可写，并放在 Web 根目录外。生产环境使用 Nginx/Apache + PHP-FPM，配置合适的上游超时及访问限流。PHP-FPM 默认可能清理环境变量，需要显式传入下面使用的配置。

本地验证：

```bash
php wxty.php
```

在 IPTV 播放器中添加以下订阅地址，就能导入本脚本支持的全部 8 个频道：

```text
http://127.0.0.1:52451/all.m3u
```

根路径 `/` 也返回同一份订阅。订阅仅列出频道，不会预先请求八个频道的上游；选台播放时才解析相应频道。条目包含频道名和分组，播放链接自动使用本次请求的主机、端口及安装路径，不写死 `127.0.0.1`。

更新已有启动器中的 `wxty.php` 后重启即可，无需再下载其他 PHP 文件。直接执行文件时，默认启动在 `127.0.0.1:52451`；由启动器管理 HTTP 服务时，将请求交给本文件即可处理 `/`、`/all.m3u`、`/wxty.php`。也支持显式命令 `php -S 127.0.0.1:52451 wxty.php`，仍然只使用同一个文件。原 `router.php` 仅作为旧启动命令的兼容包装保留。

直接执行模式使用 PHP 内置 Web 服务；需要 PHP 支持 `pcntl_exec` 或 `proc_open`。若启动器自行提供 HTTP 服务，不需要本文件再创建进程。仅运行 `php -S 127.0.0.1:52451` 且不指定处理脚本时，PHP 无法将不存在的 `/all.m3u` 交给本文件；这时需指定同一个 `wxty.php`，不必添加另一个路由文件。

原有订阅 `http://127.0.0.1:52451/wxty.php?list=1` 继续可用。Nginx/Apache 应将 `/all.m3u` 内部转发到 `/wxty.php?list=1`，并保留原有 PHP 执行配置。

单台播放地址仍是 `http://127.0.0.1:52451/wxty.php?id=wxty`。这里的“全部频道”仅指下表 8 个频道，不包含仓库中其他项目的频道。

手机或电视访问时，可用 `php wxty.php --host=0.0.0.0`，订阅地址中的 `127.0.0.1` 改为服务器的局域网 IP。可用 `--port=52451` 修改端口，`--help` 查看启动参数。反向代理无法直接推导公网前缀时，设置 `KK_PUBLIC_BASE_URL`，例如 `https://tv.example/wxty`；不自动信任客户端提供的 `X-Forwarded-Host/Proto`。

| id | 频道 ID |
| --- | --- |
| dfws | 1 |
| shxwzh | 2 |
| shds | 4 |
| dycj | 5 |
| hhxd | 9 |
| wxty（默认） | 10 |
| mdy | 11 |
| jsrw | 12 |

**播放与兼容性**

- 返回的 HLS 保留主播放列表、码率、外置音轨、字幕、KEY、MAP、BYTERANGE 等信息，将资源引用转成绝对 URL，按重定向后的实际地址计算基址。原有“展开为第一个子列表”的处理已移除。
- 播放器直接访问 CDN。播放器需要能连接到 CDN；服务端 cURL 的 Referer、Origin、UA 不会自动传给播放器的分片请求。
- 原 `?ts_url=...` 分片代理没有被正常播放链路使用，现返回 HTTP 410，不再接受任意 URL 或产生分片磁盘缓存。
- 原版用供体节目的回看地址删除时间参数后尝试直播。为保持现有频道兼容性，默认保留这一转换，仅对 `shift_address` 使用，其他查询字节不变。转换结果必须成功读取有效 HLS 才会缓存；诊断中标记为 `shift-converted`。这不证明内容一定为实时直播，也不能保证签名规则变化后仍有效。设置 `KK_SHIFT_TO_LIVE=0` 可停用这一转换。
- 失败默认返回 HTTP 503、稳定原因代码及 `Retry-After`，不会默认跳到无关节目。确需占位视频时可配置 `KK_FALLBACK_URL`，普通播放失败后返回 302；诊断请求仍返回真实错误。
- `HEAD` 只返回未观测状态，不请求上游、不建缓存，不代表频道已验证可播。

**环境变量**

| 名称 | 默认值及作用 |
| --- | --- |
| `KK_BIND_HOST` | 单文件直接启动时的监听 IP，默认 `127.0.0.1`；可用 `--host` 覆盖 |
| `KK_PORT` | 单文件直接启动时的监听端口，默认 `52451`；可用 `--port` 覆盖 |
| `KK_CACHE_DIR` | 系统临时目录下按脚本路径隔离的目录；部署时建议指定持久化私有目录 |
| `KK_API_VERSION` | `2.42.23`；只在确认上游协议变更时调整 |
| `KK_TIMEOUT` | 20 秒，范围 5–60；HTTP 请求和刷新等待共用的解析预算 |
| `KK_HTTP_TIMEOUT` | 单次 6 秒，范围 1–15；连接超时最多 2 秒 |
| `KK_MAX_REQUESTS` | 一次解析最多 16 次 HTTP 请求，范围 1–40，包含重定向和子列表验证 |
| `KK_MAX_CANDIDATES` | 最多尝试 8 个不同地址，范围 1–20 |
| `KK_SCAN_DAYS` | 最近 7 天，范围 1–7 |
| `KK_SHIFT_TO_LIVE` | `1`；设为 `0` 后不尝试转换回看地址 |
| `KK_MEDIA_HOSTS` | 未设置时允许上游返回的公网 HTTP/HTTPS 目标；可用逗号配置域名白名单。`cdn.example` 只匹配自身，`.cdn.example` 匹配自身和子域名 |
| `KK_CA_BUNDLE` | 可选的可信 CA 文件；TLS 验证始终启用 |
| `KK_PROXY_PREFIX` | 可选受信代理前缀，保留原版 HTTPS URL 前缀转换方式；必须由管理员配置 |
| `KK_ACCESS_TOKEN` | 可选的普通播放 Bearer 令牌；未设置时普通播放公开 |
| `KK_PUBLIC_BASE_URL` | 可选订阅播放链接前缀，如 `http://192.168.1.10:52451`；默认使用请求的协议、Host 和脚本目录，不包含 `wxty.php` 文件名 |
| `KK_ADMIN_TOKEN` | 管理员 Bearer 令牌；未设置时禁止 `info` 和强制刷新 |
| `KK_FALLBACK_URL` | 默认空；可选的 HTTP/HTTPS 占位播放地址 |

白名单只限制网关实际请求的媒体目标，不会将所有客户端直连资源变成代理。请求仅允许 HTTP/HTTPS 的 80/443 端口；拒绝用户信息、控制字符、私网/保留 IP、混合公网私网 DNS 结果，以及 HTTPS 向 HTTP 的重定向。每次重定向重新检查，最多三跳。直连使用 cURL `RESOLVE` 固定已验证的 DNS 地址。

如果配置 `KK_PROXY_PREFIX` 或系统 HTTP/HTTPS 代理，实际连接和远端解析由受信代理执行；cURL 的直连 DNS 固定不能替代理实施访问控制，代理侧也需要相同的目标限制。私有 CA 使用 `KK_CA_BUNDLE` 配置，不能通过关闭证书验证解决。系统 DNS 查询仍受操作系统解析超时影响，应同步检查主机 DNS 配置。

调试或刷新使用请求头传令牌，不把令牌写进 URL：

```bash
curl -H 'Authorization: Bearer YOUR_ADMIN_TOKEN' \
  'http://127.0.0.1:52451/wxty.php?id=wxty&info=1'
curl -H 'Authorization: Bearer YOUR_ADMIN_TOKEN' \
  'http://127.0.0.1:52451/wxty.php?id=wxty&refresh=1'
```

诊断保留候选来源、节目、缓存命中、实际请求次数及有效期，不返回签名 URL。错误日志同样不记录签名 URL、令牌或上游正文。

订阅沿用普通播放的访问控制。设置 `KK_ACCESS_TOKEN` 时，播放器必须在获取订阅和后续频道请求时都发送 Bearer 请求头；生成的播放链接不会包含或泄露令牌。

**缓存和回退**

直播地址仅在解密、地址检查、HLS 验证成功后写入缓存。主列表首次解析时，在同一请求预算内确认至少一条视频子列表有效，同时向播放器保留完整主列表。后续命中缓存仍读取最新列表，不缓存媒体时间线。

直播地址最多缓存 600 秒，并提前 90 秒避开签名过期；无法解析到期时间时采用 210 秒的保守有效期。`volcTime/txTime/wsTime` 按十六进制秒解析，JWT `exp` 只作为缓存寿命提示，不用作授权判断。节目单与节目详情短缓存 30 秒。

独立锁文件合并同频道的冷缓存和并发强制刷新，拿锁后重新检查缓存；内容通过权限 0600 的同目录临时文件原子替换。每分钟机会性清理过期数据，目标最多保留 256 个数据缓存文件；设备 UUID 单独保留，不参与容量淘汰。失败共享 3 秒，429 立即停止并共享 30 秒冷却。等待刷新、API、候选和子播放列表共用预算，强制刷新也不能绕过失败冷却。

RSA 使用 OpenSSL，按公钥实际位数分块，要求每个密文块都成功；不再使用手写 ASN.1/大整数解密。不在客户端擅自修改上游要求的签名算法或公钥。

**验证**

```bash
php -l wxty.php
php tests/run.php
```

回归不调用真实上游，覆盖 RFC URI 解析、特殊网段和域名限制、重定向、HLS 音轨及分片标签、RSA 残块、签名兼容、到期解析、坏候选回退、冷却、鉴权、HEAD、真实多进程刷新，以及真实本地 HTTP 服务上的订阅和路由。单文件验证只将 `wxty.php` 复制到空目录，分别检查默认端口直接启动、自定义端口和以本文件作为请求路由三种方式，保证不依赖仓库的其他 PHP 文件。GitHub Actions 对 PHP 8.2/8.3/8.4 执行同一套测试。实际网络抽样的范围见 [VALIDATION.md](VALIDATION.md)。
