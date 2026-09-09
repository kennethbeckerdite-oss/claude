# heif2jpeg

Converts HEIF photos — the format iPhones shoot by default — into ordinary JPEGs
that anything can open.

Handles `.heif`, `.heic`, `.hif`, and `.avif`.

**Your original photos are never changed, moved, or deleted.** The program only
writes new `.jpg` files.

## Setup

You need Python 3. On a Mac it's usually already installed; on Windows, get it
from [python.org](https://www.python.org/downloads/) and tick "Add Python to
PATH" during install.

There is no separate install step. The first time you run the converter it
builds its own private Python environment inside this folder (`.venv/`) and
installs what it needs there.

**This never touches your system Python or Homebrew.** If you tried
`pip install` directly and got `error: externally-managed-environment`, that's
Homebrew's Python blocking system-wide installs on purpose — the private
environment is exactly the workaround it's asking for.

## Using it

Open Terminal and `cd` into this folder first:

```
cd /path/to/heif2jpeg
```

Convert one photo — the JPEG lands next to the original:

```
./heif2jpeg IMG_4021.HEIC
```

Convert a whole folder of photos:

```
./heif2jpeg ~/Pictures/iPhone
```

Convert a folder *and* everything inside its sub-folders, putting all the JPEGs
somewhere separate:

```
./heif2jpeg ~/Pictures/iPhone -r -o ~/Pictures/converted
```

The very first run prints a minute of setup chatter before it starts
converting. Every run after that goes straight to work.

**Tip:** you don't have to type file paths. Type `./heif2jpeg ` (with a space at
the end), then drag the folder from Finder onto the Terminal window — it fills
in the path for you. Press Enter.

**On Windows** there's no `./heif2jpeg` wrapper. Do the setup once with
`python -m venv .venv` then `.venv\Scripts\pip install -r requirements.txt`,
and run it with `.venv\Scripts\python heif2jpeg.py <your folder>`.

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
- **"Missing image libraries"** — you ran `heif2jpeg.py` directly instead of
  the `./heif2jpeg` wrapper. Use the wrapper, or run `./setup.sh` first.
- **`error: externally-managed-environment`** — you ran `pip install` by hand.
  You don't need to; just run `./heif2jpeg`, which handles it.
