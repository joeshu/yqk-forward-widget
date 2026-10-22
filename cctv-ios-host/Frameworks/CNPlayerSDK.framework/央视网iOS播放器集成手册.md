#  央视网iOS播放器集成手册

BV3.23.17 | 裴洪凯 | 2025.10.27

## 一、SDK接入和工程配置
### 1.支持指令集
> arm64

### 2.支持iOS系统版本
> iOS9.0

###  3.类库组成

>
CNPlayerSDK.framework(SHARED)
CicadaPlayerSDK.framework(SHARED)
alivcffmpeg.framework(SHARED)

* 其他

>
libsqlite3.tbd
libz.tbd

### 4.工程配置
* **Other Linker Flags : 需要设置为-ObjC -lresolv**
* **Enable Bitcode : NO**
* **CNPlayerSDK、CicadaPlayerSDK、alivcffmpeg需要设置Embeded为Embeded&sign**

## 二、CNPlayer配置（CNPlayerSDKConfigProtocol）

### 1.SDK启动，初始化各播放器组件

```
//代码示例
[CNPlayer startPlayerSDK_Options:[CNPlayer defaultOptions]];
```

### 2.SDK log配置（可选）

```
//代码示例
[CNPlayer logEnabled:YES];//log总控制
[CNPlayer logToStatEnabled:NO];//统计log控制
[CNPlayer playerCoreLogEnabled:NO];//cicada内核log控制
[CNPlayer playerNetWorkLogEnabled:NO];//http log控制
[CNPlayer statInfoLogEnabled:NO];//统计log输出控制
[CNPlayer statCoreInfoLogEnabled:NO];//统计SDK内部log控制
```

## 三、CNPlayer播放控制（CNPlayerProtocol、PlaybackControlProtocol等）
### 1.起播控制
* `-(BOOL)playVODWithVid:(NSString *)vid delegate:(id<CNPlayerCallbackProtocol>)delegate configOptions:(NSDictionary<CNPlayerConfigOptionKey,id> *)configOptions;`
* `-(BOOL)playVODWithUrl:(NSString *)url delegate:(id<CNPlayerCallbackProtocol>)delegate configOptions:(NSDictionary<CNPlayerConfigOptionKey,id> *)configOptions;`
* `-(BOOL)playVODWithPlayItem:(CNPlayerItem *)playItem delegate:(id<CNPlayerCallbackProtocol>)delegate configOptions:(NSDictionary<CNPlayerConfigOptionKey,id> *)configOptions;`

* CNPlayer起播，需要根据不同情况传入由CNPlayerConfigOptionKey组成的configOptions；默认autoPlay为false；若autoPlay设置为false，可在loadStateDidChanged（CNPlayerLoadStatePrepareDone）回调中，手动调用play起播；

```
//代码示例
NSDictionary *configOptions=@{CNPlayerConfigOptionKey_Title:@"点播测试title"};
 
self.player = [CNPlayer playVODVid:@"xxxx" 
                          delegate:self 
                     configOptions:configOptions];
self.player.scalingMode = CNPlayerScalingModeAspectFit;
self.player.autoPlay = true;
[self.player prepareToPlay];
self.player.view.frame = CGRectMake(0, 0, 360, 220);
[self.view addSubview:self.player.view];
```

* **CNPlayerConfigOptionKey详解**

```
1.点播视频名称（必要）;
CNPlayerConfigOptionKey_Title

2.点播默认起播播放码率；
CNPlayerConfigOptionKey_DefaultRate

3.点播本次播放所有需要支持的码率；
CNPlayerConfigOptionKey_SupporttedRates

4.点播chapters和码率间的对应关系（本文统称点播策略）；
CNPlayerConfigOptionKey_VODConfig_ChaptersMappingInfo

5.点播本次播放的码率和带宽对应关系；
CNPlayerConfigOptionKey_RateBitrate_info

6.点播本次播放的码率和名称对应关系；
CNPlayerConfigOptionKey_RateName_info

7.点播本次播放是否开启P2P； 
CNPlayerConfigOptionConfigKey

8.点播drm流、清流选择，1为drm流，0为清流；
CNPlayerConfigOptionKey_isVodDrmHlsPriority

9.点播drm类型，二平台drm流类型为CNHLSDRMType_DRM_ENC2；
CNPlayerConfigOptionKey_VODDrmType
```
* 更多请参考CNPlayerDefin.h中的定义；

### 2.prepare、play等常规操作

* `-(void)prepareToPlay;`加载VDN、一级HLS、EPG等，完成码率生成、buffer缓存，并做好第一帧渲染准备；
* `-(void)prepareRateItemToPlay_completionBlock:(void(^)(BOOL isPublic, NSError *error))completionBlock;`加载VDN、一级HLS、EPG等，并在完成码率生成后，通过回调返回；
* `-(void)play;`开始播放，调用后，缓存可播，则进行播放；
* `-(void)pause;`暂停播放
* `-(void)reset;`播放器重置，释放掉播放内核，但保留CNPlayerItem里面的播放信息；
* `-(void)stop;`停止播放；
* `-(void)removePlayerCore;`释放掉播放内核，但保留CNPlayerItem里面的播放信息；
* `-(void)seekToTime:(NSTimeInterval)time;`点播快进快退操作；
* `-(void)seekToTime:(NSTimeInterval)time completionHandler:(void(^)(BOOL isPublic))completionHandler；`
* `-(void)restart;`点播重新播放，不重新请求VDN；
* `-(void)restartWithRate;`以选定码率重新播放；
* `-(void)retry;`重试；不重新请求VDN，当前位置、当前码率重新播放；
* `-(void)retry_completionBlock:(void(^)(NSError *))completionHandler;`
* `-(void)retry_refreshVDN_completionBlock:(void (^)(NSError *))completionHandler;`retry重试，且更新VDN；
* `-(void)switchToBackgroundMode;`监测切换后台操作，调用此方法，退到后台后，会释放掉播放内核；
* `-(void)switchToForegroundMode;`监测切换前台操作，调用此方法，进入前台后，重新播放；
* `-(void)switchToForegroundMode_completionBlock:(void(^)(NSError *))completionHandler;`

### 3.码率切换

* `- (void)switchToRateNumber:(int)number completionBlock:(void(^)(NSError *))completionBlock;`

```
[self.player switchToRateNumber:1 completionBlock:^(NSError *error){
    NSLog(@"---[完成后的动作-rate]---");
}];
```

音视频互切会重新校验版权；

### 4.版权获取

* `-(void)checkPublicPlaytime:(NSTimeInterval)playTime completionBlock:(void(^)(BOOL isPublic,CNPlayerEPGProgramItem *programChecked,NSError *error))completionBlock;//校验当前频道的版权`
* `-(void)checkPublicPlaytime:(NSTimeInterval)playTime video_channelID:(NSString *)video_channelID completionBlock:(void (^)(BOOL, CNPlayerEPGProgramItem *, NSError *))completionBlock;`

点播和直播版权获取接口；若想调用此接口，**必须要先调用起播方法**；

## 四、CNPlayer主要代理回调（CNPlayerCallbackProtocol）
### 1.加载状态回调

* `-(void)player:(id<CNPlayerMainProtocol>)player loadStateDidChanged:(CNPlayerLoadState)loadState;`

当加载资源的状态发生变化后，会发出loadStateDidChanged回调；
> 
CNPlayerLoadState详解：
CNPlayerLoadStateUnknown：未知；
CNPlayerLoadStateVDNRequesting：VDN开始请求；
CNPlayerLoadStateLoading：缓存开始加载；
CNPlayerLoadStateLoadFailed：缓存加载失败；
CNPlayerLoadStatePlayable：缓存加载成功，可播放；此状态会逐渐弃用，用CNPlayerLoadStatePrepareDone来代替；
CNPlayerLoadStatePrepareDone = CNPlayerLoadStatePlayable；首次缓冲加载成功；
CNPlayerLoadStateSeekSucceed：点播资源（点播、回看）seek加载完成；会自动播放，若想切换后暂停，可在具体的代码块回调或者此状态回调中pause即可；
CNPlayerLoadStateRateSwitchSucceed：码率切换加载完成；会自动播放，若想切换后暂停，可在具体的代码块回调或者此状态回调中pause即可；
CNPlayerLoadStateAudioSwitchSucceed：音频切换加载完成；会自动播放，若想切换后暂停，可在具体的代码块回调或者此状态回调中pause即可；
CNPlayerLoadStateVideoSwitchSucceed：视频切换加载完成；会自动播放，若想切换后暂停，可在具体的代码块回调或者此状态回调中pause即可；
CNPlayerLoadStateRetrySucceed：重试加载完成；会自动播放，若想切换后暂停，可在具体的代码块回调或者此状态回调中pause即可；
CNPlayerLoadStateForegroundSwitchSucceed：进入前台缓冲加载完成；不会自动播放；
CNPlayerLoadStateStalled：卡顿；
CNPlayerLoadStateStalledRecovery：卡顿恢复；
CNPlayerLoadStateCancelled：取消加载；

```
//代码示例
- (void)player:(id<CNPlayerMainProtocol>)player loadStateDidChanged:(CNPlayerLoadState)loadState
{
    switch (loadState) {
        case CNPlayerLoadStatePlayable:
            [_player play];
            break;
        default:
            break;
    }
}
```
### 2.播放状态回调

* `-(void)player:(id<CNPlayerMainProtocol>)player playBackStateDidChanged:(CNPlayerPlaybackState)playbackState;`

当播放状态发生改变后，会发出playBackStateDidChanged回调。
>
CNPlayerPlaybackState详解：
CNPlayerPlaybackStateUnknown：未知；
CNPlayerPlaybackStatePlaying：播放开始；
CNPlayerPlaybackStatePaused：播放暂停；
CNPlayerPlaybackStateStalled：播放卡顿；
CNPlayerPlaybackStateStopped：播放停止；
CNPlayerPlaybackStateEnded：播放结束；播放结束原因见CNPlayer属性CNPlayerFinishReason finishReason;

>
CNPlayerFinishReason详解：
CNPlayerFinishReasonUnknown：未知；
CNPlayerFinishReasonPlaybackEnded：播放自然结束，也就是播放到了终点；
CNPlayerFinishReasonPlaybackError：播放失败结束；
CNPlayerFinishReasonUserExited：用户取消播放结束；

```
//代码示例
- (void)player:(id<CNPlayerMainProtocol>)player playBackStateDidChanged:(CNPlayerPlaybackState)playbackState
{
    switch (playbackState) {
        case CNPlayerPlaybackStatePlaying:
            //CNPlayerPlaybackStatePlaying,do something!
            break;
        default:
            break;
    }
}
```

### 3.VDN请求状态回调

* `- (void)player:(id<CNPlayerMainProtocol>)player vdnRequestStateDidChanged:(CNPlayerVDNRequestState)vdnRequestState;`

VDN请求状态发生改变后的回调。

> CNPlayerVDNRequestState详解：
CNPlayerVDNRequestStateUnknown：未知；
CNPlayerVDNRequestStateRequesting：VDN请求开始；
CNPlayerVDNRequestStateFailed：VDN请求失败；
CNPlayerVDNRequestStateSucceed：VDN请求成功；
CNPlayerVDNRequestStateCancelled：VDN请求取消；
```
//代码示例
- (void)player:(id<CNPlayerMainProtocol>)player vdnRequestStateDidChanged:(CNPlayerVDNRequestState)vdnRequestState
{
    switch (vdnRequestState) {
        case CNPlayerVDNRequestStateSucceed:
            //CNPlayerVDNRequestStateSucceed,do something!
            break;
        default:
            break;
    }
}
```

### 4.参数错误

* `- (void)player:(id<CNPlayerMainProtocol>)player parameterError:(NSError *)error rate:(CNPlayerRate)rate;`

主要是VDN中某些关键参数的缺失，如hls4和hls6等，而视频/频道名称、vid/channelID等起播参数错误，因暂未定错误码，而未融入此回调中；

### 5.VDN请求失败

* `- (void)player:(id<CNPlayerMainProtocol>)player vdnRequestFailed:(NSError *)error;`

VDN请求失败后，会发出vdnRequestFailed回调，并给出具体的错误码和错误信息，具体的错误信息获取由NSError+CNPlayer提供，ex：statCode = V4001，msg = 点播接口认证失败请求失败(ack==no等)；
查看第五章中的VDN系列错误。

```
//代码示例
- (void)player:(id<CNPlayerMainProtocol>)player vdnRequestFailed:(NSError *)error
{
    CPLog(@"---[errorCode : %@]---[errorMsg : %@]---",error.statCode,error.msg);
}
```

### 6.播放失败

* `- (void)player:(id<CNPlayerMainProtocol>)player playbackFailed:(NSError *)error;`

播放失败后，会发出playbackFailed回调，并给出具体的错误码和错误信息，ex：statCode = C40X/50X，msg = 多码率主main.m3u8 HTTP错误；
查看第五章中的CDN、播放核心、DRM系列错误。

```
//代码示例
- (void)player:(id<CNPlayerMainProtocol>)player playbackFailed:(NSError *)error
{
    //本码率失败后，切换到别的码率（仅支持IJK和Ali播放器的rateUrls_info方式的播放）
    [self.player switchToRate:CNPlayerRate_LD 
              completionBlock:^(NSError *error){
                  CPLog(@"---[成功切换到LD]---");
    }];
}
```

### 7.节目版权变动

* `-(void)player:(id<CNPlayerMainProtocol>)player programPubicChanged:(BOOL)isPublic;`
* `-(void)player:(id<CNPlayerMainProtocol>)player programPubicChanged:(BOOL)isPublic type:(CNPlayerRateSourceType)sourceType error:(NSError *)error;`

正在播放的节目若有版权变化，会通过此回调发出；

```
//代码示例
- (void)player:(id<CNPlayerMainProtocol>)player programPubicChanged:(BOOL)isPublic type:(CNPlayerRateSourceType)sourceType error:(NSError *)error
{
    if (error) {
        NSString *code = error.statCode;
        NSString *tips = error.tips;
        NSString *msg = error.msg;
        CPLog(@"---[error code : %@-tips:%@-msg:%@]---",code,tips,msg);
    }
}
```
### 8.版权请求失败

* `- (void)player:(id<CNPlayerMainProtocol>)player publicRequestFailed:(NSError *)error;`

时移回看、返回直播、返回前台、起播等情况下，若外面配置了本次播放的CNPlayerConfigOptionKey_LivePublicCheck_ONOFF（打开版权校验开关，默认关）和CNPlayerConfigOptionKey_TimeshiftingChannelID（用于版权校验的channelID，若空则取起播方法中传入的channelID参数），且配置了configSDK_VDN_LiveTSPublicUrl（版权校验地址），则会进行版权校验，若请求失败，则发出此回调；

### 9.周期事件

* `- (void)playerPeriodicTimeEvent:(id<CNPlayerMainProtocol>)player;`

播放器会每隔一秒发出一次周期事件，可同步更新播放进度、缓冲进度等；

### 10.统计相关事件（也可用于普通播放控制）

* `- (void)player:(id<CNPlayerMainProtocol>)player statEvent:(CNPlayerStatEvent)statEvent value:(id)value;`

此事件多用于统计模块的不同事件统计，也可作为一般的控制性回调，譬如fristRender事件等；

> CNPlayerStatEvent详解：
CNPlayerStatEvent_Unknown：未知
CNPlayerStatEvent_Startup：起播，最开始位置
CNPlayerStatEvent_SetupPlayer：VDN等完成，开始设置播放器
CNPlayerStatEvent_FirstRenderDidStart：第一帧完成渲染，起播、音视频切换、restart、切换到前台、CDN和P2P相互切换等情况，都会发出此事件；
CNPlayerStatEvent_SwitchRate：切换码率，value值中有具体切换的码率值，开始切换时发出
CNPlayerStatEvent_SwitchAudioFromVideo：切换到听电视模式，开始切换时发出
CNPlayerStatEvent_SwitchVideoFromAudio：切换到看视频模式，开始切换时发出
CNPlayerStatEvent_StalledStart：卡顿开始，发生卡顿
CNPlayerStatEvent_StalledRecovery：卡顿结束
CNPlayerStatEvent_WillSwitchForegroundMode：切换到前台
CNPlayerStatEvent_DidSwitchBackgroundMode：切换到后台
CNPlayerStatEvent_VODSeekStart：点播seek开始
CNPlayerStatEvent_VODSeekCompletion：点播seek结束
CNPlayerStatEvent_willRetry：重试事件
CNPlayerStatEvent_willRestart：重新开始事件

```
- (void)player:(id<CNPlayerMainProtocol>)player statEvent:(CNPlayerStatEvent)statEvent value:(id)value
{
    switch (statEvent) {
        case CNPlayerStatEvent_SwitchRate:
            {
                if ([value isKindOfClass:[NSString class]] && 
                    [value isEqualToString:CNPlayerRate_HD]) {
                    CPLog(@"---[SwitchRate : %@]---",value);
                }
            }
            break;
        default:
            break;
    }
}
```

## 五、主要错误码
### 1.VDN系列错误

|  序号  |  errorCode  |  错误码含义  |
| --- | --- | --- |
|  1  |  V-50x/40X  |  VDN请求响应错误（50x/40x）  |
|  2  |  V-4900  |  json解析失败/非法json  |
|  3  |  V-4001  |  点播接口认证失败请求失败(ack==no )  |
|  4  |  V-4006  |  点播VDN请求成功但返回json缺少主要参数ack,hls_url,public  |
|  5  |  V-4007  |  直播调度错误(“ack”:”no”)   |
|  6  |  V-4008  |  json解析失败/非法json  |
|  7  |  V-4009  |  直播听电视hls6非法  |
|  8  |  V-4019  |  点播听电视有效url地址为空  |
|  9  |  V-4010  |  直播VDN请求成功但返回json缺少主要参数直播hls1,ack,public  |
|  10  |  V-4011  |  没有给播放器sdk传vid  |
|  11  |  V-4012  |  没有给播放器sdk传title  |
|  12  |  V-4013  |  直播ack == YES && status !=1  |
|  13  |  V-4023  |  点播ack == YES && status !=1  |
|  14  |  V-XXXX  |  VDN网络请求错误,详见NSErrorDomain.  |
|  15  |  V-9999  |  未知错误  |

### 2.CDN系列错误

|  序号  |  errorCode  |  错误码含义  |
| --- | --- | --- |
|  1  |  C-4041  |  视频流没找到  |
|  2  |  C-400  |  服务器400 code  |
|  3  |  C-401  |  服务器401 code  |
|  4  |  C-403  |  服务器403 code  |
|  5  |  C-4042  |  服务器404  |
|  6  |  C-499  |  服务器返回4xx其它错误 code  |
|  7  |  C-599  |  服务器返回5xx其它错误 code  |
|  8  |  C-40X/50X  |  多码率主main.m3u8 HTTP错误  |
|  9  |  C-XXXX  |  多码率主main.m3u8网络请求错误,详见NSErrorDomain  |
|  10  |  C-4005  |  多码率主main.m3u8 TXT解析异常   |

### 3.DRM系列错误

|  序号  |  errorCode  |  错误码含义  |
| --- | --- | --- |
|  1  |  D-80001001  |  EX_UDRM_ERROR_CONNNECT_FAILED  |
|  2  |  D-80001002  |  EX_UDRM_ERROR_SEND_ERROR  |
|  3  |  D-80001003  |  EX_UDRM_ERROR_RECV_ERROR  |
|  4  |  D-80001004  |  EX_UDRM_ERROR_SSL_NEW_ERROR  |
|  5  |  D-80001005  |  EX_UDRM_ERROR_SSL_USE_CERT_ERROR  |
|  6  |  D-80001006  |  EX_UDRM_ERROR_SSL_USE_PKEY_ERROR  |
|  7  |  D-80001007  |  EX_UDRM_ERROR_SSL_CONNECT_ERROR  |
|  8  |  D-80001008  |  EX_UDRM_ERROR_SSL_SERVER_CERT_INVALID  |
|  9  |  D-80001009  |  EX_UDRM_ERROR_BAD_REQUEST  |
|  10  |  D-80001010  |  EX_UDRM_ERROR_SERVICE_TEMP_UNAVAILABLE  |
|  11  |  D-80001011  |  EX_UDRM_ERROR_SSL_CERT_ERROR  |
|  12  |  D-80001012  |  EX_UDRM_ERROR_SSL_PKEY_ERROR  |
|  13  |  D-80001013  |  EX_UDRM_ERROR_DECRYPT_JSON_MISS_STATUS_STRING  |
|  14  |  D-80001014  |  EX_UDRM_ERROR_DB_CONNECT_ERROR  |
|  15  |  D-80001015  |  EX_UDRM_ERROR_DB_OPERATE_ERROR  |
|  16  |  D-80001016  |  EX_UDRM_ERROR_NOT_BIND_ERROR  |
|  17  |  D-80002001  |  EX_UDRM_ERROR_JSON_PARSE_ERROR  |
|  18  |  D-80002002  |  EX_UDRM_ERROR_UDRMCLIENT_NOT_EXIST  |
|  19  |  D-80002003  |  EX_UDRM_ERROR_CONTENT_NOT_EXIST  |
|  20  |  D-80002004  |  EX_UDRM_ERROR_CERT_NOT_EXIST  |
|  21  |  D-80002005  |  EX_UDRM_ERROR_SIGNATURE_CERT_NO_TRUST  |
|  22  |  D-80002006  |  EX_UDRM_ERROR_SIGNATURE_PROCESS_ERROR  |
|  23  |  D-80002007  |  EX_UDRM_ERROR_DEVICE_NO_RIGHT  |
|  24  |  D-80002008  |  EX_UDRM_ERROR_VERSION_NOT_SUPPORT  |
|  25  |  D-80002009  |  EX_UDRM_ERROR_CERT_STATUS_ERROR  |
|  26  |  D-80003001  |  EX_UDRM_ERROR_GET_LICENSE_FAILED  |
|  27  |  D-80003002  |  EX_UDRM_ERROR_NO_CONTENT_VERIFY_DATA  |
|  28  |  D-80003003  |  EX_UDRM_ERROR_CONTENT_VERIFY_FAILED  |
|  29  |  D-80003004  |  EX_UDRM_ERROR_UNKNOWN_ERROR  |
|  30  |  D-80003005  |  EX_UDRM_ERROR_AGENT_SERVER_TIME_ERROR  |
|  31  |  D-80003006  |  EX_UDRM_ERROR_GZIP_ERROR  |
|  32  |  D-80003007  |  EX_UDRM_ERROR_TIMESTAMP_ERROR  |
|  33  |  D-80003008  |  EX_UDRM_ERROR_SIGNATURE_CERT_NO_TRUST  |
|  34  |  D-80003009  |  EX_UDRM_ERROR_SIGNATURE_PROCESS_ERROR  |
|  35  |  D-80003010  |  EX_UDRM_ERROR_INVALID_ARGUMENT  |
|  36  |  D-80003011  |  EX_UDRM_ERROR_DECRYPT_INVALID_ARGUMENT  |
|  37  |  D-80004003  |  EX_UDRM_ERROR_LICENSE_LOAD_FAILED  |
|  38  |  D-80004004  |  EX_UDRM_ERROR_LICENSE_LOAD_LEN_ERROR  |
|  39  |  D-80004005  |  EX_UDRM_ERROR_LICENSE_MATCH_ERROR  |
|  40  |  D-80004006  |  EX_UDRM_ERROR_LICENSE_SIGN_VERIFY_FAILED  |
|  41  |  D-80004007  |  EX_UDRM_ERROR_LICENSE_SAVE_FAILED  |
|  42  |  D-80004008  |  EX_UDRM_ERROR_LICENSE_NO_SET_PATH  |
|  43  |  D-80004009  |  EX_UDRM_ERROR_LICENSE_NO_LICENSE  |

### 4.播放内核系列错误（K-XXXX）
具体参考CicadaPlayer错误文档。

