# 三个剧场频道 v9.5.13 实测

日期：2026-10-18 UTC。执行环境为当前 Linux 云环境；不等同用户 iOS/TUN 网络。检查通过正常上游接口进行，没有加入登录凭据或改变频道标识。

## 发现与修复

这三个频道在原版的默认参数均为 shd。优化版将全频道改成 best，JCE/BK 接口将 best 映射成 fhd，因此请求了更高档位。本次 fhd 全部返回 `iretcode=25 无登录信息`，shd 全部可取得媒体列表。这是档位相关的拒绝，不能据此判断整个频道不可用。

新版先尝试 fhd，被明确拒绝后才尝试原版 shd，五分钟内记住可用请求档位，之后重新探测 fhd。正常超时、普通频道不走该特殊回退。若两个档位都要求登录，仍返回真实失败并单频道退避。

## 结果

| 频道 | fhd 接口 | shd 列表/分片 | ffprobe 视频信息 | 视频解码 |
|---|---|---|---|---|
| CCTV 风云剧场 | iretcode=25 | 成功 / HTTP 200 | 1280×720 H.264 25fps | 25 帧通过 |
| CCTV 第一剧场 | iretcode=25 | 成功 / HTTP 200 | 1280×720 H.264 25fps | 25 帧通过 |
| CCTV 怀旧剧场 | iretcode=25 | 成功 / HTTP 200 | 1280×720 H.264 25fps | 25 帧通过 |

每个频道通过新版 refresh_once 执行 best→fhd 被拒绝→shd 回退，确认本地 HTTP 网关返回 200 与有效 HLS 列表，再下载当前媒体列表倒数第二片（单片上限 16MiB），用 ffprobe 确认视频/音频信息，用 ffmpeg 解码 25 帧视频，退出码为 0 且错误输出为空。没有进行音频解码听感、长时间连续播放或用户播放器首帧验收。

原版 shd 的 JCE 仍返回旧 liverecord CDN 地址，直接读取返回 HTTP 403；本次可用通路是 BK。不能承诺更高档之后一定恢复，也不将接口档位名冒充实际分辨率；上表分辨率来自实际下载分片的 ffprobe。

## 脱敏记录

```json
[
  {
    "slug": "cctvfyjc",
    "name": "CCTV 风云剧场",
    "checked_at": "2026-10-18T00:21:20.245709+00:00",
    "requested_quality": "best",
    "playlist": true,
    "elapsed_seconds": 2.33,
    "backup_api_quality": "shd",
    "gateway_status": 200,
    "gateway_source": "backup:bk",
    "gateway_valid_hls": true,
    "segments": 3,
    "segment_status": 200,
    "segment_bytes": 823628,
    "streams": [
      {
        "codec_name": "h264",
        "codec_type": "video",
        "width": 1280,
        "height": 720,
        "avg_frame_rate": "25/1"
      },
      {
        "codec_name": "aac",
        "codec_type": "audio",
        "avg_frame_rate": "0/0"
      }
    ],
    "ffprobe_ok": true,
    "video_decode_ok": true,
    "decode_stderr_bytes": 0
  },
  {
    "slug": "cctvdyjc",
    "name": "CCTV 第一剧场",
    "checked_at": "2026-10-18T00:21:24.347125+00:00",
    "requested_quality": "best",
    "playlist": true,
    "elapsed_seconds": 1.93,
    "backup_api_quality": "shd",
    "gateway_status": 200,
    "gateway_source": "backup:bk",
    "gateway_valid_hls": true,
    "segments": 3,
    "segment_status": 200,
    "segment_bytes": 1179324,
    "streams": [
      {
        "codec_name": "h264",
        "codec_type": "video",
        "width": 1280,
        "height": 720,
        "avg_frame_rate": "25/1"
      },
      {
        "codec_name": "aac",
        "codec_type": "audio",
        "avg_frame_rate": "0/0"
      }
    ],
    "ffprobe_ok": true,
    "video_decode_ok": true,
    "decode_stderr_bytes": 0
  },
  {
    "slug": "cctvhjjc",
    "name": "CCTV 怀旧剧场",
    "checked_at": "2026-10-18T00:21:28.076451+00:00",
    "requested_quality": "best",
    "playlist": true,
    "elapsed_seconds": 1.76,
    "backup_api_quality": "shd",
    "gateway_status": 200,
    "gateway_source": "backup:bk",
    "gateway_valid_hls": true,
    "segments": 3,
    "segment_status": 200,
    "segment_bytes": 1181204,
    "streams": [
      {
        "codec_name": "h264",
        "codec_type": "video",
        "width": 1280,
        "height": 720,
        "avg_frame_rate": "25/1"
      },
      {
        "codec_name": "aac",
        "codec_type": "audio",
        "avg_frame_rate": "0/0"
      }
    ],
    "ffprobe_ok": true,
    "video_decode_ok": true,
    "decode_stderr_bytes": 0
  }
]
```
