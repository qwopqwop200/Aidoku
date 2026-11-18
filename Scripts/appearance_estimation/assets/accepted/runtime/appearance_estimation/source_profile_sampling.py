"""Original-crop sampling: out-of-image padding can never become observed paint."""
import cv2
import numpy as np


def sample_source(rgb,x,y):
    if x.shape!=y.shape or x.ndim!=2:raise ValueError('Expected aligned profile coordinate arrays')
    h,w=rgb.shape[:2]
    valid=np.isfinite(x)&np.isfinite(y)&(x>=0)&(x<=w-1)&(y>=0)&(y<=h-1)
    # Replication prevents interpolation from introducing zero paint at the edge;
    # all coordinates outside the actual crop remain invalid observations.
    values=cv2.remap(rgb,np.nan_to_num(x).astype(np.float32),np.nan_to_num(y).astype(np.float32),
                     cv2.INTER_LINEAR,borderMode=cv2.BORDER_REPLICATE)
    return values,valid


def observed_window(valid,row,index,half_width=2):
    lo,hi=index-half_width,index+half_width+1
    return lo>=0 and hi<=valid.shape[1] and bool(valid[row,lo:hi].all())
