# export.py <variant> <W> <H> <ds> <out.mlpackage>: RVM as an ML Program that outputs alpha only.
# ds == 1: the input is the small frame itself, alpha comes out at that size (no refiner; we upsample on the GPU).
# ds < 1: full-size input, downsampled inside, the deep guided filter refines alpha back to full size.
# Weights are read with weights_only=True: tensors only, no code from the downloaded file runs.
import os, sys, torch, coremltools as ct
here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(here, 'src'))
from model import MattingNetwork

variant, W, H, ds, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4]), sys.argv[5]
net = MattingNetwork(variant).eval()
net.load_state_dict(torch.load(os.path.join(here, 'weights', f'rvm_{variant}.pth'), map_location='cpu', weights_only=True))


class AlphaOnly(torch.nn.Module):
    def __init__(self, n):
        super().__init__()
        self.n = n

    def forward(self, src, r1, r2, r3, r4):
        fgr, pha, *rec = self.n(src, r1, r2, r3, r4, downsample_ratio=ds)
        return (pha, *rec)


m = AlphaOnly(net).eval()
src = torch.rand(1, 3, H, W)
with torch.no_grad():
    _, _, *rec = net(src, downsample_ratio=ds)
shapes = [tuple(r.shape) for r in rec]
print('states', shapes)
zeros = [torch.zeros(s) for s in shapes]
traced = torch.jit.trace(m, (src, *zeros))
fp16 = ct.converters.mil.mil.types.fp16
inputs = [ct.ImageType(name='src', shape=(1, 3, H, W), scale=1 / 255, color_layout=ct.colorlayout.RGB)] + \
         [ct.TensorType(name=f'r{i + 1}i', shape=s, dtype=fp16) for i, s in enumerate(shapes)]
outputs = [ct.TensorType(name='pha', dtype=fp16)] + [ct.TensorType(name=f'r{i + 1}o', dtype=fp16) for i in range(4)]
ml = ct.convert(traced, inputs=inputs, outputs=outputs, convert_to='mlprogram',
                compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS15)
ml.save(out)
print('saved', out)
