#ifndef AUDIO_METRICS_H
#define AUDIO_METRICS_H

#include <stdint.h>

typedef struct AudioMetrics AudioMetrics;

AudioMetrics *audio_metrics_create(void);
void audio_metrics_destroy(AudioMetrics *metrics);
uint64_t audio_metrics_callback_begin(void);
void audio_metrics_record(AudioMetrics *metrics, float input_peak, float output_peak, uint64_t callback_start_ticks);
uint64_t audio_metrics_callbacks(const AudioMetrics *metrics);
uint64_t audio_metrics_silent_callbacks(const AudioMetrics *metrics);
float audio_metrics_input_peak(const AudioMetrics *metrics);
float audio_metrics_output_peak(const AudioMetrics *metrics);
double audio_metrics_elapsed_since_callback_ms(const AudioMetrics *metrics);
double audio_metrics_first_callback_elapsed_ms(const AudioMetrics *metrics);
double audio_metrics_average_callback_ms(const AudioMetrics *metrics);
double audio_metrics_max_callback_ms(const AudioMetrics *metrics);

#endif
