"""Reconstruction MSE metric — faithful port of compute_pixel.glsl lines 79-135.

Given a grayscale mask (16-dim, values in [0,1]) and an RGB patch (3x4x4, values
in [0,255]), the shader solves for optimal foreground/background colors via
closed-form least squares, reconstructs the patch, and computes the squared error.
"""

import torch


def reconstruction_mse_torch(pos: torch.Tensor, patches: torch.Tensor) -> torch.Tensor:
    """Differentiable batched reconstruction MSE.

    Args:
        pos: (B, 16) per-patch predicted masks in [0, 1]
        patches: (B, 3, 4, 4) pixel values in [0, 255]

    Returns:
        Scalar mean MSE over the batch.
    """
    B = pos.shape[0]
    neg = 1.0 - pos  # (B, 16)

    BB = (neg * neg).sum(dim=1)  # (B,)
    FF = (pos * pos).sum(dim=1)  # (B,)
    BF = (neg * pos).sum(dim=1)  # (B,)
    det = FF * BB - BF * BF + 1e-8  # (B,)

    flat = patches.reshape(B, 3, 16)  # (B, 3, 16)

    p_dot_neg = (flat * neg.unsqueeze(1)).sum(dim=2)  # (B, 3)
    p_dot_pos = (flat * pos.unsqueeze(1)).sum(dim=2)  # (B, 3)

    det_ = det.unsqueeze(1)  # (B, 1)
    BB_ = BB.unsqueeze(1)
    FF_ = FF.unsqueeze(1)
    BF_ = BF.unsqueeze(1)

    c_back = torch.clamp((p_dot_neg * FF_ - p_dot_pos * BF_) / det_, 0, 255)  # (B, 3)
    c_fore = torch.clamp((p_dot_pos * BB_ - p_dot_neg * BF_) / det_, 0, 255)  # (B, 3)

    recon = c_back.unsqueeze(2) * neg.unsqueeze(1) + c_fore.unsqueeze(2) * pos.unsqueeze(1)  # (B, 3, 16)
    err = recon - flat
    sse = (err * err).sum(dim=(1, 2))  # (B,)

    return sse.mean() / 48.0  # mean MSE


if __name__ == "__main__":
    B = 64
    pos = torch.rand(B, 16, requires_grad=True)
    patches = torch.rand(B, 3, 4, 4) * 255.0
    loss = reconstruction_mse_torch(pos, patches)
    loss.backward()
    print(f"Loss: {loss.item():.4f}, grad norm: {pos.grad.norm().item():.4f}")
    print("PASSED: forward + backward OK")
