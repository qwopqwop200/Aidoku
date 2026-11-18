"""Keep missing palette/ownership observations distinct from background pixels."""
import numpy as np


def observe_fill(rgb,ownership,style):
    pixels=np.asarray(rgb,float);own=np.asarray(ownership,bool)
    if pixels.shape[:2]!=own.shape or pixels.ndim!=3 or pixels.shape[2]!=3:
        raise ValueError('Source observation geometry differs')
    fill=np.asarray(style['fill']['rgb'],float);palette=[]
    for part in ('outline','background','shadow'):
        item=style.get(part,{})
        if part!='background' and not item.get('present'):continue
        if item.get('rgb') is not None:palette.append(item['rgb'])
        if part=='background':palette.extend(item.get('colors',[]))
    best=np.full(own.shape,np.inf);alpha=np.zeros(own.shape)
    for color in palette:
        other=np.asarray(color,float);delta=fill-other
        if np.linalg.norm(delta)<=35:continue
        t=np.clip(((pixels-other)*delta).sum(2)/np.dot(delta,delta),0,1)
        residual=np.linalg.norm(pixels-(other+t[:,:,None]*delta),axis=2)
        selected=residual<best;alpha[selected]=t[selected];best[selected]=residual[selected]
    # Known background/outline remains negative evidence outside erasure masks.
    # Unowned possible ink and colors outside the source palette are unknown.
    observed=(best<22)&(own|(alpha<.25))
    return alpha.astype(np.float32),observed
