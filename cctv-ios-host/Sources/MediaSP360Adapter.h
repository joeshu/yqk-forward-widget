// Source-specific JSON protocol adapter. This does not execute Android JARs.
// Wire format reference: pcbean/CatVod-Src js/sp360.js, upstream jadehh/TVSpider.
#import <Foundation/Foundation.h>

static NSString *SP360Text(id value) {
    return [value isKindOfClass:NSString.class] ? value : ([value respondsToSelector:@selector(stringValue)] ? [value stringValue] : @"");
}
static NSDictionary *SP360Object(id value) { return [value isKindOfClass:NSDictionary.class] ? value : @{}; }
static NSArray *SP360Array(id value) { return [value isKindOfClass:NSArray.class] ? value : @[]; }
static NSString *SP360Joined(id value) { return [value isKindOfClass:NSArray.class] ? [value componentsJoinedByString:@" / "] : SP360Text(value); }

static NSURLRequest *MediaSP360Request(NSString *operation, NSDictionary *args, NSError **error) {
    NSString *host=@"https://api.web.360kan.com", *path=@"/v1/rank";
    NSDictionary *query=@{@"cat":@"1"};
    NSString *page=[NSString stringWithFormat:@"%ld",(long)MAX(1,[args[@"page"] integerValue])];
    if([operation isEqual:@"category"]){
        path=@"/v1/filter/list"; NSDictionary *filters=SP360Object(args[@"filters"]);
        query=@{@"catid":SP360Text(args[@"categoryId"]),@"rank":SP360Text(filters[@"by"]).length?SP360Text(filters[@"by"]):@"rankhot",@"cat":SP360Text(filters[@"cat"]),@"year":SP360Text(filters[@"year"]),@"area":SP360Text(filters[@"area"]),@"size":@"35",@"pageno":page};
    }else if([operation isEqual:@"search"]){
        host=@"https://api.so.360kan.com";path=@"/index";
        query=@{@"force_v":@"1",@"kw":SP360Text(args[@"keyword"]),@"pageno":page,@"v_ap":@"1",@"tab":@"all"};
    }else if([operation isEqual:@"detail"]){
        NSArray *parts=[SP360Text(args[@"id"]) componentsSeparatedByString:@"+"];
        if(parts.count!=2||![parts[0] length]||![parts[1] length]){
            if(error)*error=[NSError errorWithDomain:@"CCTVHostSP360" code:1 userInfo:@{NSLocalizedDescriptionKey:@"360 影片标识无效，请重新打开影片"}];return nil;
        }
        path=@"/v1/detail";query=@{@"id":parts[0],@"cat":parts[1]};
    }
    NSURLComponents *parts=[NSURLComponents componentsWithString:[host stringByAppendingString:path]];
    NSMutableArray *items=[NSMutableArray array];for(NSString *key in query)[items addObject:[NSURLQueryItem queryItemWithName:key value:query[key]]];parts.queryItems=items;
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:parts.URL];
    [request setValue:@"https://www.360kan.com/" forHTTPHeaderField:@"Referer"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];return request;
}

static NSDictionary *MediaSP360Normalize(NSString *operation, NSDictionary *args, id raw) {
    if([operation isEqual:@"play"]){
        NSString *url=SP360Text(args[@"id"]);
        return @{@"url":url,@"originalURL":url,@"parse":@1,@"jx":@1,@"requiresWebPlayback":@YES};
    }
    NSDictionary *root=SP360Object(raw),*data=SP360Object(root[@"data"]);
    if([operation isEqual:@"detail"]){
        NSMutableArray *lines=[NSMutableArray array];NSDictionary *episodes=SP360Object(data[@"allepidetail"]),*links=SP360Object(data[@"playlinksdetail"]);
        for(id site in SP360Array(data[@"playlink_sites"])){
            if(![site isKindOfClass:NSString.class])continue;
            NSMutableArray *rows=[NSMutableArray array];
            for(id row in SP360Array(episodes[site])){
                NSDictionary *item=SP360Object(row);NSString *url=SP360Text(item[@"url"]);
                if(url.length)[rows addObject:@{@"id":url,@"name":SP360Text(item[@"playlink_num"])}];
                if(rows.count>=2000)break;
            }
            if(!rows.count){NSDictionary *link=SP360Object(links[site]);NSString *url=SP360Text(link[@"default_url"]);if(url.length)[rows addObject:@{@"id":url,@"name":SP360Text(link[@"quality"]).length?SP360Text(link[@"quality"]):@"正片"}];}
            if(rows.count)[lines addObject:@{@"id":site,@"name":site,@"episodes":rows}];
        }
        return @{@"id":SP360Text(args[@"id"]),@"name":SP360Text(data[@"title"]),@"poster":SP360Text(data[@"cdncover"]),@"description":SP360Text(data[@"description"]),@"actor":SP360Joined(data[@"actor"]),@"director":SP360Joined(data[@"director"]),@"year":SP360Text(data[@"pubdate"]),@"lines":lines};
    }
    NSArray *rows=[operation isEqual:@"home"]?SP360Array(root[@"data"]):([operation isEqual:@"search"]?SP360Array(SP360Object(data[@"longData"])[@"rows"]):SP360Array(data[@"movies"]));
    NSMutableArray *items=[NSMutableArray array];
    for(id value in rows){
        NSDictionary *row=SP360Object(value);NSString *identifier=SP360Text(row[@"ent_id"]?:row[@"en_id"]?:row[@"id"]),*cat=SP360Text(row[@"cat"]?:row[@"cat_id"]?:args[@"categoryId"]?:@"1"),*name=SP360Text(row[@"title"]?:row[@"titleTxt"]);
        if(!identifier.length||!name.length)continue;
        NSString *poster=SP360Text(row[@"cover"]);if([poster hasPrefix:@"//"])poster=[@"https:" stringByAppendingString:poster];
        [items addObject:@{@"id":[NSString stringWithFormat:@"%@+%@",identifier,cat],@"name":name,@"poster":poster,@"remarks":SP360Text(row[@"upinfo"]?:row[@"tag"]?:SP360Object(row[@"coverInfo"])[@"txt"])}];
        if(items.count>=200)break;
    }
    NSMutableDictionary *result=[@{@"items":items,@"page":@(MAX(1,[args[@"page"] integerValue])),@"hasMore":@(items.count>=35)} mutableCopy];
    if([operation isEqual:@"home"])result[@"categories"]=@[@{@"id":@"1",@"name":@"电影"},@{@"id":@"2",@"name":@"剧集"},@{@"id":@"3",@"name":@"综艺"},@{@"id":@"4",@"name":@"动漫"}];
    return result;
}
