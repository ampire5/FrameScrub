#!/usr/bin/env python3
"""Make a separate Lite Max/MSP event preset; never edit Console's database or the keyboard fallback.

The vendor template remains user-supplied (or read from an installed Console); no vendor resources are bundled.
Usage: python3 scripts/make-tourbox-event-preset.py [--source vendor-Max.tb] [--output new-preset.tb]
"""
import argparse
import base64
import gzip
from pathlib import Path
import xml.etree.ElementTree as ET
import zipfile


def generate(source):
    root = ET.fromstring(gzip.decompress(source))
    node = root.find("configBytes")
    if node is None or not node.text:
        raise ValueError("Template has no configBytes")
    data = bytearray(base64.b64decode(node.text, validate=True))
    if len(data) != 22 + 256 * 13:
        raise ValueError("Unsupported template size")
    button = bytes.fromhex("000403e90000000000000000")
    rotation = bytes.fromhex("080403e80000000000000000")
    if data[22 + 2 * 13 + 1:22 + 3 * 13] != button or data[22 + 4 * 13 + 1:22 + 5 * 13] != rotation:
        raise ValueError("Expected the vendor Max/MSP template")
    controls = {0: button, 2: button, 3: button, 4: rotation, 9: rotation,
                10: button, 34: button, 35: button, 42: button, 55: button}
    for record in range(256):
        data[22 + record * 13:22 + (record + 1) * 13] = bytes([record]) + controls.get(record, bytes(12))
    node.text = base64.b64encode(data).decode("ascii")
    name = root.find("presetName")
    if name is None:
        name = ET.SubElement(root, "presetName")
    name.text = "FrameScrub Lite Events"
    shortcuts = root.find("shortCuts")
    if shortcuts is not None:
        shortcuts.clear()
    output = gzip.compress(ET.tostring(root, encoding="utf-8"), mtime=0)
    check = base64.b64decode(ET.fromstring(gzip.decompress(output)).findtext("configBytes"), validate=True)
    if check != data:
        raise ValueError("Preset round-trip failed")
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="An exported vendor Max/MSP Lite .tb template")
    parser.add_argument("--output", type=Path, default=Path("build/FrameScrub-Lite-Events.tb"))
    args = parser.parse_args()
    if args.source:
        source = args.source.read_bytes()
    else:
        archive = Path("/Applications/TourBox Console.app/Contents/Resources/LibTM.dec")
        with zipfile.ZipFile(archive) as vendor:
            matches = [n for n in vendor.namelist() if n.endswith("/lite/Max_MacOS_en.tb")]
            if len(matches) != 1:
                raise ValueError("Could not identify the vendor Lite Max template; use --source")
            source = vendor.read(matches[0])
    output = generate(source)
    if args.source and args.output.resolve() == args.source.resolve():
        raise ValueError("Output must differ from the source template")
    if args.output.exists():
        raise ValueError("Output exists; choose a new --output path")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(output)
    print(args.output.resolve())


if __name__ == "__main__":
    main()
