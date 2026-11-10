#import <Foundation/Foundation.h>
#import "ResourceContentInspection.h"
#define Check(v) do{if(!(v)){NSLog(@"failed: %s",#v);return 1;}}while(0)
static NSData *bytes(NSString *s){return [s dataUsingEncoding:NSUTF8StringEncoding];}
int main(void){@autoreleasepool {
    NSString *page=@"\uFEFF <!DOCTYPE html><html><a href='./config.json?sig=a%2Bb&amp;part=1'>订阅配置</a><a href='https://github.com/example/source/blob/main/index.js'>脚本</a><a href='javascript:alert(1)'>订阅</a><a href='https://u:p@bad.test/list.json'>配置</a><a href='./config.json?sig=a%2Bb&amp;part=1'>重复</a><script src='ads.js'></script></html>";
    NSData *html=bytes(page);Check(ResourceContentIsHTML(html));
    NSArray *links=ResourceContentPageLinks(html,[NSURL URLWithString:@"https://source.test/path/page.html"]);
    Check(links.count==2);Check([links[0][@"url"] isEqual:@"https://source.test/path/config.json?sig=a%2Bb&part=1"]);
    Check([links[1][@"url"] isEqual:@"https://raw.githubusercontent.com/example/source/main/index.js"]);
    Check([ResourceContentExtension(bytes(@"access denied"),@"download") isEqual:@"txt"]);
    Check([ResourceContentExtension(bytes(@"module.exports={home(){return {}}}"),@"download") isEqual:@"js"]);
    Check([ResourceContentExtension(html,@"fake.py") isEqual:@"html"]);
    Check([ResourceContentExtension(bytes(@"from base.spider import Spider\nclass Spider: pass"),@"download") isEqual:@"py"]);
    Check([ResourceContentExtension(bytes(@"export default {home(){return {}}}"),@"download.mjs") isEqual:@"mjs"]);
    Check([ResourceContentExtension(bytes(@"{\"sites\":[]}"),@"download.php") isEqual:@"json"]);
    Check([ResourceContentExtension(bytes(@"#EXTM3U\n#EXTINF:-1,Test\nhttps://source.test/a.m3u8"),@"index") isEqual:@"m3u"]);
    Check([ResourceContentExtension([NSData dataWithBytes:"PK\003\004" length:4],@"download.php") isEqual:@"zip"]);
    Check([ResourceContentPageLinks(bytes(@"<html><a href='https://source.test/a.json'>配置</a></html>"),nil) count]==1);
    NSMutableString *large=[NSMutableString stringWithString:@"<html>"];for(NSUInteger i=0;i<80;i++)[large appendFormat:@"<a href='%lu.json'>资源</a>",(unsigned long)i];
    Check([ResourceContentPageLinks(bytes(large),[NSURL URLWithString:@"https://source.test/"]) count]==32);
    NSLog(@"Static resource inspection passed");return 0;
}}
