import { Buffer } from 'buffer'
export const randomBytes = count => Buffer.from(globalThis.__hostRandomBytes(count))
export const randomUUID = () => globalThis.__hostUUID()
