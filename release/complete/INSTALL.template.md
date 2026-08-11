# BOM Engine CleanV1 completeness RC

Package: `{{PACKAGE_NAME}}`

Commit: `{{GIT_COMMIT}}`

1. Close SketchUp.
2. Disable or remove the development loader `bom_engine_clean_dev_loader.rb` from the SketchUp Plugins directory.
3. In SketchUp Extension Manager choose **Install Extension**, select `{{PACKAGE_NAME}}.rbz`, and accept the warning if shown.
4. Restart SketchUp.
5. Confirm **Plugins > BOM Engine Clean Analysis (Experimental)** is present and only one CleanV1 loader is active.
6. Use **Development Build Info** to record the active source and fingerprint.

This is an acceptance candidate. It has passed non-SketchUp automation but has not passed real SketchUp acceptance.
