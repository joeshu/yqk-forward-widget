import { build } from 'esbuild'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { mkdirSync, copyFileSync, readFileSync, writeFileSync } from 'node:fs'
import { createHash } from 'node:crypto'
const root = dirname(fileURLToPath(import.meta.url))
const source = JSON.parse(readFileSync(resolve(root, 'yangshipin/SOURCE.json'), 'utf8'))
for (const [name, expected] of Object.entries(source.files)) {
  const bytes = readFileSync(resolve(root, 'yangshipin/upstream', name))
  if (createHash('sha256').update(bytes).digest('hex') !== expected) throw new Error(`Original upstream JS changed: ${name}`)
}
const output = resolve(root, '../GeneratedJS')
mkdirSync(output, { recursive: true })
await build({
  entryPoints: [resolve(root, 'yangshipin/entry.mjs')], outfile: resolve(output, 'yangshipin.bundle.js'),
  bundle: true, format: 'iife', platform: 'browser', target: 'safari15', charset: 'utf8', legalComments: 'eof',
  inject: [resolve(root, 'compat/buffer.mjs')],
  plugins: [{ name: 'cctvhost-native-bridges', setup(build) {
    build.onResolve({ filter: /^node:crypto$/ }, () => ({ path: resolve(root, 'compat/crypto.mjs') }))
    build.onResolve({ filter: /^\.\/runtime\.js$/ }, () => ({ path: resolve(root, 'compat/browser-runtime.mjs') }))
    build.onResolve({ filter: /utils\/colorOut\.js$/ }, () => ({ path: resolve(root, 'compat/color.mjs') }))
  } }],
})
copyFileSync(resolve(root, 'yangshipin/upstream/LICENSE'), resolve(output, 'yangshipin-LICENSE.txt'))
console.log('Built original yangshipin JS for JavaScriptCore')

const notices = ['buffer', 'base64-js', 'ieee754', 'core-js'].map(name => `${name}\n${readFileSync(resolve(root, 'node_modules', name, 'LICENSE'), 'utf8')}`).join('\n\n')
writeFileSync(resolve(output, 'yangshipin-THIRD-PARTY-NOTICES.txt'), notices)
copyFileSync(resolve(root, 'yangshipin/SOURCE.json'), resolve(output, 'yangshipin-SOURCE.json'))
