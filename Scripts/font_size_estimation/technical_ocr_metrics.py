"""Technical character/count evidence; no words, token IDs or semantics."""
import math
import unicodedata
import numpy as np

SMALL_KANA=set('ぁぃぅぇぉっゃゅょゎゕゖァィゥェォッャュョヮヵヶ')


def technical_metrics(text,confidence,bbox_size,prior):
    text=unicodedata.normalize('NFC',text or '')
    chars=[c for c in text if not c.isspace() and not unicodedata.category(c).startswith('M')]
    total=max(1,len(chars));counts=dict(cjk=0,kana=0,small=0,latin=0,digit=0,punct=0,dot=0,symbol=0)
    for c in chars:
        code=ord(c);category=unicodedata.category(c)
        if 0x3400<=code<=0x9fff or 0xf900<=code<=0xfaff or 0x20000<=code<=0x2fa1f:counts['cjk']+=1
        elif 0x3040<=code<=0x30ff or 0xff65<=code<=0xff9f:counts['kana']+=1
        elif c.isalpha() and code<0x250:counts['latin']+=1
        elif category.startswith('N'):counts['digit']+=1
        elif category.startswith('P'):counts['punct']+=1
        elif category.startswith('S'):counts['symbol']+=1
        counts['small']+=c in SMALL_KANA;counts['dot']+=c in '.．。・･…⋯'
    effective=max(1.,counts['cjk']+counts['kana']-.5*counts['small']+.5*(counts['latin']+counts['digit'])+.3*counts['punct']+.5*counts['symbol'])
    w,h=bbox_size;valid=isinstance(confidence,(int,float)) and math.isfinite(confidence) and 0<=confidence<=1
    return np.array([math.log1p(len(chars))]+[counts[k]/total for k in ['cjk','kana','small','latin','digit','punct','dot','symbol']]+[sum(c.isspace() for c in text)/total,float(text.count('\n')),w/(prior*effective),h/(prior*effective),math.sqrt(w*h/effective)/prior,effective/(w*h/prior**2),float(valid),float(confidence) if valid else 0.,math.log1p(sum(bool(x.strip()) for x in text.splitlines()))],float)
