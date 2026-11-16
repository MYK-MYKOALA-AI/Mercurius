// Builds the Mercurius app icon from the logo: `swift scripts/make-icon.swift <out.png>`.
import AppKit

let out = CommandLine.arguments[1]
guard let image = NSImage(contentsOfFile: "Design/Brand/Mercurius.png"),
      let logo = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Mercurius logo could not be read")
}

let side = 1024
let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.interpolationQuality = .high
// macOS icon grid: an 824 pt tile centred in 1024, corner radius about 22.5%.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
context.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)); context.clip()
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let charcoal = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0.20, green: 0.18, blue: 0.17, alpha: 1),
                                                       CGColor(srgbRed: 0.09, green: 0.08, blue: 0.08, alpha: 1)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(charcoal, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
let glow = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 1, green: 0.36, blue: 0.09, alpha: 0.55),
                                                   CGColor(srgbRed: 1, green: 0.36, blue: 0.09, alpha: 0)] as CFArray, locations: [0, 1])!
context.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 470), startRadius: 0, endCenter: CGPoint(x: 512, y: 470), endRadius: 400, options: [])
context.draw(logo, in: CGRect(x: 132, y: 132, width: 760, height: 760))
let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
