import express from 'express';
import session from 'express-session';
import { rateLimit } from 'express-rate-limit';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { ApiError, createCluster, demoCluster, kubernetesClient } from './cluster.js';

const root = fileURLToPath(new URL('../', import.meta.url));

export function createApp({ config, cluster, password, demo = false }) {
  if (!password || password.length < 24) throw new Error('A portal password of at least 24 characters is required.');
  const app = express();
  app.disable('x-powered-by');
  app.use((request, response, next) => {
    response.set({
      'Content-Security-Policy': "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
      'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer', 'Cache-Control': 'no-store'
    });
    next();
  });
  app.get('/healthz', (request, response) => response.json({ healthy: true }));
  app.use(express.json({ limit: '8kb' }));
  app.use(session({
    name: 'switchboard.sid', secret: crypto.createHash('sha256').update(password).digest('hex'),
    resave: false, saveUninitialized: false,
    cookie: { httpOnly: true, sameSite: 'strict', secure: process.env.COOKIE_SECURE === 'true', maxAge: 4 * 60 * 60 * 1000 }
  }));
  app.post('/api/login', rateLimit({ windowMs: 15 * 60 * 1000, limit: 20, standardHeaders: 'draft-8', legacyHeaders: false }), (request, response, next) => {
    const candidate = crypto.createHash('sha256').update(String(request.body?.password || '')).digest();
    const expected = crypto.createHash('sha256').update(password).digest();
    if (!crypto.timingSafeEqual(candidate, expected)) return response.status(401).json({ error: 'Incorrect portal password.' });
    request.session.regenerate(error => {
      if (error) return next(error);
      request.session.authenticated = true;
      request.session.csrf = crypto.randomBytes(32).toString('hex');
      response.json({ csrf: request.session.csrf });
    });
  });
  app.use('/api', (request, response, next) => {
    if (!request.session.authenticated) return response.status(401).json({ error: 'Sign in to Lab Switchboard.' });
    if (request.method !== 'GET' && request.get('X-CSRF-Token') !== request.session.csrf) return response.status(403).json({ error: 'Session verification failed. Reload and sign in again.' });
    next();
  });
  app.get('/api/config', (request, response) => response.json({ ...config, demo, csrf: request.session.csrf }));
  app.get('/api/vms', async (request, response) => response.json({ vms: await cluster.list(), timestamp: new Date().toISOString() }));
  app.post('/api/vms/:namespace/:name/:action', rateLimit({ windowMs: 60000, limit: 20 }), async (request, response) => {
    if (request.body?.confirm !== true) throw new ApiError(400, 'Explicit confirmation is required.');
    const { namespace, name, action } = request.params;
    const result = await cluster.action(namespace, name, action);
    console.info(JSON.stringify({ event: 'vm-action', namespace, name, action, timestamp: new Date().toISOString() }));
    response.status(202).json(result);
  });
  app.post('/api/logout', (request, response, next) => request.session.destroy(error => error ? next(error) : response.json({ signedOut: true })));
  app.get('/assets/lucide.js', (request, response) => response.sendFile(path.join(root, 'node_modules/lucide/dist/umd/lucide.min.js')));
  const fonts = {
    'sans.woff2': '@fontsource/ibm-plex-sans/files/ibm-plex-sans-latin-400-normal.woff2',
    'sans-medium.woff2': '@fontsource/ibm-plex-sans/files/ibm-plex-sans-latin-500-normal.woff2',
    'mono.woff2': '@fontsource/ibm-plex-mono/files/ibm-plex-mono-latin-400-normal.woff2'
  };
  app.get('/assets/fonts/:name', (request, response) => {
    const font = fonts[request.params.name];
    if (!font) return response.sendStatus(404);
    response.sendFile(path.join(root, 'node_modules', font));
  });
  app.use(express.static(path.join(root, 'public'), { etag: false }));
  app.use((error, request, response, next) => {
    if (!(error instanceof ApiError)) console.error('Portal request failed:', error.message);
    response.status(error.status || 500).json({ error: error instanceof ApiError ? error.message : 'Request failed. Check portal logs.' });
  });
  return app;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const config = JSON.parse(fs.readFileSync(process.env.SWITCHBOARD_CONFIG || path.join(root, 'config/lab.json'), 'utf8'));
  const demo = process.env.SWITCHBOARD_DEMO === 'true';
  const password = process.env.SWITCHBOARD_PASSWORD || (demo ? 'switchboard-demo-local-only' : '');
  const cluster = demo ? demoCluster(config) : createCluster(config, kubernetesClient());
  const port = Number(process.env.PORT || 18088);
  const host = process.env.BIND_ADDRESS || '127.0.0.1';
  createApp({ config, cluster, password, demo }).listen(port, host, () => console.info(`Lab Switchboard listening on ${host}:${port}${demo ? ' (simulated demo)' : ''}`));
}