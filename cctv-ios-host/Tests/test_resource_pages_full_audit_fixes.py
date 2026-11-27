import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parent.parent / "Sources"


def read_src(name: str) -> str:
    return (ROOT / name).read_text(encoding="utf-8")


class ResourcePagesFullAuditFixesTests(unittest.TestCase):
    # ------------------------------------------------------------------
    # Batch 1: Resource Main Page & Coordination Layer
    # ------------------------------------------------------------------
    def test_batch1_root_services_hardening(self):
        src = read_src("RootViewController+Services.m")
        self.assertIn("CCTVURLFromPossiblyUnescapedString([item[@\"url\"] isKindOfClass:NSString.class]?item[@\"url\"]:@\"\")", src)
        self.assertIn("self.pendingTVBoxSiteName=nil;self.pendingTVBoxExt=nil;", src)
        self.assertIn("__weak UIAlertController *weakCredential=credential;", src)
        self.assertIn("[site[@\"ext\"] isKindOfClass:NSString.class]", src)
        self.assertIn("![packageRoot isKindOfClass:NSString.class]||!packageRoot.length", src)
        self.assertIn("self.subscriptionURLs.allObjects", src)

    def test_batch1_root_subscriptions_hardening(self):
        src = read_src("RootViewController+Subscriptions.m")
        self.assertIn("douban-index:", src)
        self.assertIn("![source isKindOfClass:NSString.class]||!source.length", src)
        self.assertIn("[owner deleteSubscription:deletedKey];", src)
        self.assertIn("refreshExistingResourceMatches", src)
        self.assertIn("udpxyMap[sourceKey]?:udpxyMap[url.absoluteString]", src)
        self.assertIn("__weak UIAlertController *weakAlert=a;", src)

    def test_batch1_config_center_hardening(self):
        src = read_src("ConfigCenterViewController.m")
        self.assertIn("@property(nonatomic, assign) NSUInteger probeGeneration;", src)
        self.assertIn("owner.probeGeneration++;owner.probingResources=NO;", src)
        self.assertIn("reloadProfilesForcingTableReload:", src)
        self.assertIn("__weak UIAlertController *weakAlert=alert;", src)
        self.assertIn("if(w.onMatchStationLogos)w.onMatchStationLogos(source);", src)
        self.assertNotIn("dispatch_semaphore_wait", src)

    # ------------------------------------------------------------------
    # Batch 2: Import Workflow, Subscription Subpage & TVBox/Package Layer
    # ------------------------------------------------------------------
    def test_batch2_profile_store_and_xmltv_hardening(self):
        prof = read_src("ProfileStore.m")
        self.assertIn("source=source.length?source:CCTVNativeLogoSourceKey;", prof)
        self.assertIn("NSPropertyListSerialization propertyList:replacement isValidForFormat:NSPropertyListBinaryFormat_v1_0", prof)
        self.assertIn("if(![source isKindOfClass:NSString.class]||!source.length)return;", prof)

        xmltv = read_src("XMLTVStore.m")
        self.assertIn("value.length==19&&([value characterAtIndex:14]=='+'||[value characterAtIndex:14]=='-')", xmltv)
        self.assertIn("@property(nonatomic,strong) NSMutableSet<NSString *> *forcedSources;", xmltv)
        self.assertIn("if(generation==self.generation&&!_paused){self.tasks[source]=task;shouldResume=YES;}", xmltv)

    def test_batch2_import_workflow_and_subscription_subpage(self):
        imp = read_src("ResourceImportWorkflowViewController.m")
        self.assertIn("self.addressPlaceholder.hidden=self.address.text.length>0;", imp)
        self.assertIn("BOOL selectable=!row[@\"saved\"]&&!row[@\"error\"]&&!row[@\"saveError\"]&&![row[@\"kind\"] isEqual:@\"page\"]&&![row[@\"unsupportedOnly\"] boolValue];", imp)
        self.assertIn("__weak UIAlertController *weakForm=form;", imp)
        self.assertIn("@\"retryOrigin\":url.absoluteString?:@\"\"", imp)
        self.assertIn("if(error||!data.length){[owner showFailure:error.localizedDescription?:@\"无法读取链接内容\"];return;}", imp)
        self.assertIn("else if(!folder)", imp)

        sub = read_src("SubscriptionResourceViewController.m")
        self.assertIn("if(gesture.delegate!=self)self.previousPopDelegate=gesture.delegate;", sub)
        self.assertIn("@property(nonatomic) NSUInteger refreshGeneration;", sub)
        self.assertIn("if(!owner.editingResource&&!owner.saving)", sub)
        self.assertIn("__weak UIAlertController *weakAlert=alert;", sub)
        self.assertIn("self.onMatchStationLogos();self.refreshing=NO;", sub)

    def test_batch2_tvbox_exporters_and_fetchers(self):
        exp = read_src("TVBoxCatalogPackageExporter.m")
        self.assertIn("@property(nonatomic) BOOL started;", exp)
        self.assertIn("if(self.totalBytes>=buffer.length)self.totalBytes-=buffer.length;else self.totalBytes=0;", exp)
        self.assertIn("self.progressHandler=nil;", exp)
        self.assertIn("if(!queue){[self finish:nil error:", exp)

        bulk = read_src("TVBoxCatalogBulkImporter.m")
        self.assertIn("- (void)dealloc {", bulk)
        self.assertIn("if(!owner){if(service)[ServiceStore remove:service[@\"id\"]];return;}", bulk)

        dl = read_src("TVBoxCatalogDownloader.m")
        self.assertIn("NSURLSession *previousSession=nil;", dl)
        self.assertIn("[previousSession invalidateAndCancel];", dl)

        fetch = read_src("ResourceImportFetcher.m")
        self.assertIn("if(!valid&&!self.failure)", fetch)

    # ------------------------------------------------------------------
    # Batch 3: Services, Plugin Detail, Log Center & Package Downloader
    # ------------------------------------------------------------------
    def test_batch3_media_downloader_plugin_and_detail(self):
        mpd = read_src("MediaPackageDownloader.m")
        self.assertIn("NSData *bodySnapshot=nil;", mpd)
        self.assertIn("NSData *scriptPayload=nil;", mpd)

        pvc = read_src("PluginViewController.m")
        self.assertIn("if(!owner||restartGeneration!=owner.restartGeneration)return;", pvc)

        prd = read_src("PluginResourceDetailViewController.m")
        self.assertIn("if(!owner||toggleGeneration!=owner.toggleGeneration)return;", prd)
        self.assertIn("editor.onWillSaveCode=^BOOL(NSString *code", prd)
        self.assertIn("editor.onCloseCode=^{", prd)
        self.assertIn("self.tempOptionsPath=optPath;", prd)

    def test_batch3_services_and_logs(self):
        svc = read_src("ServicesViewController.m")
        self.assertIn("if (section == 2 && [ServiceStore subscriptionURLForService:self.service].length > 0) return 13;", svc)
        self.assertIn("self.emptyLabel.hidden=visibleSections.count>0;", svc)
        self.assertIn("dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{", svc)
        self.assertIn("重启服务失败", svc)

        lc = read_src("LogCenterViewController.m")
        self.assertIn("if(errs.count){UIPasteboard.generalPasteboard.string=", lc)

        pls = read_src("PluginLogStore.m")
        self.assertIn("- (NSString *)formattedRunTimestamp:(id)raw", pls)
        self.assertIn("rangeOfComposedCharacterSequencesForRange:NSMakeRange(0,48)", pls)

    # ------------------------------------------------------------------
    # Batch 4: Code Editor, ServiceStore & MediaPackageImporter
    # ------------------------------------------------------------------
    def test_batch4_service_store_editor_and_importer(self):
        ss = read_src("ServiceStore.m")
        self.assertIn("BOOL userConfirmed=[mutableService[@\"userConfirmedPort\"] boolValue];", ss)
        self.assertIn("addProtected([dataDir stringByAppendingPathComponent:@\"plugin-logs\"]);", ss)
        self.assertIn("addProtected(previousImport[@\"packageRoot\"]);", ss)

        se = read_src("ServiceEditorViewController.m")
        self.assertIn("__weak UIAlertController *weakAlert = alert;", se)
        self.assertIn("NSMaxRange(owner->_editor.selectedRange)", se)
        self.assertIn("if (self.onWillSaveCode)", se)
        self.assertIn("if(!owner||applyGeneration!=owner.applyPortGeneration)return;", se)
        self.assertIn("if(!saved&&codePath.length&&previousCodeData)", se)
        self.assertIn("service[@\"userConfirmedPort\"]=@YES;", se)

        mpi = read_src("MediaPackageImporter.m")
        self.assertIn("PackageError(error,@\"ZIP 目录项大小无效\")", mpi)


if __name__ == "__main__":
    unittest.main()
