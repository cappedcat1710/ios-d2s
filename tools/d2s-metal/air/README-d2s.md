# AIR -> NIR frontend (from hakios, MIT)

This directory is the AIR (Apple shader bitcode) to NIR translator from the hakios
project (github.com/oosexgang/hakios-xnu-kernel, `tools/mesa/air`), MIT licensed, copyright
"Darwin on redwood contributors" (see the SPDX headers; they are kept as they were).

Changes made here (d2s) to build against Mesa 26.2.6 instead of 25.0.7:

- `gl_shader_stage` -> `mesa_shader_stage` (and `_name`)
- `nir_builder.exact` -> `nir_builder.fp_math_ctrl` (`nir_fp_exact` / `nir_fp_fast_math`)
- `nir_def.parent_instr` -> `nir_def_instr(def)`
- `nir_eval_const_opcode` takes a poison-mask argument
- `nir_block_create(impl)`, `nir_shader_create` without the last argument
- `nir_copy_prop` -> `nir_opt_copy_prop`

Build: copy to Mesa's `src/compiler/air` and add `subdir('air')` after `subdir('spirv')` in
`src/compiler/meson.build` (see tools/d2s-metal/air-meson.patch), then `ninja src/compiler/air/air2nir`.
`air2nir LIB.metallib FUNCTION` prints the NIR. With CoreAnimation's library (from iOS 17.6.1,
kept out of git) 156 of 167 functions translate, including fixed_vert_lph_spc and fixed_frag_lph_cph.
