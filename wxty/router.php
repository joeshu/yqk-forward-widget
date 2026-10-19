<?php
declare(strict_types=1);

// Compatibility wrapper. New deployments only need: php wxty.php
if (!defined('WXTY_LIBRARY_ONLY')) define('WXTY_LIBRARY_ONLY', true);
require_once __DIR__ . '/wxty.php';

wxtyDispatch();
