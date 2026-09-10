# PDF Web Export

`pdf-lib.min.js` and its MIT license are vendored from the existing npm
dependency `pdf-lib` 1.17.1. No CDN or document upload is used for conversion.
To update, copy `node_modules/pdf-lib/dist/pdf-lib.min.js` and `LICENSE.md`
here and rerun the PDF export tests and browser worker smoke test.

The worker embeds only annotated page snapshots and rotates the original
PDF pages without rasterizing untouched pages. Original content and text
remain in the PDF; historical flattened strokes are not editable ink.
Signed and encrypted PDFs are rejected rather than silently rewritten.
