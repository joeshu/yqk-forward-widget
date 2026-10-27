# Runtime diagnostics

运行诊断是按操作记录的 JSONL 事件流，不是计数器。先在“设置 → 运行诊断模式”开启，复现一次问题后进入“运行诊断记录”。每次 App 运行单独保存一个 JSONL，可从列表打开、单独导出或删除；也可清空全部记录。每条记录独立包含 `session_id` 和 `event_id`；同一条播放、订阅或影视解析流程使用相同的 `correlation_id`，请求与播放器重建还会记录各自的 generation，便于过滤过期回调。旧版混合 `runtime-debug.jsonl` 会按行内 `session_id` 拆分为会话文件，所有拆分文件写入成功后才删除旧文件；无法识别的行保留在单独的旧记录中。

## 播放问题

用 `correlation_id` 过滤相关记录。CCTV / 订阅播放通常依次出现 `channel_selected`、`native_playback_start_requested` 或 `remote_playback_start_requested`、可选的 `playback_readiness_probe_result`，最后是 `playback_first_frame`、`playback_first_frame_ready` 或 `playback_failed`。影视解析通常依次出现 `media_api_started`、`media_api_succeeded` / `media_api_failed`、`episode_resolve_succeeded`、`episode_player_handoff` 和播放器事件。

`player_reports_playing` 只代表 AVPlayer 报告播放状态；`media_item_ready` 代表媒体项已就绪；只有 `playback_first_frame` 或 `playback_first_frame_ready` 才表示检测到视频帧。若停在解析阶段，看对应 `media_api_failed` 的 `failure_stage`、`http_status`、错误域/代码和插件错误字段；若媒体已就绪但没有首帧，查看 `playback_video_frame_timeout`、`player_waiting_to_play` 或 `playback_stalled`，并与同一个操作 ID 下的播放器事件对照。

影视浏览会把首页、分类/搜索、详情、线路/选集和播放地址解析分阶段记录。`media_home_request_started`、`media_listing_request_started` 和 `media_detail_request_started` 可用来判断请求有没有发出；对应的 `*_readable` / `media_listing_result_applied` 表示真实内容已交给页面；`*_failed` 和 `*_response_discarded` 用来区分请求失败与过期回调被丢弃。缓存事件记录命中、是否过期和项目数量；搜索只记关键词长度，不记录搜索文本。详情和选集事件记录线路/集数、所选索引及结果结构，不记录影片名称或内容 ID。

播放地址解析事件额外记录 `result_has_media_url` 布尔值、解析模式和备选线路数。`episode_resolve_succeeded` 只表示插件返回了可交给播放器的结果；不能据此认定 AVPlayer 已收到媒体数据。用户重试、切线路和卡顿恢复会记录来源、匹配到同一集的结果及恢复决策。`playback_stall_recovery_skipped` 中的原因能区分播放已自行恢复、播放器已不再等待、恢复次数到限或已有解析正在执行。

AVPlayer 提供访问日志时，首帧、等待、卡顿和失败事件会附带媒体请求数、传输字节、卡顿数、丢帧数、可用码率/启动时间和视频呈现尺寸；失败事件还会尽量记录播放器错误日志中的上游状态码、媒体请求主机和底层错误域/代码链。请求头只记录总数，以及 User-Agent、Referer、Origin、Cookie/Authorization 是否存在，不包含头名称列表或头值。iOS 未提供的字段会省略。它们描述系统报告的播放会话，不能替代实际画面检查。海报加载失败会单独记录 HTTP 状态、MIME 类型、已收/预期字节、耗时和失败阶段（HTTP、体积超限、网络、空响应或图像解码），便于区分图片源故障与影片目录/播放故障。

影视服务 API 事件包含 `operation`、`request_id`、服务端口、耗时、响应状态/大小、结果类型和播放结果形态（是否有地址、解析模式、备选线路数、播放主机及扩展名）。`arguments` 和响应正文不会写入诊断文件。插件返回结构化错误时会记录 `plugin_error_code`、脱敏后的 `plugin_error_message` 和可重试标志。

## 服务与订阅问题

服务状态按阶段区分：`service_start_accepted` 只表示宿主接受了启动请求；`python_script_entry_started` 表示 Python 线程已进入脚本；`python_runtime_background_work_active` 表示脚本返回时仍有后台工作；HTTP 健康检查通过才会出现 `local_service_health_ready` / `playback_readiness_probe_result`。Python 运行异常、意外退出和确认停止分别记录为 `python_runtime_failed`、`python_runtime_exited_unexpectedly` 和 `python_runtime_stopped`。

Python 还会在每个关键执行阶段同步写入最近运行标记，包含服务 ID、脚本文件名、阶段、端口和进程内存快照。若下次启动发现上次进程仍留有活动标记，会记录 `python_session_interrupted`，并在对应脚本的独立日志中追加中断提示。事件同时带有 `previous_app_session_state`：`closed` 表示上次 App 的关闭标记已写入、但 Python 服务仍被标为活动；`unclosed` 表示上次 App 没有正常关闭标记；`unknown` 表示无法判断。三种情况都只说明 Python 服务没有完成清理，只有 `unclosed` 才进一步支持“进程非正常结束”的判断，仍不能单凭它判定为崩溃。未捕获的 Python 后台线程异常会记录 `python_background_thread_exception`，包含服务 ID、线程名、异常类型、源文件行号和脱敏错误文本，完整 traceback 会写入该服务独立日志。

`previous_session_unclosed` 表示上次应用没有留下关闭标记，可能由崩溃、系统回收、强制关闭或设备重启造成，不是崩溃报告。`app_will_terminate` 表示系统调用了终止回调；其后的 `app_session_closed.session_marker_closed` 确认关闭标记是否成功落盘。会话记录同时保留最后检查点和进程物理内存快照。即使这些记录能表明会话异常结束，也不能代替 iOS `.ips` 报告中的崩溃线程和调用栈。

开启诊断时，未捕获的 Objective-C 异常会在进程退出前尝试同步记录异常名、脱敏后的原因和最多 12 条栈帧。MetricKit 如果稍后向 App 投递系统崩溃诊断，会另记 `metrickit_crash_diagnostic_received`，包含信号、异常类型/代码、终止原因、关联的上次未正常结束会话 ID，以及最多 16 条可用于 dSYM 符号化的二进制 UUID/偏移摘要。若没有崩溃栈，MetricKit 也可能延迟提供 `metrickit_app_exit_metrics_received`：它按报告周期汇总前台/后台正常退出、异常退出、看门狗、内存/CPU 限额、内存压力和非法访问等计数，可帮助判断系统是否记录过资源限额终止；这些累计值没有单次退出时间，不能直接对应到某个会话。MetricKit 投递可能延迟，也可能没有报告；`SIGKILL`、系统回收、设备重启以及原生崩溃期间的内存破坏仍可能没有可读取的诊断内容。应用不会在致命信号处理函数里执行 Objective-C 或同步写文件，避免崩溃处理本身再次触发崩溃。

影视首页另外持久化记录 `media_home_data_apply_started/completed`、`media_home_modules_rebuild_started/completed`、`media_grid_cell_configuration_started/completed` 和 `media_grid_first_cell_will_display`。检查点文件会保留白名单中的频道数、分类数、首页模式、渲染序号和卡片索引，并随下一次启动的 `previous_session_unclosed` 一起导出。它们可以把“接口返回”继续拆到数据应用、模块重建、首张卡片配置和首次进入显示队列；若事件在某个 `started` 后中断，可把最后检查点与上下文对齐。它们能缩小原生页面故障窗口，不能代替 `.ips` 调用栈。

如果没有 `.ips`，可以先查看 iPhone“设置 → 隐私与安全性 → 分析与改进 → 分析数据”中是否有 `JetsamEvent` 或 CCTVHost 的系统诊断；内存回收常表现为 `JetsamEvent`，不会有普通应用崩溃栈。需要即时捕获时，将 iPhone 连接 Mac，在“控制台”选择设备并开始实时串流，按 `CCTVHost` 过滤，复现后保存相关日志。App 内 MetricKit 诊断可能在之后的启动周期才送达，需打开 App 并导出对应会话。以上途径拿不到系统栈时，导出诊断中的“最后检查点 + 上下文 + 内存占用”仍可区分页面阶段、内存压力和强制终止等线索，但不能单独证明具体崩溃指令。

服务详情里的“查看日志”先列出该脚本的每次运行；点开一条只看本次启动到停止/失败的日志，可单独导出或清理。每个脚本最多保留最近 20 次运行，每次日志最多 256 KiB；升级前原有的连续日志作为“更新前历史日志”保留。若应用在运行期间退出，下次查看时会把未结束记录标成“未正常结束”，不会把它和新一轮运行合并。

Python 插件的 HTTP 响应体受每响应 16 MiB 上限保护；每个服务最多 4 个 HTTP handler，全宿主最多 12 个 handler，同时最多 2 个/服务、8 个/宿主执行大响应读取。超限或读取并发预算耗尽会让该 HTTP 请求失败，避免多个完整媒体分片同时无限占用内存。重复的并发/响应限制事件按 1、2、4、8… 次采样记录，服务停止时再补记准确累计数和被合并的重复数，减少过载时每次都同步写盘造成的额外压力；首发事件、拒绝原因和最终总数仍可见。低于上限的普通响应可继续读取。

Node 与 JavaScriptCore 的调用会以 `plugin_bridge_started` 及 `plugin_bridge_succeeded` / `plugin_bridge_failed` 成对记录，包含服务 ID、引擎、操作名、耗时、响应大小和失败阶段，不包含脚本源码或请求正文。`failure_stage` 能区分桥接异常、空/非法响应和插件返回业务错误。

服务健康检查事件包含 `probe_id`、尝试次数、最后 HTTP 状态、响应字节数、内容类型、错误域/代码及失败类型。`process_failed` 表示宿主发现进程退出；`network_error` / `http_status` 表示探测请求没有通过；`invalid_health_response` 表示 HTTP 200 但健康 JSON 不符合约定；`probe_timeout` 表示在截止时间内没有就绪。

HTTP 订阅事件使用相同的 `correlation_id` 串起开始、健康检查与结果。失败阶段可区分网络/超时、HTTP 状态、响应过大、空响应、非法 UTF-8 和“内容有效但没有解析出频道”；记录还包括响应 MIME 类型、耗时、字节数和频道数。M3U 解析会保留常见 `#EXTVLCOPT:http-user-agent`、`http-referrer`、`http-cookie`、`http-origin` 及 `#EXTHTTP` 请求头并应用于 AVPlayer 请求；禁止由播放列表覆盖 Host、Content-Length、Connection 等传输字段。导入文本只记录输入字节数和解析出的频道数，不记录文本内容。

## 隐私与解释限制

日志不记录原始播放地址、绝对路径、查询参数值、Cookie、令牌、请求参数或响应正文；播放诊断最多记录查询参数名、签名字段是否存在及媒体主机/扩展名，用于判断地址类型而不暴露签名。Python 崩溃标记只保留脚本文件名，不保存脚本路径或源码。错误文本经过脱敏并截断；单次运行文件上限为 4 MiB，超限后滚动保留最近约 3 MiB；最多保留 24 次或合计 32 MiB，较旧记录会自动清理。关闭诊断后停止新增记录，已有日志仍可导出。清空全部记录也会移除旧的会话检查点；当前 App 若仍开启诊断，会在后续新事件出现时重新建立本次日志。

Python 脚本与 CCTVHost 共享 App 进程。Python 级异常能被记录，但原生扩展触发的进程级崩溃无法由同一进程安全捕获；遇到此类情况，应将 `python_session_interrupted` 的阶段与系统生成的 `.ips` 崩溃栈对照。

这些事件说明应用代码观察到的网络响应、服务状态和播放器回调，不代表服务内容一定可播，也不代表 AVPlayer 报告播放中就已经解码。真机复现时应开启诊断、记录问题发生时间、只复现一次并尽快导出日志，避免日志滚动覆盖关联事件。

## 网页回退与实际解码证据

网页回退沿用原播放的 `correlation_id`、`service_id` 和 `playback_attempt_id`。`web_media_extraction_started` 表示用户请求读取页面媒体；`web_media_extraction_failed` 区分 JavaScript 执行失败与没有有效 HTTP/HTTPS 媒体地址；`web_media_native_handoff` 只表示已取得地址并准备交回原生播放器，不能当成已出首帧。网页加载失败另记 `web_media_navigation_failed`。这些事件不记录页面正文、媒体完整地址、签名值或凭据。

`media_relay_client_disconnected` 表示宿主向客户端写响应时收到断连，不再误报为 `media_relay_failed`。停止、拖动进度、播放器故障都可能产生断连，因此它既不证明播放成功，也不证明上游失败。上游读取时发生连接中断仍记为失败。

FFmpeg 软件解码测试和 iPhone AVPlayer 验收分别记录。清单可读、分片可读、网页取得媒体地址、播放器报告 playing 都不能代替视频首帧；持续播放至少 5 秒还需要对应播放器的帧与进度证据，不能从中继传输耗时推断。

### CatPaw optional recommendations

A successful `home` response with a nonempty `class` array remains usable if the
optional `homeVod` request fails. Categories are retained so a user can browse
instead of receiving a whole-page failure. Missing recommendation routes (404/405)
remain compatible; other failures emit `catpaw_recommendations_failed` with the
provider ID, HTTP status (or null for transport errors), and
`categories_available: true`. This event does not establish video availability.
When neither recommendations nor categories are available, the failure is still
reported. No upstream response body or playback credentials enter this event.

Regression: `test_catpaw_optional_recommendation_failure_preserves_categories`
uses a local HTTP 503 fixture and verifies category navigation and independent
service shutdown. It does not test an external movie or AVPlayer decoding.
