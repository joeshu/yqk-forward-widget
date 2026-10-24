# CCTVHost —— 央视影音 iOS SDK 原生宿主（M1）

目标：用 IPA 里的官方 iOS 三件套在自有 App 内原生播放，彻底去掉 Android 模拟器、Unicorn、WASM。
本工程是 **M1 最小验证宿主**：只做「启动 SDK → 起播一个频道 → 打印内部状态」，不追求 UI 完成度。

## 目录

```
CCTVHost/
├── Frameworks/           # 已放入：CNPlayerSDK / CicadaPlayerSDK / alivcffmpeg（已删旧签名）
├── Resources/Info.plist  # ATS 放开、arm64、竖屏
├── Sources/
│   ├── main.m / AppDelegate.[hm]
│   ├── RootViewController.[hm]   # 频道/播放器业务与宿主总日志
│   ├── LogCenterViewController  # 独立日志浏览、筛选和导出界面
│   ├── PluginLogStore           # 按脚本 ID 隔离的插件日志存储
│   └── Include/                  # 手写的最小头文件（官方 framework 不带 Headers）
├── Scripts/resign-check.sh
└── project.yml           # XcodeGen 工程描述
```

## 日志分层

- 设置里的“日志中心”查看宿主总日志；播放、Python、JavaScriptCore 和 Node 运行输出在这里汇总，便于排查跨模块问题。
- 服务详情里的“查看日志”只显示该服务脚本的输出，并可单独搜索、复制、导出或清空。每份日志按稳定的服务 ID 写入 `Application Support/ysp/plugin-logs/`，更换脚本不会覆盖其他插件日志。
- 日志浏览页与播放器分开，通过设置、服务详情或播放器“更多”进入，不遮住正在播放的视频。

## 一、生成工程并编译

```bash
brew install xcodegen          # 一次性
cd CCTVHost
xcodegen generate              # 生成 CCTVHost.xcodeproj
open CCTVHost.xcodeproj
```

Xcode 里只需要改两处：

1. **Signing & Capabilities** → 选自己的 Team，Bundle Identifier 改成自己的（如 `com.yourname.cctvhost`）。
2. 确认三个 framework 在 *Frameworks, Libraries, and Embedded Content* 里是 **Embed & Sign**；
   Build Settings 里 `Other Linker Flags` 为 `-ObjC -lresolv`（project.yml 已设置）。

真机运行（模拟器无法跑：framework 只有 arm64，且需要 VideoToolbox）。

## 二、M1 判读标准

启动后日志区应依次出现：

1. `CNPlayer class = CNPlayer, CicadaPlayer class = CicadaPlayer` —— 说明三件套已加载
2. `defaultOptions = …` —— SDK 配置对象成功构造
3. 点击 `cctv1` 后：`调用 +[CNPlayer playLIVEWithChannelID:delegate:configOptions:] 返回类型 …`
4. SDK 内部应出现 auth / VDN / license 相关日志，随后首帧出现

**前 3 条出现、第 4 条没有** → SDK 启动成功但没有鉴权，按下面第 5 节处理。
**第 1 条就没出现** → framework 没嵌入/没签名，检查 Embed & Sign 与 `-ObjC`。

## 三、两条代码路径

| 路径 | 代码位置 | 用途 |
| --- | --- | --- |
| A. CNPlayerSDK 业务层 | `tapChannel:` | 主路径：VDN、版权、清晰度、EPG 全由 SDK 负责 |
| B. Cicada 内核直连 | `tapCicada:` | 调试：输入一条受保护 m3u8，直接验证 UDRM 解密是否工作（不依赖 VDN 鉴权） |

B 路径的价值：**它能在不知道任何 appKey 的情况下验证「内置客户端证书 + 许可服务」是否放行**。
如果 B 能出画面，说明许可链路通，问题只在与 VDN 鉴权相关的 A 路径。

## 四、已验证的事实（来自 IPA 静态分析与实测）

- 许可服务：`https://drm.live.cntv.cn:444/udrm/udmCNTVGetLicense`，无需 TLS 客户端证书，
  请求体为 `version/platform/cdn/deviceID/drmServerID/udrmTerminalLibVersion/nonce/timestamp/contentIDs[]/certificateChain[]/signature`，
  我们构造的请求被服务端解析并返回 `status:-72 signature error` —— 即**只缺签名，字段全对**。
- 签名由 SDK 内置私钥 `m_udrm_cli_prikey` + 证书链 `g_udrm_cli_cerchain` 完成，不可离线伪造，也不需要伪造。
- VDN `https://vdn.live.cntv.cn/api2/live.do?channel=cctv1` 不带鉴权恒为 `play=0`（T8）。

## 五、如果 A 路径没有鉴权（appKey 缺失）

`CNPlayer` 提供两个启动入口：`startPlayerSDK_Options:`（默认配置）与 `startPlayerSDK_AppKey:appSecret:`。
若默认入口发起 auth 失败，需要补 appKey/appSecret。三种取法，按优先级：

1. **反汇编主二进制调用点**：`+[CNPlayer startPlayerSDK_AppKey:appSecret:options:]` 的调用方会把两个 NSString 常量
   经 `adrp/add` 指向 `__cfstring` 载入；找到调用点即可读出字面量。
2. **运行期日志**：在真机上开 `logEnabled:YES`，auth 失败日志通常会带被拒的 appkey 前缀。
3. **接入抓包**：iPhone 上配代理抓 `open.app.cctv.com/sdk/api/auth` 的 query（`appkey / sdkId / timestamp / sign`），
   `sign` 为 md5 组合，有 appkey + appSecret 即可复现。

拿到后把 `setupSDK` 里的 `startPlayerSDK_Options:` 换成：

```objc
[CNPlayer startPlayerSDK_AppKey:@"<appKey>" appSecret:@"<appSecret>"];
```

## 六、已知风险

- **许可绑定 deviceID**：许可请求里的 deviceID 由 SDK 生成，重装/换机可能需重新取；本工程未做设备注册。
- **清晰度**：配置中 `login_bitrate` 含 HSD/SD，未登录可能只能拿到较低码率（先按 AD 自动跑通再调）。
- **重签名合法性**：三件套来自 App Store 包，仅限个人自用；不得分发。
- **不可代理给 APTV**：解密在 demuxer 内完成，无官方明文 TS 输出接口（B 路线已排除）。

## 七、下一步（M2 起）

1. 频道目录接入现有 `CHANNELS-v0.3.0.json`（53 台/94 线）替换硬编码的 6 个按钮。
2. 播放器视图换成 `CicadaPlayerView` 或 CNPlayer 自带视图，补全全屏/手势。
3. 记录首帧耗时、CPU、内存，与 v0.3.7 模拟器版本对比（目标：首帧 < 1.5s，连续播放不掉帧）。

<!-- build trigger: 2026-10-22T16:38:34Z -->
