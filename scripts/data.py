"""STL-10 patch extraction pipeline.

Loads STL-10 unlabeled images (96x96 RGB), extracts patches simulating
terminal cell rendering (variable-size cells downsampled to patch_w x patch_h).
"""

import torch
import torch.nn.functional as F
from torch.utils.data import Dataset
import torchvision
import numpy as np


def extract_patches(
    images: torch.Tensor,
    cell_pixel_width: int = 4,
    cell_aspect: float = 2.0,
    patch_w: int = 4,
    patch_h: int = 4,
) -> torch.Tensor:
    """Extract patches from images, simulating terminal cell rendering.

    Each terminal cell covers cell_pixel_width x (cell_pixel_width * cell_aspect)
    source pixels, then gets downsampled to patch_w x patch_h.

    Args:
        images: (N, 3, H, W) uint8 or float tensor in [0, 255]
        cell_pixel_width: source pixels per cell horizontally
        cell_aspect: height/width ratio of a terminal cell
        patch_w: output patch width
        patch_h: output patch height

    Returns:
        (N * num_patches_per_image, 3, patch_h, patch_w) float32 in [0, 255]
    """
    images = images.float()
    N, C, H, W = images.shape
    cell_pixel_height = int(cell_pixel_width * cell_aspect)

    cols = W // cell_pixel_width
    rows = H // cell_pixel_height

    # Crop to exact grid
    images = images[:, :, :rows * cell_pixel_height, :cols * cell_pixel_width]

    # Reshape into cells: (N, C, rows, cell_h, cols, cell_w)
    cells = images.reshape(N, C, rows, cell_pixel_height, cols, cell_pixel_width)
    # -> (N*rows*cols, C, cell_h, cell_w)
    cells = cells.permute(0, 2, 4, 1, 3, 5).reshape(-1, C, cell_pixel_height, cell_pixel_width)

    # Downsample to patch_h x patch_w via area averaging
    if cell_pixel_height != patch_h or cell_pixel_width != patch_w:
        patches = F.adaptive_avg_pool2d(cells, (patch_h, patch_w))
    else:
        patches = cells

    return patches


class PatchDataset(Dataset):
    """Pre-extracted patches from STL-10 unlabeled split."""

    def __init__(self, root: str = "./data", max_images: int | None = None,
                 patch_w: int = 4, patch_h: int = 4, chunk_size: int = 5000):
        self.patch_w = patch_w
        self.patch_h = patch_h
        print("Downloading/loading STL-10 unlabeled split...")
        dataset = torchvision.datasets.STL10(
            root=root, split="unlabeled", download=True
        )
        # dataset.data is (N, 3, 96, 96) uint8 numpy array
        data = dataset.data
        if max_images is not None:
            data = data[:max_images]

        N = data.shape[0]
        print(f"Extracting {patch_w}x{patch_h} patches from {N} images in chunks of {chunk_size}...")
        chunks = []
        for i in range(0, N, chunk_size):
            images = torch.from_numpy(data[i:i + chunk_size])
            chunks.append(extract_patches(images, patch_w=patch_w, patch_h=patch_h))
        self.patches = torch.cat(chunks, dim=0)
        del chunks
        print(f"Total patches: {self.patches.shape[0]} with shape {self.patches.shape[1:]}")

    def __len__(self):
        return self.patches.shape[0]

    def __getitem__(self, idx):
        return self.patches[idx]


if __name__ == "__main__":
    for pw, ph in [(4, 4), (4, 8)]:
        ds = PatchDataset(max_images=100, patch_w=pw, patch_h=ph)
        print(f"  Dataset size: {len(ds)}")
        sample = ds[0]
        print(f"  Sample shape: {sample.shape}, range: [{sample.min():.1f}, {sample.max():.1f}]")
