"""Training loop for learned glyph mask generation."""

import argparse
import os
import time

import torch
from torch.utils.data import DataLoader

from data import PatchDataset
from model import GlyphPredictor
from metric import reconstruction_mse_torch


def main():
    parser = argparse.ArgumentParser(description="Train glyph mask predictor")
    parser.add_argument("--batch-size", type=int, default=2048)
    parser.add_argument("--epochs", type=int, default=20)
    parser.add_argument("--lr", type=float, default=1e-3)
    parser.add_argument("--weight-decay", type=float, default=1e-4)
    parser.add_argument("--max-images", type=int, default=None,
                        help="Limit number of STL-10 images (for testing)")
    parser.add_argument("--checkpoint-dir", type=str, default="checkpoints")
    parser.add_argument("--data-root", type=str, default="./data")
    parser.add_argument("--device", type=str, default=None)
    parser.add_argument("--patch-w", type=int, default=4, help="Patch width")
    parser.add_argument("--patch-h", type=int, default=4, help="Patch height")
    args = parser.parse_args()

    device = torch.device(
        args.device if args.device
        else "cuda" if torch.cuda.is_available()
        else "cpu"
    )
    print(f"Using device: {device}")

    dataset = PatchDataset(root=args.data_root, max_images=args.max_images,
                           patch_w=args.patch_w, patch_h=args.patch_h)
    loader = DataLoader(
        dataset,
        batch_size=args.batch_size,
        shuffle=True,
        num_workers=4,
        pin_memory=device.type == "cuda",
        persistent_workers=True,
    )

    model = GlyphPredictor(patch_w=args.patch_w, patch_h=args.patch_h).to(device)
    param_count = sum(p.numel() for p in model.parameters())
    print(f"Model parameters: {param_count:,}")

    optimizer = torch.optim.AdamW(
        model.parameters(), lr=args.lr, weight_decay=args.weight_decay
    )
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(
        optimizer, T_max=args.epochs * len(loader)
    )

    os.makedirs(args.checkpoint_dir, exist_ok=True)

    for epoch in range(args.epochs):
        model.train()
        total_loss = 0.0
        num_batches = 0
        t0 = time.time()

        for patches in loader:
            patches = patches.to(device)
            masks = model(patches)
            loss = reconstruction_mse_torch(masks, patches)

            optimizer.zero_grad()
            loss.backward()
            optimizer.step()
            scheduler.step()

            total_loss += loss.item()
            num_batches += 1

        avg_loss = total_loss / num_batches
        elapsed = time.time() - t0
        lr = scheduler.get_last_lr()[0]

        # Monitor mask diversity: mean entropy of predicted masks
        model.eval()
        with torch.no_grad():
            sample = next(iter(loader)).to(device)
            sample_masks = model(sample)
            entropy = -(
                sample_masks * torch.log(sample_masks + 1e-8)
                + (1 - sample_masks) * torch.log(1 - sample_masks + 1e-8)
            ).mean()

        print(
            f"Epoch {epoch+1:3d}/{args.epochs} | "
            f"Loss: {avg_loss:.4f} | "
            f"Entropy: {entropy:.4f} | "
            f"LR: {lr:.2e} | "
            f"Time: {elapsed:.1f}s"
        )

        if (epoch + 1) % 5 == 0 or epoch == args.epochs - 1:
            path = os.path.join(args.checkpoint_dir, f"glyph_predictor_ep{epoch+1}.pt")
            torch.save({
                "epoch": epoch + 1,
                "patch_w": args.patch_w,
                "patch_h": args.patch_h,
                "model_state_dict": model.state_dict(),
                "optimizer_state_dict": optimizer.state_dict(),
                "loss": avg_loss,
            }, path)
            print(f"  Saved checkpoint: {path}")

    print("Training complete.")


if __name__ == "__main__":
    main()
