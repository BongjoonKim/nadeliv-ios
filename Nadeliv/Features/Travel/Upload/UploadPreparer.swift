import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 업로드할 파일과 메타데이터. TravelMediaRequest 로 서버에 같이 보낸다.
nonisolated struct PreparedUpload {
    let fileURL: URL
    let fileName: String
    let mimeType: String
    let width: Int?
    let height: Int?
    let duration: Int?
    let takenAt: String?
}

/// 사진 선택기에서 받은 파일을 서버에 올릴 형태로 만든다.
/// - HEIC 사진은 JPEG 으로 바꾼다 (웹 브라우저·썸네일 Lambda 호환). EXIF 는 유지.
/// - 촬영 시각·크기·길이를 읽어 같이 보낸다 (앨범 촬영순 정렬에 쓰임).
enum UploadPreparer {
    nonisolated static func prepare(_ source: URL) async throws -> PreparedUpload {
        let type = UTType(filenameExtension: source.pathExtension.lowercased()) ?? .data
        if type.conforms(to: .movie) || type.conforms(to: .video) {
            return try await prepareVideo(source, type: type)
        }
        return try prepareImage(source, type: type)
    }

    // MARK: - 사진

    private nonisolated static func prepareImage(_ source: URL, type: UTType) throws -> PreparedUpload {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]
        var width = props[kCGImagePropertyPixelWidth] as? Int
        var height = props[kCGImagePropertyPixelHeight] as? Int
        // EXIF 회전값 5~8 은 가로세로가 바뀐 상태로 보인다.
        if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation >= 5 {
            swap(&width, &height)
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let takenAt = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap(exifDateToServer)

        let baseName = displayName(source)
        let isHEIF = type.conforms(to: .heic) || type.conforms(to: .heif)
        if isHEIF {
            let jpegURL = source.deletingPathExtension().appendingPathExtension("jpg")
            guard let destination = CGImageDestinationCreateWithURL(
                jpegURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil
            ) else { throw CocoaError(.fileWriteUnknown) }
            let options = [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
            // AddImageFromSource 는 원본 메타데이터(EXIF·GPS·회전)를 그대로 옮긴다.
            CGImageDestinationAddImageFromSource(destination, imageSource, 0, options)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            try? FileManager.default.removeItem(at: source)
            return PreparedUpload(
                fileURL: jpegURL, fileName: baseName + ".jpg", mimeType: "image/jpeg",
                width: width, height: height, duration: nil, takenAt: takenAt
            )
        }

        return PreparedUpload(
            fileURL: source,
            fileName: baseName + "." + source.pathExtension.lowercased(),
            mimeType: type.preferredMIMEType ?? "image/jpeg",
            width: width, height: height, duration: nil, takenAt: takenAt
        )
    }

    /// "2026:10:03 19:35:49" → "2026-10-03T19:35:49" (카메라 로컬 시각 그대로)
    private nonisolated static func exifDateToServer(_ text: String) -> String? {
        let parts = text.split(separator: " ")
        guard parts.count == 2, parts[0].count == 10, parts[1].count >= 8 else { return nil }
        return parts[0].replacingOccurrences(of: ":", with: "-") + "T" + parts[1].prefix(8)
    }

    // MARK: - 영상

    private nonisolated static func prepareVideo(_ source: URL, type: UTType) async throws -> PreparedUpload {
        let asset = AVURLAsset(url: source)
        var duration: Int?
        var width: Int?
        var height: Int?
        var takenAt: String?

        if let time = try? await asset.load(.duration), time.isNumeric {
            duration = Int(time.seconds.rounded())
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let rect = CGRect(origin: .zero, size: size).applying(transform)
            width = Int(abs(rect.width))
            height = Int(abs(rect.height))
        }
        if let item = try? await asset.load(.creationDate),
           let date = try? await item.load(.dateValue) {
            takenAt = TravelDate.serverString(date)
        }

        return PreparedUpload(
            fileURL: source,
            fileName: displayName(source) + "." + source.pathExtension.lowercased(),
            mimeType: type.preferredMIMEType ?? "video/quicktime",
            width: width, height: height, duration: duration, takenAt: takenAt
        )
    }

    /// 임시 복사본 이름 앞의 "UUID-" 를 떼고 원래 파일 이름(확장자 제외)을 돌려준다.
    private nonisolated static func displayName(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        if name.count > 37, name[name.index(name.startIndex, offsetBy: 36)] == "-" {
            return String(name.dropFirst(37))
        }
        return name
    }
}

/// multipart/form-data 본문을 디스크에 만든다. 대용량 영상도 메모리에 올리지 않는다.
enum MultipartBuilder {
    nonisolated struct Request: Encodable {
        let width: Int?
        let height: Int?
        let duration: Int?
        let takenAt: String?
    }

    nonisolated static func build(_ upload: PreparedUpload, boundary: String) throws -> URL {
        let output = upload.fileURL.deletingLastPathComponent()
            .appending(path: "\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }

        let safeName = upload.fileName.replacingOccurrences(of: "\"", with: "")
        try handle.write(contentsOf: Data(
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: \(upload.mimeType)\r\n\r\n".utf8
        ))
        let reader = try FileHandle(forReadingFrom: upload.fileURL)
        defer { try? reader.close() }
        while let chunk = try reader.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            try handle.write(contentsOf: chunk)
        }

        let json = try JSONEncoder().encode(Request(
            width: upload.width, height: upload.height, duration: upload.duration, takenAt: upload.takenAt
        ))
        try handle.write(contentsOf: Data(
            "\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"request\"\r\nContent-Type: application/json\r\n\r\n".utf8
        ))
        try handle.write(contentsOf: json)
        try handle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return output
    }
}
