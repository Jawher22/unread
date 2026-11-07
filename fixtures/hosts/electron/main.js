// Fixture host (Chromium): shows one HTML file in an Electron window without
// taking focus, so `Unread --extract --pid` can read it like Chrome/Electron content.
//   (cd fixtures/hosts/electron && npm install)
//   fixtures/hosts/electron/node_modules/.bin/electron fixtures/hosts/electron [--hidden] [--profile dir] fixtures/pages/inline.html
// --hidden (extract-fixture.sh): fully transparent and click-through, so a test run
// never covers the user's work. It stays on screen, so Accessibility sees the same geometry,
// and on every Space: Accessibility lists only the current Space's windows.
const { app, BrowserWindow } = require('electron');
const path = require('path');

const target = process.argv[process.argv.length - 1];
const remote = /^https?:\/\//.test(target); // live pages, for investigating
const hidden = process.argv.includes('--hidden');
// --profile <dir> (extract-fixture.sh): hosts started together otherwise share one Chromium profile and its locks.
const profile = process.argv.indexOf('--profile');
if (profile > 0) app.setPath('userData', path.resolve(process.argv[profile + 1]));
const file = remote ? target : path.resolve(target);
// --browser: Chromium's basic accessibility only, as Chrome, Arc and Aside give without VoiceOver: element
// frames but no inline text boxes, so text ranges have no bounds (WebDocument.probeTextGeometry).
if (process.argv.includes('--browser')) app.commandLine.appendSwitch('force-renderer-accessibility', 'basic');
// --scroll-after S: scroll the page down by half a window S seconds after it loads, as a reader would.
const scrollAfter = process.argv.indexOf('--scroll-after');
app.dock?.hide();
app.whenReady().then(() => {
  const win = new BrowserWindow({ x: 60, y: 60, width: 900, height: 1000, show: false, opacity: hidden ? 0 : 1,
                                  title: `Unread fixture (Chromium): ${path.basename(file)}` });
  if (hidden) {
    win.setIgnoreMouseEvents(true);
    win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  }
  if (remote) win.loadURL(file); else win.loadFile(file);
  // extract-fixture.sh waits for "loaded" before reading the page.
  win.once('ready-to-show', () => {
    win.showInactive();
    // Hidden, the host must never take the keyboard (#66): its window is on every Space, so macOS can make it active.
    if (hidden) app.setActivationPolicy('prohibited');
    console.log('loaded');
    if (scrollAfter > 0) setTimeout(() => {
      win.webContents.executeJavaScript('window.scrollBy(0, innerHeight / 2); scrollY').then(y => console.log(`scrolled ${y}`));
    }, 1000 * Number(process.argv[scrollAfter + 1]));
  });
});
