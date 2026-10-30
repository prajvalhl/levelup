import AudioMetrics
import XCTest

final class AudioMetricsTests: XCTestCase {
    func testSilentAndNonSilentCallbackMetrics() throws {
        let metrics = try XCTUnwrap(audio_metrics_create())
        defer { audio_metrics_destroy(metrics) }
        audio_metrics_record(metrics, 0, 0, audio_metrics_callback_begin())
        audio_metrics_record(metrics, 0.25, 0.125, audio_metrics_callback_begin())
        XCTAssertEqual(audio_metrics_callbacks(metrics), 2)
        XCTAssertEqual(audio_metrics_silent_callbacks(metrics), 0)
        XCTAssertEqual(audio_metrics_input_peak(metrics), 0.25, accuracy: 0.0001)
        XCTAssertEqual(audio_metrics_output_peak(metrics), 0.125, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(audio_metrics_first_callback_elapsed_ms(metrics), 0)
        XCTAssertGreaterThanOrEqual(audio_metrics_average_callback_ms(metrics), 0)
        XCTAssertGreaterThanOrEqual(audio_metrics_max_callback_ms(metrics), 0)
        audio_metrics_record(metrics, 0, 0, audio_metrics_callback_begin())
        XCTAssertEqual(audio_metrics_silent_callbacks(metrics), 1)
    }
}
