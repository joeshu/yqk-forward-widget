import { Buffer } from 'buffer'

class Readable {
  constructor(options={}) {
    this.listeners=new Map();this.queue=[];this.reading=false;this.ended=false;this.destroyed=false;this.encoding='';this.source=options.read
  }
  on(name,callback){if(typeof callback==='function'){if(!this.listeners.has(name))this.listeners.set(name,[]);this.listeners.get(name).push(callback);if(name==='data')this._drain();if(name==='data'&&this.source&&!this.reading){this.reading=true;try{this.source.call(this)}catch(error){this.destroy(error)}}}return this}
  once(name,callback){const wrapped=(...args)=>{this.off(name,wrapped);callback(...args)};return this.on(name,wrapped)}
  off(name,callback){this.listeners.set(name,(this.listeners.get(name)||[]).filter(value=>value!==callback));return this}
  emit(name,...args){for(const callback of [...(this.listeners.get(name)||[])])try{callback(...args)}catch{}return Boolean((this.listeners.get(name)||[]).length)}
  push(value){if(this.destroyed||this.ended)return false;if(value===null){this.ended=true;this._drain();return false}this.queue.push(value);this._drain();return this.queue.length<16}
  setEncoding(value){this.encoding=String(value||'');return this}
  read(){const value=this.queue.shift();this._drain();return value??null}
  _drain(){if(this.destroyed)return;const dataListeners=this.listeners.get('data')||[];if(dataListeners.length)while(this.queue.length){let value=this.queue.shift();if(this.encoding)value=Buffer.isBuffer(value)?value.toString(this.encoding):String(value);this.emit('data',value)}if(this.ended&&!this.queue.length){this.ended=false;this.emit('end')}}
  pipe(destination){this.on('data',chunk=>destination.write?.(chunk));this.once('end',()=>destination.end?.());return destination}
  destroy(error){if(this.destroyed)return this;this.destroyed=true;this.queue.length=0;if(error)this.emit('error',error);this.emit('close');return this}
  static from(iterable,options={}){const stream=new Readable(options);Promise.resolve().then(async()=>{try{for await(const value of iterable){if(stream.destroyed)return;stream.push(value)}stream.push(null)}catch(error){stream.destroy(error)}});return stream}
}
class PassThrough extends Readable { write(value){return this.push(value)} end(value){if(value!==undefined)this.push(value);this.push(null);return this} }
export { Readable, PassThrough }
export default { Readable, PassThrough }
