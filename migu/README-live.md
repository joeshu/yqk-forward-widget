# 咪咕动态服务 0.2.0

下载 [migu-live-v0.2.0.py](https://raw.githubusercontent.com/joeshu/yqk-forward-widget/main/migu/migu-live-v0.2.0.py)，Python 3.10+，仅需一个文件，不用安装依赖。

```sh
python3 migu-live-v0.2.0.py 18768
```

保持脚本运行，在同一设备的播放器中订阅：

```text
http://127.0.0.1:18768/all.m3u
```

也可以订阅 `/migu.m3u8`。端口可修改；手机 App 中直接运行脚本时默认 18768。`127.0.0.1` 指播放器所在设备，不能指向另一台设备。

## 这一版的变化

0.1.0 默认读取第三方 `52top` 列表；0.2.0 **默认直接使用咪咕官方取源接口**。文件内置 2026-10-19 从官方公开频道接口取得的 123 条频道配置（ID、名称、分组），订阅不需要先下载第三方列表。目录中的固定入口形如 `/live/p608807420.m3u8`；打开频道时获取当前播放地址，不把会过期的地址写死在脚本中。

默认仅监听 `127.0.0.1`，无访问令牌，不创建缓存文件、不申请文件锁，也不依赖当前目录可写。运行环境不支持 SIGTERM 时继续运行，可使用 App 停止按钮。启动失败会显示阶段（例如 `bind`、`data-directory`）、异常类型及系统错误码，避免旧版笼统日志无法定位。

这些修改覆盖了旧版的目录/文件锁/信号兼容隐患；原截图未包含具体异常，不能据此确定原故障唯一原因，也未在用户的 iPhone App 实机验证。App 仍需支持 Python 标准库、线程、本地 HTTP 监听，并允许脚本保持运行；系统或 App 挂起脚本时服务会停止。

## 取源与播放范围

默认使用匿名标清（`rateType=2`），不包含用户账号、共享 token 或会员凭据。接口拒绝地区、登录或会员权限时直接报错，不尝试规避限制。**123 条是官方目录数量，不表示 123 个频道都能匿名播放**。本版未接入会员登录、自动 EPG 更新和官方回看，不在目录中声明回看能力。

当前服务器实测官方目录可访问，播放接口返回 `COPYRIGHT_AREA_INVALID`，服务会显示 `MIGU_REGION_RESTRICTED`。所以这一版未完成当前出口的成功媒体播放验收，国内设备上的实际可播性仍需验证。官方协议可能变化，出现 `MIGU_API_FORMAT_CHANGED` / `MIGU_PLAY_URL_FORMAT_CHANGED` 时应更新适配代码。

同频道的同时请求共用一次取源，最多 4 个工作线程、8 个进行中/排队频道；成功地址在内存中缓存 30 秒，失败冷却 5 秒，最多保存 64 个结果。不把过期结果继续当作可用地址，也不批量扫描全部频道。取源请求使用固定 HTTPS 接口、主机和路径限制、有界响应及超时，返回的媒体地址和每次重定向也须通过域名和端口校验。

| 模式 | 参数 | 行为 |
| --- | --- | --- |
| 直连，默认 | 无 | 频道入口返回 302，播放器直接访问咪咕 CDN。 |
| 清单转发 | `--mode manifest` | 读取入口 HLS，按最终响应地址展开相对 URI，保留变体、KEY/MAP、时间线等；视频由播放器访问 CDN。 |

```sh
python3 migu-live-v0.2.0.py 18768 --mode manifest
```

清单转发最多 4 路下载、8 个进行中/排队键；成功缓存 1 秒，失败冷却 3 秒，已完成缓存最多 32 条/8 MiB。每张清单最大 512 KiB。服务不缓存视频分片，不转码，不提供无缝会话迁移；播放中 CDN 会话失效时可能需要重新打开频道。两种模式都会将上游资源 URL 交给播放器。

## 故障定位

浏览器打开 `http://127.0.0.1:18768/status` 查看目录状态和最近错误；目录就绪仅表示内置频道信息可用，`playback_verified: false` 不代表已验证视频解码。

- `Startup failed [bind] ... errno=...`：检查端口占用、App 本地监听权限；尝试其他端口。
- `Startup failed [data-directory] ...`：使用缓存列表或持久化令牌时，指定 App 可写的 `--data-dir`。默认本机官方模式不需要目录。
- `MIGU_REGION_RESTRICTED`：咪咕拒绝当前出口地区。
- `MIGU_LOGIN_OR_MEMBERSHIP_REQUIRED`：当前匿名方式无相应权限。
- `MIGU_API_LOADING` / `MIGU_API_CAPACITY`：当前请求尚未完成或并发已满，可稍后重试。

Ctrl+C 或 SIGTERM 停止；在途请求结束前 Python 可能有短暂退出等待。日志不打印源播放 URL、签名、请求查询或访问令牌。

## 局域网使用

跨设备使用时显式配置地址，自动启用服务访问令牌：

```sh
python3 migu-live-v0.2.0.py 18768 --bind 0.0.0.0 --public-base http://192.168.1.10:18768 --data-dir /可写目录/migu-live
```

日志显示 `access.token` 所在路径，订阅为 `http://192.168.1.10:18768/all.m3u?token=文件中的令牌`。本机也可用 `--require-token`；或用 `--token-env MIGU_ACCESS_TOKEN` 读取明确指定的环境变量（32–128 个 URL 安全字符），不写令牌文件。默认持久化目录为 `~/.cache/migu-live`，仅启用需要持久化的选项时使用。

对外地址不从客户端 Host/X-Forwarded 头推断。免令牌模式限制 Host 和跨站浏览器请求，降低 DNS 重绑定风险。公网应使用 HTTPS 反向代理和访问令牌。不要提交私有缓存目录或播放会话数据。

## 兼容原列表

旧列表方式仅通过显式参数启用：

```sh
python3 migu-live-v0.2.0.py 18768 --source http://www.52top.com.cn:678/downloads/migu.txt --data-dir /可写目录/migu-live
python3 migu-live-v0.2.0.py 18768 --input /路径/已有列表.m3u8 --data-dir /可写目录/migu-live
```

此方式保留原目录校验、EPG 和已有回看模板，依赖目录更新及签名有效期，须有可写私有目录和文件锁。源码中的 `DEFAULT_SOURCE`、`EPG_URLS` 和 `SOURCE_HOSTS` 供这个兼容分支使用，**默认官方模式不会下载这些地址**。

## 开发与验证

模块：`migu/native.py`（内置频道和官方接口）、`migu/service.py`（本地服务）；根目录 `migu-live.py` 是开发入口。发布文件由 `migu/build_service.py` 展开源码生成，没有动态 exec、压缩代码载荷或远程代码加载。版本指纹见 `migu-live-v0.2.0.json`。旧版 0.1.0 保留作历史记录。

参考：[用户提供的 ysp-live v9.5](https://garysclub.sharewithyou.dpdns.org/ysp-live/ysp-live-v9.5.py) 的本地订阅服务结构，以及 [develop202/migu_video](https://github.com/develop202/migu_video) 中公开的咪咕接口字段。没有执行参考项目代码，也未复制账号或设备注册逻辑。频道元数据来源为 `https://program-sc.miguvideo.com/live/v2/tv-data/1ff892f2b5ab4a79be6e25b69d2f5d05` 及其分组接口。

```sh
python3 -m unittest discover -s tests/migu -v
python3 -m unittest discover -s tests/migu_live -v
python3 migu/build_service.py --check
```

验证范围包括 Linux 下的独立文件启动、只读工作目录、文件锁不可用、信号接口不可用、端口冲突诊断、目录订阅，以及取源协议响应、请求合并、缓存过期和上游拒绝。真实网络结果见 [0.2.0 验证记录](live-validation-0.2.0.json)；不代表 iOS 实机或长时间解码验收。
