# BOM Engine Clean binary package RC

Package: `{{PACKAGE_NAME}}`

Commit: `{{GIT_COMMIT}}`

1. Close every running SketchUp process.
2. In SketchUp Extension Manager, install `{{PACKAGE_NAME}}.rbz`.
3. Restart SketchUp.
4. Confirm **Plugins > BOM Engine Clean Analysis (Experimental)** contains Clean JSON, Clean Visual, and **Export Optimized Clean Package (.cleanpkg)...**.
5. Record **Development Build Info** before acceptance.

The automated Ruby and offline real-fixture checks passed. Real SketchUp binary-package acceptance remains pending.
