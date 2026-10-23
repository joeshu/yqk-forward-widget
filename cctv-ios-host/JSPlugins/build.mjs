import { build } from 'esbuild'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { mkdirSync, copyFileSync, readFileSync, writeFileSync, readdirSync } from 'node:fs'
import { createHash } from 'node:crypto'
const root = dirname(fileURLToPath(import.meta.url))
const source = JSON.parse(readFileSync(resolve(root, 'yangshipin/SOURCE.json'), 'utf8'))
for (const [name, expected] of Object.entries(source.files)) {
  const bytes = readFileSync(resolve(root, 'yangshipin/upstream', name))
  if (createHash('sha256').update(bytes).digest('hex') !== expected) throw new Error(`Original upstream JS changed: ${name}`)
}
const output = resolve(root, '../GeneratedJS')
mkdirSync(output, { recursive: true })
const plugins = [{ name: 'cctvhost-native-bridges', setup(build) {
    build.onResolve({filter:/^assets:\/\/js\/lib\/cheerio\.min\.js$/},()=>({path:resolve(root,'drpy/cheerio-bridge.mjs')}))
    build.onResolve({filter:/^assets:\/\/js\/lib\/crypto-js\.js$/},()=>({path:resolve(root,'drpy/crypto-bridge.mjs')}))
    build.onResolve({filter:/模板\.js$/},()=>({path:resolve(root,'drpy/upstream/template.js')}))
    build.onResolve({filter:/jsencrypt\.js$/},args=>args.importer.endsWith('/upstream/drpy2.js')?({path:resolve(root,'drpy/jsencrypt-bridge.mjs')}):null)
    build.onResolve({ filter: /^(?:node:)?crypto$/ }, () => ({ path: resolve(root, 'compat/crypto.mjs') }))
    build.onResolve({ filter: /^\.\/runtime\.js$/ }, () => ({ path: resolve(root, 'compat/browser-runtime.mjs') }))
    build.onResolve({ filter: /utils\/colorOut\.js$/ }, () => ({ path: resolve(root, 'compat/color.mjs') }))
} }]
await build({
  entryPoints: [resolve(root, 'yangshipin/entry.mjs')], outfile: resolve(output, 'yangshipin.bundle.js'),
  bundle: true, format: 'iife', platform: 'browser', target: 'safari15', charset: 'utf8', legalComments: 'eof',
  inject: [resolve(root, 'compat/buffer.mjs')],
  plugins,
})
copyFileSync(resolve(root, 'yangshipin/upstream/LICENSE'), resolve(output, 'yangshipin-LICENSE.txt'))
console.log('Built original yangshipin JS for JavaScriptCore')

const notices = ['buffer', 'base64-js', 'ieee754', 'core-js'].map(name => `${name}\n${readFileSync(resolve(root, 'node_modules', name, 'LICENSE'), 'utf8')}`).join('\n\n')
writeFileSync(resolve(output, 'yangshipin-THIRD-PARTY-NOTICES.txt'), notices)
copyFileSync(resolve(root, 'yangshipin/SOURCE.json'), resolve(output, 'yangshipin-SOURCE.json'))

await build({entryPoints:[resolve(root,'generic/entry.mjs')],outfile:resolve(output,'js-runtime.bundle.js'),bundle:true,format:'iife',platform:'browser',target:'safari15',charset:'utf8',legalComments:'eof',inject:[resolve(root,'compat/buffer.mjs')],logOverride:{'direct-eval':'silent','equals-new-object':'silent'},plugins})
const ruleSource=JSON.parse(readFileSync(resolve(root,'drpy/SOURCE.json'),'utf8'))
for(const [name,expected] of Object.entries(ruleSource.files))if(createHash('sha256').update(readFileSync(resolve(root,'drpy/upstream',name))).digest('hex')!==expected)throw Error(`Pinned drpy source changed: ${name}`)
copyFileSync(resolve(root,'drpy/upstream/LICENSE'),resolve(output,'drpy-LICENSE.txt'))
copyFileSync(resolve(root,'drpy/SOURCE.json'),resolve(output,'drpy-SOURCE.json'))
// Node.js Mobile disables WebAssembly. Node 18's built-in fetch uses a WASM
// HTTP parser, so install a pure-JS HTTP/HTTPS implementation in the host.
await build({entryPoints:[resolve(root,'node_modules/node-fetch/lib/index.js')],outfile:resolve(output,'node-fetch.bundle.cjs'),platform:'node',target:'node18',bundle:true,format:'cjs',external:['encoding'],legalComments:'eof'})
writeFileSync(resolve(output,'node-fetch-THIRD-PARTY-NOTICES.txt'),['node-fetch','whatwg-url','tr46','webidl-conversions'].map(name=>{
  const directory=resolve(root,'node_modules',name),license=readdirSync(directory).find(file=>/^licen[cs]e(?:[.\-_]|$)/i.test(file));return name+'\n'+readFileSync(license?resolve(directory,license):resolve(root,'../Resources/tr46-LICENSE.txt'),'utf8')
}).join('\n\n'))
const dependencyNames=['buffer','base64-js','ieee754','core-js','rollup','crypto-js','iconv-lite','safer-buffer','string_decoder','cheerio','cheerio-select','boolbase','css-select','css-what','nth-check','domhandler','domutils','dom-serializer','domelementtype','entities','htmlparser2','parse5','parse5-htmlparser2-tree-adapter']
writeFileSync(resolve(output,'js-runtime-THIRD-PARTY-NOTICES.txt'),dependencyNames.map(name=>{
  const directory=resolve(root,'node_modules',name),files=readdirSync(directory),license=files.find(file=>/^licen[cs]e(?:\.|$)/i.test(file))
  return `${name}\n${license?readFileSync(resolve(directory,license),'utf8'):'License: '+JSON.parse(readFileSync(resolve(directory,'package.json'),'utf8')).license}`
}).join('\n\n'))
