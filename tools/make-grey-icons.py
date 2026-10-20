"""Makes the greyed-out ability icons the Icon display shows while on cooldown.

The plugin API can tint sprites but not desaturate them, so the grey icons are
generated here from the game's own sprites and shipped in resources/grey_icons.

  1. Load the plugin in game once. GameData/ability-catalogue.lua saves the
     abilities' icon sprite ids to the client's plugin database
     (PersistentDB key "abilityIconIDs").
  2. Run:  python tools/make-grey-icons.py
     It reads those ids, decodes each sprite from the local game cache, and
     writes resources/grey_icons/icon_<id>.png in greyscale (alpha kept).
     Or pass sprite ids to convert just those: python tools/make-grey-icons.py 14219
  3. Deploy (deploy.ps1 copies resources/) and reload the plugin.

Only reads the game files. Standard library only.
"""

import bz2
import re
import sqlite3
import struct
import sys
import zlib
from pathlib import Path

GAME_FOLDER = Path(r"C:\ProgramData\Jagex\RuneScape-BETA")
SPRITE_CACHE = GAME_FOLDER / "js5-8.jcache"
PLUGIN_DATABASE = GAME_FOLDER / "plugins" / "PluginData.db"
ICON_IDS_KEY = "abilityIconIDs"
OUTPUT_FOLDER = Path(__file__).resolve().parent.parent / "resources" / "grey_icons"


def open_read_only(path):
    return sqlite3.connect(f"file:{path.as_posix()}?mode=ro", uri=True)


def saved_icon_ids():
    """The sprite ids the plugin saved, or an empty list."""
    with open_read_only(PLUGIN_DATABASE) as database:
        row = database.execute(
            "SELECT Value FROM DataStore WHERE Key = ? LIMIT 1", (ICON_IDS_KEY,)
        ).fetchone()
    if row is None:
        return []
    value = row[0]
    text = value.decode("utf-8", "replace") if isinstance(value, bytes) else str(value)
    return sorted({int(number) for number in re.findall(r"\d+", text)})


def unpack_container(data):
    """Unwraps a js5 container: a compression byte, lengths, then the payload."""
    compression = data[0]
    length = struct.unpack(">I", data[1:5])[0]
    if compression == 0:
        return data[5:5 + length]
    payload = data[9:9 + length]
    if compression == 1:
        # Jagex strips the "BZh1" header from bzip2 streams.
        return bz2.decompress(b"BZh1" + payload)
    if compression == 2:
        return zlib.decompress(payload, 16 + zlib.MAX_WBITS)
    raise ValueError(f"unsupported compression type {compression}")


def decode_true_colour(raw):
    """Decodes the newer sprite format into (width, height, RGBA pixels).

    A type byte (0: 24-bit RGB), a flags byte (2: an alpha plane follows),
    width and height (u16 each), the RGB pixels row by row, then the alpha
    plane if any. The trailing u16 is the frame count with its top bit set.
    """
    kind, flags = raw[0], raw[1]
    if kind != 0:
        raise ValueError(f"unsupported true-colour sprite type {kind}")
    width, height = struct.unpack(">HH", raw[2:6])
    count = width * height
    rgb = raw[6:6 + count * 3]
    if len(rgb) != count * 3:
        raise ValueError("true-colour sprite is shorter than its size")
    if flags & 2:
        alphas = raw[6 + count * 3:6 + count * 4]
        if len(alphas) != count:
            raise ValueError("true-colour sprite is missing its alpha plane")
    else:
        alphas = bytes([255]) * count
    pixels = [(rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2], alphas[i]) for i in range(count)]
    return width, height, pixels


def decode_first_frame(raw):
    """Decodes frame 0 of a palette sprite into (width, height, RGBA pixels).

    Layout, read from the end: frame count (u16); before it per-frame
    offsets and sizes, max width/height and the palette size; before that the
    palette (index 0 is transparent). Pixel data starts at byte 0: per frame a
    flags byte (1 = column-major, 2 = has an alpha plane), the palette
    indices, then the alpha plane if any.
    """
    count = struct.unpack(">H", raw[-2:])[0]
    if count & 0x8000:
        return decode_true_colour(raw)
    header = len(raw) - 7 - count * 8
    palette_size = raw[header + 4] + 1
    sizes = header + 5 + count * 4
    widths = struct.unpack(f">{count}H", raw[sizes:sizes + 2 * count])
    heights = struct.unpack(f">{count}H", raw[sizes + 2 * count:sizes + 4 * count])
    palette_start = header - (palette_size - 1) * 3
    palette = [(0, 0, 0)] + [
        tuple(raw[palette_start + i * 3:palette_start + i * 3 + 3])
        for i in range(palette_size - 1)
    ]

    width, height = widths[0], heights[0]
    flags = raw[0]
    position = 1

    def read_plane():
        nonlocal position
        plane = [0] * (width * height)
        if flags & 1:
            for x in range(width):
                for y in range(height):
                    plane[x + y * width] = raw[position]
                    position += 1
        else:
            plane[:] = raw[position:position + width * height]
            position += width * height
        return plane

    indexes = read_plane()
    alphas = read_plane() if flags & 2 else [255 if index else 0 for index in indexes]
    pixels = [palette[index] + (alphas[i],) for i, index in enumerate(indexes)]
    return width, height, pixels


def greyscale(pixels):
    """Rec. 601 luma, keeping alpha."""
    return [
        (round(0.299 * r + 0.587 * g + 0.114 * b),) * 3 + (a,)
        for r, g, b, a in pixels
    ]


def write_png(path, width, height, pixels):
    rows = b"".join(
        b"\x00" + bytes(channel for pixel in pixels[y * width:(y + 1) * width] for channel in pixel)
        for y in range(height)
    )

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(rows, 9))
        + chunk(b"IEND", b"")
    )


def main(arguments):
    ids = [int(argument) for argument in arguments] or saved_icon_ids()
    if not ids:
        print(f"No icon ids found. Load the plugin in game first (it saves them as "
              f"'{ICON_IDS_KEY}' in {PLUGIN_DATABASE}), or pass sprite ids.")
        return 1

    OUTPUT_FOLDER.mkdir(parents=True, exist_ok=True)
    written, skipped = 0, []
    with open_read_only(SPRITE_CACHE) as cache:
        for sprite_id in ids:
            row = cache.execute("SELECT DATA FROM cache WHERE KEY = ?", (sprite_id,)).fetchone()
            if row is None:
                skipped.append((sprite_id, "not in the sprite cache"))
                continue
            try:
                width, height, pixels = decode_first_frame(unpack_container(row[0]))
            except (ValueError, IndexError, struct.error, OSError, zlib.error) as error:
                skipped.append((sprite_id, str(error)))
                continue
            write_png(OUTPUT_FOLDER / f"icon_{sprite_id}.png", width, height, greyscale(pixels))
            written += 1

    print(f"Wrote {written} grey icon(s) to {OUTPUT_FOLDER}")
    for sprite_id, reason in skipped:
        print(f"  skipped {sprite_id}: {reason}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
