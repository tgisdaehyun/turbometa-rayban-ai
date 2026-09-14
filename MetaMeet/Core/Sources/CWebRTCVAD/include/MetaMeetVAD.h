#ifndef METAMEET_VAD_H
#define METAMEET_VAD_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
int MetaMeetHasVoice(const int16_t *samples, size_t count);
#ifdef __cplusplus
}
#endif
#endif
