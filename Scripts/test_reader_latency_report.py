import unittest

from reader_latency_report import distribution, summarize


class ReaderLatencyReportTests(unittest.TestCase):
    def test_budgets_use_inclusive_cutoffs_and_nearest_rank(self):
        self.assertEqual(distribution([3000.01, 1000, 2000, 3000]), {
            "n": 4, "p50_ms": 2000, "p95_ms": 3000.01,
            "within_1s": 1, "within_2s": 2, "within_3s": 3,
        })

    def test_interrupted_or_mixed_spans_are_not_cache_hits(self):
        events = [
            (1, "loaded_presentation_begin"), (2, "loaded_composite_memory_hit"),
            (4, "loaded_presentation_end"),
            (5, "loaded_presentation_begin"), (6, "loaded_composite_memory_hit"),
            (7, "export_render_end"), (8, "loaded_presentation_end"),
            (9, "loaded_presentation_begin"), (10, "export_render_end"),
            (11, "loaded_presentation_end"),
        ]
        rows = [dict(reader_event=name, event=name, pid="1", seq=str(seq),
                     trace="abc", page_token="42", outcome="0", elapsed_ms="1999")
                for seq, name in events]
        report = summarize(rows)
        self.assertEqual(report["omissions"]["interrupted_presentation"], 1)
        self.assertEqual(report["omissions"]["failed_or_unclassified_presentation"], 1)
        self.assertEqual(report["render_hit_bitmap"]["n"], 0)
        self.assertEqual(report["render_cold"]["within_2s"], 1)
