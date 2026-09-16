// Fit every photo in its column at one shared height without cropping/stretching.
export function uniformPhotoHeight(slots, preferredHeight) {
  return slots.reduce((height, { width, image }) => {
    if (!(width > 0 && image.width > 0 && image.height > 0)) {
      throw new RangeError('Photo layout dimensions must be positive');
    }
    return Math.min(height, width * image.height / image.width);
  }, preferredHeight);
}
