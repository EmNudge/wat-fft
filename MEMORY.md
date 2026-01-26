# Memory Layout

This document describes the WebAssembly memory layout used by the FFT implementations.

## Overview

All FFT modules use linear memory to store:

1. **Input/Output data** - Complex numbers at the start of memory
2. **Secondary buffer** - Ping-pong buffer for Stockham algorithm
3. **Twiddle factors** - Precomputed sin/cos values
4. **RFFT twiddle factors** - Additional twiddles for real FFT

## Memory Map

```
Offset (bytes)    Size        Description
─────────────────────────────────────────────────────────────
0x00000 (0)       Variable    Primary data buffer (input/output)
                              N complex numbers = N × 16 bytes

0x10000 (65536)   Variable    Secondary buffer (Stockham ping-pong)
                              N complex numbers = N × 16 bytes

0x20000 (131072)  Variable    Twiddle factors (W_N^k)
                              N complex numbers = N × 16 bytes

0x30000 (196608)  Variable    RFFT twiddle factors
                              (N/2) complex numbers = N × 8 bytes
```

## Constants

Defined as globals in WAT modules:

```wat
(global $SECONDARY_OFFSET i32 (i32.const 65536))   ;; 0x10000 = 64KB
(global $TWIDDLE_OFFSET i32 (i32.const 131072))    ;; 0x20000 = 128KB
(global $RFFT_TWIDDLE_OFFSET i32 (i32.const 196608)) ;; 0x30000 = 192KB
```

## Memory Requirements by Module

| Module                  | Pages | Total Memory | Max FFT Size | Notes                    |
| ----------------------- | ----- | ------------ | ------------ | ------------------------ |
| `fft_combined`          | 4     | 256 KB       | ~4096        | Radix-2/4 auto-dispatch  |
| `fft_real_combined`     | 5     | 320 KB       | ~4096        | Real FFT + auto-dispatch |
| `fft_stockham_f32_dual` | 2     | 128 KB       | ~4096        | f32 dual-complex SIMD    |
| `fft_real_f32_dual`     | 3     | 192 KB       | ~4096        | f32 real FFT             |

**Note:** 1 WebAssembly page = 64 KB (65,536 bytes)

## Complex Number Layout

Each complex number is stored as two consecutive 64-bit floats:

```
Offset    Type     Description
──────────────────────────────
+0        f64      Real part
+8        f64      Imaginary part
```

To access complex number at index `i`:

- Real part: `memory[i * 16]` (as f64)
- Imaginary part: `memory[i * 16 + 8]` (as f64)

Using SIMD (v128):

```wat
;; Load complex number at index i
(v128.load (i32.shl (local.get $i) (i32.const 4)))
```

## Maximum Supported FFT Sizes

The maximum FFT size is limited by available memory:

| Pages | Memory | Max N (data only) | Max N (with twiddles) |
| ----- | ------ | ----------------- | --------------------- |
| 1     | 64 KB  | 4,096             | N/A (no space)        |
| 2     | 128 KB | 8,192             | 2,048                 |
| 3     | 192 KB | 12,288            | 4,096                 |
| 4     | 256 KB | 16,384            | 4,096                 |
| 8     | 512 KB | 32,768            | 16,384                |

**Calculation:**

- Data buffer: `N × 16` bytes
- Secondary buffer (Stockham): `N × 16` bytes
- Twiddle factors: `N × 16` bytes
- RFFT twiddles: `N × 8` bytes

For Stockham with twiddles: `N × 16 × 3 + N × 8 = N × 56` bytes max

## Twiddle Factor Storage

Twiddle factors `W_N^k = e^(-2πik/N) = cos(-2πk/N) + i·sin(-2πk/N)` are precomputed:

```
Index k   Offset                        Value
───────────────────────────────────────────────────
0         TWIDDLE_OFFSET                W_N^0 = 1 + 0i
1         TWIDDLE_OFFSET + 16           W_N^1
2         TWIDDLE_OFFSET + 32           W_N^2
...
N-1       TWIDDLE_OFFSET + (N-1)*16     W_N^(N-1)
```

## Memory Access Patterns

### Radix-2 Butterfly

```
In-place update of data[i] and data[i + stride]:
  temp = data[i]
  data[i] = temp + W * data[i + stride]
  data[i + stride] = temp - W * data[i + stride]
```

### Radix-4 Butterfly

```
Four-point butterfly at indices i, i+q, i+2q, i+3q (q = N/4):
  Uses twiddles W^0, W^k, W^2k, W^3k
```

### Stockham (Out-of-place)

```
Reads from primary buffer, writes to secondary buffer
After each stage, buffers are swapped
Final result may need to be copied back
```

## Extending Memory

To support larger FFT sizes, increase memory pages in the WAT module:

```wat
;; For N up to 16384, use 8 pages
(memory (export "memory") 8)
```

Or grow memory dynamically:

```javascript
const pages = Math.ceil((N * 56) / 65536);
if (wasm.memory.buffer.byteLength < pages * 65536) {
  wasm.memory.grow(pages - wasm.memory.buffer.byteLength / 65536);
}
```

## Safety Considerations

1. **Buffer overflow**: Ensure `N * 16 <= SECONDARY_OFFSET` for non-Stockham
2. **Twiddle overflow**: Ensure `N * 16 <= memory_size - TWIDDLE_OFFSET`
3. **Alignment**: All accesses are 16-byte aligned for SIMD
4. **Initialization**: Call `precompute_twiddles(N)` before FFT operations
