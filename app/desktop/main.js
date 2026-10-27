// 증강 체스 데스크톱 앱: 항상 최신 사이트를 열고, 인터넷이 없으면 앱에 들어 있는 오프라인 판을 열어요.
const { app, BrowserWindow, shell, Menu } = require('electron');
const path = require('path');

const SITE = 'https://ssook0204-prog.github.io/augment-chess/';
const SITE_ORIGIN = 'https://ssook0204-prog.github.io';
// 로그인(디스코드·이메일)은 앱 창 안에서 그대로 진행해요.
const IN_APP = [/^https:\/\/ssook0204-prog\.github\.io\/augment-chess(\/|$)/, /^https:\/\/[a-z0-9-]+\.supabase\.co\//, /^https:\/\/(www\.|canary\.|ptb\.)?discord(app)?\.com\//];
const inApp = u => IN_APP.some(r => r.test(u));

let win = null;

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => { if (win) { if (win.isMinimized()) win.restore(); win.focus(); } });
  app.whenReady().then(create);
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
  win.loadURL(SITE);
}
