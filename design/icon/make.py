# 回笺图标矢量定稿：主送达（实心箭头飞入信封）+ 可回复（虚线回程）
# 用法：python3 design/icon/make.py  → 生成 huijian-*.svg 并写入各端图标（需要 rsvg-convert、ImageMagick、iconutil）
import math, os, shutil, subprocess, sys

THEMES = {
    "light": dict(bg="#F4F1EA", env="#4A63B5", line="#2B2924", flap="#F4F1EA", arrow="#4A63B5", spark="#D44C3D", dash="#2B2924"),
    "dark": dict(bg="#1A1917", env="#5B74C9", line="#EBE6DC", flap="#1A1917", arrow="#8EA2EC", spark="#E06A5A", dash="#ABA497"),
}


def arrowhead(tip, d, length, half):
    dx, dy = d
    n = math.hypot(dx, dy)
    dx, dy = dx / n, dy / n
    px, py = -dy, dx
    bx, by = tip[0] - dx * length, tip[1] - dy * length
    return (f"M {tip[0]:.1f} {tip[1]:.1f} L {bx + px * half:.1f} {by + py * half:.1f} "
            f"L {bx - px * half:.1f} {by - py * half:.1f} Z"), (bx, by), (px, py)


def content(c, simple=False, mono=None):
    """图形本体（1024 坐标系，不含底色）。simple=小尺寸简化版；mono=单色剪影颜色。"""
    col = (lambda k: mono) if mono else (lambda k: c[k])
    d = (0.55, 0.835)
    tip = (660, 420)
    head, (bx, by), (px, py) = arrowhead(tip, d, 104, 54)
    w = 29
    a, b = (bx + px * w, by + py * w), (bx - px * w, by - py * w)
    po, pi = (a, b) if a[1] < b[1] else (b, a)
    oc = (po[0] - d[0] * 230, po[1] - d[1] * 230)  # 末端切线与箭头方向一致，避免折角
    ic = (pi[0] - d[0] * 190, pi[1] - d[1] * 190)
    shaft = (f"M 118 566 C 130 330, {oc[0]:.1f} {oc[1]:.1f}, {po[0]:.1f} {po[1]:.1f} "
             f"L {pi[0]:.1f} {pi[1]:.1f} C {ic[0]:.1f} {ic[1]:.1f}, 190 360, 118 566 Z")
    out = []
    if not simple:
        dhead, _, _ = arrowhead((180, 698), (-0.70, -0.72), 46, 27)
        out.append(f'<path d="M 560 742 C 450 830, 290 810, 206 724" fill="none" stroke="{col("dash")}" '
                   f'stroke-width="13" stroke-linecap="round" stroke-dasharray="28 26"/>')
        out.append(f'<path d="{dhead}" fill="{col("dash")}" stroke="{col("dash")}" stroke-width="8" stroke-linejoin="round"/>')
    if mono:
        # 单色剪影：信封实心，封口线挖空（用 mask），箭头头部与信封之间留缝
        out.append('<mask id="m"><rect width="1024" height="1024" fill="#fff"/>'
                   '<polyline points="500,446 686,572 872,446" fill="none" stroke="#000" stroke-width="30" '
                   'stroke-linecap="round" stroke-linejoin="round"/>'
                   f'<path d="{head}" fill="#000" stroke="#000" stroke-width="40" stroke-linejoin="round"/></mask>')
        out.append(f'<rect x="463" y="391" width="446" height="330" rx="58" fill="{mono}" mask="url(#m)"/>')
        out.append(f'<path d="{shaft}" fill="{mono}"/><path d="{head}" fill="{mono}"/>')
    else:
        out.append(f'<rect x="476" y="404" width="420" height="304" rx="46" fill="{col("env")}" stroke="{col("line")}" stroke-width="26"/>')
        out.append(f'<polyline points="500,446 686,572 872,446" fill="none" stroke="{col("flap")}" stroke-width="30" '
                   'stroke-linecap="round" stroke-linejoin="round"/>')
        out.append(f'<path d="{shaft}" fill="{col("arrow")}"/>')
        out.append(f'<path d="{head}" fill="{col("arrow")}" stroke="{c["bg"]}" stroke-width="14" '
                   'stroke-linejoin="round" paint-order="stroke"/>')
    for (x1, y1, x2, y2) in [(812, 352, 784, 306), (862, 334, 862, 272), (912, 352, 940, 306)]:
        out.append(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{col("spark")}" stroke-width="26" stroke-linecap="round"/>')
    return "\n".join(out)


# 图形外接框中心约 (534, 507)；居中后按比例缩放
CX, CY = 534, 507


def svg(theme="light", frame="full", scale=1.0, simple=False, mono=None):
    """frame: full=满版方形底色；none=透明底；mac=macOS 圆角方块 + 投影。"""
    c = THEMES[theme]
    if simple:
        scale *= 1.12
        cy = 470  # 去掉虚线后图形重心上移
    else:
        cy = CY
    g = f'<g transform="translate(512 512) scale({scale:.4f}) translate({-CX} {-cy})">{content(c, simple, mono)}</g>'
    head = '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
    if frame == "full":
        return f'{head}<rect width="1024" height="1024" fill="{c["bg"]}"/>{g}</svg>'
    if frame == "none":
        return f"{head}{g}</svg>"
    # macOS：824×824 圆角方块（Apple 网格），轻投影，图形缩进方块内
    s = 824 / 1024
    g = f'<g transform="translate(512 512) scale({scale * s:.4f}) translate({-CX} {-cy})">{content(c, simple, mono)}</g>'
    return (f'{head}<defs><filter id="sh" x="-20%" y="-20%" width="140%" height="140%">'
            '<feDropShadow dx="0" dy="10" stdDeviation="14" flood-color="#3C301E" flood-opacity="0.28"/></filter></defs>'
            f'<rect x="100" y="100" width="824" height="824" rx="185" fill="{c["bg"]}" filter="url(#sh)"/>{g}</svg>')


def render(svg_text, path, px):
    tmp = path + ".svg"
    open(tmp, "w").write(svg_text)
    subprocess.run(["rsvg-convert", "-w", str(px), "-h", str(px), tmp, "-o", path], check=True)
    os.remove(tmp)


def main():
    """在仓库根目录的 design/icon 下运行：生成 SVG 源文件并把各端图标写到各自位置。"""
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    here = os.path.dirname(os.path.abspath(__file__))
    for t in THEMES:
        open(f"{here}/huijian-{t}.svg", "w").write(svg(t))
        open(f"{here}/huijian-{t}-small.svg", "w").write(svg(t, simple=True))
    tmp = os.path.join(here, "build")
    os.makedirs(tmp, exist_ok=True)

    # macOS .icns（≤32px 用简化版）
    iconset = f"{tmp}/AppIcon.iconset"
    os.makedirs(iconset, exist_ok=True)
    for base in (16, 32, 128, 256, 512):
        for mult in (1, 2):
            px = base * mult
            name = f"icon_{base}x{base}{'@2x' if mult == 2 else ''}.png"
            render(svg("light", "mac", simple=px <= 32), f"{iconset}/{name}", px)
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", f"{root}/mac/Resources/AppIcon.icns"], check=True)

    # iOS：1024 满版不透明（浅色 + 深色）
    render(svg("light"), f"{root}/ios/Resources/AppIcon.png", 1024)
    render(svg("dark"), f"{root}/ios/Resources/AppIcon-dark.png", 1024)
    for p in ("AppIcon.png", "AppIcon-dark.png"):
        subprocess.run(["magick", f"{root}/ios/Resources/{p}", "-alpha", "off", f"{root}/ios/Resources/{p}"], check=True)

    # Android：方形 ic_launcher + 自适应前景（安全区 66/108）+ 主题单色 + 通知栏白色剪影
    res = f"{root}/android/app/src/main/res"
    dens = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
    for dn, k in dens.items():
        d = f"{res}/mipmap-{dn}"
        os.makedirs(d, exist_ok=True)
        render(svg("light", simple=48 * k <= 72), f"{d}/ic_launcher.png", int(48 * k))
        render(svg("light", "none", scale=0.66), f"{d}/ic_launcher_foreground.png", int(108 * k))
        render(svg("light", "none", scale=0.66, mono="#000000"), f"{d}/ic_launcher_monochrome.png", int(108 * k))
        d = f"{res}/drawable-{dn}"
        os.makedirs(d, exist_ok=True)
        render(svg("light", "none", scale=1.05, simple=True, mono="#FFFFFF"), f"{d}/ic_stat_huijian.png", int(24 * k))
    os.makedirs(f"{res}/mipmap-anydpi-v26", exist_ok=True)
    open(f"{res}/mipmap-anydpi-v26/ic_launcher.xml", "w").write(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background" />\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
        '    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />\n'
        '</adaptive-icon>\n')
    open(f"{res}/values/ic_launcher_background.xml", "w").write(
        '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
        f'    <color name="ic_launcher_background">{THEMES["light"]["bg"]}</color>\n</resources>\n')

    # 服务端网页：favicon 64（简化版）、apple-touch-icon 180
    render(svg("light", simple=True), f"{root}/server/favicon.png", 64)
    render(svg("light"), f"{root}/server/apple-touch-icon.png", 180)

    # Windows .ico（16–256），给 Windows 客户端用：python3 make.py --ico <输出路径>
    if "--ico" in sys.argv:
        out = sys.argv[sys.argv.index("--ico") + 1]
        pngs = []
        for px in (16, 24, 32, 48, 64, 128, 256):
            p = f"{tmp}/{px}.png"
            render(svg("light", simple=px <= 32), p, px)
            pngs.append(p)
        subprocess.run(["magick", *pngs, out], check=True)
    shutil.rmtree(tmp)


if __name__ == "__main__":
    main()
