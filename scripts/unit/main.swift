// Checks for the shell's Foundation-only logic, without building or launching the app.
// Run: sh scripts/unit/run.sh
import AppKit

var failures = 0
func check(_ ok: Bool, _ label: String, line: Int = #line) {
    if !ok { failures += 1; print("FAIL line \(line): \(label)") }
}

// Pinyin
check(Pinyin.syllable("中") == "zhong", "syllable of 中")
check(Pinyin.syllable("a") == nil, "ASCII has no syllable")
check(Pinyin.matches("zhongwen", in: "中文笔记.md"), "full syllables")
check(Pinyin.matches("zw", in: "中文笔记.md"), "initials")
check(Pinyin.matches("zhongw", in: "中文笔记.md"), "syllable then a prefix at the end")
check(Pinyin.matches("wenbj", in: "中文笔记.md"), "starts mid-name")
check(Pinyin.matches("bj", in: "PRD-笔记.md"), "mixed with ASCII")
check(Pinyin.matches("prdbj", in: "PRD笔记.md"), "ASCII then pinyin, contiguous")
check(!Pinyin.matches("zhwen", in: "中文笔记.md"), "no mid-syllable fragment before the end")
check(!Pinyin.matches("zj", in: "中文笔记.md"), "characters must be contiguous")
check(!Pinyin.matches("notes", in: "notes.md"), "ASCII-only names are left to literal matching")

// ImageSizes
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nib-unit-\(getpid())")
try? FileManager.default.createDirectory(at: tmp.appendingPathComponent("a b"), withIntermediateDirectories: true)
let png = tmp.appendingPathComponent("a b/shot.png")
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 30, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
try! rep.representation(using: .png, properties: [:])!.write(to: png)
let doc = "x ![a](a%20b/shot.png) y ![b](<a b/shot.png>) ![c](https://e.com/x.png) ![d](missing.png)"
let sizes = ImageSizes.scan(doc, base: tmp.path)
check(sizes[png.standardizedFileURL.path] == [30, 20], "size read from header, percent-encoded and <> paths")
check(sizes.count == 1, "remote and missing images skipped")
check(ImageSizes.resolve("../x.png", base: "/a/b") == "/a/x.png", "relative paths normalised")
try? FileManager.default.removeItem(at: tmp)

print(failures == 0 ? "unit checks passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
