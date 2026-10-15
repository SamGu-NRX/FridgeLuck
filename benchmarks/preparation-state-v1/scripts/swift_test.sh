#!/bin/sh
# Convenience wrapper mirroring the task's standard invocation.
exec swift test --package-path "$(dirname "$0")/../SwiftReplay"
