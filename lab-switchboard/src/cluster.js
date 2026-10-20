import https from 'node:https';
import fs from 'node:fs';

export class ApiError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

export function kubernetesClient() {
  const directory = '/var/run/secrets/kubernetes.io/serviceaccount';
  const origin = `https://${process.env.KUBERNETES_SERVICE_HOST}:${process.env.KUBERNETES_SERVICE_PORT_HTTPS || 443}`;
  const certificate = fs.readFileSync(`${directory}/ca.crt`);
  return (method, resourcePath, payload) => new Promise((resolve, reject) => {
    const body = payload === undefined ? undefined : JSON.stringify(payload);
    const request = https.request(new URL(resourcePath, origin), {
      method,
      ca: certificate,
      headers: {
        Authorization: `Bearer ${fs.readFileSync(`${directory}/token`, 'utf8').trim()}`,
        Accept: '*/*',
        ...(body ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } : {})
      },
      timeout: 12000
    }, response => {
      let output = '';
      response.setEncoding('utf8');
      response.on('data', chunk => {
        output += chunk;
        if (output.length > 8 * 1024 * 1024) request.destroy(new Error('API response too large'));
      });
      response.on('end', () => {
        if (response.statusCode >= 400) {
          reject(new ApiError(response.statusCode, response.statusCode === 409 ? 'VM state changed. Refresh and try again.' : 'Kubernetes rejected the request. Check resource state and portal RBAC.'));
          return;
        }
        try { resolve(output ? JSON.parse(output) : {}); }
        catch { reject(new ApiError(502, 'Invalid Kubernetes API response.')); }
      });
    });
    request.on('timeout', () => request.destroy(new Error('Kubernetes request timed out')));
    request.on('error', () => reject(new ApiError(502, 'Kubernetes API is unavailable.')));
    if (body) request.write(body);
    request.end();
  });
}

export function createCluster(config, request) {
  const namespaceAllowed = namespace => config.namespaces.includes(namespace);
  const vmPath = (namespace, name) => `/apis/kubevirt.io/v1/namespaces/${encodeURIComponent(namespace)}/virtualmachines/${encodeURIComponent(name)}`;
  const owned = vm => vm.metadata?.labels?.[config.managedLabel] === config.managedValue;

  function summary(vm, instances) {
    const instance = instances.find(item => item.metadata.name === vm.metadata.name);
    const ready = instance?.status?.conditions?.some(condition => condition.type === 'Ready' && condition.status === 'True') || false;
    const namespace = vm.metadata.namespace;
    const name = vm.metadata.name;
    const guest = config.guests[`${namespace}/${name}`] || {};
    return {
      namespace, name, title: guest.title || name, os: guest.os || 'KubeVirt guest',
      status: vm.status?.printableStatus || instance?.status?.phase || 'Stopped',
      ready, active: Boolean(instance), managed: owned(vm),
      manual: vm.spec?.runStrategy === 'Manual',
      cores: vm.spec?.template?.spec?.domain?.cpu?.cores || 1,
      memory: vm.spec?.template?.spec?.domain?.resources?.requests?.memory || 'Unknown',
      guest,
      interfaces: (instance?.status?.interfaces || []).map(item => ({ name: item.name, ip: item.ipAddress || '' }))
    };
  }

  return {
    async list() {
      const results = await Promise.all(config.namespaces.map(async namespace => {
        const [vms, instances] = await Promise.all([
          request('GET', `/apis/kubevirt.io/v1/namespaces/${namespace}/virtualmachines`),
          request('GET', `/apis/kubevirt.io/v1/namespaces/${namespace}/virtualmachineinstances`)
        ]);
        return vms.items.map(vm => summary(vm, instances.items));
      }));
      return results.flat();
    },
    async action(namespace, name, action) {
      if (!namespaceAllowed(namespace) || !/^[a-z0-9][a-z0-9.-]{0,252}$/.test(name) || !['start', 'stop'].includes(action)) {
        throw new ApiError(400, 'Unsupported VM or action.');
      }
      const vm = await request('GET', vmPath(namespace, name));
      if (!owned(vm) || vm.spec?.runStrategy !== 'Manual') throw new ApiError(403, 'Only project-managed VMs with Manual runStrategy can be controlled.');
      if (vm.metadata.deletionTimestamp) throw new ApiError(409, 'This VM is being deleted.');
      await request('PUT', `/apis/subresources.kubevirt.io/v1/namespaces/${namespace}/virtualmachines/${name}/${action}`, {});
      return { message: `${action === 'start' ? 'Start' : 'Graceful stop'} requested for ${name}.` };
    }
  };
}

export function demoCluster(config) {
  const active = new Set(['netpol-test/netpol-client', 'rocky-desktop/rocky-desktop']);
  return {
    async list() {
      return Object.entries(config.guests).map(([key, guest]) => {
        const [namespace, name] = key.split('/');
        return { namespace, name, title: guest.title, os: guest.os, ready: active.has(key), active: active.has(key), status: active.has(key) ? 'Running' : 'Stopped', managed: true, manual: true, cores: name === 'rocky-desktop' ? 4 : 2, memory: name === 'rocky-desktop' ? '6Gi' : '2Gi', guest, interfaces: [] };
      });
    },
    async action(namespace, name, action) {
      if (!config.guests[`${namespace}/${name}`] || !['start', 'stop'].includes(action)) throw new ApiError(400, 'Unsupported demo action.');
      if (action === 'start') active.add(`${namespace}/${name}`); else active.delete(`${namespace}/${name}`);
      return { message: `Demo: ${action} simulated for ${name}. No live VM changed.` };
    }
  };
}