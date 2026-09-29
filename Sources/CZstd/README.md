# Zstandard decompressor

This directory contains the decompression-only Zstandard 1.5.6 amalgamation
(`zstddeclib.c`, `zstd.h`, and `zstd_errors.h`), redistributed under the
BSD-3-Clause license in `LICENSE`. The files were obtained from VibeMenu at
commit `5b1588f6d6a923519d886d8e0d015e2373593356`, which vendors the
upstream Zstandard amalgamation. Only decoding is linked into QuotaTempo.
