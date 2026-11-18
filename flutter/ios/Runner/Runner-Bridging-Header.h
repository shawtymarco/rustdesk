#import "GeneratedPluginRegistrant.h"

#import "bridge_generated.h"

#include <stddef.h>
#include <stdint.h>

// Native video output (src/flutter.rs, ios_render). Returns 0 when not drawn,
// 1 when drawn, 2 when drawn as the first frame of the texture.
typedef int32_t (*rustdesk_ios_on_rgba_fn)(const uint8_t *buffer, size_t len,
                                            int32_t width, int32_t height);
void rustdesk_ios_set_video_callback(rustdesk_ios_on_rgba_fn callback);
