import test from 'node:test';
import assert from 'node:assert/strict';
import https from 'node:https';
import fs from 'node:fs';
import { EventEmitter } from 'node:events';
import { createApp } from '../src/server.js';
import { createCluster, demoCluster, kubernetesClient } from '../src/cluster.js';

const config = { namespaces: ['netpol-test'], managedLabel: 'owner', managedValue: 'lab', guests: { 'netpol-test/client': { title: 'Client' } } };
const password = 'a-private-test-password-only';

test('KubeVirt lifecycle transport accepts its empty 202 response representation', async context => {
  context.mock.method(fs, 'readFileSync', file => String(file).endsWith('ca.crt') ? Buffer.from('test-ca') : 'test-token');
  context.mock.method(https, 'request', (url, options, callback) => {
    assert.equal(options.headers.Accept, '*/*');
    const request = new EventEmitter();
    request.write = () => {};
    request.end = () => {
      const response = new EventEmitter();
      response.statusCode = 202;
      response.setEncoding = () => {};
      callback(response);
      response.emit('end');
    };
    return request;
  });
  const result = await kubernetesClient()('PUT', '/apis/subresources.kubevirt.io/v1/namespaces/netpol-test/virtualmachines/client/start', {});
  assert.deepEqual(result, {});
});

test('VM control enforces namespace, action, ownership and Manual runStrategy', async () => {
  const calls = [];
  const vm = { metadata: { name: 'client', namespace: 'netpol-test', labels: { owner: 'lab' } }, spec: { runStrategy: 'Manual' } };
  const cluster = createCluster(config, async (...args) => { calls.push(args); return vm; });
  await assert.rejects(cluster.action('kube-system', 'client', 'start'), { status: 400 });
  await assert.rejects(cluster.action('netpol-test', '../client', 'start'), { status: 400 });
  await assert.rejects(cluster.action('netpol-test', 'client', 'delete'), { status: 400 });
  assert.equal(calls.length, 0);
  await cluster.action('netpol-test', 'client', 'start');
  assert.equal(calls[1][0], 'PUT');
  assert.equal(calls[1][1], '/apis/subresources.kubevirt.io/v1/namespaces/netpol-test/virtualmachines/client/start');
  vm.metadata.labels.owner = 'someone-else';
  await assert.rejects(cluster.action('netpol-test', 'client', 'stop'), { status: 403 });
  vm.metadata.labels.owner = 'lab';
  vm.spec.runStrategy = 'Always';
  await assert.rejects(cluster.action('netpol-test', 'client', 'stop'), { status: 403 });
});

test('HTTP controls require login, CSRF and explicit confirmation', async context => {
  const app = createApp({ config, cluster: demoCluster(config), password, demo: true });
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  context.after(() => server.close());
  const origin = `http://127.0.0.1:${server.address().port}`;
  const send = (route, options = {}) => fetch(`${origin}${route}`, options);
  assert.equal((await send('/api/vms')).status, 401);
  assert.equal((await send('/healthz')).status, 200);
  for (const asset of ['/assets/lucide.js', '/assets/fonts/sans.woff2', '/assets/fonts/sans-medium.woff2', '/assets/fonts/mono.woff2']) {
    assert.equal((await send(asset)).status, 200, asset);
  }
  assert.equal((await send('/assets/fonts/unknown.woff2')).status, 404);
  assert.equal((await send('/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{"password":"wrong"}' })).status, 401);
  const login = await send('/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ password }) });
  assert.equal(login.status, 200);
  const cookie = login.headers.get('set-cookie').split(';')[0];
  const { csrf } = await login.json();
  const headers = { Cookie: cookie, 'Content-Type': 'application/json' };
  assert.equal((await send('/api/vms', { headers })).status, 200);
  assert.equal((await send('/api/vms/netpol-test/client/start', { method: 'POST', headers, body: '{"confirm":true}' })).status, 403);
  headers['X-CSRF-Token'] = csrf;
  assert.equal((await send('/api/vms/netpol-test/client/start', { method: 'POST', headers, body: '{}' })).status, 400);
  assert.equal((await send('/api/vms/netpol-test/client/start', { method: 'POST', headers, body: '{"confirm":true}' })).status, 202);
  assert.equal((await send('/api/logout', { method: 'POST', headers })).status, 200);
  assert.equal((await send('/api/vms', { headers })).status, 401);
});