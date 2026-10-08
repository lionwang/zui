#!/usr/bin/env node
// Generates icon.ico: a WeChat-style badge (green rounded square, white
// speech bubble with a tail and two eyes) at 16, 32 and 48 px.
//
//   node examples/wechat/assets/make_icon.mjs
//
// The .ico embeds 32 bpp DIBs (bottom-up BGRA + a 1 bpp AND mask), which
// LoadImageW accepts for the title bar, Alt+Tab and the taskbar - the
// Windows stand-ins for the app and dock icons.
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const outPath = join(here, "icon.ico");

const SIZES = [16, 32, 48];

// Brand colors.
const green = [0x07, 0xC1, 0x60];
const bubble = [0xFF, 0xFF, 0xFF];
const eye = [0x07, 0xC1, 0x60];

function canvas(size) {
  return { size, px: new Uint8ClampedArray(size * size * 4) };
}

function blend(c, x, y, r, g, b, a) {
  const i = (y * c.size + x) * 4;
  const t = a / 255;
  c.px[i + 0] = b * t + c.px[i + 0] * (1 - t);
  c.px[i + 1] = g * t + c.px[i + 1] * (1 - t);
  c.px[i + 2] = r * t + c.px[i + 2] * (1 - t);
  c.px[i + 3] = Math.max(c.px[i + 3], a);
}

// Design coordinates live on a 48x48 unit grid and scale to the target size;
// supersampling with 4x4 subpixels keeps the small sizes crisp.
const UNITS = 48;
const SUB = 4;


function roundedSquare(u, v, r) {
  const dx = Math.min(u - r, UNITS - r - u);
  const dy = Math.min(v - r, UNITS - r - v);
  if (dx < 0 || dy < 0) return true; // covers the corners' outer area
  return dx * dx + dy * dy <= r * r;
}

function circle(u, v, cx, cy, r) {
  const dx = u - cx, dy = v - cy;
  return dx * dx + dy * dy <= r * r;
}

function bubbleBody(u, v) {
  // Rounded body, then a tail cut out of the bottom-left corner.
  const cx = UNITS / 2, cy = UNITS / 2 - 1.5;
  const rx = 11, ry = 9.5;
  const dx = (u - cx) / rx, dy = (v - cy) / ry;
  if (dx * dx + dy * dy > 1) return false;
  // Tail: a triangle hanging from the lower left of the bubble.
  const inTail = u < 22 && v > 27 && (v - 27) * 5 >= (21 - u) * 8;
  return !inTail || dx * dx + dy * dy <= 0.86;
}

const eyes = (u, v) => circle(u, v, 19, 22, 2.0) || circle(u, v, 29, 22, 2.0);

// The 48px design: background to the edge (it is what Windows shows in the
// taskbar / Alt+Tab), white bubble, two green eyes.
function design48(u, v) {
  if (roundedSquare(u, v, 9)) {
    return { color: green, hit: true };
  }
  if (bubbleBody(u, v)) {
    if (eyes(u, v)) return { color: eye, hit: true };
    return { color: bubble, hit: true };
  }
  return { color: [0, 0, 0], hit: false };
}

// Scaled: shrink the whole badge slightly (0.92) and keep the proportions.
function scaledDesign(u, v) {
  const m = UNITS * 0.04; // margin so the rounded corners stay visible
  const s = (UNITS - 2 * m) / UNITS;
  const su = (u - UNITS / 2) / s + UNITS / 2;
  const sv = (v - UNITS / 2) / s + UNITS / 2;
  if (su < 0 || su > UNITS || sv < 0 || sv > UNITS) return { color: [0, 0, 0], hit: false };
  return design48(su, sv);
}

// Paint each pixel: average the design's color over subpixels (the per-point
// design returns { color, hit }).
function render(size) {
  const c = canvas(size);
  const step = UNITS / size;
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      let r = 0, g = 0, b = 0, a = 0;
      for (let sy = 0; sy < SUB; sy++) {
        for (let sx = 0; sx < SUB; sx++) {
          const u = (x + (sx + 0.5) / SUB) * step;
          const v = (y + (sy + 0.5) / SUB) * step;
          const d = scaledDesign(u, v);
          if (d.hit) {
            r += d.color[0]; g += d.color[1]; b += d.color[2]; a += 255;
          }
        }
      }
      const n = SUB * SUB;
      const i = (y * size + x) * 4;
      c.px[i + 0] = b / n;
      c.px[i + 1] = g / n;
      c.px[i + 2] = r / n;
      c.px[i + 3] = a / n;
    }
  }
  return c;
}

// --- ICO container ---------------------------------------------------------

function u16(n) { const b = Buffer.alloc(2); b.writeUInt16LE(n); return b; }
function u32(n) { const b = Buffer.alloc(4); b.writeUInt32LE(n); return b; }

function dib(c) {
  const { size } = c;
  const header = Buffer.concat([
    u32(40),            // BITMAPINFOHEADER size
    u32(size),          // width
    u32(size * 2),      // height doubled: pixels + AND mask
    u16(1),             // planes
    u16(32),            // bits per pixel
    u32(0),             // BI_RGB
    // sizeImage below (pixel data + mask, mask rows padded to 4 bytes)
    u32(size * size * 4 + Math.ceil(size / 32) * 4 * size),
    u32(0), u32(0), u32(0), u32(0),
  ]);
  // Bottom-up BGRA rows.
  const rows = [];
  const maskBytesPerRow = Math.ceil(size / 8 / 4) * 4;
  for (let y = size - 1; y >= 0; y--) {
    const row = Buffer.alloc(size * 4);
    for (let x = 0; x < size; x++) {
      const s = (y * size + x) * 4; // source is top-down BGRA
      const d = x * 4;
      row[d + 0] = c.px[s + 0]; // B
      row[d + 1] = c.px[s + 1]; // G
      row[d + 2] = c.px[s + 2]; // R
      row[d + 3] = c.px[s + 3]; // A
    }
    rows.push(row);
  }
  // 1 bpp AND mask (1 = transparent), bottom-up, rows padded to 4 bytes.
  for (let y = size - 1; y >= 0; y--) {
    const m = Buffer.alloc(maskBytesPerRow);
    for (let x = 0; x < size; x++) {
      const alpha = c.px[(y * size + x) * 4 + 3];
      if (alpha < 128) {
        m[Math.floor(x / 8)] |= 0x80 >> (x % 8);
      }
    }
    rows.push(m);
  }
  return Buffer.concat([header, ...rows]);
}

const canvases = SIZES.map(render);
const dibs = canvases.map(dib);

const header = Buffer.concat([u16(0), u16(1), u16(dibs.length)]); // ICONDIR
let offset = header.length + 16 * dibs.length;
const entries = dibs.map((d, i) => {
  const size = SIZES[i];
  const e = Buffer.concat([
    Buffer.from([size === 256 ? 0 : size, size === 256 ? 0 : size, 0, 0]),
    u16(1),
    u16(32),
    u32(d.length),
    u32(offset),
  ]);
  offset += d.length;
  return e;
});

writeFileSync(outPath, Buffer.concat([header, ...entries, ...dibs]));
console.log(`wrote ${outPath} (${SIZES.length} sizes: ${SIZES.join(", ")})`);
