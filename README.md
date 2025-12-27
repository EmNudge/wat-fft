# WAT FFT - Fast Fourier Transform in WebAssembly Text Format

A from-scratch implementation of the Fast Fourier Transform (FFT) algorithm using WebAssembly Text (WAT) format. This project demonstrates modular WAT programming, a glue system for composing modules, and comprehensive testing.

## Project Structure

```
wat-fft/
├── modules/           # Individual WAT modules
│   ├── add.wat       # Basic integer addition
│   ├── sub.wat       # Basic integer subtraction
│   ├── swap.wat      # Memory swap for f64 values
│   ├── reverse_bits.wat  # Bit reversal for FFT
│   ├── math_trig.wat     # Trigonometric functions (sin/cos)
│   └── fft_main.wat      # Main FFT implementation
├── tests/            # Test files for each module
│   ├── utils.js      # Test utilities
│   ├── add.test.js
│   ├── sub.test.js
│   ├── swap.test.js
│   ├── reverse_bits.test.js
│   ├── math_trig.test.js
│   └── combined.test.js  # Integration tests
├── dist/             # Compiled WASM files (generated)
├── glue.js           # Module composition and compilation system
└── package.json      # NPM configuration
```

## Features

### Modular Architecture
- **Individual Modules**: Each component (add, sub, swap, reverse_bits, math_trig) is independently testable
- **Glue System**: Automatically combines modules into a unified WASM binary
- **Dependency Management**: Handles modules with dependencies (e.g., fft_main depends on reverse_bits, swap, sin, cos)

### FFT Implementation
- **Cooley-Tukey Algorithm**: In-place radix-2 FFT
- **Bit-Reversal Permutation**: Efficient bit reversal for FFT input reordering
- **Twiddle Factors**: Computed on-the-fly using custom trigonometric functions

### Trigonometric Functions
- **Taylor Series**: Sin and cos implemented from scratch using 7-term Taylor series
- **Angle Normalization**: Proper handling of angles outside [0, 2π]
- **Trade-offs**: Demonstrates the accuracy limitations of Taylor series approximations

## Setup

### Prerequisites
- Node.js (v18 or later)
- `wat2wasm` tool (from WABT - WebAssembly Binary Toolkit)

### Install WABT
```bash
# macOS
brew install wabt

# Ubuntu/Debian
sudo apt-get install wabt

# Or download from: https://github.com/WebAssembly/wabt/releases
```

### Install Dependencies
```bash
npm install
```

## Usage

### Build All Modules
```bash
npm run glue
```

This will:
1. Compile standalone modules (add, sub, swap, reverse_bits, math_trig)
2. Create a combined module with all functions
3. Output all WASM files to the `dist/` directory

### Run Tests
```bash
# Run all tests
npm test

# Run individual module tests
npm run test:add
npm run test:sub
npm run test:swap
npm run test:reverse_bits
npm run test:math_trig
npm run test:combined
```

## Module Details

### add.wat & sub.wat
Simple arithmetic operations demonstrating basic WAT syntax.

### swap.wat
Swaps two f64 values in memory using byte offsets.

### reverse_bits.wat
Reverses the bits of an integer, used for FFT bit-reversal permutation.
- Input: value and number of bits to consider (log2n)
- Output: bit-reversed value

### math_trig.wat
Implements trigonometric functions from scratch:
- **cos(x)**: 7-term Taylor series approximation
- **sin(x)**: 7-term Taylor series approximation
- **normalize_angle**: Reduces angles to [0, 2π] range
- **PI and TWO_PI**: Exported as global constants

**Accuracy Note**: Taylor series approximations have ~1-3% error at larger angles. For production use, consider:
- Pre-computed twiddle factor tables
- Native trig functions via imports
- Better approximation methods (e.g., CORDIC)

### fft_main.wat
Complete FFT implementation:
- **Algorithm**: Cooley-Tukey radix-2 decimation-in-time
- **Input**: Array of complex numbers in memory (interleaved real/imaginary)
- **Memory Layout**: Each complex number is 16 bytes (8 bytes real + 8 bytes imaginary)
- **Constraints**: Input size must be a power of 2

## Glue System

The `glue.js` script provides:

1. **Individual Compilation**: Each standalone module is wrapped with memory export
2. **Module Composition**: Combines multiple modules into a single WAT file
3. **Dependency Handling**: Skips modules that depend on others (compiled only in combined mode)
4. **Automatic Compilation**: Runs `wat2wasm` on all generated WAT files

### How It Works
- Standalone modules are wrapped in `(module (memory (export "memory") 1) ...)`
- Complete modules (like math_trig.wat) are used as-is
- Combined module includes all function bodies with shared memory

## Testing

All modules have comprehensive tests:

- **Unit Tests**: Test individual modules in isolation
- **Integration Tests**: Test the combined FFT implementation
- **Test Utilities**: Helper functions in `tests/utils.js` for loading WASM modules

### Test Coverage
- ✅ Basic arithmetic (add, sub)
- ✅ Memory operations (swap)
- ✅ Bit manipulation (reverse_bits)
- ✅ Trigonometric functions (sin, cos)
- ✅ Complete FFT (N=4 and N=8)

## Performance Considerations

This implementation prioritizes:
1. **Educational Value**: Demonstrates WAT programming from scratch
2. **Modularity**: Shows how to structure complex WAT projects
3. **Testability**: Every component is independently verifiable

For production FFT:
- Use pre-computed twiddle factors
- Consider larger radix (radix-4, radix-8)
- Import higher-precision trig functions
- Add SIMD optimizations where available

## Known Limitations

1. **Taylor Series Accuracy**: Sin/cos approximations have ~1-3% error, causing FFT output errors of up to 40% for some coefficients
2. **Power-of-2 Only**: Current implementation only handles FFT sizes that are powers of 2
3. **In-place Only**: No option for out-of-place FFT
4. **No Inverse FFT**: Only forward FFT is implemented

## Future Improvements

- [ ] Add inverse FFT (IFFT)
- [ ] Implement better trig approximations or pre-computed tables
- [ ] Support arbitrary FFT sizes (not just powers of 2)
- [ ] Add windowing functions
- [ ] SIMD optimizations
- [ ] Benchmarking suite

## License

ISC

## Contributing

This is an educational project demonstrating WAT/WASM concepts. Contributions are welcome!
