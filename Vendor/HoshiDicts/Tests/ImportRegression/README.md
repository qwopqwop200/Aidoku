# Import regression probes

Compile parser.cpp with src/json/yomitan_parser.cpp and the src and external/glaze/include search paths using C++23 and ASan/UBSan. Compile import.cpp with importer, yomitan_parser, hash/hash, hash/bloom, zip/zip and memory/memory sources; link zstd and libdeflate. Run `python3 fixtures.py /absolute/path/to/import-probe`.

The parser test covers each truncated UTF-8 input prefix, strict tuple/trailing validation and signed frequency bounds. The integration fixture verifies escaped Unicode, control-safe summary serialization, malformed/oversized bank failure, cleanup of partial output and preservation of an existing dictionary. It writes only into a fresh temporary directory.
