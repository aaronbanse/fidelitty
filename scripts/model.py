"""GlyphPredictor MLP: predicts optimal 4x4 grayscale mask for a given RGB patch."""

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
    """MLP that maps a (B, 3, 4, 4) RGB patch to a (B, 16) grayscale mask."""

    def __init__(self, hidden_dim: int = 64, num_res_blocks: int = 3):
        super().__init__()
        self.input_proj = nn.Sequential(
            nn.Linear(48, hidden_dim),
            nn.GELU(),
        )
        self.res_blocks = nn.Sequential(
            *[ResidualBlock(hidden_dim) for _ in range(num_res_blocks)]
        )
        self.output_proj = nn.Linear(hidden_dim, 16)

    def forward(self, patches: torch.Tensor) -> torch.Tensor:
        """
        Args:
            patches: (B, 3, 4, 4) in [0, 255]
        Returns:
            (B, 16) mask values in [0, 1]
        """
        x = patches.reshape(patches.shape[0], -1)  # (B, 48)
        x = self.input_proj(x)
        x = self.res_blocks(x)
        x = torch.sigmoid(self.output_proj(x))
        return x
