#import "ServiceEditorViewController.h"
#import "HostTheme.h"
#import "PyHost.h"
#import "ServiceStore.h"
#import <JavaScriptCore/JavaScriptCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface ServiceCodeViewController () <UITextViewDelegate>
@property(nonatomic, strong) UILabel *codeStatusLabel;
@property(nonatomic, copy) NSString *initialCodeText;
@property(nonatomic, copy) NSString *lastSearchQuery;
@property(nonatomic, copy) NSString *lastReplaceText;
@property(nonatomic, assign) BOOL applyingSyntaxHighlight;
@property(nonatomic, assign) NSUInteger syntaxHighlightGeneration;
- (void)scheduleSyntaxHighlighting;
- (void)reloadThemeAppearance;
- (void)promptFindInCode;
- (void)promptGoToLine;
- (void)validateCodeSyntax;
- (void)formatJSONIfApplicable;
- (void)copyAllCode;
- (void)promptReplaceInCode;
- (void)pasteReplaceCode;
- (void)insertCodeTemplate:(NSString *)templateKind;
- (void)resetBundledCodeIfApplicable;
- (void)save;
@end

@implementation ServiceCodeViewController {
    UITextView *_editor;
}
- (NSString *)detectedCodeLanguageLabel {
    NSString *ext = self.path.pathExtension.lowercaseString ?: @"";
    if ([ext isEqualToString:@"js"] || [ext isEqualToString:@"mjs"] || [ext isEqualToString:@"cjs"]) return @"JavaScript";
    if ([ext isEqualToString:@"json"]) return @"JSON";
    if ([ext isEqualToString:@"py"]) return @"Python";
    NSString *sample = _editor.text ?: @"";
    if ([sample hasPrefix:@"{"] || [sample hasPrefix:@"["]) return @"JSON";
    if ([sample containsString:@"function("] || [sample containsString:@"module.exports"] || [sample containsString:@"var rule"]) return @"JavaScript";
    return @"Python";
}
- (void)updateCodeStatusBar {
    if (!self.codeStatusLabel) return;
    NSString *text = _editor.text ?: @"";
    NSUInteger length = text.length;
    NSUInteger totalLines = 1;
    for (NSUInteger i = 0; i < length; i++) {
        if ([text characterAtIndex:i] == '\n') totalLines++;
    }
    NSRange sel = _editor.selectedRange;
    NSUInteger cursorLoc = sel.location != NSNotFound ? MIN(sel.location, length) : 0;
    NSUInteger cursorLine = 1, lineStart = 0;
    for (NSUInteger i = 0; i < cursorLoc; i++) {
        if ([text characterAtIndex:i] == '\n') { cursorLine++; lineStart = i + 1; }
    }
    NSUInteger cursorCol = cursorLoc - lineStart + 1;
    NSString *mode = self.readOnly ? @"只读" : ([text isEqualToString:self.initialCodeText ?: @""] ? @"未修改" : @"已修改*");
    self.codeStatusLabel.text = [NSString stringWithFormat:@"%@ · %lu 行 · %.1f KB · 行 %lu:%lu · %@",
                                 [self detectedCodeLanguageLabel],
                                 (unsigned long)totalLines,
                                 (double)[text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] / 1024.0,
                                 (unsigned long)cursorLine,
                                 (unsigned long)cursorCol,
                                 mode];
}
- (void)applySyntaxHighlightingIfNeeded {
    if (self.applyingSyntaxHighlight || !_editor) return;
    NSString *text = _editor.text ?: @"";
    if (!text.length || text.length > 128 * 1024) return;
    self.applyingSyntaxHighlight = YES;
    NSRange selectedRange = _editor.selectedRange;
    UIFont *codeFont = _editor.font ?: [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    NSTextStorage *storage = _editor.textStorage;
    NSRange fullRange = NSMakeRange(0, text.length);
    [storage beginEditing];
    [storage addAttribute:NSForegroundColorAttributeName value:HostText() range:fullRange];
    [storage addAttribute:NSFontAttributeName value:codeFont range:fullRange];
    static NSRegularExpression *numberRe = nil;
    static NSRegularExpression *keywordRe = nil;
    static NSRegularExpression *stringRe = nil;
    static NSRegularExpression *commentRe = nil;
    static dispatch_once_t highlightOnce;
    dispatch_once(&highlightOnce, ^{
        numberRe = [NSRegularExpression regularExpressionWithPattern:@"\\b\\d+(?:\\.\\d+)?\\b" options:0 error:NULL];
        keywordRe = [NSRegularExpression regularExpressionWithPattern:@"\\b(?:def|class|import|from|return|async|await|if|elif|else|for|while|try|except|finally|with|pass|break|continue|lambda|yield|function|const|let|var|module|exports|require|export|default|new|typeof|instanceof|true|false|null|None|True|False)\\b" options:0 error:NULL];
        stringRe = [NSRegularExpression regularExpressionWithPattern:@"(?:\"(?:\\\\.|[^\"\\\\\\n])*\"|'(?:\\\\.|[^'\\\\\\n])*')" options:0 error:NULL];
        commentRe = [NSRegularExpression regularExpressionWithPattern:@"(?m)(?:#.*$|//.*$|/\\*[\\s\\S]*?\\*/)" options:0 error:NULL];
    });
    UIColor *numColor = UIColor.systemTealColor;
    UIColor *kwColor = HostAccent();
    UIColor *strColor = UIColor.systemOrangeColor;
    UIColor *cmtColor = HostSecondaryText();
    for (NSTextCheckingResult *m in [numberRe matchesInString:text options:0 range:fullRange]) {
        [storage addAttribute:NSForegroundColorAttributeName value:numColor range:m.range];
    }
    for (NSTextCheckingResult *m in [keywordRe matchesInString:text options:0 range:fullRange]) {
        [storage addAttribute:NSForegroundColorAttributeName value:kwColor range:m.range];
    }
    for (NSTextCheckingResult *m in [stringRe matchesInString:text options:0 range:fullRange]) {
        [storage addAttribute:NSForegroundColorAttributeName value:strColor range:m.range];
    }
    for (NSTextCheckingResult *m in [commentRe matchesInString:text options:0 range:fullRange]) {
        [storage addAttribute:NSForegroundColorAttributeName value:cmtColor range:m.range];
    }
    [storage endEditing];
    if (NSMaxRange(selectedRange) <= text.length) {
        _editor.selectedRange = selectedRange;
    }
    self.applyingSyntaxHighlight = NO;
}
- (void)scheduleSyntaxHighlighting {
    NSUInteger generation = ++self.syntaxHighlightGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        ServiceCodeViewController *owner = weakSelf;
        if (!owner || owner.syntaxHighlightGeneration != generation || owner->_editor.markedTextRange != nil) return;
        [owner applySyntaxHighlightingIfNeeded];
    });
}
- (void)textViewDidChange:(UITextView *)textView {
    if (textView.markedTextRange != nil) return;
    [self scheduleSyntaxHighlighting];
    [self updateCodeStatusBar];
}
- (void)textViewDidChangeSelection:(UITextView *)textView {
    [self updateCodeStatusBar];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = HostSelectedInterfaceStyle();
    self.title = self.readOnly ? @"查看代码" : @"编辑代码";
    self.view.backgroundColor = HostBackground();
    if (!self.readOnly) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"返回" style:UIBarButtonItemStylePlain target:self action:@selector(requestCloseCodeEditor)];
    }
    self.codeStatusLabel = [UILabel new];
    self.codeStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.codeStatusLabel.font = HostMonospacedDigitFont(12, UIFontWeightMedium, UIFontTextStyleCaption1);
    self.codeStatusLabel.adjustsFontForContentSizeCategory = YES;
    self.codeStatusLabel.textColor = HostSecondaryText();
    self.codeStatusLabel.numberOfLines = 1;
    self.codeStatusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.codeStatusLabel.accessibilityIdentifier = @"service.code.status";
    [self.view addSubview:self.codeStatusLabel];

    _editor = [UITextView new];
    _editor.translatesAutoresizingMaskIntoConstraints = NO;
    _editor.delegate = self;
    _editor.backgroundColor = HostCard();
    _editor.textColor = HostText();
    _editor.layer.cornerRadius = 14;
    _editor.layer.cornerCurve = kCACornerCurveContinuous;
    _editor.layer.borderWidth = 0.6;
    HostSetLayerBorderColor(_editor, HostBorder());
    UIFont *baseCodeFont=[UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    UIFont *scaledCodeFont=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledFontForFont:baseCodeFont];
    // 大字体下代码等比放大到 30pt+ 会导致每行只剩几个字符、无法手工编辑：封顶 20pt。
    if(scaledCodeFont.pointSize>20)scaledCodeFont=[UIFont monospacedSystemFontOfSize:20 weight:UIFontWeightRegular];
    _editor.font=scaledCodeFont;
    _editor.adjustsFontForContentSizeCategory=YES;
    _editor.editable = !self.readOnly;
    _editor.autocorrectionType = UITextAutocorrectionTypeNo;
    _editor.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _editor.smartQuotesType = UITextSmartQuotesTypeNo;
    _editor.smartDashesType = UITextSmartDashesTypeNo;
    _editor.spellCheckingType = UITextSpellCheckingTypeNo;
    _editor.layoutManager.allowsNonContiguousLayout = YES;
    UIToolbar *kbToolbar = [[UIToolbar alloc] init]; [kbToolbar sizeToFit];
    UIBarButtonItem *kbFind = [[UIBarButtonItem alloc] initWithTitle:@"搜索" style:UIBarButtonItemStylePlain target:self action:@selector(promptFindInCode)];
    UIBarButtonItem *kbLine = [[UIBarButtonItem alloc] initWithTitle:@"跳行" style:UIBarButtonItemStylePlain target:self action:@selector(promptGoToLine)];
    UIBarButtonItem *kbCheck = [[UIBarButtonItem alloc] initWithTitle:@"预检" style:UIBarButtonItemStylePlain target:self action:@selector(validateCodeSyntax)];
    UIBarButtonItem *kbFlex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *kbDone = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(dismissCodeKeyboard)];
    kbToolbar.items = @[kbFind, kbLine, kbCheck, kbFlex, kbDone];
    _editor.inputAccessoryView = kbToolbar;
    _editor.text=@"正在读取代码…";_editor.editable=NO;
    NSString *path=self.path;NSUInteger limit=self.readOnly?512*1024:2*1024*1024;__weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{
        NSError *error=nil;NSData *data=nil;NSFileHandle *file=path.length?[NSFileHandle fileHandleForReadingAtPath:path]:nil;
        @try{if(file)data=[file readDataUpToLength:limit+1 error:&error];}@catch(NSException *exception){NSLog(@"[CCTVHost] code file read raised %@",exception.name);error=[NSError errorWithDomain:@"CCTVHostCode" code:1 userInfo:nil];}@finally{[file closeAndReturnError:NULL];}
        BOOL truncated=data.length>limit;if(truncated)data=[data subdataWithRange:NSMakeRange(0,limit)];
        NSString *text=data?[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]:nil;
        for(NSUInteger trim=1;!text && truncated && trim<=3;trim++)text=[[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0,data.length-trim)] encoding:NSUTF8StringEncoding];
        dispatch_async(dispatch_get_main_queue(),^{ServiceCodeViewController *owner=weakSelf;if(!owner)return;
            if(!text || error){owner->_editor.text=@"无法读取 UTF-8 代码文件";if(owner.navigationItem.rightBarButtonItems.count>1)owner.navigationItem.rightBarButtonItems=@[owner.navigationItem.rightBarButtonItems.lastObject];[owner updateCodeStatusBar];return;}
            owner.initialCodeText=text;
            owner->_editor.text=text;if(truncated){owner.readOnly=YES;if(owner.navigationItem.rightBarButtonItems.count>1)owner.navigationItem.rightBarButtonItems=@[owner.navigationItem.rightBarButtonItems.lastObject];owner.navigationItem.prompt=@"只读预览已截断，导出包含完整文件";}
            owner->_editor.editable=!owner.readOnly;owner.navigationItem.rightBarButtonItem.enabled=YES;
            [owner applySyntaxHighlightingIfNeeded];
            [owner updateCodeStatusBar];
        });
    }});
    [self.view addSubview:_editor];
    [NSLayoutConstraint activateConstraints:@[
        [self.codeStatusLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:4],
        [self.codeStatusLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.codeStatusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.codeStatusLabel.heightAnchor constraintGreaterThanOrEqualToConstant:20],
        [_editor.topAnchor constraintEqualToAnchor:self.codeStatusLabel.bottomAnchor constant:4],
        [_editor.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_editor.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [_editor.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor]
    ]];
    UIAction *findAction = [UIAction actionWithTitle:@"搜索代码关键字" image:[UIImage systemImageNamed:@"magnifyingglass"] identifier:nil handler:^(__unused UIAction *a){ [weakSelf promptFindInCode]; }];
    UIAction *goToLineAction = [UIAction actionWithTitle:@"跳转到指定行号" image:[UIImage systemImageNamed:@"number"] identifier:nil handler:^(__unused UIAction *a){ [weakSelf promptGoToLine]; }];
    UIAction *validateSyntaxAction = [UIAction actionWithTitle:@"语法与结构预检" image:[UIImage systemImageNamed:@"checkmark.shield"] identifier:nil handler:^(__unused UIAction *a){ [weakSelf validateCodeSyntax]; }];
    UIAction *formatJSONAction = [UIAction actionWithTitle:@"校验并美化 JSON" image:[UIImage systemImageNamed:@"curlybraces"] identifier:nil handler:^(__unused UIAction *a){ [weakSelf formatJSONIfApplicable]; }];
    UIAction *copyCodeAction = [UIAction actionWithTitle:@"复制全部代码" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__unused UIAction *a){ [weakSelf copyAllCode]; }];
    NSMutableArray<UIMenuElement *> *toolActions = [NSMutableArray arrayWithObjects:findAction, goToLineAction, validateSyntaxAction, formatJSONAction, copyCodeAction, nil];
    if (!self.readOnly) {
        UIAction *replaceAction = [UIAction actionWithTitle:@"查找并替换代码" image:[UIImage systemImageNamed:@"arrow.left.arrow.right"] identifier:nil handler:^(__unused UIAction *a){ [weakSelf promptReplaceInCode]; }];
        [toolActions insertObject:replaceAction atIndex:1];
        UIAction *pasteCodeAction = [UIAction actionWithTitle:@"粘贴剪贴板替换代码" image:[UIImage systemImageNamed:@"doc.on.clipboard"] identifier:nil handler:^(__unused UIAction *a){ [weakSelf pasteReplaceCode]; }];
        [toolActions addObject:pasteCodeAction];
        UIAction *pyHTTPTpl = [UIAction actionWithTitle:@"插入 Python HTTP 直播模板" image:[UIImage systemImageNamed:@"network"] identifier:nil handler:^(__unused UIAction *a){ [weakSelf insertCodeTemplate:@"python-http"]; }];
        UIAction *pySpiderTpl = [UIAction actionWithTitle:@"插入 Python 影视 Spider 模板" image:[UIImage systemImageNamed:@"film"] identifier:nil handler:^(__unused UIAction *a){ [weakSelf insertCodeTemplate:@"python-spider"]; }];
        UIAction *jsPluginTpl = [UIAction actionWithTitle:@"插入 JavaScript 影视插件模板" image:[UIImage systemImageNamed:@"sparkles"] identifier:nil handler:^(__unused UIAction *a){ [weakSelf insertCodeTemplate:@"js-media"]; }];
        UIMenu *tplMenu = [UIMenu menuWithTitle:@"插入标准脚本模板" image:[UIImage systemImageNamed:@"doc.badge.plus"] identifier:nil options:0 children:@[pyHTTPTpl, pySpiderTpl, jsPluginTpl]];
        [toolActions addObject:tplMenu];
        if (self.bundledResourcePath.length) {
            UIAction *resetBundled = [UIAction actionWithTitle:@"恢复内置初始代码" image:[UIImage systemImageNamed:@"arrow.counterclockwise"] identifier:nil handler:^(__unused UIAction *a){ [weakSelf resetBundledCodeIfApplicable]; }];
            resetBundled.attributes = UIMenuElementAttributesDestructive;
            [toolActions addObject:resetBundled];
        }
    }
    UIBarButtonItem *toolsItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"wand.and.stars"] menu:[UIMenu menuWithTitle:@"代码工具" children:toolActions]];
    toolsItem.accessibilityIdentifier = @"service.code.tools";
    toolsItem.accessibilityLabel=@"代码工具";
    toolsItem.accessibilityHint=@"搜索、跳行、预检、格式化、复制或插入代码模板";
    if (!self.readOnly) {
        UIBarButtonItem *saveItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self action:@selector(save)];
        self.navigationItem.rightBarButtonItems = @[saveItem, toolsItem];
    } else {
        self.navigationItem.rightBarButtonItem = toolsItem;
    }
}

- (void)dismissCodeKeyboard {
    [_editor resignFirstResponder];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection && [self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
        [self reloadThemeAppearance];
    }
}
- (void)reloadThemeAppearance {
    if(!self.isViewLoaded)return;
    self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.view.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.view.backgroundColor=HostBackground();
    self.codeStatusLabel.textColor=HostSecondaryText();
    _editor.backgroundColor=HostCard();
    _editor.textColor=HostText();
    HostSetLayerBorderColor(_editor,HostBorder());
    [self applySyntaxHighlightingIfNeeded];
}

- (void)showTemporaryPrompt:(NSString *)prompt {
    if (!prompt.length) return;
    self.navigationItem.prompt = prompt;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        ServiceCodeViewController *owner = weakSelf;
        if (owner && [owner.navigationItem.prompt isEqual:prompt]) owner.navigationItem.prompt = nil;
    });
}

- (void)copyAllCode {
    if (!_editor.text.length) return;
    UIPasteboard.generalPasteboard.string = _editor.text;
    [self showTemporaryPrompt:@"代码已复制到剪贴板"];
}

- (void)pasteReplaceCode {
    if (self.readOnly || !_editor.editable) return;
    NSString *clip = UIPasteboard.generalPasteboard.string;
    if (!clip.length) return;
    _editor.text = clip;
    [self updateCodeStatusBar];
    [self showTemporaryPrompt:@"已从剪贴板替换代码"];
}

- (void)promptFindInCode {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"搜索代码" message:@"输入要定位的函数名、字段或配置键（支持循环查找下一处）" preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakAlert = alert;
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){
        field.placeholder = @"输入关键字";
        field.text = weakSelf.lastSearchQuery ?: @"";
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"定位下一处" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){
        ServiceCodeViewController *owner = weakSelf;
        if (!owner) return;
        NSString *query = weakAlert.textFields.firstObject.text ?: @"";
        if (!query.length || !owner->_editor.text.length) return;
        owner.lastSearchQuery = query;
        NSString *fullText = owner->_editor.text;
        NSMutableArray<NSValue *> *matches = [NSMutableArray array];
        NSRange searchRange = NSMakeRange(0, fullText.length);
        while (searchRange.location < fullText.length) {
            NSRange found = [fullText rangeOfString:query options:NSCaseInsensitiveSearch range:searchRange];
            if (found.location == NSNotFound) break;
            [matches addObject:[NSValue valueWithRange:found]];
            searchRange.location = NSMaxRange(found);
            searchRange.length = fullText.length - searchRange.location;
        }
        if (!matches.count) {
            [owner showTemporaryPrompt:[NSString stringWithFormat:@"未找到「%@」", query]];
            return;
        }
        NSUInteger currentEnd = NSMaxRange(owner->_editor.selectedRange);
        NSUInteger matchIndex = 0;
        for (NSUInteger i = 0; i < matches.count; i++) {
            if (matches[i].rangeValue.location >= currentEnd) {
                matchIndex = i;
                break;
            }
        }
        NSRange range = matches[matchIndex].rangeValue;
        [owner->_editor becomeFirstResponder];
        owner->_editor.selectedRange = range;
        [owner->_editor scrollRangeToVisible:range];
        [owner updateCodeStatusBar];
        [owner showTemporaryPrompt:[NSString stringWithFormat:@"已定位「%@」（第 %lu/%lu 处）", query, (unsigned long)matchIndex + 1, (unsigned long)matches.count]];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)promptReplaceInCode {
    if (self.readOnly || !_editor.editable) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"查找并替换代码" message:@"支持单步替换下一处或全文批量替换（如批量更换域名、请求头或参数名）" preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakAlert = alert;
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){
        field.placeholder = @"要查找的内容";
        field.text = weakSelf.lastSearchQuery ?: @"";
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){
        field.placeholder = @"替换为（可留空表示删除）";
        field.text = weakSelf.lastReplaceText ?: @"";
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"替换下一处" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){
        ServiceCodeViewController *owner = weakSelf;
        if (!owner || !owner->_editor.editable) return;
        NSString *findStr = weakAlert.textFields.firstObject.text ?: @"";
        NSString *replaceStr = weakAlert.textFields.count > 1 ? (weakAlert.textFields[1].text ?: @"") : @"";
        if (!findStr.length || !owner->_editor.text.length) return;
        owner.lastSearchQuery = findStr;
        owner.lastReplaceText = replaceStr;
        NSString *fullText = owner->_editor.text;
        NSUInteger startLoc = owner->_editor.selectedRange.location != NSNotFound ? NSMaxRange(owner->_editor.selectedRange) : 0;
        NSRange forwardRange = NSMakeRange(MIN(startLoc, fullText.length), fullText.length - MIN(startLoc, fullText.length));
        NSRange found = [fullText rangeOfString:findStr options:0 range:forwardRange];
        if (found.location == NSNotFound && startLoc > 0) {
            found = [fullText rangeOfString:findStr options:0 range:NSMakeRange(0, MIN(startLoc, fullText.length))];
        }
        if (found.location == NSNotFound) {
            [owner showTemporaryPrompt:[NSString stringWithFormat:@"未找到「%@」", findStr]];
            return;
        }
        owner->_editor.text = [fullText stringByReplacingCharactersInRange:found withString:replaceStr];
        NSRange newRange = NSMakeRange(found.location, replaceStr.length);
        [owner applySyntaxHighlightingIfNeeded];
        owner->_editor.selectedRange = newRange;
        [owner->_editor scrollRangeToVisible:newRange];
        [owner updateCodeStatusBar];
        [owner showTemporaryPrompt:[NSString stringWithFormat:@"已替换 1 处「%@」", findStr]];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"全部替换" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a){
        ServiceCodeViewController *owner = weakSelf;
        if (!owner || !owner->_editor.editable) return;
        NSString *findStr = weakAlert.textFields.firstObject.text ?: @"";
        NSString *replaceStr = weakAlert.textFields.count > 1 ? (weakAlert.textFields[1].text ?: @"") : @"";
        if (!findStr.length || !owner->_editor.text.length) return;
        owner.lastSearchQuery = findStr;
        owner.lastReplaceText = replaceStr;
        NSString *fullText = owner->_editor.text;
        NSUInteger count = 0;
        NSRange searchRange = NSMakeRange(0, fullText.length);
        while (searchRange.location < fullText.length) {
            NSRange found = [fullText rangeOfString:findStr options:0 range:searchRange];
            if (found.location == NSNotFound) break;
            count++;
            searchRange.location = NSMaxRange(found);
            searchRange.length = fullText.length - searchRange.location;
        }
        if (count == 0) {
            [owner showTemporaryPrompt:[NSString stringWithFormat:@"未找到「%@」", findStr]];
            return;
        }
        owner->_editor.text = [fullText stringByReplacingOccurrencesOfString:findStr withString:replaceStr];
        [owner applySyntaxHighlightingIfNeeded];
        [owner updateCodeStatusBar];
        [owner showTemporaryPrompt:[NSString stringWithFormat:@"已全部替换 %lu 处", (unsigned long)count]];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)promptGoToLine {
    NSString *text = _editor.text ?: @"";
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    NSUInteger totalLines = MAX((NSUInteger)1, lines.count);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"跳转到指定行号" message:[NSString stringWithFormat:@"当前代码共 %lu 行，请输入 1–%lu 之间的行号", (unsigned long)totalLines, (unsigned long)totalLines] preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){
        field.placeholder = [NSString stringWithFormat:@"1–%lu", (unsigned long)totalLines];
        field.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"跳转" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){
        ServiceCodeViewController *owner = weakSelf;
        if (!owner) return;
        NSInteger targetLine = [weakAlert.textFields.firstObject.text integerValue];
        if (targetLine < 1) return;
        NSString *currentText = owner->_editor.text ?: @"";
        NSArray<NSString *> *currentLines = [currentText componentsSeparatedByString:@"\n"];
        NSUInteger clampedLine = MIN((NSUInteger)targetLine, MAX((NSUInteger)1, currentLines.count));
        NSUInteger offset = 0;
        for (NSUInteger i = 0; i + 1 < clampedLine && i < currentLines.count; i++) {
            offset += currentLines[i].length + 1;
        }
        NSUInteger lineLen = (clampedLine - 1 < currentLines.count) ? currentLines[clampedLine - 1].length : 0;
        NSRange lineRange = NSMakeRange(MIN(offset, currentText.length), MIN(lineLen, currentText.length - MIN(offset, currentText.length)));
        [owner->_editor becomeFirstResponder];
        owner->_editor.selectedRange = lineRange;
        [owner->_editor scrollRangeToVisible:lineRange];
        [owner updateCodeStatusBar];
        [owner showTemporaryPrompt:[NSString stringWithFormat:@"已跳转到第 %lu 行", (unsigned long)clampedLine]];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)validateCodeSyntax {
    NSString *text = _editor.text ?: @"";
    if (!text.length) {
        [self showTemporaryPrompt:@"当前代码为空"];
        return;
    }
    NSString *lang = [self detectedCodeLanguageLabel];
    if ([lang isEqualToString:@"JSON"]) {
        NSData *raw = [text dataUsingEncoding:NSUTF8StringEncoding];
        NSError *err = nil;
        id obj = raw.length ? [NSJSONSerialization JSONObjectWithData:raw options:NSJSONReadingFragmentsAllowed error:&err] : nil;
        NSString *title = (obj && !err) ? @"JSON 语法校验通过" : @"JSON 语法校验未通过";
        NSString *msg = (obj && !err) ? [NSString stringWithFormat:@"JSON 结构合法（顶层类型：%@）。", [obj isKindOfClass:NSDictionary.class] ? @"对象 Object" : ([obj isKindOfClass:NSArray.class] ? @"数组 Array" : @"基础值")] : (err.localizedDescription ?: @"存在非法 JSON 语法");
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    // 针对 Python / JavaScript 的字符串与注释感知括号平衡及宿主入口探测
    NSMutableArray<NSDictionary *> *stack = [NSMutableArray array];
    NSUInteger line = 1, col = 0;
    unichar quoteChar = 0;
    BOOL inLineComment = NO, inBlockComment = NO, escaped = NO;
    NSString *mismatchDetail = nil;
    NSUInteger len = text.length;
    for (NSUInteger i = 0; i < len; i++) {
        unichar c = [text characterAtIndex:i];
        unichar next = (i + 1 < len) ? [text characterAtIndex:i + 1] : 0;
        if (c == '\n') {
            line++; col = 0; inLineComment = NO; escaped = NO; continue;
        }
        col++;
        if (inLineComment) continue;
        if (inBlockComment) {
            if (c == '*' && next == '/') { inBlockComment = NO; i++; col++; }
            continue;
        }
        if (quoteChar != 0) {
            if (escaped) { escaped = NO; continue; }
            if (c == '\\') { escaped = YES; continue; }
            if (c == quoteChar) quoteChar = 0;
            continue;
        }
        if ([lang isEqualToString:@"Python"] && c == '#') { inLineComment = YES; continue; }
        if ([lang isEqualToString:@"JavaScript"] && c == '/' && next == '/') { inLineComment = YES; i++; col++; continue; }
        if ([lang isEqualToString:@"JavaScript"] && c == '/' && next == '*') { inBlockComment = YES; i++; col++; continue; }
        if (c == '\'' || c == '"' || ([lang isEqualToString:@"JavaScript"] && c == '`')) { quoteChar = c; continue; }
        if (c == '(' || c == '[' || c == '{') {
            [stack addObject:@{@"char": @(c), @"line": @(line), @"col": @(col)}];
        } else if (c == ')' || c == ']' || c == '}') {
            unichar expected = (c == ')') ? '(' : ((c == ']') ? '[' : '{');
            NSDictionary *top = stack.lastObject;
            if (!top || [top[@"char"] unsignedShortValue] != expected) {
                mismatchDetail = [NSString stringWithFormat:@"第 %lu 行第 %lu 列发现多余或不匹配的闭合符号 '%C'", (unsigned long)line, (unsigned long)col, c];
                break;
            }
            [stack removeLastObject];
        }
    }
    if (!mismatchDetail && stack.count > 0) {
        NSDictionary *unclosed = stack.lastObject;
        mismatchDetail = [NSString stringWithFormat:@"第 %@ 行第 %@ 列开启的符号 '%C' 未闭合", unclosed[@"line"], unclosed[@"col"], [unclosed[@"char"] unsignedShortValue]];
    }
    NSString *jsEngineSyntaxError = nil;
    if (!mismatchDetail && [lang isEqualToString:@"JavaScript"]) {
        JSContext *syntaxCtx = [[JSContext alloc] init];
        __block NSString *capturedJSException = nil;
        syntaxCtx.exceptionHandler = ^(JSContext *ctx, JSValue *exception) {
            NSNumber *errLine = [exception[@"line"] isNumber] ? [exception[@"line"] toNumber] : nil;
            capturedJSException = errLine ? [NSString stringWithFormat:@"第 %@ 行：%@", errLine, exception.toString] : exception.toString;
        };
        // 将顶层 ESM import/export 转为等行注释后用 Function 构造器做只编译不执行的 AST 语法检查
        static NSRegularExpression *esmRe = nil;
        static dispatch_once_t esmOnce;
        dispatch_once(&esmOnce, ^{
            esmRe = [NSRegularExpression regularExpressionWithPattern:@"(?m)^\\s*(?:import\\s+.*|export\\s+(?:default\\s+)?)" options:0 error:NULL];
        });
        NSString *compileCandidate = esmRe ? [esmRe stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@"// "] : text;
        syntaxCtx[@"__candidateSource"] = compileCandidate;
        [syntaxCtx evaluateScript:@"new Function(__candidateSource);"];
        if (capturedJSException.length) {
            jsEngineSyntaxError = capturedJSException;
        }
    }
    NSMutableArray<NSString *> *detectedEntries = [NSMutableArray array];
    for (NSString *fn in @[@"home", @"category", @"search", @"detail", @"play", @"init"]) {
        if ([text containsString:fn]) [detectedEntries addObject:fn];
    }
    NSInteger inferredPort = [ServiceStore inferredPortInCode:text];
    NSString *inferredPlaylist = [ServiceStore inferredPlaylistPathInCode:text];
    NSMutableString *report = [NSMutableString string];
    [report appendFormat:@"识别语言：%@\n", lang];
    [report appendFormat:@"括号与代码块结构：%@\n", mismatchDetail ?: @"全部平衡通过（() / [] / {} 闭合正常）"];
    if ([lang isEqualToString:@"JavaScript"]) {
        [report appendFormat:@"JavaScriptCore 语法编译：%@\n", jsEngineSyntaxError ?: @"AST 编译通过（无 SyntaxError）"];
    }
    if (detectedEntries.count) [report appendFormat:@"检测到插件方法关键字：%@\n", [detectedEntries componentsJoinedByString:@"、"]];
    if (inferredPort > 0) [report appendFormat:@"识别脚本默认端口：%ld\n", (long)inferredPort];
    if (inferredPlaylist.length) [report appendFormat:@"识别直播列表路由：%@", inferredPlaylist];
    BOOL hasIssue = (mismatchDetail != nil) || (jsEngineSyntaxError != nil);
    UIAlertController *a = [UIAlertController alertControllerWithTitle:hasIssue ? @"代码结构预检发现问题" : @"代码结构预检通过" message:[report stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)insertCodeTemplate:(NSString *)templateKind {
    if (self.readOnly || !_editor.editable) return;
    NSString *tpl = nil;
    if ([templateKind isEqualToString:@"python-http"]) {
        tpl = @"import os\nfrom http.server import BaseHTTPRequestHandler, HTTPServer\n\nPORT = int(os.environ.get('CCTVHOST_PORT', '18768'))\n\nclass Handler(BaseHTTPRequestHandler):\n    def do_GET(self):\n        if self.path == '/health':\n            body = b'{\"ok\":true}'\n            self.send_response(200)\n            self.send_header('Content-Type', 'application/json')\n            self.end_headers()\n            self.wfile.write(body)\n        elif self.path == '/all.m3u':\n            m3u = '#EXTM3U\\n#EXTINF:-1,示例频道\\nhttps://example.com/live.m3u8\\n'.encode('utf-8')\n            self.send_response(200)\n            self.send_header('Content-Type', 'application/vnd.apple.mpegurl; charset=utf-8')\n            self.end_headers()\n            self.wfile.write(m3u)\n        else:\n            self.send_response(404)\n            self.end_headers()\n\nif __name__ == '__main__':\n    HTTPServer(('127.0.0.1', PORT), Handler).serve_forever()\n";
    } else if ([templateKind isEqualToString:@"python-spider"]) {
        tpl = @"# CCTVHost Python 影视 Spider 模板\nclass Spider:\n    def init(self, extend=''):\n        pass\n\n    def homeContent(self, filter=False):\n        return {'class': [{'type_id': '1', 'type_name': '电影'}], 'list': []}\n\n    def categoryContent(self, tid, pg, filter=False, extend=None):\n        return {'list': [], 'page': pg, 'pagecount': 1}\n\n    def detailContent(self, ids):\n        return {'list': []}\n\n    def searchContent(self, key, quick=False):\n        return {'list': []}\n\n    def playerContent(self, flag, id, vipFlags=None):\n        return {'parse': 0, 'url': id, 'header': {}}\n";
    } else if ([templateKind isEqualToString:@"js-media"]) {
        tpl = @"// CCTVHost JavaScript 影视插件模板 (cctvhost.media/1)\nmodule.exports = {\n  async capabilities() {\n    return ['home', 'category', 'search', 'detail', 'play'];\n  },\n  async home() {\n    return { categories: [{ id: 'movie', name: '精选' }], items: [] };\n  },\n  async category({ id, page = 1 }) {\n    return { items: [], page, hasMore: false };\n  },\n  async search({ wd, page = 1 }) {\n    return { items: [] };\n  },\n  async detail({ id }) {\n    return { id, name: '', lines: [] };\n  },\n  async play({ id }) {\n    return { url: id, headers: {}, parse: 0 };\n  }\n};\n";
    }
    if (!tpl.length) return;
    _editor.text = tpl;
    [self updateCodeStatusBar];
    [self showTemporaryPrompt:@"已插入标准脚本模板"];
}

- (void)resetBundledCodeIfApplicable {
    if (self.readOnly || !self.bundledResourcePath.length) return;
    NSString *factoryCode = [NSString stringWithContentsOfFile:self.bundledResourcePath encoding:NSUTF8StringEncoding error:NULL];
    if (!factoryCode.length) {
        [self showTemporaryPrompt:@"未找到内置初始代码文件"];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"恢复内置初始代码？" message:@"当前编辑器中的修改将被还原为随应用提供的初始脚本内容，点击右上角保存后生效。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"恢复初始代码" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a){
        ServiceCodeViewController *owner = weakSelf;
        if (!owner) return;
        owner->_editor.text = factoryCode;
        [owner updateCodeStatusBar];
        [owner showTemporaryPrompt:@"已恢复为内置初始代码"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)formatJSONIfApplicable {
    NSData *raw = [_editor.text dataUsingEncoding:NSUTF8StringEncoding];
    if (!raw.length || raw.length > 2 * 1024 * 1024) return;
    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:raw options:NSJSONReadingFragmentsAllowed error:&err];
    if (err || !obj) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"JSON 校验未通过" message:err.localizedDescription ?: @"当前内容不是有效的 JSON" preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    NSData *pretty = [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
    if (pretty.length && !self.readOnly) {
        _editor.text = [[NSString alloc] initWithData:pretty encoding:NSUTF8StringEncoding];
        [self updateCodeStatusBar];
        [self showTemporaryPrompt:@"JSON 校验通过并已格式化"];
    } else {
        [self showTemporaryPrompt:@"JSON 校验通过"];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.isMovingFromParentViewController || self.isBeingDismissed) {
        dispatch_block_t onClose = self.onCloseCode;
        self.onCloseCode = nil;
        if (onClose) onClose();
    }
}

- (void)dealloc {
    dispatch_block_t onClose = self.onCloseCode;
    self.onCloseCode = nil;
    if (onClose) onClose();
}

- (void)requestCloseCodeEditor {
    if (self.readOnly || !_editor.editable || [_editor.text isEqualToString:self.initialCodeText ?: @""]) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"代码有尚未保存的修改" message:@"是否保存对当前代码文件的更改？" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"继续编辑" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"保存并返回" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ [weakSelf save]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"放弃修改" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a){ [weakSelf.navigationController popViewControllerAnimated:YES]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)save {
    if(!_editor.editable)return;
    if (self.onWillSaveCode) {
        NSError *validationError = nil;
        if (!self.onWillSaveCode(_editor.text ?: @"", &validationError)) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"内容校验未通过"
                                                                       message:validationError.localizedDescription ?: @"请检查输入格式后重试。"
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
            return;
        }
    }
    NSError *error = nil;
    BOOL ok = [_editor.text writeToFile:self.path atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if (ok) {
        self.initialCodeText = [_editor.text copy];
        self.onCloseCode = nil;
        if (self.onSaveCode) self.onSaveCode();
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"保存失败"
                                                                   message:error.localizedDescription
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }
}
@end

@interface ServiceEditorViewController () <UIDocumentPickerDelegate,UIGestureRecognizerDelegate,NSURLSessionDataDelegate>
- (BOOL)customCodeMatchesSavedVersion;
- (BOOL)writeCodeForService:(NSDictionary *)service;
- (void)applyPortChange:(NSDictionary *)service;
- (void)applySaveForService:(NSDictionary *)service;
- (void)persistService:(NSDictionary *)service;
- (void)finishSavingService:(NSDictionary *)service;
- (void)dismissKeyboard;
- (void)updateSourceControlFont;
@property(nonatomic, strong) UITextField *nameField;
@property(nonatomic, strong) UITextField *portField;
@property(nonatomic, strong) UITextField *playlistPathField;
@property(nonatomic, strong) UITextField *urlField;
@property(nonatomic, strong) UITextField *argsField;
@property(nonatomic, strong) UISwitch *lanSwitch;
@property(nonatomic, strong) UISegmentedControl *sourceControl;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *code;
@property(nonatomic, strong) NSURLSessionDataTask *downloadTask;
@property(nonatomic, strong) NSURLSession *downloadSession;
@property(nonatomic, strong) NSMutableData *downloadData;
@property(nonatomic) NSUInteger downloadGeneration;
@property(nonatomic, copy) NSString *downloadFailureMessage;
@property(nonatomic, copy) NSString *downloadRequestedURL;
@property(nonatomic,copy) NSDictionary *initialDraft;
@property(nonatomic,weak) id<UIGestureRecognizerDelegate> previousPopDelegate;
- (void)draftChanged;
- (void)portFieldChanged;
- (NSDictionary *)draftSnapshot;
- (void)requestClose;
@property(nonatomic, assign) BOOL downloading;
@property(nonatomic, copy) NSString *optionsText;
@property(nonatomic, assign) BOOL entryCodeEdited;
@property(nonatomic, assign) BOOL applyingPortChange;
@property(nonatomic) NSUInteger applyPortGeneration;
@property(nonatomic, copy) NSString *cachedSection0Footer;
- (void)refreshSection0FooterCache;
-  (void)urlChanged;
-  (NSString *)draftPath;
-  (NSString *)optionsDraftPath;
-  (void)save;
-  (void)editManual;
-  (void)presentCodeDocumentPicker;
-  (void)loadRemote;
@end
@implementation ServiceEditorViewController
- (BOOL)managedCode {return [self.service[@"builtin"] boolValue] || [self.service[@"manifest"] isKindOfClass:NSDictionary.class];}
- (BOOL)isReadOnlyCode {return [self.service[@"builtin"] boolValue];}
- (nullable NSString *)bundledFactoryCodePath {
    return [ServiceStore bundledFactoryCodePathForService:self.service];
}
- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}
- (UITextField *)field:(NSString *)placeholder value:(NSString *)value {
    UITextField *f = [UITextField new];
    f.attributedPlaceholder = [[NSAttributedString alloc] initWithString:placeholder?:@"" attributes:@{NSForegroundColorAttributeName:HostSecondaryText()}];
    f.text = value;
    f.textColor = HostText();
    f.tintColor = HostAccent();
    f.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    f.adjustsFontForContentSizeCategory=YES;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    [f addTarget:self action:@selector(draftChanged) forControlEvents:UIControlEventEditingChanged];
    [f.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    return f;
}
- (void)assignAvailablePort {
    NSMutableSet<NSNumber *> *usedPorts=[NSMutableSet set];
    for(NSDictionary *other in [ServiceStore services]){
        if(![other[@"id"] isEqual:self.identifier]){
            NSInteger p=[other[@"port"] integerValue];
            if(p>0)[usedPorts addObject:@(p)];
        }
    }
    NSInteger inferred=[ServiceStore inferredPortInCode:self.code];
    if(inferred>=1024&&inferred<=65535&&![usedPorts containsObject:@(inferred)]){
        self.portField.text=[NSString stringWithFormat:@"%ld",(long)inferred];
        [self draftChanged];
        return;
    }
    NSInteger candidate=18768;
    while([usedPorts containsObject:@(candidate)]&&candidate<65535)candidate++;
    self.portField.text=[NSString stringWithFormat:@"%ld",(long)candidate];
    [self draftChanged];
}
- (void)pasteURLIntoField {
    NSString *clip=[UIPasteboard.generalPasteboard.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!clip.length)return;
    self.urlField.text=clip;
    [self urlChanged];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = HostSelectedInterfaceStyle();
    self.title = self.service ? @"编辑资源" : @"添加资源配置";
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"返回" style:UIBarButtonItemStylePlain target:self action:@selector(requestClose)];
    self.tableView.backgroundColor = HostBackground();
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 76;
    self.identifier = self.service[@"id"] ?: NSUUID.UUID.UUIDString;
    [NSFileManager.defaultManager removeItemAtPath:[self draftPath] error:NULL];
    [NSFileManager.defaultManager removeItemAtPath:[self optionsDraftPath] error:NULL];
    self.nameField = [self field:@"服务名称" value:self.service[@"name"]];
    self.portField = [self field:@"端口 1024–65535" value:[self.service[@"port"] description] ?: @"18768"];
    self.portField.keyboardType = UIKeyboardTypeNumberPad;
    [self.portField addTarget:self action:@selector(portFieldChanged) forControlEvents:UIControlEventEditingChanged];
    UIButton *autoPortBtn=[UIButton buttonWithType:UIButtonTypeSystem];
    [autoPortBtn setTitle:@"自动分配" forState:UIControlStateNormal];
    autoPortBtn.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    autoPortBtn.tintColor=HostAccent();
    autoPortBtn.backgroundColor=HostSelectedSurface();
    autoPortBtn.layer.cornerRadius=10;
    autoPortBtn.layer.cornerCurve=kCACornerCurveContinuous;
    HostInstallPressFeedback(autoPortBtn);
    autoPortBtn.frame=CGRectMake(0,0,68,36);
    autoPortBtn.accessibilityLabel=@"自动分配可用端口";
    autoPortBtn.accessibilityHint=@"在 1024–65535 范围内分配一个未被占用的端口";
    autoPortBtn.accessibilityTraits=UIAccessibilityTraitButton;
    [autoPortBtn addTarget:self action:@selector(assignAvailablePort) forControlEvents:UIControlEventTouchUpInside];
    self.portField.rightView=autoPortBtn;
    self.portField.rightViewMode=UITextFieldViewModeAlways;
    // 数字键盘没有 Return 键：给一个完成按钮收键盘，否则只能靠拖动列表收起。
    UIToolbar *portToolbar=[[UIToolbar alloc] init];[portToolbar sizeToFit];
    UIBarButtonItem *portDone=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(dismissKeyboard)];
    portToolbar.items=@[[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],portDone];
    self.portField.inputAccessoryView=portToolbar;
    NSString *configuredPlaylistPath=([self.service[@"playlistPathSource"] isEqual:@"inferred"]||[self.service[@"playlistPathSource"] isEqual:@"detected"])?@"":[ServiceStore playlistPathForService:self.service];
    self.playlistPathField=[self field:@"留空自动识别，或填 /all.m3u" value:configuredPlaylistPath];self.playlistPathField.autocapitalizationType=UITextAutocapitalizationTypeNone;
    self.urlField = [self field:@"https://…/service.py" value:self.service[@"url"]];
    self.urlField.keyboardType = UIKeyboardTypeURL;
    UIButton *pasteURLBtn=[UIButton buttonWithType:UIButtonTypeSystem];
    [pasteURLBtn setTitle:@"粘贴" forState:UIControlStateNormal];
    pasteURLBtn.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    pasteURLBtn.tintColor=HostAccent();
    pasteURLBtn.backgroundColor=HostSelectedSurface();
    pasteURLBtn.layer.cornerRadius=10;
    pasteURLBtn.layer.cornerCurve=kCACornerCurveContinuous;
    HostInstallPressFeedback(pasteURLBtn);
    pasteURLBtn.frame=CGRectMake(0,0,48,36);
    pasteURLBtn.accessibilityLabel=@"粘贴剪贴板中的代码链接";
    pasteURLBtn.accessibilityHint=@"将剪贴板内容填入远程代码 URL 输入框";
    pasteURLBtn.accessibilityTraits=UIAccessibilityTraitButton;
    [pasteURLBtn addTarget:self action:@selector(pasteURLIntoField) forControlEvents:UIControlEventTouchUpInside];
    self.urlField.rightView=pasteURLBtn;
    self.urlField.rightViewMode=UITextFieldViewModeUnlessEditing;
    self.urlField.clearButtonMode=UITextFieldViewModeWhileEditing;
    [self.urlField addTarget:self action:@selector(urlChanged) forControlEvents:UIControlEventEditingChanged];
    self.argsField = [self field:@"参数以 | 分隔，可用 {port} / {bind}" value:self.service[@"arguments"]];
    self.lanSwitch = [UISwitch new];
    self.lanSwitch.onTintColor = HostAccent();
    self.lanSwitch.on = [self.service[@"lan"] boolValue];
    self.lanSwitch.accessibilityLabel=@"允许局域网访问";
    self.lanSwitch.accessibilityHint=@"开启后同一局域网内的设备可访问此服务";
    [self.lanSwitch addTarget:self action:@selector(draftChanged) forControlEvents:UIControlEventValueChanged];
    self.sourceControl = [[UISegmentedControl alloc] initWithItems:@[ @"文件", @"链接", @"代码" ]];
    self.sourceControl.accessibilityLabel=@"服务代码来源";
    self.sourceControl.accessibilityHint=@"选择服务代码来自文件、链接或直接输入代码";
    self.sourceControl.selectedSegmentTintColor=HostAccentFill();
    [self updateSourceControlFont];
    self.sourceControl.selectedSegmentIndex = 1;
    [self.sourceControl addTarget:self
                           action:@selector(sourceChanged)
                 forControlEvents:UIControlEventValueChanged];
    if (self.service && ![self managedCode])
        self.code = [NSString stringWithContentsOfFile:[ServiceStore codePath:self.service]
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
    [self.sourceControl.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [self refreshSection0FooterCache];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave
                                                      target:self
                                                      action:@selector(save)];
    self.navigationItem.rightBarButtonItem.accessibilityLabel=@"保存资源配置";
    self.navigationItem.rightBarButtonItem.accessibilityHint=@"校验并保存当前资源名称、端口、代码与网络配置";
}
- (void)reloadThemeAppearance {
    if(!self.isViewLoaded)return;
    self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.view.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.tableView.backgroundColor=HostBackground();
    for(UITextField *f in @[self.nameField,self.portField,self.playlistPathField,self.urlField,self.argsField]){
        f.textColor=HostText();f.tintColor=HostAccent();
    }
    self.lanSwitch.onTintColor=HostAccent();
    self.sourceControl.selectedSegmentTintColor=HostAccentFill();
    [self.tableView reloadData];
}
- (void)dealloc {
    [self.downloadTask cancel];
    [self.downloadSession invalidateAndCancel];
}
- (void)dismissKeyboard {[self.view endEditing:YES];}
- (void)updateSourceControlFont {
    // 分段控件标题默认 13pt 固定字号，大字体下会截断：跟随辅助字体。
    [self.sourceControl setTitleTextAttributes:@{NSFontAttributeName:[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]} forState:UIControlStateNormal];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if(previousTraitCollection&&![previousTraitCollection.preferredContentSizeCategory isEqualToString:self.traitCollection.preferredContentSizeCategory])[self updateSourceControlFont];
    if(previousTraitCollection&&[self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection])[self reloadThemeAppearance];
}
- (void)urlChanged {
    self.downloadGeneration++;[self.downloadTask cancel];self.downloadTask=nil;[self.downloadSession invalidateAndCancel];self.downloadSession=nil;self.downloadData=nil;self.downloadFailureMessage=nil;self.downloading=NO;
    if (![self managedCode]) {
        self.code = nil;
        [self refreshSection0FooterCache];
    }
    [self draftChanged];
}
- (void)sourceChanged {
    [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0   ? 2
           : section == 1 ? ([self managedCode] ? 1 : 3)
           : section == 2 ? ([self.service[@"builtin"] boolValue] ? 1 : 3)
                          : 1;
}
- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section { HostStyleSectionHeaderView(view); }
- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section { HostStyleSectionFooterView(view); }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if(section==3)return nil;
    // Node.js 服务此前被误标为“Python 服务”。
    return @[ ([self.service[@"engine"] isEqual:@"node"]?@"Node.js 服务":([self.service[@"engine"] isEqual:@"javascript"]?@"JavaScript 服务":@"Python 服务")), @"代码来源", @"网络与启动", @"" ][section];
}
- (void)refreshSection0FooterCache {
    NSString *sourceCode = self.code;
    if (!sourceCode.length && self.service) {
        NSString *entry = [ServiceStore codePath:self.service];
        NSDictionary *attrs = entry.length ? [NSFileManager.defaultManager attributesOfItemAtPath:entry error:NULL] : nil;
        if (entry.length && [attrs[NSFileSize] unsignedLongLongValue] <= 256 * 1024) {
            sourceCode = [NSString stringWithContentsOfFile:entry encoding:NSUTF8StringEncoding error:NULL];
        }
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSInteger inferredPort = (sourceCode.length ? [ServiceStore inferredPortInCode:sourceCode] : 0) ?: [self.service[@"inferredPort"] integerValue];
    if (inferredPort >= 1024 && inferredPort <= 65535) [parts addObject:[NSString stringWithFormat:@"脚本默认端口 %ld",(long)inferredPort]];
    NSString *playlist = (sourceCode.length ? [ServiceStore inferredPlaylistPathInCode:sourceCode] : nil) ?: [ServiceStore playlistPathForService:self.service];
    if (playlist.length) [parts addObject:[NSString stringWithFormat:@"直播路由 %@",playlist]];
    NSString *epg = (sourceCode.length ? [ServiceStore inferredEPGPathInCode:sourceCode] : nil) ?: [ServiceStore epgPathForService:self.service];
    if (epg.length) [parts addObject:[NSString stringWithFormat:@"节目单路由 %@",epg]];
    NSInteger currentPort = self.portField.text.integerValue;
    NSString *conflictWarning = nil;
    if (currentPort >= 1024 && currentPort <= 65535) {
        for (NSDictionary *other in [ServiceStore services]) {
            if (![other[@"id"] isEqual:self.identifier] && [other[@"port"] integerValue] == currentPort) {
                conflictWarning = [NSString stringWithFormat:@"⚠ 端口 %ld 已被「%@」占用，建议点右侧“自动分配”更换端口。", (long)currentPort, other[@"name"] ?: other[@"id"]];
                break;
            }
        }
    }
    NSString *recognized = parts.count ? [NSString stringWithFormat:@"已识别：%@ · 宿主会自动将服务与本机节目单端口对齐至上方设置的端口。",[parts componentsJoinedByString:@" · "]] : nil;
    if (conflictWarning && recognized) self.cachedSection0Footer = [NSString stringWithFormat:@"%@\n%@", conflictWarning, recognized];
    else self.cachedSection0Footer = conflictWarning ?: recognized;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return self.cachedSection0Footer;
    }
    if (section == 1)
        return @"导入后可查看、编辑或导出代码。内置服务代码只读。";
    if (section == 2)
        return @"自定义脚本的参数用 | 分隔，支持 {port}、{bind}、{dataDir}。直播列表路径可留空自动识别；手动填写时只接受本机绝对路径，例如 /all.m3u。服务可按 ID 分别启停；"
               @"并行运行时每个 HTTP 服务必须使用不同端口。常见 Python HTTPServer 会采用这里设置的端口；其他框架请将启动参数设为 {port} 或读取 CCTVHOST_PORT。";
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                                reuseIdentifier:nil];
    c.backgroundColor = HostCard();
    c.layer.cornerRadius = 14;
    c.layer.cornerCurve = kCACornerCurveContinuous;
    c.clipsToBounds = YES;
    c.layer.borderWidth = 0.6;
    HostSetLayerBorderColor(c, HostBorder());
    c.textLabel.textColor = HostText();
    c.detailTextLabel.textColor = HostSecondaryText();
    c.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    c.textLabel.adjustsFontForContentSizeCategory=YES;
    c.textLabel.numberOfLines=0;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    UIView *input = nil;
    if (ip.section == 0) {
        c.textLabel.text = ip.row == 0 ? @"服务名称" : @"本机端口";
        input = ip.row == 0 ? self.nameField : self.portField;
    } else if (ip.section == 1) {
        if ([self managedCode]) {
            c.textLabel.text = [self.service[@"manifest"] isKindOfClass:NSDictionary.class]?([self isReadOnlyCode]?@"查看资源入口代码":@"查看 / 编辑资源入口代码"):@"查看内置代码";
            c.detailTextLabel.text = self.entryCodeEdited ? @"已修改" : ([ServiceStore codePath:self.service].lastPathComponent ?: @"");
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            c.selectionStyle = UITableViewCellSelectionStyleDefault;
        } else if (ip.row == 0)
            input = self.sourceControl;
        else if (ip.row == 1) {
            if (self.sourceControl.selectedSegmentIndex == 1) {
                c.textLabel.text=@"远程代码 URL";
                input = self.urlField;
            } else {
                c.textLabel.text =
                    self.sourceControl.selectedSegmentIndex == 0 ? @"选择 Python 文件" : @"输入 / 编辑代码";
                c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                c.selectionStyle = UITableViewCellSelectionStyleDefault;
            }
        } else {
            c.textLabel.text = self.downloading   ? @"正在加载…"
                               : self.code.length ? @"代码已加载 · 点击查看"
                                                  : @"加载代码";
            c.textLabel.textColor = HostAccent();
            c.selectionStyle = UITableViewCellSelectionStyleDefault;
            if(self.downloading){UIActivityIndicatorView *spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];[spinner startAnimating];c.accessoryView=spinner;}
        }
    } else if (ip.section == 2) {
        if (ip.row == 0) {
            if ([self managedCode]) {
                c.textLabel.text = @"允许局域网访问";
                c.accessoryView = self.lanSwitch;
            } else {
                c.textLabel.text = @"网络绑定";
                c.detailTextLabel.text = @"由脚本启动参数决定";
            }
        } else if(ip.row == 1 && [self.service[@"manifest"] isKindOfClass:NSDictionary.class]){
            c.textLabel.text=@"插件参数";c.detailTextLabel.text=@"编辑账号、画质等 JSON 配置";c.accessoryType=UITableViewCellAccessoryDisclosureIndicator;c.selectionStyle=UITableViewCellSelectionStyleDefault;
        }else if(ip.row==1){c.textLabel.text=@"启动参数";input=self.argsField;}
        else{c.textLabel.text=@"直播列表路径";input=self.playlistPathField;}
    } else {
        c.textLabel.text = @"保存服务";
        c.textLabel.font = HostRoundedFont(16.0, UIFontWeightBold, UIFontTextStyleHeadline);
        c.textLabel.textColor = HostAccent();
        c.textLabel.textAlignment = NSTextAlignmentCenter;
        c.backgroundColor = HostSelectedSurface();
        c.layer.borderWidth = 0.9;
        HostSetLayerBorderColor(c, [HostAccent() colorWithAlphaComponent:0.45]);
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
        c.accessibilityHint=@"保存当前资源配置";
    }
    if (input) {
        NSString *rowTitle=[c.textLabel.text copy];
        c.textLabel.text=nil;
        c.detailTextLabel.text=nil;
        c.accessoryType=UITableViewCellAccessoryNone;
        UIStackView *stack=[[UIStackView alloc] init];
        stack.translatesAutoresizingMaskIntoConstraints=NO;
        stack.axis=UILayoutConstraintAxisVertical;
        stack.alignment=UIStackViewAlignmentFill;
        stack.spacing=rowTitle.length?6:0;
        if(rowTitle.length){
            UILabel *title=[UILabel new];
            title.text=rowTitle;
            title.textColor=HostSecondaryText();
            title.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
            title.adjustsFontForContentSizeCategory=YES;
            title.numberOfLines=0;
            [stack addArrangedSubview:title];
            input.accessibilityLabel=rowTitle;
        }
        if ([input.superview isKindOfClass:UIStackView.class]) {
            [(UIStackView *)input.superview removeArrangedSubview:input];
        }
        [input removeFromSuperview];
        input.translatesAutoresizingMaskIntoConstraints=NO;
        [stack addArrangedSubview:input];
        [c.contentView addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:c.contentView.leadingAnchor constant:16],
            [stack.trailingAnchor constraintEqualToAnchor:c.contentView.trailingAnchor constant:-16],
            [stack.topAnchor constraintEqualToAnchor:c.contentView.topAnchor constant:10],
            [stack.bottomAnchor constraintEqualToAnchor:c.contentView.bottomAnchor constant:-10]
        ]];
    } else {
        c.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        c.detailTextLabel.adjustsFontForContentSizeCategory=YES;
        c.detailTextLabel.numberOfLines=0;
    }
    if(c.selectionStyle!=UITableViewCellSelectionStyleNone){
        c.accessibilityTraits=UIAccessibilityTraitButton;
        if(!c.accessibilityHint.length)c.accessibilityHint=@"点按查看或编辑此行配置";
    }
    return c;
}
- (void)tableView:(UITableView *)tableView didHighlightRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tableView cellForRowAtIndexPath:ip];
    if (!c || c.selectionStyle == UITableViewCellSelectionStyleNone || UIAccessibilityIsReduceMotionEnabled()) return;
    [UIView animateWithDuration:0.10 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.2 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{ c.transform = CGAffineTransformMakeScale(0.984, 0.984); } completion:nil];
}
- (void)tableView:(UITableView *)tableView didUnhighlightRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tableView cellForRowAtIndexPath:ip];
    if (!c) return;
    [UIView animateWithDuration:0.22 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0.2 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{ c.transform = CGAffineTransformIdentity; } completion:nil];
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)point {
    if (ip.section == 0) {
        NSInteger port = self.portField.text.integerValue;
        NSString *path = [self.playlistPathField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!path.length) path = [ServiceStore playlistPathForService:self.service] ?: @"/all.m3u";
        NSString *endpoint = (port >= 1024 && port <= 65535) ? [NSString stringWithFormat:@"http://127.0.0.1:%ld%@", (long)port, path] : nil;
        NSString *serviceName = [self.nameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!endpoint.length && !serviceName.length) return nil;
        return [UIContextMenuConfiguration configurationWithIdentifier:ip previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
            NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
            if (endpoint.length) {
                [actions addObject:[UIAction actionWithTitle:@"复制本机接口地址" image:[UIImage systemImageNamed:@"link"] identifier:nil handler:^(__unused UIAction *a) {
                    UIPasteboard.generalPasteboard.string = endpoint;
                    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, @"本机接口地址已复制");
                }]];
            }
            if (serviceName.length) {
                [actions addObject:[UIAction actionWithTitle:@"复制服务名称" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__unused UIAction *a) {
                    UIPasteboard.generalPasteboard.string = serviceName;
                }]];
            }
            return [UIMenu menuWithTitle:serviceName.length ? serviceName : @"服务配置" children:actions];
        }];
    }
    if (ip.section == 1 && (self.urlField.text.length || self.code.length)) {
        NSString *urlCopy = [self.urlField.text copy];
        NSString *codeCopy = [self.code copy];
        return [UIContextMenuConfiguration configurationWithIdentifier:ip previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
            NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
            if (urlCopy.length) {
                [actions addObject:[UIAction actionWithTitle:@"复制远程代码链接" image:[UIImage systemImageNamed:@"link"] identifier:nil handler:^(__unused UIAction *a) {
                    UIPasteboard.generalPasteboard.string = urlCopy;
                }]];
            }
            if (codeCopy.length) {
                [actions addObject:[UIAction actionWithTitle:@"复制已加载代码" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__unused UIAction *a) {
                    UIPasteboard.generalPasteboard.string = codeCopy;
                }]];
            }
            return actions.count ? [UIMenu menuWithTitle:@"代码来源" children:actions] : nil;
        }];
    }
    return nil;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 3) {
        [self save];
        return;
    }
    if(ip.section==2 && ip.row==1 && [self.service[@"manifest"] isKindOfClass:NSDictionary.class]){
        NSString *path=[self optionsDraftPath];id options=self.service[@"manifest"][@"options"]?:@{};
        if(![NSFileManager.defaultManager fileExistsAtPath:path]){
            if([options isKindOfClass:NSString.class]){
                [(NSString *)options writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            }else{
                NSData *data=[NSJSONSerialization dataWithJSONObject:options options:NSJSONWritingPrettyPrinted|NSJSONWritingFragmentsAllowed error:NULL];
                if(data.length)[data writeToFile:path atomically:YES];
            }
        }
        __weak typeof(self) weakSelf=self;
        ServiceCodeViewController *editor=[ServiceCodeViewController new];editor.path=path;
        editor.onSaveCode=^{ServiceEditorViewController *owner=weakSelf;if(!owner)return;owner.optionsText=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];[owner draftChanged];[owner.tableView reloadData];};
        [self.navigationController pushViewController:editor animated:YES];return;
    }
    if (ip.section != 1)
        return;
    if ([self managedCode]) {
        [self editManual];
        return;
    }
    if (ip.row == 1 && self.sourceControl.selectedSegmentIndex == 0) {
        [self presentCodeDocumentPicker];
    } else if (ip.row == 1 && self.sourceControl.selectedSegmentIndex == 2) {
        [self editManual];
    } else if (ip.row == 2) {
        if (self.sourceControl.selectedSegmentIndex == 1 && !self.code.length)
            [self loadRemote];
        else if (self.sourceControl.selectedSegmentIndex == 0 && !self.code.length)
            [self presentCodeDocumentPicker];
        else
            [self editManual];
    }
}
- (void)presentCodeDocumentPicker {
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[ UTTypePythonScript, UTTypeJavaScript, UTTypeJSON, UTTypePlainText, UTTypeSourceCode ]
                            asCopy:YES];
    p.delegate = self;
    [self presentViewController:p animated:YES completion:nil];
}
- (void)message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"资源配置"
                                                               message:message
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)acceptCode:(NSData *)data {
    if (data.length > 2 * 1024 * 1024) {
        [self message:@"文件超过 2 MB，请选择较小的 Python 脚本。"];
        return;
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text.length) {
        [self message:@"无法读取 UTF-8 Python 代码。"];
        return;
    }
    self.code = text;
    if (!self.service) {
        NSInteger inferredPort = [ServiceStore inferredPortInCode:text];
        if (inferredPort >= 1024 && inferredPort <= 65535 && [self.portField.text isEqualToString:@"18768"]) {
            BOOL used = NO;
            for (NSDictionary *other in [ServiceStore services]) {
                if ([other[@"port"] integerValue] == inferredPort) { used = YES; break; }
            }
            if (!used) self.portField.text = [NSString stringWithFormat:@"%ld", (long)inferredPort];
        }
    }
    [self refreshSection0FooterCache];
    [self draftChanged];
    [self.tableView reloadData];
}
- (void)loadRemote {
    NSURL *url = [NSURL URLWithString:self.urlField.text];
    if (!([url.scheme isEqualToString:@"https"] || [url.scheme isEqualToString:@"http"]) ||
        !url.host.length) {
        [self message:@"请输入有效的 HTTP 或 HTTPS 代码链接。"];
        return;
    }
    [self.downloadTask cancel];[self.downloadSession invalidateAndCancel];self.downloadSession=nil;
    self.downloadGeneration++;self.downloadFailureMessage=nil;self.downloadRequestedURL=[self.urlField.text copy];
    self.downloading = YES;[self draftChanged];
    [self.tableView reloadData];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url];
    r.timeoutInterval = 20;
    NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;config.URLCache=nil;config.requestCachePolicy=NSURLRequestReloadIgnoringLocalCacheData;
    self.downloadSession=[NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:NSOperationQueue.mainQueue];
    self.downloadData=[NSMutableData data];
    self.downloadTask=[self.downloadSession dataTaskWithRequest:r];
    [self.downloadTask resume];
}
// 流式上限：状态码非 200 或声明超过 2 MiB 直接取消，不等整包下完再由 acceptCode 事后判断。
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    if(task!=self.downloadTask){completion(NSURLSessionResponseCancel);return;}
    NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class]?((NSHTTPURLResponse *)response).statusCode:0;
    if(status!=200){self.downloadFailureMessage=@"下载失败，请检查代码链接。";completion(NSURLSessionResponseCancel);return;}
    if(response.expectedContentLength>2*1024*1024){self.downloadFailureMessage=@"文件超过 2 MB，请选择较小的 Python 脚本。";completion(NSURLSessionResponseCancel);return;}
    completion(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if(task!=self.downloadTask)return;
    [self.downloadData appendData:data];
    if(self.downloadData.length>2*1024*1024)[task cancel];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if(task!=self.downloadTask){[session finishTasksAndInvalidate];return;}
    NSUInteger generation=self.downloadGeneration;
    NSData *data=[self.downloadData copy];NSString *failure=self.downloadFailureMessage;BOOL tooLarge=self.downloadData.length>2*1024*1024;
    __weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_main_queue(),^{
        ServiceEditorViewController *owner=weakSelf;if(!owner||generation!=owner.downloadGeneration||![owner.urlField.text isEqualToString:owner.downloadRequestedURL]){[session finishTasksAndInvalidate];return;}
        owner.downloading=NO;owner.downloadTask=nil;owner.downloadData=nil;owner.downloadFailureMessage=nil;[owner.downloadSession finishTasksAndInvalidate];owner.downloadSession=nil;
        if(tooLarge||failure.length)[owner message:tooLarge?@"文件超过 2 MB，请选择较小的 Python 脚本。":failure];
        else if(error)[owner message:error.localizedDescription?:@"下载失败，请检查代码链接。"];
        else [owner acceptCode:data];
        [owner.tableView reloadData];
    });
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *u = urls.firstObject;if(!u)return;
    // 先用文件大小预判，超限直接提示；读取放后台，避免主线程同步读大文件卡顿。
    NSNumber *size=nil;[u getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
    if(size&&size.unsignedLongLongValue>2*1024*1024){[self message:@"文件超过 2 MB，请选择较小的 Python 脚本。"];return;}
    __weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        BOOL scoped=[u startAccessingSecurityScopedResource];
        NSFileHandle *handle=[NSFileHandle fileHandleForReadingFromURL:u error:NULL];NSData *data=nil;BOOL tooLarge=NO;
        @try{data=[handle readDataUpToLength:2*1024*1024+1 error:NULL];if(data.length>2*1024*1024){tooLarge=YES;data=nil;}}@catch(NSException *exception){NSLog(@"[CCTVHost] code import read raised %@",exception.name);data=nil;}@finally{[handle closeAndReturnError:NULL];}
        if(scoped)[u stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(),^{ServiceEditorViewController *owner=weakSelf;if(!owner)return;if(tooLarge)[owner message:@"文件超过 2 MB，请选择较小的 Python 脚本。"];else [owner acceptCode:data];});
    });
}
- (NSString *)draftPath {
    return [[ServiceStore directory]
        stringByAppendingPathComponent:[self.identifier stringByAppendingString:@"-draft.py"]];
}
- (NSString *)optionsDraftPath {return [[ServiceStore directory] stringByAppendingPathComponent:[self.identifier stringByAppendingString:@"-options.json"]];}
- (void)editManual {
    if([self managedCode]){
        ServiceCodeViewController *view=[ServiceCodeViewController new];
        view.path=[ServiceStore codePath:self.service];
        view.bundledResourcePath=[self bundledFactoryCodePath];
        view.readOnly=[self isReadOnlyCode];
        __weak typeof(self) weakSelf=self;
        view.onSaveCode=^{ServiceEditorViewController *owner=weakSelf;if(!owner)return;owner.entryCodeEdited=YES;[owner refreshSection0FooterCache];[owner draftChanged];[owner.tableView reloadData];};
        [self.navigationController pushViewController:view animated:YES];
        return;
    }
    NSString *path = [self draftPath];
    NSError *writeError=nil;
    // 写草稿失败（如空间不足）此前被 error:NULL 吞掉，仍会 push 编辑器打开空文件；
    // 失败时提示并停留。
    if(![self.code ?: @"# Python service\n" writeToFile:path
                                         atomically:YES
                                           encoding:NSUTF8StringEncoding
                                              error:&writeError]){[self message:writeError.localizedDescription?:@"无法写入草稿，请检查存储空间。"];return;}
    ServiceCodeViewController *v = [ServiceCodeViewController new];
    v.path = path;
    v.readOnly = [self managedCode];
    [self.navigationController pushViewController:v animated:YES];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    BOOL codeUpdated = NO;
    if (![self managedCode]) {
        NSString *draftFile = [self draftPath];
        if ([NSFileManager.defaultManager fileExistsAtPath:draftFile]) {
            NSString *text = [NSString stringWithContentsOfFile:draftFile
                                                       encoding:NSUTF8StringEncoding
                                                          error:NULL];
            if (text && ![text isEqualToString:self.code ?: @""]) {
                self.code = text;
                codeUpdated = YES;
            }
        }
    }
    if ([self.service[@"manifest"] isKindOfClass:NSDictionary.class]) {
        NSString *optPath = [self optionsDraftPath];
        if ([NSFileManager.defaultManager fileExistsAtPath:optPath]) {
            self.optionsText = [NSString stringWithContentsOfFile:optPath encoding:NSUTF8StringEncoding error:NULL];
        } else {
            self.optionsText = nil;
        }
    }
    if (codeUpdated) [self refreshSection0FooterCache];
    if(!self.initialDraft)self.initialDraft=[self draftSnapshot];
    UIGestureRecognizer *gesture=self.navigationController.interactivePopGestureRecognizer;
    if(gesture.delegate!=self){self.previousPopDelegate=gesture.delegate;gesture.delegate=self;}
    [self draftChanged];[self.tableView reloadData];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];UIGestureRecognizer *gesture=self.navigationController.interactivePopGestureRecognizer;
    if(gesture.delegate==self)gesture.delegate=self.previousPopDelegate;
    if(self.isMovingFromParentViewController||self.isBeingDismissed){
        [self.downloadTask cancel];self.downloadTask=nil;[self.downloadSession invalidateAndCancel];self.downloadSession=nil;self.downloadGeneration++;self.downloading=NO;
    }
}
- (NSDictionary *)draftSnapshot {
    return @{@"name":self.nameField.text?:@"",@"port":self.portField.text?:@"",@"url":self.urlField.text?:@"",@"arguments":self.argsField.text?:@"",@"playlist":self.playlistPathField.text?:@"",@"lan":@(self.lanSwitch.on),@"code":self.code?:@"",@"options":self.optionsText?:@"",@"entryCodeEdited":@(self.entryCodeEdited)};
}
- (void)portFieldChanged {
    NSInteger port = self.portField.text.integerValue;
    BOOL outOfRange = (port < 1024 || port > 65535);
    BOOL conflict = NO;
    if (!outOfRange) {
        for (NSDictionary *other in [ServiceStore services]) {
            if (![other[@"id"] isEqual:self.identifier] && [other[@"port"] integerValue] == port) { conflict = YES; break; }
        }
    }
    self.portField.textColor = outOfRange ? UIColor.systemRedColor : (conflict ? UIColor.systemOrangeColor : HostText());
    [self refreshSection0FooterCache];
    UITableViewHeaderFooterView *footer = [self.tableView footerViewForSection:0];
    if (footer) {
        footer.textLabel.text = self.cachedSection0Footer;
        [self.tableView beginUpdates];
        [self.tableView endUpdates];
    }
    [self draftChanged];
}
- (void)draftChanged {
    BOOL changed=!self.service||![[self draftSnapshot] isEqual:self.initialDraft];NSInteger port=self.portField.text.integerValue;
    self.navigationItem.rightBarButtonItem.enabled=changed&&!self.downloading&&!self.applyingPortChange&&self.nameField.text.length&&port>=1024&&port<=65535;
}
- (void)requestClose {
    if(self.applyingPortChange)return;
    if([[self draftSnapshot] isEqual:self.initialDraft]){[self.downloadTask cancel];self.downloadTask=nil;[self.downloadSession invalidateAndCancel];self.downloadSession=nil;self.downloadGeneration++;self.downloading=NO;[self.navigationController popViewControllerAnimated:YES];return;}
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"有尚未保存的更改" message:@"可以继续编辑、保存，或放弃本次更改。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"继续编辑" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf=self;
    if(self.navigationItem.rightBarButtonItem.enabled)[alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[weakSelf save];}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"放弃更改" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){ServiceEditorViewController *owner=weakSelf;if(!owner)return;[owner.downloadTask cancel];owner.downloadTask=nil;[owner.downloadSession invalidateAndCancel];owner.downloadSession=nil;owner.downloadGeneration++;[NSFileManager.defaultManager removeItemAtPath:[owner draftPath] error:NULL];[NSFileManager.defaultManager removeItemAtPath:[owner optionsDraftPath] error:NULL];[owner.navigationController popViewControllerAnimated:YES];}]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if(self.applyingPortChange)return NO;
    if(![[self draftSnapshot] isEqual:self.initialDraft]){[self requestClose];return NO;}return YES;
}
- (void)save {
    if(self.applyingPortChange||self.downloading)return;
    NSInteger port = self.portField.text.integerValue;
    NSString *name =
        [self.nameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length || port < 1024 || port > 65535) {
        [self message:@"请填写名称，以及 1024–65535 范围内的端口。"];
        return;
    }
    if (![self managedCode] && !self.code.length) {
        [self message:@"请先加载或输入 Python 代码。"];
        return;
    }
    NSMutableDictionary *service = [self.service ?: @{} mutableCopy];
    service[@"id"] = self.identifier;
    service[@"name"] = name;
    service[@"port"] = @(port);
    service[@"lan"] = @(self.lanSwitch.on);
    NSString *arguments=self.argsField.text?:@"";
    if(![arguments isEqual:(self.service[@"arguments"]?:@"")])service[@"argumentsSource"]=@"manual";
    service[@"arguments"] = arguments;
    service[@"url"] = self.urlField.text ?: @"";
    if (self.code.length) {
        NSInteger inferredPort = [ServiceStore inferredPortInCode:self.code];
        if (inferredPort >= 1024 && inferredPort <= 65535) service[@"inferredPort"] = @(inferredPort);
        NSString *inferredEPG = [ServiceStore inferredEPGPathInCode:self.code];
        if (inferredEPG.length && ![service[@"epgPathSource"] isEqual:@"manual"]) {
            service[@"epgPath"] = inferredEPG;
            service[@"epgPathSource"] = @"inferred";
        }
    }
    NSString *playlistPath=[self.playlistPathField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(playlistPath.length){if(![playlistPath hasPrefix:@"/"]||[playlistPath hasPrefix:@"//"]||playlistPath.length>=128||[playlistPath containsString:@".."]||[playlistPath containsString:@"?"]||[playlistPath containsString:@"#"]||[playlistPath containsString:@"\\"]||[playlistPath containsString:@":"]||[playlistPath rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location!=NSNotFound||[playlistPath rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound){[self message:@"直播列表路径须以单个 / 开头，且不能包含空格、..、查询参数、片段或控制字符。例：/all.m3u"];return;}service[@"playlistPath"]=playlistPath;service[@"playlistPathSource"]=@"manual";}else if(![service[@"playlistPathSource"] isEqual:@"detected"]){[service removeObjectForKey:@"playlistPath"];[service removeObjectForKey:@"playlistPathSource"];} // Keep a verified path when users save unrelated settings.
    service[@"updated"] = @(NSDate.date.timeIntervalSince1970);
    if (self.entryCodeEdited) {
        NSString *factoryPath = [self bundledFactoryCodePath];
        NSData *factoryData = factoryPath.length ? [NSData dataWithContentsOfFile:factoryPath] : nil;
        NSData *currentData = [ServiceStore codePath:self.service].length ? [NSData dataWithContentsOfFile:[ServiceStore codePath:self.service]] : nil;
        if (factoryData.length && [currentData isEqualToData:factoryData]) {
            [service removeObjectForKey:@"userEditedCode"];
        } else {
            service[@"userEditedCode"] = @YES;
        }
    }
    if([service[@"manifest"] isKindOfClass:NSDictionary.class] && self.optionsText){
        NSString *trimmedOpts = [self.optionsText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSError *jsonError=nil;id options=[NSJSONSerialization JSONObjectWithData:[self.optionsText dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingFragmentsAllowed error:&jsonError];
        if(jsonError && [self.service[@"manifest"][@"options"] isKindOfClass:NSString.class] && ![trimmedOpts hasPrefix:@"{"] && ![trimmedOpts hasPrefix:@"["]){
            options = trimmedOpts;
            jsonError = nil;
        }
        if(![options isKindOfClass:NSDictionary.class] && ![options isKindOfClass:NSString.class]){[self message:jsonError.localizedDescription?:@"插件参数须为 JSON 对象或字符串"];return;}
        NSMutableDictionary *manifest=[service[@"manifest"] mutableCopy];manifest[@"options"]=options;service[@"manifest"]=manifest;
    }
    if(self.service){
        BOOL runtimeUnchanged=[self customCodeMatchesSavedVersion]&&!self.entryCodeEdited;
        for(NSString *key in @[@"arguments",@"url",@"playlistPath"]){if(![(self.service[key]?:@"") isEqual:(service[key]?:@"")])runtimeUnchanged=NO;}if([self.service[@"port"] integerValue]!=port||[self.service[@"lan"] boolValue]!=self.lanSwitch.on||![(self.service[@"manifest"]?:@{}) isEqual:(service[@"manifest"]?:@{})])runtimeUnchanged=NO;
        if(runtimeUnchanged){[ServiceStore save:service];[self finishSavingService:service];return;}
    }
    [ServiceStore associateLegacyLoopbackSubscriptionsForService:self.service];
    // 端口冲突只在启动时才报错：保存时先提示，避免悄悄造出一个
    // 启动即失败的端口冲突（对方即使已停止，同时运行仍会冲突）。
    NSDictionary *conflictingService=nil;
    for(NSDictionary *other in [ServiceStore services])if(![other[@"id"] isEqual:self.identifier]&&[other[@"port"] integerValue]==port){conflictingService=other;break;}
    if(conflictingService){
        BOOL conflictingRunning=[PyHost isManagedServiceIdentifier:conflictingService[@"id"]];
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"端口已被占用" message:[NSString stringWithFormat:@"端口 %ld 已被“%@”使用（%@）。同时运行会冲突；只保留一个运行中的服务才能正常监听该端口。",(long)port,conflictingService[@"name"]?:conflictingService[@"id"],conflictingRunning?@"当前运行中":@"当前已停止"] preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        __weak typeof(self) weakSelf=self;
        [alert addAction:[UIAlertAction actionWithTitle:@"仍要保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){service[@"userConfirmedPort"]=@YES;[weakSelf applySaveForService:service];}]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [self applySaveForService:service];
}
- (void)applySaveForService:(NSDictionary *)service {
    NSInteger port=[service[@"port"] integerValue];
    if([PyHost isManagedServiceIdentifier:self.identifier]){
        NSInteger oldPort=[self.service[@"port"] integerValue];
        if(oldPort==port){
            // 只改了名称：不需要重启，直接保存名称并返回；代码无未保存
            // 修改时才允许，改了代码或配置时可一键停止并重启应用。
            NSMutableDictionary *candidate=[service mutableCopy];[candidate removeObjectForKey:@"name"];[candidate removeObjectForKey:@"updated"];
            NSMutableDictionary *current=[self.service mutableCopy];[current removeObjectForKey:@"name"];[current removeObjectForKey:@"updated"];
            for(NSString *key in @[@"url",@"arguments",@"playlistPath",@"playlistPathSource"]){if([candidate[key] isKindOfClass:NSString.class]&&![candidate[key] length])[candidate removeObjectForKey:key];if([current[key] isKindOfClass:NSString.class]&&![current[key] length])[current removeObjectForKey:key];}
            if([candidate isEqualToDictionary:current]&&[self customCodeMatchesSavedVersion]&&!self.entryCodeEdited){[self persistService:service];return;}
            if(!self.onApplyService){[self message:@"此服务仍在运行。停止服务后才能保存其他配置。"];return;}
            UIAlertController *restartAlert=[UIAlertController alertControllerWithTitle:@"应用配置并重启服务？"
                                                                                message:[NSString stringWithFormat:@"%@ 正在运行。将先停止该服务、保存更新后的配置或代码，并在端口 %ld 上重新启动。",self.service[@"name"]?:@"此服务",(long)port]
                                                                         preferredStyle:UIAlertControllerStyleAlert];
            [restartAlert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            __weak typeof(self) weakSelf=self;
            [restartAlert addAction:[UIAlertAction actionWithTitle:@"停止并重启" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[weakSelf applyPortChange:service];}]];
            [self presentViewController:restartAlert animated:YES completion:nil];
            return;
        }
        if(!self.onApplyService){[self message:@"端口尚未保存。请先停止服务，再保存新端口并重新启动。"] ;return;}
        UIAlertController *confirmation=[UIAlertController alertControllerWithTitle:@"应用新端口？"
                                                                              message:[NSString stringWithFormat:@"将停止 %@，把 HTTP 监听端口从 %ld 改为 %ld，再重新启动。重启失败时新端口仍会保存，并显示失败原因。",self.service[@"name"]?:@"此服务",(long)oldPort,(long)port]
                                                                       preferredStyle:UIAlertControllerStyleAlert];
        [confirmation addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        __weak typeof(self) weakSelf=self;
        [confirmation addAction:[UIAlertAction actionWithTitle:@"停止并重启" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[weakSelf applyPortChange:service];}]];
        [self presentViewController:confirmation animated:YES completion:nil];
        return;
    }
    [self persistService:service];
}
- (BOOL)customCodeMatchesSavedVersion {
    if([self managedCode]||[self.service[@"builtin"] boolValue])return YES;
    NSString *saved=[NSString stringWithContentsOfFile:[ServiceStore codePath:self.service]
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    return [saved isEqualToString:self.code?:@""];
}
- (BOOL)writeCodeForService:(NSDictionary *)service {
    if (![service[@"builtin"] boolValue] && ![service[@"manifest"] isKindOfClass:NSDictionary.class]) {
        NSError *error = nil;
        if (![self.code writeToFile:[ServiceStore codePath:service]
                         atomically:YES
                           encoding:NSUTF8StringEncoding
                              error:&error]) {
            [self message:error.localizedDescription];
            return NO;
        }
    }
    return YES;
}
- (void)applyPortChange:(NSDictionary *)service {
    if(self.applyingPortChange)return;
    BOOL hasCustomCode=![service[@"builtin"] boolValue]&&![service[@"manifest"] isKindOfClass:NSDictionary.class];
    NSString *codePath=hasCustomCode?[ServiceStore codePath:service]:nil;
    NSData *previousCodeData=codePath.length?[NSData dataWithContentsOfFile:codePath]:nil;
    if(![self writeCodeForService:service])return;
    self.applyingPortChange=YES;
    self.navigationItem.rightBarButtonItem.enabled=NO;
    __weak typeof(self) weakSelf=self;
    NSUInteger applyGeneration=++self.applyPortGeneration;
    self.onApplyService(self.service,service,^(NSError *error){
        dispatch_async(dispatch_get_main_queue(),^{
            ServiceEditorViewController *owner=weakSelf;if(!owner||applyGeneration!=owner.applyPortGeneration)return;
            owner.applyingPortChange=NO;
            owner.navigationItem.rightBarButtonItem.enabled=YES;
            if(error){
                BOOL saved=[error.userInfo[@"CCTVHostServiceConfigurationSaved"] boolValue];
                if(!saved&&codePath.length&&previousCodeData){[previousCodeData writeToFile:codePath atomically:YES];}
                if(saved){
                    [NSFileManager.defaultManager removeItemAtPath:[owner draftPath] error:NULL];
                    [NSFileManager.defaultManager removeItemAtPath:[owner optionsDraftPath] error:NULL];
                    if(owner.onSave)owner.onSave();
                }
                UIAlertController *alert=[UIAlertController alertControllerWithTitle:saved?@"端口已保存，服务未启动":@"端口更新失败"
                                                                                message:error.localizedDescription?:@"请查看此服务的独立日志。"
                                                                         preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:saved?@"返回服务详情":@"好" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){if(saved)[owner.navigationController popViewControllerAnimated:YES];}]];
                [owner presentViewController:alert animated:YES completion:nil];
                return;
            }
            [owner finishSavingService:service];
        });
    });
    // onApplyService 回调若永不触发，保存按钮会永久禁用：30 秒看门狗兜底复位。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC),dispatch_get_main_queue(),^{ServiceEditorViewController *owner=weakSelf;if(!owner||applyGeneration!=owner.applyPortGeneration||!owner.applyingPortChange)return;owner.applyingPortChange=NO;owner.navigationItem.rightBarButtonItem.enabled=YES;[owner message:@"应用新端口超时，保存按钮已恢复；请查看此服务的独立日志确认状态。"];});
}
- (void)persistService:(NSDictionary *)service {
    if(![self writeCodeForService:service])return;
    [ServiceStore save:service];
    [self finishSavingService:service];
}
- (void)finishSavingService:(NSDictionary *)service {
    [NSFileManager.defaultManager removeItemAtPath:[self draftPath] error:NULL];
    [NSFileManager.defaultManager removeItemAtPath:[self optionsDraftPath] error:NULL];
    if (self.onSave)
        self.onSave();
    [self.navigationController popViewControllerAnimated:YES];
}
@end
