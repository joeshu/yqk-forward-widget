import { Buffer } from 'buffer'
export { randomBytes, randomUUID } from './crypto.mjs'
import CryptoJS from 'crypto-js'
const wordArray = (value, encoding) => CryptoJS.enc.Hex.parse(Buffer.from(value, encoding).toString('hex'))
export function createHash(algorithm) {
  const names = {md5:'MD5',sha1:'SHA1',sha224:'SHA224',sha256:'SHA256',sha384:'SHA384',sha512:'SHA512'}
  const name = names[String(algorithm).toLowerCase().replaceAll('-','')]
  if(!name) throw new Error(`Unsupported digest: ${algorithm}`)
  const hash = CryptoJS.algo[name].create()
  return {update(value,encoding){hash.update(wordArray(value,encoding));return this},digest(encoding){const bytes=Buffer.from(hash.finalize().toString(CryptoJS.enc.Hex),'hex');return encoding?bytes.toString(encoding):bytes}}
}
export function createHmac(algorithm, key) {
  const names={md5:CryptoJS.algo.MD5,sha1:CryptoJS.algo.SHA1,sha256:CryptoJS.algo.SHA256,sha512:CryptoJS.algo.SHA512}
  const algo=names[String(algorithm).toLowerCase()];if(!algo)throw new Error('Unsupported HMAC')
  const hash=CryptoJS.algo.HMAC.create(algo,wordArray(key))
  return {update(value,encoding){hash.update(wordArray(value,encoding));return this},digest(encoding){const bytes=Buffer.from(hash.finalize().toString(CryptoJS.enc.Hex),'hex');return encoding?bytes.toString(encoding):bytes}}
}
