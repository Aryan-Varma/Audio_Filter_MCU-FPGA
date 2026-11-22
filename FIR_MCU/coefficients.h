/**
 * @file coefficients.h
 * @brief Default bootstrap Q1.15 FIR filter coefficients for Renesas RA6E2.
 *        129-tap low-pass filter (Fs=48000 Hz, Cutoff=4500 Hz, Hamming window).
 *        Can be regenerated anytime using filter_designer.py.
 */

#ifndef COEFFICIENTS_H
#define COEFFICIENTS_H

#include <stdint.h>

#define FILTER_NUM_TAPS     (129)
#define FILTER_SAMPLE_RATE  (48000)
#define FILTER_CUTOFF_HZ    (4500)

/* Filter taps in signed Q1.15 format [-32768, 32767], stored in Flash ROM */
static const int16_t FILTER_TAPS[FILTER_NUM_TAPS] = {
         0,     -2,     -3,     -4,     -3,     -1,      3,      7,
        10,     10,      6,     -3,    -14,    -23,    -26,    -18,
         0,     23,     43,     51,     41,     13,    -28,    -66,
       -88,    -80,    -40,     22,     88,    133,    136,     89,
         0,   -104,   -186,   -212,   -165,    -49,    103,    241,
       311,    278,    137,    -75,   -294,   -439,   -446,   -290,
         0,    341,    617,    716,    567,    173,   -378,   -921,
     -1258,  -1206,   -652,    401,   1828,   3394,   4807,   5792,
      6144,   5792,   4807,   3394,   1828,    401,   -652,  -1206,
     -1258,   -921,   -378,    173,    567,    716,    617,    341,
         0,   -290,   -446,   -439,   -294,    -75,    137,    278,
       311,    241,    103,    -49,   -165,   -212,   -186,   -104,
         0,     89,    136,    133,     88,     22,    -40,    -80,
       -88,    -66,    -28,     13,     41,     51,     43,     23,
         0,    -18,    -26,    -23,    -14,     -3,      6,     10,
        10,      7,      3,     -1,     -3,     -4,     -3,     -2,
         0
};

#endif /* COEFFICIENTS_H */