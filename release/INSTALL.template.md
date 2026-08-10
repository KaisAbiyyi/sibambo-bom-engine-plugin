# BOM Engine Clean Analysis release candidate

Package: `{{PACKAGE_NAME}}`

Clean format: `bom_engine_clean_v1` version `1.0.0`

Source commit: `{{GIT_COMMIT}}`

This is a release candidate. It has passed standalone Ruby tests but still requires real SketchUp acceptance.

## Install

1. Close any extra SketchUp windows.
2. In SketchUp, open **Window > Extension Manager** and uninstall or disable an older **BOM Engine Clean Analysis (Experimental)** development build.
3. Check the SketchUp Plugins directory and remove stale duplicate copies only after backing them up. There must be only one active `bom_engine_clean_loader.rb`, and it must use the intended `bom_engine/` runtime from this RC. Do not leave an older `bom_engine_clean/` runtime or a second loader active.
4. In **Extension Manager**, choose **Install Extension**, select `{{PACKAGE_NAME}}.rbz`, and accept the installation prompt.
5. Restart SketchUp so the new loader and shared runtime are loaded once from a clean process.

The code registers the command through SketchUp's `UI.menu('Plugins')` menu. Open the **BOM Engine Clean Analysis (Experimental)** submenu and choose **Export Clean Analysis JSON...**. Choose the output path in the save dialog, then choose the batch options.

A successful file must identify itself as:

```text
bom_engine_clean_v1
1.0.0
```

## Replace or uninstall

Use Extension Manager to uninstall/disable the RC before installing another build, then restart SketchUp. Because this RC ships the shared `bom_engine/` runtime dependency closure, coordinate replacement with any installed BOM Engine development build that uses the same folder. Never keep conflicting copies of the loader or runtime under alternate Plugins paths.
