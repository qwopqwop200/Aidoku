"""Independent source colour context for physical pen-width regression."""
from source_appearance import rank
VERSION='source-width-independent-background-context-v1'


def background_index(packet,prediction,model=None):
    if not model or model.get('backgroundContextRanker') is None:return prediction['backgroundIndex']
    if model.get('backgroundContextVersion')!=VERSION:raise ValueError('Width background/source context contract mismatch')
    if model['backgroundContextConditioned']:
        return rank(model['backgroundContextRanker'],packet,'background',prediction['fillIndex'],prediction['outlineIndex'])
    return rank(model['backgroundContextRanker'],packet,'background')
