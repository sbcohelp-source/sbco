// Run from the repository root: node apps/desktop/src-tauri/installer/branding/render.mjs
// Uses the repository's locked Sharp/libvips renderer and installed DejaVu Sans.
import sharp from "sharp";
import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

for (const name of ["banner", "dialog"]) {
  const source = fileURLToPath(new URL(`${name}.svg`, import.meta.url));
  const image = sharp(await readFile(source))
    .flatten({ background: "#ffffff" })
    .removeAlpha();
  const { data, info } = await image.clone().raw().toBuffer({ resolveWithObject: true });
  if (info.channels !== 3) throw new Error("Expected RGB artwork");
  const stride = (info.width * 3 + 3) & ~3;
  const pixels = stride * info.height;
  const bmp = Buffer.alloc(54 + pixels);
  bmp.write("BM");
  bmp.writeUInt32LE(bmp.length, 2);
  bmp.writeUInt32LE(54, 10);
  bmp.writeUInt32LE(40, 14);
  bmp.writeInt32LE(info.width, 18);
  bmp.writeInt32LE(info.height, 22);
  bmp.writeUInt16LE(1, 26);
  bmp.writeUInt16LE(24, 28);
  bmp.writeUInt32LE(pixels, 34);
  bmp.writeInt32LE(3780, 38);
  bmp.writeInt32LE(3780, 42);
  for (let y = 0; y < info.height; y++) {
    for (let x = 0; x < info.width; x++) {
      const from = (y * info.width + x) * 3;
      const to = 54 + (info.height - 1 - y) * stride + x * 3;
      bmp[to] = data[from + 2];
      bmp[to + 1] = data[from + 1];
      bmp[to + 2] = data[from];
    }
  }
  await writeFile(new URL(`${name}.bmp`, import.meta.url), bmp);
  await image.png().toFile(fileURLToPath(new URL(`${name}.png`, import.meta.url)));
  console.log(`${name}: ${info.width}×${info.height}, uncompressed 24-bit BMP`);
}
