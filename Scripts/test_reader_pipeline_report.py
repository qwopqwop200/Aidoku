import tempfile
import unittest
from pathlib import Path
from reader_pipeline_report import read_events, summarize


class ReaderPipelineReportTests(unittest.TestCase):
    def test_production_camel_case_provider_failure_is_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'events.log'
            path.write_text('time=1 pid=7 seq=1 pipeline_event=providerFailure '
                            'trace=5 page_token=abc attempt=1 retry=1 reason=0 elapsed_ms=25\n')
            report = summarize(read_events([path]))
        self.assertEqual(report['problems'], [dict(time='1', event='providerFailure',
                                                   page_token='abc', trace='5')])
        self.assertEqual(report['phases'][0]['event'], 'providerFailure')

    def test_offscreen_events_join_visible_page_and_sinks_do_not_deduplicate_each_other(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'events.log'
            path.write_text('time=1 pid=7 seq=1 reader_event=page_render_begin trace=5 page_token=abc page=-1\n'
                            'time=1 pid=7 seq=1 pipeline_event=provider_queue trace=5 page_token=abc elapsed_ms=25\n'
                            'time=2 pid=7 seq=2 reader_event=page_render_end trace=5 page_token=abc elapsed_ms=50 outcome=0\n'
                            'time=3 pid=7 seq=3 reader_event=visible_page trace=9 page_token=abc page=60\n'
                            'time=4 pid=7 seq=4 reader_event=visible_page trace=10 page_token=def page=61\n')
            report = summarize(read_events([path, path]), page=60)
            self.assertEqual(report['events'], 4)
            self.assertEqual(report['phases'][0]['max_ms'], 50)
            self.assertEqual(report['unmatched_starts'], [])
            self.assertEqual(report['page_tokens'], ['abc'])

    def test_loss_invalid_metrics_and_legacy_events_are_explicit(self):
        rows = [dict(event='export_render_begin', time='1', pid='1', trace='1', page='60', dropped='5'),
                dict(event='page_failed', time='2', page='60', code='-1', elapsed_ms='nan', outcome='2')]
        report = summarize(rows, page=60)
        self.assertEqual(report['dropped'], 5)
        self.assertEqual(report['phases'], [])
        self.assertEqual(len(report['problems']), 1)
        self.assertEqual(report['unmatched_starts'][0]['stage'], 'export_render')


if __name__ == '__main__':
    unittest.main()
