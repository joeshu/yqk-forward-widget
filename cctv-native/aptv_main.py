"""APTV entry point: start HTTP listener before any official network requests."""
def main(argv=None):
    global _API_LEGACY_ENABLED, _HTTP_REUSE_ENABLED
    parser = argparse.ArgumentParser(description='央视官网多频道 APTV 实验版（系统JavaScriptCore，无Node/子进程）')
    parser.add_argument('port', type=int, nargs='?', default=18768)
    parser.add_argument('--bind', default='127.0.0.1')
    parser.add_argument('--cache-dir', default=None, help='可选磁盘缓存目录；默认仅内存，无需文件写入权限')
    parser.add_argument('--warmup', action=argparse.BooleanOptionalAction, default=True,
                        help='默认 GET 订阅时提前准备频道；--no-warmup 可关闭')
    parser.add_argument('--no-legacy-source-tls',action='store_true',help='关闭仅官方取源接口的旧服务器握手兼容')
    parser.add_argument('--parallel-prepare',action=argparse.BooleanOptionalAction,default=True,
                        help='并行初始化组件与准备首批分片；--no-parallel-prepare 可关闭')
    parser.add_argument('--prefix-lookahead', action=argparse.BooleanOptionalAction, default=True,
                        help='首播仅下载第三片的已校验边界前缀；不支持时自动下载整片')
    parser.add_argument('--no-http-reuse', action='store_true', help='关闭上游 HTTPS 连接复用')
    parser.add_argument('--recent-channel-seconds', type=int, default=15,
                        help='最近一个频道的组件保留秒数（0 关闭，最多 30）；过旧分片不直接播放')
    parser.add_argument('--buffer-mb', type=int, default=32)
    parser.add_argument('--idle-timeout', type=int, default=120)
    parser.add_argument('--jscore-library', default=APPLE_FRAMEWORK, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    _API_LEGACY_ENABLED = not args.no_legacy_source_tls
    _HTTP_REUSE_ENABLED = not args.no_http_reuse
    if not 1 <= args.port <= 65535 or not 16 <= args.buffer_mb <= 256 or not 30 <= args.idle_timeout <= 3600 or not 0 <= args.recent_channel_seconds <= 30:
        parser.error('invalid port/buffer/idle timeout/recent channel seconds')
    manager = ChannelManager(args)
    server = ThreadingHTTPServer((args.bind, args.port), MultiChannelHandler)
    server.daemon_threads = True
    server.manager, server.args = manager, args
    print(f'APTV 央视网页原分片实验版：http://127.0.0.1:{args.port}/all.m3u', flush=True)
    print('状态：/status；同源多频道，按需加载。首次选台下载并校验官方组件（默认内存缓存，不写磁盘）。', flush=True)
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        manager.close()
        _HTTP_POOL.clear()
        server.server_close()



def start(ctx=None):
    """Entry for embedded runners that import the file and invoke start(ctx)."""
    main([])


if __name__ == '__main__':
    main()
