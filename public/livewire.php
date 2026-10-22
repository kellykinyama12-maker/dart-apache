<?php
// Demo endpoint standing in for Laravel's /livewire/update handler. It reads
// the JSON request the browser sends over WebTransport, "renders" a component,
// and returns a Livewire-shaped response envelope as JSON. A real deployment
// points --wt-bridge-path at the Laravel front controller instead.

header('Content-Type: application/json');

$raw = file_get_contents('php://input');
$in = json_decode($raw, true);
if (!is_array($in)) {
    $in = [];
}

$component = isset($in['component']) ? (string) $in['component'] : 'demo';
$message = isset($in['message']) ? (string) $in['message'] : '';
$calls = isset($in['calls']) && is_array($in['calls']) ? $in['calls'] : [];

// Emulate a Livewire effects envelope (html diff + dispatched browser events).
$response = [
    'component' => $component,
    'effects' => [
        'html' => '<div id="' . htmlspecialchars($component, ENT_QUOTES) . '">'
            . 'Hello from Livewire over WebTransport: '
            . htmlspecialchars($message, ENT_QUOTES)
            . '</div>',
        'dispatches' => $calls,
    ],
    'transport' => 'webtransport',
    'received_bytes' => strlen($raw),
    'server_time' => gmdate('c'),
];

echo json_encode($response);
