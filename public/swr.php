<?php
// stale-while-revalidate demo: immediately stale, but serveable-stale for 30s.
// With `--cache`: first request MISS; subsequent requests are served STALE
// instantly while a background revalidation refreshes the timestamp.
header('Cache-Control: max-age=0, stale-while-revalidate=30');
header('Content-Type: text/plain; charset=UTF-8');
echo 'generated-at=' . microtime(true) . "\n";
