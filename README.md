# BDAA Authoring Suite

A macOS application for creating Blu-ray Audio discs from high-quality audio files.

## Features

- **Multi-format Support**: Import FLAC, THD, DTS, WAV, and M2TS audio files
- **Blu-ray Compliance**: Generates proper BDMV folder structure for Blu-ray burning
- **Multiple Output Codecs**:
  - LPCM (24-bit/48kHz, 96kHz, or 192kHz)
  - Dolby TrueHD/Atmos (pass-through)
  - DTS-HD Master Audio (pass-through)
- **Black Screen Video**: Automatically generates H.264 video stream at 23.976fps (configurable)
- **Disc Capacity Planning**: Estimates output size for BD-25, BD-50, and BD-XL discs

## Requirements

- macOS 11.5 or later
- Xcode 13+ (for building from source)
- External tools (bundled):
  - ffmpeg (audio conversion and video generation)
  - ffprobe (metadata extraction)
  - tsMuxeR (Blu-ray BDMV creation)

## Usage

1. **Add Audio Files**: Click "Add Files" to import your audio tracks
2. **Select Output Codec**: Choose between LPCM, TrueHD, or DTS-HD passthrough
3. **Configure Settings**: Set video FPS and resolution if needed
4. **Build**: Click "Build Blu-ray Folder" to create the BDMV structure
5. **Burn**: Use your preferred Blu-ray burning software with the generated folder

## Technical Details

- **Video Stream**: Black screen H.264 High@4.1 profile (required by Blu-ray spec)
- **Audio Quality**: Preserves original quality with pass-through modes
- **LPCM Conversion**: Normalizes mixed formats to consistent Blu-ray-legal PCM
- **Chapter Support**: Automatic chapter creation for each track

## Building from Source

```bash
git clone https://github.com/RetroWrangler/BDAA-Authoring-Suite.git
cd BDAA-Authoring-Suite
open "BDAA Authoring Suite.xcodeproj"
```

Build using Xcode or command line:
```bash
xcodebuild -project "BDAA Authoring Suite.xcodeproj" -scheme "BDAA Authoring Suite - Retro" -configuration Release
```

## License

[Add your license information here]

## Contributing

[Add contribution guidelines here]

## Support

[Add support/contact information here]