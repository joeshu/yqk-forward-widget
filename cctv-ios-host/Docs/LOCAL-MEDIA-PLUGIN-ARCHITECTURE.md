# CCTVHost 本机影视插件架构提案

状态：以下为设计背景与验收规划。0.18 已实现通用包导入、本机 Python/JSC/drpy/Node 宿主与影视页面；实际用法、已验证范围及限制以 [本机影视资源使用说明](MEDIA-PLUGINS.md) 为准。所有运行时位于 iPhone 本机，不采用 NAS/电脑服务，不增加 iCloud。

## 1. 样本与兼容边界

| 样本 | 真实接口/依赖 | 本机接入路线 |
| --- | --- | --- |
| iptv/extractors/yangshipin | 项目 ESM 提取模块、上层工具依赖 | 已有专用 JavaScriptCore 适配；通用 ZIP 导入另行实现 |
| iptv/extractors/migu | fetch/resolve、config、utils、account | 完整依赖包 + iptv-extractor 协议适配；不能仅压缩 migu 目录 |
| catpaw/index.js.md5 | 32 字符校验值，不是程序 | 下载对应 index.js，校验后识别程序；不可直接执行 md5 文件 |
| catpaw 发布版 index.js | 约 4.13 MB；Fastify、http/net/tls/fs/vm 等 Node API | 内嵌 Node.js Mobile + Catpaw HTTP 协议适配；待实机验证 |
| 看剧AI.py | Spider 类；home/category/search/detail/player 方法 | 原文件由 CPython 加载，新增 Python Spider 适配层；无需转写 JS |

猫爪样本的实际 JS 与提供的 MD5 校验一致。MD5 用于检查传输完整性，不作为来源可信或代码安全证明。

普通 JS、影视规则、Node 服务必须分别识别。JavaScriptCore 的少量 Node API 兼容函数不能替代完整 Node 环境。带 .node 原生扩展、child_process、桌面浏览器或二进制工具的包，不承诺直接兼容；导入检测应指出具体缺失依赖。

用户已确认普通 JS 与 drpy/CatVod 规则包都会导入。规则配置应绑定具体引擎及版本；只有导出 CatVod 方法的可运行模块才能直接使用 catvod-js 适配。不能把 rule 对象直接当成完整执行引擎。

## 2. 分层

原生 UI → 媒体资源模型 → 协议适配器 → 插件宿主 → 运行时。

运行时分为 JavaScriptCore、CPython、Node.js Mobile。协议独立声明：cctvhost.media/1、python-spider、catvod-js、iptv-extractor、catpaw-http。语言扩展名不决定协议。

宿主统一提供包路径、独立数据路径、设置、日志、网络请求、缓存、取消信号和生命周期。运行时适配器负责代码执行；协议适配器负责把原始结果映射为资源模型。不要为每个来源复制整套页面。

已有 CCTV 原生 SDK 播放链路保持独立；M3U 和影视直接媒体地址由 AVPlayer 播放。插件查找与影视初始化不进入 CCTV 原生开台关键路径。首次展示页面才加载对应运行时，首页不同时初始化所有插件。

## 3. 统一媒体协议

能力字段：live、home、category、search、detail、play、epg、proxy。来源只展示已声明且实际可调用的能力。

统一操作：

| 操作 | 输入 | 输出 |
| --- | --- | --- |
| capabilities | 无 | 协议版本、能力、设置项 |
| home | 无 | 分类、推荐卡片、筛选定义 |
| category | categoryId、page、filters | 卡片、分页信息 |
| search | keyword、page | 卡片、分页信息 |
| detail | id | 标题、简介、海报、播放线路及分集 |
| play | episodeId、lineId | url、headers、alternates、过期时间或明确错误 |
| catalog/resolve | 频道引用 | 直播频道/播放地址 |
| epg | 频道、日期 | 节目单 |

资源 ID 为不透明字符串，与 sourceId 一同保存；不同来源的相同 ID 不合并。列表保留 page/pagecount/hasMore；不能用“返回数量少”一律判断没有下一页。Spider 的 vod_play_from、vod_play_url 转为线路与分集，原始播放 ID 原样回传 playerContent。

成功返回 {ok:true,data:…}；失败返回 {ok:false,error:{code,message,retryable}}。区分超时、登录过期、无版权、源接口变化、运行时不兼容和非直接播放地址。parse=1 不应伪装成可播放 HLS；有对应解析能力才继续处理。

桥接可采用原生消息或仅绑定 127.0.0.1 的 HTTP；前端使用同一模型。建议内部路由 /api/v1/sources/{sourceId}/{operation}。仅直播生成 /all.m3u 和 XMLTV；影视推荐、搜索结果和剧集不自动塞进直播订阅。

## 4. 本机 Node 宿主

候选为 nodejs-mobile；官方提供 iOS 构建方案，V8 使用禁用 JIT 配置。需要先固定版本、验证 arm64 真机及当前 iOS，再决定加入正式 IPA，不能仅凭桌面 Node 测试宣布兼容。

官方要求进程内单 Node 实例：在专用后台线程启动一次 bootstrap，管理多个插件实例。插件关闭的是服务实例，不销毁整个 Node；禁止通过 process.exit 关闭宿主。插件数据写入自己的沙盒路径，端口由宿主分配并检查占用。猫爪通过其 start/stop 导出和 /check、/config、/spider/... 接入。

vm Context 不是进程隔离或安全边界。全局故障、死循环和原生错误仍可能影响 App；不能承诺“任意插件永不崩溃”。异步请求需有限并发与超时，CPU 密集任务需单独验证可终止方案。依赖子进程的服务不可直接移植到 iOS。

先验证 Node 最小启动、HTTP 回环、TLS、持久化、停止与再次启用，再验证原猫爪发布包的 init/home/search/detail/play。若包还需移动端适配，应展示清楚原因，不静默改为远端运行或 Python 重写。

## 5. 导入与更新

入口：资源 → ＋ → 导入文件/ZIP、输入下载地址。

流程：暂存下载 → 安全解压 → 识别入口/运行时/协议 → 检查依赖 → 展示名称和设置 → 安装 → 用户启用 → 能力探测 → 出现在频道或影视页。导入不自动执行代码。

优先读取 cctvhost.json，其次 package.json；没有清单时列出候选入口供选择，不递归执行所有 .js/.py 文件。Spider 类文件可识别为候选，但是否可用由加载与能力探测确认。ESM/CJS 由清单、package.json 和扩展名确定，遇到不明确语法时报告错误。

建议清单：

```json
{
  "schemaVersion": 1,
  "id": "example.media",
  "name": "示例影视",
  "runtime": "python",
  "protocol": "python-spider",
  "entry": "看剧AI.py",
  "capabilities": ["home", "category", "search", "detail", "play"]
}
```

Node 包应包含 bundle 或全部可兼容依赖；不在手机导入时自动 npm install 或编译原生模块。JS 源码保持 JS；Python Spider 保持 Python。

解压拒绝绝对路径、../ 越界、符号链接和解压炸弹；设置文件数、总大小与单文件上限，并允许猫爪这种大于 4 MB 的正常 bundle。安装采用暂存目录和原子切换，更新失败保留旧版。代码、数据、缓存分目录；更新不覆盖用户账号与历史。

.md5 地址应关联对应 .js 下载并检查格式、大小及校验；成功后仍需运行时兼容检查。运行中的包先完成停止确认，才替换代码；不热替换正在执行的模块。

## 6. 页面布局

底部：CCTV｜频道｜影视｜资源｜设置。资源页负责导入和导入后的资源列表；设置页负责 App 偏好。

- CCTV：原生 SDK 频道与播放器，保留快速切台路径。
- 频道：M3U 订阅、分组、EPG、直播收藏。
- 影视：顶部来源选择、搜索；下方分类/筛选、海报网格；详情包含简介、线路和选集。
- 收藏入口：放在频道和影视页面内，区分直播收藏、影视收藏及观看记录，记录来源与分集，不只保存会过期的播放 URL。
- 资源：顶部导入按钮和搜索；列表展示已导入的直播订阅、JS/Python 影视包和本机服务。支持类型筛选、启用、配置、日志、更新、导出和删除；资源详情显示运行时、协议、版本、健康状态和可读错误。以上通用包能力仍按实施顺序开发。
- 设置：播放器偏好、外观、网络、缓存预算、诊断与版本信息，不与资源列表混合。

右上角操作按页面提供：频道页为刷新/布局/更多，影视页为来源/搜索，插件页为导入/日志。不要将所有管理按钮堆在每一页。

首次导入影视包后提供“打开影视”；直播包提供“添加直播订阅”。首页不显示用户无法使用的播放按钮。加载、空结果、登录失效与插件错误采用不同状态。

## 7. 播放与稳定性

播放解析只在选中剧集后调用，避免打开详情即解析全部分集。保留 Cookie、Referer、User-Agent 等播放请求头，并验证 HLS 子播放列表、TS/密钥请求是否也得到所需请求头；原生资产请求头不足时使用有界本机代理。日志隐藏账号和令牌。

任务带 sourceId、sessionId、requestId；切换来源或退出页面取消旧任务，迟到结果不可覆盖当前页面。生命周期为 installed → starting → running → stopping → stopped/failed；停止失败不显示为已停止。关闭 HTTP server、连接、定时器、后台任务后才允许替换实例。

Python 常驻解释器不反复 Py_Finalize。附件 destroy() 只清缓存，仍需宿主追踪 init() 启动的预热线程；仅调用 destroy 不足以证明全部线程已停止。不可强杀任意 Python 线程。UI 全程异步，不能在主线程等待 GIL、网络或 stop。

缓存按来源分配预算，限制请求并发与单次响应大小。退出详情取消海报/搜索请求；App 进入后台按 iOS 生命周期暂停非必要服务，不承诺无限后台运行。

## 8. 实施与验收顺序

1. 统一媒体模型与协议 fixture：Python Spider 和 JS 返回相同原生 UI 模型，验证分页、多线路、请求头、parse 错误。
2. 完成通用包导入、来源管理和影视页面；附件 Spider 实测分类 → 搜索 → 详情 → 分集播放。
3. 完成 JSC 通用模块加载与 iptv-extractor 适配；咪咕检查完整依赖、用户设置、直播地址解析及版权错误。
4. Node 最小宿主与生命周期实机验证；随后原猫爪发布包完整链路测试。
5. 回归快速连续切源、停止重启、网络断开、后台恢复、缓存上限和已有 CCTV 开台/切台时间。

当前已完成的专用央视频 JS 支持不等于上述通用 ZIP、影视浏览或完整 Node 兼容。交付说明逐项标注已实现、已测试、待验证，避免扩大兼容性声明。

## 参考

- https://github.com/joeshu/iptv/tree/main/extractors/migu
- https://joeshu.github.io/yqk-forward-widget/catpaw/index.js.md5
- https://github.com/nodejs-mobile/nodejs-mobile
- https://github.com/nodejs-mobile/nodejs-mobile/blob/main/doc_mobile/FAQ.md
- https://github.com/nodejs-mobile/nodejs-mobile/blob/main/doc_mobile/BUILDING.md
