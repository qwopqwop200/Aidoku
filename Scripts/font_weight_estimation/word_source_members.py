"""Bind original line OCR to source geometry, never to weight labels or IDs."""
import cv2
import numpy as np


def polygon_iou(a,b):
    a=cv2.convexHull(np.asarray(a,np.float32));b=cv2.convexHull(np.asarray(b,np.float32))
    aa,bb=cv2.contourArea(a),cv2.contourArea(b)
    if min(aa,bb)<=0:return 0.
    intersection,_=cv2.intersectConvexConvex(a,b)
    return float(intersection/max(1e-9,aa+bb-intersection))


def match_member(polygon,observations,source_hash,minimum_iou=.4):
    candidates=[]
    for row in observations:
        if row['sourceSHA256']!=source_hash or not row.get('text'):continue
        score=polygon_iou(polygon,row['polygon'])
        if score>=minimum_iou:candidates.append((score,float(row.get('confidence',0)),row))
    return max(candidates,key=lambda r:(r[0],r[1]))[2] if candidates else None
