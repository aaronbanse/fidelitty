"""Generate a glyph set TTF from a trained GlyphPredictor model.

Pipeline:
1. Load STL-10 patches and trained model
2. Run model on all patches to get masks
3. KMeans cluster the masks
4. Quantize cluster centers to {0, 0.25, 0.5, 0.75, 1}
5. Deduplicate and build TTF font
"""

import argparse

import numpy as np
import torch
from sklearn.cluster import MiniBatchKMeans

from data import PatchDataset
from font import build_font
from model import GlyphPredictor


QUANTIZE_LEVELS = np.array([0, 0.25, 0.5, 0.75, 1.0])


def quantize(values):
    """Round each value to the nearest level in QUANTIZE_LEVELS."""
    values = np.asarray(values)
    diffs = np.abs(values[..., None] - QUANTIZE_LEVELS[None, :])
    indices = diffs.argmin(axis=-1)
    return QUANTIZE_LEVELS[indices]


def main():
    parser = argparse.ArgumentParser(description="Generate glyph set TTF")
    parser.add_argument("--checkpoint", required=True, help="Path to model checkpoint (.pt)")
    parser.add_argument("--data-root", default="./data", help="STL-10 data root")
    parser.add_argument("--max-images", type=int, default=None, help="Limit number of STL-10 images")
    parser.add_argument("--n-glyphs", type=int, default=1024, help="Number of KMeans clusters")
    parser.add_argument("--out", default="glyphs.ttf", help="Output TTF path")
    parser.add_argument("--batch-size", type=int, default=4096, help="Inference batch size")
    parser.add_argument("--cpu", action="store_true", help="Force CPU even if CUDA is available")
    parser.add_argument("--max-samples", type=int, default=500_000,
                        help="Subsample masks before clustering (0 = no limit)")
    args = parser.parse_args()

    # Load checkpoint to get patch dimensions
    device = "cpu" if args.cpu else ("cuda" if torch.cuda.is_available() else "cpu")
    state = torch.load(args.checkpoint, map_location=device, weights_only=True)
    patch_w = state.get("patch_w", 4)
    patch_h = state.get("patch_h", 4)
    print(f"Patch dimensions: {patch_w}x{patch_h}")

    # Load dataset
    dataset = PatchDataset(root=args.data_root, max_images=args.max_images,
                           patch_w=patch_w, patch_h=patch_h)

    # Load model
    model = GlyphPredictor(patch_w=patch_w, patch_h=patch_h)
    model.load_state_dict(state["model_state_dict"])
    model.to(device)
    model.eval()

    # Run inference
    all_patches = dataset.patches
    n = len(all_patches)
    masks = []
    print(f"Running inference on {n} patches...")
    with torch.no_grad():
        for i in range(0, n, args.batch_size):
            batch = all_patches[i:i + args.batch_size].to(device)
            out = model(batch)
            masks.append(out.cpu())
    masks = torch.cat(masks, dim=0).numpy()
    print(f"Collected {masks.shape[0]} mask vectors of dim {masks.shape[1]}")

    # Subsample if needed
    if args.max_samples and masks.shape[0] > args.max_samples:
        rng = np.random.default_rng(42)
        idx = rng.choice(masks.shape[0], args.max_samples, replace=False)
        masks = masks[idx]
        print(f"Subsampled to {masks.shape[0]} masks")

    # MiniBatchKMeans clustering
    n_clusters = min(args.n_glyphs, masks.shape[0])
    print(f"Running MiniBatchKMeans with {n_clusters} clusters...")
    kmeans = MiniBatchKMeans(n_clusters=n_clusters, random_state=42, batch_size=4096, n_init=3)
    kmeans.fit(masks)
    centers = kmeans.cluster_centers_

    # Quantize
    quantized = quantize(centers)
    print(f"Quantized {quantized.shape[0]} cluster centers")

    # Deduplicate
    unique = np.unique(quantized, axis=0)
    print(f"Unique glyphs after dedup: {len(unique)} (from {len(quantized)})")

    # Build font
    build_font(unique.tolist(), args.out, cols=patch_w, rows=patch_h)


if __name__ == "__main__":
    main()
