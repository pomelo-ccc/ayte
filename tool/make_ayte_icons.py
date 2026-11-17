#!/usr/bin/env python3
"""Generates Ayte's brand icon suite (macOS, Windows .ico, Web, SVG, Extension).

Visual identity (differentiated from Byte's white + Claude-orange icon):
- Deep Midnight Obsidian macOS squircle (#0B1120 -> #070B14) with a subtle
  radial aurora glow and crisp top glass specular rim.
- 4 sculptural 3D capsules in an ascending Antigravity levitation wave
  (peak on bar 3), pairing Luminous Emerald-Mint (#6EE7B7 -> #10B981 -> #047857)
  with Electric Cyan-Indigo (#7DD3FC -> #38BDF8 -> #4F46E5).
"""

from __future__ import annotations

import pathlib
import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = pathlib.Path(__file__).resolve().parent.parent


def _superellipse_mask(size: int, box: tuple[float, float, float, float], radius: float) -> Image.Image:
    """Draws a smooth macOS-style continuous-curvature rounded square mask."""
    im = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(im)
    d.rounded_rectangle(box, radius=radius, fill=255)
    return im


def _capsule_layer(
    canvas_size: int,
    x: float,
    y: float,
    w: float,
    h: float,
    stops: list[tuple[float, tuple[int, int, int]]],
    glow_rgb: tuple[int, int, int],
) -> tuple[Image.Image, Image.Image]:
    """Renders one 3D glossy capsule + its ambient glow layer at canvas_size."""
    mask = Image.new("L", (canvas_size, canvas_size), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle((x, y, x + w, y + h), radius=w / 2.0, fill=255)

    # Build capsule gradient + 3D cylindrical horizontal lighting in numpy
    iy0, iy1 = max(0, int(y) - 2), min(canvas_size, int(y + h) + 3)
    ix0, ix1 = max(0, int(x) - 2), min(canvas_size, int(x + w) + 3)

    ty = np.clip((np.arange(iy0, iy1, dtype=np.float32) - y) / max(h, 1.0), 0.0, 1.0)
    tx = np.clip((np.arange(ix0, ix1, dtype=np.float32) - x) / max(w, 1.0), 0.0, 1.0)

    # Interpolate vertical color stops
    positions = np.array([s[0] for s in stops], dtype=np.float32)
    colors = np.array([s[1] for s in stops], dtype=np.float32)
    r_col = np.interp(ty, positions, colors[:, 0])[:, None]
    g_col = np.interp(ty, positions, colors[:, 1])[:, None]
    b_col = np.interp(ty, positions, colors[:, 2])[:, None]

    # 3D cylindrical horizontal sheen: soft highlight around tx=0.30, deeper edge at tx=0.92
    cyl = 1.0 + 0.16 * np.exp(-((tx - 0.28) ** 2) / 0.045) - 0.18 * (tx ** 2.2)
    # Subtle top-cap dome highlight
    dome = 0.22 * np.exp(-(ty[:, None] / 0.16) ** 2) * np.exp(-((tx[None, :] - 0.42) ** 2) / 0.14)

    rgb = np.stack([r_col * cyl[None, :], g_col * cyl[None, :], b_col * cyl[None, :]], axis=-1)
    rgb = rgb + dome[:, :, None] * 255.0
    rgb = np.clip(rgb, 0, 255).astype(np.uint8)

    body = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    patch = Image.fromarray(rgb, mode="RGB")
    patch_rgba = patch.convert("RGBA")
    sub_mask = mask.crop((ix0, iy0, ix1, iy1))
    patch_rgba.putalpha(sub_mask)
    body.paste(patch_rgba, (ix0, iy0))

    # Crisp inner glass rim along capsule edge (brightest at top)
    rim = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    rd = ImageDraw.Draw(rim)
    stroke_w = max(2, round(canvas_size * 0.0022))
    rd.rounded_rectangle(
        (x + stroke_w * 0.5, y + stroke_w * 0.5, x + w - stroke_w * 0.5, y + h - stroke_w * 0.5),
        radius=max(1.0, (w - stroke_w) / 2.0),
        outline=(255, 255, 255, 150),
        width=stroke_w,
    )
    # Fade rim alpha from top (1.0) to bottom (0.18)
    rim_arr = np.array(rim)
    rim_ty = np.clip((np.arange(canvas_size, dtype=np.float32) - y) / max(h, 1.0), 0.0, 1.0)
    rim_fade = (1.0 - 0.82 * (rim_ty ** 0.85))[:, None]
    rim_arr[:, :, 3] = np.clip(rim_arr[:, :, 3].astype(np.float32) * rim_fade, 0, 255).astype(np.uint8)
    rim = Image.fromarray(rim_arr, mode="RGBA")
    body = Image.alpha_composite(body, rim)

    # Ambient under-glow + neon bloom
    glow = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.rounded_rectangle(
        (x - w * 0.06, y + h * 0.03, x + w * 1.06, y + h * 1.04),
        radius=w * 0.56,
        fill=(*glow_rgb, 115),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(radius=canvas_size * 0.022))
    return glow, body


def render_macos_icon(target_size: int = 1024) -> Image.Image:
    """Renders the 1024x1024 macOS squircle icon with supersampling."""
    S = 2048  # 2x supersample over 1024
    scale = S / 1024.0

    # Exact Apple macOS squircle bounds: 824x824 centered inside 1024x1024
    pad = 100.0 * scale
    sq_w = 824.0 * scale
    box = (pad, pad, pad + sq_w - 1, pad + sq_w - 1)
    radius = 185.0 * scale

    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # 1. Soft macOS drop shadow (ambient + key shadow)
    shadow1 = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd1 = ImageDraw.Draw(shadow1)
    sd1.rounded_rectangle(
        (pad, pad + 26 * scale, pad + sq_w - 1, pad + sq_w - 1 + 26 * scale),
        radius=radius,
        fill=(4, 8, 20, 125),
    )
    shadow1 = shadow1.filter(ImageFilter.GaussianBlur(radius=28 * scale))

    shadow2 = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd2 = ImageDraw.Draw(shadow2)
    sd2.rounded_rectangle(
        (pad, pad + 10 * scale, pad + sq_w - 1, pad + sq_w - 1 + 10 * scale),
        radius=radius,
        fill=(4, 8, 20, 75),
    )
    shadow2 = shadow2.filter(ImageFilter.GaussianBlur(radius=10 * scale))

    canvas = Image.alpha_composite(canvas, shadow1)
    canvas = Image.alpha_composite(canvas, shadow2)

    # 2. Deep Midnight Obsidian Squircle Surface with subtle radial aurora
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
    ny = np.clip((yy - pad) / sq_w, 0.0, 1.0)
    nx = np.clip((xx - pad) / sq_w, 0.0, 1.0)

    # Vertical base gradient: #121B33 (top) -> #0A0F1E (mid) -> #060913 (bottom)
    bg_r = 18.0 * (1.0 - ny) + 6.0 * ny
    bg_g = 27.0 * (1.0 - ny) + 10.0 * ny
    bg_b = 51.0 * (1.0 - ny) + 20.0 * ny

    # Subtle radial aurora behind the bars (emerald-cyan & indigo atmospheric lift)
    d_emerald = np.exp(-(((nx - 0.56) ** 2) / 0.11 + ((ny - 0.44) ** 2) / 0.13))
    d_indigo = np.exp(-(((nx - 0.36) ** 2) / 0.13 + ((ny - 0.58) ** 2) / 0.14))
    bg_r += 8.0 * d_emerald + 18.0 * d_indigo
    bg_g += 38.0 * d_emerald + 20.0 * d_indigo
    bg_b += 42.0 * d_emerald + 52.0 * d_indigo

    bg_rgb = np.clip(np.stack([bg_r, bg_g, bg_b], axis=-1), 0, 255).astype(np.uint8)
    sq_mask = _superellipse_mask(S, box, radius)
    bg_im = Image.fromarray(bg_rgb, mode="RGB").convert("RGBA")
    bg_im.putalpha(sq_mask)

    # 3. Four 3D glossy capsules (Antigravity ascending levitation rhythm, peak on bar 3)
    # Coordinates in 1024-space:
    bars_1024 = [
        # (x, y, w, h, stops, glow_rgb)
        (
            298.0,
            452.0,
            64.0,
            196.0,
            [(0.0, (125, 211, 252)), (0.48, (56, 189, 248)), (1.0, (67, 56, 202))],
            (56, 189, 248),
        ),
        (
            414.0,
            364.0,
            64.0,
            304.0,
            [(0.0, (103, 232, 249)), (0.45, (14, 165, 233)), (1.0, (55, 48, 163))],
            (14, 165, 233),
        ),
        (
            530.0,
            246.0,
            68.0,
            468.0,
            [
                (0.0, (167, 243, 208)),
                (0.28, (52, 211, 153)),
                (0.68, (16, 185, 129)),
                (1.0, (4, 120, 87)),
            ],
            (16, 185, 129),
        ),
        (
            650.0,
            318.0,
            64.0,
            364.0,
            [(0.0, (125, 211, 252)), (0.50, (59, 130, 246)), (1.0, (79, 70, 229))],
            (99, 102, 241),
        ),
    ]

    glow_acc = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bodies = []
    for bx, by, bw, bh, stops, glow_rgb in bars_1024:
        glow, body = _capsule_layer(
            S,
            bx * scale,
            by * scale,
            bw * scale,
            bh * scale,
            stops,
            glow_rgb,
        )
        glow_acc = Image.alpha_composite(glow_acc, glow)
        bodies.append(body)

    # Clip internal glow strictly inside squircle
    glow_arr = np.array(glow_acc)
    sq_alpha = np.array(sq_mask, dtype=np.float32) / 255.0
    glow_arr[:, :, 3] = np.clip(glow_arr[:, :, 3].astype(np.float32) * sq_alpha, 0, 255).astype(np.uint8)
    bg_im = Image.alpha_composite(bg_im, Image.fromarray(glow_arr, mode="RGBA"))

    for body in bodies:
        bg_im = Image.alpha_composite(bg_im, body)

    # 4. Crisp outer squircle specular rim (bright top glass bevel, subtle bottom edge)
    bevel = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bd = ImageDraw.Draw(bevel)
    bw_px = max(2, round(2.2 * scale))
    bd.rounded_rectangle(
        (pad + bw_px * 0.5, pad + bw_px * 0.5, pad + sq_w - 1 - bw_px * 0.5, pad + sq_w - 1 - bw_px * 0.5),
        radius=radius - bw_px * 0.5,
        outline=(210, 235, 255, 110),
        width=bw_px,
    )
    bevel_arr = np.array(bevel)
    rim_weight = (0.95 * np.exp(-((ny / 0.35) ** 1.6)) + 0.18)
    bevel_arr[:, :, 3] = np.clip(bevel_arr[:, :, 3].astype(np.float32) * rim_weight, 0, 255).astype(np.uint8)
    bevel_arr[:, :, 3] = np.minimum(bevel_arr[:, :, 3], np.array(sq_mask))
    bg_im = Image.alpha_composite(bg_im, Image.fromarray(bevel_arr, mode="RGBA"))

    canvas = Image.alpha_composite(canvas, bg_im)
    if target_size != S:
        return canvas.resize((target_size, target_size), Image.LANCZOS)
    return canvas


def render_full_bleed_icon(size: int) -> Image.Image:
    """Full-bleed rounded icon for Windows/Web/Browser Extension."""
    base = render_macos_icon(1024)
    # Crop tight around the 824x824 squircle (96..928) so small favicons/tray icons fill nicely
    cropped = base.crop((96, 96, 928, 928))
    return cropped.resize((size, size), Image.LANCZOS)


SVG_LOGO = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="286 234 444 530" fill="none">
  <defs>
    <linearGradient id="bar1" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#7DD3FC" />
      <stop offset="48%" stop-color="#38BDF8" />
      <stop offset="100%" stop-color="#4338CA" />
    </linearGradient>
    <linearGradient id="bar2" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#67E8F9" />
      <stop offset="45%" stop-color="#0EA5E9" />
      <stop offset="100%" stop-color="#3730A3" />
    </linearGradient>
    <linearGradient id="bar3" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#A7F3D0" />
      <stop offset="28%" stop-color="#34D399" />
      <stop offset="68%" stop-color="#10B981" />
      <stop offset="100%" stop-color="#047857" />
    </linearGradient>
    <linearGradient id="bar4" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#7DD3FC" />
      <stop offset="50%" stop-color="#3B82F6" />
      <stop offset="100%" stop-color="#4F46E5" />
    </linearGradient>
  </defs>
  <rect x="298" y="452" width="64" height="196" rx="32" fill="url(#bar1)" />
  <rect x="414" y="364" width="64" height="304" rx="32" fill="url(#bar2)" />
  <rect x="530" y="246" width="68" height="468" rx="34" fill="url(#bar3)" />
  <rect x="650" y="318" width="64" height="364" rx="32" fill="url(#bar4)" />
</svg>
"""


def main() -> None:
    master = render_macos_icon(1024)

    # 1. Branding assets
    branding = ROOT / "assets/branding"
    master.save(branding / "app_icon.png", optimize=True)
    (branding / "logo.svg").write_text(SVG_LOGO, encoding="utf-8")

    # 2. macOS AppIcon.appiconset & AppIcon-Dev.appiconset
    for appicon_dir in [
        ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset",
        ROOT / "macos/Runner/Assets.xcassets/AppIcon-Dev.appiconset",
    ]:
        if not appicon_dir.exists():
            continue
        for s in (16, 32, 64, 128, 256, 512, 1024):
            resized = master if s == 1024 else master.resize((s, s), Image.LANCZOS)
            target = appicon_dir / f"app_icon_{s}.png"
            if target.exists() or appicon_dir.name == "AppIcon.appiconset":
                resized.save(target, optimize=True)

    # 3. Web icons & favicon
    full_512 = render_full_bleed_icon(512)
    full_192 = render_full_bleed_icon(192)
    full_32 = render_full_bleed_icon(32)
    if (ROOT / "web").exists():
        full_32.save(ROOT / "web/favicon.png", optimize=True)
        full_192.save(ROOT / "web/icons/Icon-192.png", optimize=True)
        full_512.save(ROOT / "web/icons/Icon-512.png", optimize=True)
        full_192.save(ROOT / "web/icons/Icon-maskable-192.png", optimize=True)
        full_512.save(ROOT / "web/icons/Icon-maskable-512.png", optimize=True)

    # 4. Browser extension icons
    ext_icons = ROOT / "browser_extension/icons"
    if ext_icons.exists():
        for s in (16, 32, 48):
            render_full_bleed_icon(s).save(ext_icons / f"icon-{s}.png", optimize=True)
        framed = Image.new("RGBA", (128, 128), (0, 0, 0, 0))
        framed.alpha_composite(render_full_bleed_icon(96), (16, 16))
        framed.save(ext_icons / "icon-128.png", optimize=True)

    # 5. Windows .ico
    win_res = ROOT / "windows/runner/resources"
    if win_res.exists():
        ico_base = render_full_bleed_icon(256)
        for ico_name in ("app_icon.ico", "app_icon_dev.ico"):
            if (win_res / ico_name).exists():
                ico_base.save(
                    win_res / ico_name,
                    format="ICO",
                    sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
                )

    print("✓ Generated all Ayte brand icon assets.")


if __name__ == "__main__":
    main()
