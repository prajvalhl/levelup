#include "AudioMetrics.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach_time.h>

struct AudioMetrics {
    _Atomic uint64_t callbacks;
    _Atomic uint64_t silent_callbacks;
    _Atomic uint32_t input_peak_bits;
    _Atomic uint32_t output_peak_bits;
    _Atomic uint64_t last_callback_ticks;
    _Atomic uint64_t start_ticks;
    _Atomic uint64_t first_callback_ticks;
    _Atomic uint64_t callback_duration_total_ticks;
    _Atomic uint64_t callback_duration_max_ticks;
};

AudioMetrics *audio_metrics_create(void) {
    AudioMetrics *metrics = calloc(1, sizeof(AudioMetrics));
    if (metrics) atomic_store_explicit(&metrics->start_ticks, mach_absolute_time(), memory_order_relaxed);
    return metrics;
}

void audio_metrics_destroy(AudioMetrics *metrics) {
    free(metrics);
}

uint64_t audio_metrics_callback_begin(void) {
    return mach_absolute_time();
}

void audio_metrics_record(AudioMetrics *metrics, float input_peak, float output_peak, uint64_t callback_start_ticks) {
    if (!metrics) return;
    atomic_fetch_add_explicit(&metrics->callbacks, 1, memory_order_relaxed);
    uint64_t now = mach_absolute_time();
    atomic_store_explicit(&metrics->last_callback_ticks, now, memory_order_relaxed);
    uint64_t duration = now - callback_start_ticks;
    atomic_fetch_add_explicit(&metrics->callback_duration_total_ticks, duration, memory_order_relaxed);
    uint64_t previous_max = atomic_load_explicit(&metrics->callback_duration_max_ticks, memory_order_relaxed);
    if (duration > previous_max) {
        atomic_store_explicit(&metrics->callback_duration_max_ticks, duration, memory_order_relaxed);
    }
    uint64_t no_first_callback = 0;
    atomic_compare_exchange_strong_explicit(&metrics->first_callback_ticks, &no_first_callback, now,
                                            memory_order_relaxed, memory_order_relaxed);
    if (input_peak == 0.0f) {
        atomic_fetch_add_explicit(&metrics->silent_callbacks, 1, memory_order_relaxed);
    } else {
        atomic_store_explicit(&metrics->silent_callbacks, 0, memory_order_relaxed);
    }
    uint32_t input_bits, output_bits;
    memcpy(&input_bits, &input_peak, sizeof(input_bits));
    memcpy(&output_bits, &output_peak, sizeof(output_bits));
    atomic_store_explicit(&metrics->input_peak_bits, input_bits, memory_order_relaxed);
    atomic_store_explicit(&metrics->output_peak_bits, output_bits, memory_order_relaxed);
}

static double ticks_to_milliseconds(uint64_t ticks) {
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    return (double)ticks * (double)timebase.numer / (double)timebase.denom / 1000000.0;
}

double audio_metrics_average_callback_ms(const AudioMetrics *metrics) {
    if (!metrics) return -1.0;
    uint64_t count = atomic_load_explicit(&metrics->callbacks, memory_order_relaxed);
    if (count == 0) return 0.0;
    uint64_t total = atomic_load_explicit(&metrics->callback_duration_total_ticks, memory_order_relaxed);
    return ticks_to_milliseconds(total / count);
}

double audio_metrics_max_callback_ms(const AudioMetrics *metrics) {
    return metrics ? ticks_to_milliseconds(atomic_load_explicit(&metrics->callback_duration_max_ticks, memory_order_relaxed)) : -1.0;
}

uint64_t audio_metrics_callbacks(const AudioMetrics *metrics) {
    return metrics ? atomic_load_explicit(&metrics->callbacks, memory_order_relaxed) : 0;
}

uint64_t audio_metrics_silent_callbacks(const AudioMetrics *metrics) {
    return metrics ? atomic_load_explicit(&metrics->silent_callbacks, memory_order_relaxed) : 0;
}

static float float_from_bits(uint32_t bits) {
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

float audio_metrics_input_peak(const AudioMetrics *metrics) {
    return float_from_bits(metrics ? atomic_load_explicit(&metrics->input_peak_bits, memory_order_relaxed) : 0);
}

float audio_metrics_output_peak(const AudioMetrics *metrics) {
    return float_from_bits(metrics ? atomic_load_explicit(&metrics->output_peak_bits, memory_order_relaxed) : 0);
}

double audio_metrics_elapsed_since_callback_ms(const AudioMetrics *metrics) {
    if (!metrics) return -1.0;
    uint64_t last = atomic_load_explicit(&metrics->last_callback_ticks, memory_order_relaxed);
    if (last == 0) return -1.0;
    uint64_t delta = mach_absolute_time() - last;
    return ticks_to_milliseconds(delta);
}

double audio_metrics_first_callback_elapsed_ms(const AudioMetrics *metrics) {
    if (!metrics) return -1.0;
    uint64_t start = atomic_load_explicit(&metrics->start_ticks, memory_order_relaxed);
    uint64_t first = atomic_load_explicit(&metrics->first_callback_ticks, memory_order_relaxed);
    if (start == 0 || first == 0) return -1.0;
    uint64_t delta = first - start;
    return ticks_to_milliseconds(delta);
}
