// Рисует иконку «ОПА!» 1024×1024 и собирает Resources/AppIcon.icns:
//   swiftc tools/make-icon.swift -o /tmp/make-icon && /tmp/make-icon /tmp/icon.png
//   mkdir /tmp/AppIcon.iconset
//   for n in 16 32 128 256 512; do
//     sips -z $n $n /tmp/icon.png --out /tmp/AppIcon.iconset/icon_${n}x${n}.png
//     sips -z $((n * 2)) $((n * 2)) /tmp/icon.png --out /tmp/AppIcon.iconset/icon_${n}x${n}@2x.png
//   done
//   iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
// Надпись заглавными: строчное «Опа!» в 32–64 px читается как "Ona!".
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let center = CGPoint(x: 512, y: 512)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Тело иконки в сетке macOS: 824×824 с отступом 100, скругление ~185.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 28
shadow.set()
color(0xFF7A45).setFill()
bodyPath.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
bodyPath.addClip()
NSGradient(colors: [color(0xFFC53D), color(0xFF7A45), color(0xFF3D6E)])!.draw(in: body, angle: -90)

// «Взрыв» за клавишей — как в комиксе, когда что-то внезапно.
let burst = NSBezierPath()
let rays = 16
for i in 0..<(rays * 2) {
    let angle = CGFloat(i) * .pi / CGFloat(rays) + .pi / 2
    let radius: CGFloat = i % 2 == 0 ? 470 : 330
    let p = CGPoint(x: center.x + cos(angle) * radius, y: center.y + 10 + sin(angle) * radius)
    if i == 0 { burst.move(to: p) } else { burst.line(to: p) }
}
burst.close()
color(0xFFF2B8, 0.55).setFill()
burst.fill()

// Мягкий блик сверху.
NSGradient(colors: [NSColor.white.withAlphaComponent(0.20), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: 100, y: 600, width: 824, height: 324), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// Клавиша, чуть повёрнутая: «подпрыгнула».
ctx.saveGState()
ctx.translateBy(x: center.x, y: center.y)
ctx.rotate(by: 7 * .pi / 180)
let keyWidth: CGFloat = 560, keyHeight: CGFloat = 400, skirt: CGFloat = 46
let face = NSRect(x: -keyWidth / 2, y: -keyHeight / 2 + skirt / 2, width: keyWidth, height: keyHeight)
let base = face.offsetBy(dx: 0, dy: -skirt)

NSGraphicsContext.saveGraphicsState()
let keyShadow = NSShadow()
keyShadow.shadowColor = color(0x8A1030, 0.45)
keyShadow.shadowOffset = NSSize(width: 0, height: -22)
keyShadow.shadowBlurRadius = 36
keyShadow.set()
color(0xD8CFE6).setFill()
NSBezierPath(roundedRect: base, xRadius: 92, yRadius: 92).fill()
NSGraphicsContext.restoreGraphicsState()

let facePath = NSBezierPath(roundedRect: face, xRadius: 92, yRadius: 92)
NSGraphicsContext.saveGraphicsState()
facePath.addClip()
NSGradient(colors: [color(0xFFFFFF), color(0xF1ECF8)])!.draw(in: face, angle: -90)
NSGraphicsContext.restoreGraphicsState()
color(0xFFFFFF, 0.9).setStroke()
facePath.lineWidth = 4
facePath.stroke()

let fontSize: CGFloat = 176
let heavy = NSFont.systemFont(ofSize: fontSize, weight: .black)
let font = heavy.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: fontSize) } ?? heavy
let text = NSAttributedString(string: "ОПА!", attributes: [
    .font: font,
    .foregroundColor: color(0x2B2140),
    .kern: -4,
])
let width = text.size().width
// Центрируем по высоте прописных, а не по всей строке.
text.draw(at: CGPoint(x: -width / 2, y: face.midY - font.capHeight / 2 + font.descender - 4))
ctx.restoreGState()

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
