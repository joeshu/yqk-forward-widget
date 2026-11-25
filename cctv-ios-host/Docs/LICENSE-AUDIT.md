# 第三方组件许可证合规审计报告（Phase 6）

- **审计分支**：`p6-license`（基线 commit `6744668`）
- **工程**：`cctv-ios-host`
- **审计日期**：2026-11-25
- **审计范围**：`Frameworks/`、MPV/CCTVMPVCore 构建链（`Scripts/prepare_mpv_runtime.py`、`Scripts/ci-build.sh`、`Scripts/prepare_jar_runtime.sh`、`Scripts/prepare_node_runtime.py`）、`Runtime/JAR/RuntimeLicenses`、`Resources/NodeMobile-LICENSE.txt`、`JSPlugins/`、`Plugins/`（第三方 Python）
- **审计方式**：只读本地源码、二进制 `strings`、`Info.plist` 解析、许可文件原文核对；**未联网下载**任何大文件，未修改任何代码或构建产物
- **结论先行**：本工程如果要公开发布 **unsigned IPA**，存在 **3 项高风险** 许可证冲突（GPL 与闭源 SDK 同包、JAR 运行时 GPL-3.0 与 Unicorn/Keystone GPL-2.0 互斥、CNPlayerSDK 内嵌 IJK FFmpeg 的 LGPL 可替换性不满足），**必须先整改再发布**；MPV 侧（CCTVMPVCore）因采用 LGPL 切片 + 符号隔离 + 构建脚本随包，风险较低。

---

## 0. 构建链与分销事实基线（来自 ci-build.sh / prepare_*.py）

最终 `CCTVHost-unsigned.ipa` 的 `Payload/CCTVHost.app` 中与第三方组件相关的实际打包内容：

| 入包物 | 来源/脚本 | 物理形态 |
| --- | --- | --- |
| `Frameworks/CNPlayerSDK.framework` | `Frameworks/` 目录，`ci-build.sh:133` `cp -R Frameworks/*.framework` | 动态 framework（dylib），随 IPA 分发 |
| `Frameworks/CicadaPlayerSDK.framework` | 同上 | 动态 framework，随 IPA 分发 |
| `Frameworks/alivcffmpeg.framework` | 同上 | 动态 framework，随 IPA 分发 |
| `Frameworks/CCTVMPVCore.framework` | `Scripts/prepare_mpv_runtime.py`（CI 时构建） | 动态 framework（由静态 LGPL 切片链接而成），随 IPA 分发 |
| `Frameworks/NodeMobile.framework` | `Scripts/prepare_node_runtime.py`（Node.js Mobile v18.20.4） | 动态 framework，随 IPA 分发 |
| `Frameworks/Python.framework` + `python/` stdlib + site-packages | BeeWare Python-Apple-support 3.13-b16 + `media-python-requirements.txt` | 动态 framework + 纯 Python 包，随 IPA 分发 |
| 主二进制 `CCTVHost` | `clang`（`ci-build.sh:147`） | 可执行文件，**静态 force-load** `libTVAppleRuntime.a`（JAR 运行时），并动态链接上述全部 framework |
| `JARLicenses/`（RuntimeLicenses + COPYING + upstream.json + UPSTREAM-NOTICES.md） | `prepare_jar_runtime.sh` 产出，`ci-build.sh:144` `cp -R "$JAR_ROOT/Resources/" "$APP/"` | 文本，随 IPA 分发 |
| `NodeMobile-LICENSE.txt`、`tr46-LICENSE.txt` | `Resources/` | 文本，随 IPA 分发 |
| `GeneratedJS/yangshipin.bundle.js` + `yangshipin-LICENSE.txt` + 各 `*-THIRD-PARTY-NOTICES.txt` | `JSPlugins/build.mjs` | JS + 文本，随 IPA 分发 |
| `JSPlugins/yangshipin/`、`JSPlugins/compat/` | `ci-build.sh:62` | JS 资源，随 IPA 分发 |

> 注：本分支（基线 `6744668`）工作树中 **不存在 `.github/workflows/`**；CI workflow 文件见于其他分支历史（`c6f06af` 等）。MPV/FFmpeg/JAR/Node 的下载与编译动作全部位于 `Scripts/` 下，本审计以 `Scripts/` 为准。

### 主二进制链接关系（核心事实）

`ci-build.sh:147-160` 的 `clang` 命令同时：
1. `-Wl,-force_load,$JAR_ROOT/lib/libTVAppleRuntime.a` —— **静态**把 JAR 运行时（含 OpenJDK Zero、Unicorn TCI、Keystone、Capstone、unidbg、JNA、libffi、dex2jar）并入主二进制 `CCTVHost`；
2. `-framework CNPlayerSDK -framework CicadaPlayerSDK -framework alivcffmpeg` —— **动态**链接三个闭源/含 LGPL FFmpeg 的播放器 framework；
3. 经 `prepare_mpv_runtime.py` 产物 `-framework CCTVMPVCore`（但在 `ci-build.sh` 里由 rpath 间接加载）—— **动态**链接 LGPL 闭包。

即：**GPL 组件（Unicorn/Keystone，静态）与闭源 SDK（CNPlayerSDK/CicadaPlayerSDK，动态）位于同一可执行文件、同一 IPA 分发单元内**。这是本次审计最关键的事实。

---

## 1. 逐组件审计

### 1.1 Frameworks/

#### CNPlayerSDK.framework（央视影音播放器 SDK）
- **许可证**：闭源专有（`com.cctv.ysyy.CNPlayerSDK`，iOS 26.2 SDK 构建）。无许可证文件随 framework 提供。`strings` 显示其内部静态嵌入了 **FFmpeg `ff3.2--ijk0.7.5--20161205--001`**（ijkplayer 变体），属 LGPL-2.1-or-later 的 FFmpeg。
- **是否随 IPA 分发**：是（动态 framework）。
- **链接方式**：动态链接（`-framework CNPlayerSDK`）。
- **发布 unsigned IPA 义务**：
  - 闭源部分：需央视/央视影音 SDK 的商用或分发授权，本仓库未见任何授权凭证。
  - 内嵌 FFmpeg（LGPL-2.1+）：需(a) 在声明文件中列出 FFmpeg 及版本、(b) 提供/承诺提供 FFmpeg 对应源码（含 ijkplayer 补丁）、(c) **可替换性**——LGPL 要求用户能够用修改后的 FFmpeg 重新链接。但 FFmpeg 被**静态链接进闭源 SDK 内部**，终端用户无法仅替换 FFmpeg 而不动 SDK 整体，**可替换性不满足**。
- **风险等级**：**高**
- **整改建议**：(1) 取得央视 SDK 书面分发授权并随包提供授权摘要；(2) 向 SDK 提供方索取该 FFmpeg 的源码与构建脚本，或在声明中给出 3 年有效的书面源码获取承诺；(3) 推动 SDK 提供方以动态库形式独立提供 FFmpeg 切片以满足 LGPL 可替换性，或整体改为不内嵌 FFmpeg 的 SDK 版本。

#### CicadaPlayerSDK.framework（阿里 Cicada 播放器 SDK）
- **许可证**：闭源专有（`com.alibaba.CicadaPlayerSDK`，iOS 18.4 SDK 构建，路径痕迹 `/Users/xinchen/Documents/CicadaPlayer0.1Release`）。无许可证文件随 framework 提供。属阿里云视频云播放器 SDK，受阿里云单独许可协议约束。
- **是否随 IPA 分发**：是。
- **链接方式**：动态链接。
- **发布义务**：需阿里云播放器 SDK 的有效授权（通常为免费但需登记/接受在线协议）；声明文件中需注明。
- **风险等级**：**中**（无 copyleft 冲突，但授权凭证缺失）
- **整改建议**：核对并留存阿里云播放器 SDK 授权记录，在声明文件中标注 SDK 名称、版本、许可来源链接。

#### alivcffmpeg.framework（阿里裁剪版 FFmpeg）
- **许可证**：**LGPL-2.1-or-later**（FFmpeg `n4.2.1-6-g01319374d6`）。`strings` 取得完整 `configuration:` 行：`--disable-everything ... --enable-pic ... --enable-cross-compile ...`，仅启用 LGPL 合规的解码器/复用器/协议，未见 `--enable-gpl`，符合 LGPL 模式。
- **是否随 IPA 分发**：是。
- **链接方式**：动态 framework（dylib）—— 单独成 framework，理论上**可被独立替换**，满足 LGPL 可替换性的物理前提。
- **发布义务**：(a) 声明文件列出 FFmpeg n4.2.1 及 LGPL-2.1+；(b) 提供或承诺提供该 FFmpeg 源码（含阿里裁剪配置）；(c) 由于是动态库且符号未导出绑定，替换路径成立，仅需在声明中说明替换方法。
- **风险等级**：**中**（动态可替换降低风险，但当前仓库**未提供**该 FFmpeg 的源码或源码承诺文案，需补齐）
- **整改建议**：在声明文件中加入 FFmpeg 源码获取方式（指向阿里云公开的 alivcffmpeg 源码包或自托管镜像）与替换 `alivcffmpeg.framework` 的步骤说明。

### 1.2 MPV / CCTVMPVCore 构建链（Scripts/prepare_mpv_runtime.py）

构建链一次性拉取并静态链接 MPVKit 1.0.0（mpv v0.41.0 + FFmpeg n8.1.2）的 **LGPL 闭包**，产出 `CCTVMPVCore.framework`（动态库，`-fvisibility=hidden`，仅导出 `_mpv_*`，`nm -gU` 网关拒绝任何 `av*/SSL/EVP` 符号泄漏）。

| 子组件 | 版本 | 许可证 | 静/动 | 风险 |
| --- | --- | --- | --- | --- |
| mpv | 0.41.0（MPVKit 1.0.0 LGPL 目标，排除 Libsmbclient/GPL、Libluajit/macOS） | **LGPL-2.1-or-later** | 静态→并入 CCTVMPVCore 动态库 | 低 |
| FFmpeg | n8.1.2（LGPL 切片） | LGPL-2.1-or-later | 静态→CCTVMPVCore | 低 |
| libass | 0.17.5 | ISC | 静态 | 低 |
| freetype | 2.15.0 | FreeType License (FTL) / GPL-2.0 双许可，取 FTL | 静态 | 低 |
| fribidi | 1.0.18 | LGPL-2.1-or-later | 静态 | 低 |
| harfbuzz | 15.1.0 | Old MIT（USE 表为 MIT，© Microsoft） | 静态 | 低 |
| unibreak | — | ISC/LGPL（libass 依赖） | 静态 | 低 |
| libplacebo | 7.360.1 | LGPL-2.1-or-later | 静态 | 低 |
| MoltenVK | 1.4.2 | Apache-2.0 | 静态 | 低 |
| libshaderc_combined | 2025.5.0 | Apache-2.0 | 静态 | 低 |
| lcms2 | 2.17.0 | MIT | 静态 | 低 |
| libdovi | 3.3.2 | MIT | 静态 | 低 |
| libdav1d | 1.5.3 | BSD-2-Clause | 静态 | 低 |
| libuavs3d | 1.2.1-fix | BSD-2-Clause | 静态 | 低 |
| libbluray | 1.4.0 | LGPL-2.1-or-later（注意：libbluray 上游含可选 GPL 组件，需确认使用 LGPL 配置） | 静态 | 中 |
| libuchardet | 0.0.8 | LGPL-2.1-or-later / MPL-1.1（取 LGPL） | 静态 | 低 |
| gnutls / gmp / nettle / hogweed | 3.8.11 / 配套 | LGPL-2.1-or-later / GPL-2.0-or-later（gmp）/ LGPL-2.1+（nettle/hogweed） | 静态 | 低-中 |

- **是否随 IPA 分发**：是（`CCTVMPVCore.framework`）。
- **链接方式**：CCTVMPVCore 是**动态 framework**；其内部由上述 LGPL/宽松许可的静态切片 `force_load libmpv.a` + 其余 `.a` 拼接。符号对外仅 `_mpv_*`，对 CNPlayerSDK 的 IJK FFmpeg 与 Python 的 OpenSSL 零泄漏（脚本内建校验网关）。
- **LGPL 可替换性**：物理上 CCTVMPVCore 是独立动态库，可被替换；构建脚本 `Scripts/prepare_mpv_runtime.py` + `Scripts/mpv_exported_symbols.txt` 完整随仓库提供，MPVKit 版本与 18 个依赖 XCFramework 的 URL、sha256 全部固化在脚本中，**满足“可重新链接/替换”要求**。
- **发布义务**：(a) 声明文件列出 mpv 0.41.0、FFmpeg n8.1.2 及上述全部依赖与许可证；(b) 因含 LGPL-2.1+ 组件（mpv/FFmpeg/fribidi/libbluray/libuchardet/gnutls/nettle/hogweed），须提供或承诺提供对应源码（脚本已固化源 URL 与 sha256，可视为“书面获取途径”，但建议补一段明确的 3 年有效源码声明）；(c) 说明替换 CCTVMPVCore.framework 的步骤。
- **风险等级**：**低-中**（libbluray、gmp 的“GPL 还是 LGPL”配置需最终核对 MPVKit 1.0.0 的 Package.swift 取证；其余均为低）
- **整改建议**：(1) 补一份 `NOTICES` 文本把 MPVKit 1.0.0 的 18 个依赖全部列出；(2) 在 `prepare_mpv_runtime.py` 注释或产物 README 中固化 libbluray/libass 等的源码获取地址与 LGPL 替换步骤；(3) 核对 libbluray 是否按 LGPL 配置（关闭 BD-Java/GPL 选项）。

### 1.3 Runtime/JAR（libTVAppleRuntime.a，静态并入主二进制）

上游 `jo32/tvbox-silicon` @ `47e5632`，整体 **GPL-3.0-only**（`Runtime/JAR/COPYING`）。`RuntimeLicenses/` 与 `UPSTREAM-NOTICES.md` 已随 `$APP/JARLicenses/` 入包。该 `.a` 被 `-Wl,-force_load` **静态**并入主二进制 `CCTVHost`。

| 子组件 | 许可证（据 RuntimeLicenses 与 UPSTREAM-NOTICES） | 链接 | 随包声明 | 风险 |
| --- | --- | --- | --- | --- |
| tvbox-silicon 上游整体 | **GPL-3.0-only** | 静态并入主二进制 | COPYING 随包 | **高** |
| OpenJDK Zero（mobile） | GPL-2.0 **with Classpath Exception** | 静态 | OpenJDK.txt/OpenJDK-assembly-exception.txt 随包 | 中（CPE 豁免独立模块组合） |
| **Unicorn**（TCI 解释器） | **GPL-2.0**（部分 LGPL-2.0） | 静态 | Unicorn-GPL2.txt/Unicorn-LGPL2.txt 随包 | **高** |
| **Keystone**（汇编器） | **GPL-2.0**（LLVM 派生部分另适用 LLVM 许可） | 静态 | Keystone-GPL2.txt/Keystone-LLVM.txt 随包 | **高** |
| Capstone（反汇编） | BSD-3-Clause（LLVM 派生部分适用 LLVM 许可） | 静态 | Capstone.txt/Capstone-LLVM.txt 随包 | 低 |
| unidbg | Apache-2.0 | 静态 | unidbg.txt 随包 | 低 |
| JNA | Apache-2.0 | 静态 | JNA-Apache2.txt 随包 | 低 |
| dex2jar | Apache-2.0 | 静态 | 见 UPSTREAM-NOTICES | 低 |
| libffi 3.4.8 | MIT | 静态 | libffi.txt 随包 | 低 |
| DexLoom（共享 DEX 解释器） | MIT | 资源 | 见 UPSTREAM-NOTICES | 低 |

- **是否随 IPA 分发**：是（静态并入主二进制 + 声明文件随包）。
- **链接方式**：**静态** force-load 进 `CCTVHost` 主二进制。
- **发布义务**：
  - GPL-3.0（tvbox-silicon）：整个 `CCTVHost` 二进制须以 GPL-3.0 对应方式提供**完整对应源码**（含构建脚本、补丁、jlink 配置），并注明 3 年内可获取。
  - OpenJDK：GPL-2.0+CPE，CPE 豁免“将 Java 运行时与独立模块组合”，因此 OpenJDK 本身**不**把 GPL 传染到闭源 SDK；但仍需随包声明与源码承诺。
  - Unicorn/Keystone：GPL-2.0（**无 Classpath Exception**），静态链接 → 主二进制成为 GPL-2.0 衍生作品，须以 GPL-2.0 公开源码。
- **风险等级**：**高**（详见第 2 节冲突评估）
- **整改建议**：见第 2、3 节。

### 1.4 Resources/NodeMobile-LICENSE.txt（Node.js Mobile）

- **组件**：Node.js Mobile v18.20.4（`Scripts/prepare_node_runtime.py`，`Frameworks/NodeMobile.framework`）。
- **许可证**：Node.js 主许可（MIT 风格）+ 随附第三方声明（V8 BSD、OpenSSL 3.x Apache-2.0、icu IBM 等），全部随包于 `NodeMobile-LICENSE.txt`。
- **是否随 IPA 分发**：是（动态 framework + LICENSE 文本）。
- **链接方式**：动态 framework。
- **发布义务**：保留并随包提供 `NodeMobile-LICENSE.txt`（已满足）。
- **风险等级**：**低**
- **整改建议**：确认 `NodeMobile.framework` 入包时同步复制 LICENSE（`prepare_node_runtime.py` 仅复制 framework，需保证 `ci-build.sh` 把 `Resources/NodeMobile-LICENSE.txt` 一并入包——已确认第 62 行附近复制）。

### 1.5 Resources/tr46-LICENSE.txt
- MIT（Sebastian Mayr）。随包分发，风险低。

### 1.6 JSPlugins

| 组件 | 上游/提交 | 许可证 | 是否入包 | 风险 |
| --- | --- | --- | --- | --- |
| yangshipin（`joeshu/iptv` @ `b121ed0`） | 见 `JSPlugins/yangshipin/SOURCE.json` | **GPL-3.0-only** | **是**：`GeneratedJS/yangshipin.bundle.js` + `yangshipin-LICENSE.txt` 入 `$APP/`；`JSPlugins/yangshipin/` 整目录入 `$APP/JSPlugins/` | **高** |
| drpy（`hjdhnx/dr_py` @ `ca23ffd`） | `JSPlugins/drpy/SOURCE.json`，`upstream/` 含 drpy2.js/template.js/gbk.js/jsencrypt.js/cheerio.min.js/crypto-js.js，sha256 固化 | **LGPL-3.0-only** | bois：`build.mjs` 用其源做 esbuild 桥接并校验完整性；需确认最终 `*.bundle.js` 是否包含 drpy2.js 主体（若是则 LGPL 入包） | 中 |
| FongMi/TV 资产（cheerio.min.js / crypto-js.js / cat.js / gbk.js / similarity.js） | `UPSTREAM-NOTICES.md` 记录，GPL-3.0 | **GPL-3.0** | 经 drpy 桥接引用，可能在 bundle 内 | 中 |
| yangshipin-THIRD-PARTY-NOTICES | build.mjs 生成（buffer/base64-js/ieee754/core-js） | MIT/BSD | 入 `GeneratedJS/` | 低 |
| node-fetch-THIRD-PARTY-NOTICES | build.mjs 生成 | MIT | 入 `GeneratedJS/` | 低 |
| js-runtime-THIRD-PARTY-NOTICES | build.mjs 生成，覆盖 package-lock 全部依赖 | 多为 MIT/BSD | 入 `GeneratedJS/` | 低 |
| `JSPlugins/package-lock.json` 全集 | 60 个包 | 47×MIT / 9×BSD-2 / 2×BSD-3 / 1×ISC | 经 esbuild 打包进 bundle | 低 |

- **发布义务**：
  - yangshipin（GPL-3.0）：随包分发 GPL-3.0 JS 即把对应 JS 源码以 GPL-3.0 公开（`SOURCE.json` 已固化 commit，可作源码指引）；需在声明文件标注。
  - drpy（LGPL-3.0）：若入包，需提供/承诺源码、声明可替换性；若仅作构建期适配器不入最终 bundle，则仅需声明 vendored 源与 commit。
  - FongMi/TV 资产（GPL-3.0）：同 yangshipin 处理。
- **风险等级**：yangshipin **高**（GPL-3.0 与闭源 SDK 同包分发，见第 2 节）；drpy/FongMi **中**。
- **整改建议**：(1) 在声明文件中明确列出 yangshipin(GPL-3.0)、drpy(LGPL-3.0)、FongMi 资产(GPL-3.0) 及其源 commit；(2) 若要避免 GPL-3.0 泄漏到主二进制，应将这些 JS 以“独立脚本资源、明示边界、不与主程序链为一体”的形式分发并附 NOTICE，但 JS 在同一 IPA 内仍可能被认定为组合作品，建议法务复核；(3) 确认 drpy2.js 是否真实进入 `yangshipin.bundle.js`/`js-runtime.bundle.js`，并据此决定 LGPL 声明细节。

### 1.7 Plugins（第三方 Python）

| 组件 | 来源 | 许可证 | 入包方式 | 风险 |
| --- | --- | --- | --- | --- |
| CPython 3.13（BeeWare Python-Apple-support 3.13-b16） | `prepare via ci-build.sh` | PSF-2.0 | `Frameworks/Python.framework` + stdlib | 低 |
| `media-python-requirements.txt` 全集（requests/urllib3/certifi/charset-normalizer/idna/beautifulsoup4/soupsieve/typing_extensions/html5lib/elementpath/defusedxml/six/webencodings） | pip 安装 | Apache-2.0 / MIT / BSD / MPL-2.0(certifi) | `python/lib/.../site-packages/` | 低（certifi MPL-2.0 需声明可修改+源码） |
| pycryptodome（`Crypto`/`Cryptodome`，`Plugins/crypto_compat`） | 本地 vendored | BSD-2-Clause / 公有领域 | site-packages | 低 |
| `Plugins/lxml`（**纯 Python 兼容层**，非 C 扩展，`etree.py` 基于 `html.parser`/`elementpath`/`html5lib`） | 自实现兼容 shim | 本工程许可 | `Plugins/lxml` | 低（不携带原 lxml 的 BSD/ELEMENTTREE 义务，因非衍生二进制；建议在文件头注明“非 lxml，兼容 API”） |
| `Plugins/pyquery.py` | 自实现 PyQuery 兼容 | 本工程许可 | 直接复制 | 低 |
| `Plugins/base/spider.py` | 本工程原创（CatVod Spider 接口） | 本工程许可 | `$APP/base/` | 低 |
| `Plugins/cctvhost_ffmpeg.py` | 本工程原创，调用主二进制已链接的 FFmpeg | 本工程许可 | site-packages | 低（不引入新 FFmpeg 副本） |
| `Plugins/hostcrypto.py` + `Plugins/lxml` 等 | 本工程原创 | 本工程许可 | 直接复制 | 低 |

- **发布义务**：CPython(PSF) 与各 pip 包均需在声明文件列出；certifi(MPL-2.0) 需提供可修改源码途径（pyc 删除已确保随包为源码形式）。
- **风险等级**：**低**
- **整改建议**：补一份 Python 依赖 NOTICE（含 CPython 版本、各 pip 包许可证），与 `THIRD-PARTY-NOTICES` 合并。

---

## 2. 重点评估：GPL 组件（Unicorn、Keystone）与闭源 SDK 同包分发的冲突

### 2.1 事实链
1. `libTVAppleRuntime.a` 经 `-Wl,-force_load` **静态**并入主二进制 `CCTVHost`。
2. 该 `.a` 内含 **Unicorn（GPL-2.0）** 与 **Keystone（GPL-2.0）**，二者均**无 Classpath Exception、无“or later”明示**（`RuntimeLicenses` 仅为 GPL-2.0 文本；UPSTREAM-NOTICES 亦仅写“GPL-2.0”）。
3. 同一 `CCTVHost` 二进制**动态链接**闭源 `CNPlayerSDK.framework`（央视专有 + 内嵌 IJK FFmpeg）、闭源 `CicadaPlayerSDK.framework`（阿里专有）。
4. 同一 IPA 还含 `CCTVMPVCore.framework`（LGPL，动态、可替换）、`NodeMobile.framework`（MIT）、yangshipin.bundle.js（GPL-3.0）等。

### 2.2 冲突判定
- **静态链接触发 copyleft**：Unicorn/Keystone 的 GPL-2.0，对“静态链接进同一可执行文件”的认定几乎无争议——整个 `CCTVHost` 主二进制成为 GPL-2.0 衍生作品，必须以 GPL-2.0 对应源码公开。**闭源 CNPlayerSDK/CicadaPlayerSDK 的专有代码无法满足 GPL-2.0 源码公开义务 → 同包分发构成许可证违约。** 这是**第 1 项高风险**。
- **GPL-2.0 vs GPL-3.0 互斥**：tvbox-silicon 上游为 **GPL-3.0-only**，而 Unicorn/Keystone 为 **GPL-2.0（疑似 only）**。GPL-2.0-only 与 GPL-3.0-only **不可单向升级组合**——若 Unicorn/Keystone 不带“or later”，则二者无法在同一衍生作品内合法共存。即便 Unicorn/Keystone 实为“GPL-2.0-or-later”，组合产物仍须同时满足 GPL-3.0（源码公开）与 GPL-2.0，闭源 SDK 依旧违约。UPSTREAM-NOTICES 自承“如何将 Unicorn/Keystone 的 GPL-2.0 适用于内嵌该运行时的 App 仍是开放问题”，印证未决。这是**第 2 项高风险**。
- **OpenJDK 的 CPE 不救场**：Classpath Exception 仅豁免 OpenJDK 自身，**不覆盖 Unicorn/Keystone**，故不能据此豁免上述冲突。
- **GPL-3.0 JS（yangshipin）与闭源 SDK 同 IPA**：yangshipin.bundle.js（GPL-3.0）随 IPA 分发。JS 与原生二进制是否构成“单一组合作品”存解释空间，但 GPL-3.0 对“聚合+深度互调”倾向认定传染；与闭源 SDK 同包存在**第 3 项高风险**（次级，因 JS 边界相对可隔离，但需法务确认）。
- **LGPL 侧（CCTVMPVCore、alivcffmpeg）无 GPL 冲突**：均为 LGPL/宽松许可，且 CCTVMPVCore 动态可替换、构建脚本随包；alivcffmpeg 动态可替换。仅源码声明/承诺文案缺失，属可补救的义务履行问题，非 copyleft 冲突。

### 2.3 结论
当前工程状态下，**公开分发 unsigned IPA 将同时违反 GPL-2.0（Unicorn/Keystone）与 GPL-3.0（tvbox-silicon、yangshipin）相对闭源 SDK 的义务**，且 GPL-2.0-only 与 GPL-3.0-only 之间可能直接互斥。**不应在未整改前公开发布。**

---

## 3. 整改建议（优先级排序）

1. **【高·阻断发布】解耦 Unicorn/Keystone 与闭源 SDK。** 三选一：
   - (a) 将 JAR 运行时（含 Unicorn/Keystone/OpenJDK）从主二进制剥离为**独立动态库/独立进程**，并使主二进制不与其静态合并，配合法务对“动态链接+独立进程”是否足以解除 GPL 组合认定的复核；
   - (b) 替换 Unicorn/Keystone 为非 GPL 等价物（如基于 Capstone(bsd)/自研模拟器），消除 GPL-2.0 触发源；
   - (c) 取得 Unicorn/Keystone 版权方的**商业/例外许可**（书面），并解决与 tvbox-silicon GPL-3.0 的兼容（需上游声明“GPL-2.0-or-later”或换用兼容上游）。
2. **【高·阻断发布】解决 tvbox-silicon GPL-3.0 与闭源 SDK 同包。** 同上剥离思路，或更换为非 GPL 的 JVM 宿主/DEX 运行方案；若保留，则主二进制及全部同包专有代码须能以 GPL-3.0 公开源码（对 CNPlayerSDK/CicadaPlayerSDK 不现实，故实质必须剥离）。
3. **【高·阻断发布】CNPlayerSDK 内嵌 IJK FFmpeg 的 LGPL 可替换性。** 推动央视 SDK 提供方以动态独立库提供 FFmpeg 切片或提供可重链接产物；否则整包分发不可满足 LGPL-2.1+。
4. **【中】补 GBP/LGPL 源码声明与可替换说明。** 新增并随包分发统一 `THIRD-PARTY-NOTICES.txt`，至少含：FFmpeg(n4.2.1@alivcffmpeg、n8.1.2@CCTVMPVCore、ff3.2-ijk@CNPlayerSDK)、mpv 0.41.0、libass 0.17.5、MoltenVK 1.4.2、gnutls/gmp/nettle/hogweed 3.8.11、fribidi/harfbuzz/freetype/unibreak、libbluray 1.4.0、libuchardet、libdovi/dav1d/uavs3d、lcms2、libshaderc、libplacebo、OpenJDK mobile、Unicorn/Keystone/Capstone/unidbg/JNA/libffi/dex2jar/DexLoom、Node.js Mobile 18.20.4、CPython 3.13、yangshipin(GPL-3.0,commit b121ed0)、drpy(LGPL-3.0,commit ca23ffd)、FongMi/TV 资产、各 pip 包。对每个 LGPL/GPL 组件给出 3 年有效源码获取方式与替换步骤。
5. **【中】核对 libbluray / gmp 的 GPL-2.0-or-later 取证。** 确认 MPVKit 1.0.0 的 Package.swift 中 libbluray 是否按 LGPL 配置（关闭 BD-Java 等 GPL 选项）；gmp 为 GPL-2.0-or-later，与 LGPL gnutls 链接需确认 nettle 对 gmp 的使用方式不触发 GPL。
6. **【中】yangshipin/drpy/FongMi JS 边界法务复核。** 明确 GPL-3.0 JS 与主程序是否构成组合作品；必要时将 JS 资源以“用户可选下载、非默认随包”形式剥离，仅随包附带 NOTICE 与源 commit。
7. **【低】SDK 商用授权凭证归档。** 留存央视 CNPlayerSDK、阿里 CicadaPlayerSDK 的授权记录并在声明中标注。
8. **【低】Python 依赖 NOTICE。** 合并 certifi(MPL-2.0) 等的可修改源码声明（随包已是 .py 源码，满足）。

---

## 4. 风险等级汇总

| # | 组件/问题 | 许可证 | 随包 | 链接 | 风险 | 是否阻断发布 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Unicorn（JAR 内） | GPL-2.0 | 是（静态并入主二进制） | 静态 | **高** | 是 |
| 2 | Keystone（JAR 内） | GPL-2.0 | 是（静态并入主二进制） | 静态 | **高** | 是 |
| 3 | tvbox-silicon JAR 上游 | GPL-3.0-only | 是（静态并入主二进制） | 静态 | **高** | 是 |
| 4 | CNPlayerSDK + 内嵌 IJK FFmpeg | 专有 + LGPL-2.1+(FFmpeg) | 是 | 动态 | **高**（授权缺失+LGPL可替换性不满足） | 是 |
| 5 | yangshipin.bundle.js | GPL-3.0-only | 是 | 资源 | **高**（与闭源 SDK 同包） | 是 |
| 6 | CicadaPlayerSDK | 专有（阿里云） | 是 | 动态 | 中 | 否（需补授权凭证） |
| 7 | alivcffmpeg | LGPL-2.1+ | 是 | 动态 | 中 | 否（需补源码声明/替换说明） |
| 8 | CCTVMPVCore（mpv+FFmpeg LGPL 闭包） | LGPL-2.1+/宽松 | 是 | 动态(内部静态拼装) | 低-中 | 否（需补 NOTICE，核对 libbluray/gmp） |
| 9 | OpenJDK mobile | GPL-2.0+CPE | 是 | 静态并入主二进制 | 中（CPE 豁免组合） | 否 |
| 10 | drpy / FongMi 资产 | LGPL-3.0 / GPL-3.0 | 待确认入包 | 资源 | 中 | 视入包情况 |
| 11 | Node.js Mobile 18.20.4 | MIT+第三方声明 | 是 | 动态 | 低 | 否 |
| 12 | CPython 3.13 + pip 包 | PSF/MIT/BSD/Apache/MPL | 是 | 动态+解释 | 低 | 否 |
| 13 | Capstone/unidbg/JNA/dex2jar/libffi/DexLoom | BSD/Apache/MIT | 是 | 静态并入主二进制 | 低 | 否 |

---

## 5. 审计边界与不确定性（须法务/上游确认）

1. **Unicorn/Keystone 的 “GPL-2.0-only vs or-later”**：本审计仅依据 `RuntimeLicenses` 文本与 `UPSTREAM-NOTICES.md` 记述，未逐源文件核对上游版权头。若任一为 “GPL-2.0-or-later”，则 GPL-2.0↔GPL-3.0 互斥风险降级为“二者均须公开源码”，但与闭源 SDK 的冲突**仍然存在**。
2. **libbluray 是否纯 LGPL 配置**：依赖 MPVKit 1.0.0 的 Package.swift 取证，本审计未联网拉取该文件。
3. **drpy2.js/FongMi 资产是否进入最终 bundle**：需对 `GeneratedJS/*.bundle.js` 做打包内容比对（本审计未执行构建）。
4. **JAR 运行时剥离为独立动态库后是否能解除 GPL 组合认定**：属法律解释，需法务出具意见。
5. **CNPlayerSDK/CicadaPlayerSDK 的上游授权条款**：本审计未取得两家 SDK 的在线协议原文，仅依据 bundle id 与构建痕迹判定为专有。

本报告为只读审计，未修改任何代码或构建产物。
