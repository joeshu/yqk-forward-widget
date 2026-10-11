const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),configs=require('./collection-config.cjs');
const marker='// BEGIN COLLECTION RUNTIME';
function decorate(name,code){code=code.split(marker)[0].trimEnd();return code+'\n\n'+marker+'\nvar CollectionConfig='+JSON.stringify(configs[name])+';\n'+fs.readFileSync(path.join(__dirname,'collection-runtime.js'),'utf8');}
function build(check=false){for(const name of Object.keys(configs)){const file=path.join(__dirname,name+'.js'),code=decorate(name,fs.readFileSync(file,'utf8')),c=vm.createContext({});vm.runInContext(code,c);const snapshot=path.join(__dirname,name+'-'+c.WidgetMetadata.version+'.js');for(const target of [file,snapshot])if(check){if(fs.readFileSync(target,'utf8')!==code)throw Error(target+' stale');}else fs.writeFileSync(target,code);}}
module.exports={decorate,build};if(require.main===module)build(process.argv.includes('--check'));
