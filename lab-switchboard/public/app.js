/* global lucide */
const state = { config: null, vms: [], filter: 'all', selected: null, busy: new Map(), syncing: false };
const element = id => document.getElementById(id);
const icons = () => lucide.createIcons();
let csrf = '';
let toastTimer;

function node(tag, className, text) {
  const result = document.createElement(tag);
  if (className) result.className = className;
  if (text !== undefined) result.textContent = text;
  return result;
}
function icon(name) { const result = node('i'); result.dataset.lucide = name; return result; }
function notify(message) {
  clearTimeout(toastTimer);
  element('toast').textContent = message;
  element('toast').hidden = false;
  toastTimer = setTimeout(() => { element('toast').hidden = true; }, 6000);
}
async function api(route, options = {}) {
  const response = await fetch(route, { ...options, headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrf, ...options.headers } });
  const body = await response.json();
  if (!response.ok) {
    if (response.status === 401) showLogin();
    throw new Error(body.error || 'Request failed.');
  }
  return body;
}
function showLogin() {
  state.config = null;
  state.vms = [];
  csrf = '';
  element('portal').hidden = true;
  element('login-view').hidden = false;
}
function key(vm) { return `${vm.namespace}/${vm.name}`; }
function statusType(vm) { return vm.ready ? 'running' : !vm.active && vm.status === 'Stopped' ? 'stopped' : 'attention'; }
function toolButton(name, title, callback, disabled = false) {
  const button = node('button', 'icon-button');
  button.type = 'button';
  button.title = title;
  button.setAttribute('aria-label', title);
  button.disabled = disabled;
  button.append(icon(name));
  button.addEventListener('click', callback);
  return button;
}
function renderFleet() {
  const list = element('vm-list');
  list.replaceChildren();
  const query = element('vm-search').value.toLowerCase();
  const filtered = state.vms.filter(vm => `${vm.name} ${vm.title} ${vm.namespace}`.toLowerCase().includes(query) && (state.filter === 'all' || statusType(vm) === state.filter));
  for (const vm of filtered) {
    const row = node('tr', state.selected === key(vm) ? 'selected' : '');
    const identity = node('div', 'vm-identity');
    const symbol = node('div', `vm-symbol ${vm.ready ? 'running' : ''}`); symbol.append(icon(vm.guest.rdp ? 'monitor' : 'server')); identity.append(symbol);
    const names = node('div');
    const name = node('button', 'vm-name', vm.title); name.addEventListener('click', () => selectVm(vm));
    names.append(name, node('div', 'vm-meta', vm.name)); identity.append(names);
    const identityCell = node('td'); identityCell.append(identity);
    const badge = node('span', `status ${statusType(vm)}`); badge.append(node('span', 'dot'), node('span', '', state.busy.has(key(vm)) ? 'Request pending' : vm.ready ? 'Ready' : vm.status));
    const statusCell = node('td'); statusCell.append(badge);
    const namespaceCell = node('td'); namespaceCell.append(node('span', 'namespace', vm.namespace));
    const resources = node('td', 'resource', `${vm.cores} vCPU / ${vm.memory}`);
    const actions = node('div', 'row-actions');
    const locked = !vm.managed || !vm.manual || state.busy.has(key(vm));
    actions.append(
      toolButton('play', `Start ${vm.title}`, () => confirmAction(vm, 'start'), locked || vm.active || vm.status !== 'Stopped'),
      toolButton('square', `Stop ${vm.title}`, () => confirmAction(vm, 'stop'), locked || !vm.active),
      toolButton('terminal', `Access ${vm.title}`, () => selectVm(vm), !vm.active)
    );
    const actionCell = node('td'); actionCell.append(actions);
    row.append(identityCell, statusCell, namespaceCell, resources, actionCell); list.append(row);
  }
  if (!filtered.length) { const row = node('tr'); const cell = node('td', 'empty', 'No virtual machines match this view.'); cell.colSpan = 5; row.append(cell); list.append(row); }
  element('total-count').textContent = state.vms.length;
  element('running-count').textContent = state.vms.filter(vm => vm.ready).length;
  element('stopped-count').textContent = state.vms.filter(vm => statusType(vm) === 'stopped').length;
  element('attention-count').textContent = state.vms.filter(vm => statusType(vm) === 'attention').length;
  element('nav-vm-count').textContent = state.vms.length;
  element('inventory-count').textContent = `${filtered.length} of ${state.vms.length} virtual machines`;
  element('stop-all').disabled = !state.vms.some(vm => vm.active && vm.managed && vm.manual) || state.busy.size > 0;
  icons();
}
function commandRow(title, detail, command) {
  const row = node('div', 'command-row');
  const label = node('div'); label.append(node('div', 'command-title', title), node('p', 'command-detail', detail));
  const code = node('div', 'command-code');
  const copy = toolButton('copy', `Copy ${title}`, async () => {
    try { await navigator.clipboard.writeText(command); notify(`${title} copied.`); }
    catch { notify('Clipboard unavailable. Select the command to copy it.'); }
  });
  code.append(node('pre', '', command), copy); row.append(label, code); return row;
}
function selectVm(vm) {
  state.selected = key(vm);
  renderFleet();
  renderAccess(vm);
  element('access-panel').scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}
function renderAccess(vm) {
  element('access-panel').hidden = false;
  element('access-title').textContent = vm.title;
  element('access-note').textContent = !vm.active ? 'This guest is stopped. Start it before opening a connection.' : !vm.ready ? 'The guest is starting or not Ready. Wait for readiness before connecting; VNC can help diagnose boot.' : 'Run these commands from the repository root on your KVM-host laptop. Guest login and the relevant service must be configured.';
  const commands = element('access-commands'); commands.replaceChildren();
  const prefix = 'KUBECONFIG="$PWD/work/kubeconfig-lab-k8s-01.yaml" work/virtctl-v1.9.1';
  const target = `${vm.name} -n ${vm.namespace}`;
  if (vm.guest.ssh) {
    const command = `${prefix} ssh ${vm.guest.user}@vmi/${target} \\\n+  --identity-file="$PWD/work/${vm.guest.key}" \\\n+  --known-hosts="$PWD/work/${vm.guest.knownHosts}" \\\n+  --local-ssh-opts=-tt --local-ssh-opts='-o IdentitiesOnly=yes' --local-ssh-opts='-o StrictHostKeyChecking=yes'`;
    commands.append(commandRow('SSH terminal', 'Uses the existing private key on your laptop.', command));
  }
  commands.append(commandRow('VNC display', 'Requires a local VNC viewer and guest graphics.', `${prefix} vnc ${target}`));
  if (vm.guest.rdpCommand) {
    commands.append(commandRow('RDP desktop', 'Uses the existing SSH tunnel to the guest-local RDP service and opens the desktop client.', vm.guest.rdpCommand));
  } else if (vm.guest.rdp) {
    commands.append(commandRow('RDP tunnel', 'Keep this terminal running. The guest needs RDP enabled and TCP 3389 exposed.', `${prefix} port-forward --address 127.0.0.1 vmi/${vm.name} ${vm.guest.rdpPort}:3389 -n ${vm.namespace}`));
    commands.append(commandRow('RDP client', 'Open in a second terminal. Enter the guest password directly when prompted.', `xfreerdp3 /v:127.0.0.1:${vm.guest.rdpPort} /u:${vm.guest.rdpUser} /dynamic-resolution`));
  }
  icons();
}
function confirm(title, description, warning, label) {
  const dialog = element('confirm-dialog');
  element('confirm-title').textContent = title;
  element('confirm-description').textContent = description;
  element('confirm-warning').textContent = warning;
  element('confirm-submit').textContent = label;
  dialog.returnValue = '';
  return new Promise(resolve => {
    dialog.addEventListener('close', () => resolve(dialog.returnValue === 'confirm'), { once: true });
    dialog.showModal();
  });
}
async function requestAction(vm, action) {
  state.busy.set(key(vm), { action, until: Date.now() + 90000 });
  renderFleet();
  try {
    const result = await api(`/api/vms/${encodeURIComponent(vm.namespace)}/${encodeURIComponent(vm.name)}/${action}`, { method: 'POST', body: JSON.stringify({ confirm: true }) });
    notify(result.message);
  } catch (error) { state.busy.delete(key(vm)); notify(error.message); }
  await refresh();
}
async function confirmAction(vm, action) {
  const starting = action === 'start';
  const approved = await confirm(`${starting ? 'Start' : 'Stop'} ${vm.title}?`, starting ? 'KubeVirt will schedule this guest using its existing disk and VM configuration.' : 'Request a graceful guest shutdown. Unsaved work can be lost.', starting ? 'Concurrent guests consume shared lab memory. Start server-test guests one at a time.' : 'Do not stop a guest during an OS installation or disk operation.', starting ? 'Start guest' : 'Stop guest');
  if (approved) await requestAction(vm, action);
}
async function refresh() {
  if (!state.config || state.syncing) return;
  state.syncing = true;
  element('sync-status').textContent = 'Refreshing';
  try {
    const result = await api('/api/vms');
    state.vms = result.vms;
    for (const vm of state.vms) {
      const pending = state.busy.get(key(vm));
      if (pending && (pending.until < Date.now() || (pending.action === 'start' ? vm.active : !vm.active))) state.busy.delete(key(vm));
    }
    element('inventory-error').hidden = true;
    element('sync-status').textContent = state.config.demo ? 'Simulated inventory' : 'Live inventory';
    element('last-updated').textContent = `Updated ${new Date(result.timestamp).toLocaleTimeString()}`;
    renderFleet();
    if (state.selected) {
      const selected = state.vms.find(vm => key(vm) === state.selected);
      if (selected) renderAccess(selected); else element('access-panel').hidden = true;
    }
  } catch (error) {
    element('inventory-error').textContent = error.message;
    element('inventory-error').hidden = false;
    element('sync-status').textContent = 'Connection error';
    element('vm-list').querySelectorAll('button').forEach(button => { button.disabled = true; });
    element('stop-all').disabled = true;
  } finally { state.syncing = false; }
}
async function initialize() {
  state.config = await api('/api/config'); csrf = state.config.csrf;
  element('login-view').hidden = true; element('portal').hidden = false;
  element('demo-badge').hidden = !state.config.demo;
  element('cluster-name').textContent = state.config.clusterName;
  const dashboards = element('dashboard-links'); dashboards.replaceChildren();
  for (const link of state.config.dashboardLinks) {
    const anchor = node('a', 'dashboard-item'); anchor.href = link.url; anchor.target = '_blank'; anchor.rel = 'noopener noreferrer';
    const image = node('img', 'dashboard-image'); image.src = link.name === 'Headlamp' ? '/images/headlamp-k3s-cluster-map.png' : '/images/cockpit-lab-vm-overview.png'; image.alt = `${link.name} dashboard`; image.loading = 'lazy';
    const content = node('div'); const title = node('h3', '', link.name); title.append(icon('arrow-up-right')); content.append(title, node('p', '', link.description), node('span', 'dashboard-url', link.url.replace(/^https?:\/\//, ''))); anchor.append(image, content); dashboards.append(anchor);
  }
  const commands = element('command-list'); commands.replaceChildren();
  for (const command of state.config.commands) commands.append(commandRow(command.title, command.detail, command.command));
  icons(); await refresh();
}
element('login-form').addEventListener('submit', async event => {
  event.preventDefault(); element('login-button').disabled = true; element('login-error').textContent = '';
  try { const result = await api('/api/login', { method: 'POST', body: JSON.stringify({ password: element('password').value }) }); csrf = result.csrf; element('password').value = ''; await initialize(); }
  catch (error) { element('login-error').textContent = error.message; }
  finally { element('login-button').disabled = false; }
});
element('logout').addEventListener('click', async () => { try { await api('/api/logout', { method: 'POST', body: '{}' }); showLogin(); } catch (error) { notify(error.message); } });
element('refresh').addEventListener('click', refresh);
element('vm-search').addEventListener('input', renderFleet);
document.querySelectorAll('[data-filter]').forEach(button => button.addEventListener('click', () => {
  state.filter = button.dataset.filter;
  document.querySelectorAll('[data-filter]').forEach(item => item.setAttribute('aria-pressed', String(item === button)));
  renderFleet();
}));
element('close-access').addEventListener('click', () => { state.selected = null; element('access-panel').hidden = true; renderFleet(); });
element('stop-all').addEventListener('click', async () => {
  const guests = state.vms.filter(vm => vm.active && vm.managed && vm.manual);
  if (await confirm(`Stop ${guests.length} running guests?`, guests.map(vm => vm.title).join(', '), 'Graceful shutdown requests will be sent sequentially. Unsaved work can be lost. The outer VM remains running.', 'Stop all guests')) {
    for (const vm of guests) await requestAction(vm, 'stop');
  }
});
document.querySelectorAll('nav a').forEach(anchor => anchor.addEventListener('click', () => {
  document.querySelectorAll('nav a').forEach(item => item.classList.toggle('active', item === anchor));
}));
icons();
initialize().catch(() => showLogin());
setInterval(refresh, 10000);