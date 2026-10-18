# 三个剧场 v9.5.19 复核

日期：2026-10-18 UTC；当前 Linux 云环境，通过 urllib 与系统代理请求公开接口，没有加入个人账号凭据。此次检查不是用户 iOS/TUN 环境的长时间播放验收。

## 已复现的代码问题

1. 9.5.18 在存在健康 shd 地址、fhd 重试到期的情况下，先请求 fhd；模拟该请求超时，`refresh_once=False`，健康列表请求次数为 0。
2. 首个 CDN 超时、第二个成功后，旧版下一次仍先请求坏节点，调用顺序是 `bad, good, bad, good`；修复后为 `bad, good, good`。这是离线调用序列对照，不是播放器首帧基准。
3. 后台“最近刷新”原先使用也会被发布旧缓存更新的时间戳。本版以 `last_ok` 作为实际取源成功依据。

## 本地回归结果

完整 342 项 Python 回归通过，新增 22 项剧场测试，包括：旧版失败对照、坏节点优先级、真实 HTTP 的三个频道在升级 API 等待时仍返回 200、高档位列表/分片拒绝保留原画面、迟到刷新不撤回升级、总/后台容量、取消后不发起下一次分片请求，以及 HTTP 错误响应关闭。

```sh
python3 -m unittest discover -s ysp-live/tests -p 'test_*.py'
```

## 当前上游检查

三个频道均在三轮列表取样中观察到媒体序号推进。fhd 仍返回上游登录拒绝，当前可用档位为 shd；实际分辨率由下载分片的 ffprobe 确认。

| 频道 | 列表取样 | 实测视频 | 解码 |
|---|---|---|---|
| 风云剧场 | 3 次成功，序号推进 | 1280×720，H.264，25fps | 25 帧通过 |
| 第一剧场 | 3 次成功，序号推进 | 复核为 1280×720，H.264，25fps | 换新地址后两个候选 CDN 各 25 帧通过 |
| 怀旧剧场 | 3 次成功，序号推进 | 1280×720，H.264，25fps | 25 帧通过 |

**第一剧场的分片首次返回 HTTP 403。** 随后重新请求公开 shd 地址，两个候选 CDN 分别返回 HTTP 200、1,589,540 / 1,273,888 字节，均通过视频信息和解码检查。没有观察到代理策略拒绝标记；也没有足够证据确定第一次 403 的具体原因。不能将该波动归因于设备注册，或宣称已经完全消除。

另一次 Range 前缀检查中 CDN 忽略 Range 并返回完整内容，工具按读取上限停止；正式分片复核使用普通 GET 和 8MiB 上限。生产代码已有的 Range 不兼容回退、有界内容探测保持不变。

## 修复边界

- 只对正在观看、已经有可用档位的三个剧场进行可选高档位探测，不预热整个频道目录；总/后台并发和全局请求间隔保持。
- 新高档位先验证媒体列表，默认启用媒体探测时还要验证有界分片前缀；未验证、被拒绝、明显更低声明都保留当前来源。关闭媒体探测时仅验证列表，不把前缀检查称为解码。
- 暂时失败的高档位重试不清掉正常线路，不进入整个频道的登录冷却；原有登录权限不被绕过，不能承诺未来能取得 1080p。
- 仍需用户播放器验证长时间播放；如果继续中断，需要对应时刻的日志区分接口拒绝、列表冻结、分片 403 和网络超时。

## 脱敏列表取样记录

不包含播放地址、签名或设备标识。`ok` 表示列表刷新成功；分片检查失败单独标注，不等于视频已通过。

```json
[
  {
    "channel": "cctvfyjc",
    "cycle": 0,
    "ok": true,
    "elapsed_ms": 3960,
    "quality": "shd",
    "segments": 3,
    "target": 5.0,
    "sequence": 1786539206,
    "signature": "d2f199c77a55"
  },
  {
    "channel": "cctvdyjc",
    "cycle": 0,
    "ok": true,
    "elapsed_ms": 3535,
    "quality": "shd",
    "segments": 3,
    "target": 6.0,
    "sequence": 1785717154,
    "signature": "9e0f053de25a"
  },
  {
    "channel": "cctvhjjc",
    "cycle": 0,
    "ok": true,
    "elapsed_ms": 2835,
    "quality": "shd",
    "segments": 3,
    "target": 5.0,
    "sequence": 1786533266,
    "signature": "3bb7c1ef5b00"
  },
  {
    "channel": "cctvfyjc",
    "cycle": 1,
    "ok": true,
    "elapsed_ms": 608,
    "quality": "shd",
    "segments": 3,
    "target": 8.0,
    "sequence": 1786539207,
    "signature": "c15a389ae20d"
  },
  {
    "channel": "cctvdyjc",
    "cycle": 1,
    "ok": true,
    "elapsed_ms": 880,
    "quality": "shd",
    "segments": 3,
    "target": 6.0,
    "sequence": 1785717154,
    "signature": "9e0f053de25a"
  },
  {
    "channel": "cctvhjjc",
    "cycle": 1,
    "ok": true,
    "elapsed_ms": 622,
    "quality": "shd",
    "segments": 3,
    "target": 5.0,
    "sequence": 1786533266,
    "signature": "3bb7c1ef5b00"
  },
  {
    "channel": "cctvfyjc",
    "cycle": 2,
    "ok": true,
    "elapsed_ms": 664,
    "quality": "shd",
    "segments": 3,
    "target": 8.0,
    "sequence": 1786539207,
    "signature": "c15a389ae20d",
    "segment_status": 200,
    "segment_bytes": 1016892,
    "video": [
      {
        "codec_name": "h264",
        "width": 1280,
        "height": 720,
        "avg_frame_rate": "25/1"
      }
    ],
    "decode_25_frames": true
  },
  {
    "channel": "cctvdyjc",
    "cycle": 2,
    "ok": true,
    "elapsed_ms": 813,
    "quality": "shd",
    "segments": 3,
    "target": 6.0,
    "sequence": 1785717155,
    "signature": "9201ec91de6c",
    "error_type": "HTTPError",
    "http_status": 403
  },
  {
    "channel": "cctvhjjc",
    "cycle": 2,
    "ok": true,
    "elapsed_ms": 432,
    "quality": "shd",
    "segments": 3,
    "target": 5.0,
    "sequence": 1786533267,
    "signature": "dc448e14778d",
    "segment_status": 200,
    "segment_bytes": 981736,
    "video": [
      {
        "codec_name": "h264",
        "width": 1280,
        "height": 720,
        "avg_frame_rate": "25/1"
      }
    ],
    "decode_25_frames": true
  }
]
```
