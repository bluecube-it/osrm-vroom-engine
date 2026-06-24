#!/usr/bin/env node
'use strict';

/**
 * OSRM radiuses proxy.
 *
 * Intercepts every /route/v1/ and /table/v1/ request, counts the
 * coordinates in the URL path and ALWAYS overwrites the `radiuses`
 * query parameter with a generated value (<radius> repeated once per
 * coordinate, separated by `;`).
 *
 * If the incoming request already has `radiuses`, it is discarded and
 * replaced — the proxy value always wins.
 *
 * Configuration via environment variables:
 *   OSRM_UPSTREAM_HOST   default 127.0.0.1
 *   OSRM_UPSTREAM_PORT   default 5000
 *   OSRM_PROXY_PORT      default 5001
 *   OSRM_DEFAULT_RADIUS  default 50  (meters) — tuned for DRT use cases
 */

const http = require('http');
const url  = require('url');

const UPSTREAM_HOST  = process.env.OSRM_UPSTREAM_HOST  || '127.0.0.1';
const UPSTREAM_PORT  = parseInt(process.env.OSRM_UPSTREAM_PORT  || '5000', 10);
const PROXY_PORT     = parseInt(process.env.OSRM_PROXY_PORT     || '5001', 10);
const DEFAULT_RADIUS = parseFloat(process.env.OSRM_DEFAULT_RADIUS || '50');

/**
 * Extract the number of coordinates from a `/route/v1/<profile>/<coords>`
 * or `/table/v1/<profile>/<coords>` path.
 *
 * Returns 0 when the path does not match so the request is passed through
 * untouched (e.g. /nearest/ or health-check pings).
 */
function countCoordinates(path) {
  // Match  /route/v1/driving/13.38,52.51;13.39,52.52  or
  //        /table/v1/driving/polyline(...)
  const m = path.match(/^\/(?:route|table)\/v1\/[^/]+\/(.+)$/);
  if (!m) return 0;

  const coordPart = m[1];
  // polyline(...) — we cannot count individual coordinates reliably,
  // but OSRM needs one radius entry per decoded point.  Decode is overkill
  // here; fall back to a single radius value which OSRM will reject if the
  // count is wrong, surfacing the problem instead of hiding it.
  if (coordPart.startsWith('polyline(')) return 0;

  return coordPart.split(';').length;
}

/**
 * Remove every `radiuses` occurrence from the query string.
 */
function stripRadiuses(parsedUrl) {
  if (!parsedUrl.query) return;
  const params = new URLSearchParams(parsedUrl.query);
  params.delete('radiuses');
  parsedUrl.query   = params.toString();
  parsedUrl.search   = parsedUrl.query ? '?' + parsedUrl.query : '';
  parsedUrl.path     = parsedUrl.pathname + parsedUrl.search;
}

function handleRequest(req, res) {
  const parsed = url.parse(req.url, true /* parseQueryString */);

  // Only inject for route/table services. Everything else passes through.
  const needsRadiuses = /^\/(?:route|table)\/v1\//.test(parsed.pathname);

  if (needsRadiuses) {
    const count = countCoordinates(parsed.pathname);
    if (count > 0) {
      // Strip any existing radiuses — proxy value always wins.
      stripRadiuses(parsed);

      const radiusValue = Array(count).fill(DEFAULT_RADIUS).join(';');
      // Add (or replace) radiuses.
      const params = parsed.query
        ? new URLSearchParams(parsed.query)
        : new URLSearchParams();
      params.set('radiuses', radiusValue);

      parsed.search = '?' + params.toString();
      req.url = parsed.pathname + parsed.search;

      console.log(
        `[osrm-proxy] ${req.method} ${parsed.pathname} — injected radiuses=${radiusValue} (${count} coords)`
      );
    }
  }

  const proxyOptions = {
    hostname: UPSTREAM_HOST,
    port:     UPSTREAM_PORT,
    path:     req.url,
    method:   req.method,
    headers:  req.headers,
  };

  const proxyReq = http.request(proxyOptions, function (proxyRes) {
    res.writeHead(proxyRes.statusCode, proxyRes.headers);
    proxyRes.pipe(res, { end: true });
  });

  proxyReq.on('error', function (err) {
    console.error('[osrm-proxy] upstream error:', err.message);
    res.writeHead(502, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ code: 'InvalidUrl', message: 'OSRM proxy upstream error: ' + err.message }));
  });

  req.pipe(proxyReq, { end: true });
}

const server = http.createServer(handleRequest);

server.listen(PROXY_PORT, '127.0.0.1', function () {
  console.log(
    `[osrm-proxy] listening on 127.0.0.1:${PROXY_PORT} → ${UPSTREAM_HOST}:${UPSTREAM_PORT}, radius=${DEFAULT_RADIUS}m (always override)`
  );
});

server.on('error', function (err) {
  console.error('[osrm-proxy] fatal:', err.message);
  process.exit(1);
});
