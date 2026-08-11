# CleanV1 coverage guide

`diagnostics.coverage` partitions eligible source primitives:

- `analytical`: represented by top-level architectural surfaces.
- `visual_retained`: retained as shared definition-local polygons or standalone visual edges.
- `fallback`: invalid/unrepresentable polygon data preserved explicitly in `fallback_geometry`.
- `explicitly_excluded`: excluded by a named policy such as `analysis_irrelevant`.
- `unaccounted`: eligible geometry with no output disposition. This must be zero.

Production JSON contains aggregates only. A debug compile additionally includes `diagnostics.coverage_ledger`, with deterministic source keys, primitive type, owning definition, occurrence ancestry, disposition, and reason.

From a source checkout, print the compact report without SketchUp:

```powershell
ruby dev/clean_analysis_coverage_report.rb "C:\path\to\export.json"
```

To report a detail-loss bug, provide the source object/definition name, expected visible feature, output disposition, coverage reason, and whether its definition or instance is present.
