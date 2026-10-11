// Linux shim module: the real persistence sources `import CryptoKit`, which
// exists only on Apple platforms. swift-crypto provides the identical SHA256
// API on Linux; re-exporting it under the CryptoKit module name lets the
// unmodified real sources compile in this check package. On Apple hosts the
// app builds against the real CryptoKit; this target exists only here.
@_exported import Crypto
