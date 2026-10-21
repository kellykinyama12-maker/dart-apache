<?php
// Sample PHP page served by dart-apache through php-cgi, just like Apache.
date_default_timezone_set('UTC');
header('X-Powered-By: dart-apache');
$name = $_GET['name'] ?? 'world';
?>
<!DOCTYPE html>
<html>
<head><title>dart-apache + PHP</title></head>
<body>
  <h1>Hello, <?= htmlspecialchars($name) ?>!</h1>
  <p>Served by <?= htmlspecialchars($_SERVER['SERVER_SOFTWARE']) ?></p>
  <p>Request method: <?= htmlspecialchars($_SERVER['REQUEST_METHOD']) ?></p>
  <p>The time is <?= date('Y-m-d H:i:s') ?>.</p>
  <?php if (!empty($_SERVER['PATH_INFO'])): ?>
    <p>PATH_INFO: <?= htmlspecialchars($_SERVER['PATH_INFO']) ?></p>
  <?php endif; ?>
</body>
</html>
