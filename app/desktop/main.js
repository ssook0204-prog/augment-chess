// 증강 체스 데스크톱 앱: 항상 최신 사이트를 열고, 인터넷이 없으면 앱에 들어 있는 오프라인 판을 열어요.
const { app, BrowserWindow, shell, Menu, session } = require('electron');
const path = require('path');

const SITE = process.env.AC_SITE || 'https://ssook0204-prog.github.io/augment-chess/';
const SITE_ORIGIN = 'https://ssook0204-prog.github.io';
// 로그인(디스코드·이메일)은 앱 창 안에서 그대로 진행해요.
const IN_APP = [/^https:\/\/ssook0204-prog\.github\.io\/augment-chess(\/|$)/, /^https:\/\/[a-z0-9-]+\.supabase\.co\//, /^https:\/\/(www\.|canary\.|ptb\.)?discord(app)?\.com\//];
const inApp = u => IN_APP.some(r => r.test(u));

let win = null;

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => { if (win) { if (win.isMinimized()) win.restore(); win.focus(); } });
  app.whenReady().then(async () => {
    // 사이트의 오프라인용 서비스 워커는 앱에서 쓰지 않아요(앱에 오프라인 판이 따로 있어요).
    // 예전에 등록된 것도 지우고, 새로 등록되지 않게 sw.js 요청을 막아요.
    try { await session.defaultSession.clearStorageData({ storages: ['serviceworkers', 'cachestorage'] }); } catch (e) { }
    session.defaultSession.webRequest.onBeforeRequest({ urls: ['*://*/*/sw.js*', '*://*/sw.js*'] }, (d, cb) => cb({ cancel: true }));
    create();
  });
  app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
  app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) create(); });
}

function create() {
  if (process.platform !== 'darwin') Menu.setApplicationMenu(null);
  win = new BrowserWindow({
    width: 1280, height: 860, minWidth: 360, minHeight: 560,
    title: '증강 체스', backgroundColor: '#f4f1ea',
    icon: path.join(__dirname, 'icon.png'),
    autoHideMenuBar: true,
    webPreferences: { contextIsolation: true, nodeIntegration: false, sandbox: true, spellcheck: false }
  });
  const ua = win.webContents.getUserAgent() + ' AugmentChessApp/desktop';
  win.webContents.setUserAgent(ua);

  // 새 창(target=_blank)은 기본 브라우저로, 로그인 창은 앱 안에서
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (inApp(url)) { win.loadURL(url); return { action: 'deny' }; }
    if (/^https?:/.test(url)) shell.openExternal(url);
    return { action: 'deny' };
  });
  win.webContents.on('will-navigate', (e, url) => {
    if (url.startsWith('file:') || inApp(url)) return;
    e.preventDefault();
    if (/^https?:/.test(url)) shell.openExternal(url);
  });

  let offline = false;
  win.webContents.on('did-fail-load', (e, code, desc, url, isMain) => {
    if (!isMain || offline || code === -3) return; // -3 = 사용자가 취소
    if (String(url).startsWith(SITE_ORIGIN)) {
      offline = true;
      win.loadFile(path.join(__dirname, 'offline', 'index.html'));
    }
  });
  // 그래도 "오프라인이에요" 글자만 보이면 앱에 든 오프라인 판을 열어요.
  win.webContents.on('did-finish-load', async () => {
    if (offline) return;
    try {
      const t = await win.webContents.executeJavaScript("document.title + '|' + (document.body ? document.body.innerText.slice(0, 40) : '')");
      if (/^\|?오프라인이에요/.test(t) || t.startsWith('|오프라인')) { offline = true; win.loadFile(path.join(__dirname, 'offline', 'index.html')); }
    } catch (e) { }
  });
  win.loadURL(SITE);
}
