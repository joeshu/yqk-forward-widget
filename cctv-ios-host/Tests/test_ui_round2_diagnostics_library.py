import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOG = (ROOT / "Sources/LogCenterViewController.m").read_text()
DIAG = (ROOT / "Sources/RuntimeDiagnosticsViewController.m").read_text()
BROWSER = (ROOT / "Sources/MediaBrowserViewController.m").read_text()
BROWSER_LINES = BROWSER.splitlines()
FEED = (ROOT / "Sources/MediaFeedView.m").read_text()


def browser_head():
    # 本轮范围只到详情页接口之前；行号以 @interface MediaDetailViewController 为界。
    for i, line in enumerate(BROWSER_LINES):
        if line.startswith("@interface MediaDetailViewController"):
            return "\n".join(BROWSER_LINES[:i])
    raise AssertionError("MediaDetailViewController boundary not found")


HEAD = browser_head()


class LogCenterRound2Tests(unittest.TestCase):
    def test_category_colors_use_adaptive_system_colors(self):
        # 上一轮的硬编码 RGB 在两套浅色主题下对比度不足（浅蓝在白卡上约 2:1）。
        self.assertNotIn("colorWithRed:1 green:0.34 blue:0.38", LOG)
        self.assertNotIn("colorWithRed:0.36 green:0.75 blue:1", LOG)
        self.assertNotIn("colorWithRed:0.76 green:0.56 blue:1", LOG)
        self.assertIn("UIColor.systemRedColor", LOG)
        self.assertIn("UIColor.systemBlueColor", LOG)
        self.assertIn("UIColor.systemPurpleColor", LOG)

    def test_summary_label_grows_with_dynamic_type(self):
        # 统计行固定 22pt 在超大字体下截断：只定下限并允许换行。
        self.assertIn("self.summaryLabel.numberOfLines=0", LOG)
        self.assertIn("constraintGreaterThanOrEqualToConstant:22", LOG)
        self.assertNotIn("heightAnchor constraintEqualToConstant:22", LOG)

    def test_empty_label_wraps_and_keeps_side_margins(self):
        self.assertIn("self.emptyLabel.numberOfLines=0", LOG)
        self.assertIn("constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:24", LOG)
        self.assertIn("constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-24", LOG)

    def test_log_cell_row_is_bounds_checked(self):
        # applyFilter 与 reloadData 之间 visibleLines 可能已变，越界取值会崩溃。
        self.assertIn("indexPath.row>=self.visibleLines.count", LOG)

    def test_log_row_copy_is_announced_to_accessibility(self):
        self.assertIn('cell.accessibilityHint=@"点按复制这行日志"', LOG)


class RuntimeDiagnosticsRound2Tests(unittest.TestCase):
    def test_stale_async_loads_are_discarded_by_generation(self):
        # viewWillAppear 与删除/清空后的 reload 可能重叠，旧加载后完成会把已删会话写回。
        self.assertIn("reloadGeneration", DIAG)
        self.assertIn("owner.reloadGeneration!=generation", DIAG)
        self.assertIn("self.reloadGeneration++;NSUInteger generation=self.reloadGeneration;", DIAG)

    def test_event_fields_are_null_safe(self):
        # 磁盘 JSON 里的 NSNull 进 %@ 只显示“<null>”，但 boolValue/数值取值会崩溃。
        self.assertIn('[event[@"category"] isKindOfClass:NSString.class] ? event[@"category"] : @"unknown"', DIAG)
        self.assertIn('[event[@"time"] isKindOfClass:NSString.class] ? event[@"time"] : @"时间未知"', DIAG)
        self.assertIn('[event[@"event"] isKindOfClass:NSString.class] ? event[@"event"] : @"未知事件"', DIAG)

    def test_session_fields_are_null_safe(self):
        self.assertIn('[session[@"started_at"] isKindOfClass:NSString.class] ? session[@"started_at"] : @"开始时间未知"', DIAG)
        self.assertIn('[session[@"is_current"] isKindOfClass:NSNumber.class]?[session[@"is_current"] boolValue]:NO', DIAG)
        self.assertIn('[session[@"is_open"] isKindOfClass:NSNumber.class]?[session[@"is_open"] boolValue]:NO', DIAG)
        self.assertIn('[session[@"cleanly_ended"] isKindOfClass:NSNumber.class]?[session[@"cleanly_ended"] boolValue]:NO', DIAG)
        self.assertIn('[session[@"bytes"] isKindOfClass:NSNumber.class] ? [session[@"bytes"] unsignedLongLongValue] : 0', DIAG)
        self.assertIn('[session[@"event_count"] isKindOfClass:NSNumber.class]?[session[@"event_count"] unsignedIntegerValue]:0', DIAG)
        self.assertIn('[session[@"last_event"] isKindOfClass:NSString.class]?session[@"last_event"]:@"未知"', DIAG)

    def test_async_delete_and_export_do_not_retain_the_page(self):
        # 删除/清空/导出的完成回调曾强引用 self：页面已 pop 后仍会弹提示或刷新。
        self.assertIn("RuntimeDiagnosticsViewController *owner=weakSelf;if(!owner)return;", DIAG)
        self.assertIn("UIBarButtonItem *anchor = owner.exportButton;", DIAG)
        self.assertIn("if(owner)[owner reloadRecords];", DIAG)

    def test_message_alert_is_skipped_when_page_is_not_visible(self):
        self.assertIn("if(!self.view.window)return;", DIAG)


class MediaLibraryRound2Tests(unittest.TestCase):
    def test_detail_page_boundary_is_untouched(self):
        self.assertTrue(any(line.startswith("@interface MediaDetailViewController") for line in BROWSER_LINES))
        self.assertNotIn("@implementation MediaDetailViewController", HEAD)

    # 旧发现页 MediaDiscoveryCell/MediaPosterCell 已被 413 的 MediaFeedView
    # 取代：feed 海报 cell 没有每格 more 按钮与状态标签，故无 44pt more
    # 按钮及其与状态标签重叠的问题；下面三项断言改为 feed 的等价实现。
    # （原 test_discovery_more_button_meets_44pt_touch_target 已随旧 cell 删除。）

    def test_feed_status_label_height_follows_dynamic_type(self):
        # feed 海报 cell 的片名/副标题用 preferredFont + adjustsFont，
        # 行高按当前字号的 lineHeight 算，超大字体下不截断。
        self.assertIn("self.nameLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.nameLabel.adjustsFontForContentSizeCategory=YES", FEED)
        self.assertIn("self.detailLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];self.detailLabel.adjustsFontForContentSizeCategory=YES", FEED)
        self.assertIn("CGFloat titleHeight=ceil(self.nameLabel.font.lineHeight)*2,detailHeight=ceil(self.detailLabel.font.lineHeight)", FEED)

    def test_feed_labels_use_scaled_fonts(self):
        # feed 分组头与 hero 标题用 UIFontMetrics 缩放字号，默认字号外观不变。
        self.assertIn("scaledFontForFont:[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]", FEED)
        self.assertIn("scaledFontForFont:[UIFont systemFontOfSize:27 weight:UIFontWeightBold]", FEED)
        self.assertIn("adjustsFontForContentSizeCategory=YES", FEED)

    def test_feed_poster_cell_placeholder_matches_film_fallback(self):
        # 普通媒体无海报时显示 film 占位；WebDAV 目录显示 folder 图标。
        # 海报仍经带重试的加载器取图，成功后 HostImageLoader 将 contentMode
        # 复位为 AspectFill；目录卡不请求图片。
        self.assertIn('self.poster.image=[UIImage systemImageNamed:directory?@"folder.fill":@"film"];self.poster.contentMode=UIViewContentModeCenter;self.poster.tintColor=HostSecondaryText();', FEED)
        self.assertIn("self.poster.contentMode=UIViewContentModeScaleAspectFill", FEED)
        self.assertIn("MediaFeedLoadPosterWithRetry(poster,self.poster,1)", FEED)
        self.assertIn("self.poster.image=nil", FEED)

    def test_source_picker_scope_buttons_meet_44pt_height(self):
        # 分组 pill 高 42pt（52 头高 - 上 6 - 下 4）：上边距改 4 后为 44pt。
        self.assertIn("constraintEqualToAnchor:header.topAnchor constant:4", HEAD)
        self.assertNotIn("constraintEqualToAnchor:header.topAnchor constant:6", HEAD)

    def test_source_picker_choices_are_type_checked(self):
        # choices 是外部可设的公开属性：非字典条目或 NSNull 字段进
        # choice[@"name"] / length / boolValue 会因不识别 selector 而崩溃。
        self.assertIn("if(![choice isKindOfClass:NSDictionary.class])continue;", HEAD)
        self.assertIn('label=[choice[@"scopeName"] isKindOfClass:NSString.class]?choice[@"scopeName"]:nil', HEAD)
        self.assertIn('cell.textLabel.text=[choice[@"name"] isKindOfClass:NSString.class]?choice[@"name"]:@""', HEAD)
        self.assertIn('NSString *subtitle=[choice[@"subtitle"] isKindOfClass:NSString.class]?choice[@"subtitle"]:nil', HEAD)
        self.assertIn('NSString *url=[choice[@"url"] isKindOfClass:NSString.class]?choice[@"url"]:nil', HEAD)
        self.assertIn('BOOL selected=[choice[@"selected"] isKindOfClass:NSNumber.class]?[choice[@"selected"] boolValue]:NO', HEAD)
        self.assertIn("if(index.row<0||index.row>=self.shown.count)return;", HEAD)


if __name__ == "__main__":
    unittest.main()
