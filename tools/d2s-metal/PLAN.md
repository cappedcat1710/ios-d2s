# Metal on the Mali-G76 (d2s)

Goal: QuartzCore and apps get an MTLDevice backed by the Mali-G76 through
Mesa Panfrost (Gallium) and our kernel driver (D2SGPU).

Reference: hakios (github.com/oosexgang/hakios-xnu-kernel, docs/metal-plan.md),
which did this for Adreno with its own PM4 back end. Ours replaces that back
end with Panfrost's Gallium driver (tools/d2s-gl/pantest.c shows the calls).

1. A device that exists (this commit): kernel IOAcceleratorES with the Metal
   plug-in properties (boot-arg metal=1, patch 0138), D2SMetal.bundle
   installed by the boot files (patch 0139 adds a mkdir op), the device logs
   every message it does not answer.
2. Read the log: what Metal asks first. Add queue, buffers, libraries.
3. AIR (Apple shader bitcode) to NIR front end, then Panfrost compiles NIR.
4. Render/compute encoders as Gallium draws and dispatches.
5. QuartzCore's default.metallib, present path through IOSurface.
