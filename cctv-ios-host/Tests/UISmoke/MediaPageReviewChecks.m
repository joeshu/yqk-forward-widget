#import <UIKit/UIKit.h>
#import "MediaAPIClient.h"
#import "MediaBrowserViewController.h"
#import "MediaEpisodeSelectionViewController.h"
#import "MediaEpisodeLayout.h"
#import "MediaFeedView.h"

@interface MediaBrowserViewController (MediaPageReviewChecks)
- (void)loadMore;
- (NSArray<NSDictionary *> *)mediaFeedSections;
@end
@interface MediaEpisodeSelectionViewController (MediaPageReviewChecks)
- (NSArray *)lines;
- (NSArray *)episodesForLine:(NSInteger)index;
- (void)rebuildSelection;
- (void)toggleEpisodeOrder;
@end

@interface MediaPageReviewClient : MediaAPIClient
@property(nonatomic,copy) NSDictionary *lastArguments;
@property(nonatomic,copy) void (^pendingReply)(id result,NSError *error);
@end
@implementation MediaPageReviewClient
- (void)call:(NSString *)operation arguments:(NSDictionary *)arguments correlationID:(NSString *)correlationID completion:(void (^)(id,NSError *))completion {
    self.lastArguments=arguments;
    self.pendingReply=completion;
}
- (void)cancel {self.pendingReply=nil;}
@end

static BOOL MediaPageCheck(BOOL passed,NSString *message) {
    NSLog(@"[MediaPageReview] %@ %@",passed?@"PASS":@"FAIL",message);
    return passed;
}

BOOL MediaPageReviewRunSmokeChecks(void) {
    BOOL passed=YES;
    NSMutableArray *episodes=[NSMutableArray array];
    for(NSUInteger index=0;index<100;index++){
        [episodes addObject:@{@"id":[NSString stringWithFormat:@"episode-%lu",(unsigned long)index],
                              @"name":[NSString stringWithFormat:@"第 %lu 集",(unsigned long)index+1]}];
    }
    MediaEpisodeSelectionViewController *picker=[MediaEpisodeSelectionViewController new];
    picker.item=@{@"id":@"movie",@"name":@"选集回归"};
    picker.source=@{@"id":@"review",@"port":@18780};
    picker.detail=@{@"name":@"选集回归",@"lines":@[@{@"id":@"main",@"episodes":episodes}]};
    picker.selectedEpisodeIndex=79;
    [picker loadViewIfNeeded];
    UIStackView *quick=[picker valueForKey:@"quickEpisodeStack"];
    BOOL foundSelected=NO;
    for(UIButton *button in quick.arrangedSubviews){
        if(!button.hidden&&button.tag==79)foundSelected=(button.accessibilityTraits&UIAccessibilityTraitSelected)!=0;
    }
    passed&=MediaPageCheck(foundSelected&&quick.arrangedSubviews.count==24,@"quick episodes include and announce episode 80");
    NSArray<UIButton *> *buttons=[picker valueForKey:@"episodeButtons"];
    BOOL gridSelected=NO;
    for(UIButton *button in buttons)if(button.tag==79)gridSelected=(button.accessibilityTraits&UIAccessibilityTraitSelected)!=0;
    passed&=MediaPageCheck(gridSelected,@"standalone selector marks its chosen episode");
    [picker toggleEpisodeOrder];
    foundSelected=NO;
    for(UIButton *button in quick.arrangedSubviews)if(!button.hidden&&button.tag==79)foundSelected=YES;
    passed&=MediaPageCheck(foundSelected,@"reverse order keeps the chosen episode in the quick window");
    picker.detail=@{@"lines":@[@{@"episodes":episodes}],
                    @"seasons":@[@{@"id":@"season-two",@"episodes":@[@{@"id":@"s2e1",@"name":@"第二季第一集"}]}]};
    picker.selectedEpisodeIndex=0;
    [picker rebuildSelection];
    passed&=MediaPageCheck(!picker.lines.count&&[[picker episodesForLine:0][0][@"id"] isEqual:@"s2e1"],@"a season with direct episodes cannot inherit another season's routes");
    [picker setValue:@"pending" forKey:@"inFlightEpisodeSignature"];
    [picker rebuildSelection];
    passed&=MediaPageCheck(!((UIButton *)[picker valueForKey:@"continueButton"]).enabled,@"layout changes preserve the pending playback action");

    MediaBrowserViewController *browser=[MediaBrowserViewController new];
    browser.deferAutomaticLoading=YES;
    browser.sourcesProvider=^NSArray *{return @[];};
    browser.catalogsProvider=^NSArray *{return @[];};
    [browser loadViewIfNeeded];
    MediaPageReviewClient *client=[[MediaPageReviewClient alloc] initWithPort:18780];
    [browser setValuesForKeysWithDictionary:@{@"client":client,@"source":@{@"id":@"review",@"port":@18780},
        @"homeMode":@NO,@"category":@"drama",@"page":@1,@"hasMore":@YES,
        @"items":@[@{@"id":@"first",@"name":@"第一页"}]}];
    [browser loadMore];
    void (^reply)(id,NSError *)=client.pendingReply;
    client.pendingReply=nil;
    passed&=MediaPageCheck(reply!=nil&&[client.lastArguments[@"page"] integerValue]==2,@"continuation requests page 2");
    if(reply)reply(nil,[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil]);
    NSDictionary *footer=browser.mediaFeedSections.lastObject;
    passed&=MediaPageCheck([footer[@"action"] isEqual:@"retry-page"]&&[[browser valueForKey:@"items"] count]==1,@"failed continuation retains page 1 and offers page retry");
    [browser loadMore];
    passed&=MediaPageCheck([client.lastArguments[@"page"] integerValue]==2,@"retry requests the failed page again");
    reply=client.pendingReply;client.pendingReply=nil;
    if(reply)reply(@{@"items":@[@{@"id":@"second",@"name":@"第二页"}],@"hasMore":@NO},nil);
    passed&=MediaPageCheck([[browser valueForKey:@"items"] count]==2&&[[browser valueForKey:@"failedListingPage"] integerValue]==0,@"successful retry merges results and clears failure state");
    [browser setValue:@YES forKey:@"hasMore"];
    footer=browser.mediaFeedSections.lastObject;
    passed&=MediaPageCheck([footer[@"action"] isEqual:@"load-more"],@"continuation is accessible without a scroll gesture");
    return passed;
}
