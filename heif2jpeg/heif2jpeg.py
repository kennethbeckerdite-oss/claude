#!/usr/bin/env python3
"""Convert HEIF photos (.heif/.heic/.hif/.avif) to JPEG.

Originals are never modified or deleted.

Examples:
    python3 heif2jpeg.py photo.heic
    python3 heif2jpeg.py ~/Pictures/iPhone
    python3 heif2jpeg.py ~/Pictures/iPhone -r -o ~/Pictures/converted -q 92
"""

import argparse
import sys
from pathlib import Path

try:
    from PIL import Image, ImageOps
    import pillow_heif
except ImportError:
    sys.exit(
        "Missing image libraries.\n\n"
        "Run the setup script next to this file:\n"
        "    ./setup.sh\n\n"
        "Then use the ./heif2jpeg wrapper instead of calling this file directly,\n"
        "so it picks up the libraries setup.sh installed."
    )

pillow_heif.register_heif_opener()

HEIF_SUFFIXES = {".heif", ".heic", ".hif", ".avif"}


def find_inputs(paths, recursive):
    """Expand the given files/folders into a sorted list of HEIF files."""
    found = []
    for raw in paths:
        p = Path(raw).expanduser()
        if p.is_dir():
            it = p.rglob("*") if recursive else p.glob("*")
            found += [f for f in it if f.is_file() and f.suffix.lower() in HEIF_SUFFIXES]
        elif p.is_file():
            if p.suffix.lower() in HEIF_SUFFIXES:
                found.append(p)
            else:
                print(f"skip (not a HEIF file): {p}")
        else:
            print(f"skip (not found): {p}")
    return sorted(set(found))


def output_path(src, roots, out_dir):
    """Where the JPEG for `src` should go."""
    if out_dir is None:
        return src.with_suffix(".jpg")
    # Mirror the folder structure under whichever input folder contains src.
    for root in roots:
        if root.is_dir():
            try:
                rel = src.relative_to(root)
            except ValueError:
                continue
            return (out_dir / rel).with_suffix(".jpg")
    return (out_dir / src.name).with_suffix(".jpg")


def human_size(num_bytes):
    for unit in ("B", "KB", "MB", "GB"):
        if num_bytes < 1024 or unit == "GB":
            return f"{num_bytes:.0f} {unit}" if unit == "B" else f"{num_bytes:.1f} {unit}"
        num_bytes /= 1024


def convert(src, dst, quality, overwrite):
    if dst.exists() and not overwrite:
        return "skipped", "already exists (use --overwrite to replace)"

    with Image.open(src) as im:
        # Rotate pixels to match the camera's orientation tag, then drop the
        # tag so viewers don't rotate a second time.
        im = ImageOps.exif_transpose(im)

        if im.mode in ("RGBA", "LA", "P"):
            im = im.convert("RGBA")
            flat = Image.new("RGB", im.size, (255, 255, 255))
            flat.paste(im, mask=im.split()[-1])
            im = flat
        elif im.mode != "RGB":
            im = im.convert("RGB")

        save_args = {"quality": quality, "optimize": True, "progressive": True}
        exif = im.info.get("exif")
        if exif:
            save_args["exif"] = exif
        icc = im.info.get("icc_profile")
        if icc:
            save_args["icc_profile"] = icc

        dst.parent.mkdir(parents=True, exist_ok=True)
        im.save(dst, "JPEG", **save_args)

    return "converted", f"{dst}  ({human_size(dst.stat().st_size)})"


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Convert HEIF photos (.heif/.heic/.hif/.avif) to JPEG. "
                    "Originals are left untouched.",
    )
    ap.add_argument("paths", nargs="+", help="HEIF files and/or folders to convert")
    ap.add_argument("-o", "--output", help="folder for the JPEGs (default: next to each original)")
    ap.add_argument("-q", "--quality", type=int, default=92,
                    help="JPEG quality 1-100 (default: 92)")
    ap.add_argument("-r", "--recursive", action="store_true",
                    help="also look inside sub-folders")
    ap.add_argument("--overwrite", action="store_true",
                    help="replace JPEGs that already exist")
    args = ap.parse_args(argv)

    if not 1 <= args.quality <= 100:
        ap.error("--quality must be between 1 and 100")

    out_dir = Path(args.output).expanduser() if args.output else None
    roots = [Path(p).expanduser() for p in args.paths]

    files = find_inputs(args.paths, args.recursive)
    if not files:
        print("No HEIF files found.")
        return 1

    counts = {"converted": 0, "skipped": 0, "failed": 0}
    for src in files:
        dst = output_path(src, roots, out_dir)
        try:
            status, detail = convert(src, dst, args.quality, args.overwrite)
        except Exception as exc:  # keep going through the rest of the batch
            status, detail = "failed", f"{type(exc).__name__}: {exc}"
        counts[status] += 1
        print(f"{status:9} {src.name} -> {detail}")

    print(
        f"\nDone. {counts['converted']} converted, "
        f"{counts['skipped']} skipped, {counts['failed']} failed."
    )
    return 0 if counts["failed"] == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
