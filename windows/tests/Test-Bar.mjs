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
const group = {
  outputMap: {}, onOutput: callback => { update = callback; },
  stopAll: async () => { stopped = true; },
};
const context = vm.createContext({ document, window, console,
  providerFactory: value => { config = value; return group; },
});
const bar = readFileSync(new URL('../multimonitor/bar.js', import.meta.url), 'utf8');
assert.match(bar, /^import \{ createProviderGroup \} from '\.\/vendor\/zebar\.js';/);
vm.runInContext(bar.replace(/^import[^\n]+/, 'const createProviderGroup = providerFactory;'), context);
assert.equal(config.cpu.refreshInterval, 10000);
assert.equal(config.network.refreshInterval, 30000);
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
assert.equal(document.querySelector('.center').textContent, 'Thu 29 Oct 10:00');
assert.equal(document.querySelector('.network').textContent, '<network>');
assert.equal(document.querySelector('.network network'), null, 'Untrusted labels became HTML');
assert.equal(document.querySelector('.cpu .high-usage').textContent, '90%');
assert.equal(document.querySelector('.battery rect').getAttribute('width'), '1.9');
const workspaceButton = document.querySelectorAll('.workspace')[1];
workspaceButton.click();
assert.equal(commands.pop(), 'focus --workspace 2');
group.outputMap.cpu = { usage: 12 };
update();
assert.equal(document.querySelectorAll('.workspace')[1], workspaceButton, 'Metric refresh replaced focused controls');
group.outputMap.glazewm.isPaused = true;
group.outputMap.glazewm.bindingModes = [{ name: 'resize', displayName: 'Resize' }];
update();
document.querySelector('.paused-button').click();
assert.equal(commands.pop(), 'wm-toggle-pause');
document.querySelector('.binding-mode').click();
assert.equal(commands.pop(), 'wm-disable-binding-mode --name resize');
document.querySelector('.tiling-direction').click();
assert.equal(commands.pop(), 'toggle-tiling-direction');
window.dispatchEvent(new window.Event('beforeunload'));
assert.equal(stopped, true);
const html = readFileSync(new URL('../multimonitor/with-glazewm.html', import.meta.url), 'utf8');
assert.doesNotMatch(html, /https?:|babel|react/i);
const bundle = readFileSync(new URL('../multimonitor/vendor/zebar.js', import.meta.url), 'utf8');
assert.doesNotMatch(bundle, /(?:from\s*|import\s*\()\s*["']https?:/);
console.log('PASS: offline bar assets, status rendering, safe labels, workspace controls, stable button identity, and provider shutdown.');
