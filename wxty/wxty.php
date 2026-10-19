<?php
/*
 * Based on wxty.php from https://t.me/iptvorganization .
 * Original protocol/signing parameters are retained for compatibility.
 */
declare(strict_types=1);

final class WxtyError extends RuntimeException
{
    public string $reason;
    public function __construct(string $reason) { parent::__construct($reason); $this->reason = $reason; }
}

final class WxtyGateway
{
    public const CHANNELS = ['dfws' => 1, 'shxwzh' => 2, 'shds' => 4, 'dycj' => 5,
        'hhxd' => 9, 'wxty' => 10, 'mdy' => 11, 'jsrw' => 12];
    public const NAMES = ['dfws' => '东方卫视', 'shxwzh' => '上海新闻综合', 'shds' => '上海都市',
        'dycj' => '第一财经', 'hhxd' => '哈哈炫动', 'wxty' => '五星体育', 'mdy' => '东方影视', 'jsrw' => '纪实人文'];
    private const API = 'https://kapi.kankanews.com';
    private const SECRET = '28c8edde3d61a0411511d3b1866f0636';
    private const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/116.0.0.0 Safari/537.36';
    private array $config;
    private $transport;
    private $resolver;
    private $decryptor;
    private float $deadline = 0;
    private int $requests = 0;
    private array $dns = [];
    private array $rejected = [];

    public function __construct(array $config = [], ?callable $transport = null, ?callable $resolver = null, ?callable $decryptor = null)
    {
        $env = static function (string $key, string $default): string {
            $value = getenv($key); return $value === false ? $default : $value;
        };
        $this->config = array_replace([
            'cache_dir' => $env('KK_CACHE_DIR', sys_get_temp_dir() . '/wxty-' . substr(sha1(__FILE__), 0, 12)),
            'version' => $env('KK_API_VERSION', '2.42.23'),
            'proxy_prefix' => $env('KK_PROXY_PREFIX', ''),
            'ca_bundle' => $env('KK_CA_BUNDLE', ''),
            'media_hosts' => array_filter(array_map('trim', explode(',', $env('KK_MEDIA_HOSTS', '')))),
            'shift_to_live' => $env('KK_SHIFT_TO_LIVE', '1') === '1',
            'timeout' => 20, 'http_timeout' => 6, 'max_requests' => 16, 'max_candidates' => 8,
            'scan_days' => 7, 'url_ttl' => 600, 'min_left' => 90,
            'max_bytes' => 2 * 1024 * 1024, 'max_cache_files' => 256,
        ], $config);
        foreach (['timeout' => [5, 60], 'http_timeout' => [1, 15], 'max_requests' => [1, 40],
            'max_candidates' => [1, 20], 'scan_days' => [1, 7]] as $key => [$min, $max]) {
            $value = $env('KK_' . strtoupper($key), (string) $this->config[$key]);
            $this->config[$key] = max($min, min($max, (int) $value));
        }
        $this->transport = $transport;
        $this->resolver = $resolver;
        $this->decryptor = $decryptor;
        $dir = $this->config['cache_dir'];
        if ((!is_dir($dir) && !@mkdir($dir, 0700, true) && !is_dir($dir)) || !is_writable($dir)) {
            throw new WxtyError('cache-unavailable');
        }
        if ($this->config['proxy_prefix'] !== '') {
            $parts = parse_url($this->config['proxy_prefix']);
            if (!$parts || !in_array($parts['scheme'] ?? '', ['http', 'https'], true)
                || empty($parts['host']) || isset($parts['user']) || isset($parts['pass'])
                || isset($parts['query']) || isset($parts['fragment'])
                || preg_match('/[\x00-\x20\x7f]/', $this->config['proxy_prefix'])) {
                throw new WxtyError('invalid-proxy-config');
            }
        }
    }

    private function checkBudget(): void
    {
        if (microtime(true) >= $this->deadline) throw new WxtyError('resolve-timeout');
        if ($this->requests >= $this->config['max_requests']) throw new WxtyError('request-budget');
    }

    private static function terminal(WxtyError $error): bool
    {
        return in_array($error->reason, ['resolve-timeout', 'request-budget', 'rate-limited',
            'cache-write-failed', 'cache-lock-failed', 'missing-curl', 'missing-openssl', 'invalid-rsa-key'], true);
    }

    private function cachePath(string $key): string
    {
        return $this->config['cache_dir'] . '/' . hash('sha256', $key) . '.json';
    }

    private function readCache(string $key): ?array
    {
        $raw = @file_get_contents($this->cachePath($key));
        if ($raw === false || strlen($raw) > $this->config['max_bytes'] + 1024) return null;
        $record = json_decode($raw, true);
        if (!is_array($record) || !is_numeric($record['expires_at'] ?? null)
            || $record['expires_at'] <= time() || !is_array($record['data'] ?? null)) return null;
        return $record['data'];
    }

    private function writeCache(string $key, array $data, int $expires): void
    {
        if ($expires <= time()) return;
        $payload = json_encode(['expires_at' => $expires, 'data' => $data], JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
        $tmp = @tempnam($this->config['cache_dir'], '.tmp-');
        if ($tmp === false) throw new WxtyError('cache-write-failed');
        try {
            if (!@chmod($tmp, 0600) || @file_put_contents($tmp, $payload) !== strlen($payload)
                || !@rename($tmp, $this->cachePath($key))) throw new WxtyError('cache-write-failed');
        } finally {
            if (is_file($tmp)) @unlink($tmp);
        }
        $this->cleanCache();
    }

    private function cleanCache(): void
    {
        $lock = @fopen($this->config['cache_dir'] . '/gc.lock', 'c');
        if (!$lock) return;
        try {
            if (!flock($lock, LOCK_EX | LOCK_NB)) return;
            $stat = fstat($lock);
            if (($stat['mtime'] ?? 0) > time() - 60 && ($stat['size'] ?? 0) > 0) return;
            ftruncate($lock, 0); fwrite($lock, '1'); fflush($lock);
            $files = glob($this->config['cache_dir'] . '/*.json') ?: [];
            $keep = [];
            foreach ($files as $file) {
                if ($file === $this->cachePath('uuid')) continue;
                $raw = @file_get_contents($file);
                $record = $raw === false ? null : json_decode($raw, true);
                if (!is_array($record) || ($record['expires_at'] ?? 0) <= time()) @unlink($file);
                else $keep[$file] = @filemtime($file) ?: 0;
            }
            asort($keep);
            while (count($keep) > $this->config['max_cache_files']) {
                $file = array_key_first($keep); unset($keep[$file]); @unlink($file);
            }
            foreach (glob($this->config['cache_dir'] . '/.tmp-*') ?: [] as $file) {
                if ((@filemtime($file) ?: 0) < time() - 300) @unlink($file);
            }
        } finally { flock($lock, LOCK_UN); fclose($lock); }
    }

    private function lock(string $name)
    {
        $fp = @fopen($this->config['cache_dir'] . '/' . $name . '.lock', 'c');
        if (!$fp) throw new WxtyError('cache-lock-failed');
        do {
            if (flock($fp, LOCK_EX | LOCK_NB)) return $fp;
            usleep(20000);
        } while (microtime(true) < $this->deadline);
        fclose($fp); throw new WxtyError('refresh-busy');
    }

    private function uuid(): string
    {
        $lock = $this->lock('uuid');
        try {
            $record = $this->readCache('uuid');
            if (is_string($record['uuid'] ?? null) && preg_match('/^[A-Za-z0-9_-]{21}$/D', $record['uuid'])) return $record['uuid'];
            $uuid = substr(strtr(base64_encode(random_bytes(16)), '+/', '-_'), 0, 21);
            $this->writeCache('uuid', ['uuid' => $uuid], time() + 10 * 365 * 86400);
            return $uuid;
        } finally { flock($lock, LOCK_UN); fclose($lock); }
    }

    private static function inCidr(string $ip, string $cidr): bool
    {
        [$network, $bits] = explode('/', $cidr);
        $a = @inet_pton($ip); $b = @inet_pton($network);
        if ($a === false || $b === false || strlen($a) !== strlen($b)) return false;
        $bytes = intdiv((int) $bits, 8); $extra = (int) $bits % 8;
        return substr($a, 0, $bytes) === substr($b, 0, $bytes)
            && ($extra === 0 || ((ord($a[$bytes]) ^ ord($b[$bytes])) & (0xff << (8 - $extra))) === 0);
    }

    public static function isPublicIp(string $ip): bool
    {
        if (!filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE)) return false;
        if (strpos($ip, ':') !== false) {
            if (!self::inCidr($ip, '2000::/3')) return false;
            $deny = ['2001::/32', '2001:db8::/32', '2002::/16', '3fff::/20'];
        } else $deny = ['0.0.0.0/8', '10.0.0.0/8', '127.0.0.0/8', '169.254.0.0/16',
            '172.16.0.0/12', '192.168.0.0/16', '100.64.0.0/10', '192.0.0.0/24', '192.0.2.0/24',
            '198.18.0.0/15', '198.51.100.0/24', '203.0.113.0/24', '224.0.0.0/4', '240.0.0.0/4'];
        foreach ($deny as $cidr) if (self::inCidr($ip, $cidr)) return false;
        return true;
    }

    public function validateUrl(string $url, bool $api = false): array
    {
        if (strlen($url) > 8192 || preg_match('/[\x00-\x20\x7f\\\\]/', $url)) throw new WxtyError('invalid-url');
        $p = parse_url($url);
        if (!$p || !in_array(strtolower($p['scheme'] ?? ''), ['http', 'https'], true)
            || empty($p['host']) || isset($p['user']) || isset($p['pass'])) throw new WxtyError('invalid-url');
        $host = strtolower(trim($p['host'], '[]'));
        $port = $p['port'] ?? (strtolower($p['scheme']) === 'https' ? 443 : 80);
        if (!in_array($port, [80, 443], true)) throw new WxtyError('blocked-port');
        if ($api && ($host !== 'kapi.kankanews.com' || $p['scheme'] !== 'https')) throw new WxtyError('blocked-api-host');
        if (!$api && $this->config['media_hosts']) {
            $allowed = false;
            foreach ($this->config['media_hosts'] as $entry) {
                if (!is_string($entry) || $entry === '') continue;
                $entry = strtolower($entry);
                if ($host === ltrim($entry, '.') || ($entry[0] === '.' && str_ends_with($host, $entry))) $allowed = true;
            }
            if (!$allowed) throw new WxtyError('blocked-media-host');
        }
        if (!isset($this->dns[$host])) {
            if (filter_var($host, FILTER_VALIDATE_IP)) $ips = [$host];
            elseif ($this->resolver) $ips = ($this->resolver)($host);
            else {
                $records = @dns_get_record($host, DNS_A | DNS_AAAA) ?: [];
                $ips = [];
                foreach ($records as $record) {
                    if (isset($record['ip'])) $ips[] = $record['ip'];
                    if (isset($record['ipv6'])) $ips[] = $record['ipv6'];
                }
            }
            if (!$ips) throw new WxtyError('dns-failed');
            foreach ($ips as $ip) if (!is_string($ip) || !self::isPublicIp($ip)) throw new WxtyError('blocked-address');
            $this->dns[$host] = array_values(array_unique($ips));
        }
        return ['host' => $host, 'port' => $port, 'ips' => $this->dns[$host]];
    }

    private function curlGet(string $url, array $headers, array $target, float $timeout): array
    {
        if (!function_exists('curl_init')) throw new WxtyError('missing-curl');
        $requestUrl = $url;
        if ($this->config['proxy_prefix'] !== '' && strtolower((string) parse_url($url, PHP_URL_SCHEME)) === 'https') {
            $requestUrl = $this->config['proxy_prefix'] . substr($url, 8);
        }
        $ch = curl_init($requestUrl);
        $body = ''; $responseHeaders = []; $tooLarge = false;
        $options = [CURLOPT_HTTPHEADER => $headers, CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_SSL_VERIFYPEER => true, CURLOPT_SSL_VERIFYHOST => 2,
            CURLOPT_PROTOCOLS => CURLPROTO_HTTP | CURLPROTO_HTTPS,
            CURLOPT_CONNECTTIMEOUT_MS => max(1, (int) (min(2, $timeout) * 1000)),
            CURLOPT_TIMEOUT_MS => max(1, (int) ($timeout * 1000)), CURLOPT_ENCODING => '',
            CURLOPT_WRITEFUNCTION => function ($ch, string $chunk) use (&$body, &$tooLarge): int {
                if (strlen($body) + strlen($chunk) > $this->config['max_bytes']) { $tooLarge = true; return 0; }
                $body .= $chunk; return strlen($chunk);
            },
            CURLOPT_HEADERFUNCTION => static function ($ch, string $line) use (&$responseHeaders): int {
                if (preg_match('/^HTTP\//', $line)) $responseHeaders = [];
                elseif (strpos($line, ':') !== false) {
                    [$name, $value] = explode(':', $line, 2); $responseHeaders[strtolower(trim($name))] = trim($value);
                }
                return strlen($line);
            },
        ];
        if ($requestUrl === $url && !filter_var($target['host'], FILTER_VALIDATE_IP)) {
            $ips = array_map(static fn($ip) => strpos($ip, ':') === false ? $ip : '[' . $ip . ']', $target['ips']);
            $host = strpos($target['host'], ':') === false ? $target['host'] : '[' . $target['host'] . ']';
            $options[CURLOPT_RESOLVE] = [$host . ':' . $target['port'] . ':' . implode(',', $ips)];
        }
        if ($this->config['ca_bundle'] !== '') $options[CURLOPT_CAINFO] = $this->config['ca_bundle'];
        curl_setopt_array($ch, $options);
        $ok = curl_exec($ch); $errno = curl_errno($ch); $status = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);
        if ($tooLarge) throw new WxtyError('response-too-large');
        if ($ok === false) throw new WxtyError('curl-' . $errno);
        return ['status' => $status, 'headers' => $responseHeaders, 'body' => $body];
    }

    private function request(string $url, array $headers = [], bool $api = false): array
    {
        $headers = array_merge(['User-Agent: ' . self::UA, 'Accept: */*',
            'Origin: https://live.kankanews.com', 'Referer: https://live.kankanews.com/'], $headers);
        for ($hop = 0; $hop <= 3; $hop++) {
            $this->checkBudget();
            $target = $this->validateUrl($url, $api);
            $this->checkBudget();
            $this->requests++;
            $timeout = min($this->config['http_timeout'], $this->deadline - microtime(true));
            $response = $this->transport
                ? ($this->transport)($url, $headers, $target, $timeout)
                : $this->curlGet($url, $headers, $target, $timeout);
            $status = $response['status'];
            if (strlen($response['body']) > $this->config['max_bytes']) throw new WxtyError('response-too-large');
            if ($status === 429) throw new WxtyError('rate-limited');
            if (in_array($status, [301, 302, 303, 307, 308], true)) {
                $location = $response['headers']['location'] ?? '';
                if ($hop === 3 || $location === '') throw new WxtyError('redirect-limit');
                $next = self::resolveUri($url, $location);
                if (strtolower((string) parse_url($url, PHP_URL_SCHEME)) === 'https'
                    && strtolower((string) parse_url($next, PHP_URL_SCHEME)) !== 'https') throw new WxtyError('https-downgrade');
                $url = $next; continue;
            }
            if ($status !== 200) throw new WxtyError('http-' . $status);
            if ($response['body'] === '') throw new WxtyError('empty-response');
            return ['body' => $response['body'], 'url' => $url];
        }
        throw new WxtyError('redirect-limit');
    }

    private function api(string $path, array $params, int $ttl = 0): ?array
    {
        $cacheKey = 'api:' . $path . ':' . http_build_query($params);
        if ($ttl > 0 && ($cached = $this->readCache($cacheKey)) !== null) return $cached;
        $nonce = substr(bin2hex(random_bytes(8)), 0, 8); $timestamp = time();
        $all = array_merge($params, ['Api-Version' => 'v1', 'nonce' => $nonce, 'platform' => 'pc',
            'timestamp' => $timestamp, 'version' => $this->config['version']]);
        ksort($all); $signString = '';
        foreach ($all as $key => $value) {
            if ($value === null) continue;
            if (is_array($value)) $value = str_replace('/', '\\/', json_encode($value, JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR));
            $signString .= $key . '=' . $value . '&';
        }
        $headers = ['Api-Version: v1', 'Nonce: ' . $nonce, 'M-Uuid: ' . $this->uuid(), 'Platform: pc',
            'Version: ' . $this->config['version'], 'Timestamp: ' . $timestamp, 'Sign: ' . md5(md5($signString . self::SECRET))];
        try {
            $response = $this->request(self::API . $path . '?' . http_build_query($params), $headers, true);
            $data = json_decode($response['body'], true);
            if (!is_array($data) || !is_array($data['result'] ?? null)) throw new WxtyError('invalid-api-response');
            if ($ttl > 0) $this->writeCache($cacheKey, $data, time() + $ttl);
            return $data;
        } catch (WxtyError $error) {
            if (self::terminal($error) || in_array($error->reason, ['http-401', 'http-403'], true)) throw $error;
            error_log('[wxty] api ' . $path . ' ' . $error->reason); return null;
        }
    }

    private function addresses($detail, string $source, ?array $program = null): Generator
    {
        if (!is_array($detail)) return;
        foreach (['live_address' => 'live', 'shift_address' => 'shift'] as $key => $kind) {
            if (is_string($detail[$key] ?? null) && $detail[$key] !== '') yield [
                'addr' => $detail[$key], 'source' => $source, 'kind' => $kind,
                'program' => $program['name'] ?? null, 'program_id' => $program['id'] ?? null];
        }
    }

    private function programs(int $channel, string $date): array
    {
        $response = $this->api('/content/pc/tv/programs', ['channel_id' => $channel, 'date' => $date], 30);
        $list = $response['result']['programs'] ?? [];
        return is_array($list) ? array_values(array_filter($list, 'is_array')) : [];
    }

    private function candidates(int $channel): Generator
    {
        $detail = $this->api('/content/pc/tv/channel/detail', ['channel_id' => $channel]);
        yield from $this->addresses($detail['result'] ?? [], 'channel');
        $today = new DateTimeImmutable('today', new DateTimeZone('Asia/Shanghai'));
        $list = $this->programs($channel, $today->format('Y-m-d')); $seen = [];
        foreach ($list as $p) {
            if (!isset($p['id']) || !is_scalar($p['id'])) continue;
            if ((int) ($p['start_time'] ?? 0) <= time() && time() < (int) ($p['end_time'] ?? 0)) {
                $seen[(string) $p['id']] = true;
                $pd = $this->api('/content/pc/tv/program/detail', ['channel_program_id' => $p['id']], 30);
                yield from $this->addresses($pd['result']['channel_info'] ?? [], 'current-program', $p);
                break;
            }
        }
        for ($offset = 0; $offset < $this->config['scan_days']; $offset++) {
            $day = $offset === 0 ? $list : $this->programs($channel, $today->modify('-' . $offset . ' days')->format('Y-m-d'));
            usort($day, static fn($a, $b) => (int) ($b['start_time'] ?? 0) <=> (int) ($a['start_time'] ?? 0));
            foreach ($day as $p) {
                if (!isset($p['id']) || !is_scalar($p['id']) || isset($seen[(string) $p['id']])) continue;
                if ((int) ($p['can_review'] ?? 0) !== 1 && (int) ($p['is_review'] ?? 0) !== 1) continue;
                $seen[(string) $p['id']] = true;
                $pd = $this->api('/content/pc/tv/program/detail', ['channel_program_id' => $p['id']], 30);
                yield from $this->addresses($pd['result']['channel_info'] ?? [], 'donor', $p);
            }
        }
    }

    public static function publicKey(): string
    {
        return "-----BEGIN PUBLIC KEY-----\n"
            . "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDP5hzPUW5RFeE2xBT1ERB3hHZI\n"
            . "Votn/qatWhgc1eZof09qKjElFN6Nma461ZAwGpX4aezKP8Adh4WJj4u2O54xCXDt\n"
            . "wzKRqZO2oNZkuNmF2Va8kLgiEQAAcxYc8JgTN+uQQNpsep4n/o1sArTJooZIF17E\n"
            . "tSqSgXDcJ7yDj5rc7wIDAQAB\n-----END PUBLIC KEY-----";
    }

    public static function decrypt(string $encoded, ?string $pem = null): string
    {
        if (!function_exists('openssl_public_decrypt')) throw new WxtyError('missing-openssl');
        $key = openssl_pkey_get_public($pem ?? self::publicKey());
        $details = $key ? openssl_pkey_get_details($key) : false;
        if (!$details || $details['type'] !== OPENSSL_KEYTYPE_RSA) throw new WxtyError('invalid-rsa-key');
        $size = intdiv($details['bits'] + 7, 8); $raw = base64_decode($encoded, true);
        if ($raw === false || $raw === '' || strlen($raw) % $size !== 0 || strlen($raw) > 16384) throw new WxtyError('invalid-ciphertext');
        $result = '';
        for ($offset = 0; $offset < strlen($raw); $offset += $size) {
            $out = '';
            if (!@openssl_public_decrypt(substr($raw, $offset, $size), $out, $key, OPENSSL_PKCS1_PADDING)) throw new WxtyError('decrypt-failed');
            $result .= $out;
        }
        return $result;
    }

    public static function urlExpiry(string $url): int
    {
        $query = parse_url($url, PHP_URL_QUERY); if (!is_string($query)) return 0;
        parse_str($query, $params); $times = [];
        // These CDN signing fields use hexadecimal seconds, even when digits-only.
        foreach (['volcTime', 'txTime', 'wsTime'] as $name) {
            $value = $params[$name] ?? null;
            if (is_string($value) && preg_match('/^[0-9a-fA-F]{1,10}$/D', $value)) $times[] = (int) hexdec($value);
        }
        $token = $params['token'] ?? null;
        if (is_string($token)) {
            $parts = explode('.', $token);
            if (count($parts) === 3) {
                $payload = strtr($parts[1], '-_', '+/'); $payload .= str_repeat('=', (4 - strlen($payload) % 4) % 4);
                $decoded = base64_decode($payload, true); $data = $decoded === false ? null : json_decode($decoded, true);
                if (is_array($data) && is_numeric($data['exp'] ?? null)) $times[] = (int) $data['exp'];
            }
        }
        $times = array_filter($times, static fn($value) => $value > 0);
        return $times ? min($times) : 0;
    }

    public static function withoutTimeRange(string $url): string
    {
        // Preserve every retained query byte; rebuilding with parse_str would alter signatures.
        $fragment = ''; $hash = strpos($url, '#');
        if ($hash !== false) { $fragment = substr($url, $hash); $url = substr($url, 0, $hash); }
        $question = strpos($url, '?');
        if ($question === false) return $url . $fragment;
        $keep = [];
        foreach (explode('&', substr($url, $question + 1)) as $part) {
            $key = strtolower(rawurldecode(explode('=', $part, 2)[0]));
            if (!in_array($key, ['start', 'end', 'starttime', 'endtime'], true)) $keep[] = $part;
        }
        return substr($url, 0, $question) . ($keep ? '?' . implode('&', $keep) : '') . $fragment;
    }

    private static function removeDotSegments(string $path): string
    {
        $out = '';
        while ($path !== '') {
            if (str_starts_with($path, '../')) $path = substr($path, 3);
            elseif (str_starts_with($path, './')) $path = substr($path, 2);
            elseif (str_starts_with($path, '/./')) $path = substr($path, 2);
            elseif ($path === '/.') $path = '/';
            elseif (str_starts_with($path, '/../') || $path === '/..') {
                $path = $path === '/..' ? '/' : substr($path, 3);
                $last = strrpos($out, '/'); $out = $last === false ? '' : substr($out, 0, $last);
            } elseif ($path === '.' || $path === '..') $path = '';
            else {
                $next = strpos($path, '/', $path[0] === '/' ? 1 : 0);
                if ($next === false) { $out .= $path; $path = ''; }
                else { $out .= substr($path, 0, $next); $path = substr($path, $next); }
            }
        }
        return $out;
    }

    public static function resolveUri(string $base, string $reference): string
    {
        if (preg_match('/[\x00-\x20\x7f\\\\]/', $reference)) throw new WxtyError('invalid-uri');
        $b = parse_url($base); $r = parse_url($reference);
        if (!$b || $r === false || !isset($b['scheme'], $b['host'])) throw new WxtyError('invalid-uri');
        if (isset($r['scheme'])) $t = $r;
        elseif (isset($r['host'])) $t = array_merge($r, ['scheme' => $b['scheme']]);
        else {
            $t = ['scheme' => $b['scheme'], 'host' => $b['host']];
            foreach (['port', 'user', 'pass'] as $name) if (isset($b[$name])) $t[$name] = $b[$name];
            $path = $r['path'] ?? '';
            if ($path === '') {
                $t['path'] = $b['path'] ?? '';
                if (isset($r['query'])) $t['query'] = $r['query'];
                elseif (isset($b['query'])) $t['query'] = $b['query'];
            } else {
                $basePath = $b['path'] ?? '';
                $slash = strrpos($basePath, '/');
                $t['path'] = $path[0] === '/' ? $path : ($slash === false ? '/' : substr($basePath, 0, $slash + 1)) . $path;
                if (isset($r['query'])) $t['query'] = $r['query'];
            }
            if (isset($r['fragment'])) $t['fragment'] = $r['fragment'];
        }
        if (!in_array(strtolower($t['scheme'] ?? ''), ['http', 'https'], true) || empty($t['host'])
            || isset($t['user']) || isset($t['pass'])) throw new WxtyError('invalid-uri');
        $out = strtolower($t['scheme']) . '://' . $t['host'] . (isset($t['port']) ? ':' . $t['port'] : '')
            . self::removeDotSegments($t['path'] ?? '');
        if (isset($t['query'])) $out .= '?' . $t['query'];
        if (isset($t['fragment'])) $out .= '#' . $t['fragment'];
        return $out;
    }

    public static function rewritePlaylist(string $body, string $base): string
    {
        $body = preg_replace('/^\xEF\xBB\xBF/', '', $body);
        $body = str_replace(["\r\n", "\r"], "\n", $body);
        if (!preg_match('/^#EXTM3U(?:\r\n|\r|\n|$)/', $body)) throw new WxtyError('invalid-playlist');
        $out = []; $pending = false; $references = 0;
        foreach (preg_split('/\r\n|\n|\r/', $body) as $line) {
            $line = trim($line);
            if ($line === '') { $out[] = ''; continue; }
            if ($line[0] !== '#') {
                $out[] = self::resolveUri($base, $line);
                if ($pending) { $references++; $pending = false; }
            } else {
                if (str_starts_with($line, '#EXTINF:') || str_starts_with($line, '#EXT-X-STREAM-INF:')) {
                    if ($pending) throw new WxtyError('invalid-playlist');
                    $pending = true;
                }
                $out[] = preg_replace_callback('/\bURI="([^"]*)"/i', static function ($match) use ($base) {
                    return 'URI="' . self::resolveUri($base, $match[1]) . '"';
                }, $line);
            }
        }
        if ($pending) throw new WxtyError('invalid-playlist');
        if ($references === 0) throw new WxtyError('empty-playlist');
        return implode("\n", $out);
    }

    private function playlist(string $url, bool $verifyChild, int $depth = 0): array
    {
        if ($depth > 5) throw new WxtyError('playlist-depth');
        $response = $this->request($url);
        $body = self::rewritePlaylist($response['body'], $response['url']);
        if ($verifyChild && strpos($body, '#EXT-X-STREAM-INF:') !== false) {
            $variants = []; $pending = false;
            foreach (explode("\n", $body) as $line) {
                if (str_starts_with($line, '#EXT-X-STREAM-INF:')) $pending = true;
                elseif ($pending && $line !== '' && $line[0] !== '#') { $variants[] = $line; $pending = false; }
            }
            $valid = false;
            foreach ($variants as $variant) {
                try { $this->playlist($variant, true, $depth + 1); $valid = true; break; }
                catch (WxtyError $error) { if (self::terminal($error)) throw $error; }
            }
            if (!$valid) throw new WxtyError('no-playable-variant');
        }
        return ['playlist' => $body, 'url' => $response['url']];
    }

    private function cachedResult(int $channel): ?array
    {
        $record = $this->readCache('live:' . $channel);
        if (!$record || !is_string($record['url'] ?? null) || isset($this->rejected[$record['url']])) return null;
        try {
            $playlist = $this->playlist($record['url'], false);
            return array_merge($record, $playlist, ['cache' => 'HIT', 'requests' => $this->requests]);
        } catch (WxtyError $error) {
            if ($error->reason === 'rate-limited') $this->writeCache('failure:' . $channel, ['reason' => $error->reason], time() + 30);
            if (self::terminal($error)) throw $error;
            $this->rejected[$record['url']] = true; return null;
        }
    }

    public function resolve(int $channel, bool $force = false): array
    {
        if (!in_array($channel, self::CHANNELS, true)) throw new WxtyError('invalid-channel');
        $this->deadline = microtime(true) + $this->config['timeout']; $started = microtime(true);
        $this->requests = 0; $this->dns = []; $this->rejected = [];
        $failure = $this->readCache('failure:' . $channel);
        if ($failure && is_string($failure['reason'] ?? null)) throw new WxtyError($failure['reason']);
        if (!$force && ($hit = $this->cachedResult($channel)) !== null) return $hit;
        $lock = $this->lock('channel-' . $channel);
        try {
            // Coalesce refreshes that were queued before another worker published a result.
            $record = $this->readCache('live:' . $channel);
            if ((!$force || ($record['created_at'] ?? 0) >= $started)
                && ($hit = $this->cachedResult($channel)) !== null) return $hit;
            $failure = $this->readCache('failure:' . $channel);
            if ($failure && is_string($failure['reason'] ?? null)) throw new WxtyError($failure['reason']);
            $count = 0; $seen = []; $last = 'address-unavailable';
            try {
                foreach ($this->candidates($channel) as $candidate) {
                    $fingerprint = hash('sha256', $candidate['addr']);
                    if (isset($seen[$fingerprint])) continue;
                    $seen[$fingerprint] = true;
                    if (++$count > $this->config['max_candidates']) break;
                    try {
                        $plain = $this->decryptor ? ($this->decryptor)($candidate['addr']) : self::decrypt($candidate['addr']);
                        if ($candidate['kind'] === 'shift') {
                            if (!$this->config['shift_to_live']) throw new WxtyError('replay-only-address');
                            $plain = self::withoutTimeRange($plain);
                        }
                        if (isset($this->rejected[$plain])) continue;
                        $expires = self::urlExpiry($plain);
                        if ($expires > 0 && $expires - time() <= $this->config['min_left']) throw new WxtyError('address-expiring');
                        $playlist = $this->playlist($plain, true);
                        $finalExpiry = self::urlExpiry($playlist['url']);
                        if ($finalExpiry > 0) $expires = $expires > 0 ? min($expires, $finalExpiry) : $finalExpiry;
                        if ($expires > 0 && $expires - time() <= $this->config['min_left']) throw new WxtyError('address-expiring');
                        $effective = min(time() + $this->config['url_ttl'], $expires > 0 ? $expires - $this->config['min_left'] : time() + 210);
                        $result = ['url' => $plain, 'source' => $candidate['source'],
                            'kind' => $candidate['kind'] === 'shift' ? 'shift-converted' : 'live',
                            'program' => $candidate['program'], 'program_id' => $candidate['program_id'],
                            'expires_at' => $effective, 'signed_expires_at' => $expires, 'created_at' => microtime(true)];
                        $this->writeCache('live:' . $channel, $result, $effective);
                        @unlink($this->cachePath('failure:' . $channel));
                        return array_merge($result, $playlist, ['cache' => 'MISS', 'requests' => $this->requests]);
                    } catch (WxtyError $error) {
                        if (self::terminal($error)) throw $error;
                        $last = $error->reason; error_log('[wxty] candidate ' . $candidate['source'] . ' ' . $last);
                        if ($count >= $this->config['max_candidates']) break;
                    }
                }
                throw new WxtyError($last);
            } catch (WxtyError $error) {
                $this->writeCache('failure:' . $channel, ['reason' => $error->reason], time() + ($error->reason === 'rate-limited' ? 30 : 3));
                throw $error;
            }
        } finally { flock($lock, LOCK_UN); fclose($lock); }
    }
}

function wxtySubscription(): string
{
    $configured = getenv('KK_PUBLIC_BASE_URL') ?: '';
    if ($configured !== '') $base = rtrim($configured, '/');
    else {
        $https = strtolower((string) ($_SERVER['HTTPS'] ?? ''));
        $scheme = ($https !== '' && $https !== 'off' && $https !== '0') ? 'https' : 'http';
        $host = $_SERVER['HTTP_HOST'] ?? '';
        if (!preg_match('/^(?:\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9][A-Za-z0-9.-]*)(?::[0-9]{1,5})?$/D', $host)) {
            throw new WxtyError('invalid-request-origin');
        }
        $directory = dirname($_SERVER['SCRIPT_NAME'] ?? '/wxty.php');
        if ($directory === '.' || $directory === '/') $directory = '';
        $base = $scheme . '://' . $host . $directory;
    }
    $parts = parse_url($base);
    if (!$parts || !in_array($parts['scheme'] ?? '', ['http', 'https'], true) || empty($parts['host'])
        || isset($parts['user']) || isset($parts['pass']) || isset($parts['query']) || isset($parts['fragment'])
        || preg_match('/[\x00-\x20\x7f\\\\]/', $base) || (($parts['port'] ?? 80) < 1)
        || !filter_var($base, FILTER_VALIDATE_URL)) {
        throw new WxtyError($configured === '' ? 'invalid-request-origin' : 'invalid-public-base');
    }
    $lines = ['#EXTM3U'];
    foreach (WxtyGateway::CHANNELS as $id => $channel) {
        $name = WxtyGateway::NAMES[$id];
        $lines[] = '#EXTINF:-1 tvg-id="' . $id . '" tvg-name="' . $name . '" group-title="看看新闻",' . $name;
        $lines[] = $base . '/wxty.php?id=' . $id;
    }
    return implode("\n", $lines) . "\n";
}

function wxtyMain(): void
{
    header('Cache-Control: no-cache, no-store, must-revalidate');
    $method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
    if (!in_array($method, ['GET', 'HEAD'], true)) { header('Allow: GET, HEAD'); http_response_code(405); return; }
    $id = $_GET['id'] ?? 'wxty';
    if (!is_string($id) || !isset(WxtyGateway::CHANNELS[$id])) { http_response_code(400); echo '无效频道ID'; return; }
    $authorization = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
    $token = str_starts_with($authorization, 'Bearer ') ? substr($authorization, 7) : '';
    $admin = getenv('KK_ADMIN_TOKEN') ?: '';
    $isAdmin = $admin !== '' && hash_equals($admin, $token);
    $access = getenv('KK_ACCESS_TOKEN') ?: '';
    if ($access !== '' && !$isAdmin && !hash_equals($access, $token)) { http_response_code(401); header('WWW-Authenticate: Bearer'); return; }
    if (isset($_GET['ts_url'])) { http_response_code(410); echo '分片代理已关闭；播放列表使用 CDN 直连'; return; }
    $force = isset($_GET['refresh']) && $_GET['refresh'] !== '0';
    $info = isset($_GET['info']);
    if (($force || $info) && !$isAdmin) { http_response_code(403); echo '需要管理员 Bearer 令牌'; return; }
    if (isset($_GET['list'])) {
        if ($_GET['list'] !== '1') { http_response_code(400); echo '无效订阅参数'; return; }
        try { $subscription = wxtySubscription(); }
        catch (WxtyError $error) {
            http_response_code($error->reason === 'invalid-public-base' ? 500 : 400);
            header('Content-Type: text/plain; charset=utf-8'); echo $error->reason; return;
        }
        header('Content-Type: audio/x-mpegurl; charset=utf-8');
        header('Content-Disposition: inline; filename="all.m3u"');
        if ($method !== 'HEAD') echo $subscription;
        return;
    }
    header('Content-Type: ' . ($info ? 'application/json; charset=utf-8' : 'application/vnd.apple.mpegurl'));
    if ($method === 'HEAD') { header('X-Playback-State: unobserved'); return; }
    try {
        $gateway = new WxtyGateway(); $result = $gateway->resolve(WxtyGateway::CHANNELS[$id], $force);
        header('X-Live-Url-Cache: ' . $result['cache']);
        header('X-Live-Url-Source: ' . preg_replace('/[^a-z-]/', '', $result['source']));
        if ($info) {
            unset($result['playlist'], $result['url']);
            $result['id'] = $id; $result['channel_id'] = WxtyGateway::CHANNELS[$id];
            $result['expires_in'] = max(0, $result['expires_at'] - time());
            echo json_encode($result, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
        } else echo $result['playlist'];
    } catch (Throwable $error) {
        $reason = $error instanceof WxtyError ? $error->reason : 'internal-error';
        error_log('[wxty] channel=' . $id . ' reason=' . $reason);
        header('X-Fallback-Reason: ' . preg_replace('/[^A-Za-z0-9-]/', '', $reason));
        $fallback = getenv('KK_FALLBACK_URL') ?: '';
        if (!$info && $fallback !== '' && filter_var($fallback, FILTER_VALIDATE_URL)
            && preg_match('/^https?:\/\//', $fallback) && !preg_match('/[\x00-\x20\x7f]/', $fallback)) {
            header('Location: ' . $fallback, true, 302); return;
        }
        header('Content-Type: ' . ($info ? 'application/json; charset=utf-8' : 'text/plain; charset=utf-8'));
        http_response_code(503); header('Retry-After: ' . ($reason === 'rate-limited' ? '30' : '3'));
        echo $info ? json_encode(['error' => $reason]) : '暂时无法获取直播：' . $reason;
    }
}

function wxtyDispatch(): void
{
    $path = parse_url($_SERVER['REQUEST_URI'] ?? '/wxty.php', PHP_URL_PATH);
    $script = $_SERVER['SCRIPT_NAME'] ?? '/wxty.php';
    $direct = is_string($path) && $path === $script && basename($script) === basename(__FILE__);
    if (!in_array($path, ['/', '/all.m3u', '/wxty.php'], true) && !$direct) {
        http_response_code(404);
        header('Content-Type: text/plain; charset=utf-8');
        echo 'Not found';
        return;
    }
    if (!$direct || $path === '/' || $path === '/all.m3u') $_SERVER['SCRIPT_NAME'] = '/wxty.php';
    if ($path === '/' || $path === '/all.m3u') $_GET['list'] = '1';
    wxtyMain();
}

function wxtyServe(array $arguments): int
{
    $host = getenv('KK_BIND_HOST') ?: '127.0.0.1';
    $port = getenv('KK_PORT') ?: '52451';
    foreach ($arguments as $argument) {
        if ($argument === '--help') {
            echo "Usage: php wxty.php [--host=127.0.0.1] [--port=52451]\n";
            return 0;
        }
        if (str_starts_with($argument, '--host=')) $host = substr($argument, 7);
        elseif (str_starts_with($argument, '--port=')) $port = substr($argument, 7);
        else { fwrite(STDERR, "未知启动参数；使用 --help 查看用法\n"); return 2; }
    }
    if (($host !== 'localhost' && !filter_var($host, FILTER_VALIDATE_IP))
        || !ctype_digit($port) || (int) $port < 1 || (int) $port > 65535) {
        fwrite(STDERR, "无效监听地址或端口\n"); return 2;
    }
    $listenHost = str_contains($host, ':') ? '[' . $host . ']' : $host;
    $listen = $listenHost . ':' . (int) $port;
    $publicHost = in_array($host, ['0.0.0.0', '::'], true) ? '127.0.0.1' : $listenHost;
    echo '订阅地址：http://' . $publicHost . ':' . (int) $port . "/all.m3u\n";
    $command = ['-S', $listen, '-t', __DIR__, __FILE__];
    // Replace the launcher where supported; otherwise keep the standard server as a child.
    if (function_exists('pcntl_exec')) {
        echo 'wxty-server-pid=' . getmypid() . "\n"; fflush(STDOUT);
        @pcntl_exec(PHP_BINARY, $command);
    }
    if (!function_exists('proc_open')) {
        fwrite(STDERR, "当前 PHP 禁止启动内置服务器；可使用 php -S 127.0.0.1:52451 wxty.php\n"); return 1;
    }
    $process = @proc_open(array_merge([PHP_BINARY], $command), [STDIN, STDOUT, STDERR], $pipes, __DIR__);
    if (!is_resource($process)) { fwrite(STDERR, "启动 PHP 内置服务器失败\n"); return 1; }
    $status = proc_get_status($process);
    echo 'wxty-server-pid=' . $status['pid'] . "\n"; fflush(STDOUT);
    $stop = static function () use ($process): void {
        if (is_resource($process) && proc_get_status($process)['running']) proc_terminate($process);
    };
    register_shutdown_function($stop);
    if (function_exists('pcntl_async_signals') && function_exists('pcntl_signal')) {
        pcntl_async_signals(true);
        foreach ([SIGINT, SIGTERM] as $signal) pcntl_signal($signal, static function ($signal) use ($stop) {
            $stop(); exit(128 + $signal);
        });
    }
    $code = proc_close($process);
    return $code < 0 ? 1 : $code;
}

if (!defined('WXTY_LIBRARY_ONLY')) {
    if (PHP_SAPI === 'cli' && !isset($_SERVER['REQUEST_METHOD']) && !isset($_SERVER['REQUEST_URI'])) {
        exit(wxtyServe(array_slice($argv ?? [], 1)));
    }
    wxtyDispatch();
}
