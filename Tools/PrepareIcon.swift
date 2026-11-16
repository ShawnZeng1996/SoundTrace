import AppKit
import ImageIO

let arguments = CommandLine.arguments
precondition(arguments.count == 3)
let sourceURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])
let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
let width = image.width
let height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
try pixels.withUnsafeMutableBytes { storage in
    let bytes = storage.bindMemory(to: UInt8.self)
    let context = CGContext(data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var queue: [Int] = []

    func removeExterior(_ index: Int) {
        let offset = index * 4
        guard bytes[offset + 3] != 0 else { return }
        let red = Int(bytes[offset])
        let green = Int(bytes[offset + 1])
        let blue = Int(bytes[offset + 2])
        guard max(red, green, blue) - min(red, green, blue) < 50 else { return }
        bytes[offset] = 0
        bytes[offset + 1] = 0
        bytes[offset + 2] = 0
        bytes[offset + 3] = 0
        queue.append(index)
    }

    for x in 0..<width {
        removeExterior(x)
        removeExterior((height - 1) * width + x)
    }
    for y in 0..<height {
        removeExterior(y * width)
        removeExterior(y * width + width - 1)
    }
    var cursor = 0
    while cursor < queue.count {
        let index = queue[cursor]
        cursor += 1
        let x = index % width
        let y = index / width
        if x > 0 { removeExterior(index - 1) }
        if x < width - 1 { removeExterior(index + 1) }
        if y > 0 { removeExterior(index - width) }
        if y < height - 1 { removeExterior(index + width) }
    }
    let result = context.makeImage()!
    let bitmap = NSBitmapImageRep(cgImage: result)
    let data = bitmap.representation(using: .png, properties: [:])!
    try data.write(to: outputURL)
    print("透明背景：\(queue.count) 像素；已保存 \(outputURL.path)")
}
