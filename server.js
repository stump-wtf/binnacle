// Bootstrap static server for the binnacle container.
//
// Serves the built SPA (web/dist) over node:http with a /healthz endpoint.
// Per the deployment note in stumpcloud/ansible's dub.yaml, the Gren server
// (gren-lang/node: HTTP, SQLite, control) replaces this CMD later — keep this
// file dependency-free and boring so swapping it out is a one-line change.
//
// Contract with the inventory entry:
//   - listens on PORT (default 8080)
//   - GET /healthz -> 200 "ok" (docker HEALTHCHECK and the deploy lane's
//     readiness probe)
//   - everything else -> web/dist, with index.html for unknown paths (SPA
//     routing) and immutable caching for Vite's hashed assets.

'use strict';

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

const PORT = Number(process.env.PORT || 8080);
const DIST = path.join(__dirname, 'dist');

const TYPES = {
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.ico': 'image/x-icon',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.map': 'application/json',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.woff2': 'font/woff2',
};

function send(res, status, body, headers) {
  res.writeHead(status, headers);
  res.end(body);
}

const server = http.createServer((req, res) => {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    return send(res, 405, 'method not allowed', { 'Content-Type': 'text/plain' });
  }

  // Match on the path, not the raw URL: probes that append a cache-buster
  // (/healthz?t=…) must still get the health answer, not the SPA shell.
  const pathname = req.url.split('?')[0];
  if (pathname === '/healthz' || pathname === '/healthz/') {
    return send(res, 200, 'ok', { 'Content-Type': 'text/plain' });
  }

  const wanted = path.normalize(pathname).replace(/^(\.\.[/\\])+/, '');
  let file = path.join(DIST, wanted);
  if (file === DIST || path.extname(file) === '') {
    file = path.join(DIST, 'index.html'); // SPA routing
  }
  if (!file.startsWith(DIST + path.sep)) {
    return send(res, 403, 'forbidden', { 'Content-Type': 'text/plain' });
  }

  fs.readFile(file, (err, body) => {
    if (err) {
      // Unknown route: the SPA handles it client-side.
      fs.readFile(path.join(DIST, 'index.html'), (indexErr, indexBody) => {
        if (indexErr) {
          return send(res, 404, 'not found', { 'Content-Type': 'text/plain' });
        }
        send(res, 200, indexBody, {
          'Content-Type': 'text/html; charset=utf-8',
          'Cache-Control': 'no-cache',
        });
      });
      return;
    }
    const type = TYPES[path.extname(file)] || 'application/octet-stream';
    // Vite emits content-hashed filenames for everything but index.html, so
    // hashed assets can be cached forever and index.html must not be.
    const hashed = /[.-][0-9a-zA-Z]{8,}\.(js|css|woff2|png|svg|map)$/.test(file);
    send(res, 200, body, {
      'Content-Type': type,
      'Cache-Control': hashed ? 'public, max-age=31536000, immutable' : 'no-cache',
    });
  });
});

server.listen(PORT, () => {
  console.log(`binnacle bootstrap server listening on :${PORT}`);
});
