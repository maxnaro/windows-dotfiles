import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import vm from 'node:vm';

// Optional path allows tests with dependencies installed outside the working tree.
const require = createRequire(process.argv[2] ?? new URL('../multimonitor/vendor/package.json', import.meta.url));
const { parseHTML } = require('linkedom');
const { window, document } = parseHTML('<html><body><div id="root"></div></body></html>');
const commands = [];
let update;
let config;
let stopped = false;
let batteryOutput;
let providerError;
const group = {
  raw: { battery: {
    onOutput: callback => { batteryOutput = callback; },
  } },
  outputMap: {}, onOutput: callback => { update = callback; },
  onError: callback => { providerError = callback; }, stopAll: async () => { stopped = true; },
};
const timers = new Map();
let timerId = 0;
let clickThrough = false;
let altOutput;
let altExit;
let killed = false;
const context = vm.createContext({ document, window, console, ResizeObserver: class { observe() {} disconnect() {} },
  spawnFactory: async () => ({ onStderr: () => {}, onStdout: callback => { altOutput = callback; }, onExit: callback => { altExit = callback; }, kill: () => { killed = true; } }),
  setTimeout: callback => { timers.set(++timerId, callback); return timerId; },
  clearTimeout: id => timers.delete(id),
  widgetFactory: () => ({ htmlPath: 'C:\\test\\zpack.json', window: { tauri: { setIgnoreCursorEvents: async value => { clickThrough = value; } } } }),
  providerFactory: value => { config = value; return group; },
});
const bar = readFileSync(new URL('../multimonitor/bar.js', import.meta.url), 'utf8');
assert.match(bar, /^import \{ createProviderGroup, currentWidget, shellSpawn \} from '\.\/vendor\/zebar\.js';/);
vm.runInContext(bar.replace(/^import[^\n]+/, 'const createProviderGroup = providerFactory; const currentWidget = widgetFactory; const shellSpawn = spawnFactory;'), context);
await new Promise(resolve => setImmediate(resolve));
assert.deepEqual(Object.keys(config), ['glazewm', 'date', 'battery']);
group.outputMap = {
  glazewm: { currentWorkspaces: [{ name: '1', hasFocus: true, isDisplayed: true }, { name: '2' }],
    bindingModes: [], isPaused: false, tilingDirection: 'horizontal',
    runCommand: async command => { commands.push(command); } },
  cpu: { usage: 90 }, memory: { usage: 45 }, date: { formatted: 'Thu 29 Oct 10:00' },
  battery: { chargePercent: 19, isCharging: false },
  network: { defaultInterface: { type: 'wifi' }, defaultGateway: { ssid: '<network>', signalStrength: 90 } },
  weather: { status: 'clear_day', celsiusTemp: 12.4 },
};
update();
assert.equal(document.querySelectorAll('.workspace').length, 2);
assert.equal(document.querySelector('.workspace.focused.displayed').textContent, '1');
assert.equal(document.querySelector('.right'), null);
const workspaceButton = document.querySelectorAll('.workspace')[1];
workspaceButton.click();
assert.equal(commands.pop(), 'focus --workspace 2');
group.outputMap.cpu = { usage: 12 };
update();
assert.equal(document.querySelectorAll('.workspace')[1], workspaceButton, 'Metric refresh replaced focused controls');
group.outputMap.glazewm.currentWorkspaces[1].children = [{ title: 'Changed window' }];
update();
assert.equal(document.querySelectorAll('.workspace')[1], workspaceButton, 'Window metadata must not rebuild workspace controls');
const stableClock = document.querySelector('.clock').firstChild;
update();
assert.equal(document.querySelector('.clock').firstChild, stableClock);
assert.equal(document.querySelector('.clock').textContent, 'Thu 29 Oct 10:00');
const batteryPanel = document.querySelector('.battery-status');
assert.equal(batteryPanel.hidden, true, 'Battery stays untouched until open');
group.outputMap.glazewm.currentWorkspaces[1].isDisplayed = true;
group.outputMap.glazewm.currentWorkspaces[0].isDisplayed = false;
update();
assert.equal(batteryPanel.hidden, true, 'First open waits for initial battery sample');
batteryOutput(group.outputMap.battery);
assert.equal(batteryPanel.textContent, '19%');
assert.equal(batteryPanel.classList.contains('low'), true);
assert.equal(batteryPanel.querySelector('use').getAttribute('href'), './resources/icons.svg#battery');
assert.equal(batteryPanel.querySelector('rect').getAttribute('width'), '1.9');
assert.equal(config.date.formatting, 'HH:mm · ccc dd LLL');
assert.deepEqual([...appChildren()], ['battery-status', 'workspaces', 'clock']);
function appChildren() {
  return [...document.querySelector('.app').children].map(node => node.classList.contains('battery-status') ? 'battery-status' : node.classList.contains('workspaces') ? 'workspaces' : 'clock');
}
group.outputMap.battery = { chargePercent: 52, isCharging: true };
batteryOutput(group.outputMap.battery);
update();
assert.equal(batteryPanel.textContent, '19%', 'Clock/provider refresh must not redraw battery');
assert.equal(batteryPanel.querySelector('use').getAttribute('href'), './resources/icons.svg#battery', 'Charging icon must remain fixed during the popup');

{ const callback = timers.get(timerId); timers.delete(timerId); callback(); }
group.outputMap.glazewm.currentWorkspaces.forEach(w => { w.isDisplayed = !w.isDisplayed; });
update();

assert.equal(batteryPanel.textContent, '52%');
assert.equal(batteryPanel.classList.contains('low'), false);
assert.equal(batteryPanel.querySelector('use').getAttribute('href'), './resources/icons.svg#battery-charging');
group.outputMap.battery = null;
batteryOutput(null);
providerError();

{ const callback = timers.get(timerId); timers.delete(timerId); callback(); }
group.outputMap.glazewm.currentWorkspaces.forEach(w => { w.isDisplayed = !w.isDisplayed; });
update();
assert.equal(batteryPanel.hidden, false, 'Transient failure must retain last valid battery reading');
assert.equal(batteryPanel.textContent, '52%');

{ const callback = timers.get(timerId); timers.delete(timerId); callback(); }
assert.equal(clickThrough, true);
const app = document.querySelector('.app');
assert.equal(app.classList.contains('visible'), false, 'Initial output should stay hidden');
group.outputMap.glazewm.currentWorkspaces = [{ name: '1', isDisplayed: true }, { name: '2', hasFocus: true }];
update();
assert.equal(app.classList.contains('visible'), true);
assert.equal(app.classList.contains('show-details'), false);
const firstTimer = timerId;
group.outputMap.glazewm.currentWorkspaces[1].hasFocus = false;
update();
assert.equal(timerId, firstTimer, 'Window focus must not extend popup');
group.outputMap.glazewm.currentWorkspaces = [{ name: '1' }, { name: '2', isDisplayed: true }];
update();
assert.equal(timers.has(firstTimer), false, 'Rapid switches cancel previous timeout');
{ const callback = timers.get(timerId); timers.delete(timerId); callback(); }
assert.equal(app.classList.contains('visible'), false);
assert.equal(app.getAttribute('aria-hidden'), 'true');
altOutput('down');
assert.equal(app.classList.contains('visible'), true);
update();
assert.equal(app.classList.contains('visible'), true);
altOutput('up');
assert.equal(app.classList.contains('visible'), true);
{ const callback = timers.get(timerId); timers.delete(timerId); callback(); }
assert.equal(app.classList.contains('visible'), false);
window.dispatchEvent(new window.Event('beforeunload'));
assert.equal(killed, true);
assert.equal(stopped, true);
assert.equal(timers.size, 0);
const html = readFileSync(new URL('../multimonitor/with-glazewm.html', import.meta.url), 'utf8');
assert.doesNotMatch(html, /https?:|babel|react/i);
const bundle = readFileSync(new URL('../multimonitor/vendor/zebar.js', import.meta.url), 'utf8');
assert.doesNotMatch(bundle, /(?:from\s*|import\s*\()\s*["']https?:/);
const pack = JSON.parse(readFileSync(new URL('../multimonitor/zpack.json', import.meta.url), 'utf8'));
const preset = pack.widgets.find(widget => widget.name === 'with-glazewm').presets[0];
assert.equal(pack.widgets.find(widget => widget.name === 'with-glazewm').zOrder, 'top_most');
assert.equal(preset.width, '100%');
assert.equal(preset.height, '48px');
assert.equal(preset.dockToEdge.edge, null);
assert.equal(preset.dockToEdge.enabled, false);
console.log('PASS: offline bar assets, status rendering, safe labels, workspace controls, stable button identity, and provider shutdown.');
