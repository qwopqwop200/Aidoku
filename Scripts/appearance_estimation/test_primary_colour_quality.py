import unittest
import copy
from primary_colour_quality import measure, preserves, strictly_improves


class PrimaryColourQualityTests(unittest.TestCase):
    def rows(self):
        return [dict(itemID=g,group=g,fill=dict(rgb=[0,0,0])) for g in ('train','dev')]

    def predictions(self, value):
        return [dict(itemID=g,fill=dict(rgb=[value]*3,colors=[[value]*3,[0,0,0]]))
                for g in ('train','dev')]

    def test_exact_output_primary_is_measured_not_available_palette(self):
        result=measure(self.rows(),self.predictions(200),lambda r:r['group'])
        self.assertEqual(result['dev']['within10'],0)
        self.assertGreater(result['dev']['meanDeltaE'],50)

    def test_mean_improvement_inside_same_tolerance_is_not_lost(self):
        rows=self.rows();old=measure(rows,self.predictions(15),lambda r:r['group'])
        new=measure(rows,self.predictions(10),lambda r:r['group'])
        self.assertEqual(old['dev']['within10'],new['dev']['within10'])
        self.assertTrue(strictly_improves(old,new))
        self.assertFalse(preserves(new,old))

    def test_more_palette_duplicates_cannot_change_primary_quality(self):
        a=self.predictions(15);b=copy.deepcopy(a)
        for p in b:p['fill']['colors'] += [[0,0,0]]*20
        self.assertEqual(measure(self.rows(),a,lambda r:r['group']),
                         measure(self.rows(),b,lambda r:r['group']))

    def test_test_style_is_not_read(self):
        rows=self.rows()+[dict(itemID='test',group='test')]
        pred=self.predictions(10)+[dict(itemID='test')]
        self.assertEqual(measure(rows,pred,lambda r:r['group'])['dev']['n'],1)

    def test_substyle_can_be_primary_target(self):
        rows=self.rows()
        for r in rows:r['substyles']=[dict(fill=dict(rgb=[20,20,20]))]
        self.assertEqual(measure(rows,self.predictions(20),lambda r:r['group'])['dev']['meanDeltaE'],0)

    def test_correspondence_and_split_count_guard(self):
        with self.assertRaises(ValueError):measure(self.rows(),[],lambda r:r['group'])
        p=self.predictions(10);p.reverse()
        with self.assertRaises(ValueError):measure(self.rows(),p,lambda r:r['group'])
        a=measure(self.rows(),self.predictions(10),lambda r:r['group']);b=copy.deepcopy(a)
        b['train']['n']+=1
        self.assertFalse(preserves(a,b))


if __name__=='__main__':unittest.main()
