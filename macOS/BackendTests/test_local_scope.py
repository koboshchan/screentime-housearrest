"""SIP-on and unknown local routes stay user-only. SIP-off dispatch tested separately."""
from pathlib import Path
from unittest.mock import patch
import test_original_local
b=test_original_local.b

class LocalScopeTests(test_original_local.OriginalTests):
    def test_non_admin_sip_states_keep_original_local_scope(self):
        for sip in ("enabled","unknown"):
            with self.subTest(sip=sip):
                self.engine.status_provider=lambda:dict(sip=sip)
                with patch.object(b.local_reset,"prepare",side_effect=AssertionError("system access")) as system, patch.object(b.subprocess,"run",side_effect=AssertionError("unexpected subprocess")):
                    result=self.engine.apply(self.request())
                system.assert_not_called()
                self.assertEqual(result["status"],"SUCCESS_LOGOUT_REQUIRED")
                self.assertTrue(result["logoutRequired"])
                self.assertNotIn("resetBackupPath",result)
                b.verify_backup(Path(result["backupPath"]))

    def test_ship_status_never_advertises_system_reset(self):
        from types import SimpleNamespace
        def runner(args,**kwargs):
            text="System Integrity Protection status: disabled." if "csrutil" in args[0] else "27.0.1"
            return SimpleNamespace(returncode=0,stdout=text,stderr="")
        self.assertEqual(b.status(runner)["supportedWriters"],["original_local"])

# Inherit fixture setup only, not the base test suite a second time.
for name in list(test_original_local.OriginalTests.__dict__):
    if name.startswith("test_") and name not in LocalScopeTests.__dict__:
        setattr(LocalScopeTests,name,None)
