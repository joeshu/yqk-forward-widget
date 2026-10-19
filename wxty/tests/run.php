<?php
declare(strict_types=1);
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
define('WXTY_LIBRARY_ONLY', true);
require dirname(__DIR__) . '/wxty.php';
ini_set('error_log', '/dev/null');
error_reporting(E_ALL);
set_error_handler(static function ($severity, $message, $file, $line) {
    if (error_reporting() & $severity) throw new ErrorException($message, 0, $severity, $file, $line);
    return false;
});

function same($actual, $expected): void
{
    if ($actual !== $expected) throw new RuntimeException('Expected ' . var_export($expected, true) . ', got ' . var_export($actual, true));
}
function raises(callable $fn, string $reason): void
{
    try { $fn(); } catch (WxtyError $error) { same($error->reason, $reason); return; }
    throw new RuntimeException('Expected WxtyError: ' . $reason);
}
function response(string $body, int $status = 200, array $headers = []): array
{
    return ['body' => $body, 'status' => $status, 'headers' => $headers];
}
function apiResponse(array $result): array { return response(json_encode(['result' => $result], JSON_THROW_ON_ERROR)); }
function media(string $segment = 'a.ts'): string { return "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\n" . $segment . "\n"; }
function removeTree(string $dir): void
{
    foreach (array_merge(glob($dir . '/*') ?: [], glob($dir . '/.[!.]*') ?: []) as $path) {
        if (is_dir($path)) removeTree($path); else unlink($path);
    }
    if (is_dir($dir)) rmdir($dir);
}
function gateway(string $dir, callable $handler, array $config = []): WxtyGateway
{
    return new WxtyGateway(array_replace(['cache_dir' => $dir], $config), $handler,
        static fn($host) => ['8.8.8.8'], static function ($value): string {
            if ($value === 'bad-cipher') throw new WxtyError('decrypt-failed');
            return $value;
        });
}
function normalHandler(?string $log = null): callable
{
    return static function ($url) use ($log): array {
        if ($log) file_put_contents($log, parse_url($url, PHP_URL_PATH) . "\n", FILE_APPEND | LOCK_EX);
        if (parse_url($url, PHP_URL_HOST) === 'kapi.kankanews.com') {
            usleep(150000);
            return apiResponse(['live_address' => 'https://cdn.example/live/index.m3u8']);
        }
        return response(media());
    };
}
function endpoint(array $query, array $server = [], array $env = [], bool $dispatch = false): array
{
    $code = 'define("WXTY_LIBRARY_ONLY",true); require ' . var_export(dirname(__DIR__) . '/wxty.php', true) . ';';
    foreach ($env as $key => $value) $code .= 'putenv(' . var_export($key . '=' . $value, true) . ');';
    $code .= '$_GET=' . var_export($query, true) . '; $_SERVER=' . var_export($server, true)
        . ';http_response_code(200);ob_start();' . ($dispatch ? 'wxtyDispatch' : 'wxtyMain')
        . '();$body=ob_get_clean();echo json_encode(["status"=>http_response_code(),"body"=>$body]);';
    $proc = proc_open([PHP_BINARY, '-r', $code], [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
    fclose($pipes[0]); $out = stream_get_contents($pipes[1]); $err = stream_get_contents($pipes[2]);
    fclose($pipes[1]); fclose($pipes[2]); same(proc_close($proc), 0);
    $result = json_decode($out, true);
    if (!is_array($result)) throw new RuntimeException('Endpoint failed: ' . $err);
    return $result;
}
function routerRequest(string $address, string $path, string $method = 'GET'): array
{
    $socket = stream_socket_client('tcp://' . $address, $errno, $error, 3);
    if (!$socket) throw new RuntimeException('HTTP connection failed');
    stream_set_timeout($socket, 3);
    fwrite($socket, $method . ' ' . $path . " HTTP/1.1\r\nHost: " . $address . "\r\nConnection: close\r\n\r\n");
    $response = stream_get_contents($socket); fclose($socket);
    [$head, $body] = explode("\r\n\r\n", $response, 2);
    preg_match('/^HTTP\/1\.[01] ([0-9]{3})/', $head, $match);
    $headers = [];
    foreach (explode("\r\n", $head) as $line) {
        if (strpos($line, ':') !== false) { [$key, $value] = explode(':', $line, 2); $headers[strtolower($key)] = trim($value); }
    }
    return ['status' => (int) $match[1], 'body' => $body, 'headers' => $headers];
}
if (($argv[1] ?? '') === '--worker') {
    $gateway = gateway($argv[2], normalHandler($argv[2] . '/calls.log'));
    $result = $gateway->resolve(10, ($argv[3] ?? '') === 'force');
    echo json_encode(['cache' => $result['cache'], 'source' => $result['source']]);
    exit;
}

$root = sys_get_temp_dir() . '/wxty-test-' . bin2hex(random_bytes(6));
mkdir($root, 0700, true); $number = 0; $failed = 0;
function test(string $name, callable $fn): void
{
    global $number, $failed, $root;
    $number++; $dir = $root . '/' . $number;
    try { $fn($dir); echo 'ok ' . $number . ' - ' . $name . "\n"; }
    catch (Throwable $error) { $failed++; echo 'not ok ' . $number . ' - ' . $name . ': ' . $error->getMessage() . "\n"; }
}

try {
    // RFC 3986 section 5.4, plus signed queries, custom ports and IPv6.
    $base = 'http://a/b/c/d;p?q';
    $references = ['g' => 'http://a/b/c/g', './g' => 'http://a/b/c/g', 'g/' => 'http://a/b/c/g/',
        '/g' => 'http://a/g', '//g' => 'http://g', '?y' => 'http://a/b/c/d;p?y',
        'g?y' => 'http://a/b/c/g?y', '#s' => 'http://a/b/c/d;p?q#s', 'g#s' => 'http://a/b/c/g#s',
        'g?y#s' => 'http://a/b/c/g?y#s', ';x' => 'http://a/b/c/;x', 'g;x' => 'http://a/b/c/g;x',
        '' => 'http://a/b/c/d;p?q', '.' => 'http://a/b/c/', './' => 'http://a/b/c/',
        '..' => 'http://a/b/', '../' => 'http://a/b/', '../g' => 'http://a/b/g',
        '../..' => 'http://a/', '../../' => 'http://a/', '../../g' => 'http://a/g',
        '../../../g' => 'http://a/g', '../../../../g' => 'http://a/g', '/./g' => 'http://a/g',
        '/../g' => 'http://a/g', 'g.' => 'http://a/b/c/g.', '.g' => 'http://a/b/c/.g',
        'g..' => 'http://a/b/c/g..', '..g' => 'http://a/b/c/..g', './../g' => 'http://a/b/g',
        './g/.' => 'http://a/b/c/g/', 'g/./h' => 'http://a/b/c/g/h', 'g/../h' => 'http://a/b/c/h',
        'g;x=1/./y' => 'http://a/b/c/g;x=1/y', 'g;x=1/../y' => 'http://a/b/c/y',
        'g?y/./x' => 'http://a/b/c/g?y/./x', 'g?y/../x' => 'http://a/b/c/g?y/../x'];
    foreach ($references as $ref => $expected) test('RFC URI ' . $ref, static fn() => same(WxtyGateway::resolveUri($base, $ref), $expected));
    test('port and encoded signature preserved', static fn() => same(
        WxtyGateway::resolveUri('https://cdn.example:8443/live/index.m3u8', 'a.ts?token=ab%2Bcd&sig=x%26y'),
        'https://cdn.example:8443/live/a.ts?token=ab%2Bcd&sig=x%26y'));
    test('IPv6 authority preserved', static fn() => same(WxtyGateway::resolveUri('https://[2606:4700::1111]/a/b', '../x'), 'https://[2606:4700::1111]/x'));
    test('unsafe URI scheme rejected', static fn() => raises(static fn() => WxtyGateway::resolveUri($base, 'file:///etc/passwd'), 'invalid-uri'));
    test('userinfo rejected', static fn() => raises(static fn() => WxtyGateway::resolveUri($base, 'https://user:pass@host/a'), 'invalid-uri'));
    test('control character rejected', static fn() => raises(static fn() => WxtyGateway::resolveUri($base, "a\r\nHost:x"), 'invalid-uri'));
    foreach (['127.0.0.1', '10.0.0.1', '172.16.0.1', '192.168.1.1', '169.254.169.254', '100.64.0.1',
        '192.0.2.1', '198.18.0.1', '198.51.100.1', '203.0.113.1', '224.0.0.1', '0.0.0.0',
        '::1', 'fc00::1', 'fe80::1', '::ffff:127.0.0.1', '2001:db8::1', '2002:7f00:1::1'] as $ip) {
        test('deny non-public IP ' . $ip, static fn() => same(WxtyGateway::isPublicIp($ip), false));
    }
    test('public IPv4 accepted', static fn() => same(WxtyGateway::isPublicIp('8.8.8.8'), true));
    test('public IPv6 accepted', static fn() => same(WxtyGateway::isPublicIp('2606:4700:4700::1111'), true));
    test('mixed public/private DNS rejected', static function ($dir) {
        $g = new WxtyGateway(['cache_dir' => $dir], null, static fn($host) => ['8.8.8.8', '127.0.0.1']);
        raises(static fn() => $g->validateUrl('https://cdn.example/a'), 'blocked-address');
    });
    test('media allowlist exact and suffix boundary', static function ($dir) {
        $g = gateway($dir, normalHandler(), ['media_hosts' => ['.cdn.example']]);
        same($g->validateUrl('https://edge.cdn.example/a')['host'], 'edge.cdn.example');
        raises(static fn() => $g->validateUrl('https://evilcdn.example/a'), 'blocked-media-host');
    });
    test('nonstandard request port rejected', static function ($dir) {
        $g = gateway($dir, normalHandler()); raises(static fn() => $g->validateUrl('https://cdn.example:8443/a'), 'blocked-port');
    });
    test('default mode reaches API and official CDN behind Fake-IP DNS', static function ($dir) {
        $requests = 0; $lookups = 0;
        $g = new WxtyGateway(['cache_dir' => $dir], static function ($url, $headers, $target) use (&$requests) {
            $requests++; same($target['ips'], []); same($target['dns_mode'], 'system');
            if (parse_url($url, PHP_URL_HOST) === 'kapi.kankanews.com') return apiResponse(['live_address' => 'https://volc-stream.kksmg.com/live/index.m3u8']);
            return response(media());
        }, static function ($host) use (&$lookups) { $lookups++; return ['198.18.0.42']; }, static fn($value) => $value);
        $r = $g->resolve(5); same($r['cache'], 'MISS'); same($requests, 2); same($lookups, 0);
    });
    test('official HTTPS uses system resolution without PHP DNS support', static function ($dir) {
        $g = new WxtyGateway(['cache_dir' => $dir], null, static function ($host) { throw new RuntimeException('PHP DNS must not be called'); });
        same($g->validateUrl('https://kapi.kankanews.com/content', true)['dns_mode'], 'system');
        same($g->validateUrl('https://ali-stream.kksmg.com/live.m3u8')['dns_mode'], 'system');
    });
    test('validated mode still rejects Fake-IP API without scanning all programs', static function ($dir) {
        $lookups = 0; $requests = 0;
        $g = new WxtyGateway(['cache_dir' => $dir, 'network_mode' => 'validated'],
            static function ($url) use (&$requests) { $requests++; return apiResponse([]); },
            static function ($host) use (&$lookups) { $lookups++; return ['198.18.0.42']; });
        raises(static fn() => $g->resolve(5), 'blocked-address'); same($lookups, 1); same($requests, 0);
        raises(static fn() => $g->resolve(5), 'blocked-address'); same($lookups, 1);
    });
    test('validated mode preserves public DNS pinning for official hosts', static function ($dir) {
        $g = gateway($dir, normalHandler(), ['network_mode' => 'validated']);
        $target = $g->validateUrl('https://kapi.kankanews.com/content', true);
        same($target['ips'], ['8.8.8.8']); same($target['dns_mode'], 'validated');
    });
    foreach (['https://evil-kksmg.com/a', 'https://kksmg.com.evil.example/a', 'http://volc-stream.kksmg.com/a',
        'https://127.0.0.1/a', 'https://[::1]/a', 'https://192.168.1.1/a'] as $url) {
        test('compatibility does not relax untrusted target ' . $url, static function ($dir) use ($url) {
            $g = new WxtyGateway(['cache_dir' => $dir], null, static fn($host) => ['198.18.0.42']);
            raises(static fn() => $g->validateUrl($url), 'blocked-address');
        });
    }
    test('compatible mode still applies media allowlist before system DNS', static function ($dir) {
        $g = gateway($dir, normalHandler(), ['media_hosts' => ['other.example']]);
        raises(static fn() => $g->validateUrl('https://volc-stream.kksmg.com/a'), 'blocked-media-host');
    });
    test('official redirect to private address remains blocked in compatible mode', static function ($dir) {
        $requested = [];
        $g = new WxtyGateway(['cache_dir' => $dir, 'scan_days' => 1], static function ($url) use (&$requested) {
            $requested[] = parse_url($url, PHP_URL_HOST);
            if (parse_url($url, PHP_URL_PATH) === '/content/pc/tv/channel/detail') return apiResponse(['live_address' => 'https://volc-stream.kksmg.com/index.m3u8']);
            if (parse_url($url, PHP_URL_HOST) === 'volc-stream.kksmg.com') return response('', 302, ['location' => 'https://127.0.0.1/secret']);
            return apiResponse(['programs' => []]);
        }, static fn($host) => ['198.18.0.42'], static fn($value) => $value);
        raises(static fn() => $g->resolve(5), 'blocked-address'); same(in_array('127.0.0.1', $requested, true), false);
    });
    test('invalid network mode rejected', static fn($dir) => raises(static fn() => new WxtyGateway([
        'cache_dir' => $dir, 'network_mode' => 'disabled']), 'invalid-network-mode'));
    test('numeric-only hexadecimal expiry', static fn() => same(WxtyGateway::urlExpiry('https://cdn.example/a?txTime=70000000'), 1879048192));
    test('earliest CDN and token expiry', static function () {
        $payload = rtrim(strtr(base64_encode('{"exp":1800000000}'), '+/', '-_'), '=');
        same(WxtyGateway::urlExpiry('https://cdn.example/a?wsTime=70000000&token=a.' . $payload . '.b'), 1800000000);
    });
    test('array time parameter does not raise warning', static fn() => same(WxtyGateway::urlExpiry('https://cdn.example/a?txTime[]=bad'), 0));
    test('time conversion preserves retained query bytes', static fn() => same(
        WxtyGateway::withoutTimeRange('https://cdn.example/a?start=1&token=ab%2Bcd&sig=x%26y&END=2#f'),
        'https://cdn.example/a?token=ab%2Bcd&sig=x%26y#f'));
    test('HLS master retains external audio and subtitles', static function () {
        $body = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",URI=\"audio/index.m3u8\"\n"
            . "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"s\",URI=\"//sub.example/s.m3u8\"\n"
            . "#EXT-X-STREAM-INF:BANDWIDTH=1000000,AUDIO=\"a\",SUBTITLES=\"s\"\nvideo.m3u8\n";
        $out = WxtyGateway::rewritePlaylist($body, 'https://cdn.example/live/master.m3u8');
        same(str_contains($out, 'URI="https://cdn.example/live/audio/index.m3u8"'), true);
        same(str_contains($out, 'URI="https://sub.example/s.m3u8"'), true);
        same(str_contains($out, 'https://cdn.example/live/video.m3u8'), true);
        same(str_contains($out, 'AUDIO="a",SUBTITLES="s"'), true);
    });
    test('HLS BYTERANGE KEY MAP and root-relative segments', static function () {
        $body = "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key?k=a%2Bb\"\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:6,\n#EXT-X-BYTERANGE:10@0\n/segments/a.mp4\n";
        $out = WxtyGateway::rewritePlaylist($body, 'https://cdn.example/live/index.m3u8');
        same(str_contains($out, 'URI="https://cdn.example/live/key?k=a%2Bb"'), true);
        same(str_contains($out, 'URI="https://cdn.example/live/init.mp4"'), true);
        same(str_contains($out, "#EXT-X-BYTERANGE:10@0\nhttps://cdn.example/segments/a.mp4"), true);
    });
    test('HTML not accepted as playlist', static fn() => raises(static fn() => WxtyGateway::rewritePlaylist('<html>#EXTINF</html>', $base), 'invalid-playlist'));
    test('empty HLS rejected', static fn() => raises(static fn() => WxtyGateway::rewritePlaylist("#EXTM3U\n", $base), 'empty-playlist'));
    test('HLS segment without URI rejected', static fn() => raises(static fn() => WxtyGateway::rewritePlaylist("#EXTM3U\n#EXTINF:6,\n", $base), 'invalid-playlist'));
    test('BOM and CR input supported', static fn() => same(str_contains(WxtyGateway::rewritePlaylist("\xEF\xBB\xBF#EXTM3U\r#EXTINF:6,\ra.ts\r", $base), 'http://a/b/c/a.ts'), true));
    test('RSA multiblock and strict failure', static function () {
        $key = openssl_pkey_new(['private_key_bits' => 1024, 'private_key_type' => OPENSSL_KEYTYPE_RSA]);
        $pem = openssl_pkey_get_details($key)['key']; $plain = str_repeat('abc', 80); $encrypted = '';
        foreach (str_split($plain, 117) as $chunk) { openssl_private_encrypt($chunk, $out, $key, OPENSSL_PKCS1_PADDING); $encrypted .= $out; }
        same(WxtyGateway::decrypt(base64_encode($encrypted), $pem), $plain);
        raises(static fn() => WxtyGateway::decrypt(base64_encode($encrypted . 'x'), $pem), 'invalid-ciphertext');
        $corrupt = substr($encrypted, 0, 128) . str_repeat("\x00", 128) . substr($encrypted, 256);
        raises(static fn() => WxtyGateway::decrypt(base64_encode($corrupt), $pem), 'decrypt-failed');
        raises(static fn() => WxtyGateway::decrypt('bad base64!', $pem), 'invalid-ciphertext');
    });
    test('cache HIT retains source metadata and avoids API', static function ($dir) {
        $calls = []; $handler = normalHandler();
        $g = gateway($dir, static function ($url) use (&$calls, $handler) { $calls[] = $url; return $handler($url); });
        $a = $g->resolve(10); $b = $g->resolve(10);
        same($a['cache'], 'MISS'); same($b['cache'], 'HIT'); same($b['source'], 'channel'); same($b['kind'], 'live');
        same(count($calls), 3); same($b['expires_at'], $a['expires_at']);
        same(str_contains($b['playlist'], 'https://cdn.example/live/a.ts'), true);
    });
    test('API signing compatibility and no forwarded client IP', static function ($dir) {
        $_SERVER['HTTP_X_FORWARDED_FOR'] = '127.0.0.1'; $checked = false;
        $g = gateway($dir, static function ($url, $headers) use (&$checked) {
            if (parse_url($url, PHP_URL_HOST) !== 'kapi.kankanews.com') return response(media());
            $h = []; foreach ($headers as $line) { [$k, $v] = explode(': ', $line, 2); $h[$k] = $v; }
            $values = ['Api-Version' => 'v1', 'channel_id' => 10, 'nonce' => $h['Nonce'], 'platform' => 'pc', 'timestamp' => $h['Timestamp'], 'version' => $h['Version']];
            ksort($values); $text = ''; foreach ($values as $k => $v) $text .= $k . '=' . $v . '&';
            same($h['Sign'], md5(md5($text . '28c8edde3d61a0411511d3b1866f0636')));
            same(isset($h['X-Forwarded-For']), false); $checked = true;
            return apiResponse(['live_address' => 'https://cdn.example/index.m3u8']);
        });
        $g->resolve(10); same($checked, true); unset($_SERVER['HTTP_X_FORWARDED_FOR']);
    });
    test('bad nonempty channel address falls back to current program', static function ($dir) {
        $g = gateway($dir, static function ($url) {
            $path = parse_url($url, PHP_URL_PATH);
            if ($path === '/content/pc/tv/channel/detail') return apiResponse(['live_address' => 'bad-cipher']);
            if ($path === '/content/pc/tv/programs') return apiResponse(['programs' => [['id' => 7, 'start_time' => time() - 10, 'end_time' => time() + 100]]]);
            if ($path === '/content/pc/tv/program/detail') return apiResponse(['channel_info' => ['live_address' => 'https://cdn.example/good.m3u8']]);
            return response(media());
        });
        same($g->resolve(10)['source'], 'current-program');
    });
    test('both live and shift addresses are tried', static function ($dir) {
        $seen = [];
        $g = gateway($dir, static function ($url) use (&$seen) {
            $seen[] = $url;
            if (parse_url($url, PHP_URL_HOST) === 'kapi.kankanews.com') return apiResponse(['live_address' => 'bad-cipher', 'shift_address' => 'https://cdn.example/good.m3u8?start=1&sig=a%2Bb']);
            same($url, 'https://cdn.example/good.m3u8?sig=a%2Bb'); return response(media());
        });
        same($g->resolve(10)['kind'], 'shift-converted'); same(count($seen), 2);
    });
    test('failed cached URL refreshes once and publishes replacement', static function ($dir) {
        $fresh = false; $calls = [];
        $g = gateway($dir, static function ($url) use (&$fresh, &$calls) {
            $calls[] = $url;
            if (parse_url($url, PHP_URL_HOST) === 'kapi.kankanews.com') return apiResponse(['live_address' => 'https://cdn.example/' . ($fresh ? 'new' : 'old') . '.m3u8']);
            if ($fresh && str_contains($url, 'old.m3u8')) return response('expired', 403);
            return response(media());
        });
        same($g->resolve(10)['cache'], 'MISS'); $fresh = true;
        same($g->resolve(10)['cache'], 'MISS'); same(count($calls), 5);
        $hit = $g->resolve(10); same($hit['cache'], 'HIT'); same($hit['url'], 'https://cdn.example/new.m3u8');
    });
    test('expired signing time skips media request and tries current program', static function ($dir) {
        $g = gateway($dir, static function ($url) {
            $path = parse_url($url, PHP_URL_PATH);
            if ($path === '/content/pc/tv/channel/detail') return apiResponse(['live_address' => 'https://cdn.example/expired.m3u8?txTime=' . dechex(time() - 1)]);
            if ($path === '/content/pc/tv/programs') return apiResponse(['programs' => [['id' => 9, 'start_time' => time() - 1, 'end_time' => time() + 300]]]);
            if ($path === '/content/pc/tv/program/detail') return apiResponse(['channel_info' => ['live_address' => 'https://cdn.example/current.m3u8']]);
            same($path, '/current.m3u8'); return response(media());
        });
        same($g->resolve(10)['source'], 'current-program');
    });
    test('candidate limit stops before fetching more program details', static function ($dir) {
        $calls = 0; $g = gateway($dir, static function ($url) use (&$calls) {
            $calls++; return apiResponse(['live_address' => 'bad-cipher', 'shift_address' => 'https://cdn.example/a.m3u8']);
        }, ['max_candidates' => 1]);
        raises(static fn() => $g->resolve(10), 'decrypt-failed'); same($calls, 1);
    });
    test('shift conversion can be disabled', static function ($dir) {
        $g = gateway($dir, static function ($url) {
            if (parse_url($url, PHP_URL_HOST) !== 'kapi.kankanews.com') throw new RuntimeException('Unexpected media request');
            return apiResponse(parse_url($url, PHP_URL_PATH) === '/content/pc/tv/channel/detail'
                ? ['shift_address' => 'https://cdn.example/replay.m3u8?start=1'] : ['programs' => []]);
        }, ['scan_days' => 1, 'shift_to_live' => false]);
        raises(static fn() => $g->resolve(10), 'replay-only-address');
    });
    test('redirect final URL becomes playlist base and master stays intact', static function ($dir) {
        $g = gateway($dir, static function ($url) {
            if (parse_url($url, PHP_URL_HOST) === 'kapi.kankanews.com') return apiResponse(['live_address' => 'https://cdn.example/original.m3u8']);
            if ($url === 'https://cdn.example/original.m3u8') return response('', 302, ['location' => '/new/master.m3u8']);
            if ($url === 'https://cdn.example/new/master.m3u8') return response("#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,URI=\"audio.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=10\nvideo.m3u8\n");
            same($url, 'https://cdn.example/new/video.m3u8'); return response(media());
        });
        $r = $g->resolve(10); same(str_contains($r['playlist'], '#EXT-X-MEDIA:'), true);
        same(str_contains($r['playlist'], 'https://cdn.example/new/video.m3u8'), true); same($r['requests'], 4);
    });
    test('redirect to private IP is blocked before transport', static function ($dir) {
        $calledPrivate = false;
        $g = gateway($dir, static function ($url) use (&$calledPrivate) {
            if (str_contains($url, '127.0.0.1')) $calledPrivate = true;
            if (parse_url($url, PHP_URL_PATH) === '/content/pc/tv/channel/detail') return apiResponse(['live_address' => 'https://cdn.example/index.m3u8']);
            if (parse_url($url, PHP_URL_HOST) === 'cdn.example') return response('', 302, ['location' => 'http://127.0.0.1/a.m3u8']);
            return apiResponse(['programs' => []]);
        }, ['scan_days' => 1]);
        raises(static fn() => $g->resolve(10), 'https-downgrade'); same($calledPrivate, false);
    });
    test('same-scheme redirect to private IP is blocked', static function ($dir) {
        $g = gateway($dir, static function ($url) {
            if (parse_url($url, PHP_URL_PATH) === '/content/pc/tv/channel/detail') return apiResponse(['live_address' => 'https://cdn.example/index.m3u8']);
            if (parse_url($url, PHP_URL_HOST) === 'cdn.example') return response('', 302, ['location' => 'https://127.0.0.1/a.m3u8']);
            return apiResponse(['programs' => []]);
        }, ['scan_days' => 1]);
        raises(static fn() => $g->resolve(10), 'blocked-address');
    });
    test('request budget and negative cache stop request amplification', static function ($dir) {
        $calls = 0; $g = gateway($dir, static function ($url) use (&$calls) { $calls++; return apiResponse(['programs' => []]); }, ['max_requests' => 3]);
        raises(static fn() => $g->resolve(10), 'request-budget'); same($calls, 3);
        raises(static fn() => $g->resolve(10, true), 'request-budget'); same($calls, 3);
    });
    test('429 stops immediately and is shared as cooldown', static function ($dir) {
        $calls = 0; $g = gateway($dir, static function ($url) use (&$calls) { $calls++; return response('limited', 429); });
        raises(static fn() => $g->resolve(10), 'rate-limited');
        raises(static fn() => $g->resolve(10, true), 'rate-limited'); same($calls, 1);
    });
    test('429 on cached playlist is also shared as cooldown', static function ($dir) {
        $calls = 0; $limited = false; $handler = normalHandler();
        $g = gateway($dir, static function ($url) use (&$calls, &$limited, $handler) {
            $calls++; return $limited ? response('limited', 429) : $handler($url);
        });
        $g->resolve(10); $limited = true;
        raises(static fn() => $g->resolve(10), 'rate-limited'); $before = $calls;
        raises(static fn() => $g->resolve(10), 'rate-limited'); same($calls, $before);
    });
    test('oversize response rejected', static function ($dir) {
        $g = gateway($dir, static fn($url) => response(str_repeat('x', 600)), ['max_bytes' => 512, 'scan_days' => 1]);
        raises(static fn() => $g->resolve(10), 'address-unavailable');
    });
    test('invalid ciphertext does not poison live cache', static function ($dir) {
        $handler = static function ($url) {
            return apiResponse(parse_url($url, PHP_URL_PATH) === '/content/pc/tv/channel/detail' ? ['live_address' => 'bad-cipher'] : ['programs' => []]);
        };
        $g = gateway($dir, $handler, ['scan_days' => 1]);
        raises(static fn() => $g->resolve(10), 'decrypt-failed');
        same(is_file($dir . '/' . hash('sha256', 'live:10') . '.json'), false);
    });
    test('admin debug access requires configured Bearer token', static fn() => same(endpoint(['info' => '1'])['status'], 403));
    test('public force refresh rejected', static fn() => same(endpoint(['refresh' => '1'])['status'], 403));
    test('arbitrary segment proxy is gone', static fn() => same(endpoint(['ts_url' => 'https://127.0.0.1/a.ts'])['status'], 410));
    test('array channel input returns 400', static fn() => same(endpoint(['id' => ['wxty']])['status'], 400));
    test('unknown channel returns 400', static fn() => same(endpoint(['id' => 'missing'])['status'], 400));
    test('POST returns 405', static fn() => same(endpoint([], ['REQUEST_METHOD' => 'POST'])['status'], 405));
    test('HEAD does not create caches or contact upstream', static function ($dir) {
        same(endpoint([], ['REQUEST_METHOD' => 'HEAD'], ['KK_CACHE_DIR' => $dir])['status'], 200);
        same(is_dir($dir), false);
    });
    test('access token rejects anonymous request', static fn() => same(endpoint([], ['REQUEST_METHOD' => 'HEAD'], ['KK_ACCESS_TOKEN' => 'access-token'])['status'], 401));
    test('admin token can authenticate protected HEAD', static fn() => same(endpoint(['info' => '1'],
        ['REQUEST_METHOD' => 'HEAD', 'HTTP_AUTHORIZATION' => 'Bearer admin-token'],
        ['KK_ACCESS_TOKEN' => 'access-token', 'KK_ADMIN_TOKEN' => 'admin-token'])['status'], 200));
    test('subscription includes all eight local channel URLs without fetching upstream', static function ($dir) {
        $result = endpoint(['list' => '1'], ['HTTP_HOST' => '127.0.0.1:52451', 'SCRIPT_NAME' => '/wxty.php'], ['KK_CACHE_DIR' => $dir]);
        same($result['status'], 200); same(str_starts_with($result['body'], "#EXTM3U\n"), true);
        same(substr_count($result['body'], '#EXTINF:'), 8);
        foreach (WxtyGateway::CHANNELS as $id => $channel) {
            same(str_contains($result['body'], 'http://127.0.0.1:52451/wxty.php?id=' . $id . "\n"), true);
            same(str_contains($result['body'], WxtyGateway::NAMES[$id]), true);
        }
        same(is_dir($dir), false);
    });
    test('subscription supports HTTPS IPv6 and installation subdirectory', static function () {
        $r = endpoint(['list' => '1'], ['HTTP_HOST' => '[::1]:52451', 'HTTPS' => 'on', 'SCRIPT_NAME' => '/gateway/wxty.php']);
        same($r['status'], 200); same(str_contains($r['body'], 'https://[::1]:52451/gateway/wxty.php?id=wxty'), true);
    });
    test('explicit subscription public base overrides proxy headers', static function () {
        $r = endpoint(['list' => '1'], ['HTTP_HOST' => '127.0.0.1:52451', 'SCRIPT_NAME' => '/wxty.php'],
            ['KK_PUBLIC_BASE_URL' => 'https://tv.example/gateway/']);
        same($r['status'], 200); same(str_contains($r['body'], 'https://tv.example/gateway/wxty.php?id=wxty'), true);
        same(str_contains($r['body'], '127.0.0.1'), false);
    });
    test('subscription ignores untrusted forwarded host and scheme', static function () {
        $r = endpoint(['list' => '1'], ['HTTP_HOST' => '127.0.0.1:52451', 'SCRIPT_NAME' => '/wxty.php',
            'HTTP_X_FORWARDED_HOST' => 'evil.example', 'HTTP_X_FORWARDED_PROTO' => 'https']);
        same($r['status'], 200); same(str_contains($r['body'], 'http://127.0.0.1:52451/wxty.php'), true);
        same(str_contains($r['body'], 'evil.example'), false);
    });
    test('subscription rejects injected host', static fn() => same(endpoint(['list' => '1'],
        ['HTTP_HOST' => "127.0.0.1:52451\r\n#EXTINF:evil", 'SCRIPT_NAME' => '/wxty.php'])['status'], 400));
    test('subscription rejects invalid configured base', static fn() => same(endpoint(['list' => '1'],
        ['HTTP_HOST' => '127.0.0.1:52451'], ['KK_PUBLIC_BASE_URL' => 'https://tv.example/?token=x'])['status'], 500));
    test('subscription rejects array list input', static fn() => same(endpoint(['list' => ['1']])['status'], 400));
    test('subscription HEAD has no body or cache side effects', static function ($dir) {
        same(endpoint(['list' => '1'], ['REQUEST_METHOD' => 'HEAD', 'HTTP_HOST' => '127.0.0.1:52451'],
            ['KK_CACHE_DIR' => $dir]), ['status' => 200, 'body' => '']);
        same(is_dir($dir), false);
    });
    test('subscription follows access authentication without exposing tokens', static function () {
        $server = ['HTTP_HOST' => '127.0.0.1:52451']; $env = ['KK_ACCESS_TOKEN' => 'private-playback-token'];
        same(endpoint(['list' => '1'], $server, $env)['status'], 401);
        $server['HTTP_AUTHORIZATION'] = 'Bearer private-playback-token';
        $r = endpoint(['list' => '1'], $server, $env); same($r['status'], 200);
        same(str_contains($r['body'], 'private-playback-token'), false);
    });
    test('single file handles all.m3u from an external launcher', static function ($dir) {
        $r = endpoint([], ['REQUEST_URI' => '/all.m3u', 'SCRIPT_NAME' => '/all.m3u', 'HTTP_HOST' => '127.0.0.1:52451'],
            ['KK_CACHE_DIR' => $dir], true);
        same($r['status'], 200); same(substr_count($r['body'], '#EXTINF:'), 8);
        same(str_contains($r['body'], 'http://127.0.0.1:52451/wxty.php?id=wxty'), true);
        same(is_dir($dir), false);
    });
    test('single file dispatch preserves installed script prefix', static function () {
        $r = endpoint(['list' => '1'], ['REQUEST_URI' => '/gateway/wxty.php?list=1', 'SCRIPT_NAME' => '/gateway/wxty.php',
            'HTTP_HOST' => '127.0.0.1:52451'], [], true);
        same($r['status'], 200); same(str_contains($r['body'], 'http://127.0.0.1:52451/gateway/wxty.php?id=wxty'), true);
    });
    test('single file dispatch rejects unknown paths', static fn() => same(endpoint([],
        ['REQUEST_URI' => '/missing', 'SCRIPT_NAME' => '/missing'], [], true)['status'], 404));
    foreach ([['--help', 0], ['--port=70000', 2], ['--host=invalid/host', 2]] as [$argument, $expected]) {
        test('single file CLI validates ' . $argument, static function () use ($argument, $expected) {
            $proc = proc_open([PHP_BINARY, dirname(__DIR__) . '/wxty.php', $argument],
                [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
            fclose($pipes[0]); stream_get_contents($pipes[1]); stream_get_contents($pipes[2]);
            fclose($pipes[1]); fclose($pipes[2]); same(proc_close($proc), $expected);
        });
    }
    foreach (['router', 'default', 'custom'] as $mode) test('isolated single file HTTP ' . $mode, static function ($dir) use ($mode) {
        $standalone = $mode !== 'router';
        mkdir($dir, 0700, true);
        copy(dirname(__DIR__) . '/wxty.php', $dir . '/wxty.php');
        same(count(glob($dir . '/*.php')), 1);
        $socket = stream_socket_server('tcp://127.0.0.1:' . ($mode === 'default' ? '52451' : '0'), $errno, $error);
        $address = stream_socket_get_name($socket, false); fclose($socket);
        $port = substr($address, strrpos($address, ':') + 1);
        $command = $mode === 'router' ? [PHP_BINARY, '-S', $address, '-t', $dir, $dir . '/wxty.php']
            : ($mode === 'default' ? [PHP_BINARY, $dir . '/wxty.php'] : [PHP_BINARY, $dir . '/wxty.php', '--port=' . $port]);
        $proc = proc_open($command, [0 => ['pipe', 'r'], 1 => ['file', $dir . '/http.log', 'a'],
            2 => ['file', $dir . '/http.log', 'a']], $pipes, $dir);
        fclose($pipes[0]); $parent = proc_get_status($proc)['pid'];
        try {
            $ready = false;
            for ($i = 0; $i < 100; $i++) {
                $probe = @stream_socket_client('tcp://' . $address, $errno, $error, 0.05);
                if ($probe) { fclose($probe); $ready = true; break; }
                usleep(20000);
            }
            if (!$ready) throw new RuntimeException('Server did not start: ' . file_get_contents($dir . '/http.log'));
            $r = routerRequest($address, '/all.m3u'); same($r['status'], 200);
            same($r['headers']['content-type'], 'audio/x-mpegurl; charset=utf-8');
            same(substr_count($r['body'], '#EXTINF:'), 8);
            foreach (WxtyGateway::CHANNELS as $id => $channel) {
                same(str_contains($r['body'], 'http://' . $address . '/wxty.php?id=' . $id . "\n"), true);
                same(routerRequest($address, '/wxty.php?id=' . $id, 'HEAD')['status'], 200);
            }
            same(routerRequest($address, '/')['body'], $r['body']);
            same(routerRequest($address, '/wxty.php?list=1')['body'], $r['body']);
            same(routerRequest($address, '/all.m3u', 'HEAD')['body'], '');
            same(routerRequest($address, '/missing')['status'], 404);
            same(routerRequest($address, '/all.m3u', 'POST')['status'], 405);
        } finally {
            if ($standalone) {
                preg_match_all('/wxty-server-pid=([0-9]+)/', file_get_contents($dir . '/http.log'), $matches);
                foreach (array_unique($matches[1]) as $pid) if ((int) $pid !== $parent) posix_kill((int) $pid, 15);
            }
            proc_terminate($proc); proc_close($proc);
        }
    });
    test('real HTTP router serves all.m3u and every listed channel path', static function ($dir) {
        mkdir($dir, 0700, true);
        $socket = stream_socket_server('tcp://127.0.0.1:0', $errno, $error);
        $address = stream_socket_get_name($socket, false); fclose($socket);
        $proc = proc_open([PHP_BINARY, '-S', $address, '-t', dirname(__DIR__), dirname(__DIR__) . '/router.php'],
            [0 => ['pipe', 'r'], 1 => ['file', $dir . '/http.log', 'a'], 2 => ['file', $dir . '/http.log', 'a']], $pipes);
        fclose($pipes[0]);
        try {
            $ready = false;
            for ($i = 0; $i < 100; $i++) {
                $probe = @stream_socket_client('tcp://' . $address, $errno, $error, 0.05);
                if ($probe) { fclose($probe); $ready = true; break; }
                usleep(20000);
            }
            same($ready, true);
            $r = routerRequest($address, '/all.m3u'); same($r['status'], 200);
            same($r['headers']['content-type'], 'audio/x-mpegurl; charset=utf-8');
            same($r['headers']['content-disposition'], 'inline; filename="all.m3u"');
            same(substr_count($r['body'], '#EXTINF:'), 8);
            foreach (WxtyGateway::CHANNELS as $id => $channel) {
                same(str_contains($r['body'], 'http://' . $address . '/wxty.php?id=' . $id . "\n"), true);
                same(routerRequest($address, '/wxty.php?id=' . $id, 'HEAD')['status'], 200);
            }
            same(routerRequest($address, '/')['body'], $r['body']);
            same(routerRequest($address, '/wxty.php?list=1')['body'], $r['body']);
            same(routerRequest($address, '/all.m3u', 'HEAD')['body'], '');
            same(routerRequest($address, '/missing')['status'], 404);
            same(routerRequest($address, '/all.m3u', 'POST')['status'], 405);
        } finally { proc_terminate($proc); proc_close($proc); }
    });
    foreach ([false, true] as $force) test('real process single refresh ' . ($force ? 'forced' : 'cold'), static function ($dir) use ($force) {
        mkdir($dir, 0700, true); $workers = [];
        for ($i = 0; $i < 4; $i++) {
            $proc = proc_open([PHP_BINARY, __FILE__, '--worker', $dir, $force ? 'force' : 'cold'],
                [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
            fclose($pipes[0]); $workers[] = [$proc, $pipes];
        }
        $misses = 0;
        foreach ($workers as [$proc, $pipes]) {
            $out = stream_get_contents($pipes[1]); $err = stream_get_contents($pipes[2]);
            fclose($pipes[1]); fclose($pipes[2]); same(proc_close($proc), 0);
            $result = json_decode($out, true); if (($result['cache'] ?? '') === 'MISS') $misses++;
            same($result['source'] ?? $err, 'channel');
        }
        same($misses, 1);
        $calls = file($dir . '/calls.log', FILE_IGNORE_NEW_LINES);
        same(count(array_filter($calls, static fn($path) => $path === '/content/pc/tv/channel/detail')), 1);
        foreach (glob($dir . '/*.json') as $path) {
            same(is_array(json_decode(file_get_contents($path), true)), true);
            same(fileperms($path) & 0777, 0600);
        }
    });
} finally { removeTree($root); }
echo '1..' . $number . "\n";
exit($failed === 0 ? 0 : 1);
