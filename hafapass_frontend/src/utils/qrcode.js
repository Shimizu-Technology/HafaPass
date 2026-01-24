// Minimal QR Code generator for alphanumeric/byte data
// Generates Version 2-4 QR codes (enough for UUIDs like "a1b2c3d4-e5f6-7890-abcd-ef1234567890")
// Based on ISO/IEC 18004 QR Code specification

const ECL = { L: 0, M: 1, Q: 2, H: 3 };

// Error correction codewords and data codewords for versions 1-6
const EC_TABLE = [
  // [total_codewords, ec_per_block, num_blocks, data_codewords]
  // Version 1
  { L: [26, 7, 1, 19], M: [26, 10, 1, 16], Q: [26, 13, 1, 13], H: [26, 17, 1, 9] },
  // Version 2
  { L: [44, 10, 1, 34], M: [44, 16, 1, 28], Q: [44, 22, 1, 22], H: [44, 28, 1, 16] },
  // Version 3
  { L: [70, 15, 1, 55], M: [70, 26, 1, 44], Q: [70, 18, 2, 17], H: [70, 22, 2, 13] },
  // Version 4
  { L: [100, 20, 1, 80], M: [100, 18, 2, 32], Q: [100, 26, 2, 24], H: [100, 16, 4, 9] },
  // Version 5
  { L: [134, 26, 1, 108], M: [134, 24, 2, 43], Q: [134, 18, 2, 15], H: [134, 22, 2, 11] },
  // Version 6
  { L: [172, 18, 2, 68], M: [172, 16, 4, 27], Q: [172, 24, 4, 19], H: [172, 28, 4, 15] },
];

// Version 3 alignment pattern position
const ALIGNMENT_PATTERNS = [
  [], // v1
  [6, 18], // v2
  [6, 22], // v3
  [6, 26], // v4
  [6, 30], // v5
  [6, 34], // v6
];

// Format info strings for each mask pattern (ECL M)
const FORMAT_INFO = [
  0x5412, 0x5125, 0x5E7C, 0x5B4B, 0x45F9, 0x40CE, 0x4F97, 0x4AA0,
  0x77C4, 0x72F3, 0x7DAA, 0x789D, 0x662F, 0x6318, 0x6C41, 0x6976,
];

// GF(256) arithmetic for Reed-Solomon
const GF_EXP = new Uint8Array(512);
const GF_LOG = new Uint8Array(256);
(function initGF() {
  let x = 1;
  for (let i = 0; i < 255; i++) {
    GF_EXP[i] = x;
    GF_LOG[x] = i;
    x = x << 1;
    if (x & 0x100) x ^= 0x11d;
  }
  for (let i = 255; i < 512; i++) GF_EXP[i] = GF_EXP[i - 255];
})();

function gfMul(a, b) {
  if (a === 0 || b === 0) return 0;
  return GF_EXP[GF_LOG[a] + GF_LOG[b]];
}

function rsGenPoly(nsym) {
  let g = [1];
  for (let i = 0; i < nsym; i++) {
    const ng = new Array(g.length + 1).fill(0);
    for (let j = 0; j < g.length; j++) {
      ng[j] ^= g[j];
      ng[j + 1] ^= gfMul(g[j], GF_EXP[i]);
    }
    g = ng;
  }
  return g;
}

function rsEncode(data, nsym) {
  const gen = rsGenPoly(nsym);
  const res = new Uint8Array(data.length + nsym);
  res.set(data);
  for (let i = 0; i < data.length; i++) {
    const coef = res[i];
    if (coef !== 0) {
      for (let j = 0; j < gen.length; j++) {
        res[i + j] ^= gfMul(gen[j], coef);
      }
    }
  }
  return Array.from(res.slice(data.length));
}

function getVersion(dataLen, ecl) {
  const eclKey = ['L', 'M', 'Q', 'H'][ecl];
  for (let v = 0; v < EC_TABLE.length; v++) {
    const info = EC_TABLE[v][eclKey];
    // data capacity: data_codewords * num_blocks (for multi-block)
    const capacity = info[3] * info[2];
    // Byte mode: 4 bits mode + 8/16 bits length + data * 8 bits + 4 bits terminator
    const lenBits = v < 9 ? 8 : 16;
    const overhead = Math.ceil((4 + lenBits + 4) / 8);
    if (dataLen + overhead <= capacity) return v + 1;
  }
  return 6; // fallback to version 6
}

function encodeData(text, version, ecl) {
  const eclKey = ['L', 'M', 'Q', 'H'][ecl];
  const info = EC_TABLE[version - 1][eclKey];
  const totalDataCW = info[3] * info[2];
  const ecCW = info[1];
  const numBlocks = info[2];

  // Byte mode encoding
  const bits = [];
  function pushBits(val, len) {
    for (let i = len - 1; i >= 0; i--) bits.push((val >> i) & 1);
  }

  pushBits(0b0100, 4); // Byte mode indicator
  const lenBits = version <= 9 ? 8 : 16;
  pushBits(text.length, lenBits);

  for (let i = 0; i < text.length; i++) {
    pushBits(text.charCodeAt(i), 8);
  }

  // Terminator
  const totalDataBits = totalDataCW * 8;
  const termLen = Math.min(4, totalDataBits - bits.length);
  pushBits(0, termLen);

  // Pad to byte boundary
  while (bits.length % 8 !== 0) bits.push(0);

  // Pad codewords
  const padBytes = [0xEC, 0x11];
  let padIdx = 0;
  while (bits.length < totalDataBits) {
    pushBits(padBytes[padIdx % 2], 8);
    padIdx++;
  }

  // Convert to bytes
  const dataBytes = [];
  for (let i = 0; i < bits.length; i += 8) {
    let byte = 0;
    for (let j = 0; j < 8; j++) byte = (byte << 1) | (bits[i + j] || 0);
    dataBytes.push(byte);
  }

  // Split into blocks and generate EC
  const blockSize = Math.floor(totalDataCW / numBlocks);
  const blocks = [];
  const ecBlocks = [];
  let offset = 0;
  for (let b = 0; b < numBlocks; b++) {
    const bSize = b < numBlocks ? blockSize : blockSize + 1;
    const block = dataBytes.slice(offset, offset + bSize);
    blocks.push(block);
    ecBlocks.push(rsEncode(new Uint8Array(block), ecCW));
    offset += bSize;
  }

  // Interleave data blocks
  const result = [];
  const maxBlockLen = Math.max(...blocks.map(b => b.length));
  for (let i = 0; i < maxBlockLen; i++) {
    for (let b = 0; b < numBlocks; b++) {
      if (i < blocks[b].length) result.push(blocks[b][i]);
    }
  }
  // Interleave EC blocks
  for (let i = 0; i < ecCW; i++) {
    for (let b = 0; b < numBlocks; b++) {
      result.push(ecBlocks[b][i]);
    }
  }

  return result;
}

function createMatrix(version) {
  const size = 17 + version * 4;
  const matrix = Array.from({ length: size }, () => new Uint8Array(size));
  const reserved = Array.from({ length: size }, () => new Uint8Array(size));
  return { matrix, reserved, size };
}

function placeFinderPattern(matrix, reserved, row, col) {
  for (let r = -1; r <= 7; r++) {
    for (let c = -1; c <= 7; c++) {
      const rr = row + r, cc = col + c;
      if (rr < 0 || rr >= matrix.length || cc < 0 || cc >= matrix.length) continue;
      if (r >= 0 && r <= 6 && c >= 0 && c <= 6) {
        const isBlack = (r === 0 || r === 6 || c === 0 || c === 6) ||
                        (r >= 2 && r <= 4 && c >= 2 && c <= 4);
        matrix[rr][cc] = isBlack ? 1 : 0;
      } else {
        matrix[rr][cc] = 0;
      }
      reserved[rr][cc] = 1;
    }
  }
}

function placeAlignmentPattern(matrix, reserved, row, col) {
  for (let r = -2; r <= 2; r++) {
    for (let c = -2; c <= 2; c++) {
      const rr = row + r, cc = col + c;
      if (reserved[rr][cc]) continue;
      const isBlack = Math.abs(r) === 2 || Math.abs(c) === 2 || (r === 0 && c === 0);
      matrix[rr][cc] = isBlack ? 1 : 0;
      reserved[rr][cc] = 1;
    }
  }
}

function placeTimingPatterns(matrix, reserved, size) {
  for (let i = 8; i < size - 8; i++) {
    if (!reserved[6][i]) {
      matrix[6][i] = i % 2 === 0 ? 1 : 0;
      reserved[6][i] = 1;
    }
    if (!reserved[i][6]) {
      matrix[i][6] = i % 2 === 0 ? 1 : 0;
      reserved[i][6] = 1;
    }
  }
}

function reserveFormatAreas(reserved, size) {
  // Around top-left finder
  for (let i = 0; i <= 8; i++) {
    reserved[8][i] = 1;
    reserved[i][8] = 1;
  }
  // Around top-right finder
  for (let i = 0; i <= 7; i++) {
    reserved[8][size - 1 - i] = 1;
  }
  // Around bottom-left finder
  for (let i = 0; i <= 7; i++) {
    reserved[size - 1 - i][8] = 1;
  }
  // Dark module
  reserved[size - 8][8] = 1;
}

function placeData(matrix, reserved, size, data) {
  let bitIdx = 0;
  const totalBits = data.length * 8;
  let col = size - 1;

  while (col > 0) {
    if (col === 6) col--;
    for (let row = 0; row < size; row++) {
      for (let c = 0; c < 2; c++) {
        const cc = col - c;
        const isUpward = ((size - 1 - col) >> 1) % 2 === 0;
        const rr = isUpward ? size - 1 - row : row;
        if (reserved[rr][cc]) continue;
        if (bitIdx < totalBits) {
          const byteIdx = Math.floor(bitIdx / 8);
          const bitOff = 7 - (bitIdx % 8);
          matrix[rr][cc] = (data[byteIdx] >> bitOff) & 1;
          bitIdx++;
        }
      }
    }
    col -= 2;
  }
}

function getMaskFn(maskNum) {
  switch (maskNum) {
    case 0: return (r, c) => (r + c) % 2 === 0;
    case 1: return (r) => r % 2 === 0;
    case 2: return (r, c) => c % 3 === 0;
    case 3: return (r, c) => (r + c) % 3 === 0;
    case 4: return (r, c) => (Math.floor(r / 2) + Math.floor(c / 3)) % 2 === 0;
    case 5: return (r, c) => ((r * c) % 2 + (r * c) % 3) === 0;
    case 6: return (r, c) => ((r * c) % 2 + (r * c) % 3) % 2 === 0;
    default: return (r, c) => ((r + c) % 2 + (r * c) % 3) % 2 === 0;
  }
}

function applyMask(matrix, reserved, size, maskNum) {
  const maskFn = getMaskFn(maskNum);

  for (let r = 0; r < size; r++) {
    for (let c = 0; c < size; c++) {
      if (!reserved[r][c] && maskFn(r, c)) {
        matrix[r][c] ^= 1;
      }
    }
  }
}

function placeFormatInfo(matrix, size, ecl, maskNum) {
  const formatIdx = ecl * 8 + maskNum;
  const info = FORMAT_INFO[formatIdx];

  // Place format bits
  const bits = [];
  for (let i = 14; i >= 0; i--) bits.push((info >> i) & 1);

  // Horizontal: left of top-left finder + right side
  const hPositions = [0, 1, 2, 3, 4, 5, 7, 8, size - 8, size - 7, size - 6, size - 5, size - 4, size - 3, size - 2];
  for (let i = 0; i < 15; i++) {
    matrix[8][hPositions[i]] = bits[i];
  }

  // Vertical: below top-left finder + bottom side
  const vPositions = [size - 1, size - 2, size - 3, size - 4, size - 5, size - 6, size - 7, 8, 7, 5, 4, 3, 2, 1, 0];
  for (let i = 0; i < 15; i++) {
    matrix[vPositions[i]][8] = bits[i];
  }

  // Dark module
  matrix[size - 8][8] = 1;
}

function scoreMask(matrix, size) {
  let score = 0;

  // Rule 1: consecutive same-color modules in row/col
  for (let r = 0; r < size; r++) {
    let count = 1;
    for (let c = 1; c < size; c++) {
      if (matrix[r][c] === matrix[r][c - 1]) {
        count++;
        if (count === 5) score += 3;
        else if (count > 5) score += 1;
      } else {
        count = 1;
      }
    }
  }
  for (let c = 0; c < size; c++) {
    let count = 1;
    for (let r = 1; r < size; r++) {
      if (matrix[r][c] === matrix[r - 1][c]) {
        count++;
        if (count === 5) score += 3;
        else if (count > 5) score += 1;
      } else {
        count = 1;
      }
    }
  }

  // Rule 4: proportion of dark modules
  let dark = 0;
  for (let r = 0; r < size; r++)
    for (let c = 0; c < size; c++)
      if (matrix[r][c]) dark++;
  const pct = (dark * 100) / (size * size);
  const prev5 = Math.floor(pct / 5) * 5;
  const next5 = prev5 + 5;
  score += Math.min(Math.abs(prev5 - 50) / 5, Math.abs(next5 - 50) / 5) * 10;

  return score;
}

export function generateQRMatrix(text, ecl = ECL.M) {
  const version = getVersion(text.length, ecl);
  const size = 17 + version * 4;
  const data = encodeData(text, version, ecl);

  let bestMatrix = null;
  let bestScore = Infinity;

  for (let mask = 0; mask < 8; mask++) {
    const { matrix, reserved } = createMatrix(version);

    // Place finder patterns
    placeFinderPattern(matrix, reserved, 0, 0);
    placeFinderPattern(matrix, reserved, 0, size - 7);
    placeFinderPattern(matrix, reserved, size - 7, 0);

    // Place alignment patterns (version 2+)
    if (version >= 2) {
      const positions = ALIGNMENT_PATTERNS[version - 1];
      for (let i = 0; i < positions.length; i++) {
        for (let j = 0; j < positions.length; j++) {
          // Skip if overlaps with finder pattern
          if ((i === 0 && j === 0) || (i === 0 && j === positions.length - 1) ||
              (i === positions.length - 1 && j === 0)) continue;
          placeAlignmentPattern(matrix, reserved, positions[i], positions[j]);
        }
      }
    }

    // Timing patterns
    placeTimingPatterns(matrix, reserved, size);

    // Reserve format info areas
    reserveFormatAreas(reserved, size);

    // Place data
    placeData(matrix, reserved, size, data);

    // Apply mask
    applyMask(matrix, reserved, size, mask);

    // Place format info
    placeFormatInfo(matrix, size, ecl, mask);

    // Score
    const score = scoreMask(matrix, size);
    if (score < bestScore) {
      bestScore = score;
      bestMatrix = matrix.map(row => Array.from(row));
    }
  }

  return { matrix: bestMatrix, size };
}
