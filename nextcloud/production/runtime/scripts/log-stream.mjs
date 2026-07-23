import { readFile, rename, rm, stat } from 'node:fs/promises'
import { EventAggregator } from './logs/event-aggregator.mjs'
import { FileTail } from './logs/file-tail.mjs'
import { cleanText } from './logs/sanitize.mjs'
import { TrustedProxyResolver } from './logs/trusted-proxy.mjs'
import { UserDirectory } from './logs/user-directory.mjs'

const logDirectory = '/home/container/logs'
const maximumNginxLogSize = 100 * 1024 * 1024
const activityEnabled = /^(?:1|true|yes|on)$/i.test(process.env.CONSOLE_ACTIVITY_LOGS ?? 'true')
const aggregator = new EventAggregator({
	userDirectory: new UserDirectory(),
	proxyResolver: new TrustedProxyResolver(process.env.TRUSTED_PROXIES),
})

const sourceFiles = [
	['nginx', `${logDirectory}/nginx-access.log`],
	['nginxError', `${logDirectory}/nginx-error.log`],
	['nextcloud', `${logDirectory}/nextcloud.log`],
	['audit', `${logDirectory}/audit.log`],
]

const tails = new Map((activityEnabled ? sourceFiles : []).map(([source, file]) => [
	file,
	new FileTail(file, line => aggregator.ingest(source, line), {
		onError: error => aggregator.emit('LOG', 'TAIL_ERROR', { source, message: cleanText(error.message) }),
	}),
]))

async function rotateNginxLog(file) {
	let information
	let currentWasMoved = false
	try {
		information = await stat(file)
	} catch (error) {
		if (error.code === 'ENOENT') return
		throw error
	}
	if (information.size < maximumNginxLogSize) return

	await tails.get(file)?.poll()
	await rm(`${file}.3`, { force: true })
	try { await rename(`${file}.2`, `${file}.3`) } catch (error) { if (error.code !== 'ENOENT') throw error }
	try { await rename(`${file}.1`, `${file}.2`) } catch (error) { if (error.code !== 'ENOENT') throw error }
	await rename(file, `${file}.1`)
	currentWasMoved = true

	try {
		const pid = Number.parseInt(await readFile('/home/container/tmp/nginx.pid', 'utf8'), 10)
		if (!Number.isInteger(pid) || pid <= 1) throw new Error('Nginx PID is invalid after log rotation')
		process.kill(pid, 'SIGUSR1')
	} catch (error) {
		if (currentWasMoved) {
			try { await rename(`${file}.1`, file) } catch { /* Preserve the original rotation error. */ }
		}
		throw error
	}
	aggregator.emit('LOG', 'ROTATED', { file: file.split('/').pop(), size: information.size })
}

for (const tail of tails.values()) tail.start()
if (activityEnabled) {
	aggregator.emit('LOG', 'READY', { sources: 'nginx,nextcloud,audit', grouping: '15s' })
}

const tickTimer = activityEnabled ? setInterval(() => aggregator.tick(), 500) : null
const rotationTimer = setInterval(() => {
	for (const file of [`${logDirectory}/nginx-access.log`, `${logDirectory}/nginx-error.log`]) {
		void rotateNginxLog(file).catch(error => {
			aggregator.emit('LOG', 'ROTATE_ERROR', { file: file.split('/').pop(), message: cleanText(error.message) })
		})
	}
}, 60_000)

let stopping = false
async function shutdown() {
	if (stopping) return
	stopping = true
	if (tickTimer) clearInterval(tickTimer)
	clearInterval(rotationTimer)
	await Promise.all([...tails.values()].map(tail => tail.stop().catch(() => {})))
	await aggregator.shutdown()
}

process.once('SIGINT', () => void shutdown().finally(() => process.exit(0)))
process.once('SIGTERM', () => void shutdown().finally(() => process.exit(0)))
process.on('uncaughtException', error => {
	aggregator.emit('LOG', 'FATAL', { message: cleanText(error.stack ?? error.message) })
	void shutdown().finally(() => process.exit(1))
})
process.on('unhandledRejection', error => {
	aggregator.emit('LOG', 'FATAL', { message: cleanText(error?.stack ?? error) })
	void shutdown().finally(() => process.exit(1))
})
