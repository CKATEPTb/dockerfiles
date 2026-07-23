#!/usr/bin/env node

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'onlyoffice-config-'));

function writeJson(file, value) {
	fs.mkdirSync(path.dirname(file), { recursive: true });
	fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

function nested(value, keys) {
	return keys.reduce((cursor, key) => cursor?.[key], value);
}

try {
	const serverRoot = path.join(temporaryRoot, 'server');
	const upstreamConfigRoot = path.join(temporaryRoot, 'upstream-config');
	const upstreamNginxIncludes = path.join(temporaryRoot, 'upstream-nginx-includes');
	const runtimeConfigDir = path.join(serverRoot, 'runtime', 'config');
	const nginxDir = path.join(serverRoot, 'runtime', 'nginx');
	const logDir = path.join(serverRoot, 'logs');
	const tmpDir = path.join(serverRoot, 'tmp');
	const dataDir = path.join(serverRoot, 'data');
	const secretsDir = path.join(serverRoot, '.secrets');
	const jwtSecret = 'a'.repeat(64);
	const secureLinkSecret = 'b'.repeat(64);

	fs.mkdirSync(path.join(upstreamConfigRoot, 'nginx', 'includes'), { recursive: true });
	fs.mkdirSync(upstreamNginxIncludes, { recursive: true });
	fs.mkdirSync(secretsDir, { recursive: true });
	writeJson(path.join(upstreamConfigRoot, 'local.json'), {});
	writeJson(path.join(upstreamConfigRoot, 'log4js', 'production.json'), {
		categories: { default: { appenders: ['console'], level: 'WARN' } },
	});
	fs.writeFileSync(path.join(upstreamConfigRoot, 'nginx', 'ds.conf.tmpl'), `
include /etc/nginx/includes/http-common.conf;
server {
  listen 0.0.0.0:80;
  listen [::]:80 default_server;
  set $secure_link_secret verysecretstring;
  include /etc/nginx/includes/ds-*.conf;
}
`);
	fs.writeFileSync(path.join(upstreamConfigRoot, 'nginx', 'includes', 'ds-common.conf'), `
client_max_body_size 100m;
access_log off;
error_log /var/log/onlyoffice/documentserver/nginx.error.log;
`);
	fs.writeFileSync(path.join(upstreamConfigRoot, 'nginx', 'includes', 'ds-docservice.conf'), `
location / { proxy_pass http://docservice; }
`);
	fs.writeFileSync(path.join(upstreamNginxIncludes, 'ds-cache.conf'), 'set $cache_tag "test";\n');
	fs.writeFileSync(path.join(secretsDir, 'jwt_secret'), jwtSecret, { mode: 0o600 });
	fs.writeFileSync(path.join(secretsDir, 'secure_link_secret'), secureLinkSecret, { mode: 0o600 });

	const environment = {
		...process.env,
		SERVER_ROOT: serverRoot,
		IMAGE_RUNTIME_ROOT: path.join(projectRoot, 'runtime'),
		UPSTREAM_CONFIG_ROOT: upstreamConfigRoot,
		UPSTREAM_NGINX_INCLUDES: upstreamNginxIncludes,
		RUNTIME_CONFIG_DIR: runtimeConfigDir,
		NGINX_DIR: nginxDir,
		LOG_DIR: logDir,
		TMP_DIR: tmpDir,
		DATA_DIR: dataDir,
		JWT_SECRET_FILE: path.join(secretsDir, 'jwt_secret'),
		SECURE_LINK_SECRET_FILE: path.join(secretsDir, 'secure_link_secret'),
		SERVER_PORT: '15432',
		JWT_HEADER: 'Authorization',
		ALLOW_PRIVATE_IP_ADDRESS: '0',
		USE_UNAUTHORIZED_STORAGE: '0',
		LOG_LEVEL: 'WARN',
		NGINX_ACCESS_LOG: '0',
		UPLOAD_LIMIT: '2G',
		NGINX_WORKER_PROCESSES: '2',
		NGINX_WORKER_CONNECTIONS: '2048',
	};
	const configure = spawnSync(
		process.execPath,
		[path.join(projectRoot, 'runtime', 'scripts', 'configure.mjs')],
		{ env: environment, encoding: 'utf8' },
	);
	assert.equal(configure.status, 0, configure.stderr);
	assert.doesNotMatch(configure.stdout + configure.stderr, new RegExp(jwtSecret));

	const localConfig = JSON.parse(fs.readFileSync(path.join(runtimeConfigDir, 'local.json'), 'utf8'));
	assert.equal(nested(localConfig, ['services', 'CoAuthoring', 'token', 'enable', 'browser']), true);
	assert.equal(nested(localConfig, ['services', 'CoAuthoring', 'token', 'enable', 'request', 'inbox']), true);
	assert.equal(nested(localConfig, ['services', 'CoAuthoring', 'token', 'enable', 'request', 'outbox']), true);
	assert.equal(nested(localConfig, ['services', 'CoAuthoring', 'token', 'inbox', 'inBody']), false);
	assert.equal(nested(localConfig, ['services', 'CoAuthoring', 'secret', 'browser', 'string']), jwtSecret);
	assert.equal(
		nested(localConfig, ['services', 'CoAuthoring', 'request-filtering-agent', 'allowPrivateIPAddress']),
		false,
	);
	assert.equal(
		nested(localConfig, ['services', 'CoAuthoring', 'request-filtering-agent', 'allowMetaIPAddress']),
		false,
	);
	assert.equal(nested(localConfig, ['storage', 'fs', 'secretString']), secureLinkSecret);
	assert.equal(nested(localConfig, ['wopi', 'enable']), false);

	const documentServerConfig = fs.readFileSync(path.join(nginxDir, 'ds.conf'), 'utf8');
	assert.match(documentServerConfig, /listen 0\.0\.0\.0:15432;/);
	assert.match(documentServerConfig, new RegExp(`set \\$secure_link_secret "${secureLinkSecret}";`));
	assert.doesNotMatch(documentServerConfig, /\/etc\/nginx\/includes/);
	const commonInclude = fs.readFileSync(path.join(nginxDir, 'includes', 'ds-common.conf'), 'utf8');
	assert.match(commonInclude, /client_max_body_size 2G;/);
	assert.match(commonInclude, /access_log off;/);
	assert.equal(fs.readFileSync(path.join(nginxDir, 'includes', 'ds-cache.conf'), 'utf8'), 'set $cache_tag "test";\n');

	const unsafeHeader = spawnSync(
		process.execPath,
		[path.join(projectRoot, 'runtime', 'scripts', 'configure.mjs')],
		{ env: { ...environment, JWT_HEADER: 'Authorization\r\nInjected' }, encoding: 'utf8' },
	);
	assert.notEqual(unsafeHeader.status, 0);
	assert.match(unsafeHeader.stderr, /valid HTTP header name/);

	console.log('[test-configure] OK: generated configuration and validation behavior verified');
} finally {
	fs.rmSync(temporaryRoot, { recursive: true, force: true });
}
