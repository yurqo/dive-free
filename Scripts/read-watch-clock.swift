// Read the native watchOS system clock to verify a simulator capture.
import Foundation
import Vision
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
try VNImageRequestHandler(url: URL(fileURLWithPath: CommandLine.arguments[1])).perform([request])
let clocks = (request.results ?? []).filter {
    $0.boundingBox.minY > 0.85 && $0.boundingBox.midX > 0.35 && $0.boundingBox.midX < 0.65
}.compactMap { $0.topCandidates(1).first?.string }
guard let clock = clocks.first(where: { $0.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil })
else { print("unreadable"); exit(2) }
print(clock)
