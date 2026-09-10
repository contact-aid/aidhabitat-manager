(function (root) {
  'use strict';

  // A page snapshot is in displayed (already rotated) coordinates. Convert
  // back to PDF coordinates before applying the user's additional rotation.
  function placement(box, rotation, image, legacyViewport) {
    const odd = rotation % 180 !== 0;
    const width = odd ? box.height : box.width;
    const height = odd ? box.width : box.height;
    const scale = legacyViewport
      ? Math.min(image.width / width, image.height / height)
      : null;
    const w = scale ? image.width / scale : width;
    const h = scale ? image.height / scale : height;
    const dx = (width - w) / 2;
    const dy = (height - h) / 2;
    const origins = {
      0: [box.x + dx, box.y + dy],
      90: [box.x + box.width - dy, box.y + dx],
      180: [box.x + box.width - dx, box.y + box.height - dy],
      270: [box.x + dy, box.y + box.height - dx],
    };
    return { x: origins[rotation][0], y: origins[rotation][1], width: w, height: h };
  }

  async function exportPdf({ source, pages = {}, quarterTurns = 0 }, lib = root.PDFLib) {
    if (!lib || !Number.isInteger(quarterTurns) || !pages || Array.isArray(pages)) {
      throw new Error('Preparation PDF invalide.');
    }
    const { PDFDocument, PDFDict, PDFName, degrees } = lib;
    const pdf = await PDFDocument.load(source, { updateMetadata: false });
    if (!pdf.getPageCount()) throw new Error('PDF sans page.');
    // Rewriting a signed document would invalidate its signature.
    for (const [, object] of pdf.context.enumerateIndirectObjects()) {
      if (object instanceof PDFDict && (object.has(PDFName.of('ByteRange')) ||
          object.get(PDFName.of('Type')) === PDFName.of('Sig'))) {
        throw new Error('PDF signe : modification refusee pour conserver la signature.');
      }
    }
    const pdfPages = pdf.getPages();
    for (const [key, snapshot] of Object.entries(pages)) {
      if (!/^[1-9][0-9]*$/.test(key) || Number(key) > pdfPages.length ||
          !snapshot || !snapshot.bytes || typeof snapshot.legacyViewport !== 'boolean') {
        throw new Error('Annotations de page invalides.');
      }
      const page = pdfPages[Number(key) - 1];
      const rotation = ((page.getRotation().angle % 360) + 360) % 360;
      if (rotation % 90) throw new Error('Rotation de page non prise en charge.');
      // PDF.js renders the intersection of CropBox and MediaBox.
      const crop = page.getCropBox();
      const media = page.getMediaBox();
      const x = Math.max(crop.x, media.x), y = Math.max(crop.y, media.y);
      const box = { x, y,
        width: Math.min(crop.x + crop.width, media.x + media.width) - x,
        height: Math.min(crop.y + crop.height, media.y + media.height) - y };
      if (box.width <= 0 || box.height <= 0) throw new Error('Dimensions PDF invalides.');
      const image = await pdf.embedPng(snapshot.bytes);
      if (!snapshot.legacyViewport) {
        const aspect = rotation % 180 ? box.height / box.width : box.width / box.height;
        if (Math.abs(image.width / image.height / aspect - 1) > 0.02) {
          throw new Error('Dimensions des annotations incompatibles avec la page.');
        }
      }
      page.drawImage(image, {
        ...placement(box, rotation, image, snapshot.legacyViewport),
        rotate: degrees(rotation),
      });
    }
    const turns = ((quarterTurns % 4) + 4) % 4;
    for (const page of pdfPages) {
      page.setRotation(degrees(((page.getRotation().angle + turns * 90) % 360 + 360) % 360));
    }
    const bytes = await pdf.save({ updateFieldAppearances: false });
    const verified = await PDFDocument.load(bytes, { updateMetadata: false });
    if (verified.getPageCount() !== pdfPages.length) throw new Error('PDF produit incomplet.');
    return bytes;
  }

  root.AidHabitatPdfExport = { exportPdf, placement };
})(globalThis);
