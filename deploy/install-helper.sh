#!/bin/bash
# Drive to Finder — Mac helper installer
# Run as root. In Iru: Library > Custom Script (or Self Service). Locally: sudo bash install-helper.sh
# Installs a small script Chrome uses to open Finder, plus the file that tells Chrome where it is.
set -euo pipefail

HOST_DIR="/Library/Application Support/Apparent/DriveFinder"
CHROME_DIR="/Library/Google/Chrome/NativeMessagingHosts"

mkdir -p "$HOST_DIR" "$CHROME_DIR"

cat > "$HOST_DIR/drivefinder-host" <<'JXA_EOF'
#!/usr/bin/osascript -l JavaScript
// Drive to Finder — native messaging helper for Chrome on macOS.
// Uses only what ships with macOS (osascript + Foundation), so nothing else to install.
// Protocol: Chrome writes a 4-byte little-endian length + UTF-8 JSON to stdin and
// reads the same shape back from stdout. Nothing else may be written to stdout.

ObjC.import('Foundation');
ObjC.import('stdlib');

var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function b64ToBytes(s) {
  var out = [], buf = 0, bits = 0;
  for (var i = 0; i < s.length; i++) {
    var c = B64.indexOf(s.charAt(i));
    if (c < 0) continue; // skips '=' padding
    buf = (buf << 6) | c; bits += 6;
    if (bits >= 8) { bits -= 8; out.push((buf >> bits) & 0xff); }
  }
  return out;
}

function bytesToB64(bytes) {
  var s = '';
  for (var i = 0; i < bytes.length; i += 3) {
    var n = (bytes[i] << 16) | ((bytes[i + 1] || 0) << 8) | (bytes[i + 2] || 0);
    s += B64[(n >> 18) & 63] + B64[(n >> 12) & 63];
    s += i + 1 < bytes.length ? B64[(n >> 6) & 63] : '=';
    s += i + 2 < bytes.length ? B64[n & 63] : '=';
  }
  return s;
}

function readMessage() {
  var stdin = $.NSFileHandle.fileHandleWithStandardInput;
  var head = stdin.readDataOfLength(4);
  if (head.length < 4) return null;
  var b = b64ToBytes(head.base64EncodedStringWithOptions(0).js);
  var len = (b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)) >>> 0;
  var body = stdin.readDataOfLength(len);
  var text = $.NSString.alloc.initWithDataEncoding(body, $.NSUTF8StringEncoding).js;
  return JSON.parse(text);
}

function writeMessage(obj) {
  var data = $(JSON.stringify(obj)).dataUsingEncoding($.NSUTF8StringEncoding);
  var n = data.length;
  var head = $.NSData.alloc.initWithBase64EncodedStringOptions(
    bytesToB64([n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff, (n >> 24) & 0xff]), 0);
  var stdout = $.NSFileHandle.fileHandleWithStandardOutput;
  stdout.writeData(head);
  stdout.writeData(data);
}

var fm = $.NSFileManager.defaultManager;

function exists(p) { return fm.fileExistsAtPath(p); }

function listDir(p) {
  var items = ObjC.deepUnwrap(fm.contentsOfDirectoryAtPathError(p, null));
  return Array.isArray(items) ? items : [];
}

// Every Drive for desktop account appears as ~/Library/CloudStorage/GoogleDrive-<email>.
// Older installs used /Volumes/GoogleDrive.
function findDriveRoot(email) {
  var cloud = $.NSHomeDirectory().js + '/Library/CloudStorage';
  var roots = listDir(cloud)
    .filter(function (n) { return n.indexOf('GoogleDrive-') === 0; })
    .map(function (n) { return { email: n.slice('GoogleDrive-'.length), path: cloud + '/' + n }; });

  var want = String(email || '').toLowerCase();
  for (var i = 0; i < roots.length; i++) {
    if (roots[i].email.toLowerCase() === want) return roots[i].path;
  }
  if (roots.length === 1) return roots[0].path;
  if (!roots.length && exists('/Volumes/GoogleDrive/My Drive')) return '/Volumes/GoogleDrive';
  if (!roots.length) throw new Error('Google Drive for desktop doesn’t seem to be running on this Mac. Open it, sign in, and try again.');
  throw new Error('Drive for desktop isn’t signed in as ' + email + ' on this Mac. Signed-in accounts: ' +
    roots.map(function (r) { return r.email; }).join(', '));
}

// Drive allows characters in names that macOS paths can't hold, so try the likely variants.
function variants(name) {
  var v = [name, name.replace(/\//g, ':'), name.replace(/\//g, '_'), name.replace(/[\/:]/g, '_'), name.trim()];
  return v.filter(function (x, i) { return x && v.indexOf(x) === i; });
}

function openWith(args) {
  var task = $.NSTask.alloc.init;
  task.launchPath = '/usr/bin/open';
  task.arguments = $(args);
  task.standardOutput = $.NSFileHandle.fileHandleWithNullDevice; // keep stdout clean for Chrome
  task.standardError = $.NSFileHandle.fileHandleWithNullDevice;
  task.launch;
  task.waitUntilExit;
  return task.terminationStatus;
}

function findChild(dir, name) {
  var opts = variants(String(name));
  for (var j = 0; j < opts.length; j++) {
    if (exists(dir + '/' + opts[j])) return opts[j];
  }
  return null;
}

// How many of the path pieces exist, in order, under dir.
function depthUnder(dir, segments, limit) {
  var cur = dir, n = 0;
  for (var i = 0; i < segments.length && i < limit; i++) {
    var hit = findChild(cur, segments[i]);
    if (!hit) break;
    cur = cur + '/' + hit;
    n++;
  }
  return n;
}

// Pick the shared drive folder: by name if Chrome knew it, otherwise the one that holds the path.
function pickSharedDrive(sharedDir, hint, segments) {
  if (hint) {
    var named = findChild(sharedDir, hint);
    if (named) return named;
  }
  if (!segments.length) return null;
  var best = null, bestScore = 0, drives = listDir(sharedDir);
  for (var i = 0; i < drives.length; i++) {
    var score = depthUnder(sharedDir + '/' + drives[i], segments, 4);
    if (score > bestScore) { best = drives[i]; bestScore = score; }
  }
  return best;
}

function handle(msg) {
  if (!msg || !Array.isArray(msg.segments)) return { ok: false, error: 'Nothing to open.' };
  var root = findDriveRoot(msg.email);
  var segments = msg.segments.map(String);
  var cur;

  if (msg.sharedDrive) {
    var sharedDir = root + '/Shared drives';
    if (!exists(sharedDir)) return { ok: false, error: 'Couldn’t find Shared drives in Drive for desktop on this Mac.' };
    var drive = pickSharedDrive(sharedDir, msg.driveNameHint, segments);
    if (!drive) {
      openWith([sharedDir]);
      return { ok: true, exact: false, path: sharedDir };
    }
    cur = sharedDir + '/' + drive;
  } else {
    if (!segments.length) return { ok: false, error: 'Nothing to open.' };
    cur = root;
  }

  var matched = 0;
  for (var i = 0; i < segments.length; i++) {
    var hit = findChild(cur, segments[i]);
    if (!hit) break;
    cur = cur + '/' + hit;
    matched++;
  }

  if (!msg.sharedDrive && matched === 0) {
    return { ok: false, error: 'Couldn’t find “' + segments[0] + '” in Drive for desktop on this Mac.' };
  }

  var exact = matched === segments.length;
  // Exact folder -> open it. Exact file -> reveal it. Partial -> open the deepest folder we found.
  var status = (exact && !msg.isFolder) ? openWith(['-R', cur]) : openWith([cur]);
  if (status !== 0) return { ok: false, error: 'Finder couldn’t open ' + cur };
  return { ok: true, exact: exact, path: cur };
}

function run() {
  var reply;
  try {
    reply = handle(readMessage());
  } catch (e) {
    reply = { ok: false, error: String(e && e.message || e) };
  }
  try { writeMessage(reply); } catch (e) { /* Chrome has gone away */ }
  $.exit(0);
}
JXA_EOF
chmod 755 "$HOST_DIR/drivefinder-host"
xattr -c "$HOST_DIR/drivefinder-host" 2>/dev/null || true

cat > "$CHROME_DIR/com.apparent.drivefinder.json" <<'JSON_EOF'
{
  "name": "com.apparent.drivefinder",
  "description": "Drive to Finder helper",
  "path": "/Library/Application Support/Apparent/DriveFinder/drivefinder-host",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://pikhmpompojbkhbckmgolnbmnakaakbe/"
  ]
}
JSON_EOF
chmod 644 "$CHROME_DIR/com.apparent.drivefinder.json"

echo "Drive to Finder helper installed."
exit 0
