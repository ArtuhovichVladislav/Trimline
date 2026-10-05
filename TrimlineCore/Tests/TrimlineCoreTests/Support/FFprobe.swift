import Foundation

// Reads a clip back with the locally installed ffprobe, so checks don't depend on the code under test.
enum FFprobe {
    struct Report: Decodable {
        let streams: [Stream]
        let chapters: [Chapter]
        let format: Format
    }

    struct Stream: Decodable {
        let index: Int
        let codecType: String
        let codecName: String?
        let codecTagString: String?
        let profile: String?
        let pixFmt: String?
        let width: Int?
        let height: Int?
        let tags: [String: String]?
        let sideDataList: [SideData]?
        let disposition: [String: Int]?

        var rotation: Double? { sideDataList?.compactMap(\.rotation).first }
        var isAttachedPicture: Bool { disposition?["attached_pic"] == 1 }
    }

    struct SideData: Decodable {
        let rotation: Double?
    }

    struct Chapter: Decodable {
        let startTime: String
        let endTime: String
        let tags: [String: String]?

        var start: Double { Double(startTime) ?? -1 }
        var end: Double { Double(endTime) ?? -1 }
    }

    struct Format: Decodable {
        let formatName: String
        let duration: String?
        let startTime: String?
        let tags: [String: String]?

        var start: Double { startTime.flatMap(Double.init) ?? 0 }

        var seconds: Double { duration.flatMap(Double.init) ?? 0 }
    }

    static func report(_ url: URL) throws -> Report {
        let data = try run(["-show_format", "-show_streams", "-show_chapters", url.path])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Report.self, from: data)
    }

    /// Presentation times of the first packets of the first video stream (or audio if there is none).
    static func firstPacketTimes(_ url: URL, stream: String = "v:0", count: Int = 1) throws -> [Double] {
        struct Packets: Decodable {
            struct Packet: Decodable {
                let ptsTime: String?
            }
            let packets: [Packet]
        }
        let data = try run([
            "-select_streams", stream, "-show_entries", "packet=pts_time", "-read_intervals", "%+#\(count)", url.path,
        ])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Packets.self, from: data).packets.compactMap { $0.ptsTime.flatMap(Double.init) }
    }

    private static func run(_ arguments: [String]) throws -> Data {
        guard let ffmpeg = ExternalMP3.encoder else { throw TestMediaError.writerFailed }
        let process = Process()
        process.executableURL = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        process.arguments = ["-v", "error", "-print_format", "json"] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TestMediaError.writerFailed }
        return data
    }
}
