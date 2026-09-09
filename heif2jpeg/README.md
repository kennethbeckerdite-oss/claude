# heif2jpeg

Converts HEIF photos — the format iPhones shoot by default — into ordinary JPEGs
that anything can open.

Handles `.heif`, `.heic`, `.hif`, and `.avif`.

**Your original photos are never changed, moved, or deleted.** The program only
writes new `.jpg` files.

## One-time setup

You need Python 3 (on a Mac, `python3` is usually already there; on Windows,
install it from [python.org](https://www.python.org/downloads/) and tick
"Add Python to PATH").

Then open Terminal (Mac) or Command Prompt (Windows) and run:

```
python3 -m pip install pillow pillow-heif
```

That's it. You only do this once.

## Using it

Convert one photo — the JPEG lands next to the original:

```
python3 heif2jpeg.py IMG_4021.HEIC
```

Convert a whole folder of photos:

```
python3 heif2jpeg.py ~/Pictures/iPhone
```

Convert a folder *and* everything inside its sub-folders, putting all the JPEGs
somewhere separate:

```
python3 heif2jpeg.py ~/Pictures/iPhone -r -o ~/Pictures/converted
```

**Tip:** you don't have to type file paths. Type `python3 heif2jpeg.py ` (with a
space at the end), then drag the file or folder from Finder/Explorer onto the
terminal window — it fills in the path for you. Press Enter.

## Options

| Option | What it does |
| --- | --- |
| `-o FOLDER`, `--output FOLDER` | Put the JPEGs in this folder instead of beside the originals. Sub-folder structure is preserved. |
| `-q N`, `--quality N` | JPEG quality, 1–100. Default is 92 — visually indistinguishable from the original for most photos. Use 100 for archival, 80 for smaller files. |
| `-r`, `--recursive` | Also look inside sub-folders. |
| `--overwrite` | Replace JPEGs that already exist. Without this, existing files are left alone and reported as "skipped". |

## What it does to your photos

- **Rotation is baked in.** Phones store photos sideways with a "rotate me" tag
  attached. Some programs ignore that tag, which is why photos sometimes show up
  on their side. This program physically rotates the pixels and removes the tag,
  so the JPEG looks right everywhere.
- **Camera info is kept.** Date taken, camera model, exposure settings, and GPS
  location carry over into the JPEG. If you'd rather strip location data before
  sharing, say so and that can be added as an option.
- **Colour profiles are kept**, so colours match the original.
- **Transparency becomes white.** JPEG can't store transparency. This is rare in
  photos and only shows up in graphics.
- **Live Photos and bursts** convert their main still image. The video portion
  and the extra frames are not extracted.

## When something goes wrong

The program keeps going through the rest of the batch and tells you the count at
the end:

```
Done. 47 converted, 2 skipped, 1 failed.
```

- **"skipped"** — a JPEG of that name already existed. Nothing was lost. Re-run
  with `--overwrite` if you want it replaced.
- **"failed"** — that file couldn't be read (corrupt, or not really a HEIF file
  despite its name). The rest still converted.
- **"Missing libraries"** — the setup step above hasn't been run yet.
