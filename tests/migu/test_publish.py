import os
from pathlib import Path
import subprocess
import tempfile
import unittest


PUBLISH = Path("migu/publish.sh").resolve()


class PublishIntegrationTests(unittest.TestCase):
    def git(self, cwd, *args):
        return subprocess.check_output(["git", *args], cwd=cwd, text=True, stderr=subprocess.DEVNULL).strip()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.remote = self.root / "remote.git"
        self.a, self.b = self.root / "a", self.root / "b"
        self.git(self.root, "init", "--bare", "--initial-branch=main", str(self.remote))
        self.git(self.root, "clone", str(self.remote), str(self.a))
        self.git(self.a, "config", "user.name", "Test")
        self.git(self.a, "config", "user.email", "test@example.invalid")
        for path, data in (("README.md", "original\n"), ("update_migu.py", "trusted\n"), ("migu.m3u8", "old\n"), ("migu-status.json", "{}\n")):
            (self.a / path).write_text(data)
        self.git(self.a, "add", ".")
        self.git(self.a, "commit", "-m", "Initial")
        self.git(self.a, "push", "origin", "main")
        self.base = self.git(self.a, "rev-parse", "HEAD")
        self.git(self.root, "clone", str(self.remote), str(self.b))
        self.git(self.b, "config", "user.name", "Contributor")
        self.git(self.b, "config", "user.email", "other@example.invalid")

    def other_push(self, path, data):
        (self.b / path).write_text(data)
        self.git(self.b, "add", "--", path)
        self.git(self.b, "commit", "-m", "Concurrent change")
        self.git(self.b, "push", "origin", "main")
        return self.git(self.b, "rev-parse", "HEAD")

    def publish(self):
        env = os.environ.copy()
        env["GITHUB_SHA"] = self.base
        return subprocess.run(["bash", str(PUBLISH)], cwd=self.a, env=env, text=True, capture_output=True, timeout=20)

    def test_unrelated_concurrent_commit_is_preserved_and_data_update_fast_forwards(self):
        other = self.other_push("README.md", "new unrelated documentation\n")
        (self.a / "migu.m3u8").write_text("fresh validated data\n")
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git(self.remote, "show", "main:README.md"), "new unrelated documentation")
        self.assertEqual(self.git(self.remote, "show", "main:migu.m3u8"), "fresh validated data")
        self.assertEqual(self.git(self.remote, "rev-parse", "main^"), other)

    def test_concurrent_code_change_is_not_overwritten_or_executed(self):
        other = self.other_push("update_migu.py", "different policy\n")
        (self.a / "migu.m3u8").write_text("fresh validated data\n")
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git(self.remote, "rev-parse", "main"), other)
        self.assertEqual(self.git(self.remote, "show", "main:migu.m3u8"), "old")

    def test_unchanged_data_does_not_publish_a_commit(self):
        other = self.other_push("README.md", "concurrent change\n")
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git(self.remote, "rev-parse", "main"), other)

    def test_unrelated_staged_file_cannot_be_committed_by_the_publisher(self):
        (self.a / "README.md").write_text("local work in progress\n")
        self.git(self.a, "add", "README.md")
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git(self.remote, "rev-parse", "main"), self.base)


if __name__ == "__main__":
    unittest.main()
