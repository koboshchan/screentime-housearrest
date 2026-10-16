"""No authorization, device writes or root execution. Pure fixture/static checks."""
import ast
import base64
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import test_backend

b=test_backend.b
r=b.local_reset
ROOT=Path(__file__).resolve().parents[1]

class AdminHelperTests(unittest.TestCase):
    def fake_file(self):
        return '/Users/fixture/ScreenTimeEditor.app/Contents/Resources/ScreenTimeEditor.bundle/Contents/Resources/local_reset.py'
    def call(self, result):
        with patch.object(r,'__file__',self.fake_file()), patch.object(b,'no_symlink_parents'), patch.object(Path,'is_file',return_value=True), patch.object(r.subprocess,'run',side_effect=[SimpleNamespace(returncode=0),SimpleNamespace(returncode=0),result]) as run:
            response=r.authorized_apply({'dayStart':1,'sessions':[]},b)
            self.assertEqual(run.call_count,3)
            self.assertEqual(run.call_args_list[0].args[0][0],'/usr/bin/codesign')
            self.assertEqual(run.call_args_list[1].args[0][0],'/usr/bin/codesign')
            return response,run.call_args
    def test_signed_copy_before_verify_before_execute(self):
        response,args=self.call(SimpleNamespace(returncode=0,stdout='{"status":"ok"}',stderr=''))
        self.assertEqual(response['status'],'ok')
        argv=args.args[0]
        self.assertEqual(argv[:2],['/usr/bin/osascript','-e'])
        script=argv[2]
        shell=json.loads(script[len('do shell script '):-len(' with administrator privileges')])
        self.assertLess(shell.index('/bin/cp'),shell.index('/usr/bin/codesign'))
        self.assertLess(shell.index('/usr/bin/codesign'),shell.index('"$d/helper" ',shell.index('/usr/bin/codesign')))
        self.assertIn('certificate leaf = H',shell)
        self.assertIn('/private/var/tmp/ScreenTimeAdmin.',shell)
        self.assertIn('trap',shell)
        self.assertNotIn('password',script)
        self.assertNotIn('python',shell)
    def test_cancel_no_fallback(self):
        with self.assertRaises(b.StorageError) as error:
            self.call(SimpleNamespace(returncode=1,stdout='',stderr='User canceled. (-128)'))
        self.assertEqual(error.exception.code,'admin_cancelled')
    def test_structured_partial_failure_survives(self):
        with self.assertRaises(b.StorageError) as error:
            self.call(SimpleNamespace(returncode=0,stdout='{"error":"partial backed up","code":"partial_apply_failed"}',stderr=''))
        self.assertEqual(error.exception.code,'partial_apply_failed')
    def test_missing_bundle_refused(self):
        with patch.object(r,'__file__','/tmp/local_reset.py'):
            with self.assertRaises(b.StorageError) as error:r.authorized_apply({},b)
        self.assertEqual(error.exception.code,'admin_helper_unavailable')
    def test_request_limit(self):
        with patch.object(r,'__file__',self.fake_file()),patch.object(b,'no_symlink_parents'),patch.object(Path,'is_file',return_value=True),patch.object(r.subprocess,'run',return_value=SimpleNamespace(returncode=0)) as run:
            with self.assertRaises(b.StorageError):r.authorized_apply({'sessions':['x'*66000]},b)
            self.assertEqual(run.call_count,2)
    def test_invalid_actual_signature_prevents_prompt(self):
        with patch.object(r,'__file__',self.fake_file()),patch.object(b,'no_symlink_parents'),patch.object(Path,'is_file',return_value=True),patch.object(r.subprocess,'run',return_value=SimpleNamespace(returncode=1)) as run:
            with self.assertRaises(b.StorageError):r.authorized_apply({},b)
            self.assertEqual(run.call_count,1)
            self.assertEqual(run.call_args.args[0][0],'/usr/bin/codesign')
    def test_bootstrap_parse_and_no_disk_backend_import(self):
        source=(ROOT/'Sources/AdminHelper/admin_entry.py').read_text()
        ast.parse(source)
        self.assertIn('os.setreuid(uid, 0)',source)
        self.assertIn('os.seteuid(uid)',source)
        self.assertIn('console != uid',source)
        self.assertIn("set(request) - allowed",source)
        build=(ROOT/'scripts/build_admin_helper.py').read_text()
        self.assertIn("backend.index('_MODULE_PATH = ')",build)
        self.assertIn('"-I", "-S", "-B"',build)
        self.assertNotIn('shell=True',build)

    def test_embedded_user_identity_and_privilege_scope(self):
        import importlib.util
        import os
        import types
        spec=importlib.util.spec_from_file_location('admin_entry_fixture',ROOT/'Sources/AdminHelper/admin_entry.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        seen=[]
        effective=[0]
        def seteuid(uid):effective[0]=uid;seen.append(('euid',uid))
        sources={
          'original_local':"def inject_local(*args): return 'fixture'\n",
          'local_reset':"def discover(engine, api):\n    assert engine.home == '/Users/fixture'\n    return ('fixed-system', 'fixed-user-cache')\n",
          'backend':"class Engine:\n def __init__(self,home): self.home=home\n def apply(self,req):\n  assert AUTHORIZED_HELPER\n  assert self.reset_paths == ('fixed-system','fixed-user-cache')\n  import os\n  assert os.geteuid() == 501\n  try:\n   with local_reset.system_privileges():\n    assert os.geteuid() == 0\n    raise ValueError('fixture')\n  except ValueError: pass\n  assert os.geteuid() == 501\n  return {'status':'fixture-success'}\ndef status(): return {'sip':'disabled'}\ndef require(ok,message,code):\n if not ok: raise ValueError(message)\n"}
        account=types.SimpleNamespace(pw_name='fixture',pw_gid=20,pw_dir='/Users/fixture')
        request=base64.b64encode(b'{"command":"apply"}').decode()
        with patch.object(os,'geteuid',side_effect=lambda:effective[0]),patch.object(os,'seteuid',side_effect=seteuid),patch.object(os,'setreuid') as real,patch.object(os,'setgid'),patch.object(os,'initgroups'),patch.object(os,'stat',return_value=types.SimpleNamespace(st_uid=501)),patch.object(module.pwd,'getpwuid',return_value=account),patch.dict(os.environ,dict(os.environ)),patch('builtins.print') as output:
            module.entry(sources,request,'501')
            real.assert_called_once_with(501,0)
            self.assertEqual(json.loads(output.call_args.args[0])['status'],'fixture-success')
            self.assertEqual(effective[0],501)
            self.assertEqual(seen,[('euid',501),('euid',0),('euid',501)])
    def test_embedded_rejects_path_transport_before_identity_change(self):
        import importlib.util
        import os
        import types
        spec=importlib.util.spec_from_file_location('admin_entry_fixture_reject',ROOT/'Sources/AdminHelper/admin_entry.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        account=types.SimpleNamespace(pw_name='fixture',pw_gid=20,pw_dir='/Users/fixture')
        request=base64.b64encode(b'{"command":"apply","home":"/var/root"}').decode()
        with patch.object(os,'geteuid',return_value=0),patch.object(os,'stat',return_value=types.SimpleNamespace(st_uid=501)),patch.object(module.pwd,'getpwuid',return_value=account),patch.object(os,'setreuid') as change:
            with self.assertRaisesRegex(ValueError,'fixed Apply'):module.entry({},request,'501')
            change.assert_not_called()

if __name__=='__main__':unittest.main()
