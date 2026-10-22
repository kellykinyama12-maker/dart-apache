<?php
// Minimal front-controller stand-in: proves the server routes unmatched paths
// here while preserving REQUEST_URI (what Laravel's router reads).
header('Content-Type: application/json');
echo json_encode([
    'front_controller' => true,
    'request_uri' => $_SERVER['REQUEST_URI'] ?? '',
    'method' => $_SERVER['REQUEST_METHOD'] ?? '',
    'script_name' => $_SERVER['SCRIPT_NAME'] ?? '',
]);
