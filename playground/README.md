# wat-fft Playground

Interactive playground for testing and visualizing FFT performance using the wat-fft library.

## Features

- **Multiple FFT Implementations**: Test and compare different wat-fft modules:
  - Combined (recommended) - Auto-selects radix-2/4, f64
  - Stockham - Radix-2 SIMD, f64
  - Real Combined - Real FFT, f64
  - f32 Dual - Fastest f32 complex FFT
  - Real f32 Dual - Fastest f32 real FFT

- **Audio Sources**:
  - **Synthetic**: Generate custom sine wave combinations using the Web Audio API's OfflineAudioContext
  - **File**: Load your own audio files (.wav, .mp3, .ogg, etc.)

- **Spectrogram Visualization**: Real-time spectrogram rendering with multiple color scales

- **Performance Metrics**: Track FFT execution time, frames per second, and total processing time

- **Benchmark Mode**: Compare FFT implementations head-to-head with configurable settings

## Quick Start

```bash
# From the parent directory, build WASM modules first
npm run build

# From the playground directory
cd playground
npm install   # Automatically creates symlink to WASM files
npm run dev
```

Then open http://localhost:5173 in your browser.

## Adding Sample Audio Files

Place audio files in the `public/samples/` directory. They will be served at `/samples/` and can be loaded via the file input.

Supported formats depend on browser support, typically:

- WAV (.wav)
- MP3 (.mp3)
- OGG (.ogg)
- FLAC (.flac)
- AAC (.aac, .m4a)

## Synthetic Audio Generation

The playground uses the Web Audio API's `OfflineAudioContext` to generate precise synthetic audio. You can:

1. Add multiple sine wave components
2. Configure frequency (20-20000 Hz) and amplitude (0-1) for each
3. Set sample rate (22050, 44100, or 48000 Hz)
4. Set duration (0.5-10 seconds)

### Preset Ideas

- **Single Tone**: 440 Hz @ 0.5 amplitude
- **Major Chord**: 261.63 Hz (C4) + 329.63 Hz (E4) + 392.0 Hz (G4)
- **Harmonics**: 220 Hz + 440 Hz + 660 Hz + 880 Hz with decreasing amplitudes
- **Beating**: 440 Hz + 442 Hz (creates 2 Hz beat frequency)

## Modes

The playground offers three modes, accessible via the toggle at the top of the sidebar:

### Spectrogram Mode

Generate and visualize spectrograms from audio. Supports synthetic audio generation, file uploads, and live microphone recording.

### Live Analyzer Mode

Real-time spectrum analysis using your microphone. Displays frequency bars, curves, or mirrored visualizations with customizable color schemes.

### Benchmark Mode

Compare FFT implementation performance with detailed metrics.

**Features:**

- **Multi-select implementations**: Choose which FFT libraries to benchmark
  - wat-fft variants: Combined (f64), Stockham (f64 SIMD), f32 Dual, Real FFT (f64), Real f32
  - Alternatives: fft.js, fft.js Real, fft-js, FFTW Real, KissFFT
- **Multi-select FFT sizes**: 256, 512, 1024, 2048, 4096, 8192, 16384
- **Configurable iterations**: 10-1000 iterations per test
- **Warmup runs**: 0-50 warmup runs to ensure JIT optimization
- **Progress indicator**: Real-time progress bar during benchmarking
- **Results table**: Displays Implementation, Size, Avg/Min/Median time (ms), and Ops/sec
- **Fastest highlighting**: Results highlighted in green for the fastest implementation per size
- **Export to markdown**: Copy button exports results as a markdown table with browser info

**Running a Benchmark:**

1. Select the "Benchmark" mode from the top toggle
2. Check the implementations you want to compare
3. Check the FFT sizes to test
4. Adjust iterations and warmup runs as needed
5. Click "Run Benchmark"
6. View results on the canvas
7. Click "Copy Results" to export as markdown

## Spectrogram Settings

- **FFT Size**: 256, 512, 1024, 2048, or 4096 samples
  - Larger = better frequency resolution, worse time resolution
  - Smaller = better time resolution, worse frequency resolution

- **Hop Size**: 128, 256, or 512 samples
  - Smaller = more frames, smoother visualization, slower processing
  - Larger = fewer frames, faster processing

- **Color Scale**: Viridis, Magma, or Grayscale

## Project Structure

```
playground/
├── index.html          # Main HTML page
├── package.json        # Vite dev server config
├── vite.config.js      # Vite configuration
├── public/
│   └── samples/        # Place sample audio files here
└── src/
    ├── main.js         # Application entry point
    ├── fft-loader.js   # WASM module loader
    ├── audio-sources.js # Audio generation utilities
    └── spectrogram.js  # Spectrogram computation and rendering
```

## Performance Tips

1. **Use Real FFT** for real-valued audio signals - it's approximately 2x faster
2. **Use f32 modules** when single-precision is acceptable - they're the fastest
3. **Larger hop sizes** reduce the number of FFT computations
4. **Power-of-4 FFT sizes** (256, 1024, 4096) use the faster radix-4 algorithm

## Troubleshooting

### WASM modules not loading

Make sure to build the WASM modules first:

```bash
cd ..  # Go to parent directory
npm run build
```

### Audio file not loading

- Check that the file format is supported by your browser
- Ensure the file is not corrupted
- Try a different file format (WAV is most reliable)

### Spectrogram looks wrong

- Audio too short: Increase duration or decrease FFT size
- Low frequencies missing: The spectrogram shows 0 Hz at the bottom
- Frequencies look shifted: This is normal for windowed FFT analysis

### FFT validation error

The playground validates FFT implementations on first use by checking that a cosine signal produces energy at the correct frequency bin. If validation fails, the implementation is rejected with an error message.

**Known broken implementations (removed):**

- **PFFFT**: The `@echogarden/pffft-wasm` package (v0.4.2) produces incorrect output for both Complex and Real modes (cosine energy spread across all bins instead of concentrated at bin 1).
- **WebFFT Real**: The `webfft` package's `fftr()` function produces incorrect output (DC signal gives all zeros).

If you encounter validation failures with other implementations, please report them.
