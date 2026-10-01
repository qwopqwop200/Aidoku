import Compression
import Foundation
import Testing
@testable import Aidoku

/// Reviewed original-source colored letters, white bands, hearts, and frame.
/// Annotations use immutable source RGB/components; no renderer output is an oracle.
/// In capture 0, two complete punctuation components extend 36–41 source pixels
/// beyond the OCR quad and have no auxiliary ownership. Their cores and solid
/// white bands (all RGB >= 250, spread <= 5) are protected. The mixed off-white
/// fringe is unannotated: proximity to a glyph alone cannot distinguish its
/// antialiasing from the nearly white backing. All six owned components retain
/// complete core and white-band checks. The source-only provenance is saved in
/// Scripts/tests/fixtures/slanted-native-outlines.semantic-provenance.json.
enum NativeSlantedOutlineSemanticAnnotations {
    private struct Capture {
        var width: Int
        var height: Int
        var sourceHash: String
        var maskHash: String
        var core: Int
        var halo: Int
        var artwork: Int
        var encoded: String
    }
    private static let captures: [Capture] = [
        Capture(width: 377, height: 583,
            sourceHash: "a6ee054307366e76adb3fd3041c71ef1f17a05f5cf4067243a66afc0581ae788",
            maskHash: "a7adbb29c20d14fa046d299eb47babe613767bb9ecf85bb059f38baac614a077",
            core: 14472, halo: 12723, artwork: 16305,
            encoded: [
                "eNrtnY2S47qqhVdcev9nvvfM9J62JUCgX+SgU3VmVyfptj+TJYQQADFixIgRI0aMGDFixIgRI0aMGDFixIgRI0aMGDFixIgRI0aMGDFixIgRI0aMGDFixIgR",
                "I0aMGDFixIgRI0aMGN88UiDYgj0F+E3cA3xwD+4xAntwjxHcg/sbuQT2Fy5rgntw/yL9TcF9C5jALmAP7pu4p0O/TcdzT8F9x6Qa3HdxT2u5f/nD+EdlEgfe",
                "2r/6a/CLZQ4GSWW+WYBu976c+xejTw/uaTn3b512Hzc9i3ssrCq3PP72q9b+neTz+53CXQP+u9AX9zr61hXinb5Pbwgqg29cM2mmr1N64iYncK+/6cvmWPIW",
                "h961zkcsv3OvRs9AGXnPSoLU1+696Ll7G3fH6iUR+b17KXr2vsZy177zW1ayYrhqNXb2b76NvGxKg+7VBE0IFr8IfTVIuIF76p4mDjf3QQZvpFW5oDegr9/F",
                "gJs0o6pe0unoVYv3tBq74m+mk9krr73z/poIqda2h6JP6jVk6v0zLZ/S3kF6KfZO8K1o9Nd2FnrL9fbcWTMW/QL3IPTGi22/r9TBPU26m93Y50AYJgPGzx3A",
                "vsmzS2uptzhSrtE3filbbqgXQ+uf9Mi+/brazK/zYtsNK72DegOFAXffPje4Qt95MdYoy4A7b/8Nfsy+/0I2+Ha917ub/aArsKy1RsXux9x5Opi62uRH3mka",
                "d/9r4Q/+k7qs3pV/zyH7NOGvadLYx/69CTjG079+xsRHXDkxk4bn+M0xxTQD+z/y075H6xznKYYzmP71GEvXAvO+wxOtZ9BF/wKfTv552XOnrelVQjpu4M8n",
                "MtZrzD7N9xX+nmiGByv6/x8W7/mP8udnrDD7Vd4wFhUXTtbxy/1zG28hvw68mv9TVp7Y30N+OXjjnFpw/6c2rwCfXEInub/F5B2Cl7EH+AUqQ3J/F/jkkfvn",
                "E+DXCw3L3Tl45dIruQJfU3f/4NWr3p+XnYGHxN0zeH28wRV4JXecwl1x6MqF1qiwezb4H9bPf9yD16i7b4P/A/pu7kk+1wcPWnMpzf0g7jJ5H+DV2J1zt2yj",
                "eACvVZnjwMM1eL2527mve0ql0GjBJ//YrR7Ngv3xitKI1W2xz+QvG3ajwS/JTKhKPJ8zsg28FXs79/nkSaWRTH4feDP2Hu7TyXPghZ39TeDN2I3gr2speRY8",
                "XIG/GrC3cX+GInZ48XXwaTX1Pyimcl/nVWoTJ0rwC0z+6sBuA58tyOaTl5hvBn+VDt7nY+YOE/d16107eCwBf6HL2H+XTrb16rpQsj5Ja90K6r8b7sLeovCP",
                "PzKZfOow+Smz60WMBuw2cIXSzBcbd+BxS2tvNfYRBr/V5BNTRHoieGIN82kaP4LVbPAOTX6WW0OvHE1GXrg0aDf42SbvBXwv9f+xRg/3a3GScTKTnwK+W2Ke",
                "D2oI+LnkfYAvQlMfO/arkTv2pHeL0Uka/J//TQHfBP0faTStnXiDn2vyclhYdijHgm+F/sfeifV+v8FPJW8Hn0b31Pxx3Bv9xn/cM4PHCPATyVc2QoimU3fw",
                "aT94FEfOWgz+Wp5an4yz68+PvYAnI4vXKKXZSL7obvfzOAYvXbXZSZwSTDP4iWJjAZ//bLBb0+C7/3qhkwx+HnkD+F/1mQK+i/s88LPERj+73rjPAd+MfY4v",
                "OZm8Gvyd+2jwdoPPl7uZMIwFP4W8FvyD+1Dwdq+mCO5MNfhZNq/zJ0ndHwX+soEngmrzFH7eBKsCn2aCv0zgyRhym9Lo//IM8po6MIkDn1aDJ7dlc4O/Bhv8",
                "HPL1aE0q3zN086/h/rOaY11Zqsonfs0gD6vVD9511SptHrkvwBt2Wk0PfAp5XdWpNBG8hkC+T0V9cHC0YLbaKLQmIaXZFi9V3yi3B0l0Mw1+AnmtyE8Hzxkf",
                "TZ1AZwJvNfjx5I3z6gzwQsUZZit8lNIY18vXMvJiEcg0Y9c1lxj+oAajNJhl8MPJ18BjAXjQB2DE8zGM0nSCr8zxIw/qSCK/yuLpdFX5XBKpNL2Lp9qW+0jy",
                "HVIzcgltoz5LaVD3a8ehlwgzR9MmgIeF+hilYYqDKqPE11TwWGbxPHkVO2BEtACW+Pw1UWsWSg1LXsdunMEvJg8H4C3HfHvAywZf9zKHkU+6QNkC8PpKDv1K",
                "w5d/Vpfb6iXfUqkde4sF0RHhzkUrVGUsR27EWk3eIXj7KW7BSV9Gvgl82g++SWkUBr9sC7xJag4FXz0Bog7jjCKPg8DTSnP1Gfx/L2nJrwcPp+CHuDT6kPGI",
                "+PzhTo1ZaSCfNdOSX2zySE7At8+ttTN+Snd+qWPjodhq77K13jpnXTqrWmaSg7rOzUpz6QxeR37MHqyFu1PwV7vCE79hWScGQ3qNE6fmV+K1BFQza3WBO3oH",
                "VnH00pc3mYEfESyg3o0V4JUyczR4aMsWVNscYf5OVMn9QKfGZvBY2GBKzDcouB/n1BgNvk5+KHiduTtct07gXiOP6fkGRMsWT+BVdy8IjaDV16IiE0yqJFFP",
                "4lDwsBYEksiPzGIlk7KpOh6ngTfPrNkH7Y+slzzTGcpTiEwPvoneot7IGXkkp9wzb3Ied97oJyTMQ8Z+HPhmoRHJzzoj8qwL9ALw7TJNk59yLErZseIMN75/",
                "eqT2wCcdfhU7oHlofKYH3yk0GXkUVbmmkMdrwHf6g/wZrBnk+VedgZ9t8AT6eTWzpBexHTy04NtiBSL5lS3STgc/ZuG5mftR4Mcu+Pdyx972xVTEYIHQlOQR",
                "4K9FBo+8acxXDQv4GUXKv5W7Bfye4vABHmtC6d8KnicfBr8HvHD4Iwx+PvgQmtVBsuC+B3xwnwyecWuC+wTw0IIXHJrgaAcP1HNWhzmS8Ygq4Mm6Wd2hMWff",
                "juRhC0o8EDJI4N3Fw5K/NIPyHM047m7Ip73kmQP1V/byQO5eyKe95EXw1xTuTsinveSFuvFXE3fpII4r8pWsm9Wz64eqZWbmTvpFV/afHuZWz+AbDjox54sx",
                "qx/RweBLrenkzp6od0M+bdYaritLL/fMMQK8hXeSN62p1XHTcud6MQR4zuQ/dAl6NXd6NvUJ3pVf85tQ9mngnk+oAd5g8n8bLNiOo3JTqHPwDlavih4fqNg7",
                "Sq9U8poCvLZGIesKMmpVAb8XvgPw2nptBu7FQgzsCw403jV5ablP+UBssVUvgRsX4DUN0/SdLsiF2EcKBn0veJk8xBmRmSKyGLwA/vpm8FJuZGX7iJub9eCv",
                "bwYPYrUqxhyrz+z5wfyXFqvdrwWPesM0mzuKWvF+eeb4HvD04VN9dxfJ5Kvl965vBg9TuzS9ynPxh73kPYFHE/Z/nyxNvkZ959aIK/Boo/6PPNUveUv39OPA",
                "l7tIlsIQhMpvaeF9Ivg8kmJLnTE20w3wDHrzx2BoVE/FkL8bfM8D0wX1f96NrZkH3wYexLpqI3icz11JngpaBvj+ucEGPix+YKTHDn67V/Ne7jcXhggWB/he",
                "7hA2UnIP5q40+8DjFQYv71+BDdJvDBngDQbPcqdk5c4d+4Jkh4OXu38w4LGXO97O/Tcqn4PfnNL3EvD1rY6ny35tz5d/C/hq8PHHZ3ciNPsPn80Hf9eaPOts",
                "Y+7wS3waRc/Qmyx5SNp+y9yau+70pnd2wnBnsnzC2dypDIP/LVQVaZTYe0jhBQJPtJ0AqmmUm8+8viNK80jRK/16CjyiXuWY+FhhxyJ4BPex5OmSH0Ti6xXc",
                "h6nNnWdO/mpPlYpRI19AZQ/mBPep5KsmH+BygJ3kIbQ2C+4ivh7yhKtDnDgO7gy8ph43/2p6SpUpgntNqP9sUdtCZbgq66rfgE0MdoI0Nj6k62FFY4U2l7Ad",
                "VZC3LoIGsWcPuAZswjwF3ek2+Sg2r2GE/pIDbksE+eX+3/GBTpvnSloGcE6NabvvfqBh8nWDH8ReUZ0+wPMpeO3o882+AG8An5l9z68OrdFpPG32Hb86wNNr",
                "J+VpvR6TD62h1k7N1Q/V5AO8SWe6zr4/UwuCexP4XvIBnpQaFfmrnTyCOwsGM8Dne09BPAOjqqaEjnVUcBfAVOy+0WqDu8Ekh1axCu4a8r+AxpUPC+5a8hT8",
                "Hr8kuHNgmP3uG/w+fzC4W4z+CTr0YgP88Et2ow9Ee+AHnSX0hYcQhML6v1DyA9AU5kHen8IH+l3efKBfhV14SzCbgl3xzsA2ifrg/LIYFe4cc3e9Wd+EHTXq",
                "Rc2IGIOwa1tOBPlR2NXUPRS4eg13G/XIiNyHPcj3c2/DHjmR/dw/jSPA95n759NHPnDauXdhf1axjaHn3ok9TL6Z+6d3hMnbuWMA9zD5Fu6fT4A/lntojY07",
                "RnEPkzdy/3wC/NncY/U6mnv56QA/nXseVpC2piJSNow7hFSPAD+NO+QzIgF+Cnigkk8GBPjx3KvYqbITAV63YG3UGN7mY/+vEzy0SasBfqTUQJGRSpt8gO8B",
                "r6u0QZp8gO/Qmqw3HAL8EvDQpl4zjRWDext4Q3MWsgp0gG8CD0vO9cX3UQzANvCmVHeqjWIYfJNbYztiEOBHgTeeL3iFxCcHWmM91/EKiU/7Tb6N++lKk3aL",
                "DcyHad7hTKad5PFBK/fjp9Y9ndLLfltDJuezwO8k33BOlfRGrwDfRr5v/XWmE78JPBqrQLzF4PeBRwf3dwQmt5PHVxr8RvANaaZSnAcB3gCyP85zcHxsJ/l+",
                "7gdH4o8B/7a91sPA4z17rYeQbxIa18/kDPA096rBeyZ/BHha4KHJfHIrRekE8naB91+d8gTwdqE5oSKrf/D2DOEjauH6N3mzwZdbLR7JuwffyL0w/tCaRdwf",
                "guSRvG/wzTpDnJYNremeWLUG77ouqGfwQ7i7jeq4B98sNM7J+zV5hjtqKycE+PHcG4QmwE/nDv6MVYj8PO4/4BHg1zo0gsEH+JkTq3SM1u0a6hVCcx1m8B7B",
                "i/Z+WZ6V63QEd+CbqqMcWDrLJ3igZZMV1fIUjp6AN0+e3mOFpg0dVODdsPcFvimZw2Lwfsi7At9k75LBO25J6gm8eOwewwzeB3lH4Nu418NjPsn7AS9tIF1o",
                "AU+g9kPejVvTUmXi1uBbMHhSma4weU6pZUhZX3VOaX7e7bExpivwN0Q8998f8xVYfyuhu13N+tAagnulYTrE0rcHtGd0AT7Hx5m7oc52gDeD570Pda3nAG+V",
                "mkJQqtw5Jfffj9SXWyMsc7gXT+0D6xc8/4Y25A8Z87B29UleVqPWTmnwFK1xtXYVnfcO5s9JGwFeFpNqQMZCHbEXUiNfDyi0Q/ez/+ctMsw/EPQqjLd9V/ge",
                "7b13VbN2gB/MnfFS4Qh8OoH7EOquMmx8g2/gznqn/si7B2+QGdrW/xTW9ac1L+L+ARs3RsyuU4XmKndL/j64AD8TPATwCPATFf7OPC9aH+BHgQd3gOHC3ZH5",
                "BPiB4H/eIm9z3D/uUOOTb/DlQbQbVWE/NXtsuMKf7DD5LG4GtqVXHlpzeDrkBEe+jFVWwBchTVwBvi1GRoe8qmdvHB+HOiJKZmolXb7BYajmkBpZbeBdG/wp",
                "Efkm8K4PvJ6yB1UFT2Q9DTX49Gd8EXgiuC7NrbcPjjT4dBvfAr5Mp+TAU8tZe0vHGvcvIq8KJlDMR5FPaQL5t4CfmL33A/vP/48j/wXgVUc31Tozivx54NtO",
                "JDS7NjdDv6EP8LPJF9xHkT8N/NWa1NdGnuA+iPxh4K9KNiXq3k2PPzOQ/FngpdN+5dKpnzxp8GO8yqPA3x1yLjNY8HbMvk1K80z+JPAXn8RKJXQTT8dInjf4",
                "fvKndVysFQbCM4jQJTapNr4CvHyUG8WrP5UkekxeUnh8C/hKqjxREqGtY50AnvgKvB98rXIBuFIUPSZPm/kgkz+p4aKUV1YKfH8X3szgx6r8QQ0XUfMUM4Fv",
                "6NIoKo1R5StP56R+i8/iWQV4knuH1rC06yaveNdB/RYh7HvgKTRC+o0NvKQ0rMmrJOmUTdeiVlxRLBFcEb7K3qxN4uvzq9LlP7HtH5GzCrq2Vg/41AT+Tjr/",
                "9yjwVOoqARSlwPc2WxcDZJwtk8KEA8GTKcOkJROdLQSRb5d4yeTZlRZOA8/buxCQzxu7jgUvmLzwVpwFXuLOgi+PJwwDD9GjFJ/QUZOrVJKSAf+U8CngOfWu",
                "fDGOA8+6K/VSqsOlBoLJE9xzL+cU8KXO1Ep90i2kQQUXOsCTJp+4iBqOA0/Ueq6AZ4pYjrR40rsnYwTHSg0r8Ix2E+EAYQXVtP/Erksh/uCsBdTFCg0Lvlgb",
                "rQAP8b8OtHh+wfr76qcSDPjvdP1I8IoFLfKoAQP+OKH57/VqLGCGxUMtM5Wg/CEGT/orqES/Rk6uv+w0+yOpvhviuqEui9UReFLfcTR41uAvPuyINeDzAJgY",
                "NsM54GWDv4Q+mErw6ADPZMzTAeATwZeupMh9H3iB+2lSU/BCUdSAW7fOAg9yxqxuwvLnptyCL334G0s+f7Kya2gEDzYOCfWG1EHgS4PHY8nKZNiowGMeeNrg",
                "T5Kacnc7r6wnxOJHrZ+yLAOkmtYw3PEC8KoEylXgYTP4F4B/vjIXPIdVmbd9GHhiVcpyB3io28HnETPvwUkJPHJnRzD5vuyOKnj0cD8FPJM/SUvSSPBgXEXN",
                "hvZx4XghwEJFxTgdkbKFG8HzWlOZWY+QGu4IDbj4O6M13eAtWlNVmjM1nkjLpjPKUEvumAS+avAEeBwBni1Bk0Uxy2ym5iztAeDB504eCR5sZlMdvPWcK3iN",
                "hyZt+CTwqIDnC+5RUcx2pcmPJvAxA9S5nwMede5gqmaPBK8KyUMKSx4GXiiLcl1cQjDAFjJvkPgO8Klm8cnvliudk1q2Y7yRhyzx9592zq4a8KhtkLg1eUiT",
                "ahl1v32QBG/njvIoiA6sbmfKK/hiocq1Umc6y+UVhhvKT4rgewzefeYkGMDsC0yMrJgaWjWeMvkG7t5zhfPlP4uOfI3+DRgC/p63YRcaz8eLpfrlwvurv8N2",
                "FazW3A6vKlxJ6gQUjiOv+ILwvwPDwEO9Zj3tQL3JXpmXe1u6igw1YfgTwcNoruTrnY105c0OlntNaA7rzdL5O5o+Lu1CkUUKktLgz+nNMsg/Gijyiq8Ib/Dn",
                "FTFvjD+gHbyhDJm2SOJXgO8bstZU3i2VEvoKeqPag2jKkGm44+3ce914I3i10LwYPNMgEG2LV6XUGAz+5SZvCDkMEHl9ecRXgzfGenQmLyEzlKV8LferMppN",
                "HvpSk5WqlEhfyL0zKN8p8D8Gz4XW3oJ9QABCZfIG7n+hsyHNw7k/fvbpCiEoYwCGWtuVgObB3P/i5rrmGDtWqOrVGgo+cxF8jG9euj40U0m8tLesQK2knlpo",
                "/mbZ5Dsq0Afi/IKvtwFEc/Iqt3XN1sviwCeS+8Hklf0XzeQhnzHj65TRSsNXTTyVvLbxJVpPQ1U2Wcv6cNQvA1cL5NwZVt0H0BKpl0ye4SYdjcI/b7KlFcPp",
                "4BuPQ7Fb3nRl0PI53b34eT0cXYPHAK2pcL8rz0Piee7HupT1A1QDTgBWJlbCQXxU8YMs8IeDJ16r1hZSkBeqGoBr1JXVwq0b/LFuDRuf6QFfq0/26E0Bsizx",
                "PUI2rY3g1qUrE6MEes5e5ibPECON/fZ1uIF/kTtZiQqjKHVmDlJyFbQzNeGJJtTbj7wwHJ+fzrQHKemS5mCr4JJV5WGr838aeTpjuAk8qI4VeK6YUAH/+6Wo",
                "9ds5OCjPfgF+D2eicUeE63up8BITPQGfAd52acVU2wyeNWUgie45ksbjdABenzZk2rDPzxyj6WwOCp1BZTVLBR+lResm8LVsz/we9WlZwgH8FvIcdxl8vZva",
                "fvC6oxTFxnHF3vFpVZpHNP2Xd6rGK0EXmHcFPg+DkAKUO2dN3FsM/jbB5P/WAsV6m9+R71R+ZctHwnTusHNHTxorWOxCayK5m9f2ufXhGmfcE79Kb+LefjDq",
                "caFG8N4kPjfp584kpH2yysWO5F4r88YWRzSAx3LwBc87eOmbKZIfyx21xC8FeHiaWku2990DVDRRuNzh3MGmEKgtHsk1+H/KXvUV/oQ/ZPd9JHfUErahNHD/",
                "4BVrbAn8s3DN1Q/eEFlIvqdWHrzC4CWxyZdNuOZyRyt0l+AVlwwJPFEo1CP4LatWDjzJnQwv0Nf8z+KxBnuP1rgHTwd2ePBXFpuHU/DJOXgAVKacoDUD6lEs",
                "kJp98TFqwkzlwgrklr4W/NoI67HgqSru9LJK9GsWYm/Wmk2ReBZ8GUmgP8GvXtdiB44yeD34u1OTp13IUYNr3b2cw50FzzsvJfhKnAwBvt3iRfAi+dU7Oodw",
                "L8PCdvBuDqqfZPB/50wF+CSAdzPsJr/xIAjlv9SXST7Bm8nvPIBDrZRKuuByKZyVIzHu+XkH/wiFJc/gYdpu3XrijAN/OwUAPHs4ewZfS1zyk6mamN3uZ67Y",
                "IzSZ5SQ4S7I9Q+GhSTPITn65NngDeQdHWxnwTCyeE3+X6OEXvBAduDtpd81xbfCFu6vjnhyCz2aEA7gr/HpQe5nM41szu+rB4wjwqdbfXlEhZBn4Sik7bfak",
                "44mWOzfLfHY3eLh3aZRGn3N//hfxyHaDzxT+hELJfK58/iqKHBYUhwsnOvLqY2jAGaVLi5gf2PP5z/PjmGzzRCQy1T2adE5BdvJsOO32PGpPzFYbNXgcJ/D8",
                "FMu9gIVrLR344ut6VCF8JjJW8/MdgC905rCy4HwyItSHBLeBP5g7sxwipZxI7toJvnzPccUuymuuHD2GA4sH448drDOgWn39ZAqllB3hnwM+2cCfIzT0gdHf",
                "6ycK25DfgVmTqxl8Ogc8LyGVQM7d4LFiBVUFf5DQWI8Yc0fwHYHH8aO2VYL5u+IN4E/1JKn4I6o1J7AkPvkm8Mzh9GftW9qHKaoSOQB/jsHXVJ3fF19T1f/5",
                "qCvgcRp44WmAs/ElBp+ZfG3l+oL+nClTeE25iQA/PIZAmfwag/9e8KACA78nTl2Bf1+bSHotu4J7ni3zZeDJtLMl3AM8vXxakGF515pvAp9K/3Ipd5STOwf+",
                "lZ2AV+9yB3hmfl3YBLBYUnwX+Oyk+sIU+ofIfyF4bJhY8zAevhI8dugMgEehZim7463ci6zhVUd1bmUkpbSa1xo8trVdTOlR2pYGjxeD39ZOWszcuPVtey13",
                "rNjtE584G1XYafBpleJiw1FMIea/8wz6wlPwz4MJO6Z2YYWxG/vkM5B7TEwsz74DvLhr+iLy7B/bx90ui0Nsb7nMe3Mz2qakn/F/Qeyawg==",
            ].joined()),
        Capture(width: 365, height: 607,
            sourceHash: "4ad13ca7e9a7a3f05faa20491dc6bbf00cd1d417deb7f701efea0b58a5bcd803",
            maskHash: "12f15ceae5582a70cb75dc2f31b56ee5f8b4d8f6c98d9d785a2539ad194978fb",
            core: 13227, halo: 12040, artwork: 9748,
            encoded: [
                "eJztnYuS66gORWlX/v+bZ7oT2+gFEgiQc9hV987pGAu8siMw4CSlra2tra2tra2tra2tra2tra2tra2tra2tra2n67W6Af+QXhv2NL027GnarKfp9dqwp2nD",
                "nqbXa8OepT/Om/UUvT29Yc/QJ39s2BN05uoNe7w262m6hyAb9mhlw70NG8odB2C9YWfyp5ED3rBzudOAt4wb9i3/m2kUcLO+5D9zgeNt2Kfcp4loOF34739H",
                "/KfkWll/f2Yfwpq+pG+LY0uC6fWZ/vS7RJaXNv5X0365T3/ytNQVfDHt88r8rk9gZYj/rbTvGTmvy5NYW+J/Je37otyuTgpkjP99tPPZz8GszWnqy2jnn1Wv",
                "S5PjmCv4qlQCLsbnugp8Wsh9De4RE3KlKE01fAdtfBUe11QG04btC4bc9BIcrqhCpbWGp9Nm7NJ9PVUmzcgebW6u8d1Xo2DdXsVjafM+6bwYBY0+Xo/ELX0k",
                "+y5FQ6KT1vNyiThp3XUhOg7jE1UsyVR6WauKtVdhqymCSgZsvwj1x9tpIP8I3OV29oyB1csvbVU0V7hMYrK+jreHVRdtqqKnziWqt2/8nbQfodi0Nawb54j0",
                "p1mKOlc9T6p2TZj9dIXtv6HIQ8pG2RtuvlZf2PFw69tjJ2e+UG/YsXC/DI0xNrrlIoek9xi4LaSTEXbbBY7pSwPY24jaBLv14kytMQVeidtM+n2SIXZDo6xu",
                "NcZexLuxXgNsc2xLBQ2FP2dMx93+Fivn7dovaDDsNJl334dJc9/TNw9rKtwxVTOc96s7bdUWxnuvwtrpNVczGrhL/OL869Dw3aXxucN4u4UWY/jEnwc7jeH9",
                "cg3KxnGrwDx2dqjRB8/LKxCNylTiFHxkcTFKJ6ghnEls9zqWwD5j5ddjmuUa2t0OIp2Wwk6Mi9QFxw4kB9VhvwP3bsEnrFYjqp+lGLDz+N/H+JT5Mr7jsteo",
                "Afam3aoNe6I27Ikauma5BbVhT9SGPVFNC10jGuKi43+tbkNB45ZF5+rItboxkr4D9oG0uj2CvgA2Jr1hDxMBHJh204Y1/2a0CpD++VVk2oN3B45VRvrnVtwx",
                "SctALgjszNU/P4+A/dykLaAOTfuhsGXUXwd7Ne0S6g3bVWXUG7anLtY86i+DvTZp11Bv2F6qZZAN20vSwPrbYa+gfVST9Yf1ht0tpa0/xo4K+xnDES3qyMZ+",
                "CmxdBokO+xEDbbWtdazxFPg8xYet7Bi1sI9bs67gUvixn8HWirWDA2jaRXwUHbYFdd3YN+MltIMvHxgyiJY1+8ccxYZtY62CfUZbMmwJDNvSM74BVvj9HdYW",
                "HqG4sG3pWmNWAHsF7bCwrbau36lD1o+BPZ62OYWYjf0uP/xCgBrITYDdwNrUPT7H2uNht7PWZ5FF1rafMRi2uWvUGDvRt+8JeWQw7BZbtxh7w25lbc/YP49J",
                "2iPa8VEba+u4736DBl4Ko1iwG1nXXHpwsJfkkfFnaGXKIQnfoRiN/Yw8Mgy2ydaJwC4HZuIugR3kuxlstk5ZyUr3yCeRi/ZM3lFgG1mTW+8ybDbwA/LIGNhm",
                "1iZjF/YXz6VttfYQ2DbWzJySyExMIkusHQG2gXUiM9Otxn5CHhkAu+Q+ztYG2OXQ4W/Z/WG3sNauuZQ/MtGt7T83os8h2YYmg7ELoRcs/K6FbUB9b7NBsEux",
                "i5+Z4Nb2hq3OISlnrcwi9I0k01Ghrb2O9XFLmUUY1s+aaPWFrc7X9x5LfRZh3shElhBCj7VdYWtZp3sUYtj/wRibmdY+FtD2L1mXNoeAL2GApxRg0+j45EW0",
                "9db2hq15eOO2dUK8almEsuZXbIImEkfYWtYHYq3LIiR6acUmqLW9YRtZoz0JMmxuJMJ3EQs2ECtpOw6zNawxavVYREjYvLWjJhI/2IokkghrCFumVGDNVBp1",
                "ROIGWzMSIahRFinDJqO+izZv7XiJxAu24DHWi+g0BWzR2NJCe8xEMs3YZ5mDnFZP2YXOsUg7mrc9YZdZU1uT0wQ/yr5OYlcRMm1Pgi2wVsGmGSr3rfSRCmht",
                "1/5RXkBhUwg5jc+0TG8AQErWjpe2PWGL3aNka3wan7KlJAIKSNb2uTitKjQ9R9kC7CTaOuGJEdnYzHsHSoTZs1PiOR52wdaalF1O2MW6FySSVPyBKd/7x4Kt",
                "CxMeJdga1pGsXaI9emIklVnrYNdYy9ZeALuQSQbDrqCuD0aYhM0FlAYkK2DL3vZdOCDLgYWe8TqpAPuod45cnMWwJdruqzQc6tLlQthcLlYkEa72lbCFVDJu",
                "SSzlM6CVkyQ2IuvwsFna7ivr6c3m/LN6rfANguUtrNmb9hVDv1M0lfhuhspBaFz9KSfBpqz5zjErzn2H/yraBLfzzrODSHMKhA2DJa4TKFTOfg7UjXEWoj1i",
                "S6Xt6kTYVtaXi0XW83mD3ysetFnYcl0SbC6HVOZMz3oLrFfiHvZ8h/6SCOx8jtrEOqv63UHzsOdPun4oL/rq7Fw87CbW6TY34YwOT9UbdwDWLOwTiZk1AxmE",
                "WrAu+adAsPFNTYG1anQDDA1DrRt4R2DNzY0wrC0jZpg7QPyl9+8rakWCMBLPOlk//yBHgy8gSGtgh2CNl8UuqK2+zsMeOPyGjWj/CaJuGE7mA5AN+9JBcPRt",
                "AEZvDDe7MuQ6yorBmltzaGcN+sYzOBnWDLuU+MLWZlEbxyFSFtmw6UCvjTU3x0dhLxr6BdFRsLatbwSD6/Nfy7/VMpZkaxvHIVecKyibsv9p2BLt1Mr6J59l",
                "YYaRI68lvpgbmfNl42wtgrphU11QqasNZFSwbSG/UgfEne6RhS0GnGXZsHkhtuTmRBkCwSbjnJ1F/nRwskZIFPYejLDqQ83BJsbeWSRTO+mkgv1QYxf313eo",
                "g4UG9hON/Tq1uiG56rDXrUB26JVJLDK1Rb9Swp7erj69XmXai3xfhf1UYyeZtsL2Y1SDvWrTSJ8ymAzSiu3HCcE+hWE/izaAiZHerw4bsLA6OULYYIxt3xAR",
                "QC8q+diMBmWD85+ynkebgf1ij834Ob4E51EqsNEXDDxAmHMG+84s0xJJfsdZRf1NtCHrCbCtpC/aQ1vlKoj0hsrll/E/EWcifdIe2CpnUaBvqvhNGAxbn6jX",
                "W7sdA+tgSY4tBrpsLSFFWgq7AwNKzayhR8OuufouREo+CzaDNnHQxw39Kq7+ue/WD/oJmA+7j4NgZjxFNQq2ZGv8OAeHeg3svrP5lDEHNm/rv0M8bOax3xHt",
                "ktRLgSfL8fcXh/rz+r0h6trJQHf/zGfdD1tl7GGwCWto4Xch9iPwOGOrrN3ylmpA0LxAB4I3bPaRkZYrbpWD4yQndxlbxwEY+zztpI1hL/8CEpdPN5+iuzK2",
                "EkPONOFhRw5byiHPhF0ibje2lsLF8PPHyU8Be8EqpE+35W1sMFSrFUSnXH/CZ9TZ/cJPup/Jw7gaG9+G6MrlRWuwV6zTeI3HiomkKYu00IavE9hkJ8MzWRe9",
                "3cia/LNQlpZCsJk9xA9NIp9Qvin72gqvytukDIadj8jTCl+77gsTE0mbsZlvL7LGILCP7OAC1p530ALttt6xexaUhX3mk/mo3Tc8srRbJkUQ7KZ1QgIbdbrm",
                "gJ3yNXaSb9utcdAwzQl25/b6TvlPwxHabZN9zrDR0GbNcvqAOU88AmliPQC2vQ3OGjK//MrMzW1rVen7YLtn7CvsGbiD9ffBHhUXZhK70J11O+zUPphx1rBd",
                "HL2sMewKLaHPOz8eIR7nGJRFztjtqHnYBNfBiEY5Sza2xEuznygyCKdsgosDTXDn94uTLwBrpLF7VYbNAZZpB4G9uAEFMYMRvBrDIZRpz2q4pOfAPo3NYf4B",
                "HwAybxqCdGzWLGxE+odVFLpIT4X9e5gHjTNOHIVmLcH+O1YgTfvSGAoN+0CwtaSDWjvyuI+D/ftqHfRl7dUXAPUs2MnwVFI82LFZk0k/kwLCXt2CgpivhDPB",
                "jkY7NOxeZ2/Yal2jvG+BHThlH92woyXt8KxTD+sNWyUH1OFgx2TtQjoc65CwHXJ1SNiBWXejDjcRFQ+2Uwa5WG/YotxcHfDL42Ky9kEdjXU02H4JZM3jBGWF",
                "gu3XLy7dDSwp1K26k62vULFQhzK2j62zUNFYB4LdjTqPE5B0CvUbmx2z1jBKWNahYDeyziLEJZ3iwG7sGfPTkRZejKQgsK3pGpyIGIfFHYQ1eY5DgVoyc1xz",
                "R4JtYF1KGrm9110Qp6+AjSMd8B9h9BDYf2UobCnS+5mwaLTD3KsXYNPjJdceV8lgSzRxjC1vwzkPkm2scqDrC1uCWTsMbMHaKR/IQdiys1O91BKFgk2++C3B",
                "cZwGdm7sYGkkTMpO4LYme0WALXLMjR0O9uoW3ALDCzKyU8LO3pRwY79IsIWHdO+Dmq8tyj8dwVjHgl27LVTAjmzs2LDJMeauhnl/Nut+KWGHTSLPhU1++QQZ",
                "u3+/SN83dvARHYMNFgebKQZuhdpr6/0yGi6kV6AJwj3kR+geCBu/sbLur1niQvrEmSLYQ1aU+vYynN/T1vv9PzCmQ5BZMsHu23yWf+9j8qL9INhgWKfm3Uj7",
                "xaj7CiohAr0VYFhnxm2tLU8gPV/8iIKWD/fGd9OJzMi6kTZ1tQPtWoAoWaYZ9Y3bVB+XRbpp104PArstg9y0zd7mOP8jsCusP6U8abOu7qX9CNgF1qBcjbah",
                "Sj6HdNKunhyAtpyuz6Pg3RDeFRttIWNztNXpvF5mPeyCrdmpvsS/MzbaUv9IqBo6T1URdQuHqJCu80lWsMLL3fq4wMZUpdeFmIpq1S0cosJdI5tD0AuQtrpW",
                "kTOAmjFW0I4PmwFHfp2KYc3QNlu7OiS5X2AzDA2pqVbdQn8RbH+vYtg4h7CzKD6wM6jlDMOF1FSrbqG/GNYZxcSzTvwHwppHSon7U0TOMGxIXbWrhA2KKCaJ",
                "NZvqXZL2DVW2vBhRVa26id4ixoYJgu40y/eYDIKdo2UdL0dU1atuorMQsXuokb2QfjjW3DMjTkm7/B6UAmqrXSMADIyq7xQusOY2aXqNtBP4zzfBxr5OEPYF",
                "/cAoKWzXPDLI2cvyCDDnjZMZRHMLBJ2wq3nEOvR7FGw4rKMJAoN0gG0D7QV7DW1hqMGPBwnGzuFIzdrCLU8xmrbWFcKDPH4ILS2ge8A2W7sYTVutoY1+ymED",
                "X3ODlNLZ/rC5IbYb7CW0b1y3sTFrecWrG7ZxqF2Fra/W0kgvZbDvgcgBl23klfPeDtI6+qtY8jGw0ZIMYCjBZu4grbDtd5HFWJZa54uFTYbY+izSAtvo7lIs",
                "Q62mVvqIgc0vwOhTth22lnh90s9QramVPiKwUz4IyR/mKJ3cAdti7ZohTbAX0L6cfPEEKSHd7wR/MqRtzyIWa7ssHdy1GtvpoJvX358ZNnCs1EPqvsVBlsHa",
                "DiuQLWW9RMyZY7sOFmBnuFufsDEkkS+ATXtE2F2Kjr3zfPanuQ36ROK4kW8+7Ny9eQKB48BUvKu5Ch2NrLWcvWEvo50E0rlKASqlKlrAekkeIYgE0hJFD9aq",
                "RKKCbeG3KmnLeOsUPVgraCtYPwB2xcp1ih6s64lEB9tYZ3Nz26WhrQvQ0YibaDPrR8BW0NZF6GpEkbaK9TNgV2lPaURnDklPgW0dgoyR6G0lazvshXt1otLW",
                "sjZbdeEGy1/RnnE9bTXrh8E++YLpkZkNeFHcetYPhg2WE6bphXEbWDfAXv3AB9khNRU2NreF9bNgQ2OvsfZt7vT+38B1xQ2bPkfzmTiBx/kTzTX1tLNPQWBD",
                "3Pdf8CB7mrmezoZ2CKbshbAz3Dl5fISeZK6lv6WtCgQ7Maxf6Pkx5hx7JS6NbRDOIhnsJbeWF9zPX9cgJSW+53wy7OLCwiTD50aG3SZD+9Gwy6yn0M4pM3NU",
                "uLA9vFdDrTLDnpJKMsh08QwXtof3aqhVdtjjaUO8iSQTVNge3quhVp38lCl7Gu188OeeRtYuIBRhw6IzaNM87dhBLl/0ZbJI8YzBDftC2IcE+3Mc7wWcN9/N",
                "JY8Hwz5gugBb4RXfmjiYtuRsJmWHh82k5QLeVbSV65JNsKfRZocXAWHrskiTTSfBZkjjR/JqsBs3v9skZe0HwWZBm7+kfFUfya/gRIXdD3oebOYunWXdlIDH",
                "w+5KHvNhE9rS0mRA2C6mngqbTpE4LUIOh+1j6j/W8/Y61HvHd6mGwN1tK8iL9FzYYKFGYh0Otkv6OGHPyiK/ujJIYS9JMNhepp5t7AR3polFWqL2NUvWzbob",
                "9fztaeV8/S7RErWnTQU52nrFVsAa61CwfW29YttlmXUk2CdrD9BLdm//qsgmHOzu4V4WawHsouLA7jY2ChSQdjTYbcZGQaLSDgO70djodE4DGtuqKHc1Vtjo",
                "vJIGtLZRUe5qjLCzUx5EOwpsY85WkV42AJQUDLb8s1ZvXX+WGOeEQ9EO00Py1kaHmd+0ohkjf9tieTsObPoYR/4yPFj67gDwEYkGO8hwJDEfeca4ijSSl9yw",
                "RdUI6mGvfQxYVCTYWr8qnqf52bCr8oEd4/E9RrFgKx1bLkd+DmHDFiTwM8Am3yschnVLDzltM0NGSYLNRQjLOh5sniMyrfzcgeK3ghYqHGxWBPbviz9FBWT9",
                "UNiKGasNu01M36dQsKHIrx4AmxtoZAa+FN/b9h5y+gNjEmx4mHknwtGODpsfQf+Qg+xUeLhMEhu2YOuE72vg76oEtvboEzqUwWR+2lRgHXdyJDRsKR/LrN8n",
                "RZ32CwybdzWFzd6hf4m1Z8GWbI1hM6zv7vLp1p78jC9IEQxslnVGO5a1Y8KmKSTr+dgbnQTHiTGtbR1pz3ygmvR8CLZg68BZOyBsQuzcOSL0g3Tg/SV5ZAJs",
                "xtcHA5seP/DOkYB5ZGTxBuF0TQYZn8E09v37RQQ7mLWNSXs4bMnWMDdwqMn+sw27IgKLG9Dx2Zo/PxRsI745a5D8N9zeduY6RhAh6i17QNjC9mAyScI9GkbS",
                "UChr2/LIjK0M4lbsJKE+xBAy7DX448CusM5hJx41yUMi7EVuDwMbgyJbn1KVtRr2qtzyFNiJHQ8e5RgCbHzyPO4WgONhs7N7cF6b6xhBjBps/FZNdHkQ2CVj",
                "J7gwJrLWwUZv4tScEgo2HUfQxZrCcK4C++8f4BNz0JwyVpFh/x75QSp4EQfJYSPGpP+dQ9tAcCJs+ZubZdjE2NIv2vwfN1Hcw64tU1DYP9L2PgPsuyjCmh+c",
                "SttwEzkVNiKsuS0UYWOoAHZKhW7AW2qEA7/+rAz7r0B9tUuETRwMbT9zDiUQbG7b3nW0ATbLGsMuxnSXluFI2ALt/Fh9aRF/PMiY+ryDyWAnmHCGKwTsHGHG",
                "mVs+kF0IaIOTP+P1bKEevoXTrK2FOBY2vTPEn37c7ckxaID85Bw2WbQfLjXssc04ylLtB5HOzfN4lkUWPOqutOyk9V6ZtgK21CdS2PD9mzhFEgR2hbZu840J",
                "Nu5KR1/gr6LAlnx5klCRYc6ksPMtbbPXKlUcJ+4+y3ndL+O7kWqMxA4HEzb25LWbMLDpAk3+Mv13MUZemIG9ahFe00XOe8iDu3LW8IoAOI+8Yb/XwtYYW0Vy",
                "xcPUmQysmdMA7AQy9vwFYIW1F8Nm7r0NZ4GU8Vm0WcVag3I17NTCGsPOEvqahP2nurWXw25bL4Q9ZBZjnbEVLNfDbuICjYyNvWjHTtXaAWCnBi4ALmHPD33G",
                "6wmwG8TCRrOw81tVs3Zw2OJYJceLFiLWbfur0B48m11WFcgBxRzKl78S9vl81WBPawiS4FiuBIs7f4HtLcc2X1BM2GJ+4EoUaB9BRiKnSkBXwRbTA1ugSPs6",
                "EIF1MZEsgi0T5AsoaMdgXaQdgjVlI7OWaIf5OnPXH5B0UJkgKMC9yhcMYuwC7SWwIbQy1Z9bbFlo7AisZdorvxr0s7+GAkKZIcct0g7EOhJsAhIjklDzKTmD",
                "HYS1RHvB/SNDEhIssWaARoTNc50PG3RnHOwiapl2HjuAOLDLvmA4Sfy440ragVgn7td/QxibgV38rmdC9cg1+YIkPQG2gjWTmuOxZmjHSNn0iSSUZP6koz35",
                "ckrCcGOkbPJEEpfQC8OXPG4kIdoxYfOPWcPn+wjbQKxft+DLsxtShM0cpLMfgrXrqz4z9EKCx6Y3h+sBZdjcvJ5g7fXCjCHsFeuPddiJcTClHS1JUyeTAtPa",
                "cqkHtuKbixapAvpdZEpLgLikjWD/yLBX7b0uq2bqd6EZLUFqg00+EJFga1A/EHbIb63U9XwrV2m0sKXbnTiwozwAyYmD/SPCFnvIMLDVrB8HO17O1j+zPrgh",
                "rKywhVFhENhqwz4CtvSjKmFga8sFhS3OjcS7qQlubOEWUoItzppEge1d0FkK2HTCiR6IAHvcd55JM4fM4eKni8sj4gBPNHaIWb9hxq7AfL+ooV2CjfaMyNNQ",
                "z2JthY1nxcn6GkRdoF2EndMm+69pKjddgrsMsI1xGcHDwNYF2mXYeS6Gdo+3dDDI2DnMjDx3WGttcQH3QGLKx4A9KIsQmHBhgssh7bBx8ojKelAWYVPITRva",
                "nvoei8kjcCBXYR1j2DdqLMLBPvmihfv8qBSuCjtVWMcw9jjYAvDzCDPy64GdEGt+inuxCp/dxoJn6YwgzSXcn32wrz03YRO2ydg22CmnmQjeRI+W2sIQpFk4",
                "GweGZD1qwk+AW0gi7xckqWCzBSPt6Rs04Ycp4tTBG9tyw84zJOUisZ4AO8n/oO+BJCXs2Ky1EI1ZJLFs738wxtakETPsWKz1sK1hWSfDe0pi7F7YwVmrYZvD",
                "8oxpfsk70EJA2vFpYMdirYRtXqJh8jGWiTWTjeuw44z5PhoEuzgcyfmqkkgywVZ9b/wSqTDaWZN5PX7krWbdAjucscfCVplbxVoFO3oWGQe7RBvPUw2CHS2L",
                "KGE3hpbHeglMYtdZ/0Owm2NLeQP8W8NaNayDReJlkaGw2UySEmSt3YWvhh23fxwLW5jbo2bXxKqiDN8/DoZdpf0poFE1SYRP2aNhk9nsZtbQ2pxtnwB7Cm0w",
                "/MDZWysAjwGZ0442B/XWhKSd4U0pIdSW6g8k/jgo63ERfpo+HIGobbWXWdN3IxjryQNtCt0mI2yPi/DUQNj+rCvWvl/952Dj1NxNuubc67WfFHCQ/SvDVdus",
                "+Xf4lf0/Hgba23oUrXu+EvWW5lfKeT9rLpAKd1g7p0lhnvjjDrOTCrZEp4QNk4Ws1TfpmYBzpW/qi7tM8ycl7NIx7jCCjW7cG2Aj5wo7K9f92qBKTdmThCBB",
                "SM5QJyBBXwHbZTxC2RHAybC1jxOCKX6rc+g04jT4w/AYH3s4u/AoeiWnx5DXSBviY7IGBm8LX0sjOe38r1hySNo40jnJJyJ3GI2Ik6zZP8Ox9ryJPBFeq12e",
                "sHPaiXfugeRyUb7yvGN/nVPXRdpNrLkpVL5EYNa+Cwg1zj2wFc6Nztrd2vkdTGn9sUF150Zn7TzzB0GzNzOtrDXODc7aeyESQXU0dtI4NzZr90ntCu0OYyeN",
                "cyOTTkNgf4gytPtYx3duTd7LNYi2dctqRSFQdyTFUXnkot0zuRpP0DlW4COsDWjD8eDDxVyDhbc7gRzsbQPtltXYEi5Bj3uktXEH+XAVLkF5gUOtDXD7VjNf",
                "lUvQXOMQ2HmG/hbWihxQv053DMTL38JauxuhM4hJTOJ4PmqtKWu4h1j7K0YfQNrLKdP2h7KU9kujlrDGJjjEUdc1u1esQu2Ebr0xl8q7w55rbSvENuLGa5ED",
                "P9bafbnBdK45vBT1idZ2fENVcRqq4WP6QxkJe8zHphayqTY24mPyyMgEVQ7cViEXb0DbB9IYnpv4Q+0RfUIVa/GON6PHTTye1HE9NFxsa0/CDOsjr3WF84ol",
                "VuEVZzLqq1L0Sl809Hd7MKEGlyALSN81g797o7kF4yvoDrCK9F19/ldvMPBXTzA2ft/ZCzkzbehujedbx0bvOXc56l8B2n6xAll7bfZAupriMy2Q/bs3HA7e",
                "dlYc0r86m+PRqvvSIsCORvpP7za5NCyn3R8NRbY3JRzqdE+rOcU6/+ERjsbVlg5J+k+O3YhnWoJxTU0Iizo9gbY6WnTUybWJn0iLYD+AdWkNtylW8qativYI",
                "0n9ynsecD/s5qNOAWWNn2oo6HesbLce2Tof9MNTO8qZdjvVvs3anXQr1j5P+1SzY/7qrP5pCe7N+y9Xb0h6Mjfqj0bA3aiA/GkygzRppIOyNepiYjUWb9SiR",
                "bUWb9TiN3na1lWvsPqAtoJG7gLaQRm4C2kLy2yu3VdWoPSlbjK6Nchv2eI3ZkLLFasQOiS1BblsSt+py3x6xJetR+0Kerg17ojbridqsJ2qznqgNe6I2662t",
                "ra2tra2tra2tra2tra2tra2tra2tra2tra2tra2tra2tra2tra2trcD6D9D5Khs=",
            ].joined()),
    ]

    static func verify(_ index: Int, original: [UInt8], restored: [UInt8]) throws {
        typealias F = NativeSourceRestorationMatrixFixtures
        try #require(captures.indices.contains(index))
        let capture = captures[index], count = capture.width * capture.height
        try #require(original.count == count * 4 && restored.count == original.count)
        try #require(F.hash(Data(original)) == capture.sourceHash)
        let packed = try #require(Data(base64Encoded: capture.encoded))
        let compressed = Data(packed.dropFirst(2).dropLast(4))
        var masks = [UInt8](repeating: 0, count: count)
        let written = masks.withUnsafeMutableBytes { destination in compressed.withUnsafeBytes { source in
            compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, count,
                source.bindMemory(to: UInt8.self).baseAddress!, compressed.count, nil, COMPRESSION_ZLIB)
        } }
        try #require(written == masks.count)
        try #require(F.hash(Data(masks)) == capture.maskHash)
        var core = 0, halo = 0, artwork = 0, remainingCore = 0, remainingHalo = 0, paintedArtwork = 0
        for i in masks.indices {
            if masks[i] & 1 != 0 {
                core += 1
                if restored[i * 4 + 3] < 250 || F.delta(restored, original, i) < 10 { remainingCore += 1 }
            }
            if masks[i] & 2 != 0 {
                halo += 1
                if restored[i * 4 + 3] < 250 { remainingHalo += 1 }
            }
            if masks[i] & 4 != 0 {
                artwork += 1
                if restored[i * 4 + 3] != 0 { paintedArtwork += 1 }
            }
        }
        #expect(core == capture.core && halo == capture.halo && artwork == capture.artwork)
        #expect(remainingCore == 0, "Erase every annotated colored letter")
        #expect(remainingHalo == 0, "Restore the entire annotated white outline")
        #expect(paintedArtwork == 0, "Preserve the original hearts and connected balloon frame")
    }
}
