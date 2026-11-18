import unittest
import numpy as np
from source_appearance import extract,heuristic,predict,VERSION
from calibrate_width import measure
from optimize_appearance import assign_splits,batch_predictions,threshold_statistics
from background_palette import source_features as background_features,describe


class ContextBackground:
    def predict_proba(self,features):
        # Background may legitimately share the fill colour; it must not be suppressed like an outline candidate.
        probability=features[:,-2].astype(float)
        return np.column_stack([1-probability,probability])


class VisibleBackground:
    def predict_proba(self,features):
        probability=(features[:,-5]>.05).astype(float)
        return np.column_stack([1-probability,probability])


def fixture(fill,outline):
    image=np.full((100,100,3),[135,145,155],np.uint8)
    mask=np.zeros((100,100),bool)
    for x in [12,40,68]:
        image[15:85,x:x+18]=outline;mask[15:85,x:x+18]=True
        image[19:81,x+4:x+14]=fill
    return image,mask


class SourceAppearanceTests(unittest.TestCase):
    def test_fill_outline_roles_do_not_depend_on_darkness(self):
        for fill,outline in [([30,60,95],[250,250,250]),([250,250,250],[5,5,5])]:
            image,mask=fixture(fill,outline)
            packet=extract(image,mask,font_pixels=28)
            f,o,b=heuristic(packet)
            self.assertLess(np.max(np.abs(np.array(packet['colors'][f])-fill)),3)
            self.assertLess(np.max(np.abs(np.array(packet['colors'][o])-outline)),3)
            self.assertLess(np.max(np.abs(np.array(packet['colors'][b])-[135,145,155])),3)

    def test_original_pixel_width_and_geometry_guard(self):
        image,mask=fixture([30,60,95],[250,250,250])
        evidence,_=measure(image,mask,[30,60,95],[250,250,250])
        self.assertTrue(evidence['reliable'])
        self.assertLessEqual(abs(evidence['suggestedWidthPx']-4),1)
        with self.assertRaises(ValueError):extract(image,mask[:80])

    def test_identical_crops_join_page_groups_transitively(self):
        rows=[dict(sourceImageSHA256='a',cropSHA256='shared'),
              dict(sourceImageSHA256='b',cropSHA256='shared'),
              dict(sourceImageSHA256='b',cropSHA256='other')]
        result=assign_splits(rows)
        self.assertEqual(result['groupCount'],1)
        self.assertEqual(len({r['evaluationGroup'] for r in rows}),1)
        self.assertEqual(result['exactSourceAndCropCrossSplitLeaks'],0)

    def test_contextual_background_single_and_batch_agree(self):
        image,mask=fixture([30,60,95],[250,250,250]);packet=extract(image,mask,font_pixels=28)
        model=dict(featureVersion=VERSION,conditionedBackground=True,background=ContextBackground())
        single=predict(packet,model);batch=batch_predictions([packet,packet],model)
        self.assertEqual(single['backgroundIndex'],single['fillIndex'])
        self.assertEqual([r['backgroundIndex'] for r in batch],[single['backgroundIndex']]*2)

    def test_cached_thresholds_exclude_unknown_GT(self):
        rows=[{'evaluationSplit':'dev','shadow':{'present':v}} for v in [True,False,None]]
        predictions=[{'shadow':{'probability':p}} for p in [.9,.2,.8]]
        strict,loose=threshold_statistics(rows,predictions,'shadow',[.5,.1])
        self.assertEqual((strict['TP'],strict['FP'],strict['TN'],strict['FN']),(1,0,1,0))
        self.assertEqual(loose['FP'],1)

    def test_background_palette_excludes_predicted_neighbor_text(self):
        colors=[[30,60,90],[220,200,180],[30,180,40]]
        image=np.zeros((60,60,3),np.uint8);image[:,:30]=colors[0];image[:,30:]=colors[1]
        image[10:40,10:40]=colors[2]
        own=np.zeros((60,60),bool);context=own.copy();context[10:40,10:40]=True
        packet=dict(colors=colors,features=np.zeros((3,35)).tolist(),pair=np.zeros((3,3,6)).tolist())
        prediction=dict(fillIndex=2,outlineIndex=0)
        x,mass=background_features(image,own,context,packet,prediction)
        _,unprotected=background_features(image,own,own,packet,prediction)
        self.assertEqual(mass[2],0)
        self.assertGreater(unprotected[2],.05)
        result=describe(packet,prediction,x,mass,dict(classifier=VisibleBackground(),threshold=.5,maxColors=3))
        self.assertEqual({tuple(c) for c in result['colors']},{tuple(c) for c in colors[:2]})
        self.assertAlmostEqual(sum(result['observedContextWeights']),1.)
        x,empty=background_features(image,own,np.ones_like(context),packet,prediction)
        unknown=describe(packet,prediction,x,empty,dict(classifier=VisibleBackground(),threshold=.5,maxColors=3))
        self.assertIsNone(unknown['observedContextWeights'])
        self.assertTrue(unknown['insufficientObservedContext'])


if __name__=='__main__':unittest.main()
