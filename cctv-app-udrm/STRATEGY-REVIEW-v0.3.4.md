# 附件策略对照与0.3.4实现

本轮参考用户提供的两份附件的调度与缓存策略，独立实现适合现有标准库/APTV运行环境的改动；未嵌入其大段引擎、协议或设备身份代码。

## 观察和取舍

| 附件位置/机制 | 本项目处理 |
| --- | --- |
| Python `coalesce_refresh`：同频道Event合并刷新 | 已有每路Future复用；补充删除已完成任务，取消过时且未开始的刷新任务，拒绝继续排队已切走频道 |
| Python `http_workers` / `http_queue_limit`：有界工作与排队 | 本地HTTP改为最多12个客户线程，系统监听队列16；超过并发限额立即503及Retry-After:1，不新建工作线程；连接读写超时15秒 |
| Python stale-while-refresh、失败冷却 | 保留已校验且仍新鲜的清单；现有3/6/12/24/30秒重试退避和自动路线冷却继续使用，不扩大直播陈旧窗口 |
| JS `httpsAgent` / `httpAgent` keepAlive和socket上限 | 不直接移植Node Agent；当前urllib不因此获得连接池，本轮不声称减少TLS握手 |
| JS `playlistCache` 30秒 | 本项目直播窗口约12秒，不能直接套用30秒缓存；继续按target时长更新、超过新鲜度则重建 |
| JS Node运行时和内嵌大引擎 | 不引入Node及第二套引擎，保持单文件Python+系统JSC |
| Python初始化失败时的1080p回退 | 本轮保持既定高清选择上限，不引入自动降档 |

## 改动边界

最多12个HTTP客户线程不等于全进程只有12线程；SDK、EPG、下载和刷新池仍独立。系统监听backlog16也不是Python内存中的请求任务队列。超过限额会短暂503，需要播放器重试；同时打开大量频道不保证都有容量。

取消仅对尚未开始的Future生效。已运行任务继续通过已有选择检查退出，底层正在等待的网络调用可能持续至超时；没有声称强制终止socket。SDK单会话、每路分片、线路自切、EPG及高清设置均保留。状态新增 `http_resources` 与 `scheduling.obsolete_queued_cancelled`。

## 附件摘要

- `2-ysp-engine.js` SHA-256: `264fbf0da60918f3ccc4c6de127b9330ab43f5d8946829fea04627fe84f3bf78`
- `1-ysp-live-v9.5.py` SHA-256: `caf2a2221c6fc25e6f854e3c5a312b4c385a44b0b37698249c8bcf20794aacbb`
