<?php
// Returns a non-200 status + a custom header + JSON body, to verify the
// WebTransport bridge propagates the real response status/headers (not a
// hard-coded 200). Mirrors Laravel's 419 "page expired" (CSRF) response.
http_response_code(419);
header('Content-Type: application/json');
header('X-Demo-Header: demo-value');
echo json_encode(['msg' => 'page-expired', 'code' => 419]);
