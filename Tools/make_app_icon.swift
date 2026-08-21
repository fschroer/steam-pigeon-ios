// Android's launcher icon -> the iOS app icon.
//
//   swift Tools/make_app_icon.swift <source.png> <out.png> [size] [backgroundRRGGBB]
//
// Source is Android's `app/src/main/steam_pigeon-playstore.png`, the 512-px square
// the icon was authored as. **Not `ic_launcher`** — that is the Android Studio
// template robot, still sitting in the repo unused; the manifest points at
// `@mipmap/steam_pigeon`, and the two look nothing alike.
//
// Two things this does that a copy would not:
//
// 1. **Composites onto the adaptive icon's background colour** (`#000000`, from
//    `values/steam_pigeon_background.xml`). The Play Store art carries alpha, and
//    iOS icons must not: Xcode warns, and the App Store refuses one outright.
// 2. **Resamples once**, 512 -> 1024, at high interpolation quality. iOS wants a
//    single 1024 icon and scales it down itself.
//
// The adaptive foreground is the other possible source, but it is 432 px and only
// its central 72/108 is visible, so it would mean upscaling 288 px by 3.6x. The
// two compositions are near-identical — checked side by side — so the sharper
// source wins.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else {
    fatalError("usage: make_app_icon.swift <source.png> <out.png> [size] [backgroundRRGGBB]")
}
let size = args.count > 3 ? Int(args[3])! : 1024
let hex = args.count > 4 ? args[4] : "000000"
let rgb = Int(hex, radix: 16)!
let (r, g, b) = (CGFloat((rgb >> 16) & 0xFF) / 255,
                 CGFloat((rgb >> 8) & 0xFF) / 255,
                 CGFloat(rgb & 0xFF) / 255)

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("could not read \(args[1])")
}
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("could not create an opaque context")
}
ctx.interpolationQuality = .high
ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

guard let out = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil)
else { fatalError("could not write \(args[2])") }
CGImageDestinationAddImage(dest, out, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("write failed") }
print("wrote \(args[2]) — \(size)x\(size), opaque, on #\(hex)")
