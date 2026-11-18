#import "GeneratedPluginRegistrant.h"

#import "bridge_generated.h"

#include <stddef.h>
#include <stdint.h>

// Native video output (src/flutter.rs, ios_render). Returns 0 when not drawn,
// 1 when drawn, 2 when drawn as the first frame of the texture.
typedef int32_t (*rustdesk_ios_on_rgba_fn)(const uint8_t *buffer, size_t len,
                                            int32_t width, int32_t height);
// The setters take untyped pointers so that this declaration matches the one
// in bridge_generated.h; pass a rustdesk_ios_on_rgba_fn / _on_encoded_fn.
void rustdesk_ios_set_video_callback(const void *callback);

// Hardware decoding (src/flutter.rs, ios_render). Returns 0 when not handled,
// 1 when handled, 2 when the decoder needs a key frame first; writes the
// decoded picture size (0 while unknown) to out_width / out_height.
typedef int32_t (*rustdesk_ios_on_encoded_fn)(const uint8_t *data, size_t len,
                                               int32_t h265, int32_t key,
                                               int32_t *out_width,
                                               int32_t *out_height);
void rustdesk_ios_set_decoder_callback(const void *callback);
