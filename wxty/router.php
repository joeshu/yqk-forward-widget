<?php
declare(strict_types=1);

// PHP built-in server: php -S 127.0.0.1:52451 router.php
if (!defined('WXTY_LIBRARY_ONLY')) define('WXTY_LIBRARY_ONLY', true);
require_once __DIR__ . '/wxty.php';

$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH);
if (!in_array($path, ['/', '/all.m3u', '/wxty.php'], true)) {
    http_response_code(404);
    header('Content-Type: text/plain; charset=utf-8');
    echo 'Not found';
    return;
}

$_SERVER['SCRIPT_NAME'] = '/wxty.php';
if ($path === '/' || $path === '/all.m3u') $_GET['list'] = '1';
wxtyMain();
