# CCTV-1 的 SDK 自动播放检查

日期：2026-11-05。用户确认失败项为 CCTV-1 的“SDK 自动选择”。本记录检查宿主配置与随包 CNPlayer SDK 的公开配置调用路径，不请求许可证、不提取凭据或密钥，不修改 SDK 二进制。

## 已证实的配置错配

宿主此前在 `RootViewController.m` 的 `setupSDK` 中、SDK 启动调用之前尝试调用：

```objc
configSDK_CICADA_UDRMUrl:
```

传入的硬编码值为 `https://drm.live.cntv.cn:444/udrm/udmCNTVGetLicense`。随包 SDK 将这个地址作为 **IJK** 路径的默认值；**Cicada** 路径的默认值为 `https://cdrm.live.cntv.cn/udrm/udmCNTVGetLicense`，使用 HTTPS 默认端口 443。这个调用的参数存在内核归属错配；是否实际写入，还受到下文的组件注册条件限制。

静态检查对象：

- 文件：`Frameworks/CNPlayerSDK.framework/CNPlayerSDK`
- SHA-256：`e8556692053692ef89b264105931f4eed979132d1d275fa937a1d41c3fe4a9fe`
- 架构：arm64 Mach-O；下列地址属于这一固定文件，不是运行时加载地址。

| 配置读取方法 | 方法 IMP | 配置键 | 未配置时使用的默认值 |
| --- | --- | --- | --- |
| `+[CNVDNConfigManager getVDNConfig_IJKDrmUrl]` | `0x1abf80` | `CNVDNConfig_IJKDrmUrl` | `https://drm.live.cntv.cn:444/udrm/udmCNTVGetLicense` |
| `+[CNVDNConfigManager getVDNConfig_CicadaUDrmUrl]` | `0x1ac04c` | `CNVDNConfigKey_CicadaUDrmUrl` | `https://cdrm.live.cntv.cn/udrm/udmCNTVGetLicense` |

IJK getter 在 `0x1abfe4` 判断查询结果为空时跳到 `0x1abff8`，加载 CFString `0x8bbd48`。Cicada getter 在 `0x1ac0b0` 判断为空时跳到 `0x1ac0c4`，加载 CFString `0x8bbae8`。两份 CFString 分别包含上表中的默认 URL。

## 启动前调用能否实际写入

不能仅凭宿主调用了一次 setter，就认定已覆写 SDK。顶层配置接口依赖组件注册：

- `+[CNPlayer configSDK_CICADA_UDRMUrl:]` 在 `0x79860` 通过 `CNPlayerRouter` 查找实现，再尝试调用同名配置方法。
- `+[CNPlayerRouter implementerForProtocol:]`，IMP `0x656e8`，在 `0x65724` 查询协议注册表，并在 `0x65744` 调用 `validateForImplementer:`。未取得合适实现时，不会得到正常的配置实现。
- `+[CNPlayerStartManager configSDK_CICADA_UDRMUrl:]` 在 `0xc22c` 再查询 VDN 实现，在 `0xc24c` 校验；只有通过校验且在 `0xc3f4` 符合相应协议，才进入 `0xc40c` 的配置写入调用。
- `-[CNPlayerRegister implementerForProtocol:]`，IMP `0x22854c`，只按协议名查字典；注册字典 getter `protocols_implementersDic`，IMP `0x229380`，在成员为空时创建空字典，没有在这个 getter 中自动填入默认实现。正常组件注册可见于 `startComponentSDK`，而宿主此次调用顺序将地址 setter 放在它之前。

本次没有证明在宿主这次 setter 调用时，目标组件已经注册。因此不能声称旧代码在每次冷启动都成功写入了错误地址；它可能在注册校验阶段未生效。这也意味着“删除覆写”是移除错误参数与多余启动前调用，不能单独当作用户本次 CCTV-1 故障已经定位或已经解决的证据。需要设备日志记录该调用结果、真实内核及实际使用的地址配置，才能把它与故障建立运行时因果关系。

## 自动播放会消费这个配置

覆写的调用链可由 Objective-C 方法及调用目标复核：

1. `+[CNPlayer configSDK_CICADA_UDRMUrl:]`，IMP `0x79704`，在 `0x79884` 转发同名配置方法。
2. `+[CNPlayerStartManager configSDK_CICADA_UDRMUrl:]`，IMP `0xc1ec`，在 `0xc40c` 调用 `startVDNConfig_CicadaUDrmUrl:`。
3. `CNVDNManager` 转交 `CNVDNConfigManager`；后者实例方法 IMP `0x1adb00` 在 `0x1adb74` 向配置字典调用 `setValue:forKey:`。
4. `-[CNLiveCicadaPlayer configPlayerCoreForUrl:]`，IMP `0x17d5e0`，在 `0x17e56c` 调用 `getVDNConfig_CicadaUDrmUrl`，在 `0x17e588` 将结果传给 `setUdrmLicenseUrl:`，随后在 `0x17e5ac` 调用 `setConfig:`。

因此，**若地址配置调用已通过注册校验并成功写入**，SDK 为当前直播会话使用 `CNLiveCicadaPlayer` 时会读取这个配置。这个配置项会影响自动直播，并非仅影响手选地址；但静态消费链不能证明启动前的那次调用已经成功。

修复应删除宿主的多余硬编码覆写，让官方 SDK 选择各内核自身的配置与默认值。不能把 IJK 地址改写到其他内核，也不应猜测许可证请求参数来替代 SDK 授权流程。

## 启动默认选项与升级后的状态

宿主的覆写尝试发生在 `startPlayerSDK_Options:[CNPlayer defaultOptions]` 之前。本次继续核对了启动顺序：对**已经成功写入**的配置，不能假设后面的启动调用会清除；但默认选项没有清除逻辑，也不能反过来证明启动前 setter 已经被接受。

- `+[CNPlayer defaultOptions]`，IMP `0x744fc`，构造六个统计选项键：`CNPlayerSDKStartOptionKey_HbssInterval_VOD_Stat`、`CNPlayerSDKStartOptionKey_HbssInterval_LIVE_Stat`、`CNPlayerSDKStartOptionKey_HbssInterval_Stat_SE`、`CNPlayerSDKStartOptionKey_APPName_Stat`、`CNPlayerSDKStartOptionKey_PlayScene_Stat`、`CNPlayerSDKStartOptionKey_BigDataEnabled_Stat`。其中没有 DRM 或许可证地址键。本次仅记录公开键名，未提取启动凭据或其他选项值。
- `+[CNPlayerStartManager startComponentSDK]`，IMP `0x414c`，注册组件并调用各组件的 `startSDK`。`+[CNVDNManager startSDK]`，IMP `0x11587c`，安排 `initConfig`；后者 IMP `0x115b1c` 调用动态、备用、静态直播配置读取。已检查的启动调用路径没有清空或替换 `vdnConfigDict`，也没有重新调用 Cicada 地址配置 setter。
- 对该固定 SDK 的 `__text` 直接调用扫描中，`startVDNConfig_CicadaUDrmUrl:` 仅有上述配置包装层的三个调用点：`0xc40c`、`0x102060`、`0x1a8e08`；没有来自启动方法的直接调用。`setVdnConfigDict:` 没有直接调用点。

覆写保存于进程内：`-[CNVDNConfigManager vdnConfigDict]`，IMP `0x1b08d4`，检查实例偏移 `+8` 的成员；为空时通过 `dictionary` 创建字典并保存在该成员中。`setVdnConfigDict:`，IMP `0x1b0944`，仅对成员执行对象赋值。具体的 Cicada 地址 setter `0x1adb00` 只校验字符串长度并向这个字典 `setValue:forKey:`；读取路径 `getConfigForKey:`，IMP `0x1aeb5c`，也从同一个字典取值。这些已检查的配置读写路径没有文件或 `NSUserDefaults` 持久化调用。

因此，修复版 App 在新进程启动后无需迁移或删除旧 SDK 配置。应通过正常重启加载修复代码，不猜测清理 SDK 的内部缓存。这里的结论覆盖上述已检查的地址配置与启动路径，未把静态检查扩大为对 SDK 所有后续动态行为的完整证明。

## 本地复核方法

在 `cctv-ios-host/` 运行以下只读命令。它复用 `Scripts/audit_ipa_live_routes.py` 的 Mach-O 读取器与 `../tools/ipa/objc-method-index.py`，打印配置读取方法引用的字符串以及关键调用目标；不加载或执行 SDK。

```sh
python3 - <<'PY'
import hashlib
import importlib.util
import struct
from pathlib import Path

spec = importlib.util.spec_from_file_location('audit', 'Scripts/audit_ipa_live_routes.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)
data = Path('Frameworks/CNPlayerSDK.framework/CNPlayerSDK').read_bytes()
expected = 'e8556692053692ef89b264105931f4eed979132d1d275fa937a1d41c3fe4a9fe'
assert hashlib.sha256(data).hexdigest() == expected, 'SDK changed; re-audit addresses'
reader = audit.MachO(data)
classes = audit.index(data)
starts = sorted({int(m['imp'], 16) for c in classes.values()
                 for kind in ('class', 'instance') for m in c[kind]})
cfbase, cfsize = reader.sections['__cfstring']

def method(cls, kind, name):
    item = next(m for m in classes[cls][kind] if m['name'] == name)
    start = int(item['imp'], 16)
    return start, next(value for value in starts if value > start)

def literal_refs(start, end):
    for site in range(start, end - 7, 4):
        adrp, add = struct.unpack('<II', reader.at(site, 8))
        reg = adrp & 31
        if adrp & 0x9f000000 != 0x90000000 or add & 0xff000000 != 0x91000000:
            continue
        if add & 31 != reg or (add >> 5) & 31 != reg:
            continue
        offset = ((add >> 10) & 4095) << (12 if add & (1 << 22) else 0)
        address = audit.adrp_target(adrp, site) + offset
        if not cfbase <= address < cfbase + cfsize:
            continue
        string = reader.pointer(address + 16)
        length, = struct.unpack('<Q', reader.at(address + 24, 8))
        print(hex(site), hex(address), reader.at(string, length).decode())

for name in ('getVDNConfig_IJKDrmUrl', 'getVDNConfig_CicadaUDrmUrl'):
    start, end = method('CNVDNConfigManager', 'class', name)
    print(name, hex(start), hex(end))
    literal_refs(start, end)

for cls, kind, name in (
    ('CNPlayer', 'class', 'configSDK_CICADA_UDRMUrl:'),
    ('CNPlayerStartManager', 'class', 'configSDK_CICADA_UDRMUrl:'),
    ('CNPlayerRouter', 'class', 'implementerForProtocol:'),
    ('CNPlayerRegister', 'instance', 'implementerForProtocol:'),
    ('CNPlayerRegister', 'instance', 'protocols_implementersDic'),
    ('CNVDNConfigManager', 'instance', 'startVDNConfig_CicadaUDrmUrl:'),
    ('CNLiveCicadaPlayer', 'instance', 'configPlayerCoreForUrl:'),
    ('CNPlayerStartManager', 'class', 'startComponentSDK'),
    ('CNVDNManager', 'class', 'startSDK'),
    ('CNVDNManager', 'class', 'initConfig'),
    ('CNVDNConfigManager', 'instance', 'vdnConfigDict'),
    ('CNVDNConfigManager', 'instance', 'setVdnConfigDict:'),
    ('CNVDNConfigManager', 'instance', 'getConfigForKey:'),
):
    start, end = method(cls, kind, name)
    print(cls, kind, name, hex(start), reader.calls(start, end))

# The six public key slots loaded by defaultOptions; print names only, not values.
for slot in range(0x8627a0, 0x8627d0, 8):
    string_object = reader.pointer(slot)
    string = reader.pointer(string_object + 16)
    length, = struct.unpack('<Q', reader.at(string_object + 24, 8))
    name = reader.at(string, length).decode()
    assert name.startswith('CNPlayerSDKStartOptionKey_')
    print('defaultOptions key', hex(slot), name)

stub_base, stub_size = reader.sections['__objc_stubs']
targets = {}
for address in range(stub_base, stub_base + stub_size - 8, 4):
    try:
        selector = reader.selector_stub(address)
    except (ValueError, UnicodeDecodeError):
        continue
    if selector in ('setVdnConfigDict:', 'startVDNConfig_CicadaUDrmUrl:'):
        targets[address] = selector
text_base, text_size = reader.sections['__text']
for offset, (opcode,) in enumerate(struct.iter_unpack('<I', reader.at(text_base, text_size - text_size % 4))):
    site = text_base + offset * 4
    target = audit.branch_target(opcode, site)
    if target in targets:
        print('direct config caller', hex(site), targets[target])
PY
```

如需逐条查看 getter 的条件分支，可对上述固定 IMP 区间使用 arm64 反汇编器（本次使用 Capstone），核对 `cbz` 分支及紧随的 `adrp` / `add` 字符串加载。仅搜索二进制是否包含 URL 字符串，无法单独证明它属于哪个内核；应同时复核方法归属与调用目标。

## 当前证据边界

端点参数归属错配及直播 Cicada 读取该配置项的调用关系已经静态证实。宿主启动前的 setter 是否成功写入尚未证实，故不能把这处调用直接认定为用户本次 CCTV-1 故障的根因。设备错误回调、实际内核与使用中的配置仍需运行日志确认；当前未取得这份日志。删除多余错误调用及修复恢复流程都不等于已验证出画，源码测试、HTTP 清单可读和静态调用分析均不能替代真机首帧、持续播放与前后台切换验证。

此外，CCTV-1 的 WS / BD / KS 手选地址含 `/udrm`，主、子清单可读且没有标准 `EXT-X-KEY` 标签；这仍不能证明媒体为明文。手选路由应保留在官方 SDK 路径。该手选误判是独立问题，不能据此解释用户已确认的“SDK 自动选择”故障。

## 自动起播超时恢复

用户确认 CCTV-1 的“SDK 自动选择”表现为持续转圈、随后起播超时。宿主现在对自动线路增加一次限额恢复：如果 25 秒内没有首帧，会停止并释放原播放器，再创建全新 `CNPlayer`，按 SDK 默认配置重新请求同一个频道 ID。恢复时关闭频道预加载和快速启动调优，避免沿用预加载实例或启动期参数。已有的“VDN 成功但未建立内核”恢复也使用同一份一次性预算，避免重复恢复。

单次起播最多等待 25 秒，从首次请求起总计最多等待 50 秒；若第二次仍未首帧，宿主停止 SDK 会话、结束转圈并显示“起播超时”。鉴权、版权和参数错误仍按 SDK 明确错误处理，不盲目重试；手选线路与时移不走此恢复分支。恢复原因、耗时、阶段摘要和安全的 SDK 频道 ID 会写入诊断事件 `native_startup_recovery_started`，不记录完整线路 URL。

该恢复改进针对用户描述的无回调或无首帧超时，不代表已证明故障源于某个具体频道服务端，也不代表已在真机出画。需要在装有目标 SDK 的 iOS 设备上重建并实际观察 CCTV-1 首帧及连续播放，才能确认结果。
