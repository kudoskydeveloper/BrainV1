"""Text out of .xlsx/.xlsm and .pptx (Office Open XML), standard library only.
usage: python3 -I office.py <file>"""
import re
import sys
import zipfile
from xml.etree import ElementTree as ET

NS = {"s": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
      "a": "http://schemas.openxmlformats.org/drawingml/2006/main"}


def xlsx(z):
    shared = []
    if "xl/sharedStrings.xml" in z.namelist():
        for si in ET.fromstring(z.read("xl/sharedStrings.xml")).findall("s:si", NS):
            shared.append("".join(t.text or "" for t in si.iter("{%s}t" % NS["s"])))
    wb = ET.fromstring(z.read("xl/workbook.xml"))
    names = [s.get("name") for s in wb.find("s:sheets", NS)]
    sheets = sorted((n for n in z.namelist() if re.match(r"xl/worksheets/sheet\d+\.xml$", n)), key=lambda n: int(re.findall(r"\d+", n)[-1]))
    out = []
    for i, path in enumerate(sheets):
        out.append(f"=== sheet: {names[i] if i < len(names) else path} ===")
        for row in ET.fromstring(z.read(path)).iter("{%s}row" % NS["s"]):
            cells = []
            for c in row.findall("s:c", NS):
                v = c.find("s:v", NS)
                t = c.get("t")
                if t == "s" and v is not None:
                    cells.append(shared[int(v.text)])
                elif t == "inlineStr":
                    cells.append("".join(x.text or "" for x in c.iter("{%s}t" % NS["s"])))
                else:
                    cells.append(v.text if v is not None and v.text else "")
            if any(cells):
                out.append("\t".join(cells))
    return "\n".join(out)


def pptx(z):
    slides = sorted((n for n in z.namelist() if re.match(r"ppt/slides/slide\d+\.xml$", n)), key=lambda n: int(re.findall(r"\d+", n)[-1]))
    out = []
    for i, path in enumerate(slides, 1):
        root = ET.fromstring(z.read(path))
        paras = ["".join(t.text or "" for t in p.iter("{%s}t" % NS["a"])) for p in root.iter("{%s}p" % NS["a"])]
        out.append(f"=== slide {i} ===\n" + "\n".join(p for p in paras if p.strip()))
    return "\n".join(out)


f = sys.argv[1]
with zipfile.ZipFile(f) as z:
    print(pptx(z) if f.lower().endswith(".pptx") else xlsx(z))
