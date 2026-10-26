import 'react';

declare module 'react' {
  interface CSSProperties {
    /** Safari drag suppression for note backgrounds and measurement images. */
    WebkitUserDrag?: 'auto' | 'none' | 'element';
  }
}
