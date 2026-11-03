// Fixture host (Chromium): shows one HTML file in an Electron window without
// taking focus, so `Unread --extract --pid` can read it like Chrome/Electron content.
//   (cd fixtures/hosts/electron && npm install)
//   fixtures/hosts/electron/node_modules/.bin/electron fixtures/hosts/electron fixtures/pages/inline.html
const { app, BrowserWindow } = require('electron');
const path = require('path');

const file = path.resolve(process.argv[process.argv.length - 1]);
app.dock?.hide();
app.whenReady().then(() => {
  const win = new BrowserWindow({ x: 60, y: 60, width: 900, height: 1000, show: false,
                                  title: `Unread fixture (Chromium): ${path.basename(file)}` });
  win.loadFile(file);
  win.once('ready-to-show', () => win.showInactive());
});
