<?php
date_default_timezone_set('UTC');
header('Content-Type: text/plain');
echo "method=" . $_SERVER['REQUEST_METHOD'] . "\n";
echo "name=" . ($_POST['name'] ?? '-') . "\n";
echo "len=" . ($_SERVER['CONTENT_LENGTH'] ?? '0') . "\n";
