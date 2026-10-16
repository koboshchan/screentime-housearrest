import copy
from pathlib import Path
import unittest
from unittest.mock import patch
import test_backend
b=test_backend.b

class AdminDispatchTests(unittest.TestCase):
    def request(self):
        return dict(dayStart=0,dayEnd=86400,revision='a'*64,sessions=[
            dict(id='settings-intentional',bundle='com.apple.systempreferences',
                 start=12300,end=44280)])
    def test_cancel_preserves_entire_request_without_read(self):
        engine=b.Engine('/Users/fixture',status_provider=lambda:dict(sip='disabled'))
        req=self.request();before=copy.deepcopy(req)
        with patch.object(b.local_reset,'authorized_apply',side_effect=b.StorageError('cancel','admin_cancelled')) as admin,patch.object(engine,'read') as read:
            with self.assertRaises(b.StorageError):engine.apply(req)
            admin.assert_called_once()
            read.assert_not_called()
        self.assertEqual(req,before)
    def test_sip_on_never_prompts(self):
        engine=b.Engine('/Users/fixture',status_provider=lambda:dict(sip='enabled'))
        with patch.object(b.local_reset,'authorized_apply') as admin,patch.object(engine,'read',side_effect=RuntimeError('fixture stop')):
            with self.assertRaises(RuntimeError):engine.apply(self.request())
            admin.assert_not_called()
    def test_explicit_fixture_never_prompts(self):
        engine=b.Engine('/Users/fixture',status_provider=lambda:dict(sip='disabled'),reset_paths=(Path('/fixture/light'),Path('/fixture/cache')))
        with patch.object(b.local_reset,'authorized_apply') as admin,patch.object(engine,'read',side_effect=RuntimeError('fixture stop')):
            with self.assertRaises(RuntimeError):engine.apply(self.request())
            admin.assert_not_called()
    def test_authorized_process_never_reprompts(self):
        engine=b.Engine('/Users/fixture',status_provider=lambda:dict(sip='disabled'))
        with patch.dict(b.__dict__,{'AUTHORIZED_HELPER':True}),patch.object(b.local_reset,'authorized_apply') as admin,patch.object(engine,'read',side_effect=RuntimeError('fixture stop')):
            with self.assertRaises(RuntimeError):engine.apply(self.request())
            admin.assert_not_called()
    def test_invalid_request_rejected_before_prompt(self):
        engine=b.Engine('/Users/fixture',status_provider=lambda:dict(sip='disabled'))
        with patch.object(b.local_reset,'authorized_apply') as admin:
            with self.assertRaises(b.StorageError):engine.apply({})
            admin.assert_not_called()
