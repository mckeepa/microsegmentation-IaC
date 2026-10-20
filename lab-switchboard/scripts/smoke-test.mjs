import assert from 'node:assert/strict';
import fs from 'node:fs';

const origin = new URL(process.env.SWITCHBOARD_URL || 'http://127.0.0.1:18088');
assert.ok(['localhost', '127.0.0.1', '[::1]'].includes(origin.hostname), 'Smoke tests require a loopback URL.');
const password = fs.readFileSync(new URL('../.local/admin-password', import.meta.url), 'utf8').trim();
const request = (route, options = {}) => fetch(new URL(route, origin), { ...options, signal: AbortSignal.timeout(15000) });

assert.equal((await request('/api/vms')).status, 401);
const login = await request('/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ password }) });
assert.equal(login.status, 200, 'Portal login must succeed.');
const cookie = login.headers.get('set-cookie').split(';')[0];
const { csrf } = await login.json();
const headers = { Cookie: cookie, 'Content-Type': 'application/json' };
const configResponse = await request('/api/config', { headers });
assert.equal(configResponse.status, 200);
const config = await configResponse.json();
assert.equal(config.demo, false, 'The deployed portal must use the live cluster.');
const inventory = await request('/api/vms', { headers });
assert.equal(inventory.status, 200);
const { vms } = await inventory.json();
assert.ok(vms.length > 0, 'The live inventory must contain VMs.');
for (const vm of vms) assert.ok(config.namespaces.includes(vm.namespace));
const guest = vms[0];
const actionPath = `/api/vms/${guest.namespace}/${guest.name}/start`;
assert.equal((await request(actionPath, { method: 'POST', headers, body: '{"confirm":true}' })).status, 403);
headers['X-CSRF-Token'] = csrf;
assert.equal((await request(actionPath, { method: 'POST', headers, body: '{}' })).status, 400);
assert.equal((await request('/api/vms/kube-system/not-allowed/start', { method: 'POST', headers, body: '{"confirm":true}' })).status, 400);
for (const asset of ['/assets/lucide.js', '/assets/fonts/sans.woff2', '/images/headlamp-k3s-cluster-map.png', '/images/cockpit-lab-vm-overview.png']) {
  assert.equal((await request(asset)).status, 200, asset);
}
assert.equal((await request('/api/logout', { method: 'POST', headers, body: '{}' })).status, 200);
assert.equal((await request('/api/vms', { headers })).status, 401);
console.log(`PASS: authenticated live inventory (${vms.length} VMs), assets, confirmation/CSRF guards, namespace boundary, and logout. No VM state was changed.`);