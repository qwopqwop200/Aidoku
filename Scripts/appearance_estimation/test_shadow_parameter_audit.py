import unittest
from audit_shadow_parameters import measure


class ShadowParameterAuditTests(unittest.TestCase):
    def test_abstention_and_absent_shadow_cannot_hide_labelled_parameter_failures(self):
        rows=[dict(itemID=str(i),evaluationSplit='dev',shadow=dict(present=True,rgb=[80,80,80],offsetPx=[1,2])) for i in range(3)]
        predictions=[dict(itemID='0',shadow=dict(present=True,rgb=[80,80,80],offsetPx=[1,2])),
            dict(itemID='1',shadow=dict(present=True,rgb=None,offsetPx=None)),
            dict(itemID='2',shadow=dict(present=False,rgb=[80,80,80],offsetPx=[1,2]))]
        result=measure(rows,predictions)
        self.assertEqual(result['dev']['colour']['labelled'],3)
        self.assertEqual(result['dev']['colour']['within10IncludingMissing'],1/3)
        self.assertEqual(result['dev']['offset']['missing'],2)
        self.assertEqual(result['dev']['offset']['within2IncludingMissing'],1/3)
        self.assertIsNone(result['test']['colour']['within10IncludingMissing'])

    def test_mismatched_prediction_order_is_rejected(self):
        with self.assertRaises(ValueError):measure([dict(itemID='first')],[dict(itemID='second')])


if __name__=='__main__':unittest.main()
