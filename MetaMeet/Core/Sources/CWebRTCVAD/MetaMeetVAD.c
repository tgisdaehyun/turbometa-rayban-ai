#include "MetaMeetVAD.h"
#include "webrtc/common_audio/vad/include/webrtc_vad.h"
int MetaMeetHasVoice(const int16_t *samples, size_t count) {
    if (!samples) return -1;
    VadInst *vad = WebRtcVad_Create();
    if (!vad) return -1;
    if (WebRtcVad_Init(vad) || WebRtcVad_set_mode(vad, 3)) { WebRtcVad_Free(vad); return -1; }
    size_t frames = count / 320, voiced = 0;
    for (size_t i = 0; i < frames; ++i) {
        int result = WebRtcVad_Process(vad, 16000, samples + i * 320, 320);
        if (result < 0) { WebRtcVad_Free(vad); return -1; }
        voiced += result == 1;
    }
    WebRtcVad_Free(vad);
    size_t required = frames < 20 ? (frames + 1) / 2 : 10;
    return frames > 0 && voiced >= required;
}
