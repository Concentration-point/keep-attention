import Darwin
import Testing

@main
struct KeepAttentionTestsRunner {
    static func main() async {
        let status: CInt = await Testing.__swiftPMEntryPoint(passing: nil)
        Darwin.exit(status)
    }
}
