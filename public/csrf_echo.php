<?php
// Echoes the credential-bearing request headers the bridge forwarded, so the
// WebTransport CSRF/cookie path can be verified without a full Laravel install.
header('Content-Type: application/json');
echo json_encode([
    'method' => $_SERVER['REQUEST_METHOD'] ?? '',
    'cookie' => $_SERVER['HTTP_COOKIE'] ?? null,
    'x_csrf_token' => $_SERVER['HTTP_X_CSRF_TOKEN'] ?? null,
    'x_xsrf_token' => $_SERVER['HTTP_X_XSRF_TOKEN'] ?? null,
    'authorization' => $_SERVER['HTTP_AUTHORIZATION'] ?? null,
    'x_requested_with' => $_SERVER['HTTP_X_REQUESTED_WITH'] ?? null,
    'content_type' => $_SERVER['CONTENT_TYPE'] ?? null,
    'body' => file_get_contents('php://input'),
]);
