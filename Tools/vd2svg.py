"""Android VectorDrawable -> SVG.

`android:pathData` is already SVG path syntax, so this is an attribute mapping
rather than a geometry conversion. Only the cases these files actually use are
handled, and anything else raises rather than silently dropping detail.
"""
import sys, os, json, re
import xml.etree.ElementTree as ET

AND = "{http://schemas.android.com/apk/res/android}"

def a(el, name, default=None):
    return el.get(AND + name, default)

def convert(path):
    tree = ET.parse(path)
    root = tree.getroot()
    if root.tag != "vector":
        raise SystemExit(f"{path}: not a <vector>")

    for el in root.iter():
        if el.tag not in ("vector", "path"):
            raise SystemExit(f"{path}: unhandled element <{el.tag}> — convert by hand")

    vw = a(root, "viewportWidth", "24")
    vh = a(root, "viewportHeight", "24")
    w = (a(root, "width", "24dp") or "24dp").replace("dp", "")
    h = (a(root, "height", "24dp") or "24dp").replace("dp", "")

    fills = set()
    parts = []
    for p in root.findall("path"):
        d = a(p, "pathData")
        if not d:
            continue
        d = " ".join(d.split())
        attrs = [f'd="{d}"']

        fill = a(p, "fillColor")
        if fill and fill.lower() not in ("#00000000", "@android:color/transparent"):
            fills.add(fill.lower())
            attrs.append(f'fill="{fill}"')
        else:
            attrs.append('fill="none"')

        if (fa := a(p, "fillAlpha")):
            attrs.append(f'fill-opacity="{fa}"')

        if (sc := a(p, "strokeColor")) and sc.lower() != "#00000000":
            fills.add(sc.lower())
            attrs.append(f'stroke="{sc}"')
            attrs.append(f'stroke-width="{a(p, "strokeWidth", "1")}"')
            if (cap := a(p, "strokeLineCap")):
                attrs.append(f'stroke-linecap="{cap}"')
            if (join := a(p, "strokeLineJoin")):
                attrs.append(f'stroke-linejoin="{join}"')
            if (sa := a(p, "strokeAlpha")):
                attrs.append(f'stroke-opacity="{sa}"')

        if (ft := a(p, "fillType")):
            attrs.append(f'fill-rule="{"evenodd" if ft == "evenOdd" else "nonzero"}"')

        parts.append("  <path " + " ".join(attrs) + "/>")

    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
           f'viewBox="0 0 {vw} {vh}">\n' + "\n".join(parts) + "\n</svg>\n")
    return svg, fills

if __name__ == "__main__":
    src_dir, out_dir = sys.argv[1], sys.argv[2]
    names = sys.argv[3:]
    for name in names:
        svg, fills = convert(os.path.join(src_dir, name + ".xml"))
        # A single-colour glyph becomes a TEMPLATE image so it can be tinted the way
        # Android tints its Icons. A multi-colour illustration must not be flattened
        # to one colour, so it stays original.
        template = len(fills) <= 1
        iset = os.path.join(out_dir, f"{name}.imageset")
        os.makedirs(iset, exist_ok=True)
        with open(os.path.join(iset, f"{name}.svg"), "w") as fh:
            fh.write(svg)
        contents = {
            "images": [{"filename": f"{name}.svg", "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1},
            "properties": {"preserves-vector-representation": True},
        }
        if template:
            contents["properties"]["template-rendering-intent"] = "template"
        with open(os.path.join(iset, "Contents.json"), "w") as fh:
            json.dump(contents, fh, indent=2)
        print(f"  {name:24} colours={len(fills):2}  {'template' if template else 'ORIGINAL (multicolour)'}")
