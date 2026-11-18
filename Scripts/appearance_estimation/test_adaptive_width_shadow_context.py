import copy,unittest
from unittest.mock import patch
import numpy as np
import source_shadow_observation as observer
from continuous_optimize import shadow_parameter_guard

class AdaptiveWidthShadowContextTests(unittest.TestCase):
    def test_observer_reference_width_does_not_replace_emitted_style(self):
        p=dict(fill=dict(rgb=[1,2,3]),outline=dict(present=True,rgb=[255]*3,widthPx=2.5),shadow=dict(present=True,probability=.9))
        before=copy.deepcopy(p)
        def observe(rgb,mask,arrays,geometry,pred,pixel,packet):
            self.assertEqual(pred['outline']['widthPx'],4.)
            pred['shadow']['offsetPx']=[3,3];pred['fill']['rgb']=[9]*3
        with patch('calibrate_width.measure',return_value=({},np.zeros(8))),patch('calibrate_width.width_features',return_value=np.zeros(662)),patch('width_resolution.reference_predict',return_value=[4.]),patch.object(observer,'attach',side_effect=observe):
            out=observer.attach_with_width_context(None,None,None,{},p,None,{},width_model=dict(adaptiveNormalRefinement={'present':True}))
        self.assertIs(out,p);self.assertEqual(p['outline'],before['outline']);self.assertEqual(p['fill'],before['fill'])
        self.assertEqual(p['shadow']['offsetPx'],[3,3]);self.assertEqual(p['shadow']['sourceObservation']['widthContext']['referenceWidthPx'],4.)
        self.assertEqual(p['shadow']['sourceObservation']['widthContext']['emittedStyleWidthPx'],2.5)

    def test_legacy_width_restores_late_fill_and_transfers_shadow_only(self):
        p=dict(fill=dict(rgb=[9,9,9]),shadow=dict(present=True))
        descriptor=dict(fill=dict(rgb=[1,2,3]),shadow=dict(present=True))
        def observe(rgb,mask,arrays,geometry,context,pixel,packet):
            self.assertIs(context,descriptor)
            self.assertEqual(context['fill']['rgb'],[1,2,3])
            context['shadow']['offsetPx']=[2,3]
        with patch('certified_bright_primary.restore_baseline',return_value=descriptor) as restore,patch.object(observer,'attach',side_effect=observe) as call:
            self.assertIs(observer.attach_with_width_context(1,2,3,4,p,6,7,width_model={}),p)
            restore.assert_called_once_with(p)
            call.assert_called_once_with(1,2,3,4,descriptor,6,7)
        self.assertEqual(p['fill']['rgb'],[9,9,9])
        self.assertEqual(p['shadow']['offsetPx'],[2,3])

    def test_shadow_count_cannot_hide_worse_displacement_or_swapped_labels(self):
        def report():
            return dict(knownNegativeRGBEmissions=dict(train=0,dev=0),metrics={g:dict(colour=dict(emitted=1,within10Count=1,items=[dict(itemID='sourceA',emitted=True,within10=True)]),offset=dict(emitted=1,within2PxCount=1,meanErrorPx=1.,items=[dict(itemID='sourceA',emitted=True,errorPx=1.)])) for g in ['train','dev']})
        old=report();new=copy.deepcopy(old);self.assertTrue(shadow_parameter_guard(old,new))
        new['metrics']['dev']['offset']['meanErrorPx']=1.7
        self.assertFalse(shadow_parameter_guard(old,new))
        new=copy.deepcopy(old);new['metrics']['dev']['colour']['items'][0]['itemID']='sourceB'
        self.assertFalse(shadow_parameter_guard(old,new))

if __name__=='__main__':unittest.main()
