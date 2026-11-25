import pathlib
import re
import unittest

SOURCES = pathlib.Path(__file__).resolve().parents[1] / "Sources"


def read(name):
    return (SOURCES / name).read_text(encoding="utf-8")


class P1CleanupContracts(unittest.TestCase):
    def test_try_count_stays_below_budget(self):
        total = sum(len(re.findall(r"@try\b", p.read_text(encoding="utf-8"))) for p in SOURCES.rglob("*") if p.suffix in (".m", ".h", ".mm"))
        self.assertLess(total, 40, "@try should be limited to real exception boundaries")

    def test_pure_logic_try_removed(self):
        self.assertNotIn("@try", read("PlaybackInfoViewController.m"))
        self.assertNotIn("@try", read("ProfileStore.m"))
        self.assertNotIn("@try", read("PyHost.m"))
        self.assertNotIn("@try", read("ResourceImportFetcher.m"))

    def test_jar_long_waits_reject_main_thread(self):
        jar = read("MediaJARRuntime.m")
        perform = jar.split("@implementation MediaJARRuntime", 1)[1].split("+ (id)perform:", 1)[1].split("\n+ ", 1)[0]
        guard = 'if(NSThread.isMainThread){if(error)*error=JARError(15,@"JAR 服务须从后台调用");return nil;}'
        self.assertIn(guard, perform)
        self.assertLess(perform.index(guard), perform.index("dispatch_semaphore_wait"))
        request = jar.split("@implementation MediaJARRuntime", 1)[1].split("+ (MediaJARRequest *)requestSource:", 1)[1].split("\n+ (id)perform:", 1)[0]
        self.assertIn('completion(nil,JARError(15,@"JAR 服务须从后台调用"))', request)
        self.assertLess(request.index("if(NSThread.isMainThread){"), request.index("dispatch_semaphore_wait"))

    def test_cicada_sdk_boundary_logs(self):
        cicada = read("MediaPlaybackCicadaAdapter.m")
        self.assertIn("static BOOL CicadaGuarded(SEL sel, void (NS_NOESCAPE ^block)(void))", cicada)
        self.assertNotIn("@catch (NSException *e) {}", cicada)


if __name__ == "__main__":
    unittest.main()
