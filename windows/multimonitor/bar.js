import { createProviderGroup } from './vendor/zebar.js';

const providers = createProviderGroup({
  glazewm: { type: 'glazewm' },
  network: { type: 'network', refreshInterval: 30000 },
  cpu: { type: 'cpu', refreshInterval: 10000 },
  memory: { type: 'memory', refreshInterval: 10000 },
  date: { type: 'date', formatting: 'EEE d MMM t' },
  battery: { type: 'battery', refreshInterval: 30000 },
  weather: { type: 'weather' },
});

function element(tag, className, text) {
  const node = document.createElement(tag);
  node.className = className;
  if (text != null) node.textContent = text;
  return node;
}
function icon(name, className = '') {
  const node = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  node.setAttribute('class', `icon ${className}`.trim());
  node.setAttribute('viewBox', '0 0 24 24');
  node.setAttribute('aria-hidden', 'true');
  node.setAttribute('focusable', 'false');
  const use = document.createElementNS(node.namespaceURI, 'use');
  use.setAttribute('href', `./resources/icons.svg#${name}`);
  node.append(use);
  return node;
}
function button(className, content, command, title) {
  const node = element('button', className);
  node.append(content);
  node.addEventListener('click', () => providers.outputMap.glazewm?.runCommand(command).catch(console.error));
  if (title) { node.title = title; node.setAttribute('aria-label', title); }
  return node;
}
const app = element('div', 'app');
const left = element('div', 'left');
const center = element('div', 'center');
const right = element('div', 'right');
const workspaces = element('div', 'workspaces');
const controls = element('div', 'controls');
controls.style.display = 'contents';
left.append(icon('layout-grid', 'logo'), workspaces);
right.append(controls);
const fields = {};
for (const name of ['network', 'memory', 'cpu', 'battery', 'weather']) {
  fields[name] = element('div', name);
  fields[name].hidden = true;
  right.append(fields[name]);
}
app.append(left, center, right);
document.getElementById('root').replaceChildren(app);

// Only update changed providers, preserving buttons and keyboard focus on metric ticks.
let workspaceKey = '';
let controlKey = '';
const previous = {};
function metric(name, data, glyph, text, className = '') {
  const key = JSON.stringify([data != null, glyph, text, className]);
  if (previous[name] === key) return;
  previous[name] = key;
  fields[name].style.display = data == null ? 'none' : 'flex';
  fields[name].hidden = data == null;
  fields[name].replaceChildren(icon(glyph), element('span', className, text));
}
const weatherIcons = {
  clear_day: 'sun', clear_night: 'moon', cloudy_day: 'cloud-sun', cloudy_night: 'cloud-moon',
  light_rain_day: 'cloud-drizzle', light_rain_night: 'cloud-drizzle',
  heavy_rain_day: 'cloud-rain', heavy_rain_night: 'cloud-rain',
  snow_day: 'cloud-snow', snow_night: 'cloud-snow', thunder_day: 'cloud-lightning', thunder_night: 'cloud-lightning',
};
function render() {
  const output = providers.outputMap;
  const wm = output.glazewm;
  const nextWorkspaces = JSON.stringify(wm?.currentWorkspaces);
  if (workspaceKey !== nextWorkspaces) {
    workspaceKey = nextWorkspaces;
    workspaces.replaceChildren(...(wm?.currentWorkspaces ?? []).map(workspace => button(
      `workspace${workspace.hasFocus ? ' focused' : ''}${workspace.isDisplayed ? ' displayed' : ''}`,
      String(workspace.displayName ?? workspace.name), `focus --workspace ${workspace.name}`,
    )));
  }
  const nextControls = JSON.stringify(wm && [wm.isPaused, wm.bindingModes, wm.tilingDirection]);
  if (controlKey !== nextControls) {
    controlKey = nextControls;
    const nodes = [];
    if (wm) {
      if (wm.isPaused) nodes.push(button('paused-button', 'PAUSED', 'wm-toggle-pause'));
      for (const mode of wm.bindingModes) nodes.push(button('binding-mode', String(mode.displayName ?? mode.name), `wm-disable-binding-mode --name ${mode.name}`));
      nodes.push(button('tiling-direction', icon(wm.tilingDirection === 'horizontal' ? 'columns-2' : 'rows-2'), 'toggle-tiling-direction', 'Toggle tiling direction'));
    }
    controls.replaceChildren(...nodes);
  }
  const date = output.date?.formatted ?? '';
  if (center.textContent !== date) center.textContent = date;
  const network = output.network;
  const strength = network?.defaultGateway?.signalStrength ?? 0;
  const networkIcon = { ethernet: 'ethernet-port', proprietary_virtual: 'shield-check',
    wifi: strength >= 80 ? 'wifi' : strength >= 65 ? 'wifi-high' : strength >= 40 ? 'wifi-low' : 'wifi-zero' }[network?.defaultInterface?.type] ?? 'wifi-off';
  metric('network', network, networkIcon, network?.defaultGateway?.ssid ?? '');
  metric('memory', output.memory, 'memory-stick', `${Math.round(output.memory?.usage ?? 0)}%`);
  metric('cpu', output.cpu, 'cpu', `${Math.round(output.cpu?.usage ?? 0)}%`, output.cpu?.usage > 85 ? 'high-usage' : '');
  const battery = output.battery;
  const charge = Math.max(0, Math.min(100, battery?.chargePercent ?? 0));
  metric('battery', battery, battery?.isCharging ? 'battery-charging' : 'battery', `${Math.round(charge)}%`, charge <= 20 ? 'low-battery' : '');
  if (battery && !battery.isCharging) {
    const svg = fields.battery.firstChild;
    let fill = svg.querySelector('rect');
    if (!fill) { fill = document.createElementNS(svg.namespaceURI, 'rect'); svg.append(fill); }
    for (const [key, value] of Object.entries({ x: 5, y: 9, width: charge / 10, height: 6, rx: 0.75, fill: 'currentColor', stroke: 'none' })) fill.setAttribute(key, value);
  }
  metric('weather', output.weather, weatherIcons[output.weather?.status] ?? 'cloud', `${Math.round(output.weather?.celsiusTemp ?? 0)}°C`);
}
render();
providers.onOutput(render);

window.addEventListener('beforeunload', () => { void providers.stopAll(); }, { once: true });
