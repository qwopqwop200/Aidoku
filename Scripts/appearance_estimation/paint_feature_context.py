"""A reusable source colour encoder for downstream heads, independent of output-head replacement."""
from source_appearance import predict
from nested_outline import recover_presence,VERSION as NESTED_VERSION
from outline_layer_discovery import correct_primary,refresh_conditioned_background,PRIMARY_VERSION
VERSION='source-independent-paint-feature-context-v1'


def encode(rgb,mask,packet,geometry,role_model,policy):
    result=predict(packet,role_model)
    if policy.get('sourceNestedContourVersion'):
        if policy['sourceNestedContourVersion']!=NESTED_VERSION:raise ValueError('Reference nested/source version mismatch')
        result=recover_presence(rgb,mask,result,packet['fontPixels'],geometry.get('polygons'))
    if policy.get('sourcePrimaryContourVersion'):
        if policy['sourcePrimaryContourVersion']!=PRIMARY_VERSION:raise ValueError('Reference primary/source version mismatch')
        prior=result;result=correct_primary(rgb,mask,result,packet,geometry.get('polygons'));result=refresh_conditioned_background(result,prior,packet,role_model)
    return result


def feature_prediction(rgb,mask,packet,geometry,model):
    context=model.get('featureContext')
    if context is None:return None
    if context.get('version')!=VERSION:raise ValueError('Pixel paint/source context version mismatch')
    return encode(rgb,mask,packet,geometry,context['roleModel'],context['pipelinePolicy'])
