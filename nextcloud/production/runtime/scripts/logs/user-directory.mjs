import { execFile } from 'node:child_process'
import { cleanText } from './sanitize.mjs'

function runFile(command, arguments_, options) {
	return new Promise(resolve => {
		execFile(command, arguments_, options, (error, stdout) => {
			resolve({
				status: error ? (Number.isInteger(error.code) ? error.code : null) : 0,
				stdout: stdout ?? '',
			})
		})
	})
}

export class UserDirectory {
	constructor(options = {}) {
		this.php = options.php ?? process.env.PHP_CLI_BIN ?? 'php8.4'
		this.phpIni = options.phpIni ?? '/home/container/php/php.ini'
		this.scanDirectory = options.scanDirectory ?? process.env.PHP_CLI_SCAN_DIR ?? ''
		this.webRoot = options.webRoot ?? '/home/container/www'
		this.now = options.now ?? (() => Date.now())
		this.runner = options.runner ?? runFile
		this.cache = new Map()
		this.pending = new Map()
		this.queue = []
		this.active = 0
		this.cacheTtl = options.cacheTtl ?? 300_000
		this.concurrency = options.concurrency ?? 2
		this.maximumQueue = options.maximumQueue ?? 500
	}

	emailFor(userId) {
		const uid = cleanText(userId, 128)
		if (uid === '-') return Promise.resolve('-')
		const cached = this.cache.get(uid)
		if (cached && cached.expires > this.now()) return Promise.resolve(cached.email)
		if (this.pending.has(uid)) return this.pending.get(uid)
		if (this.queue.length >= this.maximumQueue) return Promise.resolve('-')

		const result = new Promise(resolve => this.queue.push({ uid, resolve }))
		this.pending.set(uid, result)
		this.drain()
		return result
	}

	drain() {
		while (this.active < this.concurrency && this.queue.length > 0) {
			const entry = this.queue.shift()
			this.active += 1
			void this.resolveEntry(entry)
		}
	}

	async resolveEntry(entry) {
		let email = '-'
		try {
			email = await this.lookup(entry.uid)
		} catch {
			email = '-'
		}

		if (this.cache.size >= 1_000) this.cache.delete(this.cache.keys().next().value)
		this.cache.set(entry.uid, { email, expires: this.now() + this.cacheTtl })
		this.pending.delete(entry.uid)
		this.active -= 1
		entry.resolve(email)
		this.drain()
	}

	async lookup(uid) {
		const result = await this.runner(this.php, [
			'-c', this.phpIni,
			'-f', 'occ', '--',
			'user:info', '--output=json', '--no-ansi', '--no-interaction', '--', uid,
		], {
			cwd: this.webRoot,
			env: { ...process.env, PHP_INI_SCAN_DIR: this.scanDirectory },
			encoding: 'utf8',
			timeout: 5_000,
			killSignal: 'SIGKILL',
			maxBuffer: 1024 * 1024,
			windowsHide: true,
			shell: false,
		})
		if (result.status !== 0 || !result.stdout) return '-'
		try {
			const information = JSON.parse(result.stdout)
			return cleanText(information.email, 254)
		} catch {
			return '-'
		}
	}
}
