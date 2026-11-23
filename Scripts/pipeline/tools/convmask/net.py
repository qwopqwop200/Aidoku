import torch, torch.nn as nn, torch.nn.functional as F

def block(cin, cout, sep):
    if sep and cin >= 8:
        return nn.Sequential(nn.Conv2d(cin, cin, 3, padding=1, groups=cin, bias=False), nn.Conv2d(cin, cout, 1, bias=False),
                             nn.BatchNorm2d(cout), nn.ReLU(inplace=True),
                             nn.Conv2d(cout, cout, 3, padding=1, groups=cout, bias=False), nn.Conv2d(cout, cout, 1, bias=False),
                             nn.BatchNorm2d(cout), nn.ReLU(inplace=True))
    return nn.Sequential(nn.Conv2d(cin, cout, 3, padding=1, bias=False), nn.BatchNorm2d(cout), nn.ReLU(inplace=True),
                         nn.Conv2d(cout, cout, 3, padding=1, bias=False), nn.BatchNorm2d(cout), nn.ReLU(inplace=True))

class UNet(nn.Module):
    """Compact U-Net: chans per level, max-pool down, nearest up + concat; one logit per pixel."""
    def __init__(self, cin=6, chans=(8, 16, 32), sep=False):
        super().__init__()
        self.down = nn.ModuleList(); c = cin
        for ch in chans:
            self.down.append(block(c, ch, sep)); c = ch
        self.up = nn.ModuleList()
        for ch in reversed(chans[:-1]):
            self.up.append(block(c + ch, ch, sep)); c = ch
        self.head = nn.Conv2d(c, 1, 1)

    def forward(self, x):
        skips = []
        for i, d in enumerate(self.down):
            if i: x = F.max_pool2d(x, 2)
            x = d(x); skips.append(x)
        for u, s in zip(self.up, reversed(skips[:-1])):
            x = F.interpolate(x, scale_factor=2, mode='nearest')
            x = u(torch.cat([x, s], 1))
        return self.head(x)

def params(m): return sum(p.numel() for p in m.parameters())

if __name__ == '__main__':
    for ch, sep in [((8, 16, 32), False), ((8, 16, 32), True), ((8, 16), False), ((12, 24, 48), True), ((16, 32, 64), False), ((6, 12, 24), False)]:
        print(ch, sep, params(UNet(chans=ch, sep=sep)))
