"""GlyphPredictor MLP: predicts optimal grayscale mask for a given RGB patch."""

import torch
import torch.nn as nn


class ResidualBlock(nn.Module):
    def __init__(self, dim: int):
        super().__init__()
        self.norm = nn.LayerNorm(dim)
        self.linear = nn.Linear(dim, dim)
        self.act = nn.GELU()

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return x + self.act(self.linear(self.norm(x)))


class GlyphPredictor(nn.Module):
    """MLP that maps a (B, 3, patch_h, patch_w) RGB patch to a (B, n_pixels) grayscale mask."""

    def __init__(self, patch_w: int = 4, patch_h: int = 4, hidden_dim: int = 64, num_res_blocks: int = 3):
        super().__init__()
        self.patch_w = patch_w
        self.patch_h = patch_h
        n_pixels = patch_w * patch_h
        self.input_proj = nn.Sequential(
            nn.Linear(3 * n_pixels, hidden_dim),
            nn.GELU(),
        )
        self.res_blocks = nn.Sequential(
            *[ResidualBlock(hidden_dim) for _ in range(num_res_blocks)]
        )
        self.output_proj = nn.Linear(hidden_dim, n_pixels)

    def forward(self, patches: torch.Tensor) -> torch.Tensor:
        """
        Args:
            patches: (B, 3, patch_h, patch_w) in [0, 255]
        Returns:
            (B, n_pixels) mask values in [0, 1]
        """
        x = patches.reshape(patches.shape[0], -1)
        x = self.input_proj(x)
        x = self.res_blocks(x)
        x = torch.sigmoid(self.output_proj(x))
        return x
