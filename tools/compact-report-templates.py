#!/usr/bin/env python3
"""Recompress existing template JPEGs without changing page geometry or text.

Requires Pillow and pypdf. Usage:
  python3 tools/compact-report-templates.py input.pdf output.pdf
Keep the original as a backup; this command refuses to overwrite its input.
"""
import argparse
from io import BytesIO
from pathlib import Path
from PIL import Image
from pypdf import PdfWriter
from pypdf.generic import NameObject, NumberObject


def compact(source, destination):
    if source.resolve() == destination.resolve():
        raise ValueError('Input and output must be different files')
    writer = PdfWriter(clone_from=str(source))
    count = 0
    for obj in writer._objects:
        if not hasattr(obj, 'get') or obj.get('/Subtype') != '/Image' or obj.get('/Filter') != '/DCTDecode':
            continue
        # Keep image dimensions and separate alpha masks. All vector artwork,
        # text, fonts, annotations and form fields remain untouched.
        image = Image.open(BytesIO(obj._data)).convert('RGB')
        encoded = BytesIO()
        image.save(encoded, format='JPEG', quality=82, optimize=True)
        data = encoded.getvalue()
        if len(data) >= len(obj._data):
            continue
        obj._data = data
        obj[NameObject('/ColorSpace')] = NameObject('/DeviceRGB')
        obj[NameObject('/BitsPerComponent')] = NumberObject(8)
        for key in ['/DecodeParms', '/Decode']:
            if key in obj:
                del obj[key]
        count += 1
    writer.compress_identical_objects()
    writer.write(destination)
    print(f'{source.name}: {source.stat().st_size} -> {destination.stat().st_size} bytes; {count} JPEGs optimized')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    compact(args.source, args.destination)
