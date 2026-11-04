import { createProviderGroup, currentWidget, shellSpawn } from './vendor/zebar.js';

const providers = createProviderGroup({
  glazewm: { type: 'glazewm' },
  date: { type: 'date', formatting: 'HH:mm · ccc dd LLL', refreshInterval: 1000 },
  battery: { type: 'battery', refreshInterval: 10000 },
});

function element(tag, className, text) {
  const node = document.createElement(tag);
  node.className = className;
  if (text != null) node.textContent = text;
  return node;
}
function button(className, content, command, title) {
  const node = element('button', className);
  node.append(content);
  node.addEventListener('click', () => providers.outputMap.glazewm?.runCommand(command).catch(console.error));
  if (title) { node.title = title; node.setAttribute('aria-label', title); }
  return node;
}
// The overlay never intercepts clicks, including while its panel is hidden.
void currentWidget().window.tauri.setIgnoreCursorEvents(true).catch(console.error);
const app = element('div', 'app');
const workspaces = element('nav', 'workspaces');
workspaces.setAttribute('aria-label', 'Workspaces');
const clock = element('time', 'dock-panel clock');
clock.setAttribute('aria-label', 'Local time and date');
const battery = element('div', 'dock-panel battery-status');
battery.hidden = true;
const svgNamespace = 'http://www.w3.org/2000/svg';
const batteryIcon = document.createElementNS(svgNamespace, 'svg');
batteryIcon.setAttribute('class', 'icon');
batteryIcon.setAttribute('viewBox', '0 0 24 24');
batteryIcon.setAttribute('aria-hidden', 'true');
const batterySymbol = document.createElementNS(svgNamespace, 'use');
const batteryFill = document.createElementNS(svgNamespace, 'rect');
for (const [name, value] of Object.entries({ x: 5, y: 9, height: 6, rx: 0.75, fill: 'currentColor', stroke: 'none' })) {
  batteryFill.setAttribute(name, String(value));
}
batteryIcon.append(batterySymbol, batteryFill);
const batteryLabel = element('span', 'battery-label');
battery.append(batteryIcon, batteryLabel);
app.append(battery, workspaces, clock);
document.getElementById('root').replaceChildren(app);
const layoutObserver = new ResizeObserver(() => {
  const midpoint = workspaces.children.length
    ? workspaces.offsetLeft + workspaces.offsetWidth / 2 : app.offsetWidth / 2;
  app.style.setProperty('--workspace-offset', `${midpoint}px`);
});
layoutObserver.observe(app);
layoutObserver.observe(workspaces);

// Preserve buttons and keyboard focus when workspace data has not changed.
// Force a native z-order change: reapplying an already cached topmost value
// can be a no-op even when another window has displaced this overlay.
let raising = false;
let raisePending = false;
async function raiseOverlay() {
  if (unloading) return;
  raisePending = true;
  if (raising) return;
  raising = true;
  try {
    while (raisePending && !unloading) {
      raisePending = false;
      try {
        await currentWidget().window.setZOrder('normal');
      } catch (error) { console.error(error); }
      // Complete restoration even if unloading started during the first call.
      try {
        await currentWidget().window.setZOrder('top_most');
      } catch (error) { console.error(error); }
    }
  } finally { raising = false; }
}
let focusedContainer;
let workspaceKey = '';
let displayedWorkspace;
let hideTimer;
let altHeld = false;
let latestBattery;
let batteryRequestPending = false;
function setVisible(visible) {
  if (visible) void raiseOverlay();
  if (visible && !app.classList.contains('visible')) {
    batteryRequestPending = !latestBattery;
    if (latestBattery) renderBattery(latestBattery);
  }
  if (!visible) batteryRequestPending = false;
  app.classList.toggle('visible', visible);
  app.setAttribute('aria-hidden', String(!visible));
}
function showBriefly() {
  clearTimeout(hideTimer);
  setVisible(true);
  hideTimer = setTimeout(() => { if (!altHeld) setVisible(false); }, 1200);
}
app.setAttribute('aria-hidden', 'true');

let altWatcher;
let unloading = false;
let retryTimer;
let retryDelay = 1000;
function scheduleWatcher() {
  if (unloading) return;
  retryTimer = setTimeout(startWatcher, retryDelay);
  retryDelay = Math.min(retryDelay * 2, 30000);
}
function startWatcher() {
void shellSpawn('powershell.exe', [
  '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', 'Watch-Alt.ps1',
], { cwd: currentWidget().htmlPath.replace(/[\\/][^\\/]+$/, '') }).then(process => {
  if (unloading) { process.kill(); return; }
  altWatcher = process;
  process.onStdout(line => {
    const state = line.trim();
    if (state === 'down' || state === 'up') retryDelay = 1000;
    if (state === 'down' && !altHeld) {
      altHeld = true;
      clearTimeout(hideTimer);
      setVisible(true);
    } else if (state === 'up' && altHeld) {
      altHeld = false;
      showBriefly();
    }
  });
  process.onStderr(console.error);
  process.onExit(() => {
    if (altHeld && !unloading) { altHeld = false; showBriefly(); }
    scheduleWatcher();
  });
}).catch(error => { console.error(error); scheduleWatcher(); });
}
startWatcher();

// Keep the native subscription stable across simultaneous reveals on all monitors.
// Cache readings silently; only opening the overlay changes the battery display.
providers.raw.battery.onOutput(power => {
  if (!Number.isFinite(power?.chargePercent)) return;
  latestBattery = { ...power };
  if (batteryRequestPending && app.classList.contains('visible')) {
    batteryRequestPending = false;
    renderBattery(latestBattery);
  }
});
// Retain the last valid reading across transient provider errors.
function renderBattery(power) {
  battery.hidden = !Number.isFinite(power?.chargePercent);
  if (!battery.hidden) {
    const percent = Math.round(Math.max(0, Math.min(100, power.chargePercent)));
    const state = power.isCharging ? 'Charging' : power.state === 'full' ? 'Full' : 'Battery';
    batteryLabel.textContent = `${percent}%`;
    battery.setAttribute('aria-label', `${state}: ${percent}%`);
    battery.title = `${state}: ${percent}%`;
    batterySymbol.setAttribute('href', `./resources/icons.svg#${power.isCharging ? 'battery-charging' : 'battery'}`);
    batteryFill.setAttribute('width', String(power.isCharging ? 0 : 10 * percent / 100));
    battery.classList.toggle('low', percent <= 20 && !power.isCharging);
    battery.classList.toggle('charging', power.isCharging);
  }
}

function render() {
  const output = providers.outputMap;
  const formatted = output.date?.formatted ?? '--:--';
  if (clock.dataset.formatted !== formatted) {
    clock.dataset.formatted = formatted;
    const [time, ...date] = formatted.split(' · ');
    clock.replaceChildren(element('span', 'clock-time', time + (date.length ? '\u00a0' : '')));
    if (date.length) clock.append(element('span', 'clock-date', ` · ${date.join(' · ')}`));
  }
  if (output.date?.iso) clock.setAttribute('datetime', output.date.iso);
  const wm = output.glazewm;
  const focused = wm?.focusedContainer?.id;
  if (focused !== focusedContainer) {
    focusedContainer = focused;
    if (app.classList.contains('visible')) void raiseOverlay();
  }
  const displayed = wm?.currentWorkspaces?.find(workspace => workspace.isDisplayed)?.name;
  if (displayed != null) {
    if (displayedWorkspace != null && displayedWorkspace !== displayed) showBriefly();
    displayedWorkspace = displayed;
  }
  const visibleWorkspaces = (wm?.currentWorkspaces ?? []).map(({ name, displayName, hasFocus, isDisplayed }) => ({ name, displayName, hasFocus, isDisplayed }));
  const nextWorkspaces = JSON.stringify(visibleWorkspaces);
  if (workspaceKey !== nextWorkspaces) {
    workspaceKey = nextWorkspaces;
    workspaces.replaceChildren(...visibleWorkspaces.map(workspace => button(
      `workspace${workspace.hasFocus ? ' focused' : ''}${workspace.isDisplayed ? ' displayed' : ''}`,
      String(workspace.name), `focus --workspace ${workspace.name}`,
      `Workspace ${workspace.displayName ?? workspace.name}`,
    )));
  }

}
render();
providers.onOutput(render);
providers.onError(render);

window.addEventListener('beforeunload', () => { unloading = true; raisePending = false; clearTimeout(retryTimer); clearTimeout(hideTimer); altWatcher?.kill(); layoutObserver.disconnect(); void providers.stopAll(); }, { once: true });
