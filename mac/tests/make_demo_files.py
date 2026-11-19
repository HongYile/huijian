"""生成演示附件：训练曲线 PNG、混淆矩阵 PNG、PDF 报告、XLSX 表格、ZIP、日志。docx 由 textutil 生成。"""
import os, sys, zipfile, math, random
out = sys.argv[1]; os.makedirs(out, exist_ok=True)
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
plt.rcParams["font.sans-serif"] = ["PingFang SC", "Arial Unicode MS", "DejaVu Sans"]
random.seed(7)
ep = list(range(1, 101))
tr = [1.9 * math.exp(-e / 22) + 0.15 + random.uniform(-0.02, 0.02) for e in ep]
va = [1.95 * math.exp(-e / 25) + 0.19 + random.uniform(-0.03, 0.03) for e in ep]
fig, ax = plt.subplots(figsize=(8, 5), dpi=140)
ax.plot(ep, tr, label="train", color="#5B5BD6", lw=2)
ax.plot(ep, va, label="val", color="#F76B15", lw=2)
ax.axvline(87, color="#8B8D98", ls="--", lw=1); ax.text(88, 1.2, "best @87", color="#5F5F6B")
ax.set_xlabel("epoch"); ax.set_ylabel("loss"); ax.set_title("exp42 ResNet-50 loss"); ax.grid(alpha=.25); ax.legend()
fig.tight_layout(); fig.savefig(os.path.join(out, "loss.png")); plt.close(fig)
fig, ax = plt.subplots(figsize=(5, 5), dpi=140)
m = [[random.randint(0, 9) if i != j else random.randint(80, 99) for j in range(6)] for i in range(6)]
ax.imshow(m, cmap="Purples"); ax.set_title("confusion matrix")
for i in range(6):
    for j in range(6): ax.text(j, i, m[i][j], ha="center", va="center", fontsize=8)
fig.tight_layout(); fig.savefig(os.path.join(out, "confusion.png")); plt.close(fig)
from matplotlib.backends.backend_pdf import PdfPages
with PdfPages(os.path.join(out, "report.pdf")) as pdf:
    fig = plt.figure(figsize=(8.27, 11.69)); fig.text(0.1, 0.92, "exp42 评估报告", fontsize=22, weight="bold")
    fig.text(0.1, 0.88, "best val_loss 0.198 @ epoch 87 · top-1 acc 93.4%", fontsize=12, color="#5F5F6B")
    ax = fig.add_axes([0.1, 0.45, 0.8, 0.38]); ax.plot(ep, tr, color="#5B5BD6"); ax.plot(ep, va, color="#F76B15"); ax.grid(alpha=.25)
    pdf.savefig(fig); plt.close(fig)
# 最小 xlsx
x = os.path.join(out, "metrics.xlsx")
rows = [["epoch", "train_loss", "val_loss", "acc"]] + [[e, round(tr[e-1], 3), round(va[e-1], 3), round(0.6 + e * 0.0034, 3)] for e in range(1, 21)]
def cell(r, c, v):
    ref = "ABCD"[c] + str(r + 1)
    return f'<c r="{ref}" t="inlineStr"><is><t>{v}</t></is></c>' if isinstance(v, str) else f'<c r="{ref}"><v>{v}</v></c>'
sheet = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>' + \
    "".join(f'<row r="{r+1}">' + "".join(cell(r, c, v) for c, v in enumerate(row)) + "</row>" for r, row in enumerate(rows)) + "</sheetData></worksheet>"
with zipfile.ZipFile(x, "w") as z:
    z.writestr("[Content_Types].xml", '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>')
    z.writestr("_rels/.rels", '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>')
    z.writestr("xl/workbook.xml", '<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="metrics" sheetId="1" r:id="rId1"/></sheets></workbook>')
    z.writestr("xl/_rels/workbook.xml.rels", '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>')
    z.writestr("xl/worksheets/sheet1.xml", sheet)
log = "\n".join(f"[2026-11-17 0{e//20}:{e%60:02d}:00] epoch {e:3d} train_loss {tr[e-1]:.4f} val_loss {va[e-1]:.4f}" for e in ep)
open(os.path.join(out, "train.log"), "w").write(log + "\n")
with zipfile.ZipFile(os.path.join(out, "ckpt-exp42.zip"), "w") as z:
    z.writestr("best.pt", os.urandom(300000)); z.writestr("config.yaml", "lr: 3e-4\nbatch: 256\n")
open(os.path.join(out, "周报.txt"), "w").write("本周实验周报\n\n1. exp42 完成，val_loss 0.198\n2. exp43 进行中\n3. 下周计划：消融实验\n")
print("ok")
