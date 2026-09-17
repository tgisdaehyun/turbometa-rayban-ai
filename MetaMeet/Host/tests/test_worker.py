import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import wave
from test_receiver import fixture, encode
from receiver import Store
from worker import Worker, ready, fingerprint, merge, paragraphs

class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name)
        self.p = fixture(); Store(self.root).accept(*encode(self.p)); self.folder = self.root/self.p['meeting']['id']
        self.state = json.loads((self.folder/'receipt.json').read_text())
    def tearDown(self): self.tmp.cleanup()
    def test_waits_for_all_audio_and_meeting_end(self):
        self.assertTrue(ready(self.state))
        missing = copy.deepcopy(self.state); missing['received'] = {}; self.assertFalse(ready(missing))
        active = copy.deepcopy(self.state); active['meeting']['ended'] = None; self.assertFalse(ready(active))
    def test_fingerprint_ignores_titles_but_detects_audio(self):
        other = copy.deepcopy(self.state); other['meeting']['title'] = 'renamed'; self.assertEqual(fingerprint(other), fingerprint(self.state))
        other['received']['0']['sha256'] = 'new'; self.assertNotEqual(fingerprint(other), fingerprint(self.state))
    def test_merger_preserves_gap_and_checks_original(self):
        self.state['meeting']['chunks'][0]['start'] = 3
        target = self.root/'merged.wav'; gaps = merge(self.folder, self.state, target)
        self.assertEqual(gaps, [{'start': 0, 'end': 3}])
        with wave.open(str(target)) as w: self.assertEqual(w.getnframes(), 4*16000)
        (self.folder/'000000.wav').write_bytes(b'corrupt')
        with self.assertRaises(ValueError): merge(self.folder, self.state, target)
    def test_asr_is_reused_when_translation_resumes(self):
        worker = Worker({'root': str(self.root), 'translation_key_file': str(self.root/'key')})
        result = {'segments': [{'start': 0, 'end': 1, 'text': '你好', 'review_needed': False}], 'duration': 1}
        with patch.object(worker, 'transcribe', return_value=result) as asr:
            worker.process(self.folder)
            output = next((self.folder/'processed').iterdir())
            self.assertEqual(json.loads((output/'status.json').read_text())['stage'], 'translation_key_required')
            self.assertIn('[한국어 번역 대기]', (output/'원문과_한국어.md').read_text())
            (self.root/'key').write_text('test-key'); (output/'status.json').unlink()
            with patch('worker.translate_group', return_value={0: '안녕하세요'}): worker.process(self.folder)
            self.assertEqual(asr.call_count, 1)
            self.assertEqual(json.loads((output/'status.json').read_text())['stage'], 'complete')
            self.assertIn('안녕하세요', (output/'원문과_한국어.md').read_text())
            self.assertFalse(worker.process(self.folder))
    def test_grouping_keeps_all_words_across_silence(self):
        groups = paragraphs([{'start': 0, 'end': 1, 'text': 'one'}, {'start': 10, 'end': 11, 'text': 'two'}])
        self.assertEqual([g['original'] for g in groups], ['one', 'two'])

if __name__ == '__main__': unittest.main()
