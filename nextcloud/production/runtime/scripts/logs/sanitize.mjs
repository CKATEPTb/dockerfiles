const ansiPattern = /\u001b(?:\[[0-?]*[ -/]*[@-~]|\][^\u0007]*(?:\u0007|\u001b\\))/g
const controlPattern = /[\u0000-\u001f\u007f-\u009f]/g

export function cleanText(value, maximumLength = 180) {
	if (value === undefined || value === null || value === false) return '-'
	let text = typeof value === 'string' ? value : JSON.stringify(value)
	text = text
		.replace(ansiPattern, '')
		.replace(/[\r\n\t]+/g, ' ')
		.replace(controlPattern, '')
		.replace(/\s+/g, ' ')
		.trim()
	if (!text || text === '-') return '-'
	return text.length > maximumLength ? `${text.slice(0, maximumLength - 1)}…` : text
}

export function sanitizePath(value) {
	let path = cleanText(value, 512)
	if (path === '-') return path
	path = path.split(/[?#]/, 1)[0]
	path = path
		.replace(/^(\/s\/)[^/]+/i, '$1[token]')
		.replace(/^(\/public\.php\/dav\/files\/)[^/]+/i, '$1[token]')
		.replace(/^(\/\.well-known\/acme-challenge\/)[^/]+/i, '$1[token]')
		.replace(/([/&](?:token|shareToken|requesttoken|uploadId)=)[^/&]+/gi, '$1[token]')
	return cleanText(path, 180)
}

export function sanitizeReferrer(value) {
	const source = cleanText(value, 1024)
	if (source === '-') return '-'
	try {
		const parsed = new URL(source)
		if (!['http:', 'https:'].includes(parsed.protocol)) return '-'
		parsed.username = ''
		parsed.password = ''
		parsed.search = ''
		parsed.hash = ''
		parsed.pathname = sanitizePath(parsed.pathname)
		return cleanText(parsed.toString(), 220)
	} catch {
		return '-'
	}
}

export function sanitizeMessage(value) {
	return cleanText(value, 512)
		.replace(/("(?:GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|PROPFIND|REPORT|MKCOL|MOVE|COPY)\s+[^?\s"]+)\?[^\s"]+/gi, '$1?[redacted]')
		.replace(/(https?:\/\/[^?\s#]+)\?[^\s#]+/gi, '$1?[redacted]')
		.replace(/([?&](?:token|requesttoken|password|secret|key|shareToken)=)[^&\s]+/gi, '$1[redacted]')
		.replace(/(\/s\/)[^/\s]+/gi, '$1[token]')
		.replace(/(\/public\.php\/dav\/files\/)[^/\s]+/gi, '$1[token]')
}

export function isExternalReferrer(referrer, host) {
	if (referrer === '-') return false
	try {
		return new URL(referrer).host.toLowerCase() !== cleanText(host).toLowerCase()
	} catch {
		return false
	}
}

export function describeUserAgent(value) {
	const userAgent = cleanText(value, 256)
	if (userAgent === '-') return '-'
	if (/Nextcloud-Talk/i.test(userAgent)) return 'Nextcloud Talk'
	if (/Nextcloud/i.test(userAgent)) return 'Nextcloud client'
	if (/Edg\//i.test(userAgent)) return 'Edge'
	if (/Firefox\//i.test(userAgent)) return 'Firefox'
	if (/(?:Chrome|Chromium)\//i.test(userAgent)) return 'Chrome'
	if (/Safari\//i.test(userAgent)) return 'Safari'
	if (/curl\//i.test(userAgent)) return 'curl'
	if (/WebDAV|davfs|Cyberduck/i.test(userAgent)) return 'WebDAV client'
	return cleanText(userAgent, 48)
}

export function formatField(value) {
	const text = cleanText(value)
	return /^[A-Za-z0-9_.:@/+\-[\]]+$/.test(text) ? text : JSON.stringify(text)
}

export function formatBytes(value) {
	let bytes = Number(value)
	if (!Number.isFinite(bytes) || bytes < 0) bytes = 0
	const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB']
	let unit = 0
	while (bytes >= 1024 && unit < units.length - 1) {
		bytes /= 1024
		unit += 1
	}
	return `${unit === 0 ? Math.round(bytes) : bytes.toFixed(1)}${units[unit]}`
}
