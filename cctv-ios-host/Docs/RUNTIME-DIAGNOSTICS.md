# Runtime diagnostics

运行诊断是按操作记录的 JSONL 事件流，不是计数器。先在“设置 → 运行诊断”开启，复现一次问题后导出 `CCTVHost-运行诊断-*.jsonl`。每条记录独立包含 `session_id` 和 `event_id`；同一条播放、订阅或影视解析流程使用相同的 `correlation_id`，请求与播放器重建还会记录各自的 generation，便于过滤过期回调。

## 播放问题

用 `correlation_id` 过滤相关记录。CCTV / 订阅播放通常依次出现 `channel_selected`、`native_playback_start_requested` 或 `remote_playback_start_requested`、可选的 `playback_readiness_probe_result`，最后是 `playback_first_frame`、`playback_first_frame_ready` 或 `playback_failed`。影视解析通常依次出现 `media_api_started`、`media_api_succeeded` / `media_api_failed`、`episode_resolve_succeeded`、`episode_player_handoff` 和播放器事件。

`player_reports_playing` 只代表 AVPlayer 报告播放状态；`media_item_ready` 代表媒体项已就绪；只有 `playback_first_frame` 或 `playback_first_frame_ready` 才表示检测到视频帧。若停在解析阶段，看对应 `media_api_failed` 的 `failure_stage`、`http_status`、错误域/代码和插件错误字段；若媒体已就绪但没有首帧，查看 `playback_video_frame_timeout`、`player_waiting_to_play` 或 `playback_stalled`，并与同一个操作 ID 下的播放器事件对照。

影视服务 API 事件包含 `operation`、`request_id`、服务端口、耗时、响应状态/大小、结果类型和播放结果形态（是否有地址、解析模式、备选线路数、播放主机及扩展名）。`arguments` 和响应正文不会写入诊断文件。插件返回结构化错误时会记录 `plugin_error_code`、脱敏后的 `plugin_error_message` 和可重试标志。

## 服务与订阅问题

服务状态按阶段区分：`service_start_accepted` 只表示宿主接受了启动请求；`python_script_entry_started` 表示 Python 线程已进入脚本；`python_runtime_background_work_active` 表示脚本返回时仍有后台工作；HTTP 健康检查通过才会出现 `local_service_health_ready` / `playback_readiness_probe_result`。Python 运行异常、意外退出和确认停止分别记录为 `python_runtime_failed`、`python_runtime_exited_unexpectedly` 和 `python_runtime_stopped`。

Python 还会在每个关键执行阶段同步写入最近运行标记，包含服务 ID、脚本文件名、阶段、端口和进程内存快照。若下次启动发现上次进程仍留有活动标记，会记录 `python_session_interrupted`，并在对应脚本的独立日志中追加中断提示，据此定位当时运行的是哪个脚本、停在哪一阶段。该事件只说明上个进程没有完成服务清理；iOS 也可能因后台回收而结束 App，不能单凭它判定为崩溃。未捕获的 Python 后台线程异常会记录 `python_background_thread_exception`，包含服务 ID、线程名、异常类型、源文件行号和脱敏错误文本，完整 traceback 会写入该服务独立日志。

Python 插件的 HTTP 响应体受每响应 16 MiB 上限保护；每个服务最多 4 个 HTTP handler，全宿主最多 12 个 handler，同时最多 2 个/服务、8 个/宿主执行大响应读取。超限或读取并发预算耗尽会在插件日志和诊断文件中记录 `python_http_response_rejected`，并让该 HTTP 请求失败，避免多个完整媒体分片同时无限占用内存。低于上限的普通响应可继续读取；读取并发预算耗尽时该次请求会快速失败并记录原因。HTTP handler 并发预算耗尽会记录 `python_http_worker_rejected`，便于区分响应体超限与请求处理能力耗尽。

Node 与 JavaScriptCore 的调用会以 `plugin_bridge_started` 及 `plugin_bridge_succeeded` / `plugin_bridge_failed` 成对记录，包含服务 ID、引擎、操作名、耗时、响应大小和失败阶段，不包含脚本源码或请求正文。`failure_stage` 能区分桥接异常、空/非法响应和插件返回业务错误。

服务健康检查事件包含 `probe_id`、尝试次数、最后 HTTP 状态、响应字节数、内容类型、错误域/代码及失败类型。`process_failed` 表示宿主发现进程退出；`network_error` / `http_status` 表示探测请求没有通过；`invalid_health_response` 表示 HTTP 200 但健康 JSON 不符合约定；`probe_timeout` 表示在截止时间内没有就绪。

HTTP 订阅事件使用相同的 `correlation_id` 串起开始、健康检查与结果。失败阶段可区分网络/超时、HTTP 状态、响应过大、空响应、非法 UTF-8 和“内容有效但没有解析出频道”；记录还包括响应 MIME 类型、耗时、字节数和频道数。导入文本只记录输入字节数和解析出的频道数，不记录文本内容。

## 隐私与解释限制

日志不记录原始播放地址、绝对路径、查询参数、Cookie、令牌、请求参数或响应正文；Python 崩溃标记只保留脚本文件名，不保存脚本路径或源码。来源只保留协议、主机、端口、扩展名和路径指纹，用于区分/关联来源。错误文本经过脱敏并截断；日志文件有 1 MiB 上限。关闭诊断后停止新增记录，已有日志仍可导出。

Python 脚本与 CCTVHost 共享 App 进程。Python 级异常能被记录，但原生扩展触发的进程级崩溃无法由同一进程安全捕获；遇到此类情况，应将 `python_session_interrupted` 的阶段与系统生成的 `.ips` 崩溃栈对照。

这些事件说明应用代码观察到的网络响应、服务状态和播放器回调，不代表服务内容一定可播，也不代表 AVPlayer 报告播放中就已经解码。真机复现时应开启诊断、记录问题发生时间、只复现一次并尽快导出日志，避免日志滚动覆盖关联事件。
