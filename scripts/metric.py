"""Reconstruction MSE metric — faithful port of compute_pixel.glsl lines 79-135.

Given a grayscale mask (n_pixels-dim, values in [0,1]) and an RGB patch
(3 x patch_h x patch_w, values in [0,255]), the shader solves for optimal
foreground/background colors via closed-form least squares, reconstructs the
patch, and computes the squared error.
"""

import torch


def reconstruction_mse_torch(pos: torch.Tensor, patches: torch.Tensor) -> torch.Tensor:
    """Differentiable batched reconstruction MSE.

    Args:
        pos: (B, n_pixels) per-patch predicted masks in [0, 1]
        patches: (B, 3, patch_h, patch_w) pixel values in [0, 255]

    Returns:
        Scalar mean MSE over the batch.
    """
    B = pos.shape[0]
    n_pixels = pos.shape[1]
    neg = 1.0 - pos

    BB = (neg * neg).sum(dim=1)
    FF = (pos * pos).sum(dim=1)
    BF = (neg * pos).sum(dim=1)
    det = FF * BB - BF * BF + 1e-8

    flat = patches.reshape(B, 3, n_pixels)

    p_dot_neg = (flat * neg.unsqueeze(1)).sum(dim=2)
    p_dot_pos = (flat * pos.unsqueeze(1)).sum(dim=2)

    det_ = det.unsqueeze(1)
    BB_ = BB.unsqueeze(1)
    FF_ = FF.unsqueeze(1)
    BF_ = BF.unsqueeze(1)

    c_back = torch.clamp((p_dot_neg * FF_ - p_dot_pos * BF_) / det_, 0, 255)
    c_fore = torch.clamp((p_dot_pos * BB_ - p_dot_neg * BF_) / det_, 0, 255)

    recon = c_back.unsqueeze(2) * neg.unsqueeze(1) + c_fore.unsqueeze(2) * pos.unsqueeze(1)
    err = recon - flat
    sse = (err * err).sum(dim=(1, 2))

    return sse.mean() / (3 * n_pixels)


if __name__ == "__main__":
    B = 64
    for pw, ph in [(4, 4), (4, 8)]:
        n = pw * ph
        pos = torch.rand(B, n, requires_grad=True)
        patches = torch.rand(B, 3, ph, pw) * 255.0
        loss = reconstruction_mse_torch(pos, patches)
        loss.backward()
        print(f"patch {pw}x{ph}: Loss: {loss.item():.4f}, grad norm: {pos.grad.norm().item():.4f}")
    print("PASSED: forward + backward OK")
