#!/usr/bin/env python3
"""Check the actual training GPU before downloading or training a model."""
import platform
import sys


def main():
    print('Python:', sys.version.split()[0], 'Platform:', platform.platform())
    import torch
    print('PyTorch:', torch.__version__, 'CUDA wheel:', torch.version.cuda)
    if not torch.cuda.is_available():
        raise SystemExit('CUDA unavailable. Install a CUDA PyTorch wheel in THIS environment. '
                         'Use native Windows/WSL2 for the GTX 1650, not an ordinary VirtualBox VM.')
    print('GPU:', torch.cuda.get_device_name(0))
    free, total = torch.cuda.mem_get_info()
    print(f'VRAM free/total: {free / 2**30:.2f}/{total / 2**30:.2f} GiB')
    print('BF16:', torch.cuda.is_bf16_supported(), '(GTX 1650 uses FP16)')
    import bitsandbytes as bnb
    layer = bnb.nn.Linear4bit(64, 64, compute_dtype=torch.float16, quant_type='nf4').cuda()
    sample = torch.randn(2, 64, device='cuda', dtype=torch.float16, requires_grad=True)
    layer(sample).float().square().mean().backward()
    torch.cuda.synchronize()
    print('4-bit CUDA forward/backward: OK. Next: dataset validation and a 2-step smoke run.')


if __name__ == '__main__':
    main()
