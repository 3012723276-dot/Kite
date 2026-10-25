#if os(macOS)
import AVFoundation
import KiteObjC
import Testing

/// The engine leans on `KiteCatchException` to survive AVFAudio's
/// NSExceptions; prove it really catches one rather than trusting the shim.
@Suite struct KiteObjCTests {
    @Test func catchesAnAVFAudioException() {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        // Never attached: AVFAudio's "required condition is false" raise.
        let exception = KiteCatchException {
            engine.connect(player, to: engine.mainMixerNode, format: nil)
        }
        #expect(exception?.name.rawValue == "com.apple.coreaudio.avfaudio")
    }

    @Test func returnsNilWhenNothingIsRaised() {
        var ran = false
        #expect(KiteCatchException { ran = true } == nil)
        #expect(ran)
    }
}
#endif
