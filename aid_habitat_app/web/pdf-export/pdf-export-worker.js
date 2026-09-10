importScripts('pdf-lib.min.js', 'pdf-export-core.js');
self.postMessage({ ready: true });
self.onmessage = async ({ data }) => {
  try {
    const bytes = await self.AidHabitatPdfExport.exportPdf(data);
    self.postMessage({ id: data.id, bytes }, [bytes.buffer]);
  } catch (error) {
    self.postMessage({ id: data.id, error: error.message || 'Export PDF impossible.' });
  }
};
