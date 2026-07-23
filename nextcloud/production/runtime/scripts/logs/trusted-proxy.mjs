import { BlockList, isIP } from 'node:net'

function normalizeIp(value) {
	let address = String(value ?? '').trim().replace(/^"|"$/g, '')
	if (!address || address === '-') return ''
	if (address.startsWith('[')) {
		const closing = address.indexOf(']')
		if (closing > 0) address = address.slice(1, closing)
	}
	address = address.replace(/%.+$/, '')
	if (address.startsWith('::ffff:') && isIP(address.slice(7)) === 4) address = address.slice(7)
	if (!isIP(address) && /^\d{1,3}(?:\.\d{1,3}){3}:\d+$/.test(address)) {
		address = address.replace(/:\d+$/, '')
	}
	return isIP(address) ? address : ''
}

export class TrustedProxyResolver {
	constructor(configuration = '') {
		this.blockList = new BlockList()
		for (const entry of String(configuration).split(',')) {
			const [rawAddress, rawPrefix] = entry.trim().split('/', 2)
			const address = normalizeIp(rawAddress)
			const family = isIP(address)
			if (!family) continue
			const type = family === 4 ? 'ipv4' : 'ipv6'
			try {
				if (rawPrefix === undefined) {
					this.blockList.addAddress(address, type)
				} else {
					const prefix = Number(rawPrefix)
					const maximum = family === 4 ? 32 : 128
					if (Number.isInteger(prefix) && prefix >= 0 && prefix <= maximum) {
						this.blockList.addSubnet(address, prefix, type)
					}
				}
			} catch {
				// Ignore malformed panel configuration here; Nextcloud validates/uses it separately.
			}
		}
	}

	isTrusted(value) {
		const address = normalizeIp(value)
		const family = isIP(address)
		if (!family) return false
		return this.blockList.check(address, family === 4 ? 'ipv4' : 'ipv6')
	}

	clientIp(record) {
		const peer = normalizeIp(record.remote_addr)
		if (!peer || !this.isTrusted(peer)) return peer || '-'

		const cloudflare = normalizeIp(record.cf_ip)
		if (cloudflare) return cloudflare

		const forwarded = String(record.forwarded_for ?? '')
			.split(',')
			.map(normalizeIp)
			.filter(Boolean)
		let current = peer
		for (let index = forwarded.length - 1; index >= 0 && this.isTrusted(current); index -= 1) {
			current = forwarded[index]
		}
		return current || peer
	}
}

export { normalizeIp }
