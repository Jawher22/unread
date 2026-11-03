// Fixture host (Chromium): shows one HTML file in an Electron window without
// taking focus, so `Unread --extract --pid` can read it like Chrome/Electron content.
//   (cd fixtures/hosts/electron && npm install)
//   fixtures/hosts/electron/node_modules/.bin/electron fixtures/hosts/electron fixtures/pages/inline.html
const { app, BrowserWindow } = require('electron');
const path = require('path');

const target = process.argv[process.argv.length - 1];
const remote = /^https?:\/\//.test(target); // live pages, for investigating
const file = remote ? target : path.resolve(target);
app.dock?.hide();
app.whenReady().then(() => {
  const win = new BrowserWindow({ x: 60, y: 60, width: 900, height: 1000, show: false,
                                  title: `Unread fixture (Chromium): ${path.basename(file)}` });
  if (remote) win.loadURL(file); else win.loadFile(file);
  win.once('ready-to-show', () => win.showInactive());
});
