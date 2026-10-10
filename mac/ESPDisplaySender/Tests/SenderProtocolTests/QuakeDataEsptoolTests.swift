import XCTest
@testable import SenderProtocol

/// The read-only esptool runs the Quake data write makes before and after its
/// one write: the partition table read and, on an S3, the flash size.
final class QuakeDataEsptoolTests: XCTestCase {

    private let tool = EsptoolCommand.Tool(
        path: "/Users/x/Library/Arduino15/packages/esp32/tools/esptool_py/5.3.1/esptool")
    private let script = EsptoolCommand.Tool(path: "/opt/esptool/esptool.py")
    private let port = "/dev/cu.usbmodem101"

    // MARK: - read-flash

    func testReadFlashReadsThePartitionTableChipPinned() throws {
        let command = try EsptoolCommand.readFlash(
            tool: tool, chip: "esp32p4", port: port,
            address: QuakePak.partitionTableAddress,
            byteCount: QuakePak.partitionTableBytes, outputPath: "/stage/partitions.bin")
        XCTAssertEqual(command.executable, tool.path)
        XCTAssertEqual(command.arguments, [
            "--chip", "esp32p4",
            "--port", "/dev/cu.usbmodem101",
            "--baud", "921600",
            "--before", "default-reset",
            "--after", "hard-reset",
            "read-flash", "0x8000", "0xc00", "/stage/partitions.bin",
        ])
    }

    func testReadFlashUsesTheScriptSpelling() throws {
        let command = try EsptoolCommand.readFlash(
            tool: script, chip: "esp32s3", port: port,
            address: 0x8000, byteCount: 0xC00, outputPath: "/t.bin")
        XCTAssertEqual(command.executable, EsptoolCommand.Tool.pythonPath)
        XCTAssertEqual(command.arguments.first, script.path)
        XCTAssertTrue(command.arguments.contains("read_flash"))
    }

    func testReadFlashRefusesWhatWriteFlashRefuses() {
        XCTAssertThrowsError(try EsptoolCommand.readFlash(
            tool: tool, chip: "esp32s3", port: "  ",
            address: 0x8000, byteCount: 0xC00, outputPath: "/t.bin")
        ) { XCTAssertEqual($0 as? EsptoolCommandError, .noPort) }
        XCTAssertThrowsError(try EsptoolCommand.readFlash(
            tool: tool, chip: "", port: port,
            address: 0x8000, byteCount: 0xC00, outputPath: "/t.bin")
        ) { XCTAssertEqual($0 as? EsptoolCommandError, .noChip) }
        XCTAssertThrowsError(try EsptoolCommand.readFlash(
            tool: EsptoolCommand.Tool(path: ""), chip: "esp32s3", port: port,
            address: 0x8000, byteCount: 0xC00, outputPath: "/t.bin")
        ) { XCTAssertEqual($0 as? EsptoolCommandError, .noTool) }
        XCTAssertThrowsError(try EsptoolCommand.readFlash(
            tool: tool, chip: "esp32s3", port: port, baud: 0,
            address: 0x8000, byteCount: 0xC00, outputPath: "/t.bin")
        ) { XCTAssertEqual($0 as? EsptoolCommandError, .badBaud(0)) }
        XCTAssertThrowsError(try EsptoolCommand.readFlash(
            tool: tool, chip: "esp32s3", port: port,
            address: 0x8000, byteCount: 0, outputPath: "/t.bin")
        ) { XCTAssertEqual($0 as? EsptoolCommandError, .badReadExtent(address: 0x8000, byteCount: 0)) }
        XCTAssertThrowsError(try EsptoolCommand.readFlash(
            tool: tool, chip: "esp32s3", port: port,
            address: 0x8000, byteCount: 0xC00, outputPath: "")
        ) { XCTAssertEqual($0 as? EsptoolCommandError, .noOutputPath) }
    }

    // MARK: - flash-id

    func testFlashIDIsChipPinned() throws {
        let command = try EsptoolCommand.flashID(tool: tool, chip: "esp32s3", port: port)
        XCTAssertEqual(command.arguments, [
            "--chip", "esp32s3",
            "--port", "/dev/cu.usbmodem101",
            "--baud", "921600",
            "--before", "default-reset",
            "--after", "hard-reset",
            "flash-id",
        ])
        let legacy = try EsptoolCommand.flashID(tool: script, chip: "esp32s3", port: port)
        XCTAssertEqual(legacy.arguments.last, "flash_id")
    }

    func testFlashIDNeverOmitsThePortOrTheChip() {
        XCTAssertThrowsError(try EsptoolCommand.flashID(tool: tool, chip: "esp32s3", port: "")) {
            XCTAssertEqual($0 as? EsptoolCommandError, .noPort)
        }
        XCTAssertThrowsError(try EsptoolCommand.flashID(tool: tool, chip: " ", port: port)) {
            XCTAssertEqual($0 as? EsptoolCommandError, .noChip)
        }
    }

    // MARK: - detected flash size

    func testTheDetectedFlashSizeIsRead() {
        let output = """
            Connected to ESP32-S3 on /dev/cu.usbmodem101:
            Chip type:          ESP32-S3 (QFN56) (revision v0.2)
            MAC:                28:84:85:55:55:94
            Flash Memory Information:
            =========================
            Manufacturer: c8
            Device: 4019
            Detected flash size: 32MB
            Flash type set in eFuse: quad (4 data lines)
            """
        XCTAssertEqual(EsptoolOutput.detectedFlashBytes(in: output), 0x2000000)
    }

    func testTheLastFlashSizeWinsAsInTheCLI() {
        let output = "Detected flash size: 16MB\nDetected flash size: 32 MB\n"
        XCTAssertEqual(EsptoolOutput.detectedFlashBytes(in: output), 32 * 0x100000)
        XCTAssertEqual(
            EsptoolOutput.detectedFlashBytes(in: "Detected flash size: 16MB"), 16 * 0x100000)
    }

    func testNoFlashSizeMeansNil() {
        XCTAssertNil(EsptoolOutput.detectedFlashBytes(in: "Detected flash size: Unknown"))
        XCTAssertNil(EsptoolOutput.detectedFlashBytes(in: ""))
        XCTAssertNil(EsptoolOutput.detectedFlashBytes(
            in: "Detected flash size: 99999999999999999999MB"))
    }
}
