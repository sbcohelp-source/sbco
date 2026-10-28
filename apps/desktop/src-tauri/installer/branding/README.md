# Windows installer artwork

These assets reuse the SBCO clipboard-check mark and green (`#124b3a`) from `../../icons/source.svg`.

- `banner.bmp`: 493 × 58 pixels, with the mark on the right and a blank left area for the installer title.
- `dialog.bmp`: 493 × 312 pixels. Branding uses only the left 164 pixels; the right 329 pixels stay completely white for WiX content. Includes SBCO, Voucher verification, author S K Singh and sbcohelp@gmail.com.
- The corresponding SVG files are editable sources. PNG files are previews of the exact BMP pixels.

Both BMPs are uncompressed, opaque 24-bit RGB files. From the repository root, use the installed project Node runtime and run:

```bash
node apps/desktop/src-tauri/installer/branding/render.mjs
```

Rendering uses the repository's locked Sharp/libvips version and DejaVu Sans installed on the build machine. Use that font to reproduce the text layout. No network or AI image service is used.

Validation on 28 October 2026 checked dimensions, RGB decoding, PNG/BMP pixel equality, and the blank WiX text areas. Both previews were visually inspected at actual size. This is artwork validation; actual MSI dialog placement, Windows scaling, installation and signing require the Windows release build and runtime checks.
