# BOM Engine CleanV1 appearance release candidate

Package: `{{PACKAGE_NAME}}`

Source commit: `{{GIT_COMMIT}}`

Format: `bom_engine_clean_v1` version `1.0.0` (additive appearance fields)

This build has passed standalone Ruby tests. Real SketchUp material/color acceptance is still required.

## Install

1. Close extra SketchUp windows.
2. In **Window > Extension Manager**, uninstall or disable the previous **BOM Engine Clean Analysis (Experimental)** development build.
3. Back up and remove stale duplicate `bom_engine_clean_loader.rb` files. This RC uses the isolated `bom_engine_clean/` runtime folder and does not load the generic `bom_engine/` folder. Keep exactly one active clean loader/runtime pair.
4. In Extension Manager choose **Install Extension**, select `{{PACKAGE_NAME}}.rbz`, and accept the prompt.
5. Restart SketchUp so no older Ruby modules remain loaded in memory.

At startup, the Ruby Console prints `CleanV1 exporter build: <fingerprint>` and the active source directory. The same diagnostic is available under **BOM Engine Clean Analysis (Experimental) > Development Build Info**. Confirm the source ends in `Plugins/bom_engine_clean` before testing.

The extension registers under SketchUp's **Plugins** menu. Choose **BOM Engine Clean Analysis (Experimental) > Export Clean Analysis JSON...**, select an output path, and choose the batch options.

A successful output identifies itself as `bom_engine_clean_v1`, version `1.0.0`, and includes a non-empty top-level `materials` array for painted models. Existing geometry-only CleanV1 consumers may ignore the additive appearance fields.

## Replace or remove

Uninstall or disable this build in Extension Manager before installing another build, then restart SketchUp. Do not keep duplicate loaders or shared `bom_engine/` runtime folders in separate Plugins locations.
