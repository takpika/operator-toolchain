import Foundation

// LZMA as Apple's Compression framework writes it, which the app decodes with Foundation. Usage: compress.swift IN OUT
let arguments = CommandLine.arguments
let source = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
let packed = try (source as NSData).compressed(using: .lzma)
try (packed as Data).write(to: URL(fileURLWithPath: arguments[2]), options: .atomic)
