import { useMemo } from 'react';
import { generateQRMatrix } from '../utils/qrcode';

export default function QRCode({ value, size = 256, bgColor = '#ffffff', fgColor = '#000000' }) {
  const { matrix, size: matrixSize } = useMemo(() => generateQRMatrix(value), [value]);

  const cellSize = size / (matrixSize + 2); // +2 for quiet zone

  return (
    <svg
      width={size}
      height={size}
      viewBox={`0 0 ${size} ${size}`}
      xmlns="http://www.w3.org/2000/svg"
      role="img"
      aria-label={`QR code for ${value}`}
    >
      <rect width={size} height={size} fill={bgColor} />
      {matrix.map((row, r) =>
        row.map((cell, c) =>
          cell ? (
            <rect
              key={`${r}-${c}`}
              x={(c + 1) * cellSize}
              y={(r + 1) * cellSize}
              width={cellSize}
              height={cellSize}
              fill={fgColor}
            />
          ) : null
        )
      )}
    </svg>
  );
}
