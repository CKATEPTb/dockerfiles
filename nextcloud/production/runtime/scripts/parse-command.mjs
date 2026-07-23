import { fileURLToPath } from 'node:url'
import path from 'node:path'

export function parseCommandLine(line) {
	const arguments_ = []
	let current = ''
	let quote = ''
	let escaping = false
	let started = false

	for (const character of String(line)) {
		if (escaping) {
			current += character
			escaping = false
			started = true
			continue
		}
		if (character === '\\' && quote !== "'") {
			escaping = true
			started = true
			continue
		}
		if (quote) {
			if (character === quote) quote = ''
			else current += character
			started = true
			continue
		}
		if (character === "'" || character === '"') {
			quote = character
			started = true
			continue
		}
		if (/\s/u.test(character)) {
			if (started) {
				arguments_.push(current)
				current = ''
				started = false
			}
			continue
		}
		current += character
		started = true
	}

	if (escaping) throw new Error('Command ends with an unfinished escape')
	if (quote) throw new Error(`Command contains an unmatched ${quote} quote`)
	if (started) arguments_.push(current)
	return arguments_
}

async function run() {
	let input = ''
	for await (const chunk of process.stdin) input += chunk
	const arguments_ = parseCommandLine(input)
	if (arguments_.length > 0) process.stdout.write(`${arguments_.join('\0')}\0`)
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
	run().catch(error => {
		console.error(`[Nextcloud] ERROR: ${error.message}`)
		process.exitCode = 2
	})
}
