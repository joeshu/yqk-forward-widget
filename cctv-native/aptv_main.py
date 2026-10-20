"""APTV entry point: start HTTP listener before any official network requests."""
def main(argv=None):
    parser = argparse.ArgumentParser(description='CCTV-2 APTV 实验版（系统JavaScriptCore，无Node/子进程）')
    parser.add_argument('port', type=int, nargs='?', default=18768)
    parser.add_argument('--bind', default='127.0.0.1')
    parser.add_argument('--cache-dir', default=None, help='可选磁盘缓存目录；默认仅内存，无需文件写入权限')
    parser.add_argument('--warmup', action=argparse.BooleanOptionalAction, default=True,
                        help='默认 GET 订阅时提前准备频道；--no-warmup 可关闭')
    parser.add_argument('--buffer-mb', type=int, default=32)
    parser.add_argument('--idle-timeout', type=int, default=120)
    parser.add_argument('--jscore-library', default=APPLE_FRAMEWORK, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if not 1 <= args.port <= 65535 or not 16 <= args.buffer_mb <= 256 or not 30 <= args.idle_timeout <= 3600:
        parser.error('invalid port/buffer/idle timeout')
    channel = Channel(args)
    server = ThreadingHTTPServer((args.bind, args.port), Handler)
    server.daemon_threads = True
    server.channel, server.args = channel, args
    print(f'APTV 央视网页原分片实验版：http://127.0.0.1:{args.port}/all.m3u', flush=True)
    print('状态：/status；仅 CCTV-2。首次选台下载并校验官方组件（默认内存缓存，不写磁盘）。', flush=True)
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        channel.stop.set()
        server.server_close()
        # The worker releases its own JSC VM; never release it across threads.
        if channel.thread:
            channel.thread.join(35)


def start(ctx=None):
    """Entry for embedded runners that import the file and invoke start(ctx)."""
    main([])


if __name__ == '__main__':
    main()
