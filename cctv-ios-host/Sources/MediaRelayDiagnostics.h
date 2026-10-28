#import <Foundation/Foundation.h>

// Only the bounded transport schema crosses into the global diagnostic log.
// Raw plugin output, URL fields, cookies and source response bodies stay out.
static inline NSDictionary *MediaRelayDiagnosticRecord(NSString *line) {
    NSString *prefix=@"[CCTVHostMediaRelay] ";
    if([line isKindOfClass:NSString.class]&&[line hasPrefix:@"[CCTVHostMediaResult] "])prefix=@"[CCTVHostMediaResult] ";
    if(![line isKindOfClass:NSString.class]||line.length>8192||![line hasPrefix:prefix])return nil;
    NSData *data=[[line substringFromIndex:prefix.length] dataUsingEncoding:NSUTF8StringEncoding];
    if(data.length>8192)return nil;
    id value=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if(![value isKindOfClass:NSDictionary.class])return nil;
    NSString *event=value[@"event"];
    if(![@[@"media_relay_failed",@"media_relay_client_disconnected",@"media_relay_manifest_requested",@"media_relay_manifest_readable",@"media_play_result_rejected",@"media_relay_first_resource_requested",@"media_relay_first_resource_headers",@"media_relay_first_resource_byte",@"media_relay_first_resource_completed"] containsObject:event?:@""])return nil;
    NSMutableDictionary *record=[NSMutableDictionary dictionaryWithObject:event forKey:@"event"];
    for(NSString *key in @[@"request_id",@"stage",@"upstream_status",@"upstream_host",@"scheme",@"media_extension",@"error_type",@"error_summary",@"manifest_bytes",@"result_type",@"recognized_fields",@"address_type",@"candidate_count",@"validation_reason",@"elapsed_ms",@"response_bytes",@"resource_kind"]){
        id item=value[key];if([item isKindOfClass:NSNumber.class]||([item isKindOfClass:NSString.class]&&[item length]<=512))record[key]=item;
    }
    return record;
}
