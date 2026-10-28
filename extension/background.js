// Drive to Finder — background service worker
// Flow: work out which Drive item the person means -> ask the Drive API for its
// folder chain -> hand the path pieces to the Mac helper, which opens Finder.

const HOST = 'com.apparent.drivefinder';
const API = 'https://www.googleapis.com/drive/v3';
const FOLDER = 'application/vnd.google-apps.folder';

// Google-native files show up in Drive for desktop as small link files with these extensions.
const GOOGLE_EXT = {
  'application/vnd.google-apps.document': '.gdoc',
  'application/vnd.google-apps.spreadsheet': '.gsheet',
  'application/vnd.google-apps.presentation': '.gslides',
  'application/vnd.google-apps.drawing': '.gdraw',
  'application/vnd.google-apps.form': '.gform',
  'application/vnd.google-apps.site': '.gsite',
  'application/vnd.google-apps.jam': '.gjam',
  'application/vnd.google-apps.map': '.gmap',
  'application/vnd.google-apps.script': '.gscript'
};

const MSG = {
  noTarget: 'Open a Drive folder, select a file, or open a Doc/Sheet/Slides file first.',
  notSynced: 'This item isn’t in your My Drive or a shared drive you’re a member of, so Drive for desktop doesn’t sync it to your Mac.',
  noAccess: 'Couldn’t read that item from Drive. Check you’re signed in to Chrome with your Apparent account.',
  noHelper: 'The Drive to Finder helper isn’t installed on this Mac yet. Grab it from Self Service, or ask IT.',
  signIn: 'Google sign-in was cancelled. Click the button again to allow access.'
};

// ---------- entry points ----------

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: 'dtf-link',
      title: 'Show in Finder',
      contexts: ['link'],
      targetUrlPatterns: ['https://drive.google.com/*', 'https://docs.google.com/*']
    });
    chrome.contextMenus.create({
      id: 'dtf-page',
      title: 'Show in Finder',
      contexts: ['page'],
      documentUrlPatterns: ['https://drive.google.com/*', 'https://docs.google.com/*']
    });
  });
});

chrome.action.onClicked.addListener((tab) => run(tab));

chrome.commands.onCommand.addListener(async (command, tab) => {
  if (command !== 'show-in-finder') return;
  if (!tab) [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (tab) run(tab);
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId === 'dtf-link') run(tab, info.linkUrl);
  else run(tab);
});

// ---------- main ----------

async function run(tab, explicitUrl) {
  const tabId = tab && tab.id;
  try {
    const target = explicitUrl ? parseDriveUrl(explicitUrl) : await targetFromTab(tab);
    if (!target) return notify(tabId, MSG.noTarget, 'error');

    notify(tabId, 'Finding it in Finder…', 'info');
    const resolved = await resolve(target.id);
    const reply = await askHelper({
      email: resolved.email,
      segments: resolved.segments,
      isFolder: resolved.isFolder
    });

    if (!reply || !reply.ok) {
      return notify(tabId, (reply && reply.error) || 'Something went wrong opening Finder.', 'error');
    }
    if (reply.exact) notify(tabId, 'Opened in Finder', 'done');
    else notify(tabId, 'Couldn’t find that exact item on this Mac yet (it may still be syncing), so I opened the closest folder.', 'warn');
  } catch (err) {
    console.error('[Drive to Finder]', err);
    notify(tabId, err && err.userMessage ? err.userMessage : 'Something went wrong. ' + (err && err.message ? err.message : ''), 'error');
  }
}

// ---------- working out the target ----------

function parseDriveUrl(raw) {
  let u;
  try { u = new URL(raw); } catch (e) { return null; }
  const p = u.pathname;

  if (u.hostname === 'drive.google.com') {
    let m = p.match(/\/folders\/([\w-]{10,})/);
    if (m) return { id: m[1] };
    m = p.match(/\/file\/(?:u\/\d+\/)?d\/([\w-]{10,})/);
    if (m) return { id: m[1] };
    if (/^\/drive(?:\/u\/\d+)?\/(?:my-drive|home)\/?$/.test(p) || /^\/drive(?:\/u\/\d+)?\/?$/.test(p)) return { id: 'root' };
    const q = u.searchParams.get('id');
    if (q && /^[\w-]{10,}$/.test(q)) return { id: q };
    return null;
  }

  if (u.hostname === 'docs.google.com') {
    const m = p.match(/^\/(?:document|spreadsheets|presentation|forms|drawings|file)(?:\/u\/\d+)?\/d\/([\w-]{20,})/);
    if (m && m[1] !== 'e') return { id: m[1] };
  }
  return null;
}

async function targetFromTab(tab) {
  if (!tab || !tab.url) return null;
  const fromUrl = parseDriveUrl(tab.url);
  const u = new URL(tab.url);

  // In the Drive file browser, a selected file wins over the folder you're in.
  if (u.hostname === 'drive.google.com' && !/\/file\//.test(u.pathname)) {
    const selected = await selectedIdsInDrive(tab.id);
    if (selected.length) return { id: selected[0] };
  }
  return fromUrl;
}

async function selectedIdsInDrive(tabId) {
  try {
    const [res] = await chrome.scripting.executeScript({
      target: { tabId },
      func: () => {
        // Drive marks selected rows/tiles with aria-selected and carries the file ID in data-id.
        const scope = document.querySelector('[role="main"]') || document;
        const ids = [];
        for (const el of scope.querySelectorAll('[aria-selected="true"]')) {
          const holder = el.closest('[data-id]') || el.querySelector('[data-id]');
          const id = holder && holder.getAttribute('data-id');
          if (id && /^[\w-]{15,}$/.test(id) && !ids.includes(id)) ids.push(id);
        }
        return ids;
      }
    });
    return (res && res.result) || [];
  } catch (e) {
    return [];
  }
}

// ---------- Drive API ----------

let ctxCache = null;

async function getToken(interactive) {
  try {
    const r = await chrome.identity.getAuthToken({ interactive });
    return typeof r === 'string' ? r : r && r.token;
  } catch (e) {
    const err = new Error(e.message);
    err.userMessage = MSG.signIn;
    throw err;
  }
}

async function api(path, params) {
  const url = new URL(API + path);
  Object.entries(params || {}).forEach(([k, v]) => url.searchParams.set(k, v));
  let token = await getToken(true);
  let res = await fetch(url, { headers: { Authorization: 'Bearer ' + token } });
  if (res.status === 401) {
    await chrome.identity.removeCachedAuthToken({ token });
    token = await getToken(true);
    res = await fetch(url, { headers: { Authorization: 'Bearer ' + token } });
  }
  if (!res.ok) {
    const err = new Error('Drive API ' + res.status + ' for ' + path);
    err.status = res.status;
    throw err;
  }
  return res.json();
}

async function context() {
  if (ctxCache) return ctxCache;
  const [about, root] = await Promise.all([
    api('/about', { fields: 'user(emailAddress)' }),
    api('/files/root', { fields: 'id' })
  ]);
  ctxCache = { email: about.user.emailAddress, rootId: root.id };
  return ctxCache;
}

function getFile(id) {
  return api('/files/' + encodeURIComponent(id), {
    fields: 'id,name,mimeType,parents,driveId',
    supportsAllDrives: 'true'
  });
}

function getDrive(id) {
  return api('/drives/' + encodeURIComponent(id), { fields: 'id,name' });
}

function localName(file) {
  return file.name + (GOOGLE_EXT[file.mimeType] || '');
}

function fail(message) {
  const err = new Error(message);
  err.userMessage = message;
  return err;
}

async function resolve(id) {
  const ctx = await context();
  const base = { email: ctx.email };

  if (id === 'root' || id === ctx.rootId) return { ...base, segments: ['My Drive'], isFolder: true };

  let file;
  try {
    file = await getFile(id);
  } catch (e) {
    // A shared drive's own ID isn't always readable as a file — try it as a drive.
    if (e.status === 404) {
      try {
        const d = await getDrive(id);
        return { ...base, segments: ['Shared drives', d.name], isFolder: true };
      } catch (_) { /* fall through */ }
    }
    throw fail(e.status === 404 || e.status === 403 ? MSG.noAccess : e.message);
  }

  if (file.driveId && file.id === file.driveId) {
    const d = await getDrive(file.driveId);
    return { ...base, segments: ['Shared drives', d.name], isFolder: true };
  }

  const segments = [localName(file)];
  let cur = file;
  for (let depth = 0; depth < 100; depth++) {
    const parent = cur.parents && cur.parents[0];
    if (!parent) throw fail(MSG.notSynced);
    if (parent === ctx.rootId) { segments.unshift('My Drive'); break; }
    if (cur.driveId && parent === cur.driveId) {
      const d = await getDrive(parent);
      segments.unshift('Shared drives', d.name);
      break;
    }
    try { cur = await getFile(parent); } catch (e) { throw fail(MSG.notSynced); }
    segments.unshift(cur.name);
  }

  return { ...base, segments, isFolder: file.mimeType === FOLDER };
}

// ---------- Mac helper ----------

async function askHelper(message) {
  try {
    return await chrome.runtime.sendNativeMessage(HOST, message);
  } catch (e) {
    const text = String(e && e.message || e);
    if (/not found|not installed|forbidden/i.test(text)) throw fail(MSG.noHelper);
    throw fail('The Finder helper didn’t respond: ' + text);
  }
}

// ---------- feedback ----------

async function notify(tabId, text, kind) {
  if (tabId == null) return;
  try {
    await chrome.scripting.executeScript({ target: { tabId }, func: showToast, args: [text, kind] });
  } catch (e) {
    // Pages we can't draw on (e.g. chrome:// pages): fall back to the toolbar badge.
    if (kind === 'error' || kind === 'warn') {
      chrome.action.setBadgeBackgroundColor({ color: '#C5221F', tabId });
      chrome.action.setBadgeText({ text: '!', tabId });
      chrome.action.setTitle({ title: text, tabId });
    }
  }
}

// Runs inside the page.
function showToast(text, kind) {
  const ID = 'drive-to-finder-toast';
  let el = document.getElementById(ID);
  if (!el) {
    el = document.createElement('div');
    el.id = ID;
    el.setAttribute('role', 'status');
    el.setAttribute('aria-live', 'polite');
    Object.assign(el.style, {
      position: 'fixed', left: '50%', bottom: '28px', transform: 'translateX(-50%)',
      zIndex: '2147483647', maxWidth: 'min(520px, calc(100vw - 32px))',
      padding: '12px 16px', borderRadius: '10px',
      font: '500 14px/1.4 -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif',
      color: '#fff', background: '#202124', boxShadow: '0 6px 24px rgba(0,0,0,.28)',
      transition: 'opacity .2s ease', opacity: '0'
    });
    document.documentElement.appendChild(el);
  }
  const accent = { error: '#F28B82', warn: '#FDD663', done: '#81C995', info: '#8AB4F8' }[kind] || '#8AB4F8';
  el.style.borderLeft = '4px solid ' + accent;
  el.textContent = text;
  requestAnimationFrame(() => { el.style.opacity = '1'; });
  clearTimeout(el._dtfTimer);
  const ms = kind === 'info' ? 8000 : kind === 'done' ? 1800 : 6500;
  el._dtfTimer = setTimeout(() => {
    el.style.opacity = '0';
    setTimeout(() => el.remove(), 250);
  }, ms);
}
