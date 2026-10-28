# Legacy application removal

The old `sbco-live/` and `sbco/` application trees were removed at the user's request. The replacement application is `sbco-next/`. The read-only `sources/` material is preserved.

A recovery archive of legacy source (excluding dependencies, caches and Git metadata) was verified before removal. It is outside the codebase at `/tmp/sbco-legacy-code-20261028.tar.gz`; SHA-256: `578ee05dce6ee97843ed06da40a6fc0edcbffb18328e3bdb7da80262455531db`. `/tmp` is temporary storage, not a permanent backup.

`legacy-schema.json` retains the data dictionary for conversion tooling. It is reference data, not executable Frappe code. Existing sample reports remain in the project's `output/pdf/` directory. Removing source code does not stop or delete any deployed service or database.
