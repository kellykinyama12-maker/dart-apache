<?php
// Cache demo: a cacheable dynamic response. With `--cache`, the first request
// is X-Cache: MISS and subsequent ones within 60s are HIT (same timestamp).
header('Cache-Control: max-age=60');
header('Content-Type: text/plain; charset=UTF-8');
echo 'generated-at=' . microtime(true) . "\n";
