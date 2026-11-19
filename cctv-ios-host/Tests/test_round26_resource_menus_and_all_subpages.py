import os
import re
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(REPO_ROOT, "Sources")


def read_source(name):
    with open(os.path.join(SOURCES, name), "r", encoding="utf-8") as f:
        return f.read()


class Round26ResourceMenusAndAllSubpagesTests(unittest.TestCase):
    def test_config_center_sort_menu_includes_latency_and_bounds_checked_move(self):
        src = read_source("ConfigCenterViewController.m")
        m_filter = re.search(
            r"- \(void\)showResourceFilters \{.*?\n\}",
            src,
            re.DOTALL,
        )
        self.assertIsNotNone(m_filter)
        filter_body = m_filter.group(0)
        self.assertIn('@"latency":@"测速最快优先"', filter_body)
        self.assertIn("ConfigCenterViewController *owner=weakSelf;", filter_body)

        m_ctx = re.search(
            r"- \(UIContextMenuConfiguration \*\)tableView:\(UITableView \*\)tableView contextMenuConfigurationForRowAtIndexPath:.*?\n\}",
            src,
            re.DOTALL,
        )
        self.assertIsNotNone(m_ctx)
        ctx_body = m_ctx.group(0)
        self.assertIn("if(targetRow<0||targetRow>=(NSInteger)w.profiles.count)continue;", ctx_body)

        m_rm = re.search(
            r"- \(void\)confirmRemoveProfile:\(NSString \*\)source \{.*?\n\}",
            src,
            re.DOTALL,
        )
        self.assertIsNotNone(m_rm)
        self.assertIn("ConfigCenterViewController *owner=weakSelf;", m_rm.group(0))

    def test_tvbox_catalog_keyboard_dismiss_attributed_reset_and_weak_alerts(self):
        src = read_source("TVBoxCatalogViewController.m")
        self.assertIn("UIScrollViewKeyboardDismissModeOnDrag", src)
        self.assertIn("else{cell.detailTextLabel.attributedText=nil;}", src)
        m_sel = re.search(
            r"- \(void\)tableView:\(UITableView \*\)tableView didSelectRowAtIndexPath:\(NSIndexPath \*\)ip \{.*?\n\}",
            src,
            re.DOTALL,
        )
        self.assertIsNotNone(m_sel)
        self.assertIn("__weak typeof(self) weakSelf=self;", m_sel.group(0))
        self.assertNotIn("if(self.onImportSite)", m_sel.group(0))

    def test_plugin_resource_detail_keyboard_dismiss_and_weak_alerts(self):
        src = read_source("PluginResourceDetailViewController.m")
        self.assertIn("UIScrollViewKeyboardDismissModeOnDrag", src)
        m_err = re.search(
            r"- \(void\)showError:\(NSString \*\)message \{.*?\n\}",
            src,
            re.DOTALL,
        )
        self.assertIsNotNone(m_err)
        self.assertIn("owner.onLog", m_err.group(0))

    def test_plugin_run_history_dynamic_deferred_menu_and_keyboard_dismiss(self):
        src = read_source("PluginRunHistoryViewController.m")
        self.assertIn("UIScrollViewKeyboardDismissModeOnDrag", src)
        self.assertIn("UIDeferredMenuElement elementWithUncachedProvider:", src)
        self.assertIn("UIMenuElementAttributesDisabled", src)

    def test_services_and_import_workflow_cell_reuse_and_weak_alerts(self):
        svc = read_source("ServicesViewController.m")
        self.assertIn("c.detailTextLabel.attributedText=nil;", svc)
        m_add = re.search(
            r"- \(void\)add \{.*?\n\}",
            svc,
            re.DOTALL,
        )
        self.assertIsNotNone(m_add)
        self.assertIn("weakSelf.navigationController pushViewController:editor", m_add.group(0))

        wf = read_source("ResourceImportWorkflowViewController.m")
        self.assertIn('dequeueReusableCellWithIdentifier:@"resource.import.candidate"', wf)
        m_choose = re.search(
            r"- \(void\)chooseExistingResourceForCandidate:\(NSMutableDictionary \*\)row \{.*?\n\}",
            wf,
            re.DOTALL,
        )
        self.assertIsNotNone(m_choose)
        self.assertIn("ResourceImportWorkflowViewController *owner=weakSelf;", m_choose.group(0))


if __name__ == "__main__":
    unittest.main()
