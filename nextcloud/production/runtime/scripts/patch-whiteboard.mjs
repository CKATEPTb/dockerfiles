import { readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const original = `\tget CORS_ORIGINS() {
\t\tconst fullUrl = new URL(this.NEXTCLOUD_URL)
\t\tconst baseOrigin = \`\${fullUrl.protocol}//\${fullUrl.host}\`
\t\tconst origins = [this.NEXTCLOUD_URL]

\t\tif (baseOrigin !== this.NEXTCLOUD_URL) {
\t\t\torigins.push(baseOrigin)
\t\t}

\t\treturn origins
\t},`

const replacement = `\tget CORS_ORIGINS() {
\t\tconst configuredOrigins = (process.env.CORS_ORIGINS || '')
\t\t\t.split(',')
\t\t\t.map(origin => origin.trim())
\t\t\t.filter(Boolean)

\t\tif (configuredOrigins.length > 0) {
\t\t\treturn [...new Set(configuredOrigins)]
\t\t}

\t\tconst fullUrl = new URL(this.NEXTCLOUD_URL)
\t\tconst baseOrigin = \`\${fullUrl.protocol}//\${fullUrl.host}\`
\t\tconst origins = [this.NEXTCLOUD_URL]

\t\tif (baseOrigin !== this.NEXTCLOUD_URL) {
\t\t\torigins.push(baseOrigin)
\t\t}

\t\treturn origins
\t},`

export function patchWhiteboardConfig(source) {
	const normalized = source.replace(/\r\n?/g, '\n')
	const occurrences = normalized.split(original).length - 1
	if (occurrences !== 1) throw new Error(`Expected one Whiteboard CORS block, found ${occurrences}`)
	return normalized.replace(original, replacement)
}

async function run(file) {
	const source = await readFile(file, 'utf8')
	await writeFile(file, patchWhiteboardConfig(source), 'utf8')
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
	run(process.argv[2]).catch(error => {
		console.error(`[Installer] ERROR: ${error.message}`)
		process.exitCode = 1
	})
}
