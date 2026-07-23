#!/usr/bin/env node

import { existsSync } from 'node:fs';
import { readdir, readFile, stat } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const EGG_FILE = 'egg-onlyoffice-documents.json';
const DOCKERFILE = 'Dockerfile';
const IMAGE = 'ghcr.io/ckateptb/dockerfiles:onlyoffice_documents';
const STARTUP = 'bash /opt/onlyoffice-egg/runtime/start.sh';
const STARTUP_MARKER = 'ONLYOFFICE Docs successfully launched.';
const STOP_SIGNAL = '^C';
const INSTALLER = '/opt/onlyoffice-egg/install.sh';
const REQUIRED_FILES = [
	DOCKERFILE,
	EGG_FILE,
	'IMAGE_API_VERSION',
	'entrypoint.sh',
	'install.sh',
	'runtime/scripts/start.sh',
	'runtime/scripts/configure.mjs',
	'runtime/scripts/lib/common.sh',
	'runtime/scripts/lib/console.sh',
	'runtime/scripts/lib/services.sh',
	'runtime/nginx/nginx.conf.tmpl',
	'runtime/nginx/http-common.conf.tmpl',
];

const failures = [];
let assertions = 0;

function check(condition, message) {
	assertions += 1;
	if (!condition) {
		failures.push(message);
	}
}

function isPlainObject(value) {
	return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function parseJson(text, label) {
	try {
		return JSON.parse(text);
	} catch (error) {
		failures.push(`${label} is not valid JSON: ${error.message}`);
		return undefined;
	}
}

async function readText(relativePath) {
	return readFile(path.join(ROOT, relativePath), 'utf8');
}

async function walkFiles(directory = ROOT) {
	const files = [];
	const entries = await readdir(directory, { withFileTypes: true });

	for (const entry of entries) {
		if (entry.name === '.git' || entry.name === 'node_modules') {
			continue;
		}

		const absolutePath = path.join(directory, entry.name);
		if (entry.isDirectory()) {
			files.push(...await walkFiles(absolutePath));
		} else if (entry.isFile()) {
			files.push(absolutePath);
		}
	}

	return files;
}

function variableByName(egg, name) {
	return egg.variables.find((variable) => variable.env_variable === name);
}

function hasRule(variable, rule) {
	return String(variable?.rules ?? '')
		.split('|')
		.map((item) => item.trim())
		.includes(rule);
}

function isFalseDefault(value) {
	return ['0', 'false', 'no', 'off'].includes(String(value).trim().toLowerCase());
}

function unquote(value) {
	const trimmed = value.trim();
	if ((trimmed.startsWith('"') && trimmed.endsWith('"'))
		|| (trimmed.startsWith("'") && trimmed.endsWith("'"))) {
		return trimmed.slice(1, -1);
	}
	return trimmed;
}

function expandBuildArgs(value, buildArgs) {
	return value.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)/g,
		(_match, bracedName, plainName) => buildArgs.get(bracedName ?? plainName) ?? _match);
}

function validateEgg(egg) {
	if (!isPlainObject(egg)) {
		return;
	}

	check(egg.meta?.version === 'PTDL_v2', `${EGG_FILE}: meta.version must be PTDL_v2`);
	check(isPlainObject(egg.docker_images), `${EGG_FILE}: docker_images must be an object`);

	const images = isPlainObject(egg.docker_images) ? Object.entries(egg.docker_images) : [];
	check(images.length === 1, `${EGG_FILE}: exactly one runtime Docker image must be declared`);
	check(images[0]?.[0] === IMAGE && images[0]?.[1] === IMAGE,
		`${EGG_FILE}: runtime Docker image key and value must both equal ${IMAGE}`);
	check(egg.scripts?.installation?.container === IMAGE,
		`${EGG_FILE}: installer Docker image must equal ${IMAGE}`);
	check(egg.scripts?.installation?.container === images[0]?.[1],
		`${EGG_FILE}: installer and runtime must use the exact same Docker image`);

	check(egg.startup === STARTUP, `${EGG_FILE}: startup must be exactly ${STARTUP}`);
	check(egg.config?.stop === STOP_SIGNAL, `${EGG_FILE}: config.stop must be ${STOP_SIGNAL}`);
	check(egg.scripts?.installation?.entrypoint === 'bash',
		`${EGG_FILE}: installer entrypoint must be bash`);
	check(String(egg.scripts?.installation?.script ?? '').includes(INSTALLER),
		`${EGG_FILE}: installer script must delegate to ${INSTALLER}`);

	const startupConfig = typeof egg.config?.startup === 'string'
		? parseJson(egg.config.startup, `${EGG_FILE}: config.startup`)
		: egg.config?.startup;
	check(startupConfig?.done === STARTUP_MARKER,
		`${EGG_FILE}: startup done marker must be exactly "${STARTUP_MARKER}"`);

	for (const field of ['files', 'logs']) {
		const value = egg.config?.[field];
		if (typeof value === 'string') {
			const parsedValue = parseJson(value, `${EGG_FILE}: config.${field}`);
			if (parsedValue !== undefined) {
				check(isPlainObject(parsedValue),
					`${EGG_FILE}: config.${field} must encode a JSON object`);
			}
		} else {
			check(isPlainObject(value), `${EGG_FILE}: config.${field} must be an object or encoded JSON object`);
		}
	}

	check(Array.isArray(egg.variables), `${EGG_FILE}: variables must be an array`);
	if (!Array.isArray(egg.variables)) {
		return;
	}

	const variableNames = egg.variables.map((variable) => variable.env_variable);
	check(variableNames.every((name) => typeof name === 'string' && name.length > 0),
		`${EGG_FILE}: every variable must have a non-empty env_variable`);
	check(new Set(variableNames).size === variableNames.length,
		`${EGG_FILE}: env_variable names must be unique`);

	const addressVariables = egg.variables.filter((variable) => {
		const label = `${variable.env_variable ?? ''} ${variable.name ?? ''}`;
		return /(?:^|[_\s-])(?:URL|DOMAIN|HOST(?:NAME)?)(?:$|[_\s-])/i.test(label);
	});
	for (const variable of addressVariables) {
		check(!hasRule(variable, 'required'),
			`${EGG_FILE}: ${variable.env_variable} must not make a URL/domain mandatory`);
		check(String(variable.default_value ?? '') === '',
			`${EGG_FILE}: optional URL/domain ${variable.env_variable} must default to empty`);
	}

	const forbiddenNetworkVariables = egg.variables.filter((variable) =>
		/(?:^|_)(?:UDP|ALLOCATION|PORT)(?:_|$)/i.test(variable.env_variable ?? ''));
	check(forbiddenNetworkVariables.length === 0,
		`${EGG_FILE}: extra allocation/UDP variables are not allowed (${forbiddenNetworkVariables.map((item) => item.env_variable).join(', ')})`);
	for (const key of ['allocations', 'additional_allocations', 'ports']) {
		check(!(key in egg), `${EGG_FILE}: top-level ${key} is not allowed; use only the primary allocation`);
	}

	const serializedEgg = JSON.stringify(egg);
	check(!/\/udp\b/i.test(serializedEgg), `${EGG_FILE}: UDP exposure is not allowed`);
	check(!/SERVER_PORT_(?:\d+|[A-Z][A-Z0-9_]*)/i.test(serializedEgg),
		`${EGG_FILE}: only the primary SERVER_PORT allocation may be referenced`);

	const jwtSecret = variableByName(egg, 'JWT_SECRET');
	check(Boolean(jwtSecret), `${EGG_FILE}: JWT_SECRET variable is required`);
	if (jwtSecret) {
		check(String(jwtSecret.default_value ?? '') === '',
			`${EGG_FILE}: JWT_SECRET must default to empty so runtime generates it securely`);
		check(!hasRule(jwtSecret, 'required') && hasRule(jwtSecret, 'nullable'),
			`${EGG_FILE}: JWT_SECRET must be nullable and not required`);
		check(/(?:^|\|)min:(?:3[2-9]|[4-9]\d|[1-9]\d{2,})(?:\||$)/.test(String(jwtSecret.rules ?? '')),
			`${EGG_FILE}: JWT_SECRET must require at least 32 characters when supplied`);
	}

	const jwtHeader = variableByName(egg, 'JWT_HEADER');
	check(Boolean(jwtHeader), `${EGG_FILE}: JWT_HEADER variable is required`);
	if (jwtHeader) {
		check(jwtHeader.default_value === 'Authorization',
			`${EGG_FILE}: JWT_HEADER must default to Authorization`);
	}

	for (const name of ['ALLOW_PRIVATE_IP_ADDRESS', 'USE_UNAUTHORIZED_STORAGE']) {
		const variable = variableByName(egg, name);
		check(Boolean(variable), `${EGG_FILE}: ${name} variable is required`);
		if (variable) {
			check(isFalseDefault(variable.default_value),
				`${EGG_FILE}: ${name} must have a safe disabled default`);
		}
	}

	const metadataAccess = variableByName(egg, 'ALLOW_META_IP_ADDRESS');
	check(!metadataAccess || (isFalseDefault(metadataAccess.default_value) && !metadataAccess.user_editable),
		`${EGG_FILE}: metadata IP access must be absent or fixed to disabled`);
}

function validateDockerfile(dockerfile) {
	const significantLines = dockerfile
		.split(/\r?\n/)
		.map((line) => line.replace(/\s+#.*$/, '').trim())
		.filter((line) => line.length > 0 && !line.startsWith('#'));
	const buildArgs = new Map();
	for (const line of significantLines) {
		const match = line.match(/^ARG\s+([A-Za-z_][A-Za-z0-9_]*)(?:=(.*))?$/i);
		if (match?.[2] !== undefined) {
			buildArgs.set(match[1], unquote(match[2]));
		}
	}

	const fromLines = significantLines.filter((line) => /^FROM\s+/i.test(line));
	const finalFrom = fromLines.at(-1) ?? '';
	const officialImages = fromLines
		.map((line) => line.match(/^FROM\s+(?:--platform=\S+\s+)?(\S+)/i)?.[1])
		.filter(Boolean)
		.map((image) => expandBuildArgs(image, buildArgs))
		.filter((image) => /^onlyoffice\/documentserver(?::|@|$)/i.test(image));
	const pinnedOfficialImage = /^onlyoffice\/documentserver:[A-Za-z0-9._-]+@sha256:[a-f0-9]{64}$/i;
	const finalFromIndex = dockerfile.toLowerCase().lastIndexOf(finalFrom.toLowerCase());
	const finalStage = finalFromIndex >= 0 ? dockerfile.slice(finalFromIndex) : '';

	check(officialImages.length >= 1,
		`${DOCKERFILE}: an official onlyoffice/documentserver build stage is required`);
	check(officialImages.length >= 1 && officialImages.every((image) => pinnedOfficialImage.test(image)),
		`${DOCKERFILE}: official onlyoffice/documentserver base must use an exact tag and sha256 digest`);
	check(/^FROM\s+scratch(?:\s+AS\s+[A-Za-z0-9._-]+)?$/i.test(finalFrom),
		`${DOCKERFILE}: final stage must be FROM scratch to clear inherited image metadata`);
	check(/^COPY\s+(?:--[^\s]+\s+)*--from=[^\s]+\s+\/\s+\/$/im.test(finalStage),
		`${DOCKERFILE}: scratch final stage must copy the complete root filesystem from a prior stage`);
	check(!/^VOLUME(?:\s|\[)/im.test(dockerfile),
		`${DOCKERFILE}: VOLUME instructions are forbidden; Pterodactyl owns persistence`);
	check(!/^EXPOSE\s+.*\/udp\b/im.test(dockerfile), `${DOCKERFILE}: UDP ports must not be exposed`);

	const exposeLines = significantLines.filter((line) => /^EXPOSE\s+/i.test(line));
	const exposedPorts = exposeLines.flatMap((line) => line
		.replace(/^EXPOSE\s+/i, '')
		.split(/\s+/)
		.map((entry) => entry.replace(/\/tcp$/i, ''))
		.filter(Boolean));
	check(new Set(exposedPorts).size <= 1,
		`${DOCKERFILE}: at most one public HTTP port may be exposed`);
}

function validateRuntimeSecurity(configureScript) {
	const requiredDefaults = [
		[/\bconst\s+JWT_ENABLED\s*=\s*true\s*;/, 'JWT must always be enabled'],
		[/\bconst\s+JWT_IN_BODY\s*=\s*false\s*;/, 'JWT tokens in request bodies must stay disabled'],
		[/\bconst\s+ALLOW_META_IP_ADDRESS\s*=\s*false\s*;/, 'metadata IP access must stay disabled'],
		[/booleanEnvironment\(\s*['"]ALLOW_PRIVATE_IP_ADDRESS['"]\s*,\s*false\s*\)/,
			'private storage addresses must default to disabled'],
		[/booleanEnvironment\(\s*['"]USE_UNAUTHORIZED_STORAGE['"]\s*,\s*false\s*\)/,
			'unauthorized storage TLS must default to disabled'],
		[/process\.env\.JWT_HEADER\s*\|\|\s*['"]Authorization['"]/,
			'JWT_HEADER must default to Authorization at runtime'],
	];

	for (const [pattern, description] of requiredDefaults) {
		check(pattern.test(configureScript), `runtime/scripts/configure.mjs: ${description}`);
	}
}

async function validateRequiredFiles() {
	for (const relativePath of REQUIRED_FILES) {
		const absolutePath = path.join(ROOT, relativePath);
		check(existsSync(absolutePath), `missing required file: ${relativePath}`);
		if (existsSync(absolutePath)) {
			const details = await stat(absolutePath);
			check(details.isFile() && details.size > 0, `required file is empty or not a file: ${relativePath}`);
		}
	}
}

async function validateJsonFiles(files) {
	const parsedFiles = new Map();
	for (const absolutePath of files.filter((file) => file.endsWith('.json'))) {
		const relativePath = path.relative(ROOT, absolutePath).replaceAll(path.sep, '/');
		parsedFiles.set(absolutePath, parseJson(await readFile(absolutePath, 'utf8'), relativePath));
	}
	return parsedFiles;
}

function validateShellScripts(files) {
	const scripts = files.filter((file) => file.endsWith('.sh'));
	if (scripts.length === 0) {
		failures.push('no .sh files found for bash syntax validation');
		return;
	}

	const bashCandidates = ['bash'];
	if (process.platform === 'win32') {
		for (const programFiles of [process.env.ProgramFiles, process.env['ProgramFiles(x86)']]) {
			if (programFiles) bashCandidates.push(path.join(programFiles, 'Git', 'bin', 'bash.exe'));
		}
	}
	const bash = bashCandidates.find((candidate) => {
		const probe = spawnSync(candidate, ['--version'], {
			cwd: ROOT,
			encoding: 'utf8',
			windowsHide: true,
		});
		return !probe.error && probe.status === 0;
	});
	if (!bash) {
		console.warn('[check] bash is unavailable; skipped bash -n syntax checks');
		return;
	}

	for (const absolutePath of scripts) {
		const relativePath = path.relative(ROOT, absolutePath).replaceAll(path.sep, '/');
		const result = spawnSync(bash, ['-n', relativePath], {
			cwd: ROOT,
			encoding: 'utf8',
			windowsHide: true,
		});
		check(!result.error && result.status === 0,
			`${relativePath}: bash -n failed: ${(result.error?.message ?? result.stderr).trim()}`);
	}
}

function validateNodeScripts(files) {
	for (const absolutePath of files.filter((file) => file.endsWith('.mjs'))) {
		const relativePath = path.relative(ROOT, absolutePath).replaceAll(path.sep, '/');
		const result = spawnSync(process.execPath, ['--check', relativePath], {
			cwd: ROOT,
			encoding: 'utf8',
			windowsHide: true,
		});
		check(!result.error && result.status === 0,
			`${relativePath}: node --check failed: ${(result.error?.message ?? result.stderr).trim()}`);
	}
}

async function main() {
	await validateRequiredFiles();
	const files = await walkFiles();
	const parsedJsonFiles = await validateJsonFiles(files);

	if (existsSync(path.join(ROOT, EGG_FILE))) {
		const egg = parsedJsonFiles.get(path.join(ROOT, EGG_FILE));
		if (egg !== undefined) {
			validateEgg(egg);
		}
	}

	if (existsSync(path.join(ROOT, DOCKERFILE))) {
		validateDockerfile(await readText(DOCKERFILE));
	}
	if (existsSync(path.join(ROOT, 'runtime/scripts/configure.mjs'))) {
		validateRuntimeSecurity(await readText('runtime/scripts/configure.mjs'));
	}

	validateShellScripts(files);
	validateNodeScripts(files);

	if (failures.length > 0) {
		console.error(`[check] FAILED: ${failures.length} problem(s) found`);
		for (const failure of failures) {
			console.error(`  - ${failure}`);
		}
		process.exitCode = 1;
		return;
	}

	console.log(`[check] OK: ${assertions} static assertions passed`);
}

await main();
