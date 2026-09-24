import importlib.util,json,math,os,tempfile,unittest
from pathlib import Path
path = Path(__file__).parent / 'equivalence' / 'compare.py'
spec=importlib.util.spec_from_file_location('compare',path);compare=importlib.util.module_from_spec(spec);spec.loader.exec_module(compare)
class NumericEvidenceTests(unittest.TestCase):
 def test_nonfinite_json_rejected(self):
  for token in ['NaN','Infinity','-Infinity','1e999']:
   with self.subTest(token=token), tempfile.TemporaryDirectory() as directory:
    f=Path(directory)/'x.json';f.write_text('{"nested":[%s]}'%token)
    with self.assertRaises(ValueError):compare.load(f)
 def test_nonfinite_layout_rejected(self):
  for number in [math.nan,math.inf,-math.inf]:
   self.assertFalse(compare.compare_layout({'x':number},{'x':42},0)['ok'])
 def test_boolean_is_not_numeric(self):
  for a,b in [(1,True),(True,1),(0,False),(False,0)]:
   self.assertFalse(compare.compare_layout({'x':a},{'x':b},0)['ok'])
 def test_adjacent_large_integer_is_not_equal(self):
  self.assertFalse(compare.compare_layout({'x':2**53},{'x':2**53+1},0)['ok'])
 def test_nonfinite_region_coordinate_or_confidence_rejected(self):
  for key in ['rectPx','confidence']:
   a={'source':'a','rectPx':[0,0,1,1],'confidence':1.0};b=dict(a)
   a[key]=[math.nan,0,1,1] if key=='rectPx' else math.nan
   self.assertFalse(compare.compare_regions([a],[b],0,0)['ok'])
 def test_success_semantics_and_explicit_tolerance_preserved(self):
  for a,b in [(1,1.0),(True,True),(False,False),(2**53,2**53),(-0.0,0)]:
   self.assertTrue(compare.compare_layout({'x':a},{'x':b},0)['ok'])
  self.assertTrue(compare.compare_layout({'x':1},{'x':1.125},.125)['ok'])
  self.assertFalse(compare.compare_layout({'x':1},{'x':1.125},.124)['ok'])
if __name__=='__main__':unittest.main(verbosity=2)
