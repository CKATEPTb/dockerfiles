import { open, stat } from 'node:fs/promises'
import { StringDecoder } from 'node:string_decoder'

export class FileTail {
	constructor(file, onLine, options = {}) {
		this.file = file
		this.onLine = onLine
		this.interval = options.interval ?? 500
		this.fromEnd = options.fromEnd ?? true
		this.onError = options.onError ?? (() => {})
		this.position = 0
		this.identity = null
		this.lastModified = 0
		this.hasSeenFile = false
		this.initialCheckCompleted = false
		this.remainder = ''
		this.decoder = new StringDecoder('utf8')
		this.timer = null
		this.polling = false
	}

	start() {
		if (this.timer) return
		void this.poll().catch(error => this.onError(error))
		this.timer = setInterval(() => void this.poll().catch(error => this.onError(error)), this.interval)
		this.timer.unref?.()
	}

	async stop() {
		if (this.timer) clearInterval(this.timer)
		this.timer = null
		while (this.polling) await new Promise(resolve => setTimeout(resolve, 10))
		await this.poll()
	}

	async poll() {
		if (this.polling) return
		this.polling = true
		try {
			let information
			try {
				information = await stat(this.file)
			} catch (error) {
				if (error.code === 'ENOENT') {
					this.identity = null
					this.lastModified = 0
					this.initialCheckCompleted = true
					return
				}
				throw error
			}

			const identity = `${information.dev}:${information.ino}`
			const identityChanged = identity !== this.identity
			if (identityChanged) {
				this.position = !this.hasSeenFile && !this.initialCheckCompleted && this.fromEnd ? information.size : 0
				this.identity = identity
				this.hasSeenFile = true
				this.initialCheckCompleted = true
				this.remainder = ''
				this.decoder = new StringDecoder('utf8')
			}
			if (information.size < this.position) {
				this.position = 0
				this.remainder = ''
				this.decoder = new StringDecoder('utf8')
			}
			if (!identityChanged && information.size === this.position && information.mtimeMs > this.lastModified) {
				this.position = 0
				this.remainder = ''
				this.decoder = new StringDecoder('utf8')
			}
			this.lastModified = information.mtimeMs
			if (information.size === this.position) return

			const handle = await open(this.file, 'r')
			try {
				while (this.position < information.size) {
					const length = Math.min(1024 * 1024, information.size - this.position)
					const buffer = Buffer.allocUnsafe(length)
					const { bytesRead } = await handle.read(buffer, 0, length, this.position)
					if (bytesRead === 0) break
					this.position += bytesRead
					this.consume(this.decoder.write(buffer.subarray(0, bytesRead)))
				}
			} finally {
				await handle.close()
			}
		} finally {
			this.polling = false
		}
	}

	consume(chunk) {
		const lines = `${this.remainder}${chunk}`.split('\n')
		this.remainder = lines.pop() ?? ''
		for (const line of lines) {
			const normalized = line.endsWith('\r') ? line.slice(0, -1) : line
			if (normalized) this.onLine(normalized)
		}
	}
}
