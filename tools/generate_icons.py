from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "tools" / "avatar-source.png"
CROP = (165, 50, 1115, 1000)
base = Image.open(SOURCE).convert("RGB").crop(CROP).resize((1024, 1024), Image.Resampling.LANCZOS)

out = ROOT / "WorkshopLedger" / "Assets.xcassets" / "AppIcon.appiconset"
for name, size in {
    "Icon-20.png": 20,
    "Icon-20@2x.png": 40,
    "Icon-29.png": 29,
    "Icon-29@2x.png": 58,
    "Icon-40.png": 40,
    "Icon-40@2x.png": 80,
    "Icon-76.png": 76,
    "Icon-76@2x.png": 152,
    "Icon-83.5@2x.png": 167,
    "Icon-1024.png": 1024,
}.items():
    base.resize((size, size), Image.Resampling.LANCZOS).save(out / name, "PNG", optimize=True)

brand = ROOT / "WorkshopLedger" / "Assets.xcassets" / "BrandAvatar.imageset"
brand.mkdir(parents=True, exist_ok=True)
for scale, size in (("1x", 128), ("2x", 256), ("3x", 384)):
    base.resize((size, size), Image.Resampling.LANCZOS).save(brand / f"BrandAvatar@{scale}.png", "PNG", optimize=True)
print("generated app icon and brand avatar assets")
