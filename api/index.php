<?php
/**
 * VPN Panel API — backend tunggal, ringan (tanpa framework).
 * Install di: /var/www/vpn-api/index.php  (lihat README-DEPLOY.md)
 *
 * Semua permintaan lewat sini, dipetakan ke perintah di api-cli.sh,
 * yang jalan sebagai root lewat sudo (dibatasi via sudoers).
 */

// ── Konfigurasi ─────────────────────────────────────────────
$API_KEY   = getenv('VPN_API_KEY') ?: 'GANTI_DENGAN_API_KEY_ACAK_YANG_PANJANG';
$BRIDGE    = '/etc/vpn-script/api/api-cli.sh';
$SUDO_BIN  = '/usr/bin/sudo';

header('Content-Type: application/json; charset=utf-8');
header('Access-Control-Allow-Origin: *');       // ganti ke domain panel-mu di produksi
header('Access-Control-Allow-Headers: X-Api-Key, Content-Type');
header('Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS');
if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') { exit; }

function fail($code, $msg) {
  http_response_code($code);
  echo json_encode(['ok' => false, 'error' => $msg]);
  exit;
}

// ── Autentikasi sederhana lewat header X-Api-Key ────────────
$given = $_SERVER['HTTP_X_API_KEY'] ?? '';
if (!hash_equals($API_KEY, $given)) {
  fail(401, 'API key tidak valid');
}

// ── Jalankan bridge dengan argumen yang di-escape aman ──────
function run_bridge($args) {
  global $BRIDGE, $SUDO_BIN;
  $cmd = escapeshellcmd($SUDO_BIN) . ' ' . escapeshellcmd($BRIDGE);
  foreach ($args as $a) {
    $cmd .= ' ' . escapeshellarg((string) $a);
  }
  $out = shell_exec($cmd . ' 2>&1');
  $decoded = json_decode($out, true);
  if ($decoded === null) {
    fail(500, 'Bridge gagal atau output tidak valid: ' . substr((string)$out, 0, 300));
  }
  return $decoded;
}

$action = $_GET['action'] ?? '';
$method = $_SERVER['REQUEST_METHOD'];
$body   = json_decode(file_get_contents('php://input'), true) ?? [];

switch (true) {

  case $action === 'summary' && $method === 'GET':
    echo json_encode(run_bridge(['summary']));
    break;

  case $action === 'accounts' && $method === 'GET':
    echo json_encode(run_bridge(['list_accounts']));
    break;

  case $action === 'accounts' && $method === 'POST':
    $required = ['proto', 'username'];
    foreach ($required as $r) {
      if (empty($body[$r])) fail(422, "field '$r' wajib diisi");
    }
    $result = run_bridge([
      'create_account',
      $body['proto'],
      $body['username'],
      $body['days']         ?? 30,
      $body['ip_limit']     ?? 2,
      $body['quota_gb']     ?? 0,
      $body['trial_hours']  ?? 0,
    ]);
    echo json_encode($result);
    break;

  case $action === 'accounts' && $method === 'DELETE':
    if (empty($body['proto']) || empty($body['username'])) fail(422, "proto dan username wajib diisi");
    echo json_encode(run_bridge(['delete_account', $body['proto'], $body['username']]));
    break;

  case $action === 'service' && $method === 'POST':
    if (empty($body['name']) || empty($body['action'])) fail(422, "name dan action wajib diisi");
    echo json_encode(run_bridge(['toggle_service', $body['name'], $body['action']]));
    break;

  default:
    fail(404, 'Endpoint tidak ditemukan');
}
