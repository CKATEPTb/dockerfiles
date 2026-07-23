#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const JWT_ENABLED = true;
const JWT_IN_BODY = false;
const ALLOW_META_IP_ADDRESS = false;

function fail(message) {
	process.stderr.write(`[ONLYOFFICE] ERROR: ${message}\n`);
	process.exit(1);
}

function requiredEnvironment(name) {
	const value = process.env[name];
	if (!value) fail(`Required environment value is missing: ${name}.`);
	return value;
}

function booleanEnvironment(name, fallback = false) {
	const raw = process.env[name];
	if (raw === undefined || raw === '') return fallback;
	if (/^(?:1|true|yes|on)$/i.test(raw)) return true;
	if (/^(?:0|false|no|off)$/i.test(raw)) return false;
	fail(`${name} must be a boolean (0 or 1).`);
}

function integerEnvironment(name, fallback, minimum, maximum) {
	const raw = process.env[name] || String(fallback);
	if (!/^\d+$/.test(raw)) fail(`${name} must be an integer.`);
	const value = Number(raw);
	if (value < minimum || value > maximum) {
		fail(`${name} must be between ${minimum} and ${maximum}.`);
	}
	return value;
}

function setNested(target, keys, value) {
	let cursor = target;
	for (const key of keys.slice(0, -1)) {
		if (!cursor[key] || typeof cursor[key] !== 'object' || Array.isArray(cursor[key])) {
			cursor[key] = {};
		}
		cursor = cursor[key];
	}
	cursor[keys.at(-1)] = value;
}

function readJson(file) {
	try {
		return JSON.parse(fs.readFileSync(file, 'utf8'));
	} catch (error) {
		fail(`Cannot read JSON configuration ${file}: ${error.message}`);
	}
}

function writeFileAtomically(file, content, mode = 0o600) {
	const temporary = `${file}.tmp-${process.pid}`;
	fs.writeFileSync(temporary, content, { mode });
	fs.renameSync(temporary, file);
	fs.chmodSync(file, mode);
}

function copyDirectory(source, destination) {
	if (!fs.existsSync(source)) fail(`Configuration seed is missing: ${source}.`);
	fs.rmSync(destination, { recursive: true, force: true });
	fs.mkdirSync(path.dirname(destination), { recursive: true });
	fs.cpSync(source, destination, { recursive: true, force: true });
}

function copyDirectoryContents(source, destination) {
	if (!fs.existsSync(source)) return;
	fs.mkdirSync(destination, { recursive: true });
	for (const entry of fs.readdirSync(source)) {
		fs.cpSync(path.join(source, entry), path.join(destination, entry), {
			recursive: true,
			force: true,
		});
	}
}

function replaceAllLiteral(value, search, replacement) {
	return value.split(search).join(replacement);
}

const serverRoot = requiredEnvironment('SERVER_ROOT');
const imageRuntimeRoot = requiredEnvironment('IMAGE_RUNTIME_ROOT');
const upstreamConfigRoot = requiredEnvironment('UPSTREAM_CONFIG_ROOT');
const upstreamNginxIncludes = requiredEnvironment('UPSTREAM_NGINX_INCLUDES');
const runtimeConfigDir = requiredEnvironment('RUNTIME_CONFIG_DIR');
const nginxDir = requiredEnvironment('NGINX_DIR');
const logDir = requiredEnvironment('LOG_DIR');
const tmpDir = requiredEnvironment('TMP_DIR');
const dataDir = requiredEnvironment('DATA_DIR');
const jwtSecretFile = requiredEnvironment('JWT_SECRET_FILE');
const secureLinkSecretFile = requiredEnvironment('SECURE_LINK_SECRET_FILE');

for (const generatedPath of [runtimeConfigDir, nginxDir]) {
	const relative = path.relative(serverRoot, generatedPath);
	if (relative.startsWith('..') || path.isAbsolute(relative)) {
		fail(`Refusing to generate runtime configuration outside ${serverRoot}.`);
	}
}

const port = integerEnvironment('SERVER_PORT', 8080, 1, 65535);
const workerProcesses = integerEnvironment('NGINX_WORKER_PROCESSES', 1, 1, 32);
const workerConnections = integerEnvironment('NGINX_WORKER_CONNECTIONS', 4096, 128, 65535);
const jwtHeader = process.env.JWT_HEADER || 'Authorization';
if (!/^[A-Za-z][A-Za-z0-9-]{0,63}$/.test(jwtHeader)) {
	fail('JWT_HEADER must be a valid HTTP header name with at most 64 characters.');
}

const uploadLimit = process.env.UPLOAD_LIMIT || '1G';
if (!/^\d+[KMG]$/i.test(uploadLimit)) fail('UPLOAD_LIMIT must look like 512M or 1G.');

const logLevel = (process.env.LOG_LEVEL || 'WARN').toUpperCase();
const allowedLogLevels = new Set(['ALL', 'TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL', 'MARK', 'OFF']);
if (!allowedLogLevels.has(logLevel)) fail(`Unsupported LOG_LEVEL: ${logLevel}.`);

const jwtSecret = fs.readFileSync(jwtSecretFile, 'utf8').replace(/[\r\n]+$/u, '');
const secureLinkSecret = fs.readFileSync(secureLinkSecretFile, 'utf8').replace(/[\r\n]+$/u, '');
if (jwtSecret.length < 32 || jwtSecret.length > 512) fail('The persistent JWT secret has an invalid length.');
if (!/^[a-f0-9]{64}$/i.test(secureLinkSecret)) fail('The persistent secure-link secret is invalid.');

copyDirectory(upstreamConfigRoot, runtimeConfigDir);

const localJsonPath = path.join(runtimeConfigDir, 'local.json');
const localConfig = readJson(localJsonPath);
setNested(localConfig, ['services', 'CoAuthoring', 'token', 'enable', 'browser'], JWT_ENABLED);
setNested(localConfig, ['services', 'CoAuthoring', 'token', 'enable', 'request', 'inbox'], JWT_ENABLED);
setNested(localConfig, ['services', 'CoAuthoring', 'token', 'enable', 'request', 'outbox'], JWT_ENABLED);
setNested(localConfig, ['services', 'CoAuthoring', 'token', 'inbox', 'header'], jwtHeader);
setNested(localConfig, ['services', 'CoAuthoring', 'token', 'outbox', 'header'], jwtHeader);
setNested(localConfig, ['services', 'CoAuthoring', 'token', 'inbox', 'inBody'], JWT_IN_BODY);
setNested(localConfig, ['services', 'CoAuthoring', 'token', 'outbox', 'inBody'], JWT_IN_BODY);
for (const direction of ['inbox', 'outbox', 'session', 'browser']) {
	setNested(localConfig, ['services', 'CoAuthoring', 'secret', direction, 'string'], jwtSecret);
}
setNested(
	localConfig,
	['services', 'CoAuthoring', 'request-filtering-agent', 'allowPrivateIPAddress'],
	booleanEnvironment('ALLOW_PRIVATE_IP_ADDRESS', false),
);
setNested(
	localConfig,
	['services', 'CoAuthoring', 'request-filtering-agent', 'allowMetaIPAddress'],
	ALLOW_META_IP_ADDRESS,
);
if (booleanEnvironment('USE_UNAUTHORIZED_STORAGE', false)) {
	setNested(localConfig, ['services', 'CoAuthoring', 'requestDefaults', 'rejectUnauthorized'], false);
}
setNested(localConfig, ['wopi', 'enable'], false);
setNested(localConfig, ['runtimeConfig', 'filePath'], path.join(dataDir, 'onlyoffice-data', 'runtime.json'));
setNested(localConfig, ['storage', 'fs', 'secretString'], secureLinkSecret);
setNested(localConfig, ['persistentStorage', 'fs', 'secretString'], secureLinkSecret);
writeFileAtomically(localJsonPath, `${JSON.stringify(localConfig, null, 2)}\n`);

const logConfigPath = path.join(runtimeConfigDir, 'log4js', 'production.json');
const logConfig = readJson(logConfigPath);
setNested(logConfig, ['categories', 'default', 'level'], logLevel);
writeFileAtomically(logConfigPath, `${JSON.stringify(logConfig, null, 2)}\n`, 0o644);

const nginxSeedDir = path.join(runtimeConfigDir, 'nginx');
const includesDir = path.join(nginxDir, 'includes');
fs.rmSync(nginxDir, { recursive: true, force: true });
fs.mkdirSync(includesDir, { recursive: true });
copyDirectoryContents(path.join(nginxSeedDir, 'includes'), includesDir);
copyDirectoryContents(upstreamNginxIncludes, includesDir);

const templateCandidates = [
	path.join(nginxSeedDir, 'ds.conf.tmpl'),
	path.join(nginxSeedDir, 'ds.conf'),
];
const documentServerTemplate = templateCandidates.find((candidate) => fs.existsSync(candidate));
if (!documentServerTemplate) fail('The official ONLYOFFICE Nginx virtual-host template is missing.');

let documentServerConfig = fs.readFileSync(documentServerTemplate, 'utf8');
for (const sourceIncludes of [
	'/etc/nginx/includes',
	'/etc/onlyoffice/documentserver/nginx/includes',
]) {
	documentServerConfig = replaceAllLiteral(documentServerConfig, sourceIncludes, includesDir);
}
documentServerConfig = documentServerConfig
	.replace(/listen\s+0\.0\.0\.0:\d+\s*;/gu, `listen 0.0.0.0:${port};`)
	.replace(/listen\s+\[::\]:\d+([^;]*)\s*;/gu, `listen [::]:${port}$1;`)
	.replace(/listen\s+\d+\s*;/gu, `listen ${port};`)
	.replace(/set\s+\$secure_link_secret\s+[^;]+;/gu, `set $secure_link_secret "${secureLinkSecret}";`);
if (!fs.existsSync('/proc/net/if_inet6')) {
	documentServerConfig = documentServerConfig.replace(/^\s*listen\s+\[::\].*;\s*$/gmu, '');
}
writeFileAtomically(path.join(nginxDir, 'ds.conf'), documentServerConfig, 0o600);

const httpCommonTemplate = fs.readFileSync(
	path.join(imageRuntimeRoot, 'nginx', 'http-common.conf.tmpl'),
	'utf8',
);
writeFileAtomically(path.join(includesDir, 'http-common.conf'), httpCommonTemplate, 0o644);

const commonIncludePath = path.join(includesDir, 'ds-common.conf');
if (!fs.existsSync(commonIncludePath)) fail('The official ds-common.conf include is missing.');
let commonInclude = fs.readFileSync(commonIncludePath, 'utf8');
commonInclude = commonInclude
	.replace(/client_max_body_size\s+[^;]+;/gu, `client_max_body_size ${uploadLimit};`)
	.replace(/error_log\s+[^;]+;/gu, `error_log ${path.join(logDir, 'nginx-error.log')} warn;`)
	.replace(
		/access_log\s+[^;]+;/gu,
		booleanEnvironment('NGINX_ACCESS_LOG', false)
			? `access_log ${path.join(logDir, 'nginx-access.log')} onlyoffice;`
			: 'access_log off;',
	);
writeFileAtomically(commonIncludePath, commonInclude, 0o644);

let nginxConfig = fs.readFileSync(path.join(imageRuntimeRoot, 'nginx', 'nginx.conf.tmpl'), 'utf8');
const replacements = new Map([
	['__WORKER_PROCESSES__', String(workerProcesses)],
	['__WORKER_CONNECTIONS__', String(workerConnections)],
	['__LOG_DIR__', logDir],
	['__TMP_DIR__', tmpDir],
	['__NGINX_DIR__', nginxDir],
]);
for (const [token, value] of replacements) nginxConfig = replaceAllLiteral(nginxConfig, token, value);
writeFileAtomically(path.join(nginxDir, 'nginx.conf'), nginxConfig, 0o600);

process.stdout.write(`[ONLYOFFICE] Runtime configuration rendered for allocation port ${port}.\n`);
