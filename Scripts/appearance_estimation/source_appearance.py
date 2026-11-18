"""Source-only colour/topology features. No label, item identity or GT lookup at inference."""
import cv2
import numpy as np
from scipy import ndimage

cv2.setNumThreads(1)
VERSION = 'source-palette-topology-v3'


def lab(colors):
    a = np.asarray(colors, np.float32).reshape(1, -1, 3) / 255
    return cv2.cvtColor(a, cv2.COLOR_RGB2LAB).reshape(-1, 3)


def palette(rgb, selection, limit=14):
    pixels = rgb[selection]
    if not len(pixels):
        pixels = rgb.reshape(-1, 3)
    # Bounded deterministic sampling; original pixels and output coordinates are unchanged.
    pixels = pixels[::max(1, len(pixels)//180000)]
    q = pixels.astype(np.int32)//16
    code = q[:, 0]*256 + q[:, 1]*16 + q[:, 2]
    counts = np.bincount(code, minlength=4096)
    groups = []
    for k in np.argsort(-counts)[:64]:
        if counts[k] < max(2, len(pixels)*.0005):
            break
        member = pixels[code == k]
        color = np.median(member, axis=0)
        color_lab=lab([color])[0]
        nearby = next((g for g in groups if np.max(np.abs(g[0]-color)) <= 23 and
                       np.linalg.norm(lab([g[0]])[0]-color_lab)<=6), None)
        if nearby is None:
            if len(groups) < limit:
                groups.append([color, int(counts[k])])
        else:
            total = nearby[1] + counts[k]
            nearby[0] = (nearby[0]*nearby[1] + color*counts[k])/total
            nearby[1] = int(total)
    return [np.rint(g[0]).astype(int).tolist() for g in groups]


def extract(rgb, mask, polygons=None, font_pixels=None):
    """RGB + predicted glyph mask + optional detected ownership polygons only."""
    h, w = mask.shape
    if rgb.shape != (h, w, 3):
        raise ValueError('RGB/mask shape mismatch; never silently resize source geometry')
    mask = np.asarray(mask, bool)
    roi = np.ones((h, w), np.uint8)
    if polygons:
        roi[:] = 0
        cv2.fillPoly(roi, [np.rint(p).astype(np.int32) for p in polygons], 1)
    owner = roi.astype(bool)
    inside = mask & owner
    if not inside.any():
        inside = mask if mask.any() else owner
    radius = max(2, min(16, round(float(font_pixels or min(h,w))*.12)))
    near = cv2.dilate(inside.astype(np.uint8), cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (radius*2+1, radius*2+1))) > 0
    outside = near & ~mask
    if outside.sum() < 20:
        outside = ~mask
    if not outside.any():
        outside = ~owner
    colors = palette(rgb, inside)
    # Exterior palette is added as a hypothesis, not assumed to be text.
    for c in palette(rgb, outside, 6):
        if all(np.max(np.abs(np.array(c)-old)) > 23 for old in colors):
            colors.append(c)
    colors = colors[:20]
    labs = lab(colors)
    raw = rgb.astype(np.int16)
    depth = cv2.distanceTransform(mask.astype(np.uint8), cv2.DIST_L2, 3)
    masks, features, holes, contacts = [], [], [], []
    border=np.zeros((h,w),bool);border[[0,-1],:]=True;border[:,[0,-1]]=True
    far=~near
    normalizer = max(1., float(font_pixels or min(h,w)))
    for c, lc in zip(colors, labs):
        m = np.max(np.abs(raw-np.array(c)), axis=2) <= 23
        own = m & inside
        n, components, stats, _ = cv2.connectedComponentsWithStats(own.astype(np.uint8), connectivity=8)
        good = stats[1:, cv2.CC_STAT_AREA] >= 3
        sizes = stats[1:, cv2.CC_STAT_AREA][good]
        component_count = int(good.sum())
        d = depth[own]
        color = np.array(c, float)/255
        features.append([*color, lc[0]/100, lc[1]/128, lc[2]/128,
            float(color.max()-color.min()), float(color.min()), float(color.max()),
            float(own.sum()/max(1,inside.sum())), float((m&outside).sum()/max(1,outside.sum())),
            float((m&owner).sum()/max(1,owner.sum())),
            float(np.quantile(d,.5)/normalizer) if len(d) else 0,
            float(np.quantile(d,.9)/normalizer) if len(d) else 0,
            min(component_count,100)/100, float(np.median(sizes)/normalizer**2) if len(sizes) else 0,
            float(np.mean(sizes<=10)) if len(sizes) else 0])
        masks.append(own)
        # Closing one pixel tolerates antialias cracks, preserving source role evidence.
        closed = cv2.morphologyEx(m.astype(np.uint8), cv2.MORPH_CLOSE, np.ones((3,3),np.uint8)) > 0
        holes.append(ndimage.binary_fill_holes(closed) & ~closed)
        contacts.append(cv2.dilate(own.astype(np.uint8),np.ones((5,5),np.uint8))>0)
    features = np.asarray(features, np.float32)
    pair = np.zeros((len(colors),len(colors),6), np.float32)
    for i in range(len(colors)):
        for j in range(len(colors)):
            pair[i,j] = [np.linalg.norm(labs[i]-labs[j])/100,
                (masks[i]&holes[j]).sum()/max(1,masks[i].sum()),
                (masks[j]&holes[i]).sum()/max(1,masks[j].sum()),
                (masks[j]&contacts[i]).sum()/max(1,masks[j].sum()),
                (masks[i]&contacts[j]).sum()/max(1,masks[i].sum()),
                min(10, masks[j].sum()/max(1,masks[i].sum()))/10]
    features = np.column_stack([features, pair[:,:,1].max(1), pair[:,:,2].max(1), pair[:,:,1].mean(1)])
    exterior_features=[]
    for c in colors:
        m=np.max(np.abs(raw-np.array(c)),axis=2)<=23
        exterior_features.append([(m&~owner).sum()/max(1,(~owner).sum()),
            (m&far).sum()/max(1,far.sum()),(m&border).sum()/max(1,border.sum())])
    features=np.column_stack([features,np.asarray(exterior_features)])
    gray=cv2.cvtColor(rgb,cv2.COLOR_RGB2GRAY)
    kernel=max(3,min(31,round(normalizer*.25)//2*2+1))
    dark=np.maximum(0,cv2.medianBlur(gray,kernel).astype(np.float32)-gray.astype(np.float32)-3)/255
    offset=max(1,min(10,round(normalizer*.05)))
    direction_features=[]
    for own,hole in zip(masks,holes):
        filled=(own|hole).astype(np.uint8)
        values=[]
        for dx,dy in [(1,0),(1,1),(0,1),(-1,1),(-1,0),(-1,-1),(0,-1),(1,-1)]:
            shifted=cv2.warpAffine(filled,np.float32([[1,0,dx*offset],[0,1,dy*offset]]),(w,h),flags=cv2.INTER_NEAREST)>0
            strip=shifted&~filled.astype(bool)
            values.append(float(dark[strip].mean()) if strip.any() else 0.)
        direction_features.append(values+[max(values),min(values),max(values)-min(values),float(np.mean(values))])
    features=np.column_stack([features,np.asarray(direction_features)])
    return dict(version=VERSION, colors=colors, features=features.tolist(), pair=pair.tolist(),
                cropSize=[w,h], fontPixels=normalizer, maskFraction=float(mask.mean()),
                maskSource='predicted pixel/RF segmentation; no segmentation GT')


def role_features(packet, role, fill_index=None, outline_index=None):
    f = np.asarray(packet['features'], np.float32)
    if role == 'outline' and fill_index is not None:
        pair = np.asarray(packet['pair'], np.float32)[fill_index]
        f = np.column_stack([f,pair,np.tile(f[fill_index],(len(f),1))])
    elif role == 'background' and fill_index is not None and outline_index is not None:
        pair = np.asarray(packet['pair'],np.float32)
        f = np.column_stack([f,pair[fill_index],pair[outline_index],
            np.tile(f[fill_index],(len(f),1)),np.tile(f[outline_index],(len(f),1)),
            np.arange(len(f))==fill_index,np.arange(len(f))==outline_index])
    return f


def heuristic(packet):
    f = np.asarray(packet['features'])
    score = 2*f[:,17] - f[:,18] + f[:,9] - 1.3*f[:,10] + .2*f[:,6]
    fill = int(score.argmax())
    p = np.asarray(packet['pair'])[fill]
    outline_score = p[:,1]*2+p[:,3]*.6+f[:,9]*.2-p[:,2]-f[:,10]*.2
    outline_score[fill] = -1e6
    outline = int(outline_score.argmax())
    background = int((f[:,10]-.6*f[:,9]).argmax())
    return fill, outline, background


def rank(model, packet, role, fill=None, outline=None):
    if model is None:
        return heuristic(packet)[['fill','outline','background'].index(role)]
    score = model.predict_proba(role_features(packet,role,fill,outline))[:,1]
    if role == 'outline':
        score[fill] = -1
    return int(score.argmax())


def summary_features(packet, fill, outline, background):
    f = np.asarray(packet['features'],np.float32)
    p = np.asarray(packet['pair'],np.float32)
    return np.concatenate([f[fill],f[outline],f[background],p[fill,outline],
        p[fill,background],p[outline,background],[packet['maskFraction']]])


def predict(packet, model):
    if model.get('featureVersion',packet['version'])!=packet['version']:
        raise ValueError('Model/source feature contract mismatch')
    fill = rank(model.get('fill'),packet,'fill')
    outline = rank(model.get('outline'),packet,'outline',fill)
    background = rank(model.get('background'),packet,'background',fill,outline) if model.get('conditionedBackground') else rank(model.get('background'),packet,'background')
    summary = summary_features(packet,fill,outline,background)
    probability = float(model['outlinePresence'].predict_proba([summary])[0,1]) if model.get('outlinePresence') else .8
    shadow_probability = float(model['shadowPresence'].predict_proba([summary])[0,1]) if model.get('shadowPresence') else 0
    return dict(fillIndex=fill,outlineIndex=outline,backgroundIndex=background,
        fill=dict(rgb=packet['colors'][fill]),
        outline=dict(present=probability>=model.get('outlineThreshold',.5),rgb=packet['colors'][outline],
                     probability=probability,widthPx=None,widthRangePx=None),
        background=dict(rgb=packet['colors'][background]),
        shadow=dict(present=shadow_probability>=model.get('shadowThreshold',.5),probability=shadow_probability,
                    rgb=None,offsetPx=None,blurRadiusPx=None,opacity=None),
        inferenceUsesGT=False,sourceOnly=True)
