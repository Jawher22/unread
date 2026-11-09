// Fixture host (Chromium): shows one HTML file in an Electron window without
// taking focus, so `Unread --extract --pid` can read it like Chrome/Electron content.
//   (cd fixtures/hosts/electron && npm install)
//   fixtures/hosts/electron/node_modules/.bin/electron fixtures/hosts/electron [--hidden] [--profile dir] fixtures/pages/inline.html
// --hidden (extract-fixture.sh): fully transparent and click-through, so a test run
// never covers the user's work. It stays on screen, so Accessibility sees the same geometry,
// and on every Space: Accessibility lists only the current Space's windows.
const { app, BaseWindow, BrowserWindow, WebContentsView } = require('electron');
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
// --scroll-after S [--scroll-by PX]: scroll the page down by PX (half a window) S seconds after it loads, as a reader would.
const scrollAfter = process.argv.indexOf('--scroll-after');
const scrollBy = process.argv.indexOf('--scroll-by');
// --tabs PAGE: two tabs in one window, the page and PAGE, each its own WebContentsView, the page shown. A line "tab 1"
// or "tab 2" on stdin shows that tab and takes the other's view out of the window, as a browser's tab strip detaches a
// background tab's view (scripts/window-check.sh --tabs). Prints the line back once done.
const tabs = process.argv.indexOf('--tabs');
app.dock?.hide();
app.whenReady().then(() => {
  const options = { x: 60, y: 60, width: 900, height: 1000, show: false, opacity: hidden ? 0 : 1,
                    title: `Unread fixture (Chromium): ${path.basename(file)}` };
  let win, contents;
  if (tabs > 0) {
    win = new BaseWindow(options);
    const views = [new WebContentsView(), new WebContentsView()];
    const fit = () => { const b = win.getContentBounds(); views.forEach(v => v.setBounds({ x: 0, y: 0, width: b.width, height: b.height })); };
    fit(); win.on('resize', fit);
    views[1].webContents.loadFile(path.resolve(process.argv[tabs + 1]));
    win.contentView.addChildView(views[0]);
    contents = views[0].webContents;
    require('readline').createInterface({ input: process.stdin }).on('line', line => {
      const n = { 'tab 1': 0, 'tab 2': 1 }[line.trim()];
      if (n === undefined) return;
      win.contentView.addChildView(views[n]);
      win.contentView.removeChildView(views[1 - n]);
      console.log(`tab ${n + 1}`);
    });
  } else {
    win = new BrowserWindow(options);
    contents = win.webContents;
  }
  if (hidden) {
    win.setIgnoreMouseEvents(true);
    win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  }
  if (remote) contents.loadURL(file); else contents.loadFile(file);
  // extract-fixture.sh waits for "loaded" before reading the page.
  (tabs > 0 ? contents : win).once(tabs > 0 ? 'did-finish-load' : 'ready-to-show', () => {
    win.showInactive();
    // Hidden, the host must never take the keyboard (#66): its window is on every Space, so macOS can make it active.
    if (hidden) app.setActivationPolicy('prohibited');
    console.log('loaded');
    if (scrollAfter > 0) setTimeout(() => {
      contents.executeJavaScript(`window.scrollBy(0, ${scrollBy > 0 ? Number(process.argv[scrollBy + 1]) : 'innerHeight / 2'}); scrollY`).then(y => console.log(`scrolled ${y}`));
    }, 1000 * Number(process.argv[scrollAfter + 1]));
  });
});
