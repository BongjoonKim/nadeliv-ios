import AVFoundation
import AppKit

let dir = CommandLine.arguments[1]
let out = URL(fileURLWithPath: dir + "/v1.mp4")
try? FileManager.default.removeItem(at: out)
let size = CGSize(width: 720, height: 1280)
let writer = try! AVAssetWriter(outputURL: out, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 720, AVVideoHeightKey: 1280])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, "Width": 720, "Height": 1280])
writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
let fps: Int32 = 10
var frame: Int64 = 0
for i in 1...6 {
    let img = NSImage(contentsOfFile: dir + "/p\(i)-thumb.jpg")!
    var rect = CGRect(origin: .zero, size: img.size)
    let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
    for _ in 0..<15 {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb!), width: 720, height: 1280, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pb!), space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        let shift = CGFloat(frame % 15) * 8
        ctx.draw(cg, in: CGRect(x: -200 + shift, y: 0, width: 1280, height: 1280))
        CVPixelBufferUnlockBaseAddress(pb!, [])
        while !input.isReadyForMoreMediaData { usleep(1000) }
        adaptor.append(pb!, withPresentationTime: CMTime(value: frame, timescale: fps))
        frame += 1
    }
}
input.markAsFinished()
let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
sem.wait()
print(writer.status == .completed ? "ok \(frame) frames" : "failed \(String(describing: writer.error))")
