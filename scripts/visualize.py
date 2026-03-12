"""Visualize original patches, predicted masks, and reconstructed patches."""

import argparse

import torch
import matplotlib.pyplot as plt

from data import PatchDataset
from model import GlyphPredictor


def reconstruct(pos, patches):
    """Reconstruct patches using predicted masks and optimal fg/bg colors."""
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
    c_back = torch.clamp((p_dot_neg * FF.unsqueeze(1) - p_dot_pos * BF.unsqueeze(1)) / det_, 0, 255)
    c_fore = torch.clamp((p_dot_pos * BB.unsqueeze(1) - p_dot_neg * BF.unsqueeze(1)) / det_, 0, 255)

    recon = c_back.unsqueeze(2) * neg.unsqueeze(1) + c_fore.unsqueeze(2) * pos.unsqueeze(1)
    return recon.reshape_as(patches)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=str, required=True)
    parser.add_argument("--max-images", type=int, default=100)
    parser.add_argument("--data-root", type=str, default="./data")
    parser.add_argument("--n", type=int, default=8, help="Number of patches to show")
    parser.add_argument("--out", type=str, default="result.png", help="Output file path")
    args = parser.parse_args()

    ckpt = torch.load(args.checkpoint, map_location="cpu", weights_only=True)
    patch_w = ckpt.get("patch_w", 4)
    patch_h = ckpt.get("patch_h", 4)

    dataset = PatchDataset(root=args.data_root, max_images=args.max_images,
                           patch_w=patch_w, patch_h=patch_h)

    model = GlyphPredictor(patch_w=patch_w, patch_h=patch_h)
    model.load_state_dict(ckpt["model_state_dict"])
    model.eval()

    # Grab random patches
    indices = torch.randperm(len(dataset))[:args.n]
    patches = torch.stack([dataset[i] for i in indices])

    with torch.no_grad():
        masks = model(patches)
        recon = reconstruct(masks, patches)

    fig, axes = plt.subplots(3, args.n, figsize=(args.n * 1.5, 5))
    for i in range(args.n):
        # Original patch
        orig = patches[i].permute(1, 2, 0).clamp(0, 255).byte().numpy()
        axes[0, i].imshow(orig, interpolation="nearest")
        axes[0, i].axis("off")

        # Predicted mask
        mask = masks[i].reshape(patch_h, patch_w).numpy()
        axes[1, i].imshow(mask, cmap="gray", vmin=0, vmax=1, interpolation="nearest")
        axes[1, i].axis("off")

        # Reconstruction
        rec = recon[i].permute(1, 2, 0).clamp(0, 255).byte().numpy()
        axes[2, i].imshow(rec, interpolation="nearest")
        axes[2, i].axis("off")

    axes[0, 0].set_ylabel("Original", rotation=0, labelpad=60, va="center")
    axes[1, 0].set_ylabel("Mask", rotation=0, labelpad=60, va="center")
    axes[2, 0].set_ylabel("Recon", rotation=0, labelpad=60, va="center")

    plt.tight_layout()
    plt.savefig(args.out, dpi=150)
    print(f"Saved to {args.out}")


if __name__ == "__main__":
    main()
