import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";

const output = process.argv[2] ?? "src/main/resources/static";
const assetDirectory = path.join(output, "demo-assets", "v1");
fs.mkdirSync(assetDirectory, { recursive: true });

function crc32(buffer) {
  let value = 0xffffffff;
  for (const byte of buffer) {
    value ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      value = (value >>> 1) ^ ((value & 1) ? 0xedb88320 : 0);
    }
  }
  return (value ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const typeBytes = Buffer.from(type, "ascii");
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const checksum = Buffer.alloc(4);
  checksum.writeUInt32BE(crc32(Buffer.concat([typeBytes, data])));
  return Buffer.concat([length, typeBytes, data, checksum]);
}

function png(width, height, pixel) {
  const raw = Buffer.alloc(height * (1 + width * 3));
  let offset = 0;
  for (let y = 0; y < height; y += 1) {
    raw[offset++] = 0;
    for (let x = 0; x < width; x += 1) {
      const rgb = pixel(x, y);
      raw[offset++] = rgb[0];
      raw[offset++] = rgb[1];
      raw[offset++] = rgb[2];
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr.set([8, 2, 0, 0, 0], 8);
  return Buffer.concat([
    Buffer.from("89504e470d0a1a0a", "hex"),
    chunk("IHDR", ihdr),
    chunk("IDAT", zlib.deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

// The glyphs are deliberately embedded bitmap geometry. No host font, locale,
// rasterizer, metadata, or external resource can change these bytes.
const glyphs = {
  " ": ["00000", "00000", "00000", "00000", "00000", "00000", "00000"],
  "[": ["11000", "10000", "10000", "10000", "10000", "10000", "11000"],
  "]": ["01100", "00100", "00100", "00100", "00100", "00100", "01100"],
  "А": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
  "Д": ["00100", "01010", "01010", "10001", "10001", "11111", "10001"],
  "Е": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
  "И": ["10001", "11001", "10101", "10011", "10001", "10001", "10001"],
  "М": ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
  "О": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
  "П": ["11111", "10001", "10001", "10001", "10001", "10001", "10001"],
  "С": ["01111", "10000", "10000", "10000", "10000", "10000", "01111"],
};

function drawText(canvas, width, height, text, scale, color, top, centered = true) {
  const glyphWidth = 5;
  const spacing = 1;
  const textWidth = text.length * (glyphWidth + spacing) * scale - spacing * scale;
  const left = centered ? Math.floor((width - textWidth) / 2) : scale;
  for (let index = 0; index < text.length; index += 1) {
    const glyph = glyphs[text[index]];
    if (!glyph) throw new Error(`Missing embedded glyph: ${text[index]}`);
    const glyphLeft = left + index * (glyphWidth + spacing) * scale;
    for (let gy = 0; gy < glyph.length; gy += 1) {
      for (let gx = 0; gx < glyph[gy].length; gx += 1) {
        if (glyph[gy][gx] !== "1") continue;
        for (let dy = 0; dy < scale; dy += 1) {
          for (let dx = 0; dx < scale; dx += 1) {
            const x = glyphLeft + gx * scale + dx;
            const y = top + gy * scale + dy;
            if (x >= 0 && x < width && y >= 0 && y < height) canvas[y * width + x] = color;
          }
        }
      }
    }
  }
}

function banner(width, height, background, accent, ink, variant) {
  const pixels = Array.from({ length: width * height }, () => background);
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      if ((x + y * (variant + 2)) % 96 < 48) pixels[y * width + x] = accent;
    }
  }
  const panelLeft = Math.floor(width * 0.11);
  const panelTop = Math.floor(height * 0.17);
  const panelRight = Math.floor(width * 0.89);
  const panelBottom = Math.floor(height * 0.83);
  for (let y = panelTop; y < panelBottom; y += 1) {
    for (let x = panelLeft; x < panelRight; x += 1) {
      pixels[y * width + x] = background;
    }
  }
  drawText(pixels, width, height, "[ДЕМО]", 18, ink, Math.floor(height * 0.31));
  return png(width, height, (x, y) => pixels[y * width + x]);
}

function avatar(width, height, background, skin, ink, initial) {
  const pixels = Array.from({ length: width * height }, () => background);
  const center = width / 2;
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const dx = x - center;
      const dy = y - center;
      if (dx * dx + dy * dy <= (width * 0.46) ** 2) pixels[y * width + x] = skin;
      if (dx * dx + dy * dy <= (width * 0.31) ** 2 && y > height * 0.44) pixels[y * width + x] = ink;
    }
  }
  drawText(pixels, width, height, "[ДЕМО]", 5, ink, 34);
  drawText(pixels, width, height, initial, 34, skin, 205);
  return png(width, height, (x, y) => pixels[y * width + x]);
}

const banners = {
  "community-moscow.png": [[35, 63, 122], [244, 177, 66], [245, 247, 255], 1],
  "community-walks.png": [[35, 116, 84], [132, 204, 155], [245, 255, 249], 2],
  "community-online.png": [[87, 56, 153], [111, 193, 255], [249, 246, 255], 3],
  "meeting-moscow.png": [[151, 55, 72], [245, 154, 90], [255, 247, 243], 4],
  "meeting-online.png": [[33, 105, 133], [84, 201, 209], [242, 253, 255], 5],
};
for (const [name, [background, accent, ink, variant]] of Object.entries(banners)) {
  fs.writeFileSync(path.join(assetDirectory, name), banner(1200, 675, background, accent, ink, variant));
}

const avatars = [
  ["avatar-01.png", [238, 119, 123], [255, 225, 190], [104, 57, 75], "А"],
  ["avatar-02.png", [84, 142, 210], [242, 205, 170], [55, 72, 96], "М"],
  ["avatar-03.png", [142, 95, 183], [255, 222, 190], [82, 53, 99], "Е"],
  ["avatar-04.png", [64, 153, 112], [222, 180, 145], [45, 68, 57], "П"],
  ["avatar-05.png", [232, 153, 74], [249, 214, 180], [99, 64, 43], "С"],
  ["avatar-06.png", [71, 126, 154], [226, 191, 157], [48, 62, 73], "И"],
];
for (const [name, background, skin, ink, initial] of avatars) {
  fs.writeFileSync(path.join(assetDirectory, name), avatar(512, 512, background, skin, ink, initial));
}
