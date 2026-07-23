import { createHash } from 'node:crypto'
import { cleanText, describeUserAgent, formatBytes, formatField, isExternalReferrer, sanitizeMessage, sanitizePath, sanitizeReferrer } from './sanitize.mjs'
import { normalizeIp, TrustedProxyResolver } from './trusted-proxy.mjs'

const SUMMARY_WINDOW_MS = 15_000
const AUTH_CORRELATION_MS = 10_000
const LOGIN_DEDUPLICATION_MS = 60_000
const REFERRAL_TTL_MS = 10 * 60_000

function number(value) {
	const result = Number(value)
	return Number.isFinite(result) ? result : 0
}

function timestamp(value, fallback) {
	const parsed = Date.parse(String(value ?? ''))
	return Number.isFinite(parsed) ? parsed : fallback
}

function requestCategory(path) {
	if (/^\/(?:remote\.php\/(?:dav|webdav)|public\.php\/webdav|webdav)(?:\/|$)/i.test(path)) return 'dav'
	if (/^\/(?:ocs|ocs-provider)(?:\/|$)/i.test(path)) return 'ocs'
	if (/^\/whiteboard(?:\/|$)/i.test(path)) return 'whiteboard'
	if (/^\/(?:index\.php\/)?login(?:\/|$)/i.test(path)) return 'auth'
	if (/^\/(?:index\.php\/)?apps\/spreed(?:\/|$)/i.test(path)) return 'talk'
	if (/^\/(?:index\.php\/)?apps\/files(?:\/|$)/i.test(path)) return 'files'
	return 'web'
}

function safeRequestPath(path) {
	const sanitized = sanitizePath(path)
	return requestCategory(sanitized) === 'dav' ? 'dav' : sanitized
}

function statusFamily(status) {
	const normalized = Math.max(0, Math.trunc(number(status)))
	return normalized >= 100 && normalized <= 599 ? `${Math.trunc(normalized / 100)}xx` : 'other'
}

function auditUser(message, fallback) {
	const match = String(message ?? '').match(/^(?:Login successful|Login attempt): "([\s\S]*)"$/)
	return cleanText(match?.[1] ?? fallback, 128)
}

function failedLoginName(message) {
	const match = String(message ?? '').match(/^Login failed: "([\s\S]*)"$/)
	return cleanText(match?.[1], 128)
}

function auditAction(message) {
	const source = cleanText(message, 120)
	const separator = source.indexOf(':')
	return cleanText(separator > 0 ? source.slice(0, separator) : source, 48)
}

export class EventAggregator {
	constructor(options = {}) {
		this.write = options.write ?? (line => console.log(line))
		this.now = options.now ?? (() => Date.now())
		this.userDirectory = options.userDirectory ?? { emailFor: () => '-' }
		this.proxyResolver = options.proxyResolver ?? new TrustedProxyResolver(process.env.TRUSTED_PROXIES)
		this.summaryWindow = options.summaryWindow ?? SUMMARY_WINDOW_MS
		this.nextFlushAt = this.now() + this.summaryWindow
		this.requestContexts = new Map()
		this.recentRequests = []
		this.pendingAuth = []
		this.lastReferrals = new Map()
		this.recentLogins = new Map()
		this.recentVisits = new Map()
		this.loginReuse = new Map()
		this.authFailures = new Map()
		this.nextcloudRepeats = new Map()
		this.nginxRepeats = new Map()
		this.auditGroups = new Map()
		this.parseErrors = new Map()
		this.pendingTasks = new Set()
		this.web = this.emptyWebWindow()
	}

	emptyWebWindow() {
		return {
			requests: 0,
			bytes: 0,
			slow: 0,
			maximumDuration: 0,
			statuses: new Map(),
			categories: new Map(),
		}
	}

	emit(channel, event, fields = {}) {
		const details = Object.entries(fields)
			.filter(([, value]) => value !== undefined && value !== null && value !== '')
			.map(([key, value]) => `${key}=${formatField(value)}`)
			.join(' ')
		this.write(`[${channel.padEnd(5)}] ${event}${details ? ` ${details}` : ''}`)
	}

	ingest(source, line) {
		try {
			if (source === 'nginxError') {
				this.handleNginxError(line)
				return
			}
			const record = JSON.parse(line)
			if (source === 'nginx') this.handleNginx(record)
			if (source === 'nextcloud') this.handleNextcloud(record)
			if (source === 'audit') this.handleAudit(record)
		} catch {
			this.parseErrors.set(source, (this.parseErrors.get(source) ?? 0) + 1)
		}
	}

	handleNginx(record) {
		const now = this.now()
		const path = sanitizePath(record.uri)
		const category = requestCategory(path)
		const ip = this.proxyResolver.clientIp(record)
		const referrer = sanitizeReferrer(record.referer)
		const userAgent = cleanText(record.user_agent, 256)
		const requestTime = timestamp(record.time, now)
		const context = {
			id: cleanText(record.request_id, 128),
			at: requestTime,
			ip,
			host: cleanText(record.host, 255),
			method: cleanText(record.method, 16),
			path,
			category,
			referrer,
			userAgent,
			status: Math.trunc(number(record.status)),
		}

		if (context.id !== '-') this.requestContexts.set(context.id, context)
		this.recentRequests.push(context)
		this.resolveExactAuth(context)

		const referralKey = this.referralKey(ip, userAgent)
		if (isExternalReferrer(referrer, context.host)) {
			const previousReferral = this.lastReferrals.get(referralKey)
			this.lastReferrals.set(referralKey, {
				referrer,
				at: now,
				ambiguous: Boolean(previousReferral && (previousReferral.ambiguous || previousReferral.referrer !== referrer)),
			})
		}

		this.web.requests += 1
		this.web.bytes += number(record.bytes)
		const duration = number(record.duration)
		if (duration >= 5) this.web.slow += 1
		this.web.maximumDuration = Math.max(this.web.maximumDuration, duration)
		const family = statusFamily(context.status)
		this.web.statuses.set(family, (this.web.statuses.get(family) ?? 0) + 1)
		this.web.categories.set(category, (this.web.categories.get(category) ?? 0) + 1)

		const acceptsHtml = /text\/html/i.test(String(record.accept ?? ''))
		const isPage = ['GET', 'HEAD'].includes(context.method) && acceptsHtml && category !== 'dav'
		const visitKey = `${ip}|${context.host}`
		const lastVisit = this.recentVisits.get(visitKey) ?? 0
		const isExternalVisit = isExternalReferrer(referrer, context.host)
		const isDirectEntrance = referrer === '-' && /^\/(?:index\.php\/)?(?:login)?\/?$/i.test(path)
		if (isPage && (isExternalVisit || isDirectEntrance) && now - lastVisit >= LOGIN_DEDUPLICATION_MS) {
			this.recentVisits.set(visitKey, now)
			this.emit('WEB', 'VISIT', {
				ip,
				host: context.host,
				path: safeRequestPath(path),
				ref: isExternalVisit ? referrer : 'direct',
				client: describeUserAgent(userAgent),
			})
		}

		if (context.status >= 500) {
			this.emit('WEB', 'HTTP_ERROR', {
				status: context.status,
				ip,
				path: safeRequestPath(path),
				duration: `${duration.toFixed(3)}s`,
			})
		}

		this.prune(now)
	}

	handleNextcloud(record) {
		const level = Math.trunc(number(record.level))
		const levelName = ['DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL'][level] ?? `LEVEL_${level}`
		const message = sanitizeMessage(record.message)
		const fields = {
			level: levelName,
			app: cleanText(record.app, 64),
			user: cleanText(record.user, 128),
			ip: normalizeIp(record.remoteAddr) || '-',
			path: safeRequestPath(record.url),
			message,
		}
		const fingerprint = `${level}|${fields.app}|${message}`
		const previous = this.nextcloudRepeats.get(fingerprint)
		if (!previous) {
			this.nextcloudRepeats.set(fingerprint, { fields, repeats: 0, last: this.now() })
			this.emit('NC', 'LOG', fields)
		} else {
			previous.repeats += 1
			previous.last = this.now()
		}
	}

	handleAudit(record) {
		const message = String(record.message ?? '')
		if (message.startsWith('Login attempt:')) return

		let kind = ''
		let user = '-'
		if (message.startsWith('Login successful:')) {
			kind = 'success'
			user = auditUser(message, record.user)
		} else if (message.startsWith('Login failed:')) {
			kind = 'failure'
			user = failedLoginName(message)
		} else if (message === 'Logout occurred') {
			kind = 'logout'
			user = cleanText(record.user, 128)
		}

		if (!kind) {
			const group = `${cleanText(record.user, 128)}|${auditAction(message)}`
			const current = this.auditGroups.get(group) ?? {
				user: cleanText(record.user, 128),
				action: auditAction(message),
				count: 0,
			}
			current.count += 1
			this.auditGroups.set(group, current)
			return
		}

		const auth = {
			kind,
			user,
			at: timestamp(record.time, this.now()),
			correlationId: cleanText(record.clientReqId, 128),
			ip: normalizeIp(record.remoteAddr),
			userAgent: cleanText(record.userAgent, 256),
			expires: this.now() + AUTH_CORRELATION_MS,
		}
		const exact = auth.correlationId === '-' ? null : this.requestContexts.get(auth.correlationId)
		if (exact) {
			this.finalizeAuth(auth, exact)
		} else {
			this.pendingAuth.push(auth)
			if (this.pendingAuth.length > 2_000) {
				this.finalizeAuth(this.pendingAuth.shift(), null)
			}
		}
	}

	handleNginxError(line) {
		const message = sanitizeMessage(line)
		const fingerprint = message
			.replace(/\b\d{2,}\b/g, '#')
			.replace(/\[[^\]]+\]/g, '[context]')
		const previous = this.nginxRepeats.get(fingerprint)
		if (!previous) {
			this.nginxRepeats.set(fingerprint, { message, repeats: 0, last: this.now() })
			this.emit('NGINX', 'WARN', { message })
		} else {
			previous.repeats += 1
			previous.last = this.now()
		}
	}

	resolveExactAuth(context) {
		if (context.id === '-') return
		const remaining = []
		for (const auth of this.pendingAuth) {
			if (auth.correlationId === context.id) this.finalizeAuth(auth, context)
			else remaining.push(auth)
		}
		this.pendingAuth = remaining
	}

	fallbackContext(auth) {
		const candidates = this.recentRequests.filter(context => {
			if (context.category !== 'auth') return false
			if (Math.abs(context.at - auth.at) > AUTH_CORRELATION_MS) return false
			if (auth.ip && context.ip !== auth.ip) return false
			if (auth.userAgent !== '-' && context.userAgent !== '-' && context.userAgent !== auth.userAgent) return false
			return true
		})
		return candidates.length === 1 ? candidates[0] : null
	}

	finalizeAuth(auth, context) {
		const now = this.now()
		const ip = auth.ip || context?.ip || '-'
		const userAgent = auth.userAgent !== '-' ? auth.userAgent : context?.userAgent
		const referralKey = this.referralKey(ip, userAgent)
		const remembered = this.lastReferrals.get(referralKey)
		const exactReferral = context && isExternalReferrer(context.referrer, context.host) ? context.referrer : '-'
		const referrer = exactReferral !== '-'
			? exactReferral
			: remembered && !remembered.ambiguous && now - remembered.at <= REFERRAL_TTL_MS ? remembered.referrer : 'direct'

		if (auth.kind === 'success') {
			const key = `${auth.user}|${ip}|${describeUserAgent(userAgent)}`
			const previous = this.recentLogins.get(key) ?? 0
			this.recentLogins.set(key, now)
			if (now - previous < LOGIN_DEDUPLICATION_MS) {
				const reuse = this.loginReuse.get(key) ?? { user: auth.user, ip, count: 0 }
				reuse.count += 1
				this.loginReuse.set(key, reuse)
				return
			}
			const fields = {
				user: auth.user,
				ip,
				ref: referrer,
				client: describeUserAgent(userAgent),
			}
			const email = this.userDirectory.emailFor(auth.user)
			if (!email || typeof email.then !== 'function') {
				this.emit('AUTH', 'LOGIN_OK', { ...fields, email: email || '-' })
				return
			}
			const task = Promise.resolve(email)
				.catch(() => '-')
				.then(resolvedEmail => this.emit('AUTH', 'LOGIN_OK', { ...fields, email: resolvedEmail }))
			this.pendingTasks.add(task)
			task.then(
				() => this.pendingTasks.delete(task),
				() => this.pendingTasks.delete(task),
			)
			return
		}

		if (auth.kind === 'failure') {
			const key = `${auth.user}|${ip}`
			const failure = this.authFailures.get(key)
			if (failure) {
				failure.count += 1
				return
			}
			this.authFailures.set(key, { user: auth.user, ip, count: 1 })
			this.emit('AUTH', 'LOGIN_FAIL', {
				user: auth.user,
				ip,
				ref: referrer,
				client: describeUserAgent(userAgent),
			})
			return
		}

		this.emit('AUTH', 'LOGOUT', { user: auth.user, ip, client: describeUserAgent(userAgent) })
	}

	referralKey(ip, userAgent) {
		const fingerprint = createHash('sha256').update(cleanText(userAgent, 512)).digest('hex').slice(0, 16)
		return `${ip}|${fingerprint}`
	}

	prune(now = this.now()) {
		const cutoff = now - 30_000
		this.recentRequests = this.recentRequests.filter(context => context.at >= cutoff).slice(-500)
		for (const [id, context] of this.requestContexts) {
			if (context.at < cutoff) this.requestContexts.delete(id)
		}
		for (const [key, referral] of this.lastReferrals) {
			if (now - referral.at > REFERRAL_TTL_MS) this.lastReferrals.delete(key)
		}
		for (const [key, lastVisit] of this.recentVisits) {
			if (now - lastVisit > REFERRAL_TTL_MS) this.recentVisits.delete(key)
		}
		for (const [key, lastLogin] of this.recentLogins) {
			if (now - lastLogin > REFERRAL_TTL_MS) this.recentLogins.delete(key)
		}
		for (const [key, entry] of this.nextcloudRepeats) {
			if (now - entry.last > REFERRAL_TTL_MS) this.nextcloudRepeats.delete(key)
		}
		for (const [key, entry] of this.nginxRepeats) {
			if (now - entry.last > REFERRAL_TTL_MS) this.nginxRepeats.delete(key)
		}
		if (this.requestContexts.size > 2_000) {
			for (const key of [...this.requestContexts.keys()].slice(0, this.requestContexts.size - 2_000)) {
				this.requestContexts.delete(key)
			}
		}
	}

	tick(force = false) {
		const now = this.now()
		const remaining = []
		for (const auth of this.pendingAuth) {
			if (!force && auth.expires > now) {
				remaining.push(auth)
				continue
			}
			this.finalizeAuth(auth, this.fallbackContext(auth))
		}
		this.pendingAuth = remaining
		this.prune(now)
		if (force || now >= this.nextFlushAt) this.flush()
	}

	flush() {
		if (this.web.requests > 0) {
			const statuses = [...this.web.statuses.entries()].sort().map(([key, value]) => `${key}:${value}`).join(',')
			const top = [...this.web.categories.entries()].sort((a, b) => b[1] - a[1]).slice(0, 3).map(([key, value]) => `${key}:${value}`).join(',')
			this.emit('WEB', 'SUMMARY', {
				window: `${Math.round(this.summaryWindow / 1000)}s`,
				requests: this.web.requests,
				status: statuses,
				bytes: formatBytes(this.web.bytes),
				slow: this.web.slow,
				max: `${this.web.maximumDuration.toFixed(3)}s`,
				top,
			})
			this.web = this.emptyWebWindow()
		}

		for (const entry of this.nextcloudRepeats.values()) {
			if (entry.repeats > 0) this.emit('NC', 'REPEATED', { app: entry.fields.app, message: entry.fields.message, count: entry.repeats })
			entry.repeats = 0
		}
		for (const entry of this.nginxRepeats.values()) {
			if (entry.repeats > 0) this.emit('NGINX', 'REPEATED', { message: entry.message, count: entry.repeats })
			entry.repeats = 0
		}
		for (const entry of this.auditGroups.values()) {
			this.emit('AUDIT', 'ACTIVITY', { user: entry.user, action: entry.action, events: entry.count })
		}
		this.auditGroups.clear()

		for (const entry of this.loginReuse.values()) {
			this.emit('AUTH', 'REUSED', { user: entry.user, ip: entry.ip, events: entry.count })
		}
		this.loginReuse.clear()
		for (const entry of this.authFailures.values()) {
			if (entry.count > 1) this.emit('AUTH', 'LOGIN_FAIL_SUMMARY', { user: entry.user, ip: entry.ip, attempts: entry.count })
		}
		this.authFailures.clear()

		for (const [source, count] of this.parseErrors) {
			this.emit('LOG', 'PARSE_ERROR', { source, lines: count })
		}
		this.parseErrors.clear()
		this.nextFlushAt = this.now() + this.summaryWindow
	}

	async shutdown() {
		this.tick(true)
		await Promise.allSettled([...this.pendingTasks])
	}
}
