// Linux compatibility shim: production Detection.swift uses CGRect only as an
// optional payload it never reads in the replay; CoreGraphics does not exist here.
#if !canImport(CoreGraphics)
struct CGRect {}
#endif
