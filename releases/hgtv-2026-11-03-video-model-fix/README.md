# HGTV 1.0.5 播放接口修复包

本目录提供 Node 与 Python 两个 CCTVHost 可导入包：

- `HGTV-Node-1.0.5-r5-video-model-fix.zip`
- `HGTV-Python-1.0.5-r4-video-model-fix.zip`

两个包的 ZIP 清单均通过完整性校验。修复针对旧版固定设备参数调用旧模型 POST 接口时返回 HTTP 200 空包的问题，改为使用当前签名 `video_tab` GET 模型接口，并对失败请求轮换临时设备参数。

## 验证

- 两部线上剧集目录分别完整返回 215 集和 300 集；首集、中段、末集模型探测通过。
- 一集 1080p 样例完成下载、Python 与 Node CENC 解密，并通过 MP4 结构校验。
- 相关回归测试 132 项通过。
- 两包带有对应的 SHA-256 校验文件。
