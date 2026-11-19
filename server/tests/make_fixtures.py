"""生成测试用的 PNG（渐变图）和 PDF（一页文字）。"""
import sys, zlib, struct, os
out = sys.argv[1]
w, h = 800, 500
rows = b''.join(b'\x00' + b''.join(bytes([x * 255 // w, y * 255 // h, 160]) for x in range(w)) for y in range(h))
def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
open(os.path.join(out, 'loss.png'), 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows, 6)) + chunk(b'IEND', b''))
objs = ["<</Type/Catalog/Pages 2 0 R>>", "<</Type/Pages/Kids[3 0 R]/Count 1>>",
        "<</Type/Page/Parent 2 0 R/MediaBox[0 0 595 842]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>", None,
        "<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>"]
stream = b"BT /F1 24 Tf 72 760 Td (Beacon test report: exp42 val_loss 0.231) Tj ET"
objs[3] = "<</Length %d>>stream\n%s\nendstream" % (len(stream), stream.decode())
pdf = b"%PDF-1.4\n"; offs = []
for i, o in enumerate(objs, 1):
    offs.append(len(pdf)); pdf += b"%d 0 obj\n%s\nendobj\n" % (i, o.encode())
x = len(pdf)
pdf += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1) + b"".join(b"%010d 00000 n \n" % o for o in offs)
pdf += b"trailer<</Size %d/Root 1 0 R>>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, x)
open(os.path.join(out, 'report.pdf'), 'wb').write(pdf)
