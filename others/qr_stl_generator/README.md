# QR STL Generator

A Dart CLI that converts text into two-colour-friendly QR code STL models.

## Features

- Generates ASCII STL geometry optimised for a single filament swap, multi-material merging, or bundled inlay kits.
- Uses the [`qr`](https://pub.dev/packages/qr) package for QR matrix generation.
- Configurable module size, base thickness, raised height, quiet-zone margin, and error-correction level.

## Usage

```
# Single STL with a colour swap at the specified height
dart run qr_stl_generator --data "https://example.com"   --module-size 0.8 --base-height 0.6 --raise-height 0.8 --output my_qr.stl

# Dual-STL output for MMU/AMS workflows
dart run qr_stl_generator --data "Inventory-42" --mode dual-stl --output inventory
# Produces inventory_base_A.stl and inventory_qr_B.stl

# Dual-STL inlay geometry (modules flush with the base)
dart run qr_stl_generator --data "Invite" --mode dual-stl --inlay --base-height 1.2 --raise-height 0.6 --output invite

# Single STL inlay bundle (mirrored base plus aligned QR plate)
dart run qr_stl_generator --data "Gift" --mode dual-bundle --base-height 1.2 --raise-height 0.6 --output gift_bundle
```

Use `--input path/to/file.txt` to read the payload from disk. Set `--margin` to control the quiet zone in modules (default 4). Error correction is configurable via `--error-correction` (`L`, `M`, `Q`, or `H`).

In single-swap mode, configure your slicer to pause or change colour at `Z = base-height`.

### Combining dual-STL outputs

Import both generated files into the same build plate so the slicer treats them as a single multi-material object. The meshes share the same origin, so every slicer simply needs to align them "by model origin" or "by centre".

- **PrusaSlicer/SuperSlicer** – `File → Import → STL/OBJ as Parts…` and select both files. Alternatively import the base, right-click it in the object list, and choose **Add Part → Load…** to attach the module STL.
- **Bambu Studio / OrcaSlicer** – Add the base STL, then right-click it and choose **Add Process → Add Model** (or **Add Modifier**) and select the module STL. The tool automatically locks them together; assign each part to a colour slot.
- **Ultimaker Cura** – Import both STLs, select them together, then use **Right Click → Merge Models**. Cura merges them at the shared origin so you can assign distinct extruders/materials.

Once the parts are merged, assign materials/colours per part and slice as usual. No manual translation or rotation is required unless you intentionally offset the models.

### Inlay mode (dual-STL)

The `--inlay` flag changes the dual-STL export so that the base plate contains pockets and the module STL fills them. The resulting top surface is flush, which is ideal for multi-material printers that can perform colour swaps within a layer. Ensure `--base-height > --raise-height` so the base retains a pocket floor (`base-height - raise-height`); the module STL starts at that floor and finishes at `base-height`. Dual-bundle mode implicitly uses the same inlay geometry—you do not need to pass `--inlay` when bundling.

### Dual-bundle inlay kit

Select `--mode dual-bundle` to emit a single STL that contains both the pocketed base and a QR plate with all dark modules pre-arranged. The two bodies are offset along +X so they print separately on the same build plate. The base is intentionally mirrored in the STL so that after you flip it face-down the pocket layout matches the non-mirrored QR plate. Once printed, flip the base over so the cavities face down and press it onto the plate—every module drops into the correct pocket without needing to reposition individual tiles. Use `--bundle-gap` to increase the spacing between the two bodies if your printer needs extra clearance.

### Colour limitations

ASCII STL files do not support per-face or per-vertex colour metadata. Colour has to be assigned in your slicer by choosing separate toolheads/materials for each STL (dual mode) or by performing a filament swap during printing (single-swap mode).
